# microvm-list (scripts/microvm-list.sh), against fake launches: instance dirs
# with an instance.json, two whose lock is held — running — and one whose lock
# is free, as a killed launcher leaves it.
#
#   - the table: one row per launch, running ones first and then the oldest
#     first, stale ones marked, the project with $HOME as ~;
#   - --json: every instance.json, unchanged, with "running" and "dir" added,
#     in the same order;
#   - a dir without an instance.json is skipped, and no launches at all is
#     not an error: a message for the table, [] for --json.
{ pkgs, lib, microvmList }:

pkgs.runCommand "microvm-list" { nativeBuildInputs = with pkgs; [ jq util-linux ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  export XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home
  VMS=$XDG_RUNTIME_DIR/claude-microvm/vms
  list=${microvmList}/bin/microvm-list
  run () { rc=0; msg=$("$list" "$@" 2>$TMPDIR/err) || rc=$?; }

  run
  if [ $rc = 0 ] && [ -z "$msg" ] && grep -q 'no launches' $TMPDIR/err; then
    ok "no launches: a message on stderr, exit 0"
  else bad "none: rc $rc, out [$msg], err [$(cat $TMPDIR/err)]"; fi
  run --json
  [ $rc = 0 ] && [ "$(jq -c . <<< "$msg")" = "[]" ] && ok "no launches: --json prints []" || bad "none --json: rc $rc [$msg]"

  pids=()
  # fake <id> <flavor> <started> <work> [stale]
  fake () {
    local d=$VMS/$1
    mkdir -p $d; : > $d/lock
    jq -n --arg id $1 --arg flavor $2 --arg started $3 --arg work $4 \
      '{version: 1, id: $id, flavor: $flavor, started: $started, work: $work, units: {scope: ("claude_microvm-" + $id + ".scope")}}' \
      > $d/instance.json
    [ "''${5:-}" = stale ] && return
    flock $d/lock sleep 600 &
    pids+=($!)
    for _ in $(seq 1 50); do flock -n $d/lock true || break; sleep 0.1; done
  }
  fake aaaaaaaaaaaa claude 2026-10-22T10:00:00Z $HOME/projects/alpha
  fake bbbbbbbbbbbb gemini 2026-10-22T09:00:00Z /srv/beta
  fake cccccccccccc claude 2026-10-22T08:00:00Z $HOME/gamma stale
  mkdir -p $VMS/dddddddddddd        # no instance.json: not a launch
  # Running, but its instance.json claims to be aaaaaaaaaaaa — copied from that
  # launch's dir, say. It is not reported as that launch, nor as itself.
  fake eeeeeeeeeeee claude 2026-10-22T07:00:00Z /srv/copy
  jq '.id = "aaaaaaaaaaaa"' $VMS/eeeeeeeeeeee/instance.json > $TMPDIR/j && mv $TMPDIR/j $VMS/eeeeeeeeeeee/instance.json

  run
  expected=$(printf '%s\n' \
    "ID            STATE    FLAVOR  STARTED               PROJECT" \
    "bbbbbbbbbbbb  running  gemini  2026-10-22T09:00:00Z  /srv/beta" \
    "aaaaaaaaaaaa  running  claude  2026-10-22T10:00:00Z  ~/projects/alpha" \
    "cccccccccccc  stale    claude  2026-10-22T08:00:00Z  ~/gamma")
  if [ $rc = 0 ] && [ "$msg" = "$expected" ]; then
    ok "the table: running first, oldest first, stale marked, ~ for \$HOME, the dir without instance.json skipped"
  else bad "table: rc $rc"; diff <(echo "$expected") <(echo "$msg") >&2 || true; fi
  grep -q "skipping $VMS/eeeeeeeeeeee: its instance.json is not this launch's" $TMPDIR/err \
    && ok "an instance.json whose id is not its dir's is skipped, with a warning" \
    || bad "no warning for the mismatched instance.json: $(cat $TMPDIR/err)"

  run --json
  if [ $rc = 0 ] \
     && [ "$(jq -r '[.[].id] | join(" ")' <<< "$msg")" = "bbbbbbbbbbbb aaaaaaaaaaaa cccccccccccc" ] \
     && [ "$(jq -r '[.[].running] | join(" ")' <<< "$msg")" = "true true false" ] \
     && [ "$(jq -r '.[1].dir' <<< "$msg")" = "$VMS/aaaaaaaaaaaa" ] \
     && [ "$(jq -r '.[1].units.scope' <<< "$msg")" = "claude_microvm-aaaaaaaaaaaa.scope" ] \
     && [ "$(jq -r '.[1].work' <<< "$msg")" = "$HOME/projects/alpha" ]; then
    ok "--json: each instance.json as it is, plus running and dir, in the table's order"
  else bad "--json: rc $rc: $msg"; fi

  run --bogus
  [ $rc = 2 ] && ok "an unknown argument is a usage error (exit 2)" || bad "bad arg: rc $rc"

  kill "''${pids[@]}" 2>/dev/null || true
  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
