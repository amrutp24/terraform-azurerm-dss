variable "name" {
  description = "Name applied to the VM and its networking."
  type        = string
  default     = "dataiku-dss"
}

variable "resource_group_name" {
  description = "Resource group to create. Everything here goes in it, so destroying is clean."
  type        = string
  default     = "dataiku-dss"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "vm_size" {
  description = <<-EOT
    VM size. DSS drops into a low-memory mode below roughly 16 GB and says so
    in its logs, so Standard_D4s_v5 is about the smallest that behaves
    normally.
  EOT
  type        = string
  default     = "Standard_D4s_v5"
}

variable "ssh_public_key" {
  description = "SSH public key for the admin user. Required: password authentication is disabled."
  type        = string
}

variable "admin_username" {
  description = "Admin user on the VM. Not the DSS admin, which is separate."
  type        = string
  default     = "azureuser"
}

variable "allowed_cidr_blocks" {
  description = <<-EOT
    Who may reach the DSS port. Deliberately has no default: DSS holds your
    data and its login page would otherwise be open to the internet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidr_blocks) > 0
    error_message = "Name at least one CIDR block that should reach DSS."
  }

  validation {
    condition     = !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes DSS to the whole internet. Use your own range, or edit this validation if you genuinely mean it."
  }
}

variable "ssh_cidr_blocks" {
  description = "Who may reach SSH. Null creates no SSH rule at all."
  type        = list(string)
  default     = null
}

variable "vnet_cidr" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "Address range for the subnet the VM sits in."
  type        = string
  default     = "10.42.1.0/24"
}

variable "assign_public_ip" {
  description = "Give the VM a public address. False needs a route of your own -- VPN or ExpressRoute."
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  description = "OS disk size. DSS itself is about 10 GB unpacked; the rest is your projects and code environments."
  type        = number
  default     = 100
}

variable "dss_version" {
  description = "DSS version to install."
  type        = string
  default     = "15.0.0"
}

variable "dss_port" {
  description = "Port DSS listens on."
  type        = number
  default     = 10000
}

variable "data_dir" {
  description = "DSS data directory on the VM."
  type        = string
  default     = "/data/dataiku/dss_data"
}

variable "license_json" {
  description = "Contents of a DSS licence file, applied at install time. Reaches custom_data and Terraform state, so pass it from a secret store."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to everything created here."
  type        = map(string)
  default     = {}
}
