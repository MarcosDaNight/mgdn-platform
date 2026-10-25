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






run "headscale_no_dominio_proprio" {
  command = plan

  assert {
    condition     = cloudflare_dns_record.headscale.name == "headscale.mgdn.com.br" && cloudflare_dns_record.headscale.proxied == false
    error_message = "headscale.mgdn.com.br deve ser só DNS (sem proxy da Cloudflare): o Tailscale não passa pelo proxy HTTP."
  }
}

# Regressão (PR #10): pacotes no cloud-init compartilhado recriariam as duas VMs juntas.
run "pacotes_extras_so_na_principal" {
  command = plan

  assert {
    condition     = strcontains(module.primary.cloud_init, "  - sqlite3\n")
    error_message = "A principal precisa do sqlite3 (backup dos SQLite)."
  }
  assert {
    condition     = !strcontains(module.secondary.cloud_init, "  - sqlite3\n")
    error_message = "A secundária não pode receber os pacotes da principal."
  }
  assert {
    condition     = strcontains(module.primary.cloud_init, "  - age\n") && strcontains(module.secondary.cloud_init, "  - age\n")
    error_message = "As duas VMs precisam do age para decifrar os segredos (ADR 0014)."
  }
}

# ADR 0014: segredos chegam cifrados pelo GitOps, nunca pelo cloud-init. Trocar um
# segredo não pode recriar VM.
run "segredos_fora_do_cloud_init" {
  command = plan
  variables {
    cloudflare_api_token = "token-de-teste"
  }

  assert {
    condition = alltrue([for c in [module.primary.cloud_init, module.secondary.cloud_init] :
    !strcontains(c, "token-de-teste") && !strcontains(c, "BACKUP_") && !strcontains(c, "HEALTHCHECK_URL") && !strcontains(c, "ALERT_") && !strcontains(c, "HOME_DDNS_HOST")])
    error_message = "Nenhum segredo pode ir no cloud-init: eles ficam em secrets/<papel>.env.age."
  }
}

run "chave_age_de_cada_host" {
  command = plan
  variables {
    host_age_keys = {
      primary   = "AGE-SECRET-KEY-1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      secondary = "AGE-SECRET-KEY-1BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    }
  }

  assert {
    condition     = strcontains(module.primary.cloud_init, "/etc/mgdn-platform/age.key") && strcontains(module.primary.cloud_init, "AGE-SECRET-KEY-1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    error_message = "A principal deve receber a própria chave age."
  }
  assert {
    condition     = !strcontains(module.primary.cloud_init, "AGE-SECRET-KEY-1BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB") && !strcontains(module.secondary.cloud_init, "AGE-SECRET-KEY-1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    error_message = "Cada host recebe só a própria chave: a secundária não decifra os segredos da principal."
  }
}

run "sem_chave_age_sem_arquivo" {
  command = plan

  assert {
    condition     = !strcontains(module.primary.cloud_init, "age.key") && !strcontains(module.secondary.cloud_init, "age.key")
    error_message = "Sem host_age_keys, o cloud-init não grava chave."
  }
}

run "rejeita_chave_age_invalida" {
  command = plan
  variables {
    host_age_keys = { primary = "não é chave" }
  }
  expect_failures = [var.host_age_keys]
}

run "rejeita_papel_desconhecido" {
  command = plan
  variables {
    host_age_keys = { terceira = "AGE-SECRET-KEY-1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
  }
  expect_failures = [var.host_age_keys]
}
