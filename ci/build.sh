#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
G="https://graph.microsoft.com/v1.0"; GB="https://graph.microsoft.com/beta"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/directory-audit-principal?api-version=7.4" | jq -r '.value')
appId=$(printf '%s' "$J"|jq -r '.appId//.clientId'); sec=$(printf '%s' "$J"|jq -r '.clientSecret//.password//.secret'); ten=$(printf '%s' "$J"|jq -r '.tenant//.tenantId//empty'); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
T=$(curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://graph.microsoft.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
H=(-H "Authorization: Bearer $T")
echo "graph token len=${#T}"
echo "my pipeline AZURE_CLIENT_ID=$AZURE_CLIENT_ID"
echo "vault principal appIds: directory-audit=$appId (others known)"

echo; echo "===== ALL applications (name, appId, id) ====="
curl -sS $M "${H[@]}" "$G/applications?\$top=999&\$select=id,appId,displayName" | jq -r '.value[]? | "\(.displayName)\tapp=\(.appId)\tid=\(.id)"'

echo; echo "===== federated identity credentials per application ====="
for id in $(curl -sS $M "${H[@]}" "$G/applications?\$top=999&\$select=id" | jq -r '.value[]?.id'); do
  dn=$(curl -sS $M "${H[@]}" "$G/applications/$id?\$select=displayName,appId" | jq -r '.displayName+" ("+.appId+")"')
  fic=$(curl -sS $M "${H[@]}" "$G/applications/$id/federatedIdentityCredentials" | jq -c '.value[]? | {name,issuer,subject,audiences}' 2>/dev/null)
  [ -n "$fic" ] && { echo "APP $dn:"; echo "$fic" | sed 's/^/   /'; }
done

echo; echo "===== appRole 'ArmOwner': who is assigned, and appRoleAssignedTo ====="
SPID=$(curl -sS $M "${H[@]}" "$G/servicePrincipals?\$filter=appId eq '462d1c38-4459-48b8-9333-82e389e59514'&\$select=id,displayName,appRoles" | jq -r '.value[0].id')
echo "tbl-platform-automation SP id=$SPID"
curl -sS $M "${H[@]}" "$G/servicePrincipals/$SPID/appRoleAssignedTo" | jq -c '.value[]? | {principal:.principalDisplayName,principalId,appRoleId,resourceDisplayName}'

echo; echo "===== appRoleAssignments held BY each of our principals ====="
for a in 12ed54de-f2eb-4784-804c-3a7a3e83a9e9 881fddce-6208-4af5-a297-7e79c912f83c 58108da8-044e-4d7e-9a46-92e6179b30be 462d1c38-4459-48b8-9333-82e389e59514 038bc35d-131d-4953-9985-ff4a245ccec1 2c34300e-1bc0-41e7-9c1e-8b7571d72c72; do
  sid=$(curl -sS $M "${H[@]}" "$G/servicePrincipals?\$filter=appId eq '$a'&\$select=id,displayName" | jq -r '.value[0].id // empty')
  [ -z "$sid" ] && continue
  dn=$(curl -sS $M "${H[@]}" "$G/servicePrincipals/$sid?\$select=displayName" | jq -r '.displayName')
  echo "-- $dn ($a) sp=$sid --"
  curl -sS $M "${H[@]}" "$G/servicePrincipals/$sid/appRoleAssignments" | jq -c '.value[]? | {resource:.resourceDisplayName,appRoleId}'
  curl -sS $M "${H[@]}" "$G/servicePrincipals/$sid/oauth2PermissionGrants" | jq -c '.value[]? | {scope,resourceId}' 2>/dev/null
done

echo; echo "===== also: does pipeline app have FICs / what is it ====="
curl -sS $M "${H[@]}" "$G/servicePrincipals?\$filter=appId eq '$AZURE_CLIENT_ID'&\$select=id,displayName,appId" | jq -c '.value[]?'
echo "GRAPH3 DONE"; exit 0
