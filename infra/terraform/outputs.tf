output "ansible_inventory_path" {
  description = "Generated Ansible inventory path"
  value       = local_file.inventory.filename
}

output "next_steps" {
  description = "Suggested workflow"
  value = [
    "Run make config to apply WireGuard, CoreDNS and Docker configuration",
    "Run make deploy to deploy/update the internal service",
    "Run make test to validate DNS and service connectivity"
  ]
}
