#!/usr/bin/env bash
# Pipeline steps for a build-basic run — the stage view above `just wi`.
#
# Every step of a poured formula is a bead tagged with gc.root_bead_id (the run)
# and gc.step_ref (its position in the formula). One logical stage spans several
# such beads: the parent, its `.iteration.N` (the one that actually executes),
# a `.spec`, and for fanout children a `-scope-check`. They are folded together
# on a normalised step_ref, because the role lives on one of them and the
# timestamps on another — neither bead alone describes the stage.
#
# Order comes from `gc formula show`, so steps that have not started yet still
# appear in DAG order rather than sorting to the end.
#
# Usage: run-steps.sh <city> <rig> <formula> [run-root-id] [--all]
set -uo pipefail
CITY="${1:?city}"; RIG="${2:?rig}"; FORMULA="${3:?formula}"; RUN="${4:-}"; ALL="${5:-}"
exec python3 - "$CITY" "$RIG" "$FORMULA" "$RUN" "$ALL" <<'PY'
import json, re, subprocess, sys, datetime

city, rig, formula, run, allflag = sys.argv[1:6]
show_all = allflag == "--all"

def gc(*a):
    return subprocess.run(["gc","--city",city,*a], capture_output=True, text=True).stdout

def norm(ref):
    """Fold a step_ref onto the stage it belongs to."""
    ref = re.sub(r"^" + re.escape(formula) + r"\.", "", ref or "")
    ref = re.sub(r"\.iteration\.\d+", "", ref)
    ref = re.sub(r"-scope-check$", "", ref)
    return re.sub(r"\.spec$", "", ref)

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

try:
    d = json.loads(gc("bd","list","--rig",rig,"--all","--json"))
except Exception:
    sys.exit("could not read beads for rig " + rig)
beads = d if isinstance(d, list) else (d.get("issues") or [])

if not run:
    cands = sorted((b for b in beads if (b.get("title") or "") == formula),
                   key=lambda b: b.get("created_at") or "")
    if not cands: sys.exit(f"no {formula} run found in rig {rig}")
    run = cands[-1]["id"]

root = next((b for b in beads if b.get("id") == run), {})
now = datetime.datetime.now(datetime.timezone.utc)
started, ended = when(root.get("started_at")) or when(root.get("created_at")), when(root.get("closed_at"))
print(f"run: {run}  {root.get('status','?')}  "
      f"{'ran' if ended else 'running'} {dur(started, ended or now)}")

meta = root.get("metadata") or {}
for k in ("gc.var.subject_path", "gc.var.report_path",
          "gc.build.publish_status", "gc.build.publish_pr_url"):
    if meta.get(k): print(f"     {k.rsplit('.', 1)[-1]}: {meta[k]}")

# Fold the run's step beads onto stages.
stages = {}
for b in beads:
    m = b.get("metadata") or {}
    if m.get("gc.root_bead_id") != run: continue
    key = norm(m.get("gc.step_ref"))
    s = stages.setdefault(key, {"title": None, "role": None, "status": None,
                                "started": None, "ended": None, "updated": None})
    title = b.get("title") or ""
    # Prefer the substantive title over "Step spec for ..." / "Finalize scope for ...".
    if not s["title"] or (title and not re.match(r"^(Step spec|Finalize scope) for ", title)
                          and re.match(r"^(Step spec|Finalize scope) for ", s["title"] or "")):
        s["title"] = title
    routed = m.get("gc.execution_routed_to")
    if routed and not s["role"]: s["role"] = routed.split("/")[-1].replace("gc.","")
    st = b.get("status")
    rank = {"closed": 3, "in_progress": 2, "open": 1}
    if rank.get(st, 0) > rank.get(s["status"], 0) or s["status"] is None:
        # in_progress outranks closed for display: a running iteration is the news.
        if not (s["status"] == "in_progress" and st == "closed"): s["status"] = st
    for f, k in (("started","started_at"), ("ended","closed_at"), ("updated","updated_at")):
        t = when(b.get(k))
        if t and (not s[f] or (f == "started" and t < s[f]) or (f != "started" and t > s[f])): s[f] = t

# Formula order, normalised the same way.
order, seen = [], set()
for line in gc("formula","show", meta.get("gc.formula_name") or formula).splitlines():
    mm = re.match(r"^\s*[├└]──\s+([\w.\-]+):", line)
    if mm:
        k = norm(mm.group(1))
        if k not in seen: seen.add(k); order.append(k)
rank = {k: i for i, k in enumerate(order)}

rows = sorted(stages.items(), key=lambda kv: (rank.get(kv[0], 999), kv[0]))
print(f"\n  {'STAGE':<47}{'STATUS':<13}{'DURATION':>9}{'IDLE':>7}  ROLE")
for key, s in rows:
    if not show_all and s["status"] == "open" and rank.get(key, 999) == 999: continue
    title = re.sub(r"^(Step spec|Finalize scope) for ", "", s["title"] or key)
    d0 = dur(s["started"], s["ended"] if s["status"] == "closed" else now) if s["started"] else "-"
    # Idle only reads on a running step. An open step has not started, so the
    # time since it was touched says nothing about whether it is stuck.
    idle = dur(s["updated"], now) if s["status"] == "in_progress" and s["updated"] else "-"
    print(f"  {title[:46]:<47}{s['status'] or '?':<13}{d0:>9}{idle:>7}  {s['role'] or '-'}")
PY
