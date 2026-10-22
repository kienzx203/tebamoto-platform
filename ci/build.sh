#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
ARM=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
A=(-sS -H "Authorization: Bearer $ARM")

curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  | jq -r '.value[]?|"\(.properties.roleDefinitionId)\t\(.properties.principalId)\t\(.properties.scope)"' > /tmp/ra.tsv

echo "########## ROLE ASSIGNMENTS (role | principalId | scope) ##########"
declare -A RN
for rid in $(cut -f1 /tmp/ra.tsv | sort -u); do
  RN["$rid"]=$(curl "${A[@]}" "https://management.azure.com$rid?api-version=2022-04-01" | jq -r '.properties.roleName')
done
while IFS=$'\t' read -r rid pid scope; do
  printf '%-32s | %s | %s\n' "${RN[$rid]}" "$pid" "${scope##*/providers/}"
done < /tmp/ra.tsv | sort
