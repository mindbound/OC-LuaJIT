# The sandbox-tax ladder — our LuaJIT inside a machine against plain LuaJIT, rung by rung

Date: 2026-09-22. Companion to
[results-2026-09-01.md](results-2026-09-01.md) (standalone VMs against PUC),
[results-in-machine-2026-09-03.md](results-in-machine-2026-09-03.md) (Phase 0,
one benchmark in a machine) and
[results-in-machine-phase1-2026-09-04.md](results-in-machine-phase1-2026-09-04.md)
(the suite in a machine, three cells). Those compared our VM with PUC Lua. This
one compares it with **itself**: the same eight programs, the same source
files, run on plain upstream LuaJIT and then on each successive layer we put
between a LuaJIT and an OpenComputers program, so that every layer's cost has a
number of its own.

## The question

How does our LuaJIT inside a machine compare with plain LuaJIT, and which rung
of the ladder pays for the difference? The layers, in the order a program meets
them:

1. our build flags and the two source patches (CHECKHOOK, LUA52COMPAT, the
   penalty scrub);
2. jnlua's allocator convention — the VM runs on the C library's
   `realloc`/`free` instead of LuaJIT's own `lj_alloc`;
3. the shim's memory accounting on every allocation;
4. the machine's RAM cap, at the real size of the harness machine;
5. the sandbox and the JVM — `machine.lua`, OpenOS, the watchdog, ocelot-brain.

Every rung ran the identical `bench/oc/*.lua` files with the identical
`compat.lua`, so a CHECK mismatch anywhere would have rejected the row. None
did: 480 standalone processes and 16 in-machine rows, one checksum per
benchmark throughout.

## The machine and the binaries

- Box: AMD Ryzen 7 7840U, Windows 11 Pro 10.0.26200. **Not idle** during any
  of the sweeps: a Minecraft client JVM and other desktop load were running
  (the ladder script logged 62% CPU load before the standalone sweep and
  57% after it; 56% before the cap sweep and 57% after, with four `java.exe`
  processes alive — the process list was logged only for the cap sweep).
  Within-cell spreads are 1.08–1.83x over the 480 standalone cells and
  1.04–1.54x in-machine, and every reported time is the **min of n = 5**.
- **r1** — `pf/luajit-pristine/src/luajit.exe`, md5 `71368fd6…`, `-v` prints
  `LuaJIT 2.1.1787165859`. Built from the pristine upstream checkout
  `1ee778a4` with no `XCFLAGS` at all: no CHECKHOOK, no LUA52COMPAT, no
  penalty scrub, LuaJIT's own `lj_alloc`. The driver's fingerprint on every
  r1 row reads `compat52=no native=none`.
- **r2** — `build/native/luajit-windows-x86_64/src/luajit.exe`, md5
  `fe6c61d8…`, `-v` prints `LuaJIT 2.1.ROLLING`. The same upstream commit
  built by `native/build-native.sh` with
  `XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK"`, the
  CHECKHOOK patch in `lj_record.c` and the penalty scrub in `lj_func.c`
  (`native/luajit/patch-penalty-scrub.sh`). Still on `lj_alloc`. Fingerprint
  `compat52=yes native=none`.
- **r3 (all variants)** — `pf/T/ladder_host.exe`, a bare C host linked against
  the same `lj52shim.o`, `eris_lj.o` and `libluajit.a` the DLL links, so
  `luaL_newstate` is `lj52_newstate`: the state is born on `lj52_alloc` and
  never uses `lj_alloc`. It fakes jnlua's Java side with a `FakeState` struct
  and plain C `getluamemory`/`setluamemory` (one counter increment and two
  field reads or one write each). Standalone ladder host md5 `9f09cd9d…`; the
  cap sweep ran the teardown-fixed host `126171d5…` (see the crash caveat —
  the fix touches only what happens after the TIME line). Fingerprint
  `compat52=yes native=luajit/LuaJIT 2.1.ROLLING`.
- **Rung 4** — the ocelot-brain machine of `OcljSmoke.scala`: native DLL
  `libjnluajit52-windows-x86_64.dll` md5 `4312750e…` (the pressure-flush
  build; serializer `8c5a1168`; eris fingerprint
  `1ee778a4|LuaJIT 2.1.ROLLING|8c5a1168`), the **watchdog** kernel, RAM tier
  `threehalf` (1024 KB as the sandbox sees it, ramScale 3.0), OpenOS booted to
  a shell in 180 ticks / 5.34–5.37 s in all four boots.

Timing is `os.clock()` inside each benchmark around its measured kernel, in
every rung. Standalone, the driver hands the benchmark
`os = {clock = realos.clock}`; in the machine the sandbox's `os.clock` is the
raw one (`machine.lua:1019`, `clock = os.clock`). Both are the C library's
`clock()`, which on Windows is wall time since process start
(results-2026-09-01, method note), so both charge the benchmark for any time
the core was given to something else.

## The rungs, precisely

| arm | binary | JIT | allocator | cap | what is added |
|---|---|---|---|---|---|
| **r1** | pristine `luajit.exe` | on | `lj_alloc` | none | nothing: plain upstream LuaJIT |
| r1j | same | `-joff` | `lj_alloc` | none | |
| **r2** | ours `luajit.exe` | on | `lj_alloc` | none | + CHECKHOOK, LUA52COMPAT, penalty scrub |
| r2j | same | `-joff` | | | |
| **r3u** | `ladder_host --nocap` | on | C library `realloc`/`free` via `lj52_alloc` with `M->accounting == 0` | none | + the shim state and jnlua's allocator convention; accessors never called (asserted: `sets == 0`) |
| r3uj | same `--joff` | `jit.off()` | | | |
| **r3** | `ladder_host` | on | same, accounting bound (`lua_setallocf(L, NULL, L)`, the "capped" form) | 64 MB | + a get and a set on every allocation, the pressure check, `lj52_gc_pressure` (asserted: `sets > 0`) |
| r3j | same `--joff` | `jit.off()` | | | |
| **r3c** | `ladder_host --total 3457941` | on | same | 3 457 941 B | the cap set to the harness machine's real byte total: 1024 KB x 3.0 + kernelMemory 312 213 |
| r3cj | same `--joff` | `jit.off()` | | | |
| **rung 4** | ocelot-brain machine | on | the DLL, real jnlua JNI accessors | 3 457 941 B (`totalMemory` of the `h-all-jiton` boot; the sieve boot 3 548 033) | + `machine.lua` sandbox, OpenOS 1.8.9, the watchdog, the JVM |
| rung 4 off | same, `OCLJ_JIT=off` | `jit.off()` + `jit.flush()` before boot | | 3 471 313 B (`h-all-jitoff`, kernelMemory 325 585 — 13 372 B above r3cj's; the sieve boot 3 468 993) | |

r1, r2 and the r3 arms were **interleaved** (for run 1..5: for benchmark: for
arm), one fresh process each, 320 processes in 12 minutes, so box drift hits
every arm alike. The cap rung is a separate 160-process sweep of r3/r3c/r3j/r3cj,
r3 and r3c of one benchmark back to back. Rung 4 is four boots: one machine
running the seven non-quarantined benchmarks in sequence (mandelbrot,
binarytrees, trampoline, matmul, strings2, nqueens, sha256; five repetitions
each, min taken), one running only `sieve` (quarantined in `references.txt`,
so it gets a machine of its own), and the same pair with `jit.off()`.

## Results — JIT on

Min of 5, seconds. r1–r3 are the interleaved sweep; r3c is the cap sweep; rung
4 is `os.clock` inside the sandbox. The CHECK was identical on every arm and
every run.

| benchmark | r1 plain | r2 ours | r3u host, libc alloc | r3 + accounting, 64 MB | r3c cap 3.46 MB | rung 4 machine | in-game | CHECK |
|---|---:|---:|---:|---:|---:|---:|---|---|
| mandelbrot | 0.0910 | 0.0900 | 0.0880 | 0.0940 | 0.0920 | 0.1574 | | `37904620` |
| sha256 | 0.0520 | 0.0510 | 0.0490 | 0.0490 | 0.0470 | 0.0849 | | `4044b974…25a5d` |
| matmul | 0.1350 | 0.1260 | 0.1640 | 0.1600 | 0.1630 | 0.3347 | | `481.0000` |
| nqueens | 1.8910 | 1.6870 | 1.7750 | 1.6820 | 1.7100 | **1.3533** | | `85200` |
| sieve | 0.1000 | 0.1160 | 0.2600 | 0.2310 | 0.2270 | 0.2898 | | `4626000` |
| binarytrees | 0.2860 | 0.2770 | 0.5390 | 0.5640 | 0.6290 | 1.8325 | | `7038400` |
| strings2 | 0.2050 | 0.2110 | 0.2710 | 0.2820 | 0.2660 | 0.5841 | | `12582912-3852468224` |
| trampoline | 0.0090 | 0.0080 | 0.0080 | 0.0080 | 0.0100 | 0.7364 | | `247388` |

The **in-game** column is empty: nothing here ran in Minecraft. It can be
filled from the OpenOS REPL by the T5 method in
[docs/in-game-tests.md](../docs/in-game-tests.md) (run `bench/oc/<name>.lua`
from the shell, min of 5, same checksum).

Ratios, computed from the mins; > 1 means slower than the arm to the left of
the slash.

| benchmark | r2/r1 | r3u/r2 | r3/r3u | r3c/r3 (cap sweep) | rung 4/r3c | **rung 4/r1** |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.989 | 0.978 | 1.068 | 1.000 | 1.711 | **1.730** |
| sha256 | 0.981 | 0.961 | 1.000 | 0.922 | 1.806 | **1.633** |
| matmul | 0.933 | 1.302 | 0.976 | 1.032 | 2.053 | **2.479** |
| nqueens | 0.892 | 1.052 | 0.948 | 0.992 | 0.791 | **0.716** |
| sieve | 1.160 | 2.241 | 0.888 | 0.962 | 1.277 | **2.898** |
| binarytrees | 0.969 | 1.946 | 1.046 | 0.841 | 2.913 | **6.407** |
| strings2 | 1.029 | 1.284 | 1.041 | 0.940 | 2.196 | **2.849** |
| trampoline | 0.889 | 1.000 | 1.000 | 1.250 | 73.6 | **81.8** |

Cumulative ratios to r1 for the intermediate rungs, all from the interleaved
sweep: r3u/r1 = 0.967, 0.942, 1.215, 0.939, 2.600, 1.885, 1.322, 0.889 and
r3/r1 = 1.033, 0.942, 1.185, 0.889, 2.310, 1.972, 1.376, 0.889 (benchmark order
as in the table). r3c/r1 crosses two sweeps: 1.011, 0.904, 1.207, 0.904,
2.270, 2.199, 1.298, 1.111.

n and spread (max/min within the cell):

| benchmark | r1 | r2 | r3u | r3 | r3c | rung 4 |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 5, 1.31x | 5, 1.39x | 5, 1.33x | 5, 1.22x | 5, 1.36x | 5, 1.07x |
| sha256 | 5, 1.12x | 5, 1.35x | 5, 1.27x | 5, 1.47x | 5, 1.15x | 5, 1.11x |
| matmul | 5, 1.10x | 5, 1.63x | 5, 1.23x | 5, 1.51x | 5, 1.23x | 5, 1.18x |
| nqueens | 5, 1.18x | 5, 1.28x | 5, 1.23x | 5, 1.39x | 5, 1.11x | 5, 1.09x |
| sieve | 5, 1.80x | 5, 1.79x | 5, 1.19x | 5, 1.29x | 5, 1.44x | 5, 1.54x |
| binarytrees | 5, 1.15x | 5, 1.50x | 5, 1.37x | 5, 1.83x | 5, 1.21x | 5, 1.16x |
| strings2 | 5, 1.46x | 5, 1.18x | 5, 1.48x | 5, 1.56x | 5, 1.27x | 5, 1.27x |
| trampoline | 5, 1.22x | 5, 1.25x | 5, 1.38x | 5, 1.25x | 5, 1.10x | 5, 1.06x |

## Results — the interpreter arms

Same rungs with the compiler off (`-joff` on the bare binaries, `jit.off()`
in the host and the machine; the fingerprint on every row confirmed
`jit=off`, and the rung-4 boots reported `traces start/stop/abort/flush =
0/0/0/0`, `mcode=0 B`).

| benchmark | r1j | r2j | r3uj | r3j | r3cj | rung 4 off | in-game |
|---|---:|---:|---:|---:|---:|---:|---|
| mandelbrot | 0.5380 | 0.5190 | 0.5300 | 0.5320 | 0.5290 | 0.8773 | |
| sha256 | 1.1750 | 1.1820 | 1.2190 | 1.2990 | 1.1640 | 2.1127 | |
| matmul | 0.7550 | 0.8680 | 0.7690 | 0.8060 | 0.7970 | 1.5614 | |
| nqueens | 1.2740 | 1.1900 | 1.1440 | 1.1880 | 1.1450 | 2.0783 | |
| sieve | 0.7630 | 0.7670 | 0.8420 | 0.7840 | 0.8650 | 1.3627 | |
| binarytrees | 0.3460 | 0.3610 | 0.6640 | 0.7330 | 0.8160 | 1.7001 | |
| strings2 | 0.4610 | 0.4990 | 0.5100 | 0.5050 | 0.4770 | 1.1561 | |
| trampoline | 0.0580 | 0.0540 | 0.0570 | 0.0560 | 0.0550 | 0.7389 | |

| benchmark | r2j/r1j | r3uj/r2j | r3j/r3uj | r3cj/r3j | rung 4 off/r3cj | **rung 4 off/r1j** |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.965 | 1.021 | 1.004 | 1.037 | 1.658 | **1.631** |
| sha256 | 1.006 | 1.031 | 1.066 | 0.949 | 1.815 | **1.798** |
| matmul | 1.150 | 0.886 | 1.048 | 0.983 | 1.959 | **2.068** |
| nqueens | 0.934 | 0.961 | 1.038 | 1.040 | 1.815 | **1.631** |
| sieve | 1.005 | 1.098 | 0.931 | 1.138 | 1.575 | **1.786** |
| binarytrees | 1.043 | 1.839 | 1.104 | 1.024 | 2.083 | **4.914** |
| strings2 | 1.082 | 1.022 | 0.990 | 1.008 | 2.424 | **2.508** |
| trampoline | 0.931 | 1.056 | 0.982 | 0.948 | 13.43 | **12.74** |

Interpreter spreads: r1j 1.13–1.59x, r2j 1.12–1.65x, r3uj 1.10–1.55x, r3j
1.16–1.61x, r3cj 1.13–1.69x, rung 4 off 1.04–1.35x; n = 5 everywhere.

## The ladder, rung by rung

### 1. r2/r1 — CHECKHOOK, LUA52COMPAT and the penalty scrub

JIT on: 0.889 (trampoline), 0.892 (nqueens), 0.933, 0.969, 0.981, 0.989,
1.029 (strings2), **1.160 (sieve)**. JIT off: 0.931, 0.934, 0.965, 1.005,
1.006, 1.043, 1.082 (strings2), **1.150 (matmul)**.

Of the two ratios above 1.10, sieve's sits in two of the noisiest cells of
the sweep: its r1 and r2 cells have spreads of 1.80x and 1.79x (r1 min
0.1000, max 0.1800). matmul's is the JIT-off r2j/r1j = 1.150, whose cells spread
1.26x (r1j) and 1.15x (r2j); its JIT-on r2 cell is the 1.63x one, but that
ratio (r2/r1) is 0.933. Every r2/r1 ratio lies inside the spread of its own
two cells. No trace counts exist for r1 or r2 — the `_OCLJ_JITSTATS`
accessor is the shim's and appears only from rung 3 on — so the compiler's
work on the two binaries is not compared here, only their times.

### 2. r3u/r2 — the C library's allocator in place of `lj_alloc`

This is the largest standalone rung. JIT on:

| benchmark | r3u/r2 | allocator calls per run (the host's `gets=`, r3) |
|---|---:|---:|
| **sieve** | **2.241** | 72 498–72 509 |
| **binarytrees** | **1.946** | 14 074 979–14 076 582 |
| **matmul** | **1.302** | 816 455–816 469 |
| **strings2** | **1.284** | 3 188 024–3 189 653 |
| nqueens | 1.052 | 776 |
| trampoline | 1.000 | 465 |
| mandelbrot | 0.978 | 472–497 |
| sha256 | 0.961 | 574 |

JIT off: binarytrees **1.839**, sieve 1.098, trampoline 1.056, sha256 1.031,
strings2 1.022, mandelbrot 1.021, nqueens 0.961, matmul 0.886.

The four benchmarks that allocate in their measured loop are the four that
pay; the four that do not (under 800 allocator calls in the whole run,
benchmark, driver and compiler together) do not. Call count alone
does not order the cost — sieve pays the most on 72 K calls, strings2 the
least of the four on 3.2 M — which is consistent with the cost living in what
`realloc` does with each block rather than in the call itself (sieve builds a
fresh 8192-entry table per repetition, 4500 times, per
results-in-machine-phase1-2026-09-04; the others allocate many small
objects). binarytrees pays nearly the same with the compiler off (1.839) as
on (1.946): the tax is not the compiler's. That it is the allocator's is the
leading candidate, consistent with the call counts, but not separated by any
arm here: r3u differs from r2 by the executable, `lj52_newstate`'s state
record, `lj52_alloc`'s dispatch on every call and the eris link as well as
the allocator, and no arm ran the host on `lj_alloc`.

What r3u is: `lj52_alloc` with `M->accounting == 0` is `lj52_libc`, which is
literally `free(ptr)` / `realloc(ptr, nsize)` (`native/lj52shim.c:285-288`).
A LuaJIT created through `lua_newstate` with a caller-supplied allocator never
touches `lj_alloc`, its own two-level allocator, and that is what jnlua does —
`lua_newstate(l_alloc_checked, …)` over `realloc`/`free` — so **every machine
this project builds inherits this rung**; it is jnlua's convention, not a
choice of ours. Stock OpenComputers pays the C library too: PUC Lua's default
`l_alloc` is `realloc`/`free` as well, and jnlua wraps it the same way. The
rung is therefore a cost relative to a bare `luajit.exe`, not relative to what
a player runs today; it is what a LuaJIT loses by not being allowed its own
allocator. Whether an `lj_alloc`-backed accounting allocator is possible under
jnlua's `lua_setallocf` convention is a question this measurement raises and
does not answer.

### 3. r3/r3u — the accounting

JIT on: mandelbrot 1.068, binarytrees 1.046, strings2 1.041, sha256 1.000,
trampoline 1.000, matmul 0.976, nqueens 0.948, sieve 0.888. JIT off:
binarytrees 1.104, sha256 1.066, matmul 1.048, nqueens 1.038, mandelbrot
1.004, strings2 0.990, trampoline 0.982, sieve 0.931.

On the benchmark that exercises it hardest — binarytrees, 14.08 M accounted
calls per run, each a `getluamemory`, the delta arithmetic, the
`lj52_gc_pressure` check and a `setluamemory` — the rung reads 1.046 with
the compiler on and 1.104 with it off, against cell spreads of 1.83x and
1.45x. The three benchmarks with 72 K–3.2 M calls read 0.888–1.041 (on) and
0.931–1.048 (off). Every other ratio is within 0.07 of 1.000 in either
direction.

This measures the shim's part of the roadmap row "Benchmark the accounting's
cost": the bookkeeping in `lj52_alloc` costs between 0.89x and 1.10x on
these workloads, min of 5, on a box whose cells spread 1.1–1.8x. It does
**not** close the row: the row names a JNI field get and set on every
allocation, and the host's `getluamemory`/`setluamemory` are C functions on
a struct, not `GetIntField`/`SetIntField` through a JVM. That crossing runs
14 M times per binarytrees run inside rung 4, remains unmeasured, and is one
of the things rung 4's residual contains (section 5). Batching the publish,
the row's proposed trade, would address the JNI part, and this rung says
nothing about how much that part is.

### 4. r3c/r3 — the machine's RAM cap

JIT on: 1.000, 0.922, 1.032, 0.992, 0.962, 0.841 (binarytrees), 0.940, 1.250
(trampoline: 8 ms against 10 ms at 1 ms resolution). JIT off: 1.037, 0.949,
0.983, 1.040, 1.138 (sieve), 1.024, 1.008, 0.948. Spreads in the four cells
of each benchmark 1.08–1.69x.

The cap did not bind. At `--total 3457941` the emergency collector arms when
accounted use exceeds 2 593 456 bytes (headroom total/4 = 864 485); `arms=0
collects=0 bailouts=0 refusals=0` in all 160 rows, and no OOM row (exit 2)
anywhere. Peak accounted use is bounded by that instrument — an allocation
that had crossed the watermark would have counted an arm — and the host's
`used=` at exit per benchmark was:

| benchmark | used at exit, JIT on (r3 / r3c) | JIT off (r3j / r3cj) |
|---|---:|---:|
| mandelbrot | 82 268–97 840 / same | 66 516–68 564 / same |
| sha256 | 106 281 / 106 629 | 90 069 / 90 069 |
| matmul | 178 311–246 503 / 156 151–246 503 | 150 911–194 207 / same |
| nqueens | 183 193 / 183 193 | 81 813 / 81 813 |
| **sieve** | **795 145 / 795 145** | 63 617–63 657 / 63 657 |
| binarytrees | 178 677–268 209 / 148 733–263 453 | 113 425–180 841 / 113 425–204 593 |
| strings2 | 293 347–374 303 / 299 667–370 611 | 275 155 / 275 155 |
| trampoline | 85 360 / 85 360 | 81 740 / 81 740 |

The largest, sieve's 795 145 bytes, is 23% of the cap and 31% of the arm
threshold. So this rung shows what the cap costs when nothing approaches it:
the same comparison against a different number. It shows nothing about the
cost when the collector does arm; the only measured point where it does is
the in-machine sieve of the next section, and that point is confounded with
everything else rung 4 adds.

### 5. rung 4/r3c — the sandbox and the JVM

r3c is the closest standalone rung: same DLL objects, same allocator, same
accounting, the cap set to the byte total the `h-all-jiton` boot reported
(`totalMemory=3457941`, `kernelMemory=312213`; the `h-all-jitoff` boot's was
3 471 313). What remains is `machine.lua`, OpenOS, the watchdog, jnlua's
real JNI accessors and the JVM.

**Pure loops** — mandelbrot **1.711** (JIT off 1.658), sha256 **1.806**
(1.815), matmul **2.053** (1.959), sieve **1.277** (1.575). With the compiler
on or off the factor is the same to within 0.1 for the first three; whatever
the machine adds to them is not a per-trace cost. sieve is the one workload
that reached the machine's watermark: `GC PRESSURE: arms=800 collects=800
bailouts=0 refusals=0` with the JIT on and `arms=680 collects=680` with it
off, in a machine whose kernel and OpenOS already held 806 KB raw after boot
(488 KB in the JIT-off boot — a read the harness flagged `NOT QUIESCED after
45 spins` and took under the monitor while the machine thread ran), against
`arms=0` for the same program in the host at r3c's 3 457 941 B (the sieve
boots' caps were 3 548 033 and 3 468 993 B, 90 092 and 11 052 B larger;
795 KB used at exit, no OpenOS). 800 emergency cycles are inside sieve's
1.277.

**Allocation-heavy** — binarytrees **2.913** (JIT off 2.083), strings2
**2.196** (2.424). Above the pure-loop band with the compiler on; with it
off, binarytrees (2.083) is at the edge of the JIT-off pure-loop band
(1.575–1.959) and strings2 (2.424) is 24% above it. binarytrees makes
14.08 M accounted allocator calls per run and strings2 3.19 M, and in the
machine every one of them is a real JNI
`getluamemory` + `setluamemory` (section 3 measured the shim's part of that
at 1.046/1.104, with plain C accessors). If the pure-loop factor of about
1.7–2.05 applied to binarytrees as well, the remainder would be 0.5–0.8 s
over 14 M calls; that is arithmetic on an assumption, not a measurement, and
the data cannot separate the JNI crossing from the sandbox's other costs.

**pcall-heavy** — trampoline **73.6** (JIT off **13.43**). In the machine the
compiled run (0.7364) and the interpreted run (0.7389) are the same time:
the compiler, which buys 5.5x in the host (r3cj/r3c) and 6.44x on plain
LuaJIT, buys 1.003x here. This reproduces the Phase 1 "12x boundary gap"
(0.62 in-machine against 0.051 standalone interpreted on 2026-09-04; today
0.7364 against 0.0550 is 13.4x). Phase 1 attributed part of it to "our own
allocator does a JNI round trip on every accounted allocation"; rung 3 does
not test that part. Its 465 allocator calls per run (and r3/r3u = 1.000) are
the host's count under the driver's plain `pcall`; inside the machine `pcall`
is `machine.lua`'s Lua closure, whose first act is a `computer.realTime()`
upcall (per Phase 1), and its per-call allocations were never counted, so
the in-machine accounted-allocation count for trampoline is unmeasured and
the JNI-per-allocation explanation is not excluded for the machine. The gap
sits in what the sandbox does to `pcall` and its callers and whatever else
the machine adds. The ladder places it between r3c and rung 4 and cannot
place it more finely.

**nqueens — faster in the machine than anywhere standalone.** JIT on,
in-machine **1.3533** (spread 1.09x, n = 5) against r1 1.8910, r2 1.6870,
r3u 1.7750, r3 1.6820, r3c 1.7100: 0.716x plain LuaJIT and 0.76–0.80x every
standalone arm of our own build (r2, r3u, r3, r3c). JIT off it is an ordinary loop — 2.0783,
1.815x r3cj and 1.631x r1j, the same interpreter tax as mandelbrot (1.658 /
1.631), sha256 (1.815 / 1.798) and matmul (1.959 / 2.068). So the sandbox
does not make nqueens's interpreted work cheaper; the compiled code is what
differs. Standalone, the compiler makes nqueens **slower** than the
interpreter on every rung (r1/r1j 1.484; r3c/r3cj 1.493; 118 traces per run,
the most of any benchmark — `traces_ever=118` on r3u and r3); in the machine
it makes it **1.54x faster**.

Reconciling with Phase 1: the 2026-09-04 report first measured B/C = 1.44x
(compiled faster in-machine), re-measured 0.70x, and ruled the row "not
quotable" because cell C's spread inside one boot was 2.05x. Today both
in-machine cells are tight (1.09x and 1.06x, five repetitions in one boot)
and the sign is the first table's: compiled faster in the machine, slower
outside it. The "unexplained sign reversal" of the 09-04 "what this does not
say" list therefore reproduces, and is no longer a measurement artefact of
that kind.

What the data separates: rungs 2, 3u, 3 and 3c all reproduce the standalone
slowness (0.889–0.939 of r1), so the build flags, the allocator, the
accounting and the cap are not where the change happens; it happens between
r3c and rung 4. What it cannot separate, named without ranking:

- OC's replaced builtins and OpenOS's patched globals — the benchmark's call
  targets differ inside the sandbox, and a trace-heavy program (118 traces)
  can end up with a different trace tree;
- the watchdog's arm/disarm on every resume;
- in-sandbox trace aborts — the JIT PROBE counts aborts only around boot and
  its own sandbox loop (`traces start/stop/abort = 233/112/121` in the
  seven-benchmark boot, `284/126/158` in the sieve boot; 371 traces, 377
  live, 720 896 B of mcode after the whole suite), and no per-benchmark abort
  count exists in these logs;
- `os.clock` — the same C `clock()` in both rungs, wall time since process
  start on Windows, so it charges descheduled time in both; it cannot make a
  program read faster in the machine unless the standalone runs were
  descheduled more, which the interleaving argues against but does not
  exclude on a loaded box;
- the JVM thread and its scheduling;
- position in the boot: nqueens ran sixth of seven in its machine, with 286 KB
  free after it (`arms=0` for that whole boot, so no emergency cycle ran).

A rung between r3c and the machine — the bare host running `machine.lua`'s
sandbox over the same driver, with no OpenOS and no JVM — is the measurement
that would split this list, and it does not exist yet.

### 6. JIT against interpreter, inside and outside

The compiler's speedup, interpreted time / compiled time, from the mins:

| benchmark | plain LuaJIT (r1j/r1) | host, capped (r3cj/r3c) | **in the machine** (off/on) |
|---|---:|---:|---:|
| sha256 | 22.60 | 24.77 | **24.88** |
| mandelbrot | 5.91 | 5.75 | **5.57** |
| matmul | 5.59 | 4.89 | **4.67** |
| sieve | 7.63 | 3.81 | **4.70** |
| strings2 | 2.25 | 1.79 | **1.98** |
| binarytrees | 1.21 | 1.30 | **0.93** |
| trampoline | 6.44 | 5.50 | **1.003** |
| nqueens | 0.674 | 0.670 | **1.54** |

Where the work stays inside the VM (sha256, mandelbrot, matmul) the machine
gives the compiler leverage within 0.84–1.10x of plain LuaJIT's (sha256
24.88 against 22.60, mandelbrot 5.57 against 5.91, matmul 4.67 against
5.59 — matmul's leverage in the machine is 16% below plain LuaJIT's).
sieve's leverage halves already in the host (7.63 to 3.81, the allocator
rung) and comes back to 4.70 in the machine. binarytrees and trampoline lose
the compiler's contribution in the machine (0.93 and 1.003), and nqueens
gains one it never had outside. The boot-time probe's own loop reads
0.0057 s compiled against 0.0176 s interpreted in the seven-benchmark boots
(3.1x), 0.0040 against 0.0178 in the sieve boots (4.5x).

The Phase 1 clean experiment (B/C, 2026-09-04) reported sha256 22.64x,
mandelbrot 5.71x, matmul 4.67x, strings2 1.96x, binarytrees 1.10x,
trampoline 1.04x; today's in-machine column reads 24.88, 5.57, 4.67, 1.98,
0.93, 1.003 — the same picture, with n = 5 per cell instead of 3 and no
wedged runs.

## What this does not say

* **The box was not idle.** A Minecraft client JVM and desktop load ran
  throughout; the ladder logged 62% CPU load before the standalone sweep and
  56% before the cap sweep. Within-cell spreads are 1.08–1.83x over the 480
  standalone cells (sieve r1 and r2 at 1.80x/1.79x, binarytrees r3 at 1.83x;
  the two spread tables above print 1.10–1.83x because they omit the cap
  sweep's own r3/r3j cells, whose lowest is 1.08x) and 1.04–1.54x
  in-machine, so a ratio smaller than the spreads of the cells that produced
  it is inside their noise. Interleaving protects the
  within-sweep ratios (r2/r1, r3u/r2, r3/r3u, r3c/r3) from drift; the
  cross-sweep ones (r3c/r1, rung 4/r3c, rung 4/r1) it does not. The same arm
  measured in the two sweeps gives the size of that: r3 read 0.5640 for
  binarytrees in the interleaved sweep and 0.7480 in the cap sweep (1.33x
  apart, though inside the interleaved cell's 0.5640–1.0330 range); the other
  seven benchmarks agree to within 1.09x between sweeps.
* **n = 5, min taken, one box, one OS, one hardware tier.** A min of five on
  a loaded box estimates the fast tail, not the typical run.
* **The interleaved sweep's rung-3 rows crashed at teardown, after the
  measurement.** 13 of the 80 r3/r3j processes exited 139 (r3 matmul x3,
  strings2 x4; r3j binarytrees x3, mandelbrot, strings2, nqueens); none of
  the 80 r3u/r3uj processes did. In all 13 the `TIME` line (line 4) and the
  `HOST end` line (line 8) were printed before the crash, and a reproduction
  of 26 crashes in 50 cap-mode processes had `TIME` before `HOST end` in
  26/26. The cause was the host's teardown order, not the shim: it called
  `lua_close` with the accounting still bound; `lj_gc_freeall` frees the
  fake `jnlua.JavaState` registry userdata early, and every free after it
  read the cached `*M->javaref` out of a dead block (`lj52shim.c:341`; gdb
  backtraces under `pf/finish/crash/gdb/`, deterministic under the NT debug
  heap with `*javaref == 0xFEEEFEEEFEEEFEEE`, 26/50 on the natural heap).
  jnlua's own `lua_1close` does `lua_setallocf(L, l_alloc_unchecked, NULL)`
  — which the shim turns into `M->accounting = 0` — before `lua_close`
  (that order is taken from `ladder_host.c:97-98` and
  `docs/research/memory-accounting.md:62`; `jnlua.c` itself is not in this
  tree), so the DLL path should not reach this — an inference from that
  order plus the four rung-4 boots closing cleanly, not a DLL crash test.
  The host now does the same (`host_close`), in two steps: a first fix
  (`pf/finish/crash/fixed/`, md5 `ccc03019…`) added `host_close` but left
  the success path on bare `lua_close` and still crashed 13/40
  (`phase2.log`: matmul 5, strings2 8); the second (`fixed-2/`,
  `126171d5…`) routed every exit through it and ran 40/40 clean
  (`phase2b.log`), then 160/160 clean in the cap sweep, with the shim
  untouched. `summarize.lua` tabulated all five runs per cell because the
  TIME lines were intact; the interleaved sweep was not re-run on the fixed
  host.
* **Two cap points only**, 64 MB and 3 457 941 bytes, and neither bound
  (`arms=0` in all 160 rows). The cost of the cap when it does bind is not in
  this document except as the in-machine sieve's 800 arms, which cannot be
  separated from the rest of rung 4.
* **The accounting rung has plain C accessors.** r3/r3u measures the shim's
  bookkeeping; jnlua's JNI field get and set on every allocation — the thing
  the roadmap row is about — is inside rung 4's residual and is not isolated
  by any rung here.
* **Three arms would settle the attributions this document hedges, and none
  exists:** the bare host on `lj_alloc` with accounting off, to isolate the
  allocator from the rest of what r3u adds (section 2); a host built on
  jnlua's real JNI accessors under a JVM, to measure the roadmap row's named
  cost (section 3); and an in-machine accounted-allocation count for
  trampoline, to test the JNI-per-allocation explanation inside the sandbox
  (section 5).
* **One boot per JIT mode for seven benchmarks.** Phase 1 chose one benchmark
  per machine because PUC's cell accumulated garbage; here `arms=0` for both
  seven-benchmark boots, so the emergency collector never ran in them, but
  the benchmarks still ran in a fixed order in a shared heap (free after
  each, JIT on: 859, 610, 764, 727, 579, 286, 742 KB; JIT off: 863, 840, 970,
  794, 622, 936, 797 KB). sieve ran in its own machine and its boots reported
  different `kernelMemory` (402 305 and 323 265 against 312 213 and 325 585),
  so its `totalMemory` was 3 548 033 and 3 468 993 against r3c's 3 457 941 —
  up to 90 092 bytes more cap than the host rung had.
* **The Phase 0 "within 7%" does not reproduce.** 2026-09-03 measured
  mandelbrot at 0.104 in-machine against 0.097 standalone; today it is 0.1574
  in-machine (0.1749 in the Phase 0 probe of the same boot, 0.159 in the
  warm encore) against 0.0910 on plain LuaJIT and 0.0920 in the capped host,
  1.71–1.73x. The 2026-09-04 matrix's 0.155 is what today reproduces. The
  native has changed since 09-03 (a different DLL build) and the box was
  loaded differently; the data cannot say which.
* **`driver.lua`'s comment is wrong about the instrument.** It says "os.clock
  is machine.cpuTime in the sandbox"; our kernel's sandbox `os.clock` is the
  raw `os.clock` (`machine.lua:1019`), i.e. the same C `clock()` the driver
  uses. The measurement is consistent between rungs for that reason; the
  comment should not be relied on.
* **Nothing in Minecraft.** The in-game column is empty by design.

## Files

- Interleaved standalone sweep (r1, r1j, r2, r2j, r3u, r3uj, r3, r3j; 320
  rows): `pf/T/ladder-2/summary.txt`, `raw.tsv`, `ladder.log`, per-process
  logs under `logs/`.
- Cap sweep (r3, r3c, r3j, r3cj; 160 rows): `pf/finish/cap/sweep-2/summary.txt`,
  `raw.tsv`, `ladder.log`, `logs/`.
- Rung 4: `pf/T/h-all-jiton/run.log`, `h-all-jitoff/run.log`,
  `h-sieve-jiton/run.log`, `h-sieve-jitoff/run.log` (`PHASE1 ROW`, `JIT
  PROBE`, `GC PRESSURE`, `JIT MEMORY` lines), each with `native.md5`.
- Crash diagnosis: `pf/finish/crash/` (`phase1.log`, `phase2.log`,
  `phase2b.log`, `gdb/`, `gdb-ab/`, `gdb-ab-2/`, `fixed-2/host.diff`).
- Host and driver: `pf/T/ladder_host.c`, `pf/T/driver.lua`,
  `pf/T/run-ladder.sh`.

`pf/` is this session's scratchpad
(`%LOCALAPPDATA%/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-…/scratchpad/pf`);
none of it is committed. The benchmark sources are `bench/oc/*.lua` and
`bench/oc/compat.lua` (md5 `e8684d9c…` at the time of the cap sweep).
