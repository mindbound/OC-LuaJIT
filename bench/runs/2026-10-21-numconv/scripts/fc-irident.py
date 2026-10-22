#!/usr/bin/env python3
"""fc-irident.py <out.txt> <new|base>: FIX-NUMCONV's final check reads step 1's
ir_ident.lua (fc-ir_ident.lua beside it, md5 e01eb3af; scratch
claude-tmp/oclj/numconv/argue/probes/) as argument.md section 5 predicts it.
Each output line is a form, then per loop trace "trN pre eq=A back=B opnd=C |
body eq=D back=E opnd=F", eq counting the i64 EQ guards.  Expected:
  identities (x | 0, x & -1, x ~ 0, x << 0, x >> 0, x ~>> 0, x & x, x | x,
  0 | x, -1 & x, (x | 0) & -1): eq 0 in every pre-roll and body on the new
  build, 1 on the base build (the result guard the rule removes);
  cancellations (~~x, (x ~ y) ~ y, (x ~ 5) ~ 5, ~(x ~ -1)): 1 on new, 2 on base;
  controls x | 1, x ~ y, x << 1: 1 on both; x & 0xff: 0 on both (the width
  rule).
Only the first loop trace of a form is held to these (x & 0xff has a second,
whose counts are 0 on both).  Exit 0 when every form matches.  No backslashes.
"""
import sys

IDENT = ["x | 0", "x & -1", "x ~ 0", "x << 0", "x >> 0", "x ~>> 0", "x & x", "x | x",
         "0 | x", "-1 & x", "(x | 0) & -1"]
CANCEL = ["~~x", "(x ~ y) ~ y", "(x ~ 5) ~ 5", "~(x ~ -1)"]
CONTROL1 = ["x | 1", "x ~ y", "x << 1"]
CONTROL0 = ["x & 0xff"]
mode = sys.argv[2]
assert mode in ("new", "base")
want = {}
for f in IDENT:
    want[f] = 0 if mode == "new" else 1
for f in CANCEL:
    want[f] = 1 if mode == "new" else 2
for f in CONTROL1:
    want[f] = 1
for f in CONTROL0:
    want[f] = 0

text = open(sys.argv[1], "rb").read().decode("utf-8", "replace").replace(chr(13), "")
seen = {}
bad = []
for line in text.split(chr(10)):
    if not line.strip() or line.startswith("exit "):
        continue
    form = line[:14].rstrip()
    rest = line[14:]
    if form not in want:
        bad.append("unknown line: " + line[:80])
        continue
    if "tr" not in rest or "NO LOOP TRACE" in rest:
        bad.append(form + ": no loop trace")
        continue
    first = rest.split("tr")[1]
    try:
        pre = int(first.split("pre eq=")[1].split(" ")[0])
        body = int(first.split("body eq=")[1].split(" ")[0])
    except Exception:
        bad.append(form + ": unreadable: " + line[:80])
        continue
    seen[form] = (pre, body)
    if pre != want[form] or body != want[form]:
        bad.append("%s: pre eq=%d body eq=%d, want %d (%s build)" % (form, pre, body, want[form], mode))
for f in want:
    if f not in seen and not any(b.startswith(f + ":") for b in bad):
        bad.append(f + ": missing")
for b in bad:
    print("MISMATCH " + b)
print("IRIDENT %s: %d forms read, %d mismatches (identities %d, cancellations %d, controls 1/0)" % (
    mode, len(seen), len(bad), want[IDENT[0]], want[CANCEL[0]]))
sys.exit(1 if bad else 0)
