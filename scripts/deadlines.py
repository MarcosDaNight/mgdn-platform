#!/usr/bin/env python3
"""Prazos como código (.github/deadlines.yml).

Uso:
  deadlines.py --check           valida o arquivo (CI)
  deadlines.py --due [--today D] imprime em JSON os prazos dentro da janela de aviso

O YAML é lido pelo `yq` (presente nos runners do GitHub), para não depender de
bibliotecas Python fora da padrão.
"""

import argparse
import datetime as dt
import json
import subprocess
import sys

FILE = ".github/deadlines.yml"
DEFAULT_WARN_DAYS = 30


def load(path):
    out = subprocess.run(["yq", "-o=json", ".", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out) or []


def validate(items):
    errors = []
    names = set()
    for i, it in enumerate(items):
        where = f"item {i + 1}"
        if not isinstance(it, dict):
            errors.append(f"{where}: deve ser um mapa")
            continue
        unknown = set(it) - {"name", "expires", "warn_days", "renew"}
        if unknown:
            errors.append(f"{where}: campos desconhecidos {sorted(unknown)}")
        name = it.get("name")
        if not name:
            errors.append(f"{where}: falta name")
        elif name in names:
            errors.append(f"{where}: name repetido ({name})")
        names.add(name)
        try:
            dt.date.fromisoformat(str(it.get("expires")))
        except ValueError:
            errors.append(f"{where} ({name}): expires deve ser AAAA-MM-DD")
        wd = it.get("warn_days", DEFAULT_WARN_DAYS)
        if not isinstance(wd, int) or wd < 1:
            errors.append(f"{where} ({name}): warn_days deve ser um inteiro positivo")
        if not it.get("renew"):
            errors.append(f"{where} ({name}): falta renew")
    return errors


def due(items, today):
    result = []
    for it in items:
        expires = dt.date.fromisoformat(str(it["expires"]))
        left = (expires - today).days
        if left <= it.get("warn_days", DEFAULT_WARN_DAYS):
            result.append({"name": it["name"], "expires": expires.isoformat(), "days_left": left, "renew": it["renew"]})
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--due", action="store_true")
    ap.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today())
    ap.add_argument("--file", default=FILE)
    args = ap.parse_args()
    items = load(args.file)
    errors = validate(items)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if args.due:
        print(json.dumps(due(items, args.today), ensure_ascii=False))
    elif args.check:
        print(f"{len(items)} prazo(s) válidos")
    return 0


if __name__ == "__main__":
    sys.exit(main())
