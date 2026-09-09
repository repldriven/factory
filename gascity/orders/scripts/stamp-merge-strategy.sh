#!/usr/bin/env bash
# Stamp merge_strategy on lane work beads that carry none.
#
# The refinery reads merge_strategy off the WORK bead and falls back to
# "direct", which pushes straight at the target branch. queenswood's main is
# PR-only, so a direct push is refused and the work stalls assigned to the
# refinery with nothing to show for it.
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

set -uo pipefail

CITY="${GC_CITY:-$(cd "$(dirname "$0")/../.." && pwd)}"
RIG="${STAMP_RIG:-queenswood}"
STRATEGY="${STAMP_STRATEGY:-mr}"

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

beads="$(gc --city "$CITY" bd list --rig "$RIG" --exclude-type convoy,epic --json 2>/dev/null)" || {
    echo "could not list beads for rig $RIG" >&2; exit 1; }

select_lane='
    (if type=="array" then . else .issues // [] end)[]
    | select((.status // "") != "closed")
    | select((.metadata.merge_strategy // "") == "")
    | select(
        ((.metadata.branch // "") != "")
        or ((.assignee // "") | test("polecat|refinery"))
      )
    | .id'

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
[ "$failed" -eq 0 ]
