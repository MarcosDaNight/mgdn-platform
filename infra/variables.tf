variable "mgc_api_key" {
  description = "API key da Magalu Cloud (via TF_VAR_mgc_api_key no .env)."
  type        = string
  sensitive   = true
}

variable "vpc_ids" {
  description = "VPC por região (ne1, se1). Vazio usa a VPC default de cada região."
  type        = map(string)
  default     = {}
}

variable "cloudflare_api_token" {
  description = "Token da Cloudflare com Zone:Read e DNS:Edit só em mgdn.com.br (ADR 0010)."
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Chave SSH cadastrada na Magalu Cloud."
  type        = string
  default     = "mgdn-key"
}



variable "ssh_break_glass" {
  description = "Abre a porta 22 no security group (ainda filtrada pelo allowlist do host). Use só se a tailnet estiver fora."
  type        = bool
  default     = false
}

variable "repo_url" {
  description = "Repositório acompanhado pelo GitOps."
  type        = string
  default     = "https://github.com/MarcosDaNight/mgdn-platform.git"
}

variable "repo_branch" {
  description = "Branch acompanhada pelo GitOps."
  type        = string
  default     = "main"
}

variable "host_age_keys" {
  description = "Chave privada age de cada host (primary, secondary), uma linha AGE-SECRET-KEY-1... Decifra secrets/<papel>.env.age na VM (ADR 0014). Só é lida na criação da VM."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    condition     = alltrue([for k, v in var.host_age_keys : contains(["primary", "secondary"], k) && can(regex("^AGE-SECRET-KEY-1[0-9A-Z]{58}$", v))])
    error_message = "host_age_keys aceita só primary e secondary, cada uma com uma linha AGE-SECRET-KEY-1..."
  }
}
