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

# Dataiku asks for at least 16 GB.
run "the_vm_clears_dataikus_memory_floor" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.dss.size == "Standard_D4s_v5"
    error_message = "The default VM size should clear Dataiku's 16 GB floor."
  }
}
