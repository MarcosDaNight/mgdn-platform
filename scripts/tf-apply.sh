#!/usr/bin/env bash
# `make apply` seguro por padrão: planeja, mostra o que muda e, se a VM principal for
# recriada, roda o `make headscale-drain` antes de aplicar o MESMO plano. Se o apply
# falhar com a VM antiga ainda de pé, desfaz o drain.
#
# Executado pelo Makefile dentro de infra/, com as credenciais do .env já no ambiente.
set -euo pipefail

tf=${TF:-terraform}
plan=tfplan
trap 'rm -f "$plan"' EXIT

$tf plan -input=false -out="$plan"

# Só endereços e ações, sem valores.
read -r replace_primary risky < <($tf show -json "$plan" | python3 -c '
import json, sys
p = json.load(sys.stdin)
risky, primary = [], False
for r in p.get("resource_changes", []):
    a = set(r["change"]["actions"])
    if "delete" in a and any(t in r["address"] for t in ("virtual_machine", "public_ips")):
        risky.append(r["address"])
        primary |= r["address"].startswith("module.primary.mgc_virtual_machine_instances")
print("yes" if primary else "no", ",".join(risky) or "-")
')

if [[ "$risky" != "-" ]]; then
  echo
  echo "⚠️  Recria ou remove: ${risky//,/ }"
  [[ "$replace_primary" == "yes" ]] && echo "   A VM principal será recriada: o drain do Headscale roda antes do apply."
fi
echo
read -rp "Aplicar este plano? [s/N] " ok
[[ "$ok" =~ ^[sS]$ ]] || {
  echo "nada foi aplicado"
  exit 1
}

drained=false
if [[ "$replace_primary" == "yes" ]]; then
  make -C .. --no-print-directory headscale-drain
  drained=true
fi

if ! $tf apply -input=false "$plan"; then
  if $drained; then
    echo "apply falhou; desfazendo o drain na VM principal (se ela ainda existir)"
    make -C .. --no-print-directory headscale-undrain || echo "não consegui desfazer: rode 'make headscale-undrain' quando a VM responder"
  fi
  exit 1
fi
