variable "name" {
  description = "Nome da VM e prefixo dos recursos."
  type        = string
}

variable "vpc_id" {
  description = "VPC da VM. Vazio usa a VPC default da região."
  type        = string
  default     = null
}

variable "role" {
  description = "Papel do host no GitOps: aplica deploy/<role>/compose.yaml."
  type        = string

  validation {
    condition     = contains(["primary", "secondary"], var.role)
    error_message = "role deve ser primary ou secondary."
  }
}

variable "machine_type" {
  description = "Tipo da VM (ex.: BV2-2-10)."
  type        = string
}

variable "image" {
  description = "Imagem do SO."
  type        = string
  default     = "cloud-ubuntu-24.04 LTS"
}

variable "ssh_key_name" {
  description = "Chave SSH cadastrada na Magalu Cloud."
  type        = string
}

variable "public_ports" {
  description = "Portas abertas a todos no security group. A origem é filtrada no host (scripts/allowlist.sh) ou pelo próprio serviço."
  type = map(object({
    protocol    = string
    port        = number
    description = string
  }))
}

variable "env" {
  description = "Variáveis não secretas gravadas em /etc/mgdn-platform/env (lidas pelos scripts do GitOps). Segredos vão em secrets/<papel>.env.age (ADR 0014)."
  type        = map(string)
  default     = {}
}


variable "repo_url" {
  description = "Repositório Git acompanhado pelo GitOps."
  type        = string
}

variable "repo_branch" {
  description = "Branch acompanhada pelo GitOps."
  type        = string
}

variable "extra_packages" {
  description = "Pacotes apt adicionais só deste host. Mudar a lista altera o cloud-init e recria a VM."
  type        = list(string)
  default     = []
}

variable "age_key" {
  description = "Chave privada age do host (AGE-SECRET-KEY-1...), gravada em /etc/mgdn-platform/age.key para o GitOps decifrar secrets/<papel>.env.age (ADR 0014). Vazio: o host segue só com o env."
  type        = string
  default     = ""
  sensitive   = true
}
