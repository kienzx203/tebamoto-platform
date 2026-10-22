#!/usr/bin/env bash
set -euo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RG=rg-tbl-reporting-prod-eus
APP=app-tbl-reporting-prod
WAPI=2022-03-01

OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
ARM=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
[ -z "$ARM" ] && { echo "no ARM token"; exit 1; }
A=(-sS -H "Authorization: Bearer $ARM")

echo "== SUBSCRIPTIONS =="
curl "${A[@]}" "https://management.azure.com/subscriptions?api-version=2020-01-01" | jq -r '.value[]? | "\(.subscriptionId) \(.displayName)"'

echo "== ALL RESOURCES (ca sub) =="
curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01" | jq -r '.value[]? | "\(.type)\t\(.name)"'

echo "== APP SETTINGS cua reporting app =="
curl "${A[@]}" -X POST -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/appsettings/list?api-version=$WAPI"
echo
echo "== PUBLISHING CREDS (Kudu) cua reporting app =="
curl "${A[@]}" -X POST -H "Content-Length: 0" \
  "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/$APP/config/publishingcredentials/list?api-version=$WAPI" \
  | jq '{user:.properties.publishingUserName, pass:.properties.publishingPassword, scm:.properties.scmUri}'
