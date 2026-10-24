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
  if [[ "$ROLE" == "primary" ]]; then
    "$REPO_DIR/scripts/tailnet-join.sh" || log "AVISO: registro na tailnet falhou; nova tentativa no próximo sync forçado"
  fi
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
  systemctl enable --quiet --now mgdn-gitops.timer mgdn-healthcheck.timer mgdn-allowlist.timer mgdn-maintenance.timer

  # Filtro de origem ativo antes de qualquer container publicar a porta 53.
  systemctl start mgdn-allowlist.service

  compose pull --quiet
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
