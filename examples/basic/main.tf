# The smallest thing that produces a running DSS.
#
# Configuring what is inside it is a second root configuration; see the module
# README for why that cannot be the same apply.

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

module "dss" {
  source = "../../"

  location = var.location

  # No default: DSS should not become reachable from the internet by accident.
  allowed_cidr_blocks = var.allowed_cidr_blocks

  # Required: azurerm refuses a Linux VM with no credential at all. Nothing
  # can reach port 22 unless ssh_cidr_blocks is set, which it is not here.
  ssh_public_key = var.ssh_public_key

  # Creates nothing. It switches on the outputs describing how to reach the
  # host with az vm run-command, which is the only way to read the admin API
  # key when no SSH rule exists.
  enable_run_command = true
}

output "dss_url" {
  description = "Where DSS answers once it has finished installing, which takes several minutes on first boot."
  value       = module.dss.dss_url
}

output "session_command" {
  description = "Reads the admin API key off the host, with no key pair and no open SSH port."
  value       = module.dss.session_command
}
