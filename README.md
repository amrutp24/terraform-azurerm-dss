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
  license_json        = var.dss_license_json
}

output "dss_url" {
  value = module.dss.dss_url
}
```

`203.0.113.0/24` above is RFC 5737 documentation space and matches nothing real.
Put your own range there.

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

Moving it off the VM is the part this module deliberately leaves to you. Key
Vault is the cleanest option: give the VM a managed identity with `Key Vault
Secrets Officer`, push the key from cloud-init, and read it back with
`azurerm_key_vault_secret`, so nothing sensitive passes through Terraform state.
Fetching the file over SSH with an `external` data source works too.

Or skip it. Set `create_api_key = false` and create a global API key under
Administration → Security once DSS is up.

## Outputs

| Output | Use |
| --- | --- |
| `dss_url` | The `dataiku` provider's `host`. |
| `public_ip`, `private_ip` | VM addresses. |
| `vm_id` | Snapshots, extensions, anything referencing the VM. |
| `data_dir` | Path holding every project. This is what to back up. |

## Limits

The data directory sits on the OS disk, which keeps the module small and means
replacing the VM loses every project. Attach a managed data disk and mount it at
`data_dir` if you want it to survive a rebuild.

There is no load balancer, TLS or DNS. DSS answers directly on its port over
plain HTTP, so put it behind an Application Gateway with a certificate before
anyone types a password into it.

No managed identity is attached, so add one if the VM needs to reach Key Vault
or storage.

Nothing replaces a broken node either: no scale set, no health probe. DSS is
stateful and does not cluster this way, so recovery means restoring the data
directory from a backup you took yourself.

Code environments need `python_interpreter` set. The image is Ubuntu 24.04,
which ships Python 3.12 only, while DSS 15 defaults new Python environments to
`python3.9`. Left unset the build fails with `python3.9: command not found`,
and DSS reports the environment as created anyway. Pass `PYTHON312` to
`dataiku_code_env`.

It also costs money. DSS drops into a low-memory mode below roughly 16 GB and
says so in its logs, so the default is `Standard_D4s_v5` on Premium SSD, which
bills for as long as it exists. Destroy it when you are done.

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

Pass a licence at install time with `license_json` if you have one, or register
the instance through its web interface on first visit.

`license_json` reaches `custom_data` and Terraform state, so supply it from a
secret store rather than a file in your repository.

## Security defaults

`allowed_cidr_blocks` has **no default and refuses `0.0.0.0/0`**. DSS holds your
data, and its login page should not become reachable from the whole internet
because a variable had a convenient default. Edit the validation if you
genuinely mean it.

Password authentication is disabled, so `ssh_public_key` is required and a key
is the only way in. No SSH rule is created at all unless you set
`ssh_cidr_blocks`.

## License

Mozilla Public License 2.0.
