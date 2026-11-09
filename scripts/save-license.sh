#!/usr/bin/env bash
# Everything Azure needs before the first apply, in one run: a resource group,
# a Key Vault in RBAC mode, data-plane access for you, and the DSS licence
# stored in that vault as a secret.
#
# Prints the two values to put in your module call at the end. Never prints
# the licence itself. Safe to run twice: every step checks before it creates.
#
# Where the licence comes from:
#   LICENSE_FILE   a local file holding the licence JSON (default license.json
#                  beside this script)
#   AWS_PARAM      or the name of an AWS SSM parameter holding it, for example
#                  /dss/license. Used only when LICENSE_FILE does not exist.
#                  AWS_PROFILE_NAME and AWS_REGION_NAME select the profile and
#                  region, or the AWS CLI resolves them on its own.
#
# To get a licence file: register Free Edition once in the browser, then copy
# <data_dir>/config/license.json off the host.
set -euo pipefail

cd "$(dirname "$0")"

# The Azure CLI installer updates the Windows PATH, which a Git Bash session
# opened before the install does not see. Find az rather than making the
# caller care.
if ! command -v az >/dev/null 2>&1; then
  for d in "/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" \
           "/c/Program Files (x86)/Microsoft SDKs/Azure/CLI2/wbin"; do
    [ -x "$d/az.cmd" ] && PATH="$PATH:$d" && break
  done
fi
command -v az >/dev/null 2>&1 || {
  echo "az not found. Install it, or open a new shell so PATH picks it up." >&2
  exit 1
}

PY=python3
"$PY" -c 'import sys' >/dev/null 2>&1 || PY=python

# All optional. Unset SUB uses the CLI's current subscription.
LOCATION="${LOCATION:-westeurope}"
GROUP="${GROUP:-dss-vault-rg}"
SECRET="${SECRET:-dss-license}"
LICENSE_FILE="${LICENSE_FILE:-license.json}"
SUB_ARGS=()
[ -n "${SUB:-}" ] && SUB_ARGS=(--subscription "$SUB")
SUB_ID="$(az account show ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} --query id -o tsv)"

# A vault name is globally unique and cannot be reused for 90 days after a
# soft delete. Derive a stable one from the subscription, so a second run finds
# the vault the first created, and let VAULT override it.
VAULT="${VAULT:-dss-lic-$(printf '%s' "$SUB_ID" | md5sum | cut -c1-8)}"

echo "subscription: $SUB_ID"
echo "location:     $LOCATION"
echo "group:        $GROUP"
echo "vault:        $VAULT"
echo

if az group show --name "$GROUP" --subscription "$SUB_ID" >/dev/null 2>&1; then
  echo "resource group already exists"
else
  az group create --name "$GROUP" --location "$LOCATION" --subscription "$SUB_ID" --output none
  echo "resource group created"
fi

if az keyvault show --name "$VAULT" --subscription "$SUB_ID" >/dev/null 2>&1; then
  echo "vault already exists"
else
  # RBAC mode, not access policies. An access policy cannot be scoped
  # narrower than the whole vault, and the module grants the VM read on one
  # secret.
  az keyvault create --name "$VAULT" --resource-group "$GROUP" \
    --location "$LOCATION" --subscription "$SUB_ID" \
    --enable-rbac-authorization true --output none
  echo "vault created"
fi

VAULT_ID="$(az keyvault show --name "$VAULT" --subscription "$SUB_ID" --query id -o tsv)"
ME="$(az ad signed-in-user show --query id -o tsv)"

# Being Owner is not enough. Owner is management plane; reading or writing a
# secret in an RBAC vault needs a data-plane role, and without it the secret
# set below fails with a 403 that reads like a networking problem.
#
# The scope starts with a slash, which Git Bash would rewrite into a Windows
# path before az.exe sees it, so the guard goes on these two calls. It is not
# exported, because other tools on this machine need the conversion left on.
if MSYS_NO_PATHCONV=1 az role assignment list --assignee "$ME" --scope "$VAULT_ID" \
     --role "Key Vault Secrets Officer" --subscription "$SUB_ID" \
     --query "length(@)" -o tsv 2>/dev/null | grep -qv '^0$'; then
  echo "you already have Secrets Officer on the vault"
else
  MSYS_NO_PATHCONV=1 az role assignment create --role "Key Vault Secrets Officer" \
    --assignee "$ME" --scope "$VAULT_ID" --subscription "$SUB_ID" --output none
  echo "granted you Secrets Officer, waiting for it to propagate"
  sleep 30
fi

if az keyvault secret show --vault-name "$VAULT" --name "$SECRET" >/dev/null 2>&1; then
  echo "licence secret already present"
else
  # Deliberately not mktemp. On Git Bash mktemp returns a path like
  # /tmp/tmp.XXXX, which a native Windows binary resolves against the current
  # drive root. A file beside this script is a real path to every program
  # involved. It is gitignored.
  TMP=".license.tmp"
  trap 'rm -f "$TMP"' EXIT
  : > "$TMP"
  chmod 600 "$TMP" 2>/dev/null || true

  if [ -f "$LICENSE_FILE" ]; then
    cp "$LICENSE_FILE" "$TMP"
    echo "licence read from $LICENSE_FILE"
  elif [ -n "${AWS_PARAM:-}" ]; then
    # Leading-slash parameter name, so the same path-conversion guard applies.
    [ -n "${AWS_PROFILE_NAME:-}" ] && export AWS_PROFILE="$AWS_PROFILE_NAME"
    [ -n "${AWS_REGION_NAME:-}" ] && export AWS_DEFAULT_REGION="$AWS_REGION_NAME"
    MSYS_NO_PATHCONV=1 aws ssm get-parameter --name "$AWS_PARAM" --with-decryption \
      --query Parameter.Value --output text > "$TMP"
    echo "licence read from AWS parameter $AWS_PARAM"
  else
    echo "no licence found: put it in $LICENSE_FILE, or set LICENSE_FILE or AWS_PARAM" >&2
    exit 1
  fi

  "$PY" - "$TMP" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
try:
    doc = json.loads(raw)
except Exception:
    sys.exit("what was read is not JSON, so it is not the licence")
missing = {"content", "r1Pub", "r1PubSig", "r1Sig"} - set(doc)
if missing:
    sys.exit("missing expected licence fields: %s" % sorted(missing))
print("licence looks right: %d bytes" % len(raw))
PY

  az keyvault secret set --vault-name "$VAULT" --name "$SECRET" \
    --file "$TMP" --output none
  echo "licence stored in the vault"
fi

SECRET_ID="https://$VAULT.vault.azure.net/secrets/$SECRET"

echo
echo "Put these two in your module call:"
echo
echo "  license_key_vault_secret_id = \"$SECRET_ID\""
echo "  license_key_vault_id        = \"$VAULT_ID\""
