# Test for WORK_CACHE (flake.nix, host-side runner): a bad value is refused
# before the launcher touches the host, and the value reaches the /work
# virtiofsd — and only that one, since the agent-home share keeps the default.
{ pkgs, lib, runner }:

pkgs.runCommand "work-cache" { } ''
  script=${runner}/bin/microvm-run
  mkdir -p "$TMPDIR/w"

  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  if WORK_CACHE=bogus WORK_DIR=$TMPDIR/w "$script" >/dev/null 2>cache.err; then
    bad "WORK_CACHE=bogus was accepted"
  elif grep -q "WORK_CACHE must be" cache.err; then
    ok "an invalid WORK_CACHE is refused"
  else
    bad "WORK_CACHE=bogus failed, but not with the validation message:"; cat cache.err >&2
  fi

  if [ "$(grep -c -- '--cache="$WORK_CACHE"' "$script")" -eq 1 ]; then
    ok "--cache is passed to exactly one virtiofsd"
  else
    bad "expected --cache=\"\$WORK_CACHE\" exactly once in the runner"
  fi
  if awk '/--shared-dir="\$WORK"/{f=1} f && /--cache="\$WORK_CACHE"/{found=1} /^ *fi$/{f=0} END{exit !found}' "$script"; then
    ok "...and it is the /work one"
  else
    bad "--cache is not on the virtiofsd serving \$WORK"
  fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
