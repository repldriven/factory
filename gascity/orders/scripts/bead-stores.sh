#!/usr/bin/env bash
# Print every bead store in the city, one "<name>\t<path>" per line.
#
# Derived from `gc rig list --json`, which reports the HQ alongside the rigs, so
# adding a rig to city.toml is enough — nothing here needs editing. The plain
# `gc rig list` output does not name the rigs, only the HQ; the JSON form does.
#
# Usage: bead-stores.sh [city-path]
set -euo pipefail
CITY="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
gc --city "$CITY" rig list --json 2>/dev/null \
  | jq -r '(if type=="array" then . else .rigs // [] end)[] | "\(.name)\t\(.path)"' \
  | while IFS=$'\t' read -r name path; do
        [ -d "$path/.beads" ] && printf '%s\t%s\n' "$name" "$path"
    done
