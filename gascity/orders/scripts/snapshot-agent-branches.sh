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
# The manifest is written outside the repository. It is derived state — every
# row can be rebuilt from the agent/* branches, which are the durable artifact —
# and the order rewrites it every 15 minutes, so tracking it would leave the
# working tree permanently dirty.
#
# Usage: gascity/orders/scripts/snapshot-agent-branches.sh [rig-path]
# Also runs as the snapshot-agent-branches order. Override with
# AGENT_SNAPSHOT_RIG / AGENT_SNAPSHOT_MANIFEST.

set -uo pipefail

# Repo root is three levels up: <repo>/gascity/orders/scripts/<this>
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
RIG="${1:-${AGENT_SNAPSHOT_RIG:-$(dirname "$REPO")/queenswood}}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/gascity/$(basename "$REPO")"
MANIFEST="${AGENT_SNAPSHOT_MANIFEST:-$STATE/agent-branches.tsv}"
mkdir -p "$(dirname "$MANIFEST")" || exit 1

[ -d "$RIG/.git" ] || { echo "not a git repo: $RIG" >&2; exit 1; }
cd "$RIG" || exit 1

BASE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
created=0 advanced=0 unchanged=0

printf 'branch\tbead\thead\tcommits_ahead\tfiles\tupdated\n' > "$MANIFEST.tmp"

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

    n="$(git rev-list --count "$BASE..$head" 2>/dev/null || echo 0)"
    f="$(git diff --name-only "$BASE..$head" 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$branch" "$bead" "${head:0:12}" "$n" "$f" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$MANIFEST.tmp"
done

mv "$MANIFEST.tmp" "$MANIFEST"

# Anything branched earlier whose worktree has since been pruned: the branch is
# now the only thing holding that work, which is exactly why it exists.
orphans=0
while IFS= read -r b; do
    bead="${b#agent/}"
    [ -d "worktrees/$bead" ] || orphans=$((orphans + 1))
done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/agent/*')

echo "created=$created advanced=$advanced unchanged=$unchanged orphaned-branches=$orphans"
echo "manifest: $MANIFEST"
