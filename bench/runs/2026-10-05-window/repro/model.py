# model.py -- the PUC-like rule ("collect at the refusal, refuse only when
# live + request > limit") on LuaJIT's own trajectory (traj.exe, probe3.lua).
#
# For each allocation i in the segment after marker j (class c_j, live L_j
# measured by a full collection at the marker):
#   need_hi(i) = L_j + (growth granted earlier in the segment) + delta_i
#                 -- everything allocated since the marker counted live
#   need_lo(i) = L_j - (frees earlier in the segment) + delta_i
#                 -- nothing allocated since the marker counted live
# A limit X refuses at the first i with need(i) > X.  A refusal in paint
# (class 3) is swallowed by pcall(paint), so the search goes on after it.
# X = base3 + room (stock: the cap) or base3 + room + G/2 (our burst top),
# room = capk*1024 + off, the same rooms the capped sweeps used.
import sys, bisect, collections
shape, capk, off0, off1, step = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
pre = sys.argv[6]
marks = []
base = None
for line in open(pre + ".marks"):
    if line.startswith("#base"): base = int(line.split()[1]); continue
    if line.startswith("#"): continue
    a = line.split(); marks.append((int(a[0]), int(a[1]), int(a[2])))
log = [int(x) for x in open(pre + ".log")]
# per allocation: (need_lo, need_hi, class), in program order
seq_need = []
for j, (sq, cl, live) in enumerate(marks):
    end = marks[j + 1][0] if j + 1 < len(marks) else len(log)
    grow = 0; frees = 0
    for i in range(sq, end):
        d = log[i]
        if d > 0:
            seq_need.append((live - frees + d, live + grow + d, cl))
            grow += d
        else:
            frees += -d
NAMES = {1: "inside", 2: "outside(stall)", 3: "paint", 4: "dispatcher(down)", 5: "kernel"}
def prefix_max(vals):
    out = []; m = -1
    for v in vals:
        m = max(m, v); out.append(m)
    return out
lo = [n[0] for n in seq_need]; hi = [n[1] for n in seq_need]; cls = [n[2] for n in seq_need]
def first_over(arr, X, start):
    # first index >= start with arr[i] > X (linear from start; arrays are short enough)
    for i in range(start, len(arr)):
        if arr[i] > X: return i
    return -1
def terminal(arr, X):
    i = first_over(arr, X, 0)
    hops = 0
    while i >= 0 and cls[i] == 3 and hops < 8:
        # swallowed: skip the rest of this paint segment
        k = i
        while k < len(cls) and cls[k] == 3: k += 1
        i = first_over(arr, X, k); hops += 1
    return NAMES.get(cls[i], "?") if i >= 0 else "none"
# speed: precompute prefix maxima so the first crossing is a bisect
pm_lo = prefix_max(lo); pm_hi = prefix_max(hi)
def terminal_fast(arr, pm, X):
    i = bisect.bisect_right(pm, X)
    if i >= len(arr): return "none"
    if cls[i] != 3: return NAMES.get(cls[i], "?")
    return terminal(arr, X)
res = collections.Counter()
for limit in ("cap", "top"):
    for off in range(off0, off1 + 1, step):
        X = base + capk * 1024 + off + (16384 if limit == "top" else 0)
        a = terminal_fast(lo, pm_lo, X); b = terminal_fast(hi, pm_hi, X)
        res[(limit, a if a == b else "ambiguous(" + a + "|" + b + ")")] += 1
for k, v in sorted(res.items()):
    print(shape, k[0], k[1], v)
