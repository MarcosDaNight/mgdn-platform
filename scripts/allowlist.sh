#!/usr/bin/env bash
# Allowlist de origem da VM: só o IP atual de casa (via DDNS) e os CIDRs extras
# podem falar com o DNS (53) e o SSH (22). O Security Group deixa essas portas
# abertas; quem filtra é esta tabela nftables, recriada a cada execução numa única
# transação (sem janela aberta). Executado no boot (antes do Docker) e pelo
# mgdn-allowlist.timer a cada 2 min.
#
# Falha fechada: sem nenhuma origem conhecida, ninguém passa. Se o DDNS não
# resolver, mantém o último IP válido.
set -euo pipefail

# shellcheck source=/dev/null
source /etc/mgdn-platform/env
# Segredos decifrados pelo gitops-sync (ADR 0014); têm precedência sobre o env.
# shellcheck source=/dev/null
[[ ! -f /etc/mgdn-platform/secrets.env ]] || source /etc/mgdn-platform/secrets.env
state=/var/lib/mgdn-platform/home_ip
mkdir -p "${state%/*}"

log() { echo "[allowlist] $*"; }

if [[ -z "${HOME_DDNS_HOST:-}" && -z "${EXTRA_ALLOWED_CIDRS:-}" ]]; then
  log "HOME_DDNS_HOST não configurado; allowlist do host desativado"
  exit 0
fi

is_public_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    [[ ! "$1" =~ ^(0|10|127)\.|^169\.254\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

previous=$(cat "$state" 2>/dev/null || true)
if [[ -n "${HOME_DDNS_HOST:-}" ]]; then
  # Direto no 1.1.1.1: evita cache do resolvedor da VM e respeita o TTL curto do DDNS.
  resolved=$(dig +short +time=3 +tries=2 A "$HOME_DDNS_HOST" @1.1.1.1 | tail -1 || true)
  if is_public_ipv4 "$resolved"; then
    if [[ "$resolved" != "$previous" ]]; then
      log "IP de casa: ${previous:-<nenhum>} -> $resolved"
      echo "$resolved" >"$state"
    fi
  else
    log "AVISO: $HOME_DDNS_HOST não resolveu para um IPv4 público ('${resolved}'); mantendo ${previous:-<nenhum>}"
  fi
fi

home_ip=$(cat "$state" 2>/dev/null || true)
extra=${EXTRA_ALLOWED_CIDRS:-}
elements=$(echo "$home_ip ${extra//,/ }" | xargs | tr ' ' ',')
iface=$(ip route show default | awk '{print $5; exit}')

nft -f - <<EOF
table inet mgdn_allowlist
delete table inet mgdn_allowlist
table inet mgdn_allowlist {
  set allowed {
    type ipv4_addr
    flags interval
    ${elements:+elements = { $elements }}
  }
  # SSH e DNS atendidos direto pelo host (docker-proxy). Métricas (4000 Blocky,
  # 9093 Alertmanager, 9100 node-exporter) nunca pela interface pública: só tailnet.
  chain input {
    type filter hook input priority filter - 10; policy accept;
    iifname "$iface" meta l4proto { tcp, udp } th dport { 22, 53 } ip saddr != @allowed drop
    iifname "$iface" tcp dport { 4000, 9093, 9100 } drop
  }
  # Portas publicadas pelo Docker (após o DNAT)
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    iifname "$iface" meta l4proto { tcp, udp } th dport 53 ip saddr != @allowed drop
    iifname "$iface" tcp dport { 4000, 9093, 9100 } drop
  }
}
EOF

[[ -z "$elements" ]] && log "AVISO: nenhuma origem conhecida — DNS e SSH bloqueados para todos (falha fechada)"
exit 0
