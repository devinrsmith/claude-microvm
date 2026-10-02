# Behavioural test for EXTRA_SHARES parsing (flake.nix, host-side runner),
# plus eval-level pins for the guest unit that mounts the result
# (modules/base.nix).
#
# The parser is the boundary of the feature: what it accepts is exported to
# the guest, so its refusals matter as much as its defaults — overlapping the
# VM's own state directories above all. The region is extracted from the
# *built* claude runner so the Nix-to-shell escaping is covered too. Starting
# virtiofsd and booting a guest is out of reach of a sandboxed check; that
# path was verified by hand (see the README section).
{ pkgs, lib, runner, config }:

let
  unit = config.systemd.services.microvm-extra-shares;
  evalChecks = [
    {
      name = "the guest mount unit exists and is wanted at boot";
      ok = lib.elem "multi-user.target" unit.wantedBy;
    }
    {
      name = "it runs after the agent home (where the manifest lives) is mounted";
      ok = lib.elem "home-agent.mount" unit.after;
    }
    {
      name = "it is ordered before the console login that starts the agent";
      ok = lib.elem "getty@hvc0.service" unit.before;
    }
  ];
  failedEval = lib.filter (c: !c.ok) evalChecks;
in

assert lib.assertMsg (failedEval == [ ])
  "extra-shares: ${lib.concatMapStringsSep "; " (c: c.name) failedEval}";

pkgs.runCommand "extra-shares" { } ''
  script=${runner}/bin/microvm-run
  awk '/# BEGIN extra-shares/{f=1;next} /# END extra-shares/{f=0} f' "$script" > parse.sh
  if [ ! -s parse.sh ]; then
    echo "FAIL: no extra-shares region found in the runner — did the markers move?" >&2
    exit 1
  fi

  export HOME=$TMPDIR/home
  export AGENT_DIR=$HOME/.local/share/claude-microvm/proj-abc
  mkdir -p "$AGENT_DIR/sub" "$AGENT_DIR-cri" "$HOME/data" "$HOME/notes" "$HOME/other/data" \
           "$TMPDIR/with space"
  touch "$HOME/afile"

  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  # Run the region as the runner would, in a subshell so a refusal (exit 1)
  # fails the scenario, not the driver. Prints one "host|guest|mode" per share.
  parse () {
    ( set -euo pipefail; EXTRA_SHARES="$1"; . ./parse.sh
      for i in ''${_XS_HOST+"''${!_XS_HOST[@]}"}; do
        echo "''${_XS_HOST[$i]}|''${_XS_GUEST[$i]}|''${_XS_MODE[$i]}"
      done )
  }
  accepts () { # $1 description, $2 EXTRA_SHARES, $3 expected output
    local got
    if got=$(parse "$2" 2>&1) && [ "$got" = "$3" ]; then ok "$1"
    else bad "$1: got [$got], want [$3]"; fi
  }
  refuses () { # $1 description, $2 EXTRA_SHARES
    local got
    if got=$(parse "$2" 2>&1); then bad "$1: accepted, gave [$got]"
    elif [[ "$got" != error:\ EXTRA_SHARES:* ]]; then bad "$1: refused without the usual error prefix: [$got]"
    else ok "$1"; fi
  }

  accepts "unset is a no-op"            ""                       ""
  accepts "defaults: /mnt/<basename>, ro" "$HOME/data"           "$HOME/data|/mnt/data|ro"
  accepts "~ expands to HOME"           "~/data"                 "$HOME/data|/mnt/data|ro"
  accepts "mode alone, no guest path"   "~/data:rw"              "$HOME/data|/mnt/data|rw"
  accepts "guest path alone"            "~/data:/srv/ds"         "$HOME/data|/srv/ds|ro"
  accepts "guest path and mode"         "~/data:/mnt/a/b:rw"     "$HOME/data|/mnt/a/b|rw"
  accepts "the host path is resolved"   "$HOME/other/../data"    "$HOME/data|/mnt/data|ro"
  accepts "several entries, whitespace and empties tolerated" \
          " ~/data , ,~/notes:rw" \
          "$HOME/data|/mnt/data|ro
  $HOME/notes|/mnt/notes|rw"

  refuses "a missing host path"                 "~/nope"
  refuses "a file rather than a directory"      "~/afile"
  refuses "an unknown mode"                     "~/data:/mnt/d:rx"
  refuses "too many fields"                     "~/data:/mnt/d:ro:extra"
  refuses "a guest path outside /mnt and /srv"  "~/data:/etc/data"
  refuses "a guest path of /mnt itself"         "~/data:/mnt"
  refuses "a guest path with .."                "~/data:/mnt/../etc"
  refuses "a guest path with a space (default from basename)" "$TMPDIR/with space"
  refuses "two shares at one guest path"        "~/data,~/other/data"
  refuses "one guest path nested in another"    "~/data:/mnt/x,~/notes:/mnt/x/y"
  refuses "sharing / without a guest path"      "/"
  refuses "the agent home itself"               "$AGENT_DIR:/mnt/ah"
  refuses "a directory inside the agent home"   "$AGENT_DIR/sub:/mnt/sub"
  refuses "a parent of the agent home"          "$AGENT_DIR/..:/mnt/up"
  refuses "the CRI state directory"             "$AGENT_DIR-cri:/mnt/cri"
  refuses "a parent of the state dirs (HOME)"   "~:/mnt/home"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
