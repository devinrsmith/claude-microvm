# Read one key from the launcher's .microvm-env as data, never as code.
#
#   microvm-env-get <env-file> <KEY>
#
# Prints the value of the last `KEY=` line, literally, or nothing when the file
# or the key is absent. `set -euo pipefail` comes from writeShellApplication.
#
# The guest's root services (cri-proxy-env, cri-activate in modules/cri.nix)
# need a few keys from this file, but it sits in /home/agent, which the agent
# can write — and `sudo systemctl restart` reruns a service on demand. Sourcing
# it as root would run whatever the agent appended. So nothing here evaluates
# the file: no expansion, no quote removal, no command substitution.
#
# Last match wins, as it does when the agent's login shell sources the file:
# EXTRA_ENV is written after everything else so that it can override a key.
# This is the same reading microvm-policy's services use for its own keys
# (`sed -n 's/^KEY=//p' | tail -n1`).
#
# The value is the raw text after `KEY=`. The keys read this way are written
# unquoted by the launcher, or are %q-quoted values that contain nothing %q
# would escape; anything else comes back with its quoting intact, and the
# caller's own validation turns it away.

env_file="${1:?usage: microvm-env-get <env-file> <KEY>}"
key="${2:?usage: microvm-env-get <env-file> <KEY>}"

if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "microvm-env-get: not a variable name: '$key'" >&2
  exit 2
fi

[ -f "$env_file" ] || exit 0

value=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "$key="*) value="${line#"$key="}" ;;
  esac
done < "$env_file"

printf '%s\n' "$value"
