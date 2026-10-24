#!/usr/bin/env bash
# Registra este host na tailnet (idempotente). Chamado pelo gitops-sync depois de
# um deploy saudável.
#
# - primary: roda o Headscale, então gera a própria chave. É o primeiro nó
#   registrado e recebe 100.64.0.1, o DNS da tailnet anunciado pelo Headscale.
# - demais papéis: usam TAILNET_AUTHKEY (uso único, de `make tailnet-key`),
#   entregue pelo cloud-init. Depois de registrado, a chave não é mais lida.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/mgdn-platform/env
user=platform
expected_ip=100.64.0.1

log() { echo "[tailnet] $*"; }

if tailscale status --json 2>/dev/null |
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)'; then
  exit 0
fi

# O certificado Let's Encrypt sai no primeiro acesso HTTPS; espera ficar válido.
# O /etc/hosts aponta o hostname para 127.0.0.1 (sem depender de hairpin NAT).
for _ in $(seq 1 30); do
  curl -fsS -m 5 "https://$HEADSCALE_HOSTNAME/health" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS -m 5 "https://$HEADSCALE_HOSTNAME/health" >/dev/null || {
  log "headscale sem HTTPS válido em https://$HEADSCALE_HOSTNAME"
  exit 1
}

if [[ "$ROLE" == "primary" ]]; then
  container=$(docker ps -q --filter label=com.docker.compose.service=headscale)
  [[ -n "$container" ]] || {
    log "container do headscale não está rodando"
    exit 1
  }
  hs() { docker exec "$container" headscale "$@"; }
  user_id() { hs users list -n "$user" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")'; }
  uid=$(user_id)
  if [[ -z "$uid" ]]; then
    hs users create "$user" >/dev/null
    uid=$(user_id)
  fi
  key=$(hs preauthkeys create --user "$uid" --expiration 10m -o json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
else
  key="${TAILNET_AUTHKEY:-}"
  if [[ -z "$key" ]]; then
    log "TAILNET_AUTHKEY vazio; host fora da tailnet (gere com make tailnet-key e recrie a VM)"
    exit 0
  fi
fi

tailscale up --reset --login-server "https://$HEADSCALE_HOSTNAME" --authkey "$key" \
  --hostname "$(hostname)" --accept-dns=false

ip=$(tailscale ip -4)
log "registrado como $(hostname) ($ip)"
if [[ "$ROLE" == "primary" && "$ip" != "$expected_ip" ]]; then
  log "AVISO: esperado $expected_ip (DNS da tailnet no Headscale); ajuste dns.nameservers.global"
fi
