# Testes da infraestrutura (terraform test): rodam no CI com um provider simulado,
# sem credenciais e sem criar nada. Cobrem regressões já vividas no projeto.

mock_provider "mgc" {
  alias = "ne1"
}

mock_provider "mgc" {
  alias = "se1"
}

mock_provider "cloudflare" {}

# Registros de e-mail importados (dns.tf): mocks não importam, então são simulados.
override_resource {
  target = cloudflare_dns_record.null_mx
  values = { id = "d72b663ca20808faf637f5cd886befd8" }
}

override_resource {
  target = cloudflare_dns_record.spf
  values = { id = "b5b7c43f7089303891f419c294886e77" }
}

override_resource {
  target = cloudflare_dns_record.dmarc
  values = { id = "1c3bced9259697450bc61341a0d439fd" }
}

# Mocks não importam recursos: o IP herdado do v1 (bloco import) é simulado.
override_resource {
  target = module.primary.mgc_network_public_ips.this
  values = { id = "22ace1e5-1872-469b-9979-49148a8d4dad", public_ip = "201.23.0.88", vpc_id = "vpc-ne1" }
}

variables {
  # O mock não preenche a lista aninhada de VPCs do provider; os IDs vêm direto.
  vpc_ids              = { ne1 = "vpc-ne1", se1 = "vpc-se1" }
  mgc_api_key          = "teste"
  cloudflare_api_token = "teste"
  home_ddns_host       = "casa.exemplo.net"
}

run "portas_padrao" {
  command = plan

  assert {
    condition     = module.primary.public_port_keys == tolist(["dns-tcp", "dns-udp", "https"])
    error_message = "A principal deve abrir só DNS e HTTPS (Traefik); a 80 saiu com o DNS-01."
  }
  assert {
    condition     = module.secondary.public_port_keys == tolist(["dns-tcp", "dns-udp"])
    error_message = "A secundária deve abrir só DNS."
  }
}

run "ssh_so_com_break_glass" {
  command = plan
  variables {
    ssh_break_glass = true
  }

  assert {
    condition     = contains(module.primary.public_port_keys, "ssh") && contains(module.secondary.public_port_keys, "ssh")
    error_message = "Com ssh_break_glass a porta 22 deve abrir nas duas VMs."
  }
}

# Regressão (PR #10): pacotes no cloud-init compartilhado recriariam as duas VMs juntas.
run "pacotes_extras_so_na_principal" {
  command = plan

  assert {
    condition     = strcontains(module.primary.cloud_init, "  - age\n") && strcontains(module.primary.cloud_init, "  - sqlite3\n")
    error_message = "A principal precisa de age e sqlite3 (backup do Headscale)."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "  - age\n")
    error_message = "A secundária não pode receber os pacotes da principal."
  }
}

run "credenciais_de_backup_so_na_principal" {
  command = plan
  variables {
    backup = {
      access_key   = "AK"
      secret_key   = "SK"
      age_identity = "AGE-SECRET-KEY-1TESTE"
    }
  }

  assert {
    condition     = strcontains(module.primary.cloud_init, "BACKUP_BUCKET=mgdn-platform-backup-b29a4ccd")
    error_message = "A principal deve receber a configuração de backup."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "BACKUP_")
    error_message = "A secundária não pode receber credenciais de backup."
  }
}

run "headscale_resolve_localmente_na_principal" {
  command = plan

  assert {
    condition     = strcontains(module.primary.cloud_init, "127.0.0.1 mgdn-platform.duckdns.org")
    error_message = "A principal deve falar com o Headscale local via /etc/hosts (sem hairpin NAT)."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "127.0.0.1 mgdn-platform.duckdns.org")
    error_message = "A secundária precisa alcançar o Headscale pelo IP público."
  }
}

run "rejeita_ddns_invalido" {
  command = plan
  variables {
    home_ddns_host = "não é hostname"
  }
  expect_failures = [var.home_ddns_host]
}

run "rejeita_cidr_invalido" {
  command = plan
  variables {
    extra_allowed_cidrs = ["300.1.2.3/32"]
  }
  expect_failures = [var.extra_allowed_cidrs]
}

run "headscale_no_dominio_proprio" {
  command = plan

  assert {
    condition     = cloudflare_dns_record.headscale.name == "headscale.mgdn.com.br" && cloudflare_dns_record.headscale.proxied == false
    error_message = "headscale.mgdn.com.br deve ser só DNS (sem proxy da Cloudflare): o Tailscale não passa pelo proxy HTTP."
  }
}

run "token_da_cloudflare_so_na_principal" {
  command = plan
  variables {
    cloudflare_api_token = "token-de-teste"
  }

  assert {
    condition     = strcontains(module.primary.cloud_init, "CLOUDFLARE_DNS_TOKEN=token-de-teste")
    error_message = "O Traefik da principal precisa do token da Cloudflare (DNS-01)."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "CLOUDFLARE_DNS_TOKEN")
    error_message = "A secundária não pode receber o token da Cloudflare."
  }
}

run "watchdog_so_na_principal" {
  command = plan
  variables {
    alert_watchdog_url = "https://hc-ping.com/watchdog-de-teste"
  }

  assert {
    condition     = strcontains(module.primary.cloud_init, "ALERT_WATCHDOG_URL=https://hc-ping.com/watchdog-de-teste")
    error_message = "O Alertmanager da principal precisa da URL do Watchdog (ADR 0013)."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "ALERT_WATCHDOG_URL")
    error_message = "A secundária não roda Alertmanager e não pode receber a URL do Watchdog."
  }
}
