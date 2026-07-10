# 設計ノート

源内（genai-web / genai-ai-api）をさくらのAI Engine で動かすにあたっての、主要な設計判断とその理由をまとめる。差分の一覧は [README](../README.md) を参照。

## 基本方針

1. **外側のインターフェースを守り、内側を差し替える。**
   源内 Web ↔ AI アプリ間のプロトコル（`POST {inputs} → {outputs, usageMetadata}`、`x-api-key` / `x-user-id`）と、フロントエンド ↔ API 間の REST 契約は変更しない。これによりフロントエンドと AI アプリの実装を最大限流用できる。
2. **上流と共存できる形にする。**
   さくら対応は追加のプロバイダ・環境変数として実装し、既定値では従来どおり AWS 構成で動作する。上流の更新を取り込みやすくするため、既存コードの書き換えは最小限に抑える。
3. **`docker compose up` で一式が動くこと。**
   外部依存はさくらのAI Engine と Brave Search API のみ。それ以外（DB・IdP・オブジェクトストレージ・キュー）はすべてローカルコンテナで完結する。

## genai-web

### LLM プロバイダの追加（sakura）

genai-web の LLM 呼び出しは `api[model.type]` のディスパッチテーブル（`packages/cdk/lambda/utils/api.ts`）で抽象化されているため、OpenAI 互換 Chat Completions を叩く `sakura` プロバイダ（`sakuraApi.ts`）を追加する方式を取った。

- 依存追加を避けるため fetch ベースで実装（SSE パースも自前）。
- `MODEL_PROVIDER=sakura` を設定すると、フロントエンドが旧来の `type: 'bedrock'` を送ってきてもさくら側へ振り向ける。フロントエンドのモデル選択 UI は無改修。
- Qwen3 系などの thinking モデルは `<think>...</think>` を出力するため、チャンク境界をまたぐタグも処理できるストリーミングフィルタ（`ThinkTagFilter`）で除去する。
- usage（トークン数）はストリーム終端の usage チャンクから取得し、既存のメタデータ形式に載せ替える。

### Lambda ハンドラの常駐サーバ化

約 50 本の Lambda ハンドラは `createApiHandler(fn)` でラップされた「`APIGatewayProxyEvent` を受け取る純関数」なので、HTTP リクエストから `APIGatewayProxyEvent` を組み立てるアダプタ（`packages/server/src/adapter.ts`)を書き、**ハンドラ本体を無改修のまま** Hono サーバ（`packages/server`）にマウントした。

チャットのストリーミングは、オリジナルでは Lambda Response Streaming をフロントエンドが AWS SDK で直接 Invoke する構成だったため、代替として `POST /predict/stream`（JSONL の HTTP ストリーミング）を追加し、フロントエンドは `fetch` + `ReadableStream` で読むようにした（`VITE_APP_AUTH_PROVIDER=oidc` のときのみ）。

### DynamoDB → PostgreSQL

データアクセスは `repository/` 層に集約されているため、ここだけを書き換えた。DynamoDB の単一テーブル設計は `genai_items(pk, sk, attributes JSONB)` でそのまま再現し、**エンティティの JSON 形状を変えない**ことでハンドラ層・フロントエンドを無改修にしている。

- DynamoDB のソートキーはバイト順で整列されるため、`sk` 列に `COLLATE "C"` を指定してロケール非依存の順序を保証する。
- ページネーションは `LastEvaluatedKey` 互換の base64 キーセット方式。
- リポジトリのテストは DynamoDB モックから PGlite（WASM 版 PostgreSQL）による実 SQL 検証に置き換えた。

### 認証: Cognito → OIDC（Keycloak）

フロントエンドに認証ファサード（`lib/auth.ts`）を導入し、`VITE_APP_AUTH_PROVIDER=oidc` のとき oidc-client-ts（認可コード + PKCE）を使う。セッションオブジェクトは Amplify の `fetchAuthSession()` 互換の形（`tokens.accessToken.payload['cognito:groups']` など）で返すため、権限判定まわりの既存コンポーネントは無改修で動く。

- Keycloak のグループ／レルムロールを `cognito:groups` クレームにマッピング（サーバ側・フロント側の両方）。
- API 認可にはリソースサーバ向けの access_token を使用。
- Docker 構成では「ブラウザから見た IdP の URL（トークンの `iss`）」と「API コンテナから IdP へ到達する URL」が異なるため、`OIDC_ISSUER`（iss 検証用）と `OIDC_INTERNAL_ISSUER`（ディスカバリ/JWKS 取得用）を分離した。
- ファイル所有権の判定に使う identityId は、Cognito Identity Pool の代わりに JWT の `sub` を使用（`AUTH_PROVIDER=oidc`）。
- 外部 AI アプリに渡す安定ユーザー ID は、KMS HMAC の代わりにローカル HMAC-SHA256（`USER_IDENTIFIER_HMAC_SECRET`）で生成。

React StrictMode では effect が二重実行され、一度しか使えない認可コードを二重交換して「Code not valid」になるため、コールバック処理はモジュールレベルでシングルトン化している。

### チーム管理・AI アプリ管理（クリーンルーム実装）

オリジナルのチーム管理・AI アプリ管理系 17 ファイルは **Amazon Software License (ASL)** の対象で、AWS 以外の環境では利用できない（`genai-web/docs/ASL対象ファイル.md` に明記）。そのため該当機能は、**MIT ライセンスである型定義パッケージとフロントエンドから読み取れる API 契約のみを根拠に新規実装**した（`packages/server/src/teamRepository.ts`, `routes/teams.ts`, `routes/exapps.ts`）。ASL 対象ファイルは参照・流用していない。

- データモデルは DynamoDB の模倣ではなく素直なリレーショナル設計（teams / team_users / ex_apps / invoke_histories）。
- チームメンバー追加の「メールアドレス → ユーザー解決」は Cognito の代わりに Keycloak Admin REST API を使用。
- AI アプリの API キーは Secrets Manager の代わりに DB に保存（本番で暗号化が必要な場合は pgcrypto などを検討）。

### 非同期ジョブ: SQS → PostgreSQL ジョブテーブル

AI アプリの非同期実行（202 + `status_url`）のポーリングは、SQS の代わりに PostgreSQL のジョブテーブル + アプリ内ワーカーで実装した（`SELECT ... FOR UPDATE SKIP LOCKED` で多重実行を防止）。外部 MQ サービスを使わないことで、**ローカルと実環境の構成が完全に同一**になる。文字起こしジョブも同じ方式。

### 文字起こし: Transcribe → Whisper 互換 API

さくらのAI Engine の `/audio/transcriptions`（`whisper-large-v3-turbo`）を使用。Whisper API は同期型だが、長時間音声を考慮してジョブテーブルで非同期化し、フロントエンドの既存ポーリング UI をそのまま活かした。話者分離（speaker diarization）は Whisper にないため非対応。

なお `audioKey` は署名付き URL のパスから抽出される仕様のため、path-style アドレッシング（MinIO 等）ではバケット名がキーの先頭に付く。サーバ側で除去し、所有者チェックを行っている。

## AI アプリ（genai-ai-api/sakura）

### lawsy-custom（法令調査）

オリジナル（google-cloud/lawsy-custom-bq）は Vertex AI Gemini + BigQuery ML。置き換えの要点:

- **Web グラウンディングの分解**: Gemini の `google_search` ツールは「検索＋根拠付け」が一体だが、これを Brave Search API（検索）＋検索結果のプロンプト注入（根拠付け）に分解した。クエリ中の URL は SSRF 対策付きで本文を取得してプロンプトに含める（`url_context` の代替）。
- **ベクトル検索は法令名のみ**: オリジナルの設計を踏襲し、埋め込み対象は法令名だけ（条文本文は埋め込まない）。約 7,800 法令 × 1024 次元なので埋め込みコストが小さく、更新も速い。条文は法令番号で引く。
- **正確性の担保**: 条文の本文は必ずローカルの e-Gov 法令 DB から取得し、Web 検索結果は補足情報に留める。推定された法令名と DB から取得された法令名の乖離をバイグラム類似度で検知し、乖離時は「指定された法令が存在しない可能性」の開示をモデルに強制する安全機構も維持した。
- モデルは 2 段構え（法令名推定・条文選択 = 軽量モデル、レポート生成 = 高性能モデル）。

### query-expansion-rag（社内文書 RAG）

オリジナル（aws/query-expansion-rag）は Bedrock Converse + Knowledge Base（OpenSearch Serverless）。

- `converse` 呼び出しは OpenAI 互換 Chat Completions へほぼ 1:1 で移植。TOML による推論設定の階層（defaults / apps）は維持した。
- `retrieve_and_generate`（検索＋クエリ別回答生成がマネージドで一体）は、**pgvector 検索 + 取得チャンクの直接関連度評価**に再設計した。関連度評価プロンプトはもともと「文書の抜粋」を評価する設計なので、生成テキストではなくチャンクを直接評価するほうが自然であり、クエリ別の中間生成が不要になる分 LLM 呼び出しも減る。
- 複数クエリで同一チャンクがヒットした場合は最高評価のみ残す重複排除を追加。
- 文書取り込みは S3 + KB 自動同期の代わりに `ingest.py`（チャンク化 → 埋め込み → 投入）。メタデータは AWS KB と同じ `<ファイル名>.metadata.json` サイドカー形式を踏襲。

### Embedding の注意点

既定の `multilingual-e5-large` は **`query: ` / `passage: ` プレフィックスが必須**（検索側・文書側で異なる）。プレフィックスは環境変数で変更でき、e5 系以外のモデルでは空文字にする。埋め込みモデルを変えるとベクトル次元が変わるため、スキーマの `vector(1024)` を変更してデータの再構築が必要。

## 既知の制約

| 項目 | 内容 |
|---|---|
| 画像生成 | さくらのAI Engine に画像生成がないため非対応（UI 非表示）。画像「入力」は VL 系モデルで将来対応可能 |
| 話者分離 | Whisper にないため文字起こしは話者ラベルなし |
| 添付ファイル | テキスト系（txt/md/csv/html/json 等)は本文展開、画像は data URL（VL 対応モデルのみ有効）。PDF / Office 文書は本文抽出未実装 |
| 引用の粒度 | Gemini グラウンディングのチャンク単位の出典対応付けは再現されない（検索結果リスト単位） |
| コスト表示 | さくらのAI Engine の単価表を組み込んでいないため推定コストは未表示（単価表を設定すれば有効化可能） |
| パスワードリセット | Keycloak に委譲（源内独自のリセットフローは未接続） |

## 検証状況

- genai-web: 既存ユニットテスト約 790 件パス + sakura プロバイダ / PostgreSQL リポジトリのテストを追加（PGlite）
- 実環境（さくらのAI Engine 実 API）で、チャットのストリーミング・埋め込み・Whisper・lawsy（全法令 7,810 件投入）・qerag を E2E 確認
- ブラウザから OIDC ログイン → チャット → チーム作成 → AI アプリ登録 → 実行 → 履歴の一気通貫を確認
