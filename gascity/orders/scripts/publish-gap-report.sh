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
rig_name=$(basename "$rig")
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

# Rebuild the branch from the base rather than reusing whatever is there.
# A run that fails after the branch is created but before the push -- a
# rejected guard, a lint failure, an interrupt -- leaves it behind, pinned
# to whatever origin/main was at the time. Reusing it then rebuilt the
# report on that stale commit, so a fix merged in between had no effect
# and the retry failed identically to the first attempt, which reads as
# the fix not working.
#
# Only when it was never pushed. Once the branch is on the remote it is
# under review, and this script's whole premise is that disagreements get
# pushed onto it, so the remote is the base and nothing is discarded.
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git fetch origin "$branch" --quiet
    git -C "$wt" switch --quiet --force-create "$branch" "origin/$branch"
else
    git -C "$wt" switch --quiet --force-create "$branch"
fi

# After the switch, not before it: switching onto a branch that already
# carries the report refuses to overwrite an untracked file of the same
# name, which is the shape the copy used to create.
# mkdir -p because a rig publishing its first report has no docs/tdd/gaps/
# on main: queenswood's exists only because earlier reports were merged
# into it by hand.
mkdir -p "$wt/docs/tdd/gaps"
cp "$src" "$wt/docs/tdd/gaps/$name"
git -C "$wt" add "docs/tdd/gaps/$name"
if git -C "$wt" diff --cached --quiet; then
    echo "nothing to commit — the report is already on this branch"
else
    git -C "$wt" commit --quiet -m "Gap analysis for the $tdd TDD

Written by the gap-analyst against docs/tdd/$tdd.md. Report-only: every
finding is traced in source, and the ones predicting runtime behaviour
say so. Argue with it here — push edits onto this branch — rather than
treating a merged report as settled."
fi
git -C "$wt" push --quiet -u origin "$branch"

# The report now lives on the branch, so drop the analyst's copy — but only
# from the rig root, never from a worktree an agent may still be using. Left
# in place it blocks `git switch` to the very branch you would edit it on:
# checkout refuses to overwrite an untracked file of the same name.
case "$src" in
    worktrees/*) : ;;
    *) rm -f "$src" && echo "removed the working copy: $src" ;;
esac
gh pr create --base main --head "$branch" \
    --title "Gap analysis for the $tdd TDD" \
    --body "Gap report for \`docs/tdd/$tdd.md\`, written by the gap-analyst.

Report-only by construction: the formula is mode=report and may not touch
beads, branches or source, so this branch is how it becomes reviewable.

Read the findings in the diff. Where you disagree, push an edit onto this
branch — \`just implement-gaps $rig_name $tdd\` reads the report from the rig's
checkout, so only what is merged here goes on to drive work." 2>&1 | tail -2
