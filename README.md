# genai-sakura — 源内（さくらのAI Engine 構成）

デジタル庁の生成AI利活用基盤「源内」を、**AWS・Azure・Google Cloud のマネージドサービスに依存せず、[さくらのAI Engine](https://www.sakura.ad.jp/aipf/) と Docker Compose で動かす**ための構成です。オリジナルの [genai-web](https://github.com/digital-go-jp/genai-web) / [genai-ai-api](https://github.com/digital-go-jp/genai-ai-api) をフォークし、AI 呼び出しとインフラ依存を置き換えました。

> **注意**: これはデジタル庁とは無関係の**非公式**な派生構成です。ローカル検証を目的としており、公式のサポート・保証はありません。

![チャット画面。さくらのAI Engine のモデル（Qwen3.6 / Kimi K2.6 / Qwen3 Coder / Qwen3 VL / GPT-OSS / LLM-jp / Gemma / Phi-4 など）を選択できる](docs/images/chat-model-selector.png)

## リポジトリ構成

本リポジトリは起動用の Compose とドキュメントを持ち、本体は submodule として取り込んでいます。

| パス | 内容 |
|---|---|
| [`genai-web/`](https://github.com/chibiegg/genai-web/tree/sakura-ai-engine) | 源内 Web（フォーク、`sakura-ai-engine` ブランチ） |
| [`genai-ai-api/`](https://github.com/chibiegg/genai-ai-api/tree/sakura-ai-engine) | 行政実務用 AI アプリ（フォーク、`sakura-ai-engine` ブランチ。さくら移植版は `sakura/` 配下） |
| `docker-compose.yaml` | フルスタック起動用 Compose（9 サービス） |
| [`docs/design-notes.md`](docs/design-notes.md) | 設計判断の詳細（なぜそう置き換えたか） |

## クイックスタート

```bash
# 0. clone（submodule ごと取得）
git clone --recursive git@github.com:chibiegg/genai-sakura.git
cd genai-sakura

# 1. シークレットを設定
cp .env.example .env
#   .env を編集して SAKURA_AI_ENGINE_TOKEN / BRAVE_SEARCH_API_KEY を設定

# 2. 全サービスを起動（初回はビルドに数分）
docker compose up -d --build

# 3. AIアプリ（lawsy / qerag）を共通アプリとして登録（初回のみ）
sh scripts/seed-apps.sh

# 4. ブラウザで開く
open http://localhost:5173
#   ログイン: dev-user / dev-password
```

| URL | 用途 |
|---|---|
| http://localhost:5173 | 源内 Web（フロントエンド） |
| http://localhost:3001 | API サーバ |
| http://localhost:8180 | Keycloak（管理: admin / admin） |
| http://localhost:9001 | MinIO コンソール（minioadmin / minioadmin） |

> AIアプリ（法令調査・社内文書検索）は、起動後に**データ投入**が必要です（後述「AIアプリのデータ投入」）。データが無くてもチャット等は動きます。

---

## オリジナルとの差分

源内は AWS（genai-web は Amazon Bedrock ベースの GenU フォーク）、Azure、Google Cloud 上で動くよう作られています。本構成は AI 部分をさくらのAI Engine に、周辺インフラをオープンソース／クラウド非依存の構成に置き換えました。

### AI 機能の置き換え

| 機能 | オリジナル | 本構成 |
|---|---|---|
| テキスト生成 | Amazon Bedrock（Converse API） | さくらのAI Engine（OpenAI 互換 Chat Completions）。`Kimi-K2.6` / `Qwen3.6` / `Qwen3-Coder` / `Qwen3-VL`（画像入力対応） / `gpt-oss-120b` / `LLM-jp` / `Gemma` / `Phi-4` など |
| 埋め込み | Bedrock / BigQuery ML / OpenSearch | さくらのAI Engine Embedding API（`multilingual-e5-large`） |
| ベクトル検索 | Bedrock Knowledge Base + OpenSearch Serverless / BigQuery VECTOR_SEARCH | PostgreSQL + pgvector |
| Web 検索（法令調査） | Gemini の Google 検索グラウンディング | Brave Search API + ページ本文取得 |
| 文字起こし | Amazon Transcribe | さくらのAI Engine の Whisper 互換 API（`whisper-large-v3-turbo`） |
| 画像生成 | Bedrock（Nova Canvas / Stability） | **非対応**（AI Engine に画像生成なし。UI から非表示） |

> **モデルに関する注意**: `preview/` プレフィックスのモデルは**パブリックプレビュー**での提供であり、さくらのAI Engine 側で予告なく追加・変更・提供終了されることがあります。選択肢にあってもその時点で利用できないモデルが含まれる場合は、`docker-compose.yaml` の `MODEL_IDS`（api）と `VITE_APP_MODEL_IDS`(web) から該当モデルを外してください。現在利用可能なモデルの一覧は `GET {SAKURA_AI_ENGINE_BASE_URL}/models` で確認できます。

### インフラの置き換え

| 要素 | オリジナル | 本構成 |
|---|---|---|
| 実行基盤 | AWS Lambda + API Gateway | 常駐 API サーバ（Hono）。既存の Lambda ハンドラを HTTP アダプタでそのままマウント |
| 認証 | Amazon Cognito（+ SAML） | OIDC（Keycloak）。フロントは oidc-client-ts |
| データベース | Amazon DynamoDB | PostgreSQL（会話履歴は単一テーブル設計を踏襲、チーム/アプリはリレーショナル設計） |
| ストレージ | Amazon S3 | S3 互換オブジェクトストレージ（ローカルは MinIO） |
| 非同期キュー | Amazon SQS | PostgreSQL のジョブテーブル + アプリ内ワーカー（`SELECT ... FOR UPDATE SKIP LOCKED`） |
| 安定ユーザーID | AWS KMS HMAC | ローカル HMAC-SHA256 |
| チャットのストリーミング | Lambda Response Streaming（フロントが Lambda を直接 Invoke） | HTTP ストリーミング（`/predict/stream`、JSONL） |

### 動かなくなる／劣化する機能

- **画像生成**: さくらのAI Engine に該当機能がないため無効（UI 非表示）。将来 `preview/Qwen3-VL-*` を使えば画像「入力」は可能。
- **文字起こしの話者分離**: Whisper に話者分離がないため、話者ラベルは付かない。
- **法令調査の引用品質**: Gemini グラウンディングの精緻な出典対応付けの代わりに Brave 検索結果を用いるため、引用の粒度は粗くなる。

### ライセンス上の注意（重要）

オリジナルの genai-web のうち、**チーム管理・AIアプリ管理系（17ファイル）は Amazon Software License (ASL) 対象**で、AWS 以外では利用できません（`genai-web/docs/ASL対象ファイル.md`）。本構成では該当機能を、公開されている API 契約（型定義とフロントエンド、いずれも MIT）からクリーンルームで新規実装しています（`genai-web/packages/server/src/{teamRepository,teamSchema}.ts`, `routes/{teams,exapps}.ts`）。ASL 対象ファイルは一切参照・流用していません。

---

## アーキテクチャ

```
ブラウザ ─────────────────┐
  http://localhost:5173   │ (Vite / React)
                          ▼
  ┌─────────────────────────────────────────────┐
  │ 源内 Web API (Hono, :3001)                    │
  │  - 既存 Lambda ハンドラ + アダプタ            │
  │  - OIDC 検証 / チーム・AIアプリ / 文字起こし  │
  └───┬────────┬────────┬──────────┬─────────────┘
      │        │        │          │
  PostgreSQL  MinIO   Keycloak   AIアプリ（HTTP: {inputs}→{outputs}）
  (会話/team) (S3互換) (OIDC)     ├─ lawsy  ─→ pgvector + Brave + AI Engine
                                 └─ qerag  ─→ pgvector + AI Engine
                                      すべて AI Engine (Chat / Embedding / Whisper)
```

構成するサービス（`docker-compose.yaml`）:

| サービス | 内容 |
|---|---|
| `web` | 源内 Web フロントエンド（Vite 開発サーバ） |
| `api` | 源内 Web API サーバ |
| `db` | PostgreSQL（会話履歴・チーム・AIアプリ・実行履歴） |
| `keycloak` | OIDC IdP（レルム・テストユーザーを自動 import） |
| `minio` | S3 互換オブジェクトストレージ（添付・音声） |
| `lawsy-api` / `lawsy-db` | 法令調査AI と専用 pgvector |
| `qerag-api` / `qerag-db` | クエリ拡張RAG と専用 pgvector |

---

## AIアプリのデータ投入

AIアプリはそれぞれ専用の pgvector を持ちます。起動後、検索対象データを投入してください（Python 3.12 前提）。

### 法令調査AI（lawsy）

[e-Gov 法令データ一括ダウンロード](https://laws.e-gov.go.jp/bulkdownload/) の「法令標準XML形式・全法令」ZIP を展開して投入します。

```bash
cd genai-ai-api/sakura/lawsy-custom/preprocess
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

export DATABASE_URL=postgresql://lawsy:lawsy@localhost:15434/lawsy
export SAKURA_AI_API_KEY=<さくらのAI Engine のトークン>

python3 load_laws.py /path/to/展開したXMLディレクトリ  # 条文を投入（数十分）
python3 build_embeddings.py                            # 法令名の埋め込みを計算（数分）
```

全法令で約 7,800 法令・25 万条文になります。データが無い／少ない場合、対象法令が見つからず回答できません。

### 社内文書検索RAG（qerag）

```bash
cd genai-ai-api/sakura/query-expansion-rag/preprocess
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

export DATABASE_URL=postgresql://qerag:qerag@localhost:15433/qerag
export SAKURA_AI_API_KEY=<さくらのAI Engine のトークン>

python3 ingest.py /path/to/documents   # .txt/.md/.csv/.html/.pdf を取り込む
```

タグや出典 URL を付与する場合は、対象ファイルと同じ場所に `<ファイル名>.metadata.json` を置きます（`{"metadataAttributes": {"tags": "keiri", "url": "https://..."}}`）。

---

## 使い方

- **チャット**: モデル（Kimi-K2.6 / Qwen3.6 / Qwen3-Coder）を選んでストリーミング会話。
- **AIアプリ**: 上部メニューのアプリ一覧から「法令調査AI」「社内文書検索RAG」を選んで実行。
- **チーム管理**: `dev-user` はシステム管理者。チーム作成 → メンバー追加（`dev-member` / `dev-password` を追加可能）→ チーム独自の AIアプリ登録ができる。
- **文字起こし**: 音声をアップロードして文字起こし（話者分離なし）。

## 運用

```bash
docker compose logs -f api      # ログ
docker compose down             # 停止（データは volume に保持）
docker compose down -v          # 停止 + データ削除（法令データ等も消える）
```

## 設計の詳細

各置き換えの設計判断（Lambda ハンドラのアダプタ方式、DynamoDB 単一テーブルの PostgreSQL 再現、ASL 回避のクリーンルーム実装、OIDC issuer の内外分離、ジョブキュー設計など）は [docs/design-notes.md](docs/design-notes.md) を参照してください。

## デモ公開向けの設定（任意）

いずれも**オプトイン**で、設定しなければ従来どおり動作します（開発ユーザー dev-user / dev-member には利用規約も表示されません）。

### GitHub ログイン（Keycloak Identity Brokering）

Keycloak が GitHub OAuth を仲介するため、コード変更なしで「GitHub でログイン」にできます。

1. GitHub で OAuth App を作成（callback: `{Keycloak}/realms/genai/broker/github/endpoint`）
2. `.env` に `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` を設定
3. `sh scripts/setup-github-idp.sh` で IdP を登録
4. `.env` に `OIDC_IDP_HINT=github` を設定して `docker compose up -d web` — ログインが GitHub 認可画面へ直行します

### 利用規約の表示（初回ログイン時に同意を必須化）

規約の文面はリポジトリにコミットせず、gitignore された `.local/` に置いて Keycloak へ投入します。

1. `docs/terms.example.html` を `.local/terms.ja.html` にコピーして編集（英語版は `.local/terms.en.html`）
2. `sh scripts/setup-terms.sh` で Keycloak に反映

新規ユーザー（GitHub ログイン含む）は初回ログイン時に規約への同意を求められます（同意日時が記録されます）。開発用 Keycloak は非永続のため、コンテナを作り直した場合は再実行してください。

### Brave Search の無効化

`.env` の `BRAVE_SEARCH_API_KEY` を空にすると、法令調査AI（lawsy）は Web 検索なし（条文 DB のみ）で動作します。

### ロゴ・コピーライトの差し替え

ヘッダー／フッターの「ここにロゴが入る」「ここにコピーライトが入る」は `.env` で差し替えられます。

```bash
SITE_TITLE=わたしの源内デモ          # ブラウザタブのタイトル
SITE_LOGO_TEXT=わたしの源内デモ      # ロゴのテキスト
SITE_COPYRIGHT_TEXT=© 2026 chibiegg # フッターのコピーライト
# 画像ロゴを使う場合（.local/branding/ はコミットされずに /branding/ で配信される）
SITE_LOGO_IMAGE_URL=/branding/logo.svg
```

画像ファイルは `.local/branding/`（gitignore 済み）に置き、`docker compose up -d web` で反映します。

## 本番運用に向けた補足

このリポジトリは**ローカル検証用**の構成です。本番では最低限:

- `USER_IDENTIFIER_HMAC_SECRET` / Keycloak 管理者パスワード / MinIO 認証情報を変更
- Keycloak を永続 DB（PostgreSQL）で運用し、`start-dev` をやめる
- フロントは Vite 開発サーバではなくビルド成果物を配信
- `EXAPP_ALLOW_PRIVATE_ENDPOINTS` を無効化（SSRF 保護を有効に保つ）
- TLS 終端・オリジン制限（CORS）を適切に設定

## ライセンス

本リポジトリ直下のファイル（Compose・スクリプト・ドキュメント）は MIT License です。submodule（genai-web / genai-ai-api）はそれぞれのリポジトリのライセンス（MIT。ただし genai-web の一部ファイルは Amazon Software License — 上記「ライセンス上の注意」参照）に従います。
