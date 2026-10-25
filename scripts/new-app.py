#!/usr/bin/env python3
"""Gera um app novo na VM principal, só pela tailnet (docs/adicionar-app.md, ADR 0015).

Edita, no mesmo padrão do Vaultwarden e do Actual Budget:
  deploy/primary/compose.yaml        serviço (imagem por digest, mem_limit, labels mgdn.*) e volume
  deploy/primary/traefik/dynamic.yml router com tailnet-only + security-headers, e service
  deploy/common/blocky/config.yml    nome só da tailnet no customDNS (split-horizon)

Com --data, o volume entra sozinho no backup horário, no restore de VM nova e no DR
drill, pelos labels. Sem --data, o app não guarda estado.

Uso: new-app.py NOME IMAGEM PORTA [--data /caminho] [--health /caminho] [--ready ARQ]
                [--mem 256m] [--root DIR]
  IMAGEM sem @sha256 tem o digest resolvido no registro (Docker Hub, ghcr.io, quay.io...).
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

DOMAIN = "mgdn.com.br"
TAILNET_IP = "100.64.0.1"
# RAM da principal (BV2-2-10) que os mem_limit podem somar, com folga para o host.
RAM_BUDGET_MB = 1800

MANIFEST_TYPES = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


def die(msg):
    sys.exit(f"[new-app] {msg}")


def split_image(image):
    name, _, tag = image.partition(":")
    if "/" in tag:  # registro com porta, ex.: host:5000/img
        die("use IMAGEM no formato [registro/]nome:tag")
    tag = tag or "latest"
    first = name.split("/")[0]
    if "." in first or ":" in first:
        registry, repo = first, name[len(first) + 1 :]
    else:
        registry, repo = "registry-1.docker.io", name if "/" in name else f"library/{name}"
    return registry, repo, tag


def resolve_digest(image):
    """Digest do índice multi-arch (o mesmo que o docker usaria) por HEAD no manifest."""
    registry, repo, tag = split_image(image)
    url = f"https://{registry}/v2/{repo}/manifests/{tag}"
    headers = {"Accept": MANIFEST_TYPES}
    for _ in range(2):
        req = urllib.request.Request(url, method="HEAD", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                digest = r.headers.get("Docker-Content-Digest")
                if not digest:
                    die(f"{registry} não devolveu o digest de {image}")
                return digest
        except urllib.error.HTTPError as e:
            auth = e.headers.get("WWW-Authenticate", "")
            if e.code != 401 or not auth.startswith("Bearer "):
                die(f"{image}: HTTP {e.code} em {url}")
            params = dict(re.findall(r'(\w+)="([^"]*)"', auth))
            q = "&".join(f"{k}={params[k]}" for k in ("service", "scope") if k in params)
            with urllib.request.urlopen(f"{params['realm']}?{q}", timeout=20) as r:
                tok = json.load(r)
            headers["Authorization"] = f"Bearer {tok.get('token') or tok.get('access_token')}"
    die(f"não consegui autenticar em {registry}")


def mem_mb(value):
    m = re.fullmatch(r"(\d+)([kmg])?b?", str(value).lower())
    if not m:
        return 0
    n, unit = int(m.group(1)), m.group(2) or ""
    return {"k": n / 1024, "m": n, "g": n * 1024}.get(unit, n / 1024 / 1024)


def insert_before(text, anchor, block, what):
    i = text.find(anchor)
    if i < 0:
        die(f"não achei {what} ({anchor.strip()!r})")
    return text[:i] + block + text[i:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name")
    ap.add_argument("image")
    ap.add_argument("port", type=int)
    ap.add_argument("--data", help="diretório de dados no container (vira volume com backup)")
    ap.add_argument("--health", default="/", help="caminho HTTP de saúde (padrão: /)")
    ap.add_argument("--ready", default="", help="arquivo do volume que indica que há dados (padrão: qualquer conteúdo)")
    ap.add_argument("--mem", default="256m", help="mem_limit (padrão: 256m)")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    a = ap.parse_args()

    if not re.fullmatch(r"[a-z][a-z0-9-]{1,30}", a.name):
        die("NOME: letras minúsculas, números e hífen, começando por letra")
    if not a.health.startswith("/"):
        die("--health deve começar com /")
    if mem_mb(a.mem) <= 0:
        die("--mem no formato 256m ou 1g")

    compose_p = os.path.join(a.root, "deploy/primary/compose.yaml")
    traefik_p = os.path.join(a.root, "deploy/primary/traefik/dynamic.yml")
    blocky_p = os.path.join(a.root, "deploy/common/blocky/config.yml")
    compose, traefik, blocky = (open(p).read() for p in (compose_p, traefik_p, blocky_p))
    host = f"{a.name}.{DOMAIN}"

    if re.search(rf"^  {re.escape(a.name)}:\s*$", compose, re.M):
        die(f"o serviço {a.name} já existe em compose.yaml")
    if host in blocky or f"Host(`{host}`)" in traefik:
        die(f"{host} já está em uso")

    image = a.image
    if "@sha256:" not in image:
        image = f"{image}@{resolve_digest(image)}"
        print(f"[new-app] digest resolvido: {image}")

    used = sum(mem_mb(v) for v in re.findall(r"^\s+mem_limit:\s*(\S+)", compose, re.M))
    total = used + mem_mb(a.mem)
    if total > RAM_BUDGET_MB:
        print(f"[new-app] AVISO: os mem_limit somariam {total:.0f} MB, acima de {RAM_BUDGET_MB} MB da principal")

    vol = f"{a.name}-data"
    labels = [
        f"      mgdn.url: https://{host}",
        f'      mgdn.port: "{a.port}"',
        f"      mgdn.health: {a.health}",
    ]
    volumes = ""
    if a.data:
        labels += [f"      mgdn.backup.volume: {vol}"]
        if a.ready:
            labels += [f"      mgdn.backup.ready: {a.ready}"]
        volumes = f"    volumes:\n      - {vol}:{a.data}\n"
    service = (
        f"  # Gerado por `make new-app` (docs/adicionar-app.md). Só pela tailnet.\n"
        f"  {a.name}:\n"
        f"    image: {image}\n"
        f"    restart: unless-stopped\n"
        f"{volumes}"
        f"    labels:\n" + "\n".join(labels) + "\n"
        f"    mem_limit: {a.mem}\n\n"
    )
    compose = insert_before(compose, "\nvolumes:\n", "\n" + service.rstrip("\n") + "\n", "a seção volumes do compose")
    if a.data:
        compose = compose.rstrip("\n") + f"\n  {vol}:\n"

    router = (
        f"    {a.name}:\n"
        f"      rule: Host(`{host}`)\n"
        f"      entryPoints: [websecure]\n"
        f"      service: {a.name}\n"
        f"      middlewares: [tailnet-only, security-headers]\n"
        f"      tls:\n"
        f"        certResolver: cloudflare\n"
    )
    traefik = insert_before(traefik, "\n\n  middlewares:\n", "\n" + router.rstrip("\n"), "os middlewares do Traefik")
    traefik = traefik.rstrip("\n") + (
        f"\n    {a.name}:\n      loadBalancer:\n        servers:\n          - url: http://{a.name}:{a.port}\n"
    )

    mapping = list(re.finditer(rf"^    \S+: {re.escape(TAILNET_IP)}\n", blocky, re.M))
    if not mapping:
        die("não achei o customDNS do Blocky")
    end = mapping[-1].end()
    blocky = blocky[:end] + f"    {host}: {TAILNET_IP}\n" + blocky[end:]

    for p, text in ((compose_p, compose), (traefik_p, traefik), (blocky_p, blocky)):
        with open(p, "w") as f:
            f.write(text)

    print(
        f"""[new-app] {a.name} gerado em https://{host} (só pela tailnet).
Próximos passos:
  1. Revise o diff: variáveis de ambiente do app vão no serviço, em compose.yaml.
  2. Precisa de segredo? make secrets-set ROLE=primary KEY=<CHAVE> (ADR 0014).
  3. Abra o PR: o CI valida, o Trivy escaneia a imagem e o Dependabot passa a acompanhá-la.
  4. Depois do merge: https://{host} pela tailnet em até ~2 min."""
        + ("\n  O volume entra no backup, no restore de VM nova e no DR drill pelos labels." if a.data else "")
    )


if __name__ == "__main__":
    main()
