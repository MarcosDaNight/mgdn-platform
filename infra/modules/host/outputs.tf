output "public_ip" {
  description = "IP público da VM."
  value       = mgc_network_public_ips.this.public_ip
}

output "instance_id" {
  description = "ID da VM."
  value       = mgc_virtual_machine_instances.this.id
}

output "public_port_keys" {
  description = "Chaves das portas abertas no security group (usado pelos testes)."
  value       = sort(keys(var.public_ports))
}

output "cloud_init" {
  description = "cloud-init renderizado (contém segredos; usado pelos testes)."
  value       = base64decode(mgc_virtual_machine_instances.this.user_data)
  sensitive   = true
}
