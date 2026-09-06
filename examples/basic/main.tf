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

  # Password authentication is disabled, so a key is the only way in.
  ssh_public_key = var.ssh_public_key
}

output "dss_url" {
  description = "Where DSS answers once it has finished installing, which takes several minutes on first boot."
  value       = module.dss.dss_url
}
