locals {
  dns_ports = {
    dns-udp = { protocol = "udp", port = 53, description = "DNS udp (origem filtrada no host)" }
    dns-tcp = { protocol = "tcp", port = 53, description = "DNS tcp (origem filtrada no host)" }
  }
  ssh_port = var.ssh_break_glass ? {
    ssh = { protocol = "tcp", port = 22, description = "SSH break-glass (origem filtrada no host)" }
  } : {}

  # Backup imutável em br-se1, longe da principal (ADR 0006).
  backup_env = var.backup == null ? {} : {
    BACKUP_ENDPOINT        = "https://br-se1.magaluobjects.com"
    BACKUP_REGION          = "br-se1"
    BACKUP_BUCKET          = "mgdn-platform-backup-b29a4ccd"
    BACKUP_ACCESS_KEY      = var.backup.access_key
    BACKUP_SECRET_KEY      = var.backup.secret_key
    BACKUP_AGE_IDENTITY    = var.backup.age_identity
    BACKUP_HEALTHCHECK_URL = var.backup.healthcheck_url
  }

  common_env = {
    HEALTHCHECK_URL     = var.healthcheck_url
    HOME_DDNS_HOST      = var.home_ddns_host
    EXTRA_ALLOWED_CIDRS = join(",", var.extra_allowed_cidrs)
    HEADSCALE_HOSTNAME  = var.headscale_hostname
  }
}

module "primary" {
  source    = "./modules/host"
  providers = { mgc = mgc.ne1 }

  name         = "mgdn-primary"
  role         = "primary"
  machine_type = "BV2-2-10"
  ssh_key_name = var.ssh_key_name
  repo_url     = var.repo_url
  repo_branch  = var.repo_branch
  env          = merge(local.common_env, local.backup_env, { ALERT_NTFY_URL = var.alert_ntfy_url })

  public_ports = merge(local.dns_ports, local.ssh_port, {
    acme  = { protocol = "tcp", port = 80, description = "ACME HTTP-01 (Let's Encrypt)" }
    https = { protocol = "tcp", port = 443, description = "Headscale (autenticado)" }
  })

  # Backup e restore do Headscale (ADR 0006).
  extra_packages = ["age", "sqlite3"]

  # O próprio host fala com o Headscale local sem depender de hairpin NAT.
  etc_hosts = { (var.headscale_hostname) = "127.0.0.1" }
}

module "secondary" {
  source    = "./modules/host"
  providers = { mgc = mgc.se1 }

  name         = "mgdn-secondary"
  role         = "secondary"
  machine_type = "BV1-1-10"
  ssh_key_name = var.ssh_key_name
  repo_url     = var.repo_url
  repo_branch  = var.repo_branch
  env = merge(local.common_env, {
    HEALTHCHECK_URL = var.secondary_healthcheck_url
    TAILNET_AUTHKEY = var.secondary_tailnet_authkey
  })

  public_ports = merge(local.dns_ports, local.ssh_port)
}

# IP público herdado do blocky-cloud-dns (ADR 0004): o roteador de casa não muda.
import {
  to = module.primary.mgc_network_public_ips.this
  id = "22ace1e5-1872-469b-9979-49148a8d4dad"
}
