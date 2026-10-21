# The launch scope (flake.nix, "Launch scope"), against a real systemd --user.
#
# tests/instance-share.nix checks, with systemd-run stubbed, that the launcher
# asks for a scope and binds its daemons to it. Whether that does anything is
# up to systemd, so here it runs for real: a NixOS VM with a lingering user,
# the built launcher started from a login session as it would be from a
# terminal, real systemd-run, real virtiofsd. Only QEMU is replaced, by a
# stand-in that stays up — as a VM would — until told to exit.
#
#   - the launcher and its "VM" run in the launch scope, in
#     claude_microvm.slice, and the three virtiofsd units are bound to it and
#     tagged in the journal with the launch's ID;
#   - killing the launcher with SIGKILL, which no trap sees, leaves the daemons
#     running while the VM does, and systemd stops them when it exits;
#   - `systemctl --user stop <scope>` stops the VM, and the launcher's cleanup
#     still runs: its daemons and instance dir go;
#   - a VM that exits normally leaves nothing.
{ pkgs, lib, runner }:

let
  # The built launcher with QEMU, and only QEMU, swapped for $FAKE_QEMU.
  launcher = pkgs.runCommand "microvm-run-fake-qemu" { } ''
    sed -E 's|^( *)bash <\(|\1"$FAKE_QEMU" <(|' ${runner}/bin/microvm-run > $out
    grep -q '"$FAKE_QEMU" <(' $out || { echo "the QEMU invocation moved; update the pattern" >&2; exit 1; }
    chmod +x $out
  '';
  # Stays up, like a running VM, until $FAKE_QEMU_EXIT appears.
  fakeQemu = pkgs.writeShellScript "fake-qemu" ''
    echo $$ > "$FAKE_QEMU_PID"
    while [ ! -e "$FAKE_QEMU_EXIT" ]; do sleep 0.2; done
  '';
in
pkgs.testers.runNixOSTest {
  name = "launch-scope";

  nodes.machine = { ... }: {
    users.users.alice = { isNormalUser = true; uid = 1000; linger = true; };
    # A logind session for `su`, so the launcher starts where a terminal
    # login's shell would: in a session scope, outside the user manager.
    security.pam.services.su.startSession = true;
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json, shlex
    from datetime import timedelta

    ROOT = "/run/user/1000/claude-microvm"

    def alice(cmd):
        env = "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
        return "su -l alice -c " + shlex.quote(env + cmd)

    def user(args):
        return alice("systemctl --user " + args)

    def prop(unit, name):
        return machine.succeed(user(f"show -p {name} --value {unit}")).strip()

    def launch(n):
        # A project name long enough that the launcher keeps only its first
        # 12 characters, so the instance dir's socket paths under the real
        # /run/user/1000 are as long as they get by default.
        project = f"{n}-a-long-project-name"
        machine.succeed(alice(
            f"mkdir -p ~/{project} && cd ~/{project} && "
            f"FAKE_QEMU=${fakeQemu} FAKE_QEMU_PID=/tmp/qemu{n}.pid FAKE_QEMU_EXIT=/tmp/exit{n} NO_PAUSE=1 "
            f"setsid -f ${launcher} </dev/null >/tmp/launch{n}.log 2>&1"))
        machine.wait_until_succeeds(f"test -s /tmp/qemu{n}.pid", timeout=timedelta(seconds=120))
        path = machine.succeed(f"ls -d {ROOT}/{project[:12]}-claude-vm-*/instance.json").strip()
        inst = json.loads(machine.succeed(f"cat {path}"))
        return inst, path.rsplit("/", 1)[0], machine.succeed(f"cat /tmp/qemu{n}.pid").strip()

    def daemons(inst):
        return [inst["units"][k] for k in ("work", "agentHome", "guest")]

    def wait_stopped(unit):
        machine.wait_until_fails(user(f"is-active --quiet {unit}"), timeout=timedelta(seconds=60))

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")

    with subtest("the launch runs in its scope, and its daemons are bound to it"):
        inst, d, qemu = launch(1)
        scope = inst["units"]["scope"]
        assert scope, f"no scope recorded: {inst}"
        machine.succeed(user(f"is-active --quiet {scope}"))
        assert prop(scope, "Slice") == "claude_microvm.slice"
        cgroup = prop(scope, "ControlGroup")
        for pid in (inst["pid"], qemu):
            got = machine.succeed(f"cut -d: -f3 /proc/{pid}/cgroup").strip()
            assert got == cgroup, f"pid {pid} is in {got}, not the scope's {cgroup}"
        for u in daemons(inst):
            machine.succeed(user(f"is-active --quiet {u}"))
            assert scope in prop(u, "BindsTo").split(), f"{u} is not bound to {scope}"
            assert scope in prop(u, "After").split(), f"{u} is not ordered after {scope}"
            assert prop(u, "Slice") == "claude_microvm.slice"
        machine.succeed(f"journalctl MICROVM_ID={inst['id']} -o cat | grep -q .")

    with subtest("SIGKILL of the launcher: the daemons outlive it while the VM runs, then stop"):
        machine.succeed(f"kill -KILL {inst['pid']}")
        machine.wait_until_fails(f"kill -0 {inst['pid']}", timeout=timedelta(seconds=10))
        machine.sleep(2)
        machine.succeed(user(f"is-active --quiet {scope}"))
        for u in daemons(inst):
            machine.succeed(user(f"is-active --quiet {u}"))
        machine.succeed(f"kill {qemu}")
        for u in daemons(inst):
            wait_stopped(u)
        wait_stopped(scope)
        # No trap ran, so the instance dir is still there: removing it is the
        # stale sweep's job, which has not been written yet.
        machine.succeed(f"rm -rf {d}")

    with subtest("stopping the scope stops the VM, and the launcher still cleans up"):
        inst, d, qemu = launch(2)
        machine.succeed(user(f"stop {inst['units']['scope']}"))
        machine.wait_until_fails(f"test -e {d}", timeout=timedelta(seconds=60))
        for u in daemons(inst):
            wait_stopped(u)

    with subtest("a VM that exits normally leaves nothing"):
        inst, d, qemu = launch(3)
        machine.succeed("touch /tmp/exit3")
        machine.wait_until_fails(f"test -e {d}", timeout=timedelta(seconds=60))
        for u in daemons(inst) + [inst["units"]["scope"]]:
            wait_stopped(u)
        machine.succeed(f"test ! -e {ROOT}")
        machine.fail("grep -i error /tmp/launch3.log")
  '';
}
