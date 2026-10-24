output "public_ip" {
  description = "IP público da VM."
  value       = mgc_network_public_ips.this.public_ip
}

output "instance_id" {
  description = "ID da VM."
  value       = mgc_virtual_machine_instances.this.id
}
