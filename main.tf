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

module "bootstrap" {
  source  = "amrutp24/dss-bootstrap/null"
  version = "~> 0.1"

  dss_version  = var.dss_version
  dss_port     = var.dss_port
  data_dir     = var.data_dir
  license_json = var.license_json
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
}
