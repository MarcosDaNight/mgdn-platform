#!/usr/bin/env bash
# Rotação dos backups (ADR 0007): a política roda do lado do cliente, aqui, depois
# de cada backup. A regra está em
# retention.py (diários por 30 dias, um mensal por 12 meses, nunca menos de 7).
# O object lock garante que nada com menos de 30 dias pode ser apagado, mesmo que
# este script ou a VM sejam comprometidos.
#
# Uso: prune.sh [--dry-run]
set -euo pipefail

# shellcheck source=/dev/null
[[ ! -f /etc/mgdn-platform/env ]] || source /etc/mgdn-platform/env
# shellcheck source=/dev/null
[[ ! -f /etc/mgdn-platform/secrets.env ]] || source /etc/mgdn-platform/secrets.env
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/s3.sh
source "$here/s3.sh"

log() { echo "[prune] $*"; }
dry=false
[[ "${1:-}" != "--dry-run" ]] || dry=true
: "${BACKUP_BUCKET:?}"

versions=$(s3_list_versions headscale/ | grep -P '\.tar\.gz\.age\t' || true)
total=$(grep -c . <<<"$versions" || true)
doomed=$(python3 "$here/retention.py" <<<"$versions")
n=$(grep -c . <<<"$doomed" || true)

deleted=0
while IFS=$'\t' read -r key vid; do
  [[ -n "$key" ]] || continue
  if $dry; then
    log "apagaria $key ($vid)"
  else
    if s3_delete_version "$key" "$vid"; then
      deleted=$((deleted + 1))
    else
      log "AVISO: não apagou $key (lock ainda ativo?)"
    fi
  fi
done <<<"$doomed"

log "$total backups; $n fora da política; $($dry && echo "0 apagados (dry-run)" || echo "$deleted apagados"); mantidos: $((total - n))"
