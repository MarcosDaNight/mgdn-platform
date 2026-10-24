# Zona mgdn.com.br na Cloudflare (ADR 0010). Todos os registros como código, sem proxy
# (nuvem cinza): a Cloudflare só responde DNS, o tráfego vai direto para as VMs.
#
# Nomes só da tailnet (ex.: vault) NÃO entram aqui: existem apenas no Blocky
# (customDNS, split-horizon), então não aparecem no DNS público.

locals {
  zone_id = "7f69f8be82de025264eaff4739e70f66"
}

resource "cloudflare_dns_record" "headscale" {
  zone_id = local.zone_id
  name    = "headscale.mgdn.com.br"
  type    = "A"
  content = module.primary.public_ip
  ttl     = 300
  proxied = false
  comment = "Headscale (mgdn-platform, gerenciado pelo Terraform)"
}

# --- Domínio sem e-mail: impede que seja usado para spoofing ---------------------
# Registros padrão do registro.br, importados como estavam.

resource "cloudflare_dns_record" "null_mx" {
  zone_id  = local.zone_id
  name     = "mgdn.com.br"
  type     = "MX"
  content  = "."
  priority = 0
  ttl      = 1
}

resource "cloudflare_dns_record" "spf" {
  zone_id = local.zone_id
  name    = "mgdn.com.br"
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 1
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = local.zone_id
  name    = "_dmarc.mgdn.com.br"
  type    = "TXT"
  content = "\"v=DMARC1; p=reject;\""
  ttl     = 1
}

import {
  to = cloudflare_dns_record.null_mx
  id = "7f69f8be82de025264eaff4739e70f66/d72b663ca20808faf637f5cd886befd8"
}

import {
  to = cloudflare_dns_record.spf
  id = "7f69f8be82de025264eaff4739e70f66/b5b7c43f7089303891f419c294886e77"
}

import {
  to = cloudflare_dns_record.dmarc
  id = "7f69f8be82de025264eaff4739e70f66/1c3bced9259697450bc61341a0d439fd"
}
