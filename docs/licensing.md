# Getting a licence onto the VM

DSS will install and run without a licence, but a fresh instance asks whoever
opens it first to register Free Edition: a form wanting a first name, a last
name and an email address. Until somebody fills that in, the instance
licenses only the `NONE` user profile, which means the dataiku provider cannot
create a usable user and `terraform apply` on a configuration that creates
one will fail.

That makes a rebuild a manual job, which is the thing worth fixing if you
destroy and recreate often.

One clarification first, because it is easy to expect too much: none of this
removes the DSS **login page**. DSS is an application with user accounts and
always asks for credentials, `admin` / `admin` on a fresh install. What the
options below remove is the **registration form**.

## Option A: store the licence, let the VM read it

This is what `license_key_vault_secret_id` is for. Register once, keep the
licence in a Key Vault secret, and every VM after that reads it at boot and
installs it before DSS finishes starting.

1. Bring up a VM and register Free Edition in the browser, once. Copy
   `<data_dir>/config/license.json` off it into a local file named
   `scripts/license.json` (it is gitignored), for example with the command in
   the `session_command` output and the path changed.
2. Create a vault and store the licence in it:

   ```
   ./scripts/save-license.sh
   ```

   It creates a resource group and a Key Vault in RBAC mode if they do not
   exist, grants you `Key Vault Secrets Officer` on the vault and waits for
   that to propagate, checks the file looks like a licence, and stores it as a
   secret. It prints nothing of the licence. At the end it prints the two
   values for the next step. It is safe to run twice.

3. Name them in your module call:

   ```hcl
   module "dss" {
     source  = "amrutp24/dss/azurerm"
     version = "~> 0.2"

     license_key_vault_secret_id = "https://example-vault.vault.azure.net/secrets/dss-license"
     license_key_vault_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.KeyVault/vaults/example-vault"
     # ...
   }
   ```

From then on `terraform apply` produces a licensed VM with no browser
step.

Things worth knowing about how this works:

- **The licence is portable.** Its `instanceId` is generated during
  registration and travels inside the signed licence rather than being
  derived from the hardware, so the same licence works on a VM that did not
  exist when it was issued. That is what makes storing it viable at all.
- **The VM reads the secret itself**, through a user-assigned managed
  identity, so only the secret id reaches Terraform state and the VM's
  `custom_data`. The licence does not.
- **Two variables, because the two ids are different things.**
  `license_key_vault_secret_id` is a data-plane URL, which is what the fetch
  needs. `license_key_vault_id` is an ARM resource id, which is what an RBAC
  scope needs. Neither derives from the other without an API call, so the
  module takes both rather than guessing. Leave the vault id unset and the
  module creates no grant and exposes `identity_principal_id` instead, so you
  can grant access yourself. That is the route for a vault still on access
  policies or one in another subscription.
- **The fetch uses `python3` and the instance metadata service, not the `az`
  CLI.** Canonical's package manifest for the image this module boots lists
  `python3`, `curl`, `jq` and `walinuxagent`, and no `azure-cli`. The AWS
  sibling of this module lost this bet by shelling out to the AWS CLI on an
  Ubuntu 24.04 that has no `awscli` package, and the fetch failed in a way
  indistinguishable from success: DSS came up, unlicensed, and nothing said
  why. If the fetch fails here, the boot log says
  `warning: the licence command failed` and the reason is in
  `/tmp/dss-license-fetch.log`.

`license_json` does the same job in one step and is simpler, but it is
rendered into the boot script, so the licence ends up in Terraform state and
in the VM's `custom_data`, where anyone who can read the VM can read it back.
Prefer the secret.

## Prerequisites on a new subscription

A brand new subscription trips over three things before DSS is involved at
all.

- **Resource providers are not registered.** `Microsoft.Compute`,
  `Microsoft.Network`, `Microsoft.KeyVault` and `Microsoft.ManagedIdentity`
  all start out `NotRegistered`, and the subscription cannot even report VM
  quota until Compute is. Register them once, and check with
  `az provider show --namespace Microsoft.Compute --query registrationState`:

  ```
  az provider register --namespace Microsoft.Compute
  ```

  and likewise for the other three. Registration takes a minute or two.

- **Quota differs by VM family.** A fresh subscription is given zero vCPUs for
  several families including DSv5, while DSv3, DSv4 and the v6 families get
  ten. That is why the module defaults to `Standard_D4ds_v6`. Before changing
  `vm_size`, check what you have:

  ```
  az vm list-usage --location <region> --output table
  ```

- **Owner is not enough to write a secret.** Owner is a management-plane role.
  A vault in RBAC mode checks a data-plane role for secrets: `Key Vault
  Secrets User` to read, `Key Vault Secrets Officer` to write. Without it,
  `az keyvault secret set` fails with a 403 that reads like a networking
  problem. `save-license.sh` grants you the Officer role and waits for it.

## Option B: let the VM register itself

Not implemented here, and described so you can decide against it knowingly.

Selecting Free Edition in the browser sends one unauthenticated request:

```
POST /api/registration/initial-register-community
  userFirstName, userLastName, userEmail, instanceId
```

Dataiku answers with a signed licence and DSS writes it to
`<data_dir>/config/license.json`. A step in the bootstrap could do the same
with `curl` after the backend comes up, and then there is no licence to store
anywhere.

The reasons this module does not do that:

- It accepts Dataiku's Free Edition terms as a side effect of a boot, on
  every rebuild, rather than once deliberately.
- The name and email have to reach the boot script, which puts them in the
  VM's `custom_data`.
- It depends on an undocumented endpoint at boot. If that changes, VMs come
  up unlicensed and the reason is several layers down in a cloud-init log.

## Reading the admin API key

Separate from licensing, and needed either way. The bootstrap creates an
admin API key at boot and writes it to the path the `api_key_path` output
reports. Getting it off the host:

```
./scripts/fetch-key.sh
```

It uses Azure Run Command, so it needs `enable_run_command = true` (or
`ssh_cidr_blocks` and your own SSH, in which case read the file by hand).
`enable_run_command` creates nothing: the capability is already on the VM,
because `walinuxagent` is in the image. What can be missing is a permission,
`Microsoft.Compute/virtualMachines/runCommand/action` on the VM, and that
belongs to the caller rather than the VM. Owner, Contributor and Virtual
Machine Contributor all carry it. The module cannot grant it to someone it
cannot see.

The script waits for the file to exist, since DSS answers on its port about
half a minute before the key is written, extracts the key, writes `.apikey`
at mode 600 and checks that it authenticates against
`/public/api/admin/users/` before exiting. It never prints the key.

## `ssh_public_key` is required even with SSH closed

The VM has password authentication disabled, and azurerm refuses to create a
Linux VM with no credential at all. It refuses during `apply`, not `plan`,
because the provider only validates it during create, so a missing key passes
planning and fails part way through building. Pass a throwaway public key and
discard the private half if you never intend to use SSH. Port 22 stays closed
unless you set `ssh_cidr_blocks`.

## Script options

Both scripts find `az` themselves if it is installed but not on the PATH of
an already-open Git Bash, which is the usual state right after installing it.
Both take optional environment variables:

| Variable | Meaning |
| --- | --- |
| `SUB` | Subscription id or name. Unset uses the CLI's current subscription. |

`save-license.sh` also takes:

| Variable | Meaning |
| --- | --- |
| `LICENSE_FILE` | Local file holding the licence JSON. Default `license.json` beside the script. |
| `AWS_PARAM` | Name of an AWS SSM parameter to read the licence from instead, such as `/dss/license`. Only used when `LICENSE_FILE` does not exist. |
| `AWS_PROFILE_NAME`, `AWS_REGION_NAME` | Profile and region for that AWS read. Unset uses whatever the AWS CLI resolves. |
| `LOCATION` | Region for the new resource group and vault. Default `westeurope`. |
| `GROUP` | Resource group to hold the vault. Default `dss-vault-rg`. |
| `VAULT` | Vault name. Default is derived from the subscription id, so a second run finds the first vault. Names are global and cannot be reused for 90 days after a soft delete. |
| `SECRET` | Secret name. Default `dss-license`. |

`fetch-key.sh` also takes `VM_ID` (skip reading `terraform output -raw
vm_id`) and `KEYPATH` (default the `api_key_path` output).

`fetch-key.sh` reads Terraform outputs from the directory you run it in, or
from `TFDIR` if set, so run it from the root configuration that holds the
module, or pass `VM_ID`. It writes `.apikey` beside the script, where it is
gitignored.
