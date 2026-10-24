output "primary_ip" {
  description = "IP público da VM principal (DNS primário do roteador)."
  value       = module.primary.public_ip
}

output "headscale_url" {
  description = "URL do Headscale para os clientes Tailscale."
  value       = "https://${var.headscale_hostname}"
}
