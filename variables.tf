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
  description = <<-EOT
    SSH public key for the admin user. Required, and unavoidably so: with
    password authentication disabled the azurerm provider refuses a Linux VM
    carrying no credential at all, and it refuses it during apply rather than
    during plan, so there is no keyless configuration of this module that gets
    further than a failed create.

    Having a key is not the same as using one. Leave ssh_cidr_blocks unset and
    port 22 is closed to everyone, the key is never reachable, and
    enable_run_command is how you get onto the host. A throwaway key whose
    private half you discard is a reasonable thing to pass here.
  EOT
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
  description = "Who may reach SSH. Null creates no SSH rule at all, which is fine if you set enable_run_command or never need a shell."
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
  description = "Give the VM a public address. False needs a route of your own: VPN or ExpressRoute."
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

variable "license_key_vault_secret_id" {
  description = <<-EOT
    Key Vault secret id of a DSS licence, which the VM reads for itself at
    boot. The data-plane id, as the portal shows it and as
    azurerm_key_vault_secret.id returns it:

      https://example-vault.vault.azure.net/secrets/dss-license

    A version may be pinned on the end; without one the VM reads the current
    version at every boot.

    Prefer this over license_json. license_json is rendered into the
    cloud-config, so it reaches Terraform state and the VM's custom_data,
    where anyone who can read the VM can read it back. This puts only the
    secret's id in both places.

    Setting this creates a user-assigned managed identity, and with
    license_key_vault_id set, a Key Vault Secrets User assignment scoped to
    this one secret. The VM needs an identity whether or not this module
    grants it anything, because the identity is what the token comes from.

    license_json wins if you set both.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.license_key_vault_secret_id == null || can(regex("^https://[a-zA-Z0-9-]+\\.[a-z0-9.-]+/secrets/[a-zA-Z0-9-]+(/[a-z0-9]+)?$", var.license_key_vault_secret_id))
    error_message = "license_key_vault_secret_id must be a Key Vault secret id such as https://example-vault.vault.azure.net/secrets/dss-license, optionally with a version. It is interpolated into a command that runs on the VM, and the secret name is parsed out of it for the role assignment scope."
  }
}

variable "license_key_vault_id" {
  description = <<-EOT
    Resource id of the vault holding license_key_vault_secret_id, which is
    what lets this module grant the VM's identity read access to that one
    secret:

      /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault

    Separate from the secret id because the two are different namespaces: the
    secret id above is a data-plane URL, an RBAC scope is an ARM resource id,
    and neither can be derived from the other without asking Azure. This
    module reads no data sources, so it asks you instead.

    Null makes no role assignment at all. Use that when the vault is still on
    access policies, when it lives in another subscription, or when something
    other than this configuration owns its access, and grant
    identity_principal_id yourself.

    Ignored unless license_key_vault_secret_id is set.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.license_key_vault_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", var.license_key_vault_id))
    error_message = "license_key_vault_id must be a Key Vault resource id: /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>, with no trailing path."
  }
}

variable "enable_run_command" {
  description = <<-EOT
    Turn on the Run Command route onto the host, and the outputs describing
    it. Off by default.

    This is how you get a root shell without a key pair of your own and
    without opening port 22:

      az vm run-command invoke --command-id RunShellScript
        --resource-group <rg> --name <vm> --scripts '<command>'

    It is also the only way to read the API key the bootstrap writes at boot,
    which the dataiku provider needs. Without this, and without
    ssh_cidr_blocks and the private half of ssh_public_key, that file sits on
    the host and nothing can reach it, and the second half of the workflow is
    impossible.

    It is not an interactive shell: Run Command executes a script as root and
    hands back its stdout, which covers every reason this module needs to
    reach the host. Azure Bastion gives a real shell and bills by the hour for
    as long as it exists, which does not belong in a module whose defaults
    create nothing.

    This variable creates nothing, which is why it is honest to leave it off
    by default rather than always on. The capability is already on the VM:
    walinuxagent ships in the image, so there is no extension to install and
    nothing to provision. What is missing is permission, and permission here
    is held by you rather than by the VM
    (Microsoft.Compute/virtualMachines/runCommand/action, which Owner,
    Contributor and Virtual Machine Contributor all carry, and no built-in
    role grants on its own). A module cannot grant that to a caller it cannot
    see, and should not try. So this is an acknowledgement that you have it,
    and the switch for the outputs that use it.
  EOT
  type        = bool
  default     = false
}
