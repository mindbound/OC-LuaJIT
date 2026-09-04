# Step 3 Phase 1 — the benchmark suite, inside a machine

Date: 2026-09-04. Companion to
[results-in-machine-2026-09-03.md](results-in-machine-2026-09-03.md) (Phase 0,
one benchmark) and [results-2026-09-01.md](results-2026-09-01.md) (the same
programs as standalone binaries).

Nine benchmarks, three cells, **one benchmark per freshly booted 1 MB
OpenComputers machine**, real OpenOS 1.8.9 on ocelot-brain 0.24.2 under OC's
real deadline, call budget and RAM cap. 78 runs, serial.

| cell | native | kernel | JIT | what it is |
|---|---|---|---|---|
| **A** | ocelot-brain's bundled PUC Lua 5.2 | OC's stock `machine.lua` | — | **what a player runs today** |
| **B** | ours (LuaJIT) | watchdog | off | + LuaJIT interpreter, − the standing hook |
| **C** | ours (LuaJIT) | watchdog | on | + the compiler |

## Method, and why it is shaped this way

Every element below is a response to a way an earlier attempt produced a wrong
number. They are recorded because the wrong numbers were plausible.

**One benchmark per machine.** The first attempt ran all nine in one machine.
Cell A completed but drifted from 877 KB free to 237 KB and skipped a
benchmark; cell B died outright with `not enough memory`. Nine benchmarks in
one machine measures accumulated garbage, not the benchmarks.

**Interleaved A→B→C per benchmark, three replicates spread across the hour.**
Box speed on this machine drifts by up to 2×. An earlier matrix reported
mandelbrot A/C as **28×**; the replicated figure is **12.3×**, and the whole
difference was two cells landing in a fast window. Interleaving makes drift hit
all three cells together.

**A box-speed meter, free with every run.** Each boot runs a fixed
2 000 000-iteration sandbox loop before any benchmark (`sandbox-bench`).
Identical work every run, so it calibrates that boot against its cell's median.
Medians here: **A 0.0324 s, B 0.0173 s, C 0.0047 s**, n = 26 each. Cross-cell
the raw value means nothing (compiled in C); within a cell it is the check that
a row is not a lucky boot.

**Cell identity verified per row.** Each log must name the kernel *and* the
benchmark that was asked for, or the row is discarded as misattributed — an
earlier matrix filed one cell's log under another's name after a run died early
and left a stale log behind.

## Results

Median of the per-run minimum, over the replicates that produced a row.
`n` is how many runs produced one.

| benchmark | A — PUC 5.2 | B — ours, JIT off | C — ours, JIT on |
|---|---:|---:|---:|
| mandelbrot | 1.965 (n=2) | 0.823 (n=3) | 0.160 (n=2) |
| sieve | 2.616 (n=1) | **all failed** | **all failed** |
| binarytrees | 3.956 (n=2) | 1.455 (n=3) | 1.347 (n=2) |
| trampoline | 1.073 (n=3) | 0.671 (n=2) | 0.620 (n=3) |
| matmul | 3.161 (n=3) | 1.377 (n=3) | 0.288 (n=3) |
| strings2 | 1.646 (n=3) | 1.027 (n=3) | 0.569 (n=3) |
| nqueens | 3.171 (n=2) | 1.893 (n=3) | 1.314 (n=3) |
| sha256 | 2.406 (n=1) | 1.953 (n=3) | 0.086 (n=3) |
| **strings** *(quarantined)* | 1.776 (n=1) | 1.067 (n=2) | **all failed** |

Every row that completed returned its reference checksum. `sha256` reproduced
the **published** digest `4044b974…25a5d` in all three cells, `mandelbrot` the
published `37904620`, `nqueens` the published `85200`.

### Ratios worth quoting

| | B/C — the compiler alone | A/C — versus what players run |
|---|---:|---:|
| sha256 | **22.6×** | — (A n=1) |
| mandelbrot | 5.13× | 12.3× |
| matmul | 4.79× | 11.0× |
| strings2 | 1.80× | 2.89× |
| nqueens | 1.44× | 2.41× |
| binarytrees | 1.08× | 2.94× |
| trampoline | 1.08× | 1.73× |

**B/C is the clean experiment**: same binary, same kernel, same source, same
machine — only `jit.off()` differs. It reproduces the standalone
`-joff`-versus-compiled ratio closely where the work stays in the VM (sha256
22.6× in-machine against 23.1× standalone; mandelbrot 5.13× against 5.49×).

**A/C carries a confound on `sha256` and must not be quoted for it**: PUC 5.2
cannot parse bitwise operators, so cell A necessarily runs `compat.lua`'s
**bit32** branch while B and C run native operators. That is a real property of
what players have, not a defect — but it is a library difference riding along
with the VM difference, and only B/C is free of it.

**No geomean.** The spread is bimodal by construction and a mean over it would
describe no program.

## Two failures that matter more than the table

### `sieve` fails on our native and runs on PUC — 6 runs out of 6

| | sieve, 312 KB declared peak, 1 MB machine |
|---|---|
| A — PUC 5.2 | `sieve/ok/4626000/2.6158/2.8847/848/3` |
| B — ours, JIT **off** | `ERROR/not_enough_memory` ×2, then a lost machine |
| C — ours, JIT **on** | machine lost ×3 |

Cell B's failure is fully attributed: the driver's own `pcall` caught a guest
out-of-memory, with `JIT MEMORY: mcode=0 B, traces=0, jit=false` excluding
trace churn, and the RAM guard having passed immediately before — so this is
plain Lua-heap churn hitting the cap. PUC runs the identical workload in 2.6 s
with 848 KB free.

That is [memory-accounting.md §8](../docs/research/memory-accounting.md)'s
divergence doing real damage: PUC retries after an emergency full collection
when an allocation is refused; LuaJIT's `lj_mem_realloc` calls `lj_err_mem`
immediately, and our `lj52_alloc` refuses rather than collecting. **This is the
strongest argument the project has for implementing an emergency mode**, and it
is no longer a mechanism argument — it is a benchmark a player could write.

### `strings`: the compiler is the difference between running and not running

| | strings, JIT off | strings, JIT on |
|---|---|---|
| result | `ok/12582912-3852468224`, 1.05–1.08 s | **machine lost** |
| free after / on entry | ~937 KB free after | 909 KB free on entry |
| runs | 2 of 2 | 0 of 2 |

Same native, same kernel, same source, same machine size. Standalone the same
file allocates **3064 KB at return with the JIT on against 90 KB with it off**
(210 traces against 0), and the live set after a full collect is ~70 KB either
way — so this is allocation **churn**, not a leak, hitting an allocator that
refuses instead of collecting.

Its idiomatic twin `strings2` — *identical checksum*, and 1.80× faster under
the same compiler — runs fine in every cell. Two codings of one computation,
one of which the compiler makes unrunnable on a 1 MB machine.

Cell A now runs `strings` too (1.776 s). It could not before: the pair ended
its checksum with `string.format("%d", acc)` and `acc` exceeds 2³¹, which
raises on PUC 5.2 — the one VM `references.txt` had never been verified
against. That failure arrived through the driver as a skipped row and was first
read as OC's RAM cap refusing the benchmark.

## The sandbox is the ceiling on host-call-bound work

`trampoline` is 1.08× C-over-B in-machine, against **6.4× standalone**. More
tellingly it runs 0.62 s in-machine compiled against **0.051 s standalone
interpreted** — twelve times slower inside the machine than outside it with the
compiler off — while `mandelbrot` is essentially identical in and out
(0.823 in-machine `-joff` against 0.511 standalone).

So for `pcall`-heavy work the surcharge is paid outside the VM and the compiler
cannot reach it: OC's `machine.lua` replaces `pcall` with a Lua closure whose
first act is a `computer.realTime()` upcall the recorder cannot follow, and our
own allocator does a JNI round trip on every accounted allocation. Quote this
as the **12× boundary gap**, never as the 1.08×, which is below the noise
floor.

This is the honest limit on the whole project, and it is the same shape as
Phase 0's component-call result: a faster VM does not make a host call cheaper.

## What this does not say

* **Cell A is unstable: about 6 of its 26 runs wedged** (machine alive, suite
  never completing, ~160 s), which is why several A rows have n=1 or n=2. The
  A column is the weakest in the table and `sieve`/`sha256` A-values rest on a
  single run each.
* **The RAM guard is wrong for cell A and is still applied there.** It exists
  because LuaJIT has no emergency GC; PUC does, and `computer.freeMemory()`
  reads near zero on PUC simply because nothing has been collected yet. One
  `strings2` run lost two of three reps to it at a reported 4 KB free. Cell A
  should not be guarded at all.
* **`nqueens` reverses sign against standalone.** Compiled LuaJIT is *slower*
  than its own interpreter standalone (1.559 s against 1.022 s) but 1.44×
  faster in-machine. Unexplained.
* **One machine configuration**, one OS, one tier of hardware, one box.
* **Nothing has run in Minecraft.** Every number here is ocelot-brain.
