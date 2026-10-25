#!/usr/bin/env python3
"""Contrato de app por labels do Compose (ADR 0015).

Os scripts de backup, restore, healthcheck e o DR drill não conhecem os apps pelo
nome: leem estes labels de cada serviço em deploy/primary/compose.yaml.

  mgdn.backup.volume   volume com os dados do app (entra no backup horário)
  mgdn.backup.ready    arquivo, relativo ao volume, que indica que há dados
                       (vazio: qualquer conteúdo); também decide o restore --if-empty
  mgdn.backup.exclude  caminhos do volume fora do backup, separados por vírgula
  mgdn.url             URL do app na tailnet (o healthcheck passa pelo Traefik)
  mgdn.port            porta do container (o DR drill sobe o app nela)
  mgdn.health          caminho HTTP que responde 2xx com o app saudável
  mgdn.summary         "<arquivo SQLite>: <SQL>" com um resumo para a issue do drill

Uso: apps.py [--compose ARQUIVO | --config-json ARQUIVO] backup|http|drill|check
  check   confere que cada mgdn.url tem rota no Traefik e nome no Blocky (CI)
  backup  TSV: serviço, volume, ponto de montagem, ready, exclude
  http    TSV: serviço, url, health (serviços com mgdn.url)
  drill   JSON por linha: serviço, imagem, ambiente, porta, health, montagem, ready, summary
"""

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_COMPOSE = os.path.join(HERE, "..", "deploy", "primary", "compose.yaml")


def load(compose):
    out = subprocess.run(
        ["docker", "compose", "-f", compose, "config", "--format", "json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)


def apps(cfg):
    volumes = cfg.get("volumes") or {}
    for name, svc in sorted((cfg.get("services") or {}).items()):
        labels = svc.get("labels") or {}
        app = {"service": name, "labels": labels, "image": svc.get("image", "")}
        vol = labels.get("mgdn.backup.volume")
        if vol:
            mount = next(
                (v["target"] for v in svc.get("volumes") or [] if v.get("type") == "volume" and v.get("source") == vol),
                None,
            )
            if mount is None:
                sys.exit(f"{name}: mgdn.backup.volume={vol} não está montado no serviço")
            app["volume"] = (volumes.get(vol) or {}).get("name") or f"{cfg.get('name', 'mgdn')}_{vol}"
            app["mount"] = mount
        yield app


def check(cfg, primary_dir):
    traefik = open(os.path.join(primary_dir, "traefik", "dynamic.yml")).read()
    blocky = open(os.path.join(primary_dir, "..", "common", "blocky", "config.yml")).read()
    errors = []
    for a in apps(cfg):
        lb = a["labels"]
        url = lb.get("mgdn.url")
        if not url:
            continue
        host = url.removeprefix("https://").rstrip("/")
        if not url.startswith("https://") or "/" in host:
            errors.append(f"{a['service']}: mgdn.url deve ser https://<nome> ({url})")
        if f"Host(`{host}`)" not in traefik:
            errors.append(f"{a['service']}: {host} sem router em traefik/dynamic.yml")
        if f"{host}: 100.64.0.1" not in blocky:
            errors.append(f"{a['service']}: {host} sem nome no customDNS do Blocky")
        if not lb.get("mgdn.port", "").isdigit():
            errors.append(f"{a['service']}: mgdn.port ausente ou inválido")
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compose", default=DEFAULT_COMPOSE)
    ap.add_argument("--config-json", help="saída de `docker compose config --format json` já pronta (testes)")
    ap.add_argument("mode", choices=["backup", "http", "drill", "check"])
    args = ap.parse_args()
    if args.config_json:
        with open(args.config_json) as f:
            cfg = json.load(f)
    else:
        cfg = load(args.compose)
    if args.mode == "check":
        sys.exit(check(cfg, os.path.dirname(os.path.abspath(args.compose))))
    for a in apps(cfg):
        lb = a["labels"]
        if args.mode == "backup" and "volume" in a:
            print("\t".join([a["service"], a["volume"], a["mount"], lb.get("mgdn.backup.ready", ""), lb.get("mgdn.backup.exclude", "")]))
        elif args.mode == "http" and lb.get("mgdn.url"):
            print("\t".join([a["service"], lb["mgdn.url"], lb.get("mgdn.health", "/")]))
        elif args.mode == "drill" and "volume" in a and lb.get("mgdn.port"):
            env = cfg["services"][a["service"]].get("environment") or {}
            print(
                json.dumps(
                    {
                        "service": a["service"],
                        "image": a["image"],
                        "environment": env,
                        "port": lb["mgdn.port"],
                        "health": lb.get("mgdn.health", "/"),
                        "mount": a["mount"],
                        "ready": lb.get("mgdn.backup.ready", ""),
                        "summary": lb.get("mgdn.summary", ""),
                    },
                    ensure_ascii=False,
                )
            )


if __name__ == "__main__":
    main()
