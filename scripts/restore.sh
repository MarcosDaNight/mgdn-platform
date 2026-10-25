#!/usr/bin/env bash
# Restaura um backup da VM principal (ADR 0006): os volumes de todo serviço com o
# label mgdn.backup.volume (ADR 0015) e, opcionalmente, o estado do Tailscale.
#
# Uso: restore.sh [--if-empty] [--with-tailscale] [--target SERVIÇO=DIR]... [CHAVE]
#   --if-empty        só restaura os serviços cujo destino ainda não tem dados (VM nova),
#                     pelo arquivo do label mgdn.backup.ready
#   --with-tailscale  também restaura o tailscaled.state desta VM, que volta à
#                     tailnet como o mesmo nó (mesmo IP), sem novo registro; só junto
#                     com o Headscale
#   --target          destino de um serviço (padrão: o volume dele na VM); repetível
#   CHAVE             objeto no bucket (padrão: o backup mais recente)
# Compatibilidade: --target DIR (sem "=") vale para o Headscale; --vw-target,
# --actual-target e --acme-target, para vaultwarden, actual e traefik.
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
declare -A target=()
key=""
while (($#)); do
  case "$1" in
  --if-empty) if_empty=true ;;
  --with-tailscale) with_tailscale=true ;;
  --target)
    if [[ "$2" == *=* ]]; then target[${2%%=*}]=${2#*=}; else target[headscale]=$2; fi
    shift
    ;;
  --vw-target)
    target[vaultwarden]=$2
    shift
    ;;
  --actual-target)
    target[actual]=$2
    shift
    ;;
  --acme-target)
    target[traefik]=$2
    shift
    ;;
  *) key="$1" ;;
  esac
  shift
done

: "${BACKUP_BUCKET:?}" "${BACKUP_AGE_IDENTITY:?}"

# has_data <dir> <ready>: o destino já tem os dados do app?
has_data() {
  if [[ -n "$2" ]]; then [[ -s "$1/$2" ]]; else [[ -n "$(ls -A "$1" 2>/dev/null)" ]]; fi
}

declare -A ready=()
services=()
while IFS=$'\t' read -r svc vol _mount rdy _exclude; do
  services+=("$svc")
  ready[$svc]=$rdy
  [[ -n "${target[$svc]:-}" ]] || target[$svc]=/var/lib/docker/volumes/$vol/_data
done < <(python3 "$here/apps.py" --compose "$here/../deploy/primary/compose.yaml" backup)

declare -A need=()
for svc in "${services[@]}"; do
  need[$svc]=true
  if $if_empty && has_data "${target[$svc]}" "${ready[$svc]}"; then
    need[$svc]=false
  fi
done
if [[ " ${need[*]} " != *" true "* ]]; then
  log "todos os apps já têm dados (${services[*]}); nada a restaurar"
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

for svc in "${services[@]}"; do
  ${need[$svc]} || continue
  # Backups anteriores a um app não têm o diretório dele.
  [[ -d "$work/$svc" ]] || {
    log "$svc: ausente em $key"
    continue
  }
  while IFS= read -r -d '' f; do
    [[ "$(head -c 15 "$f" | tr -d '\0')" == "SQLite format 3" ]] || continue
    [[ "$(sqlite3 "$f" 'PRAGMA integrity_check;')" == "ok" ]] || {
      log "ERRO: $svc: ${f#"$work/"} corrompido em $key"
      exit 1
    }
  done < <(find "$work/$svc" -type f -print0)
  mkdir -p "${target[$svc]}"
  cp -a "$work/$svc/." "${target[$svc]}/"
  log "OK: $svc de $key restaurado em ${target[$svc]}"
done

if $with_tailscale && ${need[headscale]:-false} && [[ -f "$work/tailscale/tailscaled.state" ]]; then
  systemctl stop tailscaled
  install -D -m 0600 "$work/tailscale/tailscaled.state" /var/lib/tailscale/tailscaled.state
  systemctl start tailscaled
  log "estado do Tailscale restaurado (o nó volta com o mesmo IP)"
fi
echo "restored=$key"
