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

  # --- namespaces --------------------------------------------------------------
  # A launch with MICROVM_NAMESPACE=custom-namespace lives under
  # custom-namespace/vms/, and is listed with the same variable, and nowhere
  # else. There is no flag.
  DEFAULT_VMS=$VMS; VMS=$XDG_RUNTIME_DIR/custom-namespace/vms
  fake ffffffffffff claude 2026-10-22T11:00:00Z /srv/namespaced
  VMS=$DEFAULT_VMS
  MICROVM_NAMESPACE=custom-namespace run
  if [ $rc = 0 ] && [ "$(tail -n +2 <<< "$msg" | awk '{ print $1 }')" = ffffffffffff ]; then
    ok "MICROVM_NAMESPACE: the launches under <ns>/vms/, and only those"
  else bad "MICROVM_NAMESPACE: rc $rc: $msg"; fi
  MICROVM_NAMESPACE=custom-namespace run --json
  [ $rc = 0 ] && [ "$(jq -r '[.[].id] | join(" ")' <<< "$msg")" = ffffffffffff ] \
    && [ "$(jq -r '.[0].dir' <<< "$msg")" = "$XDG_RUNTIME_DIR/custom-namespace/vms/ffffffffffff" ] \
    && ok "...and --json the same" || bad "MICROVM_NAMESPACE --json: rc $rc: $msg"
  run
  ! grep -q ffffffffffff <<< "$msg" && ok "the default namespace does not list a namespaced launch" \
    || bad "default listed the namespaced launch: $msg"
  refused=0
  for ns in Custom a--b -a a- 1a "a b" $(printf 'a%.0s' $(seq 1 33)); do
    MICROVM_NAMESPACE="$ns" run
    if [ $rc = 2 ] && grep -q 'is not a namespace' $TMPDIR/err; then refused=$((refused + 1))
    else bad "namespace '$ns' accepted: rc $rc"; fi
  done
  [ $refused = 7 ] && ok "a MICROVM_NAMESPACE that breaks the rule is a usage error"
  run --namespace custom-namespace
  [ $rc = 2 ] && ok "there is no --namespace flag" || bad "--namespace accepted: rc $rc"

  run --bogus
  [ $rc = 2 ] && ok "an unknown argument is a usage error (exit 2)" || bad "bad arg: rc $rc"

  kill "''${pids[@]}" 2>/dev/null || true
  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
