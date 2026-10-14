# Guest-side guard for workspace paths whose contents execute on the HOST
# later, which is why the VM boundary does not cover them: .git/hooks and
# .git/config run on the next host-side git invocation, .claude/commands,
# .claude/agents and .mcp.json are picked up by the next unsandboxed session
# that opens the directory, and .envrc runs under the host's direnv. A
# sandboxed session that can write these persists code past the VM teardown.
#
# Straight denial breaks a workflow this project actively uses — asking the
# agent to write a project skill or register an MCP server (see
# attic/NEW-DOGS-AND-SKILLS.md) — so per the track's guiding constraint the
# guard is opt-in (WORKSPACE_GUARD=1) until it has lived a release under real
# use. It covers paths that exist at boot: it cannot make a file that is not
# there yet read-only, so a repo without .mcp.json is not protected against
# one being created. Defence in depth, not a boundary — the session contract
# says which state a run has.
#
# The same module carries WORKSPACE_MODE=ephemeral (Phase 11): /work becomes
# a guest-side overlay whose writes never reach the host — the complement of
# the guard. Passthrough stays the default: instant host-visible edits are
# the current contract and most of the point of virtiofs.
{ config, lib, pkgs, ... }:

let
  cfg = config.claude-vm.workspaceGuard;

  # Shows what an ephemeral session changed: the overlay's upper layer holds
  # exactly the delta. Whiteouts (0:0 char devices) are deletions.
  vmWorkDiff = pkgs.writeShellScriptBin "vm-work-diff" ''
    # vm-work-diff [--patch] — list (or diff) this ephemeral session's changes
    # to /work. Copy anything worth keeping to /home/agent before poweroff.
    up=/run/work-rw/upper
    lower=/run/work-lower
    if [ ! -d "$up" ]; then
      echo "vm-work-diff: not an ephemeral session (launch with WORKSPACE_MODE=ephemeral)" >&2
      exit 1
    fi
    patch=0
    [ "''${1:-}" = "--patch" ] && patch=1
    cd "$up"
    find . -mindepth 1 | sed 's|^\./||' | while IFS= read -r rel; do
      if [ -c "$up/$rel" ] && [ "$(stat -c %t:%T "$up/$rel")" = "0:0" ]; then
        echo "deleted:  $rel"
      elif [ -d "$up/$rel" ]; then
        continue
      elif [ -e "$lower/$rel" ]; then
        if [ "$patch" = 1 ]; then
          ${pkgs.diffutils}/bin/diff -u "$lower/$rel" "/work/$rel" || true
        else
          echo "modified: $rel"
        fi
      else
        if [ "$patch" = 1 ]; then
          ${pkgs.diffutils}/bin/diff -u /dev/null "/work/$rel" || true
        else
          echo "created:  $rel"
        fi
      fi
    done
  '';
in
{
  options.claude-vm.workspaceGuard = {
    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ".git/hooks"
        ".git/config"
        ".mcp.json"
        ".claude/commands"
        ".claude/agents"
        ".envrc"
      ];
      description = ''
        Paths under /work made read-only inside the guest when the session
        runs with WORKSPACE_GUARD=1. Relative to the workspace root; entries
        that do not exist at boot are skipped.
      '';
    };
  };

  config = {
    environment.systemPackages = [ vmWorkDiff ];

    systemd.services.work-ephemeral = {
      description = "Guest-side overlay over /work: writes never reach the host";
      after = [ "work.mount" "home-agent.mount" ];
      before = [ "workspace-guard.service" "getty@hvc0.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mode=""
        if [ -f /home/agent/.microvm-env ]; then
          mode=$(${pkgs.gnused}/bin/sed -n 's/^WORKSPACE_MODE=//p' /home/agent/.microvm-env | tail -n1)
        fi
        [ "$mode" = "ephemeral" ] || exit 0

        # Keep the pristine host view reachable (for vm-work-diff and the
        # overlay's lowerdir) without disturbing systemd's work.mount: a bind,
        # not a move.
        mkdir -p /run/work-lower /run/work-rw
        mount --bind /work /run/work-lower

        # The upper layer is RAM (its own tmpfs, so a runaway write fills
        # this mount, not /run): session writes cost memory and vanish at
        # poweroff — that is the feature. Overlay root attributes come from
        # the upper dir, so it must be the agent's.
        mount -t tmpfs -o mode=0755 tmpfs /run/work-rw
        install -d -o agent -g agent /run/work-rw/upper
        mkdir -p /run/work-rw/work
        mount -t overlay overlay \
          -o lowerdir=/run/work-lower,upperdir=/run/work-rw/upper,workdir=/run/work-rw/work \
          /work
        echo "work-ephemeral: /work is an overlay — writes stay in the VM (vm-work-diff lists them)"
      '';
    };

    systemd.services.workspace-guard = {
      description = "Read-only binds over workspace paths that execute on the host";
      after = [ "work.mount" "home-agent.mount" "work-ephemeral.service" ];
      before = [ "getty@hvc0.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        guard=""
        if [ -f /home/agent/.microvm-env ]; then
          guard=$(${pkgs.gnused}/bin/sed -n 's/^WORKSPACE_GUARD=//p' /home/agent/.microvm-env | tail -n1)
        fi
        [ "$guard" = "1" ] || exit 0

        guarded=""
        for rel in ${lib.escapeShellArgs cfg.paths}; do
          p="/work/$rel"
          [ -e "$p" ] || continue
          # A bind of a path over itself plus a read-only remount of that
          # bind: the write fails with EROFS inside the guest while the host
          # view stays untouched. The agent user cannot undo it — the mounts
          # belong to the init namespace, which locks them against detach
          # from any user namespace the agent can create.
          mount --bind "$p" "$p"
          mount -o remount,bind,ro "$p"
          guarded="$guarded $rel"
        done
        if [ -n "$guarded" ]; then
          echo "workspace-guard: read-only:$guarded"
        else
          echo "workspace-guard: enabled, but none of the guarded paths exist in /work"
        fi
      '';
    };
  };
}
