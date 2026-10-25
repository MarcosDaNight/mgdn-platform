#!/usr/bin/env bash
# Backup da VM principal (ADR 0006): os volumes de todo serviço com o label
# mgdn.backup.volume (ADR 0015: Headscale, Traefik, Vaultwarden, Actual...), com
# snapshots consistentes dos SQLite, mais o estado do cliente Tailscale desta VM.
# Cifrado com a chave pública age do repositório e enviado ao bucket imutável
# (object lock) em br-se1. Executado pelo mgdn-backup.timer.
#
# Sem a chave Noise, todos os aparelhos teriam de entrar de novo na tailnet. Sem o
# tailscaled.state, a VM recriada viraria um nó novo e perderia o 100.64.0.1
# (o DNS da tailnet).
set -euo pipefail

# shellcheck source=/dev/null
source /etc/mgdn-platform/env
repo=/opt/mgdn-platform
# shellcheck source=scripts/s3.sh
source "$repo/scripts/s3.sh"

log() { echo "[backup] $*"; }

if [[ "${ROLE:-}" != "primary" || -z "${BACKUP_BUCKET:-}" ]]; then
  log "nada a fazer neste host (ROLE=${ROLE:-?}, BACKUP_BUCKET=${BACKUP_BUCKET:-vazio})"
  exit 0
fi

ping_hc() { [[ -z "${BACKUP_HEALTHCHECK_URL:-}" ]] || curl -fsS -m 10 --retry 3 -o /dev/null "${BACKUP_HEALTHCHECK_URL}$1" || true; }
trap 'ping_hc /fail' ERR

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dirs=()

# snapshot <origem> <destino> <exclusões>: cópia do volume em que cada SQLite é trocado
# por um snapshot consistente pela API de backup online (o app pode estar gravando).
snapshot() {
  local src=$1 dst=$2 exclude=$3 ex f rel
  cp -a "$src" "$dst"
  IFS=, read -ra ex <<<"$exclude"
  for f in "${ex[@]}"; do
    [[ -z "$f" ]] || rm -rf "${dst:?}/$f"
  done
  while IFS= read -r -d '' f; do
    [[ "$(head -c 15 "$f" | tr -d '\0')" == "SQLite format 3" ]] || continue
    rel=${f#"$dst"/}
    # O snapshot já inclui o WAL; uma cópia velha dele ao lado corromperia o restore.
    rm -f "$f-wal" "$f-shm" "$f-journal"
    sqlite3 "$src/$rel" ".backup '$f'"
    [[ "$(sqlite3 "$f" 'PRAGMA integrity_check;')" == "ok" ]]
  done < <(find "$dst" -type f ! -name '*-wal' ! -name '*-shm' ! -name '*-journal' -print0)
}

# Apps com dados (ADR 0015): todo serviço com o label mgdn.backup.volume entra, sem
# bloco próprio aqui. Cada um vira um diretório com o nome do serviço no arquivo.
while IFS=$'\t' read -r svc vol _mount ready exclude; do
  src=/var/lib/docker/volumes/$vol/_data
  if [[ -n "$ready" && ! -e "$src/$ready" ]] || [[ -z "$(ls -A "$src" 2>/dev/null)" ]]; then
    log "$svc: ainda sem dados, fora deste backup"
    continue
  fi
  snapshot "$src" "$work/$svc" "$exclude"
  dirs+=("$svc")
done < <(python3 "$repo/scripts/apps.py" --compose "$repo/deploy/primary/compose.yaml" backup)
[[ " ${dirs[*]} " == *" headscale "* ]] || {
  log "ERRO: o Headscale não entrou no backup"
  exit 1
}

# Estado do cliente Tailscale desta VM (fora dos volumes): sem ele, a VM recriada
# viraria um nó novo e perderia o 100.64.0.1.
if [[ -f /var/lib/tailscale/tailscaled.state ]]; then
  mkdir "$work/tailscale"
  cp /var/lib/tailscale/tailscaled.state "$work/tailscale/"
  dirs+=(tailscale)
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$work/headscale-$ts.tar.gz.age"
tar -C "$work" -czf - "${dirs[@]}" | age -R "$repo/deploy/primary/backup/recipient.txt" >"$out"

key="headscale/$ts.tar.gz.age"
s3_put "$out" "$key"
log "OK: $key ($(stat -c %s "$out") bytes)"
ping_hc ""

# Rotação (ADR 0007). Não afeta o sucesso do backup: o lock protege o recente e a
# próxima execução tenta de novo.
"$repo/scripts/prune.sh" || log "AVISO: rotação falhou"
