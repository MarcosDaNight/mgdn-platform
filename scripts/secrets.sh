#!/usr/bin/env bash
# Segredos da plataforma cifrados no repositório com age (ADR 0014).
#
# Cada papel tem um arquivo secrets/<papel>.env.age, cifrado para a chave do
# próprio host e para a chave de administração (secrets/<papel>.recipients). O
# gitops-sync decifra o arquivo na VM a cada deploy; trocar um segredo é um PR, sem
# recriar a VM.
#
# Uso (local, com a chave de administração):
#   secrets.sh edit <papel>          abre o arquivo decifrado no $EDITOR e recifra
#   secrets.sh set <papel> <CHAVE>   grava o valor lido da entrada padrão (não ecoa)
#   secrets.sh unset <papel> <CHAVE> remove a chave
#   secrets.sh keys <papel>          lista as chaves, sem os valores
#   secrets.sh host-keys             chaves dos hosts em JSON, para TF_VAR_host_age_keys
# Uso (VM e validação):
#   secrets.sh decrypt <papel> <identidade> <destino>
#   secrets.sh check <arquivo em claro>
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# Na VM (cloud-init, systemd) não há HOME: só os comandos locais usam esta chave.
admin_key=${MGDN_AGE_KEY:-${HOME:-/root}/.config/mgdn-platform/age/admin.key}

die() {
  echo "[secrets] $*" >&2
  exit 1
}

role_file() {
  [[ "$1" =~ ^(primary|secondary)$ ]] || die "papel inválido: $1 (primary ou secondary)"
  echo "$repo/secrets/$1.env.age"
}

# check <arquivo>: só linhas KEY=valor que o bash lê sem executar nada. Valores com
# caracteres especiais vão entre aspas simples. Chaves conhecidas têm formato
# conferido, para um erro de digitação não chegar à VM.
check() {
  local file=$1 n=0 line key value err=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(\'[^\']*\'|[A-Za-z0-9_./:@%+,=-]*)$ ]]; then
      echo "[secrets] linha $n: use CHAVE=valor, com aspas simples se o valor tiver caracteres especiais" >&2
      err=1
      continue
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value#\'}
    value=${value%\'}
    [[ -n "$value" ]] || continue
    case "$key" in
    *_URL)
      [[ "$value" =~ ^https://[^[:space:]]+$ ]] || {
        echo "[secrets] linha $n: $key deve começar com https://" >&2
        err=1
      }
      ;;
    HOME_DDNS_HOST)
      [[ "$value" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || {
        echo "[secrets] linha $n: HOME_DDNS_HOST deve ser um hostname" >&2
        err=1
      }
      ;;
    EXTRA_ALLOWED_CIDRS)
      [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$ ]] || {
        echo "[secrets] linha $n: EXTRA_ALLOWED_CIDRS deve ser uma lista de CIDRs IPv4 separada por vírgulas" >&2
        err=1
      }
      ;;
    BACKUP_AGE_IDENTITY)
      [[ "$value" =~ ^AGE-SECRET-KEY-1[0-9A-Z]{58}$ ]] || {
        echo "[secrets] linha $n: BACKUP_AGE_IDENTITY deve ser uma linha AGE-SECRET-KEY-1..." >&2
        err=1
      }
      ;;
    TAILSCALED_STATE_B64)
      base64 -d <<<"$value" 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || {
        echo "[secrets] linha $n: TAILSCALED_STATE_B64 deve ser o tailscaled.state em base64" >&2
        err=1
      }
      ;;
    SSH_HOST_*_KEY_B64)
      base64 -d <<<"$value" 2>/dev/null | head -1 | grep -qx -- "-----BEGIN OPENSSH PRIVATE"" KEY-----" || {
        echo "[secrets] linha $n: $key deve ser uma chave privada OpenSSH em base64" >&2
        err=1
      }
      ;;
    esac
  done <"$file"
  return "$err"
}

tmpdir() {
  local base=${XDG_RUNTIME_DIR:-/dev/shm}
  [[ -d "$base" ]] || base=/tmp
  (umask 077 && mktemp -d "$base/mgdn-secrets.XXXXXX")
}

need_admin_key() {
  [[ -r "$admin_key" ]] || die "chave de administração não encontrada em $admin_key (MGDN_AGE_KEY=<arquivo> para outro caminho)"
}

# decrypt_to <papel> <destino>: com a chave de administração; arquivo novo começa vazio.
decrypt_to() {
  local file
  file=$(role_file "$1")
  if [[ -f "$file" ]]; then
    age -d -i "$admin_key" "$file" >"$2"
  else
    : >"$2"
  fi
}

# encrypt_from <papel> <origem>: confere o formato e cifra para os destinatários.
encrypt_from() {
  local file recipients
  file=$(role_file "$1")
  recipients="$repo/secrets/$1.recipients"
  [[ -f "$recipients" ]] || die "faltam os destinatários em $recipients"
  check "$2" || die "nada foi gravado"
  age -a -R "$recipients" -o "$file.tmp" "$2"
  mv "$file.tmp" "$file"
  echo "[secrets] $file atualizado; abra um PR para aplicar" >&2
}

cmd=${1:-}
case "$cmd" in
edit)
  need_admin_key
  work=$(tmpdir)
  trap 'rm -rf "$work"' EXIT
  decrypt_to "$2" "$work/env"
  cp "$work/env" "$work/orig"
  "${EDITOR:-vi}" "$work/env"
  if cmp -s "$work/env" "$work/orig"; then
    echo "[secrets] sem mudanças" >&2
  else
    encrypt_from "$2" "$work/env"
  fi
  ;;
set)
  need_admin_key
  [[ "${3:-}" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "uso: secrets.sh set <papel> <CHAVE> (valor pela entrada padrão)"
  work=$(tmpdir)
  trap 'rm -rf "$work"' EXIT
  decrypt_to "$2" "$work/env"
  if [[ -t 0 ]]; then
    printf 'valor de %s: ' "$3" >&2
    read -rs value
    echo >&2
  else
    value=$(cat)
  fi
  [[ "$value" != *"'"* && "$value" != *$'\n'* ]] || die "o valor não pode ter aspas simples nem quebra de linha"
  grep -v "^$3=" "$work/env" >"$work/new" || true
  printf "%s='%s'\n" "$3" "$value" >>"$work/new"
  encrypt_from "$2" "$work/new"
  ;;
unset)
  need_admin_key
  work=$(tmpdir)
  trap 'rm -rf "$work"' EXIT
  decrypt_to "$2" "$work/env"
  grep -q "^$3=" "$work/env" || die "$3 não existe em $2"
  grep -v "^$3=" "$work/env" >"$work/new" || true
  encrypt_from "$2" "$work/new"
  ;;
keys)
  need_admin_key
  work=$(tmpdir)
  trap 'rm -rf "$work"' EXIT
  decrypt_to "$2" "$work/env"
  grep -oE '^[A-Z][A-Z0-9_]*' "$work/env" || true
  ;;
decrypt)
  file=$(role_file "$2")
  work=$(tmpdir)
  trap 'rm -rf "$work"' EXIT
  age -d -i "$3" "$file" >"$work/env"
  check "$work/env"
  install -m 0600 "$work/env" "$4"
  ;;
check)
  check "$2"
  ;;
host-keys)
  # Sem as duas chaves, o plano gravaria um cloud-init sem chave e recriaria as VMs
  # sem acesso aos segredos: melhor falhar.
  dir=$(dirname "$admin_key")
  for r in primary secondary; do
    [[ -r "$dir/$r.key" ]] || die "falta $dir/$r.key (chave age do host; veja o ADR 0014)"
  done
  python3 - "$dir" <<'PY'
import json, sys
d = sys.argv[1]
keys = {}
for r in ("primary", "secondary"):
    keys[r] = next(l for l in open(f"{d}/{r}.key").read().splitlines() if l.startswith("AGE-SECRET-KEY-"))
print(json.dumps(keys))
PY
  ;;
*)
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 2
  ;;
esac
