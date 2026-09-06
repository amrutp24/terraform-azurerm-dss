# terraform-azurerm-dss

Runs [Dataiku DSS](https://www.dataiku.com/) on an Azure Linux virtual machine.

The module creates a resource group, virtual network, network security group and
a VM, and installs DSS through cloud-init: download, install, apply a licence,
register the boot service, and optionally mint the API key needed to configure
the instance afterwards.

```hcl
module "dss" {
  source  = "amrutp24/dss/azurerm"
  version = "~> 0.1"

  allowed_cidr_blocks = ["203.0.113.0/24"]
  ssh_public_key      = file("~/.ssh/id_ed25519.pub")
  license_json        = var.dss_license_json
}

output "dss_url" {
  value = module.dss.dss_url
}
```

DSS answers on `module.dss.dss_url` once it has finished installing. Allow
several minutes on first boot — the installer downloads about two gigabytes and
then builds a Python environment. Until that finishes the port simply does not
answer. Watch progress in boot diagnostics.

Everything lives in one resource group the module creates, so `terraform
destroy` leaves nothing behind.

## Configuring the instance is a second apply

This module gets you a running DSS. Creating projects, groups, connections and
code environments inside it is done with the
[`dataiku` provider](https://registry.terraform.io/providers/amrutp24/dataiku/latest),
and it has to be a **separate root configuration**.

Terraform resolves provider configuration during *planning*, before any resource
exists. A configuration that creates this VM and then points the `dataiku`
provider at it would need the VM's address and an API key before creating
anything. It deadlocks. No module structure avoids that.

So: apply this, wait for DSS to answer, then apply a second configuration that
reads this one's outputs.

That split is worth having anyway. You can rebuild the VM without touching its
configuration, and change configuration without risking the VM.

## Getting the API key out

The `dataiku` provider needs an API key, and a brand-new DSS has no way to
produce one without a browser. With `create_api_key` left on, the bootstrap runs
`dsscli api-key-create` and writes the result to `api_key_path`, mode 0600.

Moving it off the VM is the part this module deliberately does not decide for
you:

- **Key Vault** is cleanest. Give the VM a managed identity with
  `Key Vault Secrets Officer`, push the key from cloud-init, and read it back
  with `azurerm_key_vault_secret`. Nothing sensitive passes through Terraform
  state.
- **Over SSH**, with an `external` data source.
- **By hand, once.** Set `create_api_key = false` and create a global API key
  under Administration → Security after DSS is up.

## What this module does not do

Worth knowing before you rely on it.

**The data directory is on the OS disk.** That keeps the module small, and means
replacing the VM loses every project. For anything you care about, attach a
managed data disk, mount it at `data_dir`, and it survives a rebuild.

**There is no load balancer, TLS, or DNS.** DSS is reached directly on its port
over plain HTTP. Put it behind an Application Gateway with a certificate before
anyone types a password into it.

**No managed identity is attached.** Add one if the instance needs to reach Key
Vault or storage.

**One VM, no automatic recovery.** No scale set, no health probe replacing a
broken node. DSS is stateful and does not cluster like this, so recovery means
restoring the data directory.

**Sizing costs money.** DSS drops into a low-memory mode below roughly 16 GB and
says so in its logs, so the default is `Standard_D4s_v5` with Premium SSD. That
runs up a bill while it exists. `terraform destroy` when you are finished.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API, which the Free Edition
does not licence on its own — though the Enterprise trial bundled with it does,
while that trial lasts. Pass a licence at install time with `license_json`, or
register the instance through its web interface on first visit.

`license_json` reaches `custom_data` and Terraform state, so supply it from a
secret store rather than a file in your repository.

## Security defaults

`allowed_cidr_blocks` has **no default and refuses `0.0.0.0/0`**. DSS holds your
data, and its login page should not become reachable from the whole internet
because a variable had a convenient default. Edit the validation if you
genuinely mean it.

Password authentication is disabled outright — `ssh_public_key` is required, and
a key is the only way in. No SSH rule is created at all unless you set
`ssh_cidr_blocks`.

## License

Mozilla Public License 2.0.
