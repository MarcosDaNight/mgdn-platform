#!/usr/bin/env bash
# Backup do Headscale (ADR 0006) e do Vaultwarden (ADR 0010): snapshots
# consistentes dos SQLite, chave Noise, cache ACME, dados do Vaultwarden e o estado
# do cliente Tailscale desta VM, cifrados com a chave
# pública age do repositório e enviados ao bucket imutável (object lock) em br-se1.
# Executado pelo mgdn-backup.timer.
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

vol=/var/lib/docker/volumes/mgdn_headscale-data/_data
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/headscale"

# API de backup online do SQLite: consistente mesmo com o Headscale gravando (WAL).
sqlite3 "$vol/db.sqlite" ".backup '$work/headscale/db.sqlite'"
[[ "$(sqlite3 "$work/headscale/db.sqlite" 'PRAGMA integrity_check;')" == "ok" ]]
cp "$vol/noise_private.key" "$work/headscale/"
[[ ! -d "$vol/cache" ]] || cp -r "$vol/cache" "$work/headscale/"
dirs=(headscale)

# Vaultwarden (ADR 0010): banco, chaves RSA dos tokens, anexos e sends.
vw=/var/lib/docker/volumes/mgdn_vaultwarden-data/_data
if [[ -f "$vw/db.sqlite3" ]]; then
  mkdir "$work/vaultwarden"
  sqlite3 "$vw/db.sqlite3" ".backup '$work/vaultwarden/db.sqlite3'"
  [[ "$(sqlite3 "$work/vaultwarden/db.sqlite3" 'PRAGMA integrity_check;')" == "ok" ]]
  for f in rsa_key.pem rsa_key.pub.pem config.json; do
    [[ ! -f "$vw/$f" ]] || cp "$vw/$f" "$work/vaultwarden/"
  done
  for d in attachments sends; do
    [[ ! -d "$vw/$d" ]] || cp -r "$vw/$d" "$work/vaultwarden/"
  done
  dirs+=(vaultwarden)
fi

# Certificados do Traefik: uma VM recriada volta com eles, sem servir o certificado
# padrão enquanto reemite e sem gastar o limite semanal do Let's Encrypt.
acme=/var/lib/docker/volumes/mgdn_traefik-acme/_data/acme.json
if [[ -s "$acme" ]]; then
  mkdir "$work/traefik"
  cp "$acme" "$work/traefik/"
  dirs+=(traefik)
fi
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
