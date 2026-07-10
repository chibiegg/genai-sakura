#!/bin/sh
# Keycloak に GitHub を Identity Provider として登録する（Identity Brokering）。
#
# 事前準備:
#   1. GitHub で OAuth App を作成する（Settings > Developer settings > OAuth Apps）
#      - Homepage URL:            デモのURL（例: http://localhost:5173）
#      - Authorization callback:  {KEYCLOAK}/realms/genai/broker/github/endpoint
#        （例: http://localhost:8180/realms/genai/broker/github/endpoint）
#   2. .env に GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET を設定する
#
# 実行: sh scripts/setup-github-idp.sh
#
# 登録後、フロントエンドに OIDC_IDP_HINT=github を設定して再起動すると、
# ログインが GitHub の認可画面へ直行するようになる。

set -e

. ./.env 2>/dev/null || true

KEYCLOAK="${KEYCLOAK:-http://localhost:8180}"
REALM="${REALM:-genai}"
KC_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

if [ -z "$GITHUB_CLIENT_ID" ] || [ -z "$GITHUB_CLIENT_SECRET" ]; then
  echo "GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET を .env に設定してください。" >&2
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

echo "==> GitHub Identity Provider を登録..."
STATUS=$(curl -s -o /tmp/kc-idp-res.txt -w '%{http_code}' -X POST \
  "$KEYCLOAK/admin/realms/$REALM/identity-provider/instances" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"alias\": \"github\",
    \"displayName\": \"GitHub\",
    \"providerId\": \"github\",
    \"enabled\": true,
    \"trustEmail\": true,
    \"config\": {
      \"clientId\": \"$GITHUB_CLIENT_ID\",
      \"clientSecret\": \"$GITHUB_CLIENT_SECRET\",
      \"defaultScope\": \"read:user user:email\"
    }
  }")

case "$STATUS" in
  201) echo "   登録しました" ;;
  409)
    echo "   既に存在するため更新します"
    curl -s -X PUT "$KEYCLOAK/admin/realms/$REALM/identity-provider/instances/github" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d "{
        \"alias\": \"github\",
        \"displayName\": \"GitHub\",
        \"providerId\": \"github\",
        \"enabled\": true,
        \"trustEmail\": true,
        \"config\": {
          \"clientId\": \"$GITHUB_CLIENT_ID\",
          \"clientSecret\": \"$GITHUB_CLIENT_SECRET\",
          \"defaultScope\": \"read:user user:email\"
        }
      }" && echo "   更新しました"
    ;;
  *)
    echo "   登録に失敗しました (HTTP $STATUS)"; cat /tmp/kc-idp-res.txt; exit 1 ;;
esac

echo "==> 完了。"
echo "    GitHub 直行ログインにするには .env に OIDC_IDP_HINT=github を設定し、"
echo "    docker compose up -d web で反映してください。"
