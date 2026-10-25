#!/usr/bin/env bash
# Registra este host na tailnet (idempotente). Chamado pelo gitops-sync depois de
# um deploy saudável.
#
# - primary: roda o Headscale, então gera a própria chave. É o primeiro nó
#   registrado e recebe 100.64.0.1, o DNS da tailnet anunciado pelo Headscale.
# - demais papéis: restauram a identidade guardada em TAILSCALED_STATE_B64, nos
#   segredos do repositório (ADR 0014, `make secrets-capture-identity`). A VM
#   recriada volta como o mesmo nó, com o mesmo IP. Sem ela, usam TAILNET_AUTHKEY
#   (uso único, de `make tailnet-key`), o que cria um nó novo com outro IP.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/mgdn-platform/env
# Segredos decifrados pelo gitops-sync (ADR 0014); têm precedência sobre o env.
# shellcheck source=/dev/null
[[ ! -f /etc/mgdn-platform/secrets.env ]] || source /etc/mgdn-platform/secrets.env
# shellcheck source=/dev/null
source /opt/mgdn-platform/deploy/common/platform.env
user=platform
expected_ip=100.64.0.1

log() { echo "[tailnet] $*"; }

running() {
  tailscale status --json 2>/dev/null |
    python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)'
}

# Sem SNAT: por padrão o Tailscale aplica masquerade no tráfego da tailnet
# encaminhado para outra interface (aqui, a bridge do Docker), e o Blocky veria
# todo cliente como o gateway da bridge. Este host não é subnet router.
no_snat() { tailscale set --snat-subnet-routes=false; }

if running; then
  no_snat
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

# Estado restaurado do backup (VM recriada): o nó reconecta sozinho com a mesma
# identidade assim que o Headscale responde. Registrar de novo criaria um nó
# duplicado com outro IP.
for _ in $(seq 1 12); do
  running && {
    no_snat
    log "reconectado com o estado existente ($(tailscale ip -4))"
    exit 0
  }
  sleep 5
done

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
elif [[ -n "${TAILSCALED_STATE_B64:-}" ]]; then
  systemctl stop tailscaled
  base64 -d <<<"$TAILSCALED_STATE_B64" | install -D -m 0600 /dev/stdin /var/lib/tailscale/tailscaled.state
  systemctl start tailscaled
  for _ in $(seq 1 24); do
    running && {
      no_snat
      log "identidade restaurada dos segredos ($(tailscale ip -4))"
      exit 0
    }
    sleep 5
  done
  log "identidade restaurada, mas o nó não conectou; confira 'tailscale status'"
  exit 1
else
  key="${TAILNET_AUTHKEY:-}"
  if [[ -z "$key" ]]; then
    log "sem identidade nem TAILNET_AUTHKEY; host fora da tailnet (veja 'Recriar a secundária' no README)"
    exit 0
  fi
fi

tailscale up --reset --login-server "https://$HEADSCALE_HOSTNAME" --authkey "$key" \
  --hostname "$(hostname)" --accept-dns=false --snat-subnet-routes=false

ip=$(tailscale ip -4)
log "registrado como $(hostname) ($ip)"
if [[ "$ROLE" == "primary" && "$ip" != "$expected_ip" ]]; then
  log "AVISO: esperado $expected_ip (DNS da tailnet no Headscale); ajuste dns.nameservers.global"
fi
