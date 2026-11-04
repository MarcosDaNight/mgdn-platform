#!/usr/bin/env bash
# Extensões oficiais do FreshRSS (repositório FreshRSS/Extensions), copiadas para
# deploy/primary/freshrss/extensions/ no commit fixado em extensions.lock. Ficam no
# repositório, e não baixadas na VM: o deploy não depende de rede nem de terceiros, e
# o que roda é exatamente o que o PR mostrou.
#
# Uso:
#   freshrss-extensions.sh sync     copia as extensões do commit fixado
#   freshrss-extensions.sh verify   falha se o diretório difere do commit fixado (CI)
# Para atualizar: troque `commit` em extensions.lock, rode `sync` e revise o diff.
# As variáveis (upstream, commit, extensions) vêm do extensions.lock.
# shellcheck disable=SC2154
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
dir=$repo/deploy/primary/freshrss
lock=$dir/extensions.lock

# shellcheck source=/dev/null
source "$lock"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "[freshrss-extensions] commit inválido em $lock (use o SHA completo, nunca uma branch)" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q "$work/up"
git -C "$work/up" fetch -q --depth 1 "$upstream" "$commit"
git -C "$work/up" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "$(git -C "$work/up" rev-parse HEAD)" == "$commit" ]] || {
  echo "[freshrss-extensions] o commit baixado não é $commit" >&2
  exit 1
}

case "${1:-}" in
sync)
  rm -rf "$dir/extensions"
  mkdir -p "$dir/extensions"
  for e in $extensions; do cp -r "$work/up/$e" "$dir/extensions/$e"; done
  echo "[freshrss-extensions] ${extensions// /, } em ${commit:0:7}"
  ;;
verify)
  # O diretório deve ter exatamente as extensões listadas, iguais às do commit.
  [[ "$(ls "$dir/extensions")" == "$(tr ' ' '\n' <<<"$extensions" | sort)" ]] ||
    { echo "[freshrss-extensions] o diretório não bate com a lista em extensions.lock" >&2; exit 1; }
  for e in $extensions; do
    diff -r "$work/up/$e" "$dir/extensions/$e" >/dev/null ||
      { echo "[freshrss-extensions] $e difere do commit ${commit:0:7}; rode 'sync'" >&2; exit 1; }
  done
  echo "[freshrss-extensions] ok: ${commit:0:7}"
  ;;
*)
  echo "uso: $0 sync|verify" >&2
  exit 2
  ;;
esac
