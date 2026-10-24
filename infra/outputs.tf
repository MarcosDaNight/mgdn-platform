output "primary_ip" {
  description = "IP público da VM principal (DNS primário do roteador)."
  value       = module.primary.public_ip
}

output "headscale_url" {
  description = "URL do Headscale para os clientes Tailscale."
  value       = "https://${var.headscale_hostname}"
}

output "secondary_ip" {
  description = "IP público da VM secundária (DNS secundário do roteador)."
  value       = module.secondary.public_ip
}
