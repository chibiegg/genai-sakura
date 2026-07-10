#!/bin/sh
# 公開ドメインで運用する際に、Keycloak クライアント（genai-web）の
# リダイレクト URI / Web Origins に PUBLIC_WEB_ORIGIN を追加する。
#
# 使い方: PUBLIC_WEB_ORIGIN=https://example.com sh scripts/setup-client-urls.sh
# （.env に PUBLIC_WEB_ORIGIN があればそれを使う）

set -e

. ./.env 2>/dev/null || true

KEYCLOAK="${KEYCLOAK:-http://localhost:8180}"
REALM="${REALM:-genai}"
KC_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

if [ -z "$PUBLIC_WEB_ORIGIN" ]; then
  echo "PUBLIC_WEB_ORIGIN が未設定です（例: https://elekitel-demo.example.com）" >&2
  exit 1
fi

echo "==> Keycloak 管理トークンを取得..."
TOKEN=$(curl -s -X POST "$KEYCLOAK/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=$KC_ADMIN_USER&password=$KC_ADMIN_PASSWORD" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

CLIENT_UUID=$(curl -s "$KEYCLOAK/admin/realms/$REALM/clients?clientId=genai-web" \
  -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')

echo "==> genai-web クライアントに $PUBLIC_WEB_ORIGIN を追加..."
curl -s "$KEYCLOAK/admin/realms/$REALM/clients/$CLIENT_UUID" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, json
c = json.load(sys.stdin)
origin = '$PUBLIC_WEB_ORIGIN'.rstrip('/')
for uri in [origin + '/*']:
    if uri not in c['redirectUris']:
        c['redirectUris'].append(uri)
if origin not in c.get('webOrigins', []):
    c.setdefault('webOrigins', []).append(origin)
attrs = c.setdefault('attributes', {})
logout = attrs.get('post.logout.redirect.uris', '')
if origin + '/*' not in logout.split('##'):
    attrs['post.logout.redirect.uris'] = (logout + '##' if logout else '') + origin + '/*'
print(json.dumps(c))
" > /tmp/kc-client.json

STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
  "$KEYCLOAK/admin/realms/$REALM/clients/$CLIENT_UUID" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @/tmp/kc-client.json)

if [ "$STATUS" != "204" ]; then
  echo "更新に失敗しました (HTTP $STATUS)" >&2
  exit 1
fi
echo "==> 完了"
