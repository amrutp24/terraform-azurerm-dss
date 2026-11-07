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

output "session_command" {
  description = <<-EOT
    How to reach the host, when enable_run_command is on. Null otherwise,
    which is the signal that nothing but SSH can get to it.

    Not an interactive session, despite the name it shares with the AWS
    module's output: Run Command runs the script as root and returns its
    stdout. Replace the script with whatever you actually want to run.
  EOT
  value = var.enable_run_command ? join(" ", [
    "az vm run-command invoke",
    "--resource-group ${azurerm_resource_group.dss.name}",
    "--name ${azurerm_linux_virtual_machine.dss.name}",
    "--command-id RunShellScript",
    "--scripts 'cat ${module.bootstrap.api_key_path}'",
  ]) : null
}

output "api_key_path" {
  description = <<-EOT
    Where the bootstrap wrote the admin API key, which is what the dataiku
    provider needs. Reading it takes root on the host, so this is null unless
    enable_run_command is on or ssh_cidr_blocks lets you in.

    Deliberately a path rather than a command. A command would have to carry
    the subscription the VM is in, and this module is not told it: that is
    provider configuration, which a module cannot see. The caller knows it,
    so the caller builds the command.
  EOT
  value       = var.enable_run_command || var.ssh_cidr_blocks != null ? module.bootstrap.api_key_path : null
}

output "identity_principal_id" {
  description = <<-EOT
    Object id of the VM's user-assigned managed identity, or null when no
    licence secret was named and so no identity was created.

    This is what to grant if you left license_key_vault_id unset, for example
    a Key Vault Secrets User assignment on your own vault or secret. Worth
    knowing before you do: an RBAC change can take a few minutes to take
    effect, and the VM fetches its licence partway through a boot that is
    already several minutes long, so a grant made after apply returns may or
    may not arrive in time. If the boot log says the licence command failed,
    reboot and it will try again.
  EOT
  value       = local.needs_identity ? azurerm_user_assigned_identity.dss[0].principal_id : null
}
