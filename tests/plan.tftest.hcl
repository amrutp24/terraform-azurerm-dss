# Assertions on the shape of the plan: who can reach DSS, and on what.
#
# The provider is mocked. azurerm insists on a subscription id and a login
# before it will configure, so a plan would otherwise need credentials. The
# module reads no data sources, and everything asserted here comes from
# configuration rather than from the API.
mock_provider "azurerm" {}

variables {
  allowed_cidr_blocks = ["203.0.113.10/32"]
  # A throwaway key generated for these tests. The provider parses this at
  # plan time, so a placeholder string will not do. Its private half was never
  # kept, and a public key is public anyway.
  ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC3F/aqzQInJB6aH8zFLKx1/rB7+3UOYeLBWizO1mihOLV+aJgsiUs8eGSqBVShnA+yjDpBMR7x8DQ+QLQarUiVxzC+NbIk74/JRWxnrerWJdA4sZwJ0ERvdeNKMgv8VI6BgW7vGfIS0elCoB0okmxrBotd7RI2sno8UAZhg1jKP61ud/BarvuMixR/y4sIdmQkpBcHOXAadfvBH8oi7ekkikKJKSJZ+3VItU7waRBQ7o/TM/MasyM32+QiOl7f+XtNICME4/1oQ4FG8X0a+LcLov7pqNxs1ymxVkAr0inzdxWaQfuacc/egycL1WC6RToDu1tDhyyhPgCGk7iSu50O+bx9ukI08q51m/CE8gpbQz9w44Juv+yl9Ue5T2wgIBqi+HHATtBdeH/U4rwdVprkTqk3O1s2pLYPKWdG019utWbKmHkEKSFnWTWzmi+wHg8VrGKE5GZgXQ0onJOMuP6Xz550alvysK0BNGCoVsRHz9JS28lyYIe2RcI6H9r0Qxr0MkXe44gQ422i0t1KaXGZH2UFGKngsxw9Sk/eibUzTq3tHIocyt1msH0hCkqSBnMRJyutqgh9gTa2MI86naa2fS8NpQupCnW7b/fiaVYTP5glxAxLdjigIc3AyQ7x3dVPBlF3TsvF3DpZvSK6RyMlfESwkSzwNRdqAh/igFYsNQ== terraform-test@example.invalid"
}

# The network security group is the whole security story for this module. A
# rule admitting a range nobody chose would be the worst bug it could have.
run "only_the_given_ranges_reach_dss" {
  command = plan

  variables {
    allowed_cidr_blocks = ["203.0.113.10/32", "198.51.100.0/24"]
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.dss.security_rule :
      toset(rule.source_address_prefixes) == toset(["203.0.113.10/32", "198.51.100.0/24"])
      if rule.name == "dss"
    ])
    error_message = "The DSS rule must admit exactly the ranges given, and nothing else."
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.dss.security_rule :
      rule.destination_port_range == "10000"
      if rule.name == "dss"
    ])
    error_message = "The rule should open the DSS port."
  }
}

run "the_dss_port_follows_the_variable" {
  command = plan

  variables {
    dss_port = 11000
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.dss.security_rule :
      rule.destination_port_range == "11000"
      if rule.name == "dss"
    ])
    error_message = "Changing dss_port must move the rule with it, or DSS answers on a port nothing can reach."
  }
}

# SSH is off unless asked for.
run "no_ssh_rule_unless_asked_for" {
  command = plan

  assert {
    condition = length([
      for rule in azurerm_network_security_group.dss.security_rule :
      rule if rule.name == "ssh"
    ]) == 0
    error_message = "SSH must be closed by default."
  }
}

run "ssh_opens_only_to_the_given_ranges" {
  command = plan

  variables {
    ssh_cidr_blocks = ["203.0.113.10/32"]
  }

  assert {
    condition = length([
      for rule in azurerm_network_security_group.dss.security_rule :
      rule if rule.name == "ssh" && rule.destination_port_range == "22"
    ]) == 1
    error_message = "ssh_cidr_blocks is set and no SSH rule was planned."
  }

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.dss.security_rule :
      toset(rule.source_address_prefixes) == toset(["203.0.113.10/32"])
      if rule.name == "ssh"
    ])
    error_message = "The SSH rule must admit exactly the ranges given."
  }
}

# Not asserted here: that the security group is associated with the subnet.
# Both ids are computed, so at plan time the comparison cannot be evaluated,
# and applying against the mock fails instead on azurerm parsing a generated
# mock id as an Azure resource id. Giving the mocks well-formed ids moves the
# failure to the next resource rather than fixing it, so the association is
# left to review rather than bent into a test.

# Dataiku asks for at least 16 GB, and the default also has to be a size a
# new subscription can actually create. Standard_D4s_v5 was neither: a fresh
# subscription gets zero DSv5 quota, so the first apply failed on quota after
# building the network.
run "the_vm_clears_dataikus_memory_floor" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.dss.size == "Standard_D4ds_v6"
    error_message = "The default VM size should clear Dataiku's 16 GB floor with a family a new subscription has quota for."
  }

  # Not asserted: that the size is available in the chosen region, or that the
  # subscription has quota for its family. Neither is visible in a plan, which
  # is exactly why the old default survived to a real apply.
}

# ---------------------------------------------------------------------------
# Reading the licence from Key Vault, and reaching the host
# ---------------------------------------------------------------------------

# Defaults must create nothing beyond the VM and its network. An identity the
# caller did not ask for is a principal that can be granted things, and a role
# assignment the caller did not ask for is access to somebody's vault.
run "no_identity_and_no_role_assignment_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_user_assigned_identity.dss) == 0
    error_message = "A module left at its defaults must create no managed identity."
  }

  assert {
    condition     = length(azurerm_role_assignment.license_read) == 0
    error_message = "A module left at its defaults must grant no access to any vault."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.dss.identity) == 0
    error_message = "A module left at its defaults must attach no identity to the VM."
  }
}

# Reading the secret needs an identity, so naming one has to create one.
# Without it the VM boots with no identity, the token request gets a 400, and
# DSS comes up unlicensed, which looks exactly like success.
run "a_licence_secret_creates_an_identity_and_attaches_it" {
  command = plan

  variables {
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.dss) == 1
    error_message = "Naming a licence secret must create a managed identity."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.dss.identity) == 1
    error_message = "The identity must be attached to the VM, or the token request has nothing to come from."
  }

  assert {
    condition     = one(azurerm_linux_virtual_machine.dss.identity).type == "UserAssigned"
    error_message = "The VM should carry the user-assigned identity this module created, not a system-assigned one that cannot be granted the secret before first boot."
  }

  # Exactly one. IMDS wants a client id in the token request as soon as a VM
  # carries more than one identity, and this fetch command sends none.
  assert {
    condition     = length(one(azurerm_linux_virtual_machine.dss.identity).identity_ids) == 1
    error_message = "The VM must carry exactly one identity, because the token request names none."
  }
}

# A vault id is what makes the role assignment possible, and its absence must
# not quietly skip the identity as well.
run "a_licence_secret_alone_grants_nothing" {
  command = plan

  variables {
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
  }

  assert {
    condition     = length(azurerm_role_assignment.license_read) == 0
    error_message = "Without license_key_vault_id there is no scope to assign, so the module must grant nothing and leave it to the caller."
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.dss) == 1
    error_message = "The identity is what the token comes from, so it is needed whether or not this module grants it anything."
  }
}

run "the_grant_names_one_secret_and_reads_only" {
  command = plan

  variables {
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
    license_key_vault_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault"
  }

  assert {
    condition     = length(azurerm_role_assignment.license_read) == 1
    error_message = "A secret and its vault together should produce exactly one role assignment."
  }

  # The narrowest scope Azure offers. A vault-level scope would hand the VM
  # every secret in the vault, which a licence is not worth.
  assert {
    condition     = one(azurerm_role_assignment.license_read).scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault/secrets/dss-license"
    error_message = "The assignment must be scoped to the one secret named, not to the whole vault."
  }

  assert {
    condition     = one(azurerm_role_assignment.license_read).role_definition_name == "Key Vault Secrets User"
    error_message = "The VM reads one secret and never writes one, so Secrets User and not Secrets Officer."
  }

  # The identity is created in the same apply, and Entra ID replication lags
  # behind that, so without this a first apply can fail on a principal ARM
  # cannot see yet and then succeed on a retry of the same configuration.
  assert {
    condition     = one(azurerm_role_assignment.license_read).skip_service_principal_aad_check
    error_message = "The assignment targets a service principal created seconds earlier, so the directory check has to be skipped."
  }
}

# A pinned version has to survive the trip to the role assignment scope, which
# names the secret and not the version.
run "a_versioned_secret_id_still_scopes_to_the_secret" {
  command = plan

  variables {
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license/0123456789abcdef0123456789abcdef"
    license_key_vault_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault"
  }

  assert {
    condition     = one(azurerm_role_assignment.license_read).scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault/secrets/dss-license"
    error_message = "An RBAC scope names the secret, not one of its versions, so the version must be dropped."
  }
}

# The licence must not travel through Terraform. If it is in the cloud-config
# it is in state and in the VM's custom_data, which is the whole thing this
# avoids, so the script should carry the command and not a licence.
run "the_licence_is_fetched_on_the_vm_rather_than_rendered" {
  command = plan

  variables {
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "https://example-vault.vault.azure.net/secrets/dss-license")
    error_message = "The boot script should name the secret it was given."
  }

  assert {
    condition     = !strcontains(module.bootstrap.cloud_init, "writing licence")
    error_message = "No licence content should be rendered into the boot script."
  }

  # Not the az CLI. Canonical's package manifest for this image lists 659
  # packages and azure-cli is not among them, so a fetch that shells out to it
  # fails and DSS comes up unlicensed. The sibling AWS module paid for this
  # lesson with awscli.
  assert {
    condition     = !strcontains(module.bootstrap.cloud_init, "az keyvault secret show")
    error_message = "The fetch must not depend on the az CLI, which this image does not carry."
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "http://169.254.169.254/metadata/identity/oauth2/token")
    error_message = "The fetch should get its token from the instance metadata service, which needs nothing installed."
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "resource=https://vault.azure.net")
    error_message = "The token has to be requested for the Key Vault audience, or the vault rejects it."
  }

  # IMDS answers a token request only when this header is present; without it
  # the reply is a 400 and the licence never arrives.
  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "{\"Metadata\":\"true\"}")
    error_message = "The token request must carry the Metadata header IMDS requires."
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "\"Authorization\":\"Bearer \"+t")
    error_message = "The secret request should present the token it just fetched."
  }

  # The secret arrives as argv, so the Python body needs no quoting of its own
  # and a secret id cannot close a string literal.
  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "sys.argv[1]")
    error_message = "The secret id should be passed as an argument rather than interpolated into the Python."
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "api-version=7.4")
    error_message = "The Key Vault request needs an api-version; without one the vault answers 400."
  }
}

run "no_licence_secret_means_no_fetch_at_all" {
  command = plan

  assert {
    condition     = !strcontains(module.bootstrap.cloud_init, "169.254.169.254")
    error_message = "A module that was given no licence secret must not plan a token request."
  }
}

# license_json still has to work, and still has to win, for anybody already
# passing it.
run "license_json_still_renders_and_wins" {
  command = plan

  variables {
    license_json                = "{\"licenseId\":\"example\"}"
    license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
  }

  assert {
    condition     = strcontains(module.bootstrap.cloud_init, "writing licence")
    error_message = "license_json should still be rendered into the boot script."
  }

  assert {
    condition     = !strcontains(module.bootstrap.cloud_init, "fetching licence")
    error_message = "license_json wins over a fetch, so no fetch should be planned alongside it."
  }
}

# Run Command provisions nothing: walinuxagent is already in the image, and the
# permission it needs is the caller's rather than the VM's. So what has to be
# true is that the switch produces a usable command and changes nothing else.
run "run_command_creates_nothing_and_describes_itself" {
  command = plan

  variables {
    enable_run_command = true
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.dss) == 0
    error_message = "Run Command needs no identity on the VM, so asking for it must not create one."
  }

  assert {
    condition     = length(azurerm_role_assignment.license_read) == 0
    error_message = "Run Command must not quietly grant access to a vault."
  }

  assert {
    condition     = output.session_command != null
    error_message = "enable_run_command should produce the command that uses it."
  }

  assert {
    condition     = strcontains(output.session_command, "--command-id RunShellScript")
    error_message = "The command should invoke Run Command rather than something that needs Bastion or a key pair."
  }

  assert {
    condition     = strcontains(output.session_command, "--name dataiku-dss")
    error_message = "The command should name this VM, so it can be pasted as it stands."
  }

  assert {
    condition     = output.api_key_path == "/var/lib/dataiku-terraform-key.json"
    error_message = "With a way onto the host, api_key_path should name the file the bootstrap wrote."
  }
}

run "no_way_onto_the_host_says_so" {
  command = plan

  assert {
    condition     = output.session_command == null
    error_message = "Without enable_run_command there is no Run Command route, and the output should not suggest one."
  }

  assert {
    condition     = output.api_key_path == null
    error_message = "With neither Run Command nor an SSH rule, nothing can read the API key, and the output should say so rather than name an unreachable path."
  }
}

# An SSH rule is the other way in, and it is enough to read the key file.
run "an_ssh_rule_also_reaches_the_api_key" {
  command = plan

  variables {
    ssh_cidr_blocks = ["203.0.113.10/32"]
  }

  assert {
    condition     = output.api_key_path == "/var/lib/dataiku-terraform-key.json"
    error_message = "ssh_cidr_blocks is a way onto the host, so the key path should be reported."
  }

  assert {
    condition     = output.session_command == null
    error_message = "An SSH rule is not Run Command, so session_command should stay null."
  }
}

# Not asserted: that identity_principal_id reports something when an identity
# exists. A principal id is assigned by Azure, so at plan time it is unknown
# and the comparison cannot be evaluated at all, which fails the run rather
# than failing the assertion. The negative case below is knowable, because
# there the output is a literal null, and the identity's existence is covered
# by the runs above. The same reason the subnet association is left out.
run "no_identity_means_no_principal_to_report" {
  command = plan

  assert {
    condition     = output.identity_principal_id == null
    error_message = "With no identity created there is no principal, and the output should be null rather than an error."
  }
}
