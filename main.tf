# Stands up a DSS instance on an Azure Linux VM and leaves it ready to
# configure.
#
# This is layer one only. Configuring what is on the instance is a separate
# apply, because Terraform builds a provider's configuration during planning
# and the dataiku provider needs a reachable instance and an API key before
# that. See README.md.

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# ~> 0.3 rather than ~> 0.1. Both permit 0.3.x, since a two-component
# pessimistic constraint means >= 0.1.0 and < 1.0.0, so the old pin was not
# wrong. It was quiet, which is worse: a .terraform directory initialised
# before 0.3.0 existed keeps 0.1.0 until somebody passes -upgrade, and 0.1.0
# has no license_fetch_command, so the licence below silently cannot work.
# That is not hypothetical, it is what this checkout was holding. Naming the
# real floor makes init fetch what the configuration actually needs.
module "bootstrap" {
  source  = "amrutp24/dss-bootstrap/null"
  version = "~> 0.3"

  dss_version  = var.dss_version
  dss_port     = var.dss_port
  data_dir     = var.data_dir
  license_json = var.license_json

  # Read on the VM, so no licence material reaches state or custom_data. The
  # managed identity below grants this and nothing else.
  license_fetch_command = local.license_fetch_command
}

locals {
  # Reading the licence is the only thing here that needs the VM to hold an
  # identity of its own. Run Command authorises the caller, not the VM.
  needs_identity = var.license_key_vault_secret_id != null

  # Scoping the role assignment to one secret needs the vault's ARM id, and
  # that cannot be derived from the secret id: one is a data-plane URL and the
  # other an ARM resource id. Without it the module makes no assignment and
  # the caller grants access itself.
  creates_license_role_assignment = var.license_key_vault_secret_id != null && var.license_key_vault_id != null

  # The secret name out of https://<vault>.vault.azure.net/secrets/<name>,
  # for that scope. The variable validation guarantees this shape.
  license_secret_name = var.license_key_vault_secret_id == null ? null : split("/", var.license_key_vault_secret_id)[4]

  # No az CLI. Checked against the package manifest Canonical publishes for
  # the image this module boots
  # (ubuntu-24.04-server-cloudimg-amd64-azure.vhd.manifest): it lists 659
  # packages, python3 3.12.3 and curl among them, and azure-cli is not one of
  # them. Installing the CLI at boot means adding Microsoft's apt repository
  # and pulling tens of megabytes before DSS has started, to make one HTTP
  # request. The sibling AWS module learned this the expensive way, with a
  # fetch that shelled out to a CLI the image could not provide: the command
  # failed, the instance came up unlicensed, and an unlicensed instance looks
  # exactly like a working one.
  #
  # So: the identity's own token endpoint, then the Key Vault REST API, with
  # python3 and nothing but the standard library. api-version 7.4 is the
  # long-standing GA secrets version and every live vault answers it.
  #
  # No client id on the token request. IMDS only needs one when a VM carries
  # more than one identity, and this module attaches exactly one and no
  # system-assigned identity. Attaching a second one outside the module would
  # make the token request ambiguous and this fetch would start failing.
  #
  # One command, not a list: the bootstrap redirects this command's stdout
  # into the licence file and its stderr into a log, and a list would redirect
  # only its last part. The secret id arrives as argv, so the Python needs no
  # quoting of its own and a vault name cannot close a string literal.
  license_fetch_command = var.license_key_vault_secret_id == null ? "" : join(" ", [
    "python3 -c 'import json,sys,urllib.request as r;g=lambda u,h:json.load(r.urlopen(r.Request(u,headers=h),timeout=30));t=g(\"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net\",{\"Metadata\":\"true\"})[\"access_token\"];print(g(sys.argv[1]+\"?api-version=7.4\",{\"Authorization\":\"Bearer \"+t})[\"value\"])'",
    var.license_key_vault_secret_id,
  ])
}

resource "azurerm_resource_group" "dss" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "dss" {
  name                = "${var.name}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  tags                = var.tags
}

resource "azurerm_subnet" "dss" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.dss.name
  virtual_network_name = azurerm_virtual_network.dss.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "dss" {
  name                = "${var.name}-nsg"
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  tags                = var.tags

  # No default on allowed_cidr_blocks, so reaching DSS is always a decision
  # somebody made rather than something that happened.
  security_rule {
    name                       = "dss"
    description                = "DSS web interface and public API"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.dss_port)
    source_address_prefixes    = var.allowed_cidr_blocks
    destination_address_prefix = "*"
  }

  dynamic "security_rule" {
    for_each = var.ssh_cidr_blocks == null ? [] : [1]
    content {
      name                       = "ssh"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.ssh_cidr_blocks
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "dss" {
  subnet_id                 = azurerm_subnet.dss.id
  network_security_group_id = azurerm_network_security_group.dss.id
}

resource "azurerm_public_ip" "dss" {
  count = var.assign_public_ip ? 1 : 0

  name                = "${var.name}-ip"
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "dss" {
  name                = "${var.name}-nic"
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dss.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.assign_public_ip ? azurerm_public_ip.dss[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "dss" {
  name                = var.name
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.dss.id]

  dynamic "identity" {
    for_each = local.needs_identity ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.dss[0].id]
    }
  }

  # Password authentication stays off; a key is the only way in, and SSH
  # itself is only reachable if ssh_cidr_blocks says so.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # The data directory holds every project and all configuration, so this is
  # what you back up. It lives on the OS disk here for simplicity; see the note
  # in README.md about giving it its own managed disk.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Azure hands custom_data to cloud-init, so the bootstrap goes across as a
  # cloud-config document rather than a bare script.
  custom_data = base64encode(module.bootstrap.cloud_init)

  # The VM fetches its licence during boot, so the grant has to be in place
  # before it boots. Nothing in the VM's own arguments depends on the role
  # assignment, so without this Terraform is free to create them in either
  # order, and losing that race means an instance that installs unlicensed
  # and says so only in a boot log.
  depends_on = [azurerm_role_assignment.license_read]
}

# ---------------------------------------------------------------------------
# Reading the licence from Key Vault
# ---------------------------------------------------------------------------

# Everything below is created only when a licence secret was named, so a
# module left at its defaults makes no identity and no role assignment.

# User-assigned rather than system-assigned, which would be one resource
# fewer. A system-assigned identity does not exist until the VM does, so the
# role assignment granting it the secret could only be created after the VM
# was already booting and already fetching. That race is unwinnable in the
# wrong direction: the fetch fails quietly and the instance comes up
# unlicensed. A separate identity can be granted the secret first and handed
# to the VM afterwards, which is the ordering depends_on above relies on.
#
# It also survives replacing the VM, so a rebuild does not wait on RBAC
# propagation all over again.
resource "azurerm_user_assigned_identity" "dss" {
  count = local.needs_identity ? 1 : 0

  name                = "${var.name}-identity"
  location            = azurerm_resource_group.dss.location
  resource_group_name = azurerm_resource_group.dss.name
  tags                = var.tags
}

# RBAC, not a vault access policy. An access policy's smallest unit is a
# permission over the whole vault, so "get secrets" there means get every
# secret in it; an RBAC assignment can name a single secret, which is what
# this does. RBAC is also what Microsoft now recommends and what the portal
# offers first on a new vault.
#
# Microsoft documents secret-level scope as supported while advising
# vault-level scope for most cases, on the grounds that per-secret
# assignments are harder to keep track of. One secret read by one VM is
# exactly the case where that advice does not apply, and a licence is not
# worth handing out the rest of a vault for.
#
# Key Vault Secrets User, not Secrets Officer: this reads one secret and
# never writes one.
#
# This only takes effect on a vault with RBAC authorisation enabled
# (enable_rbac_authorization = true). A vault still on access policies needs
# the grant made there instead; leave license_key_vault_id unset and use the
# identity_principal_id output.
resource "azurerm_role_assignment" "license_read" {
  count = local.creates_license_role_assignment ? 1 : 0

  scope                = "${var.license_key_vault_id}/secrets/${local.license_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dss[0].principal_id

  # The identity above was created seconds ago and Entra ID replication lags
  # behind that, so the directory check ARM runs against a new service
  # principal can fail with PrincipalNotFound on a first apply and then
  # succeed on a retry of the same configuration. Skipping that check is the
  # documented answer for this exact case, a principal_id that is a freshly
  # provisioned service principal, which is what a managed identity is.
  skip_service_principal_aad_check = true
}
