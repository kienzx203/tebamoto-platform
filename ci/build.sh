#!/usr/bin/env bash
set -uo pipefail
M="--max-time 25 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
ARM=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
A=(-sS $M -H "Authorization: Bearer $ARM")
rolename(){ curl "${A[@]}" "https://management.azure.com$1?api-version=2022-04-01" | jq -r '.properties.roleName'; }
for pid in "f64d08c7-fde6-4553-99c8-5bf73666ee8c:UAMI-reporting-writer" \
           "eeab432e-1bf6-400e-b155-a28ce7cafcdb:SIP-storefront" \
           "63e87ab1-6bd2-4e80-92be-943450b20e4f:pipeline-SP"; do
  oid=${pid%%:*}; who=${pid#*:}
  echo "########## $who ($oid) ##########"
  curl "${A[@]}" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$oid'" \
    | jq -r '.value[]?|"\(.properties.roleDefinitionId)\t\(.properties.scope)"' > /tmp/ra.tsv
  if [ ! -s /tmp/ra.tsv ]; then echo "  (khong thay role nao / khong doc duoc)"; continue; fi
  while IFS=$'\t' read -r rid scope; do
    rn=$(rolename "$rid")
    printf '  %-32s | %s\n' "$rn" "${scope##*/providers/}"
  done < /tmp/ra.tsv
done
echo DONE; exit 0
