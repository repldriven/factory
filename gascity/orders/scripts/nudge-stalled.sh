#!/usr/bin/env bash
# Nudge sessions that have gone quiet, typically after a rate-limit pause.
#
# A session that hit the limit stays "active" but stops working; it needs a
# keystroke to resume. This finds the quiet ones and sends one.
#
# Deliberately not an order. Idle is not the same as stuck — an agent waiting
# on a human, or one legitimately between tasks, looks identical from here — so
# nudging on a timer would poke agents that are behaving correctly. A human
# knows the rate limit has reset; the machine does not.
#
# Delivery is wait-idle, gc's default: the message lands when the session is
# idle rather than interrupting mid-turn, so nudging a working agent is a no-op
# rather than a corruption.
#
# Usage: nudge-stalled.sh <city> <minutes> <message> [--dry-run]
set -uo pipefail
CITY="${1:?city path required}"
MINS="${2:-10}"
MSG="${3:-continue}"
DRY="${4:-}"

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

candidates=$(gc --city "$CITY" session list --json 2>/dev/null | python3 -c "
import json,sys,datetime
mins=int('$MINS')
now=datetime.datetime.now(datetime.timezone.utc)
d=json.load(sys.stdin)
rows = d if isinstance(d,list) else d.get('sessions',[])
for r in rows:
    if r.get('state') != 'active' or r.get('closed'):
        continue
    la = r.get('last_active')
    if not la:
        continue
    try:
        t = datetime.datetime.fromisoformat(la)
    except ValueError:
        continue
    age = (now - t).total_seconds() / 60
    if age >= mins:
        print(f\"{r['id']}\t{r.get('alias') or r.get('name')}\t{age:.0f}\")
")

if [ -z "$candidates" ]; then
    echo "no session idle for ${MINS}m or more"
    exit 0
fi

while IFS=$'\t' read -r id alias age; do
    [ -n "$id" ] || continue
    if [ "$DRY" = "--dry-run" ]; then
        echo "  would nudge $alias ($id), idle ${age}m"
    else
        if gc --city "$CITY" session nudge "$id" "$MSG" >/dev/null 2>&1; then
            echo "  nudged $alias ($id), idle ${age}m"
        else
            echo "  FAILED $alias ($id)" >&2
        fi
    fi
done <<< "$candidates"
