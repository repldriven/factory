#!/usr/bin/env bash
# Snapshot agent worktree HEADs onto branches, and record them.
#
# Gas City creates one worktree per work bead under <rig>/worktrees/<bead>, and
# leaves each on a DETACHED HEAD. Agents commit into those. Nothing points at
# those commits, so pruning a worktree makes the work unreachable.
#
# Launching build-basic with the default push=false / open_pr=false means the
# pipeline never pushes or opens a PR either, so the commits have no other route
# out. This script gives every worktree HEAD a branch (agent/<bead>) and writes a
# manifest so the set can be tracked as it grows.
#
# Idempotent: existing branches are advanced only if the worktree has moved on,
# and are never rewound. Safe to run while agents are working.
#
# The manifest is written outside the repository, one per rig. It is derived
# state — every row can be rebuilt from the agent/* branches, which are the
# durable artifact — and the order rewrites it every 15 minutes, so tracking it
# would leave the working tree permanently dirty.
#
# Every rig the city knows is swept, HQ excluded, so adding a rig to city.toml
# is enough; a rig with no worktrees/ directory is reported and skipped.
#
# Usage: gascity/orders/scripts/snapshot-agent-branches.sh [rig-path]
# Also runs as the snapshot-agent-branches order. A rig path limits the sweep to
# that rig; AGENT_SNAPSHOT_STATE overrides where the manifests go.

set -uo pipefail

CITY="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="${AGENT_SNAPSHOT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/gascity/$(basename "$(dirname "$CITY")")}"
mkdir -p "$STATE" || exit 1

snapshot_rig() {
    local rig="$1" manifest="$2"
    [ -d "$rig/.git" ] || { echo "not a git repo: $rig" >&2; return 1; }
    cd "$rig" || return 1
    [ -d worktrees ] || { echo "no worktrees in $rig"; return 0; }

    local base created=0 advanced=0 unchanged=0
    base="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

    printf 'branch\tbead\thead\tcommits_ahead\tfiles\tupdated\n' > "$manifest.tmp"

    local d bead head branch cur n f
    for d in worktrees/*/; do
        [ -d "$d" ] || continue
        bead="$(basename "$d")"
        head="$(git -C "$d" rev-parse HEAD 2>/dev/null)" || continue
        branch="agent/$bead"

        if ! git show-ref --verify --quiet "refs/heads/$branch"; then
            git branch "$branch" "$head" && created=$((created + 1))
        else
            cur="$(git rev-parse "$branch" 2>/dev/null)"
            if [ "$cur" != "$head" ]; then
                # only move forward — never discard commits already on the branch
                if git merge-base --is-ancestor "$cur" "$head" 2>/dev/null; then
                    git branch -f "$branch" "$head" && advanced=$((advanced + 1))
                else
                    echo "  WARN $branch diverged from its worktree; left alone" >&2
                fi
            else
                unchanged=$((unchanged + 1))
            fi
        fi

        n="$(git rev-list --count "$base..$head" 2>/dev/null || echo 0)"
        f="$(git diff --name-only "$base..$head" 2>/dev/null | wc -l | tr -d ' ')"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$branch" "$bead" "${head:0:12}" "$n" "$f" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$manifest.tmp"
    done

    mv "$manifest.tmp" "$manifest"

    # Anything branched earlier whose worktree has since been pruned: the branch
    # is now the only thing holding that work, which is exactly why it exists.
    local orphans=0 b
    while IFS= read -r b; do
        bead="${b#agent/}"
        [ -d "worktrees/$bead" ] || orphans=$((orphans + 1))
    done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/agent/*')

    echo "$(basename "$rig"): created=$created advanced=$advanced unchanged=$unchanged orphaned-branches=$orphans"
    echo "  manifest: $manifest"
}

if [ -n "${1:-}" ]; then
    rigs="$1"
else
    rigs="$(gc --city "$CITY" rig list --json 2>/dev/null \
        | jq -r --arg city "$CITY" \
            '(if type=="array" then . else .rigs // [] end)[] | select(.path != $city) | .path')" || {
        echo "could not list rigs" >&2; exit 1; }
fi

rc=0
for rig in $rigs; do
    ( snapshot_rig "$rig" "$STATE/agent-branches-$(basename "$rig").tsv" ) || rc=1
done
exit $rc
