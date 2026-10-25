#!/usr/bin/env bash
# Reconcilia a VM com o estado declarado no Git (GitOps pull-based).
# Executado pelo mgdn-gitops.timer. Cada host tem um papel (ROLE, em
# /etc/mgdn-platform/env) e aplica deploy/<ROLE>/compose.yaml. Fluxo:
#   fetch -> há commit novo? -> valida (compose, blocky, prometheus, headscale)
#   -> aplica -> verifica se o DNS responde -> se não, volta ao último commit bom.
#
# Uso: gitops-sync.sh [--force]   (--force reaplica mesmo sem commit novo)
#
# Todo o corpo fica dentro de main(): o bash lê o script inteiro antes de executar,
# então o `git checkout` pode reescrever este arquivo com segurança.

main() {
  set -euo pipefail

  # shellcheck source=/dev/null
  source /etc/mgdn-platform/env
  local state_dir=/var/lib/mgdn-platform
  local force="${1:-}"
  mkdir -p "$state_dir"
  cd "$REPO_DIR"

  # Uma execução por vez: no primeiro boot o cloud-init e o timer disparam juntos.
  exec 9>/run/mgdn-platform-gitops.lock
  flock -w 900 9

  git fetch --quiet origin "$REPO_BRANCH"
  local target applied failed
  target=$(git rev-parse "origin/$REPO_BRANCH")
  applied=$(cat "$state_dir/applied" 2>/dev/null || true)
  failed=$(cat "$state_dir/failed" 2>/dev/null || true)

  if [[ "$force" != "--force" ]]; then
    [[ "$target" == "$applied" ]] && exit 0
    if [[ "$target" == "$failed" ]]; then
      log "commit ${target:0:7} já falhou antes; aguardando um novo commit"
      exit 0
    fi
  fi

  log "[$ROLE] reconciliando ${applied:0:7} -> ${target:0:7}"

  if ! validate "$target"; then
    log "ERRO: validação falhou para ${target:0:7}; nada foi aplicado"
    echo "$target" >"$state_dir/failed"
    [[ -n "$applied" ]] && checkout "$applied"
    exit 1
  fi

  apply "$applied" "$target"

  if dns_healthy; then
    echo "$target" >"$state_dir/applied"
    rm -f "$state_dir/failed"
    docker image prune -af >/dev/null
    log "OK: ${target:0:7} aplicado"
  else
    log "ERRO: DNS não respondeu após aplicar ${target:0:7}"
    echo "$target" >"$state_dir/failed"
    if [[ -n "$applied" ]]; then
      log "rollback para ${applied:0:7}"
      apply "$target" "$applied"
      dns_healthy || log "ERRO: DNS segue indisponível após rollback"
    fi
    exit 1
  fi

  # Registro na tailnet: idempotente e não bloqueia o deploy (o DNS já está no ar).
  "$REPO_DIR/scripts/tailnet-join.sh" || log "AVISO: registro na tailnet falhou; nova tentativa no próximo sync forçado"
}

REPO_DIR=/opt/mgdn-platform

log() { echo "[gitops] $*"; }

checkout() { git -c advice.detachedHead=false checkout --quiet --force "$1"; }

compose() {
  docker compose --project-directory "$REPO_DIR/deploy/$ROLE" -f "$REPO_DIR/deploy/$ROLE/compose.yaml" "$@"
}

has_service() { compose config --services | grep -qx "$1"; }

image_of() {
  compose config --format json | python3 -c "import json,sys;print(json.load(sys.stdin)['services']['$1']['image'])"
}

validate() {
  checkout "$1"
  compose config --quiet || return 1
  compose run --rm --no-deps -T blocky validate || return 1
  if has_service prometheus; then
    compose run --rm --no-deps -T --entrypoint promtool prometheus \
      check config /etc/prometheus/prometheus.yml >/dev/null || return 1
    compose run --rm --no-deps -T --entrypoint promtool -w /etc/prometheus/tests prometheus \
      test rules slo_test.yml >/dev/null || return 1
  fi
  if has_service alertmanager; then
    compose run --rm --no-deps -T --entrypoint amtool alertmanager \
      check-config /etc/alertmanager/alertmanager.yml >/dev/null || return 1
  fi
  if has_service blackbox; then
    compose run --rm --no-deps -T blackbox --config.file=/etc/blackbox/blackbox.yml --config.check >/dev/null 2>&1 || return 1
  fi
  if has_service headscale; then
    # Diretórios temporários: o configtest abre o banco e não deve tocar no real.
    docker run --rm -v "$REPO_DIR/deploy/$ROLE/headscale/config.yaml:/etc/headscale/config.yaml:ro" \
      --tmpfs /var/lib/headscale --tmpfs /var/run/headscale \
      "$(image_of headscale)" configtest >/dev/null || return 1
  fi
}

# apply <de> <para>: instala units do systemd, sobe a stack e reinicia os serviços
# cujos arquivos de configuração mudaram (bind mounts não disparam recriação).
apply() {
  local from="$1" to="$2"
  checkout "$to"

  local unit reload=false
  for unit in deploy/systemd/*; do
    if ! cmp -s "$unit" "/etc/systemd/system/${unit##*/}"; then
      install -m 0644 "$unit" /etc/systemd/system/
      reload=true
    fi
  done
  $reload && systemctl daemon-reload
  # Idempotente: units novas são habilitadas mesmo se instaladas por uma versão
  # anterior deste script.
  systemctl enable --quiet mgdn-allowlist.service
  systemctl enable --quiet --now mgdn-gitops.timer mgdn-healthcheck.timer mgdn-allowlist.timer mgdn-maintenance.timer mgdn-backup.timer

  # O host principal fala com o próprio Headscale via 127.0.0.1 (sem hairpin NAT).
  # shellcheck source=/dev/null
  source "$REPO_DIR/deploy/common/platform.env"
  if [[ "$ROLE" == "primary" ]] && ! grep -qxF "127.0.0.1 $HEADSCALE_HOSTNAME" /etc/hosts; then
    echo "127.0.0.1 $HEADSCALE_HOSTNAME" >>/etc/hosts
  fi

  # Filtro de origem ativo antes de qualquer container publicar a porta 53.
  systemctl start mgdn-allowlist.service

  compose pull --quiet

  # Token da Cloudflare para o Traefik emitir certificados por DNS-01 (ADR 0010).
  if has_service traefik; then
    install -d -m 0700 /etc/mgdn-platform/traefik
    printf '%s' "${CLOUDFLARE_DNS_TOKEN:-}" | install -m 0600 /dev/stdin /etc/mgdn-platform/traefik/cf-dns-token
  fi

  # URL secreta do ntfy para o Alertmanager (ADR 0009): arquivo fora do repo,
  # legível pelo usuário do container (nobody). Sem URL, os alertas não saem.
  if has_service alertmanager; then
    install -d -m 0750 -g 65534 /etc/mgdn-platform/alertmanager
    printf '%s\n' "${ALERT_NTFY_URL:-http://127.0.0.1:9/alertas-desativados}" |
      install -m 0640 -g 65534 /dev/stdin /etc/mgdn-platform/alertmanager/ntfy-url
  fi

  # VM nova (primeiro deploy): restaura o Headscale do backup mais recente antes de
  # subi-lo, para os aparelhos seguirem na tailnet sem novo registro (ADR 0006).
  if [[ -z "$from" ]] && has_service headscale && [[ -n "${BACKUP_BUCKET:-}" ]]; then
    compose create headscale vaultwarden traefik >/dev/null
    "$REPO_DIR/scripts/restore.sh" --if-empty --with-tailscale >/dev/null || log "AVISO: restore do Headscale falhou; subindo com estado vazio"
  fi

  compose up -d --remove-orphans

  [[ -z "$from" ]] && return 0
  local svc
  for svc in $(compose config --services); do
    if ! git diff --quiet "$from" "$to" -- "deploy/common/$svc" "deploy/$ROLE/$svc"; then
      log "config de $svc mudou; reiniciando"
      compose restart "$svc"
    fi
  done
}

dns_healthy() {
  for _ in $(seq 1 30); do
    if dig +short +time=2 +tries=1 @127.0.0.1 cloudflare.com A | grep -qE '^[0-9.]+$'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

main "$@"
