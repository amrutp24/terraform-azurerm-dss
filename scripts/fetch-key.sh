#!/usr/bin/env bash
# Read the admin API key the bootstrap wrote at boot, and save it to .apikey.
#
# Uses Azure Run Command, which needs no key pair, no open port 22 and nothing
# installed on the VM: walinuxagent is already in the image. The caller needs
# Microsoft.Compute/virtualMachines/runCommand/action on the VM, which Owner,
# Contributor and Virtual Machine Contributor all carry.
#
# The key is never printed. It goes from the VM to .apikey (mode 600), and this
# only reports its length and prefix.
set -euo pipefail

# Terraform outputs come from where you ran this, or TFDIR; .apikey is written
# beside the script, where it is gitignored.
TFDIR="${TFDIR:-$PWD}"
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

# All optional. VM_ID skips reading `terraform -chdir="$TFDIR" output -raw vm_id`, and SUB
# picks a subscription when the VM is not in the CLI's current one. KEYPATH
# is read from the module's api_key_path output when unset.
VM_ID="${VM_ID:-$(terraform -chdir="$TFDIR" output -raw vm_id)}"
KEYPATH="${KEYPATH:-$(terraform -chdir="$TFDIR" output -raw api_key_path 2>/dev/null || echo /var/lib/dataiku-terraform-key.json)}"
SUB_ARGS=()
[ -n "${SUB:-}" ] && SUB_ARGS=(--subscription "$SUB")

echo "vm:      $VM_ID"
echo "reading: $KEYPATH"

# DSS answers on its port before the bootstrap has written the key: it has to
# wait for the backend to accept dsscli first, which is a good half minute
# later. Waiting for the file on the host is the condition that matters, so
# the script run on the VM does that waiting rather than this guessing a delay.
# Run Command executes as root already, so no sudo.
REMOTE="for i in \$(seq 1 60); do [ -s $KEYPATH ] && break; sleep 5; done; cat $KEYPATH"

# VM_ID begins with a slash, which Git Bash would rewrite into a Windows path
# before az.exe sees it. The guard goes on this one call and is not exported,
# because other tools on the machine need the conversion left on.
RESULT="$(MSYS_NO_PATHCONV=1 az vm run-command invoke --ids "$VM_ID" \
  ${SUB_ARGS[@]+"${SUB_ARGS[@]}"} \
  --command-id RunShellScript --scripts "$REMOTE" \
  --query "value[0].message" --output tsv)"

# The message is "[stdout] ... [stderr] ...". Pull the key out of it and write
# it straight to the file.
umask 077
printf '%s' "$RESULT" | "$PY" -c '
import re, sys
raw = sys.stdin.read()
m = re.search(r"dkuaps-[A-Za-z0-9]+", raw)
if not m:
    sys.exit("no DSS key in the output; the bootstrap may not have written one yet")
open(".apikey", "w").write(m.group(0))
print("wrote .apikey: %d chars, starts %s" % (len(m.group(0)), m.group(0)[:7]))
'
chmod 600 .apikey 2>/dev/null || true

# Prove it actually authenticates, rather than assuming. The credential goes
# in on stdin so it never appears in a process listing.
HOST="$(terraform -chdir="$TFDIR" output -raw dss_url)"
CODE="$(printf 'user = "%s:"\n' "$(cat .apikey)" \
  | curl -s -K - -o /dev/null -w '%{http_code}' "$HOST/public/api/admin/users/")"
echo "auth check against $HOST: http=$CODE"
[ "$CODE" = "200" ] || { echo "the key did not authenticate" >&2; exit 1; }
