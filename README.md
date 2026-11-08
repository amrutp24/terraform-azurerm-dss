# terraform-azurerm-dss

Runs [Dataiku DSS](https://www.dataiku.com/) on an Azure Linux virtual machine.

The module creates a resource group, virtual network, network security group and
a VM, then installs DSS through cloud-init: download, install, apply a licence,
register the boot service, and optionally mint the API key needed to configure
the instance afterwards.

| Requirement | Version |
| --- | --- |
| Terraform | >= 1.5 |
| `hashicorp/azurerm` | ~> 4.0 |

## Usage

```hcl
provider "azurerm" {
  features {}
}

module "dss" {
  source  = "amrutp24/dss/azurerm"
  version = "~> 0.1"

  allowed_cidr_blocks = ["203.0.113.0/24"] # replace: your office or VPN range
  ssh_public_key      = file("~/.ssh/id_ed25519.pub")

  # The VM reads the licence itself at boot, so it never reaches Terraform
  # state or custom_data. Only its name does. See "Licensing DSS" below.
  license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
  license_key_vault_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault"

  # A root shell on the host without a key pair, which is how you read the
  # admin API key. Creates nothing.
  enable_run_command = true
}

output "dss_url" {
  value = module.dss.dss_url
}
```

`203.0.113.0/24` above is RFC 5737 documentation space and matches nothing real.
Put your own range there, and your own vault in place of the example ids: if
the vault and the secret are in the same configuration, pass
`azurerm_key_vault_secret.x.id` and `azurerm_key_vault.x.id` instead of
writing them out.

`ssh_public_key` has no default and is required, because password authentication
on the VM is disabled outright. Everything the module creates goes in one
resource group it owns, so `terraform destroy` leaves nothing behind.

## While it installs

`terraform apply` returns in about a minute. DSS does not answer for several
more: the installer pulls down roughly two gigabytes and then builds a Python
environment. Until that finishes the port refuses connections outright, so a
browser shows a connection error rather than a DSS page.

cloud-init writes its progress to a log on the VM:

```bash
ssh azureuser@$(terraform output -raw public_ip) 'sudo tail -f /var/log/cloud-init-output.log'
```

Every line the bootstrap writes is prefixed `[dss-bootstrap]`, and the last one
is `done`. The same output shows up in boot diagnostics in the portal, which is
the way in when SSH is closed.

If it never reaches `done`, that log names the step that failed. DSS keeps its
own logs under `run/` inside the data directory once the installer has got that
far.

## Configuring DSS is a second apply

This module gets you a running VM. Everything inside it (projects, groups,
connections, code environments) belongs to the
[`dataiku` provider](https://registry.terraform.io/providers/amrutp24/dataiku/latest),
which needs a **separate root configuration** of its own.

Provider configuration is resolved at plan time, ahead of any resource being
created. Put the VM and the `dataiku` provider in one configuration and planning
would require the VM's address, plus an API key minted on a host that does not
exist yet. Nothing about how the modules are nested changes that.

So apply this, wait for DSS to answer, then apply a second configuration reading
these outputs:

```hcl
provider "dataiku" {
  host = data.terraform_remote_state.vm.outputs.dss_url
  # api_key from DATAIKU_API_KEY
}
```

Two layers is the better shape regardless: the VM can be rebuilt without
disturbing its configuration, and the configuration changed without risking the
VM.

## Getting the API key out

The `dataiku` provider needs an API key, and a brand-new DSS has no way to
produce one without a browser. With `create_api_key` left on, the bootstrap runs
`dsscli api-key-create` and writes the result to `api_key_path`, mode 0600.

It writes an array of one object, not a bare object, so anything reading it
has to index in: `[{"id": ..., "key": ..., "label": "terraform"}]`.

Reading it needs root on the host. Set `enable_run_command = true` and the
`session_command` output hands you the command:

```bash
eval "$(terraform output -raw session_command)"
```

That is `az vm run-command invoke --command-id RunShellScript`, which runs the
script as root and returns its stdout. It needs no key pair, no open port 22,
and nothing installed on the VM: `walinuxagent` is in the image already. What
it does need is `Microsoft.Compute/virtualMachines/runCommand/action` on the
VM, which Owner, Contributor and Virtual Machine Contributor all carry. The
module cannot grant that to you, because it has no idea who you are, so
`enable_run_command` is an acknowledgement that you already have it rather
than something that provisions access.

It is not an interactive shell. Azure Bastion is, and it bills by the hour for
as long as it exists, which is why this module does not create one.

The other route is SSH: set `ssh_cidr_blocks`, keep the private half of
`ssh_public_key`, and read the file yourself. `api_key_path` is non-null under
either, and null when neither is set, which is the signal that the file exists
on the host and nothing can reach it.

Or skip it. Set `create_api_key = false` and create a global API key under
Administration > Security once DSS is up.

## Outputs

| Output | Use |
| --- | --- |
| `dss_url` | The `dataiku` provider's `host`. |
| `public_ip`, `private_ip` | VM addresses. |
| `vm_id` | Snapshots, extensions, anything referencing the VM. |
| `data_dir` | Path holding every project. This is what to back up. |
| `session_command` | Run Command invocation that reads the API key, or null when `enable_run_command` is off. |
| `api_key_path` | Where the bootstrap left the admin key, or null when nothing can reach the host. |
| `identity_principal_id` | The VM identity to grant, or null when no licence secret was named. |

## Limits

The data directory sits on the OS disk, which keeps the module small and means
replacing the VM loses every project. Attach a managed data disk and mount it at
`data_dir` if you want it to survive a rebuild.

There is no load balancer, TLS or DNS. DSS answers directly on its port over
plain HTTP, so put it behind an Application Gateway with a certificate before
anyone types a password into it.

The only managed identity this module attaches is the one that reads the
licence secret, and the only thing it is granted is that one secret. If the VM
needs to reach storage, a registry or anything else, grant
`identity_principal_id` yourself, or attach an identity of your own: note that
a second identity on the VM would make the licence fetch's token request
ambiguous, since it names no client id.

Nothing replaces a broken node either: no scale set, no health probe. DSS is
stateful and does not cluster this way, so recovery means restoring the data
directory from a backup you took yourself.

Code environments need `python_interpreter` set. The image is Ubuntu 24.04,
which ships Python 3.12 only, while DSS 15 defaults new Python environments to
`python3.9`. Left unset the build fails with `python3.9: command not found`,
and DSS reports the environment as created anyway. Pass `PYTHON312` to
`dataiku_code_env`.

It also costs money. DSS drops into a low-memory mode below roughly 16 GB and
says so in its logs, so the default is `Standard_D4ds_v6` on Premium SSD,
which bills for as long as it exists. Destroy it when you are done.

That default is deliberately not a DSv5 size. A fresh subscription is given
zero quota for the DSv5 family, so `Standard_D4s_v5` failed on quota part way
through a first apply while DSv3, DSv4 and the v6 families all had ten vCPUs
available. Check your own with `az vm list-usage --location <region>` before
changing it.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API.

Whether a given instance serves it depends on the version and the licence, so
check rather than assume. A stock DSS 15 Community Edition installed by this
module answered the API with `license_json` unset, and projects, groups, users,
connections and scenarios were all created through it. An older `dataiku/dss` container, by
contrast, refused with `DSS API is not available with your Free Edition
license`.

The check that matters is whether the API answers at all:

```bash
curl -su "$DATAIKU_API_KEY:" "$(terraform output -raw dss_url)/public/api/admin/general-settings/" -o /dev/null -w '%{http_code}'; echo
```

`200` means the provider will work. `401` is a bad key. A licence error names
itself in the body, and then you need a licence with API access.

Pass a licence at install time if you have one, or register the instance
through its web interface on first visit.

There are two ways to pass one, and they are not equivalent:

`license_key_vault_secret_id` names a Key Vault secret and the VM reads it
**itself** at boot, so only the secret's id reaches Terraform state and
`custom_data`. Prefer this.

```hcl
license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
license_key_vault_id        = "/subscriptions/.../resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault"
```

Setting the secret id creates a user-assigned managed identity for the VM.
Setting the vault id as well scopes a `Key Vault Secrets User` assignment to
that **one secret**, which is the narrowest grant Azure offers. Leave the vault
id out and the module grants nothing; use the `identity_principal_id` output to
grant access yourself, which is what you want if the vault still uses access
policies or lives in another subscription.

How the VM reads it, since it matters when it goes wrong: the identity's token
comes from the instance metadata service and the secret from the Key Vault REST
API, fetched with `python3` and the standard library. No `az` CLI, which this
image does not carry and which would be a sizeable download at boot to make one
HTTP request. If the fetch fails, DSS installs **unlicensed rather than half
configured**, the boot log says `warning: the licence command failed`, and
the reason is in `/tmp/dss-license-fetch.log`. A `403` there means the role
assignment has not reached the vault yet; reboot and it tries again.

`license_json` is the one-step alternative and still works and still wins if
you set both. It is rendered into the cloud-config, so the licence ends up in
Terraform state and in the VM's `custom_data`. Prefer the secret.

The licence itself is portable: its `instanceId` travels inside the signed
licence rather than being derived from the hardware, so one licence works on a
VM that did not exist when it was issued. That is what makes storing it viable
at all.

## Security defaults

`allowed_cidr_blocks` has **no default and refuses `0.0.0.0/0`**. DSS holds your
data, and its login page should not become reachable from the whole internet
because a variable had a convenient default. Edit the validation if you
genuinely mean it.

Password authentication is disabled, so `ssh_public_key` is required. It is
required in a stronger sense than most variables: with no credential at all the
azurerm provider refuses to create the VM, and refuses during apply rather than
during plan, so there is no keyless configuration of this module that gets as
far as a running VM. If you do not intend to use SSH, pass a throwaway key and
discard its private half.

Having a key is not the same as exposing one. No SSH rule is created unless you
set `ssh_cidr_blocks`, so by default port 22 is closed to everyone and
`enable_run_command` is the way onto the host.

## License

Mozilla Public License 2.0.
