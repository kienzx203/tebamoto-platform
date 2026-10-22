#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RID="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$1" -d "client_secret=$2" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }
for s in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$s?api-version=7.4" | jq -r '.value')
  AID=$(echo "$J"|jq -r '.appId'); SEC=$(echo "$J"|jq -r '.clientSecret')
  T=$(spt "$AID" "$SEC")
  [ -z "$T" ] && { echo "$s: login fail"; continue; }
  R=$(curl -sS -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" "https://management.azure.com$RID/config/appsettings/list?api-version=2022-03-01")
  if echo "$R" | jq -e '.properties' >/dev/null 2>&1; then
    echo "### $s ($AID) CAN LIST APPSETTINGS ###"
    echo "$R" | jq -r '.properties | to_entries[] | "\(.key)=\(.value)"'
  else
    echo "$s: $(echo "$R" | jq -r '.error.code // "?"')"
  fi
done
echo DONE
exit 0
