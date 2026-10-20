#!/usr/bin/env python3
# mkreports.py <out.json> -- the pin rounds' agent reports (rounds 1-4: implementer and verifier, from the
# workflow journals), as one JSON file for bench/runs/2026-10-20-pin/design/.  LF, newline="".
import json, os, sys
J = "C:/Users/astro/.claude/projects/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/subagents/workflows"
ROUNDS = [("1", "wf_b2ad3b10-b6c"), ("2", "wf_539080d3-946"), ("3", "wf_d4b774ed-aed"), ("4", "wf_56f68a24-663")]
out = {}
for r, wf in ROUNDS:
    p = os.path.join(J, wf, "journal.jsonl")
    rows = {}
    labels = {}
    with open(p, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if d.get("type") == "started":
                labels[d.get("agentId")] = d.get("label")
                continue
            if d.get("type") != "result":
                continue
            label = labels.get(d.get("agentId")) or "agent%d" % len(rows)
            rows[label] = d.get("result")
    out["round" + r] = {"workflow": wf, "reports": rows}
    print("round", r, wf, sorted(rows))
with open(sys.argv[1], "w", encoding="utf-8", newline="") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
    f.write(chr(10))
