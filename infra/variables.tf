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

variable "home_ddns_host" {
  description = "Hostname DDNS mantido pelo roteador de casa; só esse IP (e os extras) alcança o DNS público (53)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.home_ddns_host))
    error_message = "home_ddns_host deve ser um hostname (ex.: minha-casa.ddns.net)."
  }
}

variable "extra_allowed_cidrs" {
  description = "CIDRs IPv4 fixos liberados além do IP de casa (ex.: break-glass)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.extra_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "extra_allowed_cidrs deve conter CIDRs IPv4 (ex.: 198.51.100.7/32)."
  }
}

variable "headscale_hostname" {
  description = "LEGADO: só lido na criação da VM. O valor efetivo vem de deploy/common/platform.env (GitOps, ADR 0010). Remover na próxima recriação planejada das VMs."
  type        = string
  default     = "mgdn-platform.duckdns.org"
}

variable "ssh_break_glass" {
  description = "Abre a porta 22 no security group (ainda filtrada pelo allowlist do host). Use só se a tailnet estiver fora."
  type        = bool
  default     = false
}

variable "healthcheck_url" {
  description = "URL de ping do healthchecks.io da VM principal. Vazio desativa."
  type        = string
  default     = ""
  sensitive   = true
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

variable "alert_ntfy_url" {
  description = "URL do tópico ntfy que recebe os alertas do Alertmanager (ex.: https://ntfy.sh/<tópico-aleatório>?template=alertmanager). Vazio desativa (ADR 0009)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "secondary_healthcheck_url" {
  description = "URL de ping do healthchecks.io da VM secundária (check próprio, ADR 0005). Vazio desativa."
  type        = string
  default     = ""
  sensitive   = true
}

variable "secondary_tailnet_authkey" {
  description = "Chave de uso único (make tailnet-key) para a secundária entrar na tailnet no primeiro boot. Só é lida na criação da VM."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup" {
  description = "Backup do Headscale (ADR 0006): credenciais da chave mgdn-backup (object-storage read/write), identidade age (linha AGE-SECRET-KEY-...) para o restore automático e URL opcional do healthchecks.io."
  type = object({
    access_key      = string
    secret_key      = string
    age_identity    = string
    healthcheck_url = optional(string, "")
  })
  default   = null
  sensitive = true
}
