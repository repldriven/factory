#!/usr/bin/env bash
# Print the newest gap report for a TDD, as a rig-relative path, or nothing.
#
# Reports are stamped <tdd>-YYYY-MM-DD-HHMMSS.md (UTC) because gap analysis is
# iterative and each run is evidence of what was true when it ran. Every dated
# name has the same shape, so lexical order is chronological order — which a
# date alone would not give: a same-day second run needs a suffix, and "-"
# precedes "." in ASCII, so <tdd>-2026-09-09-2.md loses to <tdd>-2026-09-09.md.
#
# Dated reports are preferred explicitly rather than by sorting them together
# with the undated one: "-" sorts before "." in ASCII, so <tdd>-2026-09-09.md
# would lose to a stale <tdd>.md left over from before this convention.
#
# Each candidate is tested for existence rather than left to nullglob, which
# only drops patterns containing wildcards — a bare <tdd>.md that does not exist
# would otherwise survive and be reported as the newest.
#
# Usage: latest-gap-report.sh <rig-path> <tdd-name>
set -euo pipefail
rig="${1:?rig path required}"
tdd="${2:?tdd name required}"
shopt -s nullglob

dated=()
for f in "$rig/docs/tdd/gaps/$tdd"-*.md; do
    [ -f "$f" ] && dated+=("$f")
done

if [ ${#dated[@]} -gt 0 ]; then
    printf '%s\n' "${dated[@]}" | LC_ALL=C sort | tail -1 | sed "s|^$rig/||"
elif [ -f "$rig/docs/tdd/gaps/$tdd.md" ]; then
    printf '%s\n' "docs/tdd/gaps/$tdd.md"
fi
