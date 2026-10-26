#!/usr/bin/env bash
# Gera (ou troca) a chave SSH do host de um papel (ADR 0014): a privada vai cifrada
# para secrets/<papel>.env.age e a pública para deploy/ssh/known_hosts, que o
# Makefile usa com verificação estrita. A VM instala a chave no próximo deploy e a
# mantém nas recriações, então o aviso "REMOTE HOST IDENTIFICATION HAS CHANGED" só
# aparece se alguém de fato trocar a chave.
#
# Uso: ssh-hostkey.sh <primary|secondary>
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
known=$repo/deploy/ssh/known_hosts
role=${1:-}
# Nomes pelos quais o host é acessado: MagicDNS, IP na tailnet e IP público (break-glass).
case "$role" in
primary) names="mgdn-primary,100.64.0.1,201.23.0.88" ;;
secondary) names="mgdn-secondary,100.64.0.4,201.23.18.247" ;;
*)
  echo "uso: ssh-hostkey.sh <primary|secondary>" >&2
  exit 2
  ;;
esac

work=$(umask 077 && mktemp -d "${XDG_RUNTIME_DIR:-/dev/shm}/mgdn-hostkey.XXXXXX")
trap 'rm -rf "$work"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "root@mgdn-$role" -f "$work/key"
base64 -w0 "$work/key" | "$repo/scripts/secrets.sh" set "$role" SSH_HOST_ED25519_KEY_B64

touch "$known"
grep -v "^${names%%,*}," "$known" >"$work/known" || true
echo "$names $(cut -d' ' -f1,2 "$work/key.pub")" >>"$work/known"
sort -o "$known" "$work/known"
echo "[ssh-hostkey] mgdn-$role: $(ssh-keygen -lf "$work/key.pub" | awk '{print $2}'); abra um PR com secrets/$role.env.age e deploy/ssh/known_hosts"
