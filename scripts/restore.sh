#!/usr/bin/env bash
# Restaura um backup do Headscale (ADR 0006).
#
# Uso: restore.sh [--if-empty] [--with-tailscale] [--target DIR] [CHAVE]
#   --if-empty        só restaura se DIR não tiver db.sqlite (boot de uma VM nova)
#   --with-tailscale  também restaura o tailscaled.state desta VM, que volta à
#                     tailnet como o mesmo nó (mesmo IP), sem novo registro
#   --target          destino (padrão: volume do Headscale na VM)
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
key=""
while (($#)); do
  case "$1" in
  --if-empty) if_empty=true ;;
  --with-tailscale) with_tailscale=true ;;
  --target)
    target="$2"
    shift
    ;;
  *) key="$1" ;;
  esac
  shift
done

: "${BACKUP_BUCKET:?}" "${BACKUP_AGE_IDENTITY:?}"

if $if_empty && [[ -f "$target/db.sqlite" ]]; then
  log "$target já tem db.sqlite; nada a restaurar"
  exit 0
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
[[ "$(sqlite3 "$work/headscale/db.sqlite" 'PRAGMA integrity_check;')" == "ok" ]]

mkdir -p "$target"
cp -a "$work/headscale/." "$target/"
log "OK: $key restaurado em $target"

if $with_tailscale && [[ -f "$work/tailscale/tailscaled.state" ]]; then
  systemctl stop tailscaled
  install -D -m 0600 "$work/tailscale/tailscaled.state" /var/lib/tailscale/tailscaled.state
  systemctl start tailscaled
  log "estado do Tailscale restaurado (o nó volta com o mesmo IP)"
fi
echo "restored=$key"
