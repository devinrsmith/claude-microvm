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
{ config, lib, pkgs, ... }:

let
  cfg = config.claude-vm.workspaceGuard;
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
    systemd.services.workspace-guard = {
      description = "Read-only binds over workspace paths that execute on the host";
      after = [ "work.mount" "home-agent.mount" ];
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
