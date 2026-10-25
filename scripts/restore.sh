#!/usr/bin/env bash
# Restaura um backup do Headscale (ADR 0006).
#
# Uso: restore.sh [--if-empty] [--with-tailscale] [--target DIR] [--vw-target DIR]
#                  [--actual-target DIR] [--acme-target DIR] [CHAVE]
#   --if-empty        só restaura os componentes cujo destino está vazio (VM nova)
#   --with-tailscale  também restaura o tailscaled.state desta VM, que volta à
#                     tailnet como o mesmo nó (mesmo IP), sem novo registro
#   --target          destino do Headscale (padrão: volume na VM)
#   --vw-target       destino do Vaultwarden (padrão: volume na VM)
#   --actual-target   destino do Actual Budget (padrão: volume na VM)
#   --acme-target     destino dos certificados do Traefik (padrão: volume na VM)
#   CHAVE             objeto no bucket (padrão: o backup mais recente)
#
# Na VM lê /etc/mgdn-platform/env; no CI as mesmas variáveis vêm do ambiente.
# BACKUP_AGE_IDENTITY contém a linha AGE-SECRET-KEY-... da chave privada.
# Imprime "restored=<chave>" para quem chama (o DR drill) calcular o RPO.
set -euo pipefail

# shellcheck source=/dev/null
[[ ! -f /etc/mgdn-platform/env ]] || source /etc/mgdn-platform/env
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/s3.sh
source "$here/s3.sh"

log() { echo "[restore] $*" >&2; }

if_empty=false
with_tailscale=false
target=/var/lib/docker/volumes/mgdn_headscale-data/_data
vw_target=/var/lib/docker/volumes/mgdn_vaultwarden-data/_data
actual_target=/var/lib/docker/volumes/mgdn_actual-data/_data
acme_target=/var/lib/docker/volumes/mgdn_traefik-acme/_data
key=""
while (($#)); do
  case "$1" in
  --if-empty) if_empty=true ;;
  --with-tailscale) with_tailscale=true ;;
  --target)
    target="$2"
    shift
    ;;
  --vw-target)
    vw_target="$2"
    shift
    ;;
  --actual-target)
    actual_target="$2"
    shift
    ;;
  --acme-target)
    acme_target="$2"
    shift
    ;;
  *) key="$1" ;;
  esac
  shift
done

: "${BACKUP_BUCKET:?}" "${BACKUP_AGE_IDENTITY:?}"

need_hs=true need_vw=true need_actual=true need_acme=true
if $if_empty; then
  [[ ! -f "$target/db.sqlite" ]] || need_hs=false
  [[ ! -f "$vw_target/db.sqlite3" ]] || need_vw=false
  [[ ! -f "$actual_target/server-files/account.sqlite" ]] || need_actual=false
  [[ ! -s "$acme_target/acme.json" ]] || need_acme=false
  if ! $need_hs && ! $need_vw && ! $need_actual && ! $need_acme; then
    log "Headscale, Vaultwarden, Actual e certificados já existem; nada a restaurar"
    exit 0
  fi
fi

if [[ -z "$key" ]]; then
  key=$(s3_list headscale/ | grep '\.tar\.gz\.age$' | sort | tail -1)
  [[ -n "$key" ]] || {
    log "nenhum backup encontrado em s3://$BACKUP_BUCKET/headscale/"
    exit 1
  }
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(
  umask 077
  printf '%s\n' "$BACKUP_AGE_IDENTITY" >"$work/identity"
)

s3_get "$key" "$work/backup.age"
age -d -i "$work/identity" "$work/backup.age" | tar -C "$work" -xzf -

if $need_hs; then
  [[ "$(sqlite3 "$work/headscale/db.sqlite" 'PRAGMA integrity_check;')" == "ok" ]]
  mkdir -p "$target"
  cp -a "$work/headscale/." "$target/"
  log "OK: Headscale de $key restaurado em $target"
fi

# Backups anteriores ao Vaultwarden não têm este diretório.
if $need_vw && [[ -f "$work/vaultwarden/db.sqlite3" ]]; then
  [[ "$(sqlite3 "$work/vaultwarden/db.sqlite3" 'PRAGMA integrity_check;')" == "ok" ]]
  mkdir -p "$vw_target"
  cp -a "$work/vaultwarden/." "$vw_target/"
  log "OK: Vaultwarden de $key restaurado em $vw_target"
fi

# Backups anteriores ao Actual Budget (ADR 0012) não têm este diretório.
if $need_actual && [[ -f "$work/actual/server-files/account.sqlite" ]]; then
  while IFS= read -r -d '' db; do
    [[ "$(sqlite3 "$db" 'PRAGMA integrity_check;')" == "ok" ]]
  done < <(find "$work/actual" -name '*.sqlite' -print0)
  mkdir -p "$actual_target"
  cp -a "$work/actual/." "$actual_target/"
  log "OK: Actual Budget de $key restaurado em $actual_target"
fi

if $need_acme && [[ -s "$work/traefik/acme.json" ]]; then
  # O Traefik exige acme.json com permissão 600.
  install -D -m 0600 "$work/traefik/acme.json" "$acme_target/acme.json"
  log "OK: certificados do Traefik de $key restaurados"
fi

if $with_tailscale && $need_hs && [[ -f "$work/tailscale/tailscaled.state" ]]; then
  systemctl stop tailscaled
  install -D -m 0600 "$work/tailscale/tailscaled.state" /var/lib/tailscale/tailscaled.state
  systemctl start tailscaled
  log "estado do Tailscale restaurado (o nó volta com o mesmo IP)"
fi
echo "restored=$key"
