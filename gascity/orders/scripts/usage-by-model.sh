#!/usr/bin/env bash
# Token usage by model, read from the Claude transcripts.
#
# The transcripts are the only live source. ~/.config/claude/stats-cache.json
# has the right shape but is only refreshed when a human runs /stats — it was
# three weeks stale when this was written — and rate-limit figures reach the
# statusline without ever being persisted.
#
# Agent sessions land here too: the supervisor sets CLAUDE_CONFIG_DIR, so every
# gc-spawned session writes under the same projects/ tree, keyed by its cwd.
#
# Usage: usage-by-model.sh [hours]   (default 24; 0 means since local midnight)
set -uo pipefail
HOURS="${1:-24}"
exec python3 - "$HOURS" <<'PY'
import json, os, sys, time, datetime, glob

hours = float(sys.argv[1])
now = time.time()
if hours == 0:
    t = datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    cutoff = t.timestamp(); label = t.strftime("since %Y-%m-%d %H:%M")
else:
    cutoff = now - hours*3600
    label = f"last {hours:g}h"

root = os.path.expanduser("~/.config/claude/projects")
agg, seen = {}, set()
for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
    try:
        if os.path.getmtime(path) < cutoff:      # whole file predates the window
            continue
        with open(path, errors="replace") as fh:
            for line in fh:
                if '"usage"' not in line:        # cheap filter before json parse
                    continue
                try: d = json.loads(line)
                except Exception: continue
                ts = d.get("timestamp")
                if not ts: continue
                try:
                    when = datetime.datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()
                except ValueError: continue
                if when < cutoff: continue
                rid = d.get("requestId")
                if rid:                          # one row per API request
                    if rid in seen: continue
                    seen.add(rid)
                m = d.get("message") or {}
                u = m.get("usage") or {}
                if not u: continue
                a = agg.setdefault(m.get("model") or "unknown",
                                   {"n":0,"in":0,"out":0,"cr":0,"cw":0})
                a["n"]   += 1
                a["in"]  += u.get("input_tokens",0) or 0
                a["out"] += u.get("output_tokens",0) or 0
                a["cr"]  += u.get("cache_read_input_tokens",0) or 0
                a["cw"]  += u.get("cache_creation_input_tokens",0) or 0
    except (OSError, ValueError):
        continue

def h(n):
    for unit, div in (("B",1e9), ("M",1e6), ("k",1e3)):
        if n >= div: return f"{n/div:.1f}{unit}"
    return str(n)

print(f"claude token usage — {label}")
print(f"{'model':<22}{'reqs':>7}{'output':>9}{'cache rd':>10}{'cache wr':>10}{'avg ctx':>10}")
tot = {"n":0,"in":0,"out":0,"cr":0,"cw":0}
# Output tokens dominate cost, so rank by them rather than by request count.
for model, a in sorted(agg.items(), key=lambda kv: -kv[1]["out"]):
    ctx = a["cr"] // max(a["n"], 1)
    print(f"{model:<22}{a['n']:>7}{h(a['out']):>9}{h(a['cr']):>10}{h(a['cw']):>10}{h(ctx):>10}")
    for k in tot: tot[k] += a[k]
print(f"{'-'*68}")
print(f"{'total':<22}{tot['n']:>7}{h(tot['out']):>9}{h(tot['cr']):>10}{h(tot['cw']):>10}{'':>10}")
# Cache reads are the discount, not the waste: uncached input was only
# {input} today. What drives them is avg ctx x turns, so the lever is a
# smaller context or fewer turns, never disabling the cache.
print(f"\nuncached input: {h(tot['in'])}   —  cache reads are ~{tot['cr']//max(tot['in'],1)}x that,")
print("and cost a fraction per token. avg ctx is what to watch: it is paid every turn.")
PY
