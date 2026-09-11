#!/usr/bin/env bash
# Work items for a build-basic run, scoped by its implementation convoy.
#
# Scoping matters: WI numbers restart every run, so a title match alone mixes
# this run's WI-1 with the last one's. The run root records the convoy the
# decomposer created as gc.build.implementation_convoy_id, and that is the only
# thing that says which items belong to which run.
#
# `gc convoy status --json` gives membership but no timestamps, so the two are
# joined: membership from the convoy, times from the bead list.
#
# The convoy's own status is not enough to say what is happening. A drained item
# reports `open` whether a worker holds it or it is still waiting its turn — the
# drain never moves it to in_progress. What separates the two is metadata.work_dir,
# which gc sets when the item is given its worktree, so that is what STATUS reports:
# closed / working / queued.
#
# Usage: work-items.sh <city> <rig> [run-root-id]   (default: newest build-basic)
set -uo pipefail
CITY="${1:?city}"; RIG="${2:?rig}"; RUN="${3:-}"
exec python3 - "$CITY" "$RIG" "$RUN" <<'PY'
import json, re, subprocess, sys, datetime

city, rig, run = sys.argv[1], sys.argv[2], sys.argv[3]
def gc(*a):
    r = subprocess.run(["gc","--city",city,*a], capture_output=True, text=True)
    return r.stdout

def rows(txt):
    try: d = json.loads(txt)
    except Exception: return []
    return d if isinstance(d, list) else (d.get("issues") or [])

beads = rows(gc("bd","list","--rig",rig,"--all","--json"))
by_id = {b["id"]: b for b in beads if b.get("id")}

if not run:
    cands = [b for b in beads if (b.get("title") or "") == "build-basic"]
    cands.sort(key=lambda b: b.get("created_at") or "")
    if not cands: sys.exit(f"no build-basic run found in rig {rig}")
    run = cands[-1]["id"]

root = by_id.get(run) or {}
now = datetime.datetime.now(datetime.timezone.utc)

def when(v):
    if not v: return None
    try: return datetime.datetime.fromisoformat(v.replace("Z","+00:00"))
    except ValueError: return None

def dur(a, b):
    if not a or not b: return "-"
    s = int((b - a).total_seconds())
    if s < 60: return f"{s}s"
    h, m = divmod(s // 60, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m"

started = when(root.get("started_at")) or when(root.get("created_at"))
ended   = when(root.get("closed_at"))
print(f"run: {run}  {root.get('status','?')}  "
      f"{'ran' if ended else 'running'} {dur(started, ended or now)}"
      f"{'' if ended else '  (started ' + started.astimezone().strftime('%H:%M') + ')' if started else ''}")

meta = root.get("metadata") or {}
for k in ("gc.publish_outcome", "gc.publish_pr_url"):
    if meta.get(k): print(f"     {k}: {meta[k]}")

cid = meta.get("gc.build.implementation_convoy_id")
if not cid:
    print("     decomposition has not created the implementation convoy yet"); sys.exit(0)

try: conv = json.loads(gc("convoy","status",cid,"--json"))
except Exception: sys.exit("could not read convoy " + cid)
kids = conv.get("children") or []
prog = conv.get("progress") or {}
done, total = prog.get("closed", 0), prog.get("total", len(kids))
# A decomposer may split an item, giving WI-9a and WI-9b, so the number and the
# suffix sort separately; an int() on "9b" is what used to crash this view.
def key(c):
    m = re.match(r"WI-(\d+)([A-Za-z]*)", c.get("title") or "")
    return (int(m.group(1)), m.group(2)) if m else (999, "")

def state(c, b):
    if c.get("status") == "closed": return "closed"
    return "working" if ((b.get("metadata") or {}).get("work_dir")) else "queued"

tally = {}
for c in kids:
    st = state(c, by_id.get(c["id"], {}))
    tally[st] = tally.get(st, 0) + 1
live = ", ".join(f"{tally[k]} {k}" for k in ("working", "queued") if tally.get(k))
print(f"\nconvoy {cid}  {done}/{total} closed" + (f"  ({live})" if live else ""))
print(f"  {'ITEM':<6}{'STATUS':<13}{'DURATION':>10}{'IDLE':>7}  TITLE")

for c in sorted(kids, key=key):
    b = by_id.get(c["id"], {})
    st = state(c, b)
    cre, upd = when(b.get("created_at")), when(b.get("updated_at"))
    clo = when(b.get("closed_at")) or (upd if st == "closed" else None)
    title = c.get("title") or ""
    item = title.split(":")[0] if title.startswith("WI-") else c["id"]
    rest = title.split(": ", 1)[1] if ": " in title else title
    # A queued item is not running, so it has no duration to report — only an age,
    # which reads as progress it has not made.
    duration = dur(cre, clo or now) if st != "queued" else "-"
    idle = "-" if st == "closed" else dur(upd, now)
    print(f"  {item:<6}{st:<13}{duration:>10}{idle:>7}  {rest[:52]}")
PY
