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

RD=$(curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01")

echo "########## ROLE ASSIGNMENTS (role | principalId | scope) ##########"
curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
 | jq --argjson rd "$RD" -r '
   ($rd.value|map({(.name):.properties.roleName})|add) as $m
   | .value[]? | "\($m[(.properties.roleDefinitionId|split("/")|last)] // (.properties.roleDefinitionId|split("/")|last))\t\(.properties.principalId)\t\(.properties.scope)"' \
 | sort

RES=$(curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01")
echo "########## kv-tbl-sec: rbac flag + accessPolicies ##########"
VID=$(echo "$RES" | jq -r '.value[]|select(.name=="kv-tbl-sec-x3euoz")|.id')
curl "${A[@]}" "https://management.azure.com$VID?api-version=2022-07-01" \
 | jq '.properties | {enableRbacAuthorization, accessPolicies:[.accessPolicies[]?|{objectId,secrets:.permissions.secrets}]}'

echo "########## app-tbl-storefront-prod identity ##########"
SID=$(echo "$RES" | jq -r '.value[]|select(.name=="app-tbl-storefront-prod")|.id')
curl "${A[@]}" "https://management.azure.com$SID?api-version=2022-03-01" | jq '.identity'
