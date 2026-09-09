#!/usr/bin/env bash
# Put a gap report on a branch and open a pull request for it.
#
# `gap-analysis` is mode=report: three steps, validate then write then finalize.
# It must not touch beads, branches or source, so nothing commits what it wrote
# — the two reports already on main (#604, #605) were branched and pushed by
# hand. This does that step.
#
# The report is written to report_path relative to the analyst's workspace,
# which is a worktree on a detached HEAD, so both the rig root and every
# worktree are searched and the newest match wins.
#
# The report is a document to argue with, not a verdict to accept. Opening a PR
# is what makes it reviewable: read the findings in the diff, push edits onto
# the branch, and merge when it says something you agree with. `implement-gaps`
# reads from the rig's checkout, so only a merged report drives work.
#
# Usage: publish-gap-report.sh <rig-path> <tdd-name>
set -euo pipefail
rig="${1:?rig path required}"
tdd="${2:?tdd name required}"
cd "$rig"

shopt -s nullglob
candidates=()
for f in "docs/tdd/gaps/$tdd"-*.md worktrees/*/"docs/tdd/gaps/$tdd"-*.md; do
    [ -f "$f" ] && candidates+=("$f")
done
[ ${#candidates[@]} -gt 0 ] || { echo "no report for '$tdd' in the rig or any worktree" >&2; exit 1; }

src=$(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort -t/ -k5 | tail -1)
name=$(basename "$src")
branch="gaps/${name%.md}"
echo "report: $src"

git fetch origin main --quiet

# A temporary worktree, not `git switch`: this runs against the rig the user is
# working in, and a recipe that leaves their checkout on a gaps/ branch is a
# side effect nobody asked for.
wt=$(mktemp -d)/pub
git worktree add --quiet --detach "$wt" origin/main
trap 'git worktree remove --force "$wt" 2>/dev/null || true' EXIT

cp "$src" "$wt/docs/tdd/gaps/$name"
git -C "$wt" switch --quiet --create "$branch" 2>/dev/null || git -C "$wt" switch --quiet "$branch"
git -C "$wt" add "docs/tdd/gaps/$name"
if git -C "$wt" diff --cached --quiet; then
    echo "nothing to commit — the report is already on this branch"
else
    git -C "$wt" commit --quiet -m "Gap analysis for the $tdd TDD

Written by the gap-analyst against docs/tdd/$tdd.md. Report-only: every
finding is traced in source, and the ones predicting runtime behaviour
say so. Argue with it here — push edits onto this branch — rather than
treating a merged report as settled.

Claude-Session: https://claude.ai/code/session_01M3qxmC6dPHqpMWMyZ6Zfou"
fi
git -C "$wt" push --quiet -u origin "$branch"
gh pr create --base main --head "$branch" \
    --title "Gap analysis for the $tdd TDD" \
    --body "Gap report for \`docs/tdd/$tdd.md\`, written by the gap-analyst.

Report-only by construction: the formula is mode=report and may not touch
beads, branches or source, so this branch is how it becomes reviewable.

Read the findings in the diff. Where you disagree, push an edit onto this
branch — \`just implement-gaps $tdd\` reads the report from the rig's
checkout, so only what is merged here goes on to drive work.

https://claude.ai/code/session_01M3qxmC6dPHqpMWMyZ6Zfou" 2>&1 | tail -2
