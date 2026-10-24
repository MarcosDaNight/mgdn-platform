# Uma VM da plataforma: security group (só portas; a origem é filtrada no host),
# IP público dedicado (sobrevive a recriações da VM) e cloud-init mínimo que
# entrega o controle ao GitOps do repositório.

terraform {
  required_providers {
    mgc = {
      source = "magalucloud/mgc"
    }
  }
}

data "mgc_network_vpcs" "all" {}

locals {
  vpc_id = one([for v in data.mgc_network_vpcs.all.items : v.id if v.name == "vpc_default"])
}

resource "mgc_network_security_groups" "this" {
  name                  = "${var.name}-sg"
  description           = "${var.name}: portas publicas, origem filtrada no host"
  disable_default_rules = true
}

resource "mgc_network_security_groups_rules" "egress" {
  for_each = toset(["IPv4", "IPv6"])

  security_group_id = mgc_network_security_groups.this.id
  description       = "Saida liberada"
  direction         = "egress"
  ethertype         = each.key
  remote_ip_prefix  = each.key == "IPv4" ? "0.0.0.0/0" : "::/0"
}

resource "mgc_network_security_groups_rules" "ingress" {
  for_each = var.public_ports

  security_group_id = mgc_network_security_groups.this.id
  description       = each.value.description
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = "0.0.0.0/0"
}

resource "mgc_network_public_ips" "this" {
  vpc_id      = local.vpc_id
  description = "${var.name} DNS"

  lifecycle {
    # É o DNS configurado no roteador de casa: nunca destruir por acidente.
    # Para remover de propósito, apague esta linha num PR próprio.
    prevent_destroy = true
    # O provider não atualiza a descrição in-place e o import não preenche o
    # vpc_id; os dois forçariam recriar um IP importado (ADR 0004).
    ignore_changes = [description, vpc_id]
  }
}

resource "mgc_virtual_machine_instances" "this" {
  name                     = var.name
  machine_type             = var.machine_type
  image                    = var.image
  ssh_key_name             = var.ssh_key_name
  vpc_id                   = local.vpc_id
  allocate_public_ipv4     = false
  creation_security_groups = [mgc_network_security_groups.this.id]

  user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    env = merge(var.env, {
      ROLE        = var.role
      REPO_URL    = var.repo_url
      REPO_BRANCH = var.repo_branch
    })
    repo_url    = var.repo_url
    repo_branch = var.repo_branch
    hosts       = var.etc_hosts
  }))
}

resource "mgc_network_public_ips_attach" "this" {
  public_ip_id = mgc_network_public_ips.this.id
  interface_id = one([for n in mgc_virtual_machine_instances.this.network_interfaces : n.id if n.primary])
}
