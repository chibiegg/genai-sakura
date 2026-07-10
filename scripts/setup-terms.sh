#!/bin/sh
# Keycloak の利用規約（初回ログイン時に同意を求める文面）を設定する。
#
# 文面はリポジトリにコミットせず、gitignore された .local/ 配下に置く:
#   .local/terms.ja.html  … 日本語の規約（必須）
#   .local/terms.en.html  … 英語の規約（任意）
# 雛形は docs/terms.example.html を参照。
#
# 実行: sh scripts/setup-terms.sh
#
# 注意: 開発用 Keycloak（H2）はコンテナ再作成で設定が消えるため、
#       keycloak を作り直した場合は再実行すること。

set -e

. ./.env 2>/dev/null || true

KEYCLOAK="${KEYCLOAK:-http://localhost:8180}"
REALM="${REALM:-genai}"
KC_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
TERMS_JA_FILE="${TERMS_JA_FILE:-.local/terms.ja.html}"
TERMS_EN_FILE="${TERMS_EN_FILE:-.local/terms.en.html}"

if [ ! -f "$TERMS_JA_FILE" ]; then
  echo "規約ファイルが見つかりません: $TERMS_JA_FILE" >&2
  echo "docs/terms.example.html を参考に作成してください。" >&2
  exit 1
fi

echo "==> Keycloak 管理トークンを取得..."
TOKEN=$(curl -s -X POST "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=$KC_ADMIN_USER&password=$KC_ADMIN_PASSWORD" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

if [ -z "$TOKEN" ]; then
  echo "管理トークンの取得に失敗しました。" >&2
  exit 1
fi

upload() {
  LOCALE="$1"
  FILE="$2"
  echo "==> termsText ($LOCALE) を設定: $FILE"
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "$KEYCLOAK/admin/realms/$REALM/localization/$LOCALE/termsText" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: text/plain; charset=utf-8' \
    --data-binary @"$FILE")
  if [ "$STATUS" != "204" ] && [ "$STATUS" != "200" ] && [ "$STATUS" != "201" ]; then
    echo "   設定に失敗しました (HTTP $STATUS)" >&2
    exit 1
  fi
  echo "   OK"
}

upload ja "$TERMS_JA_FILE"
if [ -f "$TERMS_EN_FILE" ]; then
  upload en "$TERMS_EN_FILE"
fi

echo "==> 完了。新規ユーザーの初回ログイン時に規約が表示されます。"
