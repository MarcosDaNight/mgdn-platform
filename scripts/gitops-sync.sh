#!/usr/bin/env bash
# Reconcilia a VM com o estado declarado no Git (GitOps pull-based).
# Executado pelo mgdn-gitops.timer. Cada host tem um papel (ROLE, em
# /etc/mgdn-platform/env) e aplica deploy/<ROLE>/compose.yaml. Fluxo:
#   fetch -> há commit novo? -> valida (compose, blocky, prometheus, headscale)
#   -> aplica -> verifica se o DNS responde -> se não, volta ao último commit bom.
# Sem commit novo, faz self-heal: `compose up -d` (idempotente) recria o que tiver
# sido parado ou removido fora do Git. Toda execução publica métricas para o
# Prometheus (textfile collector do node-exporter).
#
# Uso: gitops-sync.sh [--force]   (--force reaplica mesmo sem commit novo)
#
# Todo o corpo fica dentro de main(): o bash lê o script inteiro antes de executar,
# então o `git checkout` pode reescrever este arquivo com segurança.

main() {
  set -euo pipefail

  # shellcheck source=/dev/null
  source /etc/mgdn-platform/env
  # shellcheck source=/dev/null
  [[ ! -f "$SECRETS_ENV" ]] || source "$SECRETS_ENV"
  local state_dir=$STATE_DIR
  local force="${1:-}"
  mkdir -p "$state_dir"
  cd "$REPO_DIR"

  # Uma execução por vez: no primeiro boot o cloud-init e o timer disparam juntos.
  exec 9>/run/mgdn-platform-gitops.lock
  flock -w 900 9

  # Métricas em toda saída, inclusive nas falhas (set -e).
  trap 'write_metrics $?' EXIT

  git fetch --quiet origin "$REPO_BRANCH"
  local target applied failed
  target=$(git rev-parse "origin/$REPO_BRANCH")
  applied=$(cat "$state_dir/applied" 2>/dev/null || true)
  failed=$(cat "$state_dir/failed" 2>/dev/null || true)

  if [[ "$force" != "--force" ]]; then
    if [[ "$target" == "$applied" ]]; then
      self_heal
      exit 0
    fi
    if [[ "$target" == "$failed" ]]; then
      log "commit ${target:0:7} já falhou antes; aguardando um novo commit"
      self_heal
      exit 0
    fi
  fi

  log "[$ROLE] reconciliando ${applied:0:7} -> ${target:0:7}"

  if ! validate "$target"; then
    log "ERRO: validação falhou para ${target:0:7}; nada foi aplicado"
    echo "$target" >"$state_dir/failed"
    [[ -n "$applied" ]] && checkout "$applied"
    # VM nova: sem o timer, nada tentaria de novo e a VM ficaria parada até ser
    # recriada. Com ele, o próximo commit (a correção) é aplicado sozinho.
    [[ -n "$applied" ]] || install_gitops_timer
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
STATE_DIR=/var/lib/mgdn-platform
METRICS_DIR=$STATE_DIR/metrics
# Segredos do repositório (ADR 0014): a chave do host vem do cloud-init; o arquivo
# decifrado é lido pelos scripts depois do env e tem precedência sobre ele.
AGE_KEY=/etc/mgdn-platform/age.key
SECRETS_ENV=/etc/mgdn-platform/secrets.env

# self_heal: reaplica o estado do commit atual. Sem mudanças no Git, `compose up -d`
# não faz nada; se um container foi parado ou removido à mão, ele volta.
self_heal() {
  local out changed
  if ! out=$(compose up -d --remove-orphans 2>&1); then
    log "AVISO: self-heal falhou: $(tail -1 <<<"$out")"
    return 1
  fi
  changed=$(grep -cE ' (Started|Recreated|Created)$' <<<"$out" || true)
  if ((changed > 0)); then
    log "self-heal: $changed container(s) recolocado(s) no estado do Git"
    echo $(($(cat "$STATE_DIR/drift_total" 2>/dev/null || echo 0) + changed)) >"$STATE_DIR/drift_total"
  fi
}

# write_metrics <código de saída>: gravação atômica lida pelo node-exporter.
write_metrics() {
  local rc=$1 now applied target
  now=$(date +%s)
  mkdir -p "$METRICS_DIR"
  [[ "$rc" -ne 0 ]] || echo "$now" >"$STATE_DIR/last_success"
  applied=$(cat "$STATE_DIR/applied" 2>/dev/null || echo none)
  target=$(git -C "$REPO_DIR" rev-parse "origin/$REPO_BRANCH" 2>/dev/null || echo unknown)
  cat >"$METRICS_DIR/.mgdn_gitops.prom" <<METRICS
# HELP mgdn_gitops_last_run_timestamp_seconds Fim da última execução do GitOps sync.
# TYPE mgdn_gitops_last_run_timestamp_seconds gauge
mgdn_gitops_last_run_timestamp_seconds $now
# HELP mgdn_gitops_last_success_timestamp_seconds Fim da última execução bem-sucedida.
# TYPE mgdn_gitops_last_success_timestamp_seconds gauge
mgdn_gitops_last_success_timestamp_seconds $(cat "$STATE_DIR/last_success" 2>/dev/null || echo 0)
# HELP mgdn_gitops_last_result 1 se a última execução terminou bem, 0 se falhou.
# TYPE mgdn_gitops_last_result gauge
mgdn_gitops_last_result $([[ "$rc" -eq 0 ]] && echo 1 || echo 0)
# HELP mgdn_gitops_behind 1 se a branch tem um commit que não está aplicado.
# TYPE mgdn_gitops_behind gauge
mgdn_gitops_behind $([[ "$applied" == "$target" ]] && echo 0 || echo 1)
# HELP mgdn_gitops_drift_corrections_total Containers recolocados no estado do Git pelo self-heal.
# TYPE mgdn_gitops_drift_corrections_total counter
mgdn_gitops_drift_corrections_total $(cat "$STATE_DIR/drift_total" 2>/dev/null || echo 0)
# HELP mgdn_gitops_applied_info Commit aplicado neste host.
# TYPE mgdn_gitops_applied_info gauge
mgdn_gitops_applied_info{commit="${applied:0:7}"} 1
METRICS
  mv "$METRICS_DIR/.mgdn_gitops.prom" "$METRICS_DIR/mgdn_gitops.prom"
}

log() { echo "[gitops] $*"; }

# ssh_host_key: instala a chave SSH do host guardada nos segredos (ADR 0014). A VM
# recriada mantém a identidade, e o deploy/ssh/known_hosts do repositório continua
# valendo. Só a chave ed25519 é oferecida. Configuração inválida não chega ao sshd.
ssh_host_key() {
  [[ -n "${SSH_HOST_ED25519_KEY_B64:-}" ]] || return 0
  local key=/etc/ssh/ssh_host_ed25519_key conf=/etc/ssh/sshd_config.d/10-mgdn-hostkey.conf
  local tmp changed=false
  tmp=$(mktemp)
  base64 -d <<<"$SSH_HOST_ED25519_KEY_B64" >"$tmp"
  if ! cmp -s "$tmp" "$key"; then
    [[ ! -f "$key" ]] || cp -a "$key" "$key.anterior"
    install -m 0600 "$tmp" "$key"
    ssh-keygen -y -f "$key" >"$key.pub"
    chmod 0644 "$key.pub"
    changed=true
  fi
  rm -f "$tmp"
  if [[ "$(cat "$conf" 2>/dev/null)" != "HostKey $key" ]]; then
    echo "HostKey $key" >"$conf"
    changed=true
  fi
  $changed || return 0
  # Com o ssh.socket do Ubuntu 24.04, o /run/sshd só existe depois da primeira conexão,
  # e sem ele o `sshd -t` falha mesmo com a configuração certa.
  install -d -m 0755 /run/sshd
  local err
  if err=$(sshd -t 2>&1); then
    systemctl try-reload-or-restart ssh.service
    log "chave SSH do host instalada ($(ssh-keygen -lf "$key.pub" | awk '{print $2}'))"
  else
    rm -f "$conf"
    if [[ -f "$key.anterior" ]]; then
      mv "$key.anterior" "$key"
      ssh-keygen -y -f "$key" >"$key.pub"
    fi
    log "AVISO: sshd rejeitou a chave do host dos segredos (${err:-sem saída}); mantida a anterior"
  fi
}

install_gitops_timer() {
  install -m 0644 "$REPO_DIR"/deploy/systemd/mgdn-gitops.{service,timer} /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --quiet --now mgdn-gitops.timer
  log "timer do GitOps instalado: o próximo commit será tentado sozinho"
}

checkout() { git -c advice.detachedHead=false checkout --quiet --force "$1"; }

compose() {
  docker compose --project-directory "$REPO_DIR/deploy/$ROLE" -f "$REPO_DIR/deploy/$ROLE/compose.yaml" "$@"
}

has_service() { compose config --services | grep -qx "$1"; }

image_of() {
  compose config --format json | python3 -c "import json,sys;print(json.load(sys.stdin)['services']['$1']['image'])"
}

# has_secrets: há chave neste host e arquivo de segredos no commit em checkout.
# Hosts sem chave (criados antes do ADR 0014) seguem só com o env do cloud-init.
has_secrets() { [[ -f "$AGE_KEY" && -f "$REPO_DIR/secrets/$ROLE.env.age" ]]; }

validate() {
  checkout "$1"
  compose config --quiet || return 1
  if has_secrets; then
    "$REPO_DIR/scripts/secrets.sh" decrypt "$ROLE" "$AGE_KEY" /run/mgdn-secrets.validate || return 1
    rm -f /run/mgdn-secrets.validate
  fi
  compose run --rm --no-deps -T blocky validate || return 1
  if has_service prometheus; then
    compose run --rm --no-deps -T --entrypoint promtool prometheus \
      check config /etc/prometheus/prometheus.yml >/dev/null || return 1
    compose run --rm --no-deps -T --entrypoint promtool -w /etc/prometheus/tests prometheus \
      test rules slo_test.yml gitops_test.yml watchdog_test.yml host_test.yml tailnet_test.yml >/dev/null || return 1
  fi
  if has_service alertmanager; then
    compose run --rm --no-deps -T --entrypoint amtool alertmanager \
      check-config /etc/alertmanager/alertmanager.yml >/dev/null || return 1
    # O Watchdog (ADR 0013) vai só para o healthchecks.io, nunca para o celular.
    compose run --rm --no-deps -T --entrypoint amtool alertmanager config routes test \
      --config.file /etc/alertmanager/alertmanager.yml --verify.receivers=healthchecks alertname=Watchdog >/dev/null || return 1
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

  if has_secrets; then
    "$REPO_DIR/scripts/secrets.sh" decrypt "$ROLE" "$AGE_KEY" "$SECRETS_ENV"
    # shellcheck source=/dev/null
    source "$SECRETS_ENV"
  fi
  ssh_host_key

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
  # O Traefik só lê o arquivo no boot: token novo pede restart.
  local restart_traefik=false
  if has_service traefik; then
    install -d -m 0700 /etc/mgdn-platform/traefik
    if [[ -f /etc/mgdn-platform/traefik/cf-dns-token && "$(cat /etc/mgdn-platform/traefik/cf-dns-token)" != "${CLOUDFLARE_DNS_TOKEN:-}" ]]; then
      restart_traefik=true
    fi
    printf '%s' "${CLOUDFLARE_DNS_TOKEN:-}" | install -m 0600 /dev/stdin /etc/mgdn-platform/traefik/cf-dns-token
  fi

  # URLs secretas do Alertmanager, em arquivos fora do repo legíveis pelo usuário do
  # container (nobody): o tópico do ntfy (ADR 0009) e o ping do Watchdog no
  # healthchecks.io (ADR 0013). Sem URL, o envio correspondente não sai.
  if has_service alertmanager; then
    install -d -m 0750 -g 65534 /etc/mgdn-platform/alertmanager
    printf '%s\n' "${ALERT_NTFY_URL:-http://127.0.0.1:9/alertas-desativados}" |
      install -m 0640 -g 65534 /dev/stdin /etc/mgdn-platform/alertmanager/ntfy-url
    printf '%s\n' "${ALERT_WATCHDOG_URL:-http://127.0.0.1:9/watchdog-desativado}" |
      install -m 0640 -g 65534 /dev/stdin /etc/mgdn-platform/alertmanager/watchdog-url
  fi

  # VM nova (primeiro deploy): restaura os apps com dados (label mgdn.backup.volume,
  # ADR 0015) do backup mais recente antes de subi-los. O Headscale volta com os
  # aparelhos, que seguem na tailnet sem novo registro (ADR 0006).
  if [[ -z "$from" ]] && has_service headscale && [[ -n "${BACKUP_BUCKET:-}" ]]; then
    # shellcheck disable=SC2046
    compose create $(python3 "$REPO_DIR/scripts/apps.py" --compose "$REPO_DIR/deploy/$ROLE/compose.yaml" backup | cut -f1) >/dev/null
    "$REPO_DIR/scripts/restore.sh" --if-empty --with-tailscale >/dev/null || log "AVISO: restore do Headscale falhou; subindo com estado vazio"
  fi

  compose up -d --remove-orphans

  [[ -z "$from" ]] && return 0
  if $restart_traefik; then
    log "token da Cloudflare mudou; reiniciando traefik"
    compose restart traefik
  fi
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
