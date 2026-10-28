# The variable validations exist to fail at plan time rather than after a VM
# is already running. These check they fire.
#
# The provider is mocked: azurerm insists on a subscription id and a login
# before it will configure, so a plan would otherwise need credentials.
mock_provider "azurerm" {}

variables {
  allowed_cidr_blocks = ["203.0.113.10/32"]
  # A throwaway key generated for these tests. The provider parses this at
  # plan time, so a placeholder string will not do. Its private half was never
  # kept, and a public key is public anyway.
  ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC3F/aqzQInJB6aH8zFLKx1/rB7+3UOYeLBWizO1mihOLV+aJgsiUs8eGSqBVShnA+yjDpBMR7x8DQ+QLQarUiVxzC+NbIk74/JRWxnrerWJdA4sZwJ0ERvdeNKMgv8VI6BgW7vGfIS0elCoB0okmxrBotd7RI2sno8UAZhg1jKP61ud/BarvuMixR/y4sIdmQkpBcHOXAadfvBH8oi7ekkikKJKSJZ+3VItU7waRBQ7o/TM/MasyM32+QiOl7f+XtNICME4/1oQ4FG8X0a+LcLov7pqNxs1ymxVkAr0inzdxWaQfuacc/egycL1WC6RToDu1tDhyyhPgCGk7iSu50O+bx9ukI08q51m/CE8gpbQz9w44Juv+yl9Ue5T2wgIBqi+HHATtBdeH/U4rwdVprkTqk3O1s2pLYPKWdG019utWbKmHkEKSFnWTWzmi+wHg8VrGKE5GZgXQ0onJOMuP6Xz550alvysK0BNGCoVsRHz9JS28lyYIe2RcI6H9r0Qxr0MkXe44gQ422i0t1KaXGZH2UFGKngsxw9Sk/eibUzTq3tHIocyt1msH0hCkqSBnMRJyutqgh9gTa2MI86naa2fS8NpQupCnW7b/fiaVYTP5glxAxLdjigIc3AyQ7x3dVPBlF3TsvF3DpZvSK6RyMlfESwkSzwNRdqAh/igFYsNQ== terraform-test@example.invalid"
}

run "accepts_a_valid_configuration" {
  command = plan
}

run "rejects_an_empty_allowed_list" {
  command = plan

  variables {
    allowed_cidr_blocks = []
  }

  expect_failures = [var.allowed_cidr_blocks]
}

run "rejects_opening_dss_to_the_internet" {
  command = plan

  variables {
    allowed_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_cidr_blocks]
}
