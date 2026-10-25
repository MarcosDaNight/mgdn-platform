locals {
  dns_ports = {
    dns-udp = { protocol = "udp", port = 53, description = "DNS udp (origem filtrada no host)" }
    dns-tcp = { protocol = "tcp", port = 53, description = "DNS tcp (origem filtrada no host)" }
  }
  ssh_port = var.ssh_break_glass ? {
    ssh = { protocol = "tcp", port = 22, description = "SSH break-glass (origem filtrada no host)" }
  } : {}
}

# Segredos (tokens, URLs de ping, credenciais do backup, IP de casa) não passam
# por aqui: ficam cifrados em secrets/<papel>.env.age e chegam pelo GitOps (ADR 0014).
# O cloud-init leva só a chave age de cada host, então trocar um segredo não recria
# a VM.

module "primary" {
  source    = "./modules/host"
  providers = { mgc = mgc.ne1 }

  name         = "mgdn-primary"
  role         = "primary"
  vpc_id       = lookup(var.vpc_ids, "ne1", null)
  machine_type = "BV2-2-10"
  ssh_key_name = var.ssh_key_name
  repo_url     = var.repo_url
  repo_branch  = var.repo_branch
  age_key      = lookup(var.host_age_keys, "primary", "")

  # Certificados por DNS-01/TLS-ALPN no Traefik: a porta 80 não é mais necessária.
  public_ports = merge(local.dns_ports, local.ssh_port, {
    https = { protocol = "tcp", port = 443, description = "Traefik: Headscale (autenticado) e apps da tailnet" }
  })

  # Backup e restore dos SQLite (ADR 0006).
  extra_packages = ["sqlite3"]
}

module "secondary" {
  source    = "./modules/host"
  providers = { mgc = mgc.se1 }

  name         = "mgdn-secondary"
  role         = "secondary"
  vpc_id       = lookup(var.vpc_ids, "se1", null)
  machine_type = "BV1-1-10"
  ssh_key_name = var.ssh_key_name
  repo_url     = var.repo_url
  repo_branch  = var.repo_branch
  age_key      = lookup(var.host_age_keys, "secondary", "")

  public_ports = merge(local.dns_ports, local.ssh_port)
}

# IP público herdado do blocky-cloud-dns (ADR 0004): o roteador de casa não muda.
import {
  to = module.primary.mgc_network_public_ips.this
  id = "22ace1e5-1872-469b-9979-49148a8d4dad"
}
