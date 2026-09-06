output "vm_id" {
  description = "Virtual machine id."
  value       = azurerm_linux_virtual_machine.dss.id
}

output "public_ip" {
  description = "Public address, when one was assigned."
  value       = var.assign_public_ip ? azurerm_public_ip.dss[0].ip_address : null
}

output "private_ip" {
  description = "Address within the virtual network."
  value       = azurerm_network_interface.dss.private_ip_address
}

output "dss_url" {
  description = "Where DSS will answer once it has finished installing. Allow several minutes on first boot: the installer downloads about two gigabytes."
  value = format("http://%s:%d",
    var.assign_public_ip ? azurerm_public_ip.dss[0].ip_address : azurerm_network_interface.dss.private_ip_address,
  var.dss_port)
}

output "data_dir" {
  description = "DSS data directory on the VM. This is what to back up."
  value       = var.data_dir
}
