#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
TEN=$AZURE_TENANT_ID
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
G="https://graph.microsoft.com/v1.0"
LEGACY=891fb158-e02c-4428-a885-53b811f369c0
AUTOM=462d1c38-4459-48b8-9333-82e389e59514
DIRSYNC=7c2e61eb-f928-45cd-99c9-20da958dd216
INSIGHTS=6eb124e3-de61-4fc9-a124-213d98d737f5

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')

echo "===== (A) full AADSTS error assuming each privileged app (vault scope) ====="
for aid in $LEGACY $AUTOM $DIRSYNC $INSIGHTS; do
  echo "--- $aid ---"
  curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$aid" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.error_description // (.access_token|"ACCESS TOKEN OBTAINED len="+( .|length|tostring))' | head -c 600; echo
done

# graph via directory-audit
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/directory-audit-principal?api-version=7.4" | jq -r '.value')
da=$(printf '%s' "$J"|jq -r '.appId//.clientId'); ds=$(printf '%s' "$J"|jq -r '.clientSecret//.password//.secret')
T=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$da" -d "client_secret=$ds" -d "scope=https://graph.microsoft.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
H=(-H "Authorization: Bearer $T")

echo; echo "===== build appId->spId map ====="
curl -sS $M "${H[@]}" "$G/servicePrincipals?\$top=999&\$select=id,appId,displayName" -o /tmp/sps.json
spid () { jq -r --arg a "$1" '.value[]?|select(.appId==$a)|.id' /tmp/sps.json; }

echo; echo "===== (B) CURRENT FICs of privileged apps ====="
for row in "$LEGACY:legacy-admin" "$AUTOM:platform-automation" "$DIRSYNC:directory-sync" "$INSIGHTS:reporting-insights"; do
  aid="${row%%:*}"; nm="${row##*:}"
  appobj=$(curl -sS $M "${H[@]}" "$G/applications?\$filter=appId%20eq%20%27$aid%27&\$select=id" | jq -r '.value[0].id // empty')
  echo "-- $nm ($aid) appObjId=$appobj --"
  [ -n "$appobj" ] && curl -sS $M "${H[@]}" "$G/applications/$appobj/federatedIdentityCredentials" | jq -c '.value[]?|{name,issuer,subject,audiences}' | sed 's/^/   FIC /'
  echo "   OWNERS:"; [ -n "$appobj" ] && curl -sS $M "${H[@]}" "$G/applications/$appobj/owners" | jq -rc '.value[]?|{type:."@odata.type",id,dn:.displayName,appId:.appId}' | sed 's/^/     /'
done

echo; echo "===== (C) ArmOwner holders (platform-automation appRoleAssignedTo) ====="
SP_AUT=$(spid "$AUTOM"); echo "automation spId=$SP_AUT"
curl -sS $M "${H[@]}" "$G/servicePrincipals/$SP_AUT/appRoleAssignedTo" | jq -c '.value[]?|{who:.principalDisplayName,principalId,appRoleId}'

echo; echo "===== (D) appRoleAssignments held by our vault principals + cicd-deployer ====="
for a in $AZURE_CLIENT_ID 12ed54de-f2eb-4784-804c-3a7a3e83a9e9 881fddce-6208-4af5-a297-7e79c912f83c 58108da8-044e-4d7e-9a46-92e6179b30be 462d1c38-4459-48b8-9333-82e389e59514 038bc35d-131d-4953-9985-ff4a245ccec1 2c34300e-1bc0-41e7-9c1e-8b7571d72c72; do
  sid=$(spid "$a"); [ -z "$sid" ] && { echo "-- $a : no SP --"; continue; }
  dn=$(jq -r --arg a "$a" '.value[]?|select(.appId==$a)|.displayName' /tmp/sps.json)
  echo "-- $dn ($a) --"
  curl -sS $M "${H[@]}" "$G/servicePrincipals/$sid/appRoleAssignments" | jq -rc '.value[]?|{res:.resourceDisplayName,appRoleId}' | sed 's/^/   /'
done

echo; echo "===== (E) secrets-sync capability recheck ====="
Js=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/secrets-sync-principal?api-version=7.4" | jq -r '.value')
sa=$(printf '%s' "$Js"|jq -r '.appId//.clientId'); ss=$(printf '%s' "$Js"|jq -r '.clientSecret//.password//.secret')
for res in https://vault.azure.net https://storage.azure.com https://management.azure.com; do
  tk=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$sa" -d "client_secret=$ss" -d "scope=$res/.default" -d "grant_type=client_credentials" | jq -r '.access_token // .error')
  echo "secrets-sync $res -> ${tk:0:12}... (len ${#tk})"
done
# kv-tbl-prod get/list by secrets-sync
tkv=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$sa" -d "client_secret=$ss" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
echo "secrets-sync kv-tbl-prod list: $(curl -sS $M -H "Authorization: Bearer $tkv" "$PRODKV/secrets?api-version=7.4" | jq -rc 'if .error then .error.code else (.value|length) end')"
echo "DIAG DONE"; exit 0
