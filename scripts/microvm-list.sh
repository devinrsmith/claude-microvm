# List launches: what is running, and what a killed launcher left behind.
#
#   microvm-list [--json]
#
# One line per instance dir under $XDG_RUNTIME_DIR/claude-microvm/vms/, or
# under <ns>/vms/ with MICROVM_NAMESPACE=<ns> (see
# microvm-instances.sh): its ID, whether it is still running or left over
# ("stale": its lock is free, so its launcher has gone without cleaning up),
# the flavor, its name (MICROVM_NAME, or its project's basename; "-" for a
# launch from before names were recorded), when it started, and the project.
# Running ones first, then the oldest first. A dir whose instance.json is not
# its own (its id is not the dir's name) is skipped with a warning. `set -euo pipefail` comes from
# writeShellApplication.
#
# --json prints instead one array of every launch's instance.json, each with
# two fields added: "running" (true or false) and "dir" (its instance dir) —
# for tooling, which should read this rather than parse the table.
#
# Exit status: 0, also when there are none; 2 usage.

json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    -h|--help) echo "usage: microvm-list [--json]" >&2; exit 2 ;;
    *) echo "microvm-list: unknown argument: $1" >&2; echo "usage: microvm-list [--json]" >&2; exit 2 ;;
  esac
  shift
done
use_namespace

# $vms (set by use_namespace) and running() come from microvm-instances.sh.
entries=()
if [ -d "$vms" ]; then
  for d in "$vms"/*/; do
    d="${d%/}"
    [ -f "$d/instance.json" ] || continue
    if ! own_instance "$d"; then
      echo "microvm-list: skipping $d: its instance.json is not this launch's (its id is not $(basename "$d"))" >&2
      continue
    fi
    if running "$d"; then r=true; else r=false; fi
    # A dir being removed as we look may lose its instance.json under us.
    e="$(jq -c --argjson running "$r" --arg dir "$d" '. + {running: $running, dir: $dir}' "$d/instance.json" 2>/dev/null)" || continue
    entries+=("$e")
  done
fi

all="$(printf '%s\n' ${entries[@]+"${entries[@]}"} | jq -s 'sort_by((if .running then 0 else 1 end), .started)')"

if [ "$json" = 1 ]; then
  printf '%s\n' "$all"
  exit 0
fi

if [ "$(jq length <<< "$all")" = 0 ]; then
  echo "microvm-list: no launches under $vms" >&2
  exit 0
fi

# The project with $HOME as ~, as the session contract shows it.
jq -r --arg home "${HOME:-}" '
  ["ID", "STATE", "FLAVOR", "NAME", "STARTED", "PROJECT"],
  (.[] | [.id, (if .running then "running" else "stale" end), .flavor, (.name // "-"), .started,
          (if $home != "" and (.work | startswith($home + "/")) then "~" + (.work | ltrimstr($home)) else .work end)])
  | @tsv' <<< "$all" | column -t -s $'\t'
