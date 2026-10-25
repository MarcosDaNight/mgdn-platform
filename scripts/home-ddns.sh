#!/usr/bin/env bash
# DDNS de casa pela Cloudflare, opcional: substitui o hostname do No-IP, que expira se
# não for confirmado a cada 30 dias. Roda num computador sempre ligado em casa, pelo
# timer de usuário deploy/home/mgdn-home-ddns.timer, e mantém um registro A em
# mgdn.com.br com o IP público atual. As VMs leem esse nome em HOME_DDNS_HOST.
#
# Configuração em ~/.config/mgdn-platform/home-ddns.env (0600):
#   CF_API_TOKEN=...   token com DNS:Edit só na zona mgdn.com.br (não o do Terraform)
#   CF_ZONE_ID=7f69f8be82de025264eaff4739e70f66
#   DDNS_NAME=<nome-difícil-de-adivinhar>.mgdn.com.br
set -euo pipefail

env_file=${HOME_DDNS_ENV:-$HOME/.config/mgdn-platform/home-ddns.env}
# shellcheck source=/dev/null
source "$env_file"
: "${CF_API_TOKEN:?}" "${CF_ZONE_ID:?}" "${DDNS_NAME:?}"

log() { echo "[home-ddns] $*"; }

ip=$(curl -fsS -4 -m 10 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')
[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  log "não consegui descobrir o IP público (resposta: ${ip:-vazia})"
  exit 1
}

api() {
  curl -fsS -m 20 -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"
}
base="https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records"

read -r id current < <(api "$base?type=A&name=$DDNS_NAME" | python3 -c '
import json, sys
r = (json.load(sys.stdin).get("result") or [{}])[0]
print(r.get("id", "-"), r.get("content", "-"))
')

if [[ "$current" == "$ip" ]]; then
  exit 0
fi

body=$(printf '{"type":"A","name":"%s","content":"%s","ttl":60,"proxied":false,"comment":"DDNS de casa (mgdn-platform, scripts/home-ddns.sh)"}' "$DDNS_NAME" "$ip")
if [[ "$id" == "-" ]]; then
  api -X POST "$base" --data "$body" >/dev/null
  log "$DDNS_NAME criado: $ip"
else
  api -X PUT "$base/$id" --data "$body" >/dev/null
  log "$DDNS_NAME: $current -> $ip"
fi
