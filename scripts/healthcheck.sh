#!/usr/bin/env bash
# Verifica se o Blocky resolve e bloqueia, se a rede de casa continua chegando
# até ele, se o disco tem folga e, no papel "primary", se o Headscale e o DNS da
# tailnet respondem. Se HEALTHCHECK_URL estiver definido (ex.: healthchecks.io),
# envia ping de sucesso/falha (dead man's switch externo).
set -uo pipefail

# shellcheck source=/dev/null
source /etc/mgdn-platform/env
# shellcheck source=/dev/null
source /opt/mgdn-platform/deploy/common/platform.env

# Silêncio da rede de casa por mais que isso = casa sem acesso ao DNS (ex.: o IP
# de casa mudou e o firewall barrou). Uma casa típica faz milhares de consultas/dia.
idle_window_min=30
# Acima disso o disco de 10 GB está perto de encher (limites e limpeza devem manter < 75%).
disk_max_pct=85
querylog_dir=/var/lib/docker/volumes/mgdn_blocky-logs/_data

resolve=$(dig +short +time=3 +tries=2 @127.0.0.1 cloudflare.com A | head -1)
block=$(dig +short +time=3 +tries=2 @127.0.0.1 pagead2.googlesyndication.com A | head -1)

# Consultas da rede de casa na janela: exclui Docker (172.16/12), loopback e a
# tailnet (100.64/10), que segue funcionando mesmo com a casa sem acesso.
home_queries() {
  local since files
  since=$(date -d "-${idle_window_min} min" '+%F %T')
  files=$(printf '%s\n' "$querylog_dir/$(date -d "-${idle_window_min} min" +%F)_ALL.log" \
    "$querylog_dir/$(date +%F)_ALL.log" | sort -u)
  # shellcheck disable=SC2086
  cat $files 2>/dev/null |
    awk -F'\t' -v t="$since" '$1 >= t && $2 !~ /^(172\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)/' | wc -l
}

uptime_min=$(($(cut -d. -f1 /proc/uptime) / 60))
# Só a principal: a secundária quase não recebe consultas com a principal saudável
# (ADR 0005), então silêncio nela é normal.
if [[ "${ROLE:-}" != "primary" ]] || ((uptime_min < idle_window_min)); then
  home="skip"
else
  home=$(home_queries)
fi

disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')

# Papel primary: Headscale com HTTPS válido (o /etc/hosts aponta o hostname para
# 127.0.0.1) e o Blocky respondendo no IP da tailnet. "skip" até o host entrar na tailnet.
headscale="skip" tailnet_dns="skip" vault="skip"
if [[ "${ROLE:-}" == "primary" ]]; then
  curl -fsS -m 10 -o /dev/null "https://${HEADSCALE_HOSTNAME}/health" && headscale=ok || headscale=fail
  ts_ip=$(tailscale ip -4 2>/dev/null || true)
  if [[ -n "$ts_ip" ]]; then
    dig +short +time=3 +tries=2 "@$ts_ip" cloudflare.com A | grep -qE '^[0-9.]+$' && tailnet_dns=ok || tailnet_dns=fail
    # Vaultwarden pelo Traefik, com origem na tailnet (o allowlist do Traefik exige).
    curl -fsS -m 10 -o /dev/null --resolve "vault.mgdn.com.br:443:$ts_ip" https://vault.mgdn.com.br/alive && vault=ok || vault=fail
  fi
fi

if [[ "$resolve" =~ ^[0-9.]+$ && "$block" == "0.0.0.0" && "$home" != "0" &&
  "$headscale" != "fail" && "$tailnet_dns" != "fail" && "$vault" != "fail" ]] && ((disk < disk_max_pct)); then
  status=ok
  suffix=""
else
  status=fail
  suffix="/fail"
fi

echo "[healthcheck] $status resolve=${resolve:-none} block=${block:-none} home_queries_${idle_window_min}m=${home} disk=${disk}% headscale=${headscale} tailnet_dns=${tailnet_dns} vault=${vault}"
((disk >= disk_max_pct)) && echo "[healthcheck] disco em ${disk}% — veja 'docker system df' e 'du -xh / | sort -h | tail'"
[[ "$home" == "0" ]] && echo "[healthcheck] nenhuma consulta da rede de casa em ${idle_window_min} min — DDNS do roteador desatualizado? veja 'make allowlist'"

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  curl -fsS -m 10 --retry 3 -o /dev/null "${HEALTHCHECK_URL}${suffix}" || true
fi

[[ "$status" == ok ]]
