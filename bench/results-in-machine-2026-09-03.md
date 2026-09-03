# In-machine benchmark — does the JIT pay off for OpenComputers workloads?

Date: 2026-09-03. **Phase 0 of Step 3.** Companion to
[results-2026-09-01.md](results-2026-09-01.md), which measured the same VMs as
standalone binaries. This one measures them **inside a running
OpenComputers machine**: real OpenOS 1.8.9 on ocelot-brain 0.24.2, under OC's
real per-resume deadline, its real per-tick call budget and its real RAM cap.

The 2026-09-01 study predicted a **bimodal** answer — large gains on
compute-bound Lua, ~zero on component-call-bound programs. That is what the
numbers say, and it is the shape rather than any single multiplier that should
be quoted.

## The cells

| cell | native | kernel | JIT | what it is |
|---|---|---|---|---|
| **A** | ocelot-brain's bundled PUC Lua 5.2 | OC's stock `machine.lua` | — | **what a player runs today** |
| **B** | ours (LuaJIT) | watchdog variant | off | + LuaJIT interpreter, − the standing hook |
| **C** | ours (LuaJIT) | watchdog variant | on | + the compiler |

B is not optional. The watchdog change alone speeds the *interpreter*
(`hook-vs-jit.md` §7), so an A→C figure without B would credit the compiler for
work the hook removal did.

Cell A is selected by *not* pointing `forceNativeLibPathFirst` at our DLL, so
ocelot-brain loads its own native. Its fingerprint is asserted with equal force
in both directions — `native=<stock>`, `jit=NO-JIT-TABLE`,
`eris=[persist,settings,unpersist]` (ours has a fourth key, `version`) — because
a mis-resolved DLL is the one way this comparison could lie outright.

## Results (3 runs per cell)

### Compute-bound: `bench/oc/mandelbrot.lua`

Byte-identical to `bench/mandelbrot.lua` except that its two `print`s became
`return`s, so its checksum is the **published reference, unchanged**:
`37904620`, verified in every run of every cell.

| cell | run 1 | run 2 | run 3 | mean | vs A |
|---|---:|---:|---:|---:|---:|
| A — PUC 5.2 | 1.8389 | 1.7863 | 1.8351 | **1.820 s** | 1.00× |
| B — LuaJIT, JIT off | 0.7088 | 0.7042 | 0.7072 | **0.707 s** | 2.58× |
| C — LuaJIT, JIT on | 0.1074 | 0.1053 | 0.0997 | **0.104 s** | **17.5×** |

Of the 17.5×, **2.58× is the LuaJIT interpreter plus the removal of OC's
standing deadline hook**, and **6.79× is the compiler on top of that**.

Cross-check against the standalone table: mandelbrot there is 1.355 s on
lua5.3 and 0.097 s on luajit, a 14.0× ratio. In-machine C is 0.104 s — within
7% of the standalone compiled time. **The sandbox is not eating the win**: a
compiled trace inside an OpenComputers machine runs at essentially the speed it
runs at on a bare VM.

### Component-bound: a recursive `fs.list` walk over 120 nested directories

| cell | run 1 | run 2 | run 3 | mean | vs A |
|---|---:|---:|---:|---:|---:|
| A — PUC 5.2 | 6.50 | 6.30 | 6.25 | **6.35 s** | 1.00× |
| B — LuaJIT, JIT off | 6.40 | 6.20 | 6.35 | **6.32 s** | 1.00× |
| C — LuaJIT, JIT on | 6.45 | 6.45 | 6.25 | **6.38 s** | **1.00×** |

Flat, to within run-to-run noise, across a VM change *and* a compiler.
`fs.list` carries no `direct` flag, so `machine.lua` turns every call into a
`coroutine.yield` → synchronised call → **one game tick, minimum**. 122 entries
therefore cost ~122 ticks no matter how fast the VM is. No compiler can make a
scheduler tick shorter.

**This is the half of the answer a release note must not omit.** A program that
spends its life calling components — most automation scripts — gets nothing
from this project. A program that computes gets an order of magnitude.

### Environment

Post-boot free memory, reported by the sandbox itself, on a 1024 KB machine
at `OCLJ_RAM_SCALE=3.0`: **865–1024 KB free of 1024 KB**. That number sizes
every benchmark in Phase 1 — LuaJIT has no emergency GC, so an oversized
workload kills the machine rather than failing its own row.

## Every number has a control

| assertion | control, and it was observed to fire |
|---|---|
| `mandelbrot` CHECK == `37904620` in all three cells | **`OCLJ_BENCH_SABOTAGE=1`** plants the same file with `MAXI` 128 → 13. The run returned `7162053` **in 0.0222 s — 4.7× "faster"** — and the checksum rejected it. A fast wrong answer cannot pass. |
| the baseline is really PUC 5.2 | the guard `die()`s if it sees `_OCLJ_NATIVE`, a `jit` table, or a non-5.2 `_VERSION`. Observed: it rejected a correctly-loaded stock native once, because `_VERSION` reports `Lua+Eris 5.2` on **both** natives (`luaopen_eris` sets it) and cannot discriminate them at all. The discriminators that work are the marker and the `jit` table. |
| the walk really made indirect calls | `p0-component-walk-ran` requires ≥120 entries; a walk finishing in fewer ticks than it made calls would mean they were not indirect. |
| the JIT is on/off as asked | `j0`, plus `m1`/`k2`/`k5` which assert our accessors are **absent** in cell A — that absence is how we know A is a different VM and not our native with the compiler switched off. |
| every run is otherwise green | all 28–30 existing milestones pass in every published run. |

## What this does not say

* **One benchmark.** mandelbrot is pure float arithmetic with no allocation and
  no string work. It is the friendliest possible case for a tracing JIT. The
  standalone table already shows the spread is enormous — 41× on sha256, 0.25×
  on the `strings` pathology — so a suite is needed before any geomean is
  quoted. That is Phase 1, and Phase 0's job was only to decide whether to
  build it.
* **One machine configuration**, one OS, one tier of hardware.
* **Nothing about warmup.** Each cell runs the benchmark once, after a boot
  that already compiled ~110 traces. A machine that has just loaded from a save
  starts cold — every world save flushes every trace (`hook-vs-jit.md` §8) —
  and the cost of that is still unmeasured.
* **Nothing in Minecraft.** Every number here is ocelot-brain.

## Verdict on Phase 0

The gate was: *if C ≈ B, stop — the JIT buys nothing in-machine, and Phases 1–3
are cancelled.* C is **6.8× faster than B**. The suite is justified.
