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

# Back up bead state, then start the city under the supervisor.
up: backup
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

# Delegates to the bd pack's mol-dog-backup order, which is also what runs on a
# 6h cooldown. It talks to the Dolt server, takes a lock, and can rsync offsite;
# a second implementation here would be a second answer with no owner.

# Sync every bead store now, rather than waiting for the 6h order.
backup:
    gc --city {{ city }} order run mol-dog-backup

# Reports bytes on disk, not bd's "Last sync" field, which lags: it read 11:54
# while archives were being written at 12:54. Freezing file mtimes is what the
# two-day silent failure actually looked like, and the only thing that caught it.

# Whether each backup destination is actually receiving data.
backup-status:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS=$'\t' read -r name store; do
      dest=$( (cd "$store" && bd backup status 2>&1 || true) \
              | sed -n 's|.*Destination: *file://||p' | head -1 )
      if [ -z "$dest" ]; then
        echo "  $name: NO DESTINATION — run 'just backup-init'"
        continue
      fi
      newest=$(find "$dest" -type f -name '*.darc' -exec stat -f '%m %N' {} + 2>/dev/null \
               | sort -rn | head -1)
      if [ -z "$newest" ]; then
        echo "  $name: destination configured but empty — $dest"
        continue
      fi
      when=$(date -r "${newest%% *}" '+%Y-%m-%d %H:%M')
      age=$(( ($(date +%s) - ${newest%% *}) / 60 ))
      size=$(du -sh "$dest" 2>/dev/null | cut -f1)
      printf '  %-12s %s  (%s min ago, %s)\n' "$name" "$when" "$age" "$size"
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

# Take a gap report to a pull request, via the gastown polecat and refinery.
implement-gaps tdd:
    #!/usr/bin/env bash
    set -euo pipefail
    # build-basic commits into detached-HEAD worktrees, and its publish stage
    # operates on the rig branch, which never carries that work — on its own it
    # has no route to a PR. Delegating implementation to the polecat does: it
    # pushes a feature branch and hands to the refinery, which opens the PR.
    report=$(bash {{ city }}/orders/scripts/latest-gap-report.sh \
               "{{ repos }}/{{ rig }}" "{{ tdd }}")
    [ -n "$report" ] || { echo "no gap report for {{ tdd }}; run 'just gap-analysis {{ tdd }}'" >&2; exit 1; }
    echo "report: $report"
    bead=$(gc --city {{ city }} bd create "Close the {{ tdd }} TDD gaps ($report)" \
             --rig {{ rig }} --json \
           | jq -r 'if type=="array" then .[0].id else .id end')
    echo "work bead: $bead"
    gc --city {{ city }} bd update "$bead" \
      --set-metadata merge_strategy=mr --set-metadata target=main
    gc --city {{ city }} sling {{ rig }}/gc.run-operator "$bead" --on build-basic \
      --var artifact_root="docs/plan/gaps/{{ tdd }}" \
      --var plan_path="$report" \
      --var implementation_formula=mol-polecat-work \
      --var implementation_target=gastown.polecat

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

# Open beads in the rig.
work:
    gc --city {{ city }} bd list --rig {{ rig }}
