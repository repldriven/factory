# Driving the factory.
#
# These encode the workflows we run against a rig, so the command lines live in
# the repo instead of a terminal history. `gc` finds the city by walking up from
# the working directory, which does not happen from the repository root, so
# every recipe passes --city explicitly. `bd` does not walk up at all, so the
# bead recipes cd into each store.

city    := justfile_directory() / "gascity"
rig     := "queenswood"
repos   := parent_directory(justfile_directory())
backups := env('XDG_STATE_HOME', env('HOME') / ".local/state") / "gascity/backups"

_default:
    @just --list --unsorted

# --- running the city ----------------------------------------------------

# Start the city under the supervisor.
up:
    gc --city {{ city }} start

# Stop the city.
down:
    gc --city {{ city }} stop

# Controller, agents and rigs.
status:
    gc --city {{ city }} status

# Health checks.
doctor:
    gc --city {{ city }} doctor

# --- bead state ----------------------------------------------------------

# Every bead store the city knows about, HQ included.
stores:
    @bash {{ city }}/orders/scripts/bead-stores.sh {{ city }}

# Backup itself is native and needs no recipe: `bd` syncs every 15m with
# backup.enabled=true, the pack's mol-dog-backup order syncs Dolt remotes every
# 6h, and `gc doctor` holds bd-backup-freshness, -size and -state. What is not
# native is creating the destination in the first place, which is why this
# survives — the freshness check went green only once every store had one.
#
# A store that already has a destination is left alone: repointing it would
# orphan the history already pushed there.

# One-time: give any store without a backup destination a local one.
backup-init:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS=$'\t' read -r name store; do
      # `|| true` before the grep: under pipefail a non-zero exit from bd
      # fails the pipeline even when the text matched, which silently turned
      # this guard off and repointed stores that already had a destination.
      out=$( cd "$store" && bd backup status 2>&1 || true )
      # "Destination:", not "Last backup:" — the latter belongs to bd's own
      # periodic backup, which is a separate mechanism and is disabled here. A
      # store can report it while having no Dolt destination at all.
      if printf '%s' "$out" | grep -q 'Destination:'; then
        echo "  keep $name — already has a destination"
      else
        dest="{{ backups }}/$name"
        mkdir -p "$dest"
        ( cd "$store" && bd backup init "$dest" ) >/dev/null && echo "  init $name -> $dest"
      fi
    done < <(bash {{ city }}/orders/scripts/bead-stores.sh {{ city }})

# --- work ----------------------------------------------------------------

# TDDs with no gap report yet.
tdds-without-gaps:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in "{{ repos }}/{{ rig }}"/docs/tdd/*.md; do
      n=$(basename "$f" .md)
      compgen -G "{{ repos }}/{{ rig }}/docs/tdd/gaps/$n*.md" >/dev/null || echo "$n"
    done

# The newest gap report for a TDD, or nothing if it has never been analysed.
latest-gaps tdd:
    @bash {{ city }}/orders/scripts/latest-gap-report.sh "{{ repos }}/{{ rig }}" "{{ tdd }}"

# Analysis is iterative, so reports are timestamped and kept, never overwritten.

# Report where a TDD and the code disagree.
gap-analysis tdd:
    #!/usr/bin/env bash
    set -euo pipefail
    gaps="{{ repos }}/{{ rig }}/docs/tdd/gaps"
    # UTC, and to the second: every dated report then has the same shape, so
    # lexical order is chronological order. A date alone collides on the second
    # run of a day, and disambiguating that with a "-2" suffix sorts WRONG —
    # "-" precedes "." in ASCII, so the suffixed file loses to the original.
    name="{{ tdd }}-$(date -u +%F-%H%M%S)"
    [ -e "$gaps/$name.md" ] && { echo "$gaps/$name.md already exists" >&2; exit 1; }
    echo "report: docs/tdd/gaps/$name.md"
    gc --city {{ city }} sling {{ rig }}/gc.gap-analyst -f gap-analysis \
      --var subject_path=docs/tdd/{{ tdd }}.md \
      --var report_path="docs/tdd/gaps/$name.md"

# The analyst is report-only and commits nothing, so this is what makes the
# report reviewable: branch it, push it, open a PR, argue in the diff.

# Open a PR for a gap report the analyst has written.
gaps-pr tdd:
    @bash {{ city }}/orders/scripts/publish-gap-report.sh "{{ repos }}/{{ rig }}" "{{ tdd }}"

# Take a gap report to a pull request, all the way through gascity.
implement-gaps tdd:
    #!/usr/bin/env bash
    set -euo pipefail
    # Pure gascity: implementation stays on gc.implementation-worker and the
    # publish stage raises the PR. Publish does not push gc.work_branch — it
    # builds a branch from the approved worktree anchor and pushes that, which is
    # what publish.md means by "a finalized result can be an approved source
    # anchor/worktree". Proven on qw-0yjm: publish_outcome=published, PR #618,
    # with no polecat and no refinery.
    #
    # push and open_pr default to false, which is the whole reason the banks run
    # produced no PR — a launch variable left at its default, not the structural
    # gap it looked like at the time.
    #
    # Unproven: that run had one work item, so the anchor was the whole change.
    # Whether publish integrates ten worktrees is what the next TDD answers;
    # there is no integration step between implement and publish.
    report=$(bash {{ city }}/orders/scripts/latest-gap-report.sh \
               "{{ repos }}/{{ rig }}" "{{ tdd }}")
    [ -n "$report" ] || { echo "no gap report for {{ tdd }}; run 'just gap-analysis {{ tdd }}'" >&2; exit 1; }
    echo "report: $report"
    bead=$(gc --city {{ city }} bd create "Close the {{ tdd }} TDD gaps ($report)" \
             --rig {{ rig }} --json \
           | jq -r 'if type=="array" then .[0].id else .id end')
    echo "work bead: $bead"
    # --rig is required: `gc bd update` does not resolve a rig-scoped id from
    # the city root, unlike `gc sling`, which does. It is a global flag and
    # absent from `gc bd update --help`.
    #
    # merge_strategy is inert while implementation is gascity's: the refinery is
    # its only reader and nothing routes there. Kept because it costs one call
    # and is the difference between a PR and a push refused at a protected main
    # the moment anything does.
    gc --city {{ city }} bd update "$bead" --rig {{ rig }} \
      --set-metadata merge_strategy=mr --set-metadata target=main
    gc --city {{ city }} sling {{ rig }}/gc.run-operator "$bead" --on build-basic \
      --var artifact_root="docs/plan/gaps/{{ tdd }}" \
      --var plan_path="$report" \
      --var push=true \
      --var open_pr=true

# Stamp merge_strategy=mr on work beads that lack it. Also runs as an order.
stamp-merge-strategy:
    @bash {{ city }}/orders/scripts/stamp-merge-strategy.sh

# Delivery is wait-idle, so a session that is actually working ignores it.

# Nudge sessions quiet for N minutes — after a rate-limit pause.
nudge minutes="10" message="continue":
    @bash {{ city }}/orders/scripts/nudge-stalled.sh {{ city }} "{{ minutes }}" "{{ message }}"

# Which sessions a nudge would reach, without sending anything.
nudge-dry minutes="10":
    @bash {{ city }}/orders/scripts/nudge-stalled.sh {{ city }} "{{ minutes }}" "" --dry-run

# Reads the Claude transcripts, which are the only live source: stats-cache.json
# is refreshed only when a human runs /stats, and rate-limit figures reach the
# statusline without being persisted anywhere. Agent sessions are included —
# the supervisor sets CLAUDE_CONFIG_DIR, so they write to the same tree.
#
# Ranked by output tokens rather than request count, since that is what costs.

# Token usage by model. `hours` of 0 means since local midnight.
usage hours="24":
    @bash {{ city }}/orders/scripts/usage-by-model.sh {{ hours }}

# Scoped by the run's implementation convoy, because WI numbers restart every
# run — a title match alone mixes this run's WI-1 with the last one's.

# Work items for a build-basic run, newest unless a run id is given.
wi run="":
    @bash {{ city }}/orders/scripts/work-items.sh {{ city }} {{ rig }} "{{ run }}"

# Pipeline steps for a build-basic run — the stage above `wi`, showing which
# role holds each step. Pass --all as the second arg to include stages the
# formula never reached.
steps run="" all="":
    @bash {{ city }}/orders/scripts/run-steps.sh {{ city }} {{ rig }} build-basic "{{ run }}" "{{ all }}"

# Steps of a gap-analysis run. Report-only, so there are no work items and no
# `wi` view to go with it — the three steps are the whole run.
analysis run="" all="":
    @bash {{ city }}/orders/scripts/run-steps.sh {{ city }} {{ rig }} gap-analysis "{{ run }}" "{{ all }}"

# Open beads in the rig.
work:
    gc --city {{ city }} bd list --rig {{ rig }}
