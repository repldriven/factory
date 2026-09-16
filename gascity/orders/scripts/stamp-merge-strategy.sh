#!/usr/bin/env bash
# Stamp merge_strategy on lane work beads that carry none.
#
# The refinery reads merge_strategy off the WORK bead and falls back to
# "direct", which pushes straight at the target branch. Every rig's main is
# PR-only (a ruleset on both queenswood and mono), so a direct push is refused
# and the work stalls assigned to the refinery with nothing to show for it.
#
# Nothing in the gascity or gastown packs sets this key, and decomposition
# creates the work beads mid-run, so a value stamped on the root bead at launch
# never reaches them. This closes that gap from outside, at zero model cost.
#
# Narrow by design. Only beads already in the polecat/refinery lane are
# touched: one assigned to either role, or one carrying metadata.branch because
# a polecat has pushed. Assignment happens well before the polecat finishes, so
# the stamp lands before the refinery ever reads it. A bead that already names a
# strategy is left alone whatever it says, so a deliberate "direct" survives.
#
# Every rig the city knows is swept, HQ excluded, so adding a rig to city.toml
# is enough. STAMP_RIG narrows the sweep to one rig.

set -uo pipefail

CITY="${GC_CITY:-$(cd "$(dirname "$0")/../.." && pwd)}"
STRATEGY="${STAMP_STRATEGY:-mr}"

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

if [ -n "${STAMP_RIG:-}" ]; then
    rigs="$STAMP_RIG"
else
    rigs="$(gc --city "$CITY" rig list --json 2>/dev/null \
        | jq -r --arg city "$CITY" \
            '(if type=="array" then . else .rigs // [] end)[] | select(.path != $city) | .name')" || {
        echo "could not list rigs" >&2; exit 1; }
fi

select_lane='
    (if type=="array" then . else .issues // [] end)[]
    | select((.status // "") != "closed")
    | select((.metadata.merge_strategy // "") == "")
    | select(
        ((.metadata.branch // "") != "")
        or ((.assignee // "") | test("polecat|refinery"))
      )
    | .id'

total_failed=0
for RIG in $rigs; do
    beads="$(gc --city "$CITY" bd list --rig "$RIG" --exclude-type convoy,epic --json 2>/dev/null)" || {
        echo "could not list beads for rig $RIG" >&2; total_failed=$((total_failed + 1)); continue; }

    stamped=0 failed=0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        if gc --city "$CITY" bd update "$id" --rig "$RIG" \
               --set-metadata "merge_strategy=$STRATEGY" >/dev/null 2>&1; then
            echo "  stamped $id merge_strategy=$STRATEGY"
            stamped=$((stamped + 1))
        else
            echo "  FAILED $id" >&2
            failed=$((failed + 1))
        fi
    done < <(printf '%s' "$beads" | jq -r "$select_lane")

    echo "stamped=$stamped failed=$failed strategy=$STRATEGY rig=$RIG"
    total_failed=$((total_failed + failed))
done

[ "$total_failed" -eq 0 ]
