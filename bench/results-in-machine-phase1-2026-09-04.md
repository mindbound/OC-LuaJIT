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
benchmark: nine benchmarks in one machine measures accumulated garbage, not the
benchmarks.

*That reason is real for cell A and does not explain cell B, which this
document previously claimed it did.* Re-reading the logs: in `matrix/B1`, `B2`,
`B3`, `C2` and `C3` the machine died on **`sieve`, the second benchmark**,
after `mandelbrot` alone, with **926–1003 KB free** — an essentially untouched
machine. Those were not accumulation; they were `sieve` doing in one benchmark
what §8's divergence predicts, which the trio below now measures directly.
One-benchmark-per-machine remains right, for cell A's reason.

**Interleaved A→B→C per benchmark, three replicates spread across the hour.**
Box speed on this machine drifts by up to 2×. An earlier matrix reported
mandelbrot A/C as **28×**; the replicated figure is **13.2×**, and the whole
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

**RE-RUN 2026-09-04 on the fixed harness.** The first version of this table
carried `n=1` and `n=2` rows throughout. That was the wedge — the harness
reading the machine's Lua state from the JVM thread while ocelot-brain's
executor was using it — discarding roughly one run in four, and not at random:
it clustered on the runs that entered the observation window. Every row below
is `n=3`, from 78 runs with no wedge, no `VOID` and no misattribution.

| benchmark | A — PUC 5.2 | B — ours, JIT off | C — ours, JIT on |
|---|---:|---:|---:|
| mandelbrot | 2.037 (n=3) | 0.884 (n=3) | 0.155 (n=3) |
| sieve | 2.783 (n=3) | *skipped — see below* | *skipped — see below* |
| binarytrees | 4.399 (n=3) | 1.497 (n=3) | 1.359 (n=3) |
| trampoline | 1.098 (n=3) | 0.706 (n=3) | 0.682 (n=3) |
| matmul | 3.579 (n=3) | 1.451 (n=3) | 0.311 (n=3) |
| strings2 | 1.797 (n=3) | 1.196 (n=3) | 0.610 (n=3) |
| nqueens | 4.359 (n=3) | 1.954 (n=3) | 2.810 (n=3) |
| sha256 | 1.445 (n=3) | 1.986 (n=3) | 0.088 (n=3) |
| **strings** *(quarantined)* | 1.940 (n=2) | 1.087 (n=2) | **died both runs** |

Every row that completed returned its reference checksum. `sha256` reproduced
the **published** digest `4044b974…25a5d` in all three cells, `mandelbrot` the
published `37904620`, `nqueens` the published `85200`.

The six `sieve` cells are `SKIP-LOWMEM`, not deaths, and that skip was a units
bug in the guard rather than the guard working. It is fixed, and the trio that
replaces those cells is below.

### Ratios worth quoting

| | B/C — the compiler alone | A/C — versus what players run |
|---|---:|---:|
| sha256 | **22.64×** | — *confounded, see below* |
| mandelbrot | 5.71× | 13.16× |
| matmul | 4.67× | 11.51× |
| strings2 | 1.96× | 2.95× |
| binarytrees | 1.10× | 3.24× |
| trampoline | 1.04× | 1.61× |
| nqueens | **not quotable** | **not quotable** |

**B/C is the clean experiment**: same binary, same kernel, same source, same
machine — only `jit.off()` differs. It reproduces the standalone
`-joff`-versus-compiled ratio closely where the work stays in the VM (sha256
22.64× in-machine against 23.1× standalone; mandelbrot 5.71× against 5.49×).

**`nqueens` is not quotable in either column, and the earlier "sign reversal"
was never a sign.** The first table reported B/C = 1.44×; this one computes
0.70×. Both sit inside the benchmark's own noise. Intra-run spread — fastest
against slowest of the three repetitions *inside a single boot*, identical work
in one process:

| | A | B | C |
|---|---:|---:|---:|
| nqueens | 1.03 | 1.04 | **2.05** |
| matmul | 1.06 | **1.81** | 1.13 |
| strings2 | **1.69** | 1.03 | 1.12 |
| every other row | ≤1.15 | ≤1.11 | ≤1.17 |

A ratio built on a cell that varies 2.05× within one boot cannot have a
reliable sign. This closes the open "nqueens sign reversal" question as a
measurement problem rather than a VM behaviour; `matmul` cell B and `strings2`
cell A are the same fault, smaller, and their ratios should be read as
approximate.

**`sha256` cell A is not a VM comparison in EITHER direction.** PUC 5.2 cannot
parse bitwise operators, so cell A runs `compat.lua`'s **bit32** branch while B
and C run native operators — confirmed in the logs rather than assumed:

```
A-sha256   PHASE1 compat path in-sandbox: bit32-STITCHED
B-sha256   PHASE1 compat path in-sandbox: operators
```

This has always been noted for A/C. It applies just as much to **A/B**, which
is easy to miss and inviting: A at 1.445 s against B at 1.986 s reads as "our
interpreter is slower than PUC", and it is not that finding — the two cells are
running different implementations of the same primitive. Only B/C is free of
it, and B/C is the 22.64×.

**No geomean.** The spread is bimodal by construction and a mean over it would
describe no program.

## Two failures that matter more than the table

### `sieve` fails on our native and runs on PUC — 6 of 6 against 3 of 3

Re-measured 2026-09-04 as a dedicated trio after the matrix, with the RAM
guard's units corrected so the workload was **admitted** rather than refused.
`N, REPS = 8192, 4500` as shipped, one benchmark per freshly booted 1 MB
machine, three replicates per cell.

| | sieve, 1 MB machine, guard admitting |
|---|---|
| A — PUC 5.2 | **completes 3 of 3** — `4626000`, 2.65–2.84 s, 676–805 KB free |
| B — ours, JIT **off** | **`not enough memory` 3 of 3** — one caught by the driver's `pcall`, two machines lost |
| C — ours, JIT **on** | **`not enough memory` 3 of 3** — machines lost |

Cell B is the one that carries the argument: `JIT PROBE: jit.off() +
jit.flush() -> jit.status()=false`, so **no trace memory is involved at all**
and this is plain table churn against the cap. The kernel allocates a fresh
8192-entry `flags` table per repetition — roughly 64 KB of garbage, 4500 times,
with exactly one of them live at any instant.

The size of the gap, from cell B's own boot line:

| | |
|---|---:|
| program budget (`totalMemory 3467681` − `kernelMemory 321953`) | 3072 real KB |
| free at boot | 3042 real KB |
| `sieve` live set, collect-then-count, every REPS in every mode | **52.4 KB** |

The machine died, so the heap reached about **58× its live set** — over 98% of
it garbage at the moment of refusal.

That is [memory-accounting.md §8](../docs/research/memory-accounting.md)'s
divergence doing real damage: PUC's `luaM_realloc_` calls `luaC_fullgc(L, 1)`
and retries when an allocation is refused, finds a heap that is almost entirely
dead, and continues; LuaJIT's `lj_mem_realloc` calls `lj_err_mem` on the first
refusal, and "emergency" appears nowhere in the LuaJIT tree. **This is the
strongest argument the project has for implementing an emergency mode**, and it
is no longer a mechanism argument — it is a benchmark a player could write.

**And a player has no way around it.** `machine.lua` builds the sandbox global
table at `:737` and `collectgarbage` is not in it; the only one is the kernel's
at `:1526`, a full collect every tenth resume, fired *between* resumes — while
`sieve` finishes inside a single resume. Between sandbox code and the wall
there is nothing but `lj52shim.c:290` returning `NULL`.

#### Two corrections this section has had to make about itself

**The earlier "6 runs out of 6" cannot be sourced any more, and that is my
fault.** Those six logs lived in the matrix output directory, which was cleared
by an `rm -rf` when the re-run was launched. What survives on disk from before
today's trio is five shared-machine failures (`matrix/B1,B2,B3,C2,C3`) and two
fresh-machine ones (`matrix3/B-sieve`, `matrix3/C-sieve`). The trio above
replaces that evidence with something better — the guard admits the workload
instead of refusing it — but the destroyed set should not have been destroyed.

**The `SKIP-LOWMEM` rows in the matrix were a units bug, not the guard
working.** `references.txt`'s peak column is real KB;
`computer.freeMemory()` is real free **divided** by `ramScaleFor64Bit`
(`NativeLuaArchitecture.scala:161`, against the cap set at `:145`). A machine
advertising 1024 KB holds 3072 real KB, so the guard was testing 1155 real
against ~977 scaled — off by 3×, in the direction that refuses. An earlier
draft of this document called that skip "precisely the outcome the guard exists
to produce". It was not; it was the harness declining to run a benchmark the
machine had 2.5× the room to start.

Fixing the units does not rescue the guard, because the peak it guards on is an
artifact of whatever samples it. Every sampler is a GC safepoint:

| sieve, same file, same parameters | reported peak |
|---|---:|
| count hook, every 10000 instructions | 440.8 KB |
| in-band, once per repetition | 1143.6 KB |
| unsampled — heap *on return* at REPS=1500 | **1205.7 KB** |

The unsampled heap **at return** exceeds the sampled **peak**, which a peak
cannot do — so even the in-band figure is short, and in a machine it goes past
3042 KB. `sieve` is now quarantined in `references.txt` by hand, as `strings`
already was: quarantine records what was *observed* to kill a machine, where
the guard was predicting it from a number that does not exist.

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

* **Cell A is unstable: about 6 of its 26 runs wedged**, which is why several A
  rows have n=1 or n=2 and `sieve`/`sha256` A-values rest on a single run each.
  **The cause was identified after this table was produced** (2026-09-04): OC's
  stock kernel sometimes fails to clear the count-hook `checkDeadline` re-arms
  when a deadline fires — `debug.sethook(co, checkDeadline, "", 1)`, a hook on
  *every instruction* — and the machine then runs about 200x slow for the rest
  of its life. Measured: **0.00–0.1 heartbeat ticks per second against 3–4 in a
  healthy run**, on a 0.05 s timer. Nothing crashes, so `lastError` is null and
  `isRunning` is true; the suite simply never gets far enough to paint a row,
  which reads from outside as every benchmark failing.

  It correlates with `k4`'s post-timeout loop time being missing — 4/4 in the
  runs that established it, and again in a later cell-C run.

  **ROOT-CAUSED 2026-09-04, AND IT WAS THE HARNESS.** Everything in the two
  paragraphs below is superseded: it was neither OC's kernel nor ours. The
  harness reads the raw `LuaState` (kernel marker, JIT probe, watchdog stats,
  mcode counters) while ocelot-brain's executor thread is using it, and
  `quiesced()` cannot prevent that — `switchTo(Yielded)` arms a thread-pool
  resume *before* the state leaves `Running`, so `!isExecuting` means "a resume
  is already scheduled". Widening the window 50 ms took the wedge rate to 4/4;
  taking the executor's own monitor took it to **0/20 with the marker rate
  unchanged** (p = 2×10⁻⁸ on the conditional). So **roughly a quarter of every
  measurement in this document was being lost to a harness bug**, and the rows
  marked n=1 or n=2 below are its casualties. The suite should be re-run.

  The superseded reasoning is kept because it took three wrong hypotheses to
  get here and the dead ends are worth as much as the answer:

  **(superseded) every cell can hit it, including ours.** An earlier version of
  this paragraph said only the stock-kernel cell was exposed. A `kernel=watchdog`
  run then hobbled with the identical signature, and matrix3's `C-matmul` had
  already burned 453 s the same way. `native/kernel/patch-machine-lua.lua`
  replaces the three *arm* sites but deliberately leaves `checkDeadline`'s own
  post-expiry `debug.sethook(co, checkDeadline, "", 1)` in place, on the
  reasoning that it only runs after the deadline has passed and that `disarm()`
  clears it. When that disarm loses the race the hook stays armed and the
  machine crawls — in **either** kernel. So this is our code as much as OC's,
  and clearing that re-arm is a fix actually available to us. The harness now detects it from the tick rate and reports the run
  as `PHASE1 VOID` with `p1-run-VOID-stock-kernel-hook-not-cleared`, and does
  not judge its benchmark rows: a discarded run is honest, a run reported as
  eight benchmark failures is not. **Re-run a void run; do not tabulate it.**
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
