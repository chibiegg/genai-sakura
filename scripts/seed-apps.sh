#!/bin/sh
# 共通アプリチームに lawsy / qerag を「公開済みAIアプリ」として登録する。
# docker compose up 後に一度だけ実行すればよい（DB は永続化されるため）。
#
# 使い方: sh scripts/seed-apps.sh
#
# 前提: web/api/keycloak が起動済み（http://localhost:3001, http://localhost:8180）

set -e

KEYCLOAK="${KEYCLOAK:-http://localhost:8180}"
API="${API:-http://localhost:3001}"
COMMON_TEAM_ID="00000000-0000-0000-0000-000000000000"

echo "==> Keycloak からトークンを取得..."
TOKEN=$(curl -s -X POST "$KEYCLOAK/realms/genai/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=genai-web&username=dev-user&password=dev-password&scope=openid' \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "トークンの取得に失敗しました。Keycloak が起動しているか確認してください。" >&2
  exit 1
fi

register() {
  NAME="$1"
  ENDPOINT="$2"
  DESC="$3"
  HOWTO="$4"
  PLACEHOLDER="$5"

  echo "==> 登録: $NAME ($ENDPOINT)"
  curl -s -X POST "$API/teams/$COMMON_TEAM_ID/exapps" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{
      \"exAppName\": \"$NAME\",
      \"endpoint\": \"$ENDPOINT\",
      \"placeholder\": $PLACEHOLDER,
      \"description\": \"$DESC\",
      \"howToUse\": \"$HOWTO\",
      \"apiKey\": \"\",
      \"status\": \"published\",
      \"copyable\": false
    }" > /dev/null && echo "   OK"
}

register \
  "法令調査AI（lawsy）" \
  "http://lawsy-api:8080/" \
  "最新の法令条文とWeb検索（Brave Search）を参照して、出典リンク付きの法令レポートを生成します。" \
  "質問を入力して実行してください。回答には e-Gov 法令検索への引用リンクが付きます。処理には1〜2分かかります。事前に法令データの投入が必要です（README 参照）。" \
  '"{\"input_text\": {\"type\": \"textarea\", \"title\": \"調べたい法令・制度に関する質問\", \"desc\": \"例: 個人情報保護法の要配慮個人情報とは？\", \"required\": true}}"'

register \
  "社内文書検索RAG（qerag）" \
  "http://qerag-api:8080/invoke" \
  "取り込んだ社内文書を検索し、クエリ拡張と関連度評価を経て回答を生成します。" \
  "質問を入力して実行してください。事前に文書の取り込みが必要です（README 参照）。" \
  '"{\"question\": {\"type\": \"textarea\", \"title\": \"質問\", \"desc\": \"例: 経費精算の締め日はいつですか？\", \"required\": true}}"'

echo "==> 完了。http://localhost:5173 のアプリ一覧に表示されます。"
