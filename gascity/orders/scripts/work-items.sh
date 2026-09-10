#!/usr/bin/env bash
# Work items for a build-basic run, scoped by its implementation convoy.
#
# Scoping matters: WI numbers restart every run, so a title match alone mixes
# this run's WI-1 with the last one's. The run root records the convoy the
# decomposer created as gc.build.implementation_convoy_id, and that is the only
# thing that says which work items belong to which run.
#
# Usage: work-items.sh <city> <rig> [run-root-id]   (default: newest build-basic)
set -uo pipefail
CITY="${1:?city}"; RIG="${2:?rig}"; RUN="${3:-}"

if [ -z "$RUN" ]; then
    RUN=$(gc --city "$CITY" bd list --rig "$RIG" --all --json 2>/dev/null \
        | jq -r '(if type=="array" then . else .issues//[] end)
                 | map(select((.title // "") == "build-basic"))
                 | sort_by(.created_at) | reverse | .[0].id // empty')
fi
[ -n "$RUN" ] || { echo "no build-basic run found in rig $RIG" >&2; exit 1; }

root=$(gc --city "$CITY" bd show "$RUN" --rig "$RIG" 2>/dev/null)
state=$(printf '%s' "$root" | head -1)
echo "run: $state"

# Publish is the end state worth surfacing: a run can be all-items-closed and
# still not have produced a PR.
printf '%s' "$root" | grep -E 'gc.publish_outcome|gc.publish_pr_url' | sed 's/^/     /'

cid=$(printf '%s' "$root" | grep -oE 'gc.build.implementation_convoy_id: \S+' | awk '{print $2}')
if [ -z "$cid" ]; then
    echo "     decomposition has not created the implementation convoy yet"
    exit 0
fi
echo
gc --city "$CITY" convoy status "$cid" 2>&1 | grep -vE '^\s*$'
