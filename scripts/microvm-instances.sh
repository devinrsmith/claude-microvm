# Shared by microvm-stop and microvm-list, which are built with this file
# ahead of their own (see mkMicrovmTool in flake.nix): where launches live,
# and how to tell one that is still running.
#
# Each launch's instance dir is $XDG_RUNTIME_DIR/claude-microvm/vms/<id> (see
# "Instance dir" in flake.nix). Its instance.json says what the launch is; its
# lock, held by the launcher and QEMU until both have gone, says whether it is
# still running — a dir whose lock is free is one a killed launcher left.

vms="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-microvm/vms"

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
