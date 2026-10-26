# Shared by microvm-stop and microvm-list, which are built with this file
# ahead of their own (see mkMicrovmTool in flake.nix): where launches live,
# and how to tell one that is still running.
#
# Each launch's instance dir is $XDG_RUNTIME_DIR/claude-microvm/vms/<id>, or
# $XDG_RUNTIME_DIR/<ns>/vms/<id> for a launch with MICROVM_NAMESPACE=<ns> (see
# "Namespace" and "Instance dir" in flake.nix). Its instance.json says what the
# launch is; its lock, held by the launcher and QEMU until both have gone, says
# whether it is still running — a dir whose lock is free is one a killed
# launcher left.
#
# $ns_pattern and $ns_max come first, from flake.nix, so the tools and the
# launcher check a namespace against the same rule.

# Sets $vms for MICROVM_NAMESPACE, as the launcher reads it, else the default.
# A tool looks in one namespace at a time, as a launch lives in one. Only the
# variable selects it, as for the launcher: a namespace is for tools that run
# launches of their own, and they set it for every call.
use_namespace() {
  local ns="${MICROVM_NAMESPACE:-}" root
  if [ -z "$ns" ]; then
    root=claude-microvm
  elif [[ "$ns" =~ $ns_pattern ]] && [ "${#ns}" -le "$ns_max" ]; then
    root="$ns"
  else
    echo "$(basename "$0"): MICROVM_NAMESPACE=$ns is not a namespace: up to $ns_max characters of lowercase words (a-z, 0-9, _) joined by single dashes, starting with a letter" >&2
    exit 2
  fi
  vms="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$root/vms"
}

# Whether a launch still holds its lock. The lock file is opened read-only
# and never created: a dir mid-removal must not get a new file put back in it.
running() { # instance dir
  local fd
  [ -e "$1/lock" ] || return 1
  # Braces: `exec` with only redirections keeps them, so a 2>/dev/null on it
  # would silence the rest of the script.
  { exec {fd}<"$1/lock"; } 2>/dev/null || return 1
  if flock -n "$fd"; then exec {fd}<&-; return 1; fi
  exec {fd}<&-
  return 0
}

# Whether a dir's instance.json is its own: its id is the dir's name. One that
# is not — edited by hand, or copied from another launch's dir — describes
# some other launch, and nothing here acts on it or reports it as this one.
own_instance() { # instance dir
  [ "$(jq -r .id "$1/instance.json" 2>/dev/null)" = "$(basename "$1")" ]
}
