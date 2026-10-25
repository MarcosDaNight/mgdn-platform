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
metrics_dir=/var/lib/mgdn-platform/metrics

# Última vez que cada aparelho apareceu na tailnet, para o alerta TailnetNodeStale.
# Aparelho online conta como visto agora. Gravação atômica lida pelo node-exporter.
tailnet_metrics() {
  local container
  container=$(docker ps -q --filter label=com.docker.compose.service=headscale)
  [[ -n "$container" ]] || return 0
  mkdir -p "$metrics_dir"
  docker exec "$container" headscale nodes list -o json | python3 -c '
import json, sys, time
from datetime import datetime
now = time.time()
print("# HELP mgdn_tailnet_node_last_seen_timestamp_seconds Última vez que o aparelho apareceu na tailnet.")
print("# TYPE mgdn_tailnet_node_last_seen_timestamp_seconds gauge")
for n in json.load(sys.stdin) or []:
    seen = n.get("last_seen") or {}
    if isinstance(seen, dict):
        ts = float(seen.get("seconds", 0))
    else:
        ts = datetime.fromisoformat(seen.replace("Z", "+00:00")).timestamp()
    if n.get("online"):
        ts = now
    user = (n.get("user") or {}).get("name", "")
    print("mgdn_tailnet_node_last_seen_timestamp_seconds{node=\"%s\",user=\"%s\"} %d" % (n["given_name"], user, ts))
' >"$metrics_dir/.mgdn_tailnet.prom" && mv "$metrics_dir/.mgdn_tailnet.prom" "$metrics_dir/mgdn_tailnet.prom"
}

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
# 127.0.0.1), o Blocky respondendo no IP da tailnet e cada app com o label mgdn.url
# (ADR 0015) saudável pelo Traefik. "skip" até o host entrar na tailnet.
headscale="skip" tailnet_dns="skip" apps="skip" apps_ok=true
if [[ "${ROLE:-}" == "primary" ]]; then
  tailnet_metrics || echo "[healthcheck] AVISO: métricas da tailnet não foram atualizadas"
  curl -fsS -m 10 -o /dev/null "https://${HEADSCALE_HOSTNAME}/health" && headscale=ok || headscale=fail
  ts_ip=$(tailscale ip -4 2>/dev/null || true)
  if [[ -n "$ts_ip" ]]; then
    dig +short +time=3 +tries=2 "@$ts_ip" cloudflare.com A | grep -qE '^[0-9.]+$' && tailnet_dns=ok || tailnet_dns=fail
    # Pelo Traefik, com origem na tailnet (o allowlist do Traefik exige).
    apps=""
    while IFS=$'\t' read -r svc url health; do
      host=${url#https://}
      if curl -fsS -m 10 -o /dev/null --resolve "$host:443:$ts_ip" "$url$health"; then
        apps+="$svc:ok,"
      else
        apps+="$svc:fail,"
        apps_ok=false
      fi
    done < <(python3 /opt/mgdn-platform/scripts/apps.py http)
    apps=${apps%,}
    # Sem nenhum app listado, o apps.py falhou (ex.: docker compose config).
    [[ -n "$apps" ]] || {
      apps="erro"
      apps_ok=false
    }
  fi
fi

if [[ "$resolve" =~ ^[0-9.]+$ && "$block" == "0.0.0.0" && "$home" != "0" &&
  "$headscale" != "fail" && "$tailnet_dns" != "fail" ]] && $apps_ok && ((disk < disk_max_pct)); then
  status=ok
  suffix=""
else
  status=fail
  suffix="/fail"
fi

echo "[healthcheck] $status resolve=${resolve:-none} block=${block:-none} home_queries_${idle_window_min}m=${home} disk=${disk}% headscale=${headscale} tailnet_dns=${tailnet_dns} apps=${apps:-none}"
((disk >= disk_max_pct)) && echo "[healthcheck] disco em ${disk}% — veja 'docker system df' e 'du -xh / | sort -h | tail'"
[[ "$home" == "0" ]] && echo "[healthcheck] nenhuma consulta da rede de casa em ${idle_window_min} min — DDNS do roteador desatualizado? veja 'make allowlist'"

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  curl -fsS -m 10 --retry 3 -o /dev/null "${HEALTHCHECK_URL}${suffix}" || true
fi

[[ "$status" == ok ]]
