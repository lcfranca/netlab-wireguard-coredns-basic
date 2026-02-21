variable "server_public_ip" {
  description = "Public IP or DNS name of the WireGuard server"
  type        = string
}

variable "server_ssh_user" {
  description = "SSH user used by Ansible"
  type        = string
  default     = "ubuntu"
}

variable "server_ssh_port" {
  description = "SSH port for the WireGuard server"
  type        = number
  default     = 22
}

variable "server_ssh_private_key_file" {
  description = "Path to SSH private key used by Ansible for server login"
  type        = string
  default     = ""
}

variable "client_hosts" {
  description = "Client hosts for Ansible inventory"
  type = list(object({
    name                 = string
    ansible_ip           = string
    ssh_user             = optional(string, "ubuntu")
    ssh_port             = optional(number, 22)
    ssh_private_key_file = optional(string, "")
  }))
  default = []
}

variable "wireguard_subnet" {
  description = "WireGuard private subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "wireguard_server_ip" {
  description = "Server private VPN IP"
  type        = string
  default     = "10.0.0.1"
}

variable "dns_zone" {
  description = "Private DNS zone managed by CoreDNS"
  type        = string
  default     = "intranet.local"
}

variable "service_hostname" {
  description = "Internal DNS hostname for the containerized service"
  type        = string
  default     = "service1.intranet.local"
}

variable "service_container_image" {
  description = "Container image/tag to deploy as internal service"
  type        = string
  default     = "netlab/service1:latest"
}

variable "coredns_image" {
  description = "CoreDNS image/tag"
  type        = string
  default     = "coredns/coredns:1.12.0"
}
