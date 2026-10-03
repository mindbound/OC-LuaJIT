# The sandbox-tax ladder, re-run on the migrated box — our LuaJIT inside a machine against plain LuaJIT, rung by rung

Date: 2026-09-29. This is [results-ladder-2026-09-22.md](results-ladder-2026-09-22.md)
done again, one week later, on a **different machine**: the same eight programs,
the same source files, the same eight standalone arms, the same cap rung and the
same four in-machine boots, with the two C binaries the ladder needs rebuilt on
the new box by its own compiler. The 09-22 document defines the rungs and the
analysis; this one keeps its section order and asks, at every rung, which of its
findings survive a change of hardware, compiler and load, and which were the old
box's rather than the ladder's. Companions further back:
[results-2026-09-01.md](results-2026-09-01.md),
[results-in-machine-2026-09-03.md](results-in-machine-2026-09-03.md) and
[results-in-machine-phase1-2026-09-04.md](results-in-machine-phase1-2026-09-04.md).

**2026-10-02: the in-game column is in.** In one run in Minecraft on this
box, mandelbrot, matmul and binarytrees (its first rep) read 0.963x, 1.052x
and 1.376x the capped host and 0.839, 0.641 and 0.782 of the ocelot-brain
machine's times, so here the harness's rung 4 overstates what a player pays —
see [The in-game column](#the-in-game-column-t7-2026-10-02). **That evening**
core placement turned out to be the main factor — unpinned, the harness's
JVM reads 1.12–1.50x its performance-core times, the efficient-core arm's
range, and pinned to the performance cores its rung 4 reads
mandelbrot 0.0661, matmul 0.1049 and binarytrees 0.5168 against the game's
0.0626, 0.1031 and 0.5586 ([Addendum 2026-10-02 evening](#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores))
— nqueens' compiled-slower-than-interpreted reading turned out to be the
stale-trace mechanism ([nqueens: the same mechanism](#nqueens-the-same-mechanism)),
and the allocator rung got its missing `lj_alloc` arm, which puts the rung on
the allocator, and a shim change that gives every machine its own `lj_alloc`
arena ([results-allocator-2026-10-02.md](results-allocator-2026-10-02.md)).

## The question

How does our LuaJIT inside a machine compare with plain LuaJIT, and which rung
of the ladder pays for the difference? The layers, in the order a program meets
them, unchanged from 09-22:

1. our build flags and the two source patches (CHECKHOOK, LUA52COMPAT, the
   penalty scrub);
2. jnlua's allocator convention — the VM runs on the C library's
   `realloc`/`free` instead of LuaJIT's own `lj_alloc`;
3. the shim's memory accounting on every allocation;
4. the machine's RAM cap, at the real size of the harness machine;
5. the sandbox and the JVM — `machine.lua`, OpenOS, the watchdog, ocelot-brain.

And a sixth question this document adds: how much of what 09-22 charged to
rung 5 was the box it ran on.

Every rung ran the identical `bench/oc/*.lua` files with the identical
`compat.lua` (md5 `e8684d9c…`, the same file as on 09-22), so a CHECK mismatch
anywhere would have rejected the row. None did: 480 standalone processes and 16
in-machine rows, one checksum per benchmark throughout, and this time not one of
the 480 processes exited abnormally (the 09-22 teardown crash is gone, see the
caveats).

## The machine and the binaries

- Box: Intel Core Ultra 9 285HX (24 cores, 24 threads), 256 GB RAM, Windows 11
  Pro 10.0.26200. **Quiesced**: gradle daemons stopped, no Minecraft, and the
  chain script counted 0 `java` processes before it started (`pf2/chain.log`).
  The ladder script logged 1% CPU load before the standalone sweep and 13%
  after it, 8% before the cap sweep and 10% after, and no java process before
  or after the cap sweep. The 09-22 box was an AMD Ryzen 7 7840U (8 cores, 16
  threads) that was **not idle**: 56–62% load and a Minecraft client JVM
  throughout. Within-cell spreads here are 1.01–1.10x over the 90 standalone
  cells whose times are 40 ms or more (the six trampoline JIT-on cells, 7–9 ms
  at 1 ms resolution, read 1.12–1.29x), against 1.08–1.83x on 09-22; **in-machine
  they are 1.21–2.38x with the compiler on and 1.16–1.35x with it off, wider
  than 09-22's 1.04–1.54x** — see the caveats. Every reported time is the
  **min of n = 5**.
- Compiler: WinLibs GCC 16.2.0 (x86_64-msvcrt-posix-seh, Brecht Sanders r1);
  09-22 used 15.2.0. r1 and r3 were rebuilt on this box by `pf2/rebuild.sh`
  (15:47:35–15:47:54, every md5 in `pf2/rebuild.log`); the old box's binaries
  are preserved under `pf2/old-bin/` — `luajit-pristine-gcc152.exe`
  `71368fd6…`, `ladder_host-gcc152.exe` `126171d5…`, `lua51-gcc152.dll`
  `5e43ffc6…` — and were not run.
- **r1** — `pf/luajit-pristine/src/luajit.exe`, md5 `98e24588…`
  (`lua51.dll` `754bfdce…`), `-v` prints `LuaJIT 2.1.1787165859`. Rebuilt
  from the pristine upstream checkout after asserting it is unpatched: scrub
  markers in `lj_func.c` 0, `make` with no `XCFLAGS` and no `BUILDMODE`, flags
  leaked into the compile lines 0. No CHECKHOOK, no LUA52COMPAT, no penalty
  scrub, LuaJIT's own `lj_alloc`. Fingerprint on every r1 row `compat52=no
  native=none`.
- **r2** — `build/native/luajit-windows-x86_64/src/luajit.exe`, md5
  `cae31580…`, `-v` prints `LuaJIT 2.1.ROLLING`. The same upstream commit built
  by `native/build-native.sh` with this GCC and
  `XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK"`, the
  CHECKHOOK patch in `lj_record.c` and the penalty scrub in `lj_func.c`. Still
  on `lj_alloc`. Fingerprint `compat52=yes native=none`.
- **r3 (all variants)** — `pf/T/ladder_host.exe`, md5 `cc6e8509…` (857 512 B),
  the teardown-fixed host of 09-22 (`host_close` on every exit path)
  recompiled here and linked against the same objects the DLL links:
  `build/native/luajit-windows-x86_64/src/libluajit.a` `13878386…`,
  `build/native/obj-windows-x86_64/lj52shim.o` `8ef84b32…`, `eris_lj.o`
  `8c94e8b0…`. `luaL_newstate` is `lj52_newstate`: the state is born on
  `lj52_alloc` and never uses `lj_alloc`. It fakes jnlua's Java side with a
  `FakeState` struct and plain C `getluamemory`/`setluamemory`. Driver
  `pf/T/driver.lua` md5 `88174b54…`. One host for both sweeps this time.
  Fingerprint `compat52=yes native=luajit/LuaJIT 2.1.ROLLING`.
- **Rung 4** — the ocelot-brain machine of `OcljSmoke.scala`: native DLL
  `build/native/libdir-additive/libjnluajit52-windows-x86_64.dll` md5
  `bcf8715c…` (830 108 B; serializer `8c5a1168`; eris fingerprint
  `eris-lj 0.3 (M3) / 1ee778a4|LuaJIT 2.1.ROLLING|8c5a1168 / fmt=3`), the
  **watchdog** kernel, RAM tier `threehalf` (1024 KB as the sandbox sees it,
  ramScale 3.0), `OCLJ_REPS=5`, JDK **Temurin 1.8.0_504** pinned through
  `OCLJ_JAVA` (the `java` on this box's PATH is 17; the 09-22 numbers were JDK
  8, so the pin keeps the arm comparable), GC pace at LuaJIT's defaults
  (`stepmul=200 pause=200`, logged by the harness). OpenOS 1.8.9 booted to a
  shell in 180 ticks / 5.25–5.27 s in all four boots (boot-ms 5270, 5263,
  5253, 5261; 09-22: 5.34–5.37 s). The DLL is a build of this box (15:29:37
  on 2026-09-29, the same `build-native.sh` run that wrote r2's `luajit.exe`
  and the `lj52shim.o`/`eris_lj.o`/`libluajit.a` r3 links, 15:29:31–15:29:37)
  and **not the DLL 09-22 ran** (`4312750e…`, the
  pressure-flush build); whether the two were built from the same
  `lj52shim.c` and eris source is not established in either document — git
  shows `native/lj52shim.c` last changed in `f32897a` (2026-09-22T20:22+03:00),
  the commit that added the 09-22 document, and which side of that change
  `4312750e…` was built from is unrecorded (the old box's jnlua DLL is not
  among the binaries preserved in `pf2/old-bin/`). The DLL build is therefore
  a confounder of its own between the two documents (see the caveats).

Timing is `os.clock()` inside each benchmark around its measured kernel, in
every rung. Standalone, the driver hands the benchmark
`os = {clock = realos.clock}`; in the machine the sandbox takes
`clock = os.clock` from the raw state (`machine.lua:1019`), which ocelot-brain
has replaced with `machine.cpuTime` ("Two clocks" in the caveats); standalone
it is the C library's `clock()`, wall time since process start on Windows
(results-2026-09-01, method note). Both are wall time, so both charge the
benchmark for any time the core was given to something else — which, on this
box, was very little.

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
| **r3c** | `ladder_host --total 3457941` | on | same | 3 457 941 B | the cap kept at the **09-22** harness machine's byte total (1024 KB x 3.0 + kernelMemory 312 213) so the two documents' r3c rows compare like with like |
| r3cj | same `--joff` | `jit.off()` | | | |
| **rung 4** | ocelot-brain machine | on | the DLL, real jnlua JNI accessors | 3 480 561 B (`totalMemory` of the `h-all-jiton` boot, kernelMemory 334 833; the sieve boot 3 485 921 / 340 193) | + `machine.lua` sandbox, OpenOS 1.8.9, the watchdog, the JVM |
| rung 4 off | same, `OCLJ_JIT=off` | `jit.off()` + `jit.flush()` before boot | | 3 560 281 B (`h-all-jitoff`, kernelMemory 414 553; the sieve boot 3 513 901 / 368 173) | |

The four boots' totals are 22 620 to 102 340 bytes above r3c's 3 457 941. That
is immaterial to the cap rung — the collector armed 0 times in every host cell —
and to the machine's seven-benchmark boots (0 arms); it matters, a little, for
the sieve boots, where the collector did arm (section 5).

r1, r2 and the r3 arms were **interleaved** (for run 1..5: for benchmark: for
arm), one fresh process each: 320 processes in 4 min 8 s (15:48:51–15:52:59),
so box drift hits every arm alike. The cap rung is a separate 160-process
sweep of r3/r3c/r3j/r3cj (15:52:59–15:55:21), r3 and r3c of one benchmark back
to back. Rung 4 is four boots (15:55:21–16:02:09; harness wall 106.0, 91.3,
107.7 and 82.4 s): one machine running the seven non-quarantined benchmarks in
sequence (mandelbrot, binarytrees, trampoline, matmul, strings2, nqueens,
sha256; five repetitions each, min taken), one running only `sieve`
(quarantined in `references.txt`, so it gets a machine of its own), and the
same pair with `jit.off()`.

## Results — JIT on

Min of 5, seconds. r1–r3 are the interleaved sweep; r3c is the cap sweep; rung
4 is `os.clock` inside the sandbox (the `PHASE1 ROW` min, cross-checked against
`run.log`, `harness.log` and `chain.log`). The CHECK was identical on every arm
and every run.

| benchmark | r1 plain | r2 ours | r3u host, libc alloc | r3 + accounting, 64 MB | r3c cap 3.46 MB | rung 4 machine | in-game | CHECK |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| mandelbrot | 0.0650 | 0.0650 | 0.0650 | 0.0650 | 0.0650 | 0.0746 | 0.0626 | `37904620` |
| sha256 | 0.0480 | 0.0470 | 0.0480 | 0.0470 | 0.0480 | 0.0669 | — | `4044b974…25a5d` |
| matmul | 0.0800 | 0.0820 | 0.0940 | 0.0970 | 0.0980 | 0.1608 | 0.1031 | `481.0000` |
| nqueens | 1.0410 | 1.0610 | 1.0700 | 1.0590 | 1.0650 | **0.6765** | — | `85200` |
| sieve | 0.0850 | 0.0870 | 0.2170 | 0.2160 | 0.2170 | **0.1829** | — | `4626000` |
| binarytrees | 0.1920 | 0.1900 | 0.3640 | 0.4090 | 0.4060 | 0.7146 | 0.5586 | `7038400` |
| strings2 | 0.1780 | 0.1770 | 0.2100 | 0.2260 | 0.2230 | 0.3046 | — | `12582912-3852468224` |
| trampoline | 0.0080 | 0.0080 | 0.0070 | 0.0080 | 0.0080 | 0.2756 | — | `247388` |

The **in-game** column is T7 of [docs/in-game-tests.md](../docs/in-game-tests.md),
run in Minecraft on this box on 2026-10-02: min of 5 in one machine, same
files, same checksums; the other five benchmarks are not in the in-game
runner. binarytrees' cell is its first rep, the only one comparable with the
other arms — [The in-game column](#the-in-game-column-t7-2026-10-02) says why
and reads all three.

Ratios, computed from the mins; > 1 means slower than the arm to the left of
the slash. In the two rung-4 columns, where every ratio changed, the 09-22
value follows in brackets; the within-sweep columns' 09-22 values are quoted
in the sections below where they differ.

| benchmark | r2/r1 | r3u/r2 | r3/r3u | r3c/r3 (cap sweep) | rung 4/r3c | **rung 4/r1** |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 1.000 | 1.000 | 1.000 | 1.000 | 1.148 [1.711] | **1.148** [1.730] |
| sha256 | 0.979 | 1.021 | 0.979 | 1.021 | 1.394 [1.806] | **1.394** [1.633] |
| matmul | 1.025 | 1.146 | 1.032 | 1.000 | 1.641 [2.053] | **2.010** [2.479] |
| nqueens | 1.019 | 1.008 | 0.990 | 1.004 | 0.635 [0.791] | **0.650** [0.716] |
| sieve | 1.024 | 2.494 | 0.995 | 0.977 | 0.843 [1.277] | **2.152** [2.898] |
| binarytrees | 0.990 | 1.916 | 1.124 | 1.002 | 1.760 [2.913] | **3.722** [6.407] |
| strings2 | 0.994 | 1.186 | 1.076 | 0.978 | 1.366 [2.196] | **1.711** [2.849] |
| trampoline | 1.000 | 0.875 | 1.143 | 1.000 | 34.45 [73.6] | **34.45** [81.8] |

Cumulative ratios to r1 for the intermediate rungs, all from the interleaved
sweep: r3u/r1 = 1.000, 1.000, 1.175, 1.028, 2.553, 1.896, 1.180, 0.875 and
r3/r1 = 1.000, 0.979, 1.212, 1.017, 2.541, 2.130, 1.270, 1.000 (benchmark
order as in the table). r3c/r1 crosses two sweeps: 1.000, 1.000, 1.225, 1.023,
2.553, 2.115, 1.253, 1.000. The two sweeps agree on their shared arms to within
1.03x on every benchmark (r3 interleaved against r3 in the cap sweep: sieve
0.2160 against 0.2220 is the largest gap; 09-22's binarytrees gap was 1.33x).

n and spread (max/min within the cell):

| benchmark | r1 | r2 | r3u | r3 | r3c | rung 4 |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 5, 1.02x | 5, 1.05x | 5, 1.03x | 5, 1.03x | 5, 1.03x | 5, **1.80x** |
| sha256 | 5, 1.02x | 5, 1.04x | 5, 1.02x | 5, 1.02x | 5, 1.06x | 5, 1.40x |
| matmul | 5, 1.01x | 5, 1.02x | 5, 1.09x | 5, 1.02x | 5, 1.04x | 5, 1.22x |
| nqueens | 5, 1.03x | 5, 1.01x | 5, 1.01x | 5, 1.01x | 5, 1.01x | 5, **2.38x** |
| sieve | 5, 1.04x | 5, 1.01x | 5, 1.03x | 5, 1.05x | 5, 1.05x | 5, **1.96x** |
| binarytrees | 5, 1.02x | 5, 1.04x | 5, 1.07x | 5, 1.04x | 5, 1.04x | 5, 1.21x |
| strings2 | 5, 1.02x | 5, 1.07x | 5, 1.05x | 5, 1.02x | 5, 1.04x | 5, 1.39x |
| trampoline | 5, 1.12x | 5, 1.12x | 5, 1.29x | 5, 1.12x | 5, 1.12x | 5, 1.24x |

A consequence of the tight standalone cells that the rest of this document
leans on: where two cells do not overlap at all (every run of one is faster
than every run of the other), their ratio is resolved, however small. On the
old box that was true of no ratio under about 1.3; here it is true of ratios
as small as 1.008 (nqueens r3u/r2: r2 ran 1.0610–1.0680, r3u 1.0700–1.0840,
2 ms apart — section 2), and of matmul r2/r1 1.025 (r1 0.0800–0.0810, r2
0.0820–0.0840), nqueens r3/r3u 0.990 (section 3) and sieve r3cj/r3j 1.015
(section 4).

## Results — the interpreter arms

Same rungs with the compiler off (`-joff` on the bare binaries, `jit.off()`
in the host and the machine; the fingerprint on every row confirmed
`jit=off`, and the rung-4 boots reported `traces start/stop/abort/flush =
0/0/0/0`, `mcode=0 B`). The **in-game** column is empty: the interpreter
was not measured in the game (T7 ran with the compiler on only).

| benchmark | r1j | r2j | r3uj | r3j | r3cj | rung 4 off | in-game |
|---|---:|---:|---:|---:|---:|---:|---|
| mandelbrot | 0.3760 | 0.3770 | 0.3750 | 0.3770 | 0.3770 | 0.4134 | |
| sha256 | 0.7750 | 0.7710 | 0.7730 | 0.7730 | 0.7710 | 0.9766 | |
| matmul | 0.5850 | 0.5910 | 0.6070 | 0.6110 | 0.6110 | 0.7317 | |
| nqueens | 0.8640 | 0.8700 | 0.8740 | 0.8720 | 0.8740 | 1.0884 | |
| sieve | 0.5930 | 0.5760 | 0.7350 | 0.7100 | 0.7280 | **0.6387** | |
| binarytrees | 0.2500 | 0.2540 | 0.4300 | 0.4890 | 0.4880 | 0.8797 | |
| strings2 | 0.3490 | 0.3470 | 0.3640 | 0.3660 | 0.3650 | 0.6166 | |
| trampoline | 0.0400 | 0.0420 | 0.0410 | 0.0410 | 0.0410 | 0.3577 | |

| benchmark | r2j/r1j | r3uj/r2j | r3j/r3uj | r3cj/r3j | rung 4 off/r3cj | **rung 4 off/r1j** |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 1.003 | 0.995 | 1.005 | 1.005 | 1.097 [1.658] | **1.099** [1.631] |
| sha256 | 0.995 | 1.003 | 1.000 | 0.992 | 1.267 [1.815] | **1.260** [1.798] |
| matmul | 1.010 | 1.027 | 1.007 | 1.005 | 1.198 [1.959] | **1.251** [2.068] |
| nqueens | 1.007 | 1.005 | 0.998 | 1.002 | 1.245 [1.815] | **1.260** [1.631] |
| sieve | 0.971 | 1.276 | 0.966 | 1.015 | 0.877 [1.575] | **1.077** [1.786] |
| binarytrees | 1.016 | 1.693 | 1.137 | 0.988 | 1.803 [2.083] | **3.519** [4.914] |
| strings2 | 0.994 | 1.049 | 1.005 | 0.992 | 1.689 [2.424] | **1.767** [2.508] |
| trampoline | 1.050 | 0.976 | 1.000 | 1.000 | 8.72 [13.43] | **8.94** [12.74] |

Interpreter spreads: r1j 1.01–1.10x (the 1.10x is matmul, one run at 0.6420
against four at 0.5850–0.5950), r2j 1.01–1.02x, r3uj 1.01–1.06x, r3j
1.01–1.05x, r3cj 1.01–1.07x, rung 4 off 1.16–1.35x; n = 5 everywhere.

## The box change, in numbers

Every absolute time moved with the CPU, and not by one factor. Old-box time
divided by new-box time, from the two documents' mins:

| benchmark | r1 | r1j | r3c | r3cj | rung 4 | rung 4 off |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 1.40 (0.0910 → 0.0650) | 1.43 | 1.42 | 1.40 | **2.11** (0.1574 → 0.0746) | 2.12 |
| sha256 | 1.08 (0.0520 → 0.0480) | 1.52 | 0.98 | 1.51 | 1.27 (0.0849 → 0.0669) | 2.16 |
| matmul | 1.69 (0.1350 → 0.0800) | 1.29 | 1.66 | 1.30 | **2.08** (0.3347 → 0.1608) | 2.13 |
| nqueens | 1.82 (1.8910 → 1.0410) | 1.47 | 1.61 | 1.31 | **2.00** (1.3533 → 0.6765) | 1.91 |
| sieve | 1.18 (0.1000 → 0.0850) | 1.29 | 1.05 | 1.19 | 1.58 (0.2898 → 0.1829) | 2.13 |
| binarytrees | 1.49 (0.2860 → 0.1920) | 1.38 | 1.55 | 1.67 | **2.56** (1.8325 → 0.7146) | 1.93 |
| strings2 | 1.15 (0.2050 → 0.1780) | 1.32 | 1.19 | 1.31 | 1.92 (0.5841 → 0.3046) | 1.87 |
| trampoline | 1.13 (0.0090 → 0.0080, one tick) | 1.45 | 1.25 | 1.34 | **2.67** (0.7364 → 0.2756) | 2.07 |

Three things in this table carry the rest of the document.

- The standalone compiled arms moved by 1.0–1.8x, benchmark by benchmark:
  sha256's compiled kernel barely noticed the CPU (1.08x on plain LuaJIT,
  0.98x in the capped host) while nqueens's and matmul's gained 1.7–1.8x on
  plain LuaJIT (r1: 1.82 and 1.69; in the capped host, r3c, 1.61 and 1.66).
  The standalone interpreter moved more uniformly on plain LuaJIT, 1.29–1.52x
  (r1j); the capped host's interpreter, r3cj, moved 1.19x (sieve) to 1.67x
  (binarytrees).
- The in-machine arms moved by **more than the standalone ones on every
  benchmark**: 1.27–2.67x with the compiler on, and **1.87–2.16x with it off,
  all eight inside that band**. Per benchmark, the machine's interpreter
  gained 1.16–1.80x more from the change of box than the capped host's did
  (rung 4 off factor / r3cj factor: 1.51, 1.43, 1.64, 1.46, 1.80, 1.16, 1.43,
  1.54).
- That is why the rung-4 residual of section 5 is smaller here everywhere: the
  ratio rung 4/r3c cannot stay put when its numerator moved 2.1x and its
  denominator 1.4x.

The reading these numbers support is that a part of the 09-22 residual was
the old box's, not the machine's: an 8-core, 16-thread host at 56–62% load,
with a Minecraft client JVM resident, running the harness's poller thread
beside the machine's executor thread, so that the two competed for cores that
a standalone process — one thread, one core — did not have to share. On this
box, with 24 cores, 0 java processes at the start and 1–13% load, the poller
and the executor each have a core of their own, and the machine's tax comes
out smaller relative to the host than it did: with the compiler off
1.16–1.80x smaller (binarytrees 1.16, sieve 1.80, matmul 1.64, the other five
1.43–1.54 — the quotients listed above); with it on 1.25–2.14x (rung 4
factor / r3c factor, i.e. 09-22's rung 4/r3c over today's: mandelbrot 1.49,
sha256 1.30, matmul 1.25, nqueens 1.25, sieve 1.51, binarytrees 1.66,
strings2 1.61, trampoline 2.14). This is the leading
candidate and the one the two documents together support; it is not
separated from the other things that changed with the box — the CPU itself
and its caches, GCC 16.2 against 15.2, the JVM compiling ocelot-brain on a
faster core, JDK 8.0.504 against the old box's JDK 8 build — by any arm run
here, because no arm ran the machine on the old box quiesced or on this box
loaded.

## The ladder, rung by rung

### 1. r2/r1 — CHECKHOOK, LUA52COMPAT and the penalty scrub

JIT on: 0.979 (sha256), 0.990 (binarytrees), 0.994, 1.000, 1.000, 1.019,
1.024 (sieve), **1.025 (matmul)**. JIT off: 0.971 (sieve), 0.994, 0.995,
1.003, 1.007, 1.010, 1.016, **1.050 (trampoline: 42 ms against 40 ms at 1 ms
resolution)**.

Neither of 09-22's two ratios above 1.10 reproduces. sieve's 1.160 (JIT on)
came from cells spreading 1.80x and 1.79x; today the same cells spread 1.04x
and 1.01x and the ratio is 1.024, with the cells overlapping (r1 0.0850–0.0880,
r2 0.0870–0.0880). matmul's JIT-off 1.150 is 1.010 today, cells overlapping
(r1j 0.5850–0.6420, r2j 0.5910–0.5980). Two ratios on this rung are resolved
in the non-overlap sense: matmul JIT on, 1.025 (r1 0.0800–0.0810 against r2
0.0820–0.0840, one millisecond in eighty), and sieve JIT off, 0.971 (r1j
0.5930–0.6050 against r2j 0.5760–0.5880 — ours faster). Every other r2/r1
ratio lies inside the overlap of its own two cells. The flags and the two
patches cost, on these workloads and this box, between −3% and +2.5%
(trampoline's JIT-off +5% is one clock tick). No trace
counts exist for r1 or r2 — the `_OCLJ_JITSTATS` accessor is the shim's and
appears only from rung 3 on — so the compiler's work on the two binaries is
not compared here, only their times.

### 2. r3u/r2 — the C library's allocator in place of `lj_alloc`

This is the largest standalone rung, as on 09-22, and every one of its four
large ratios is now a non-overlapping pair of cells. JIT on:

| benchmark | r3u/r2 | 09-22 | r2 cell / r3u cell | allocator calls per run (the host's `gets=`, r3) |
|---|---:|---:|---|---:|
| **sieve** | **2.494** | 2.241 | 0.0870–0.0880 / 0.2170–0.2240 | 72 497–72 507 |
| **binarytrees** | **1.916** | 1.946 | 0.1900–0.1970 / 0.3640–0.3880 | 14 075 457–14 076 775 |
| **strings2** | **1.186** | 1.284 | 0.1770–0.1900 / 0.2100–0.2200 | 3 188 074–3 189 720 |
| **matmul** | **1.146** | 1.302 | 0.0820–0.0840 / 0.0940–0.1020 | 816 455–816 535 |
| sha256 | 1.021 | 0.961 | overlap | 574 |
| nqueens | 1.008 | 1.052 | 1.0610–1.0680 / 1.0700–1.0840, disjoint by 2 ms | 776 |
| mandelbrot | 1.000 | 0.978 | overlap | 472–497 |
| trampoline | 0.875 | 1.000 | 7 ms against 8 ms | 465 |

JIT off: binarytrees **1.693** (09-22: 1.839), sieve **1.276** (1.098),
strings2 1.049, matmul 1.027 (0.886), nqueens 1.005, sha256 1.003, mandelbrot
0.995, trampoline 0.976. binarytrees' and sieve's JIT-off pairs do not overlap either
(r2j 0.2540–0.2590 against r3uj 0.4300–0.4550; 0.5760–0.5880 against
0.7350–0.7470).

The finding reproduces in shape: the four benchmarks that allocate in their
measured loop are the four that pay, the four that do not (under 800
allocator calls in the whole run, benchmark, driver and compiler together) do
not, and call count alone does not order the cost — sieve pays the most on
72 K calls, strings2 and matmul the least of the four on 3.2 M and 0.8 M. The
sizes moved with the box: sieve's tax grew from 2.24x to 2.49x and matmul's
shrank from 1.30x to 1.15x, which is what one expects if the tax is a fixed
amount of allocator work per block on top of compute that got faster at
different rates per benchmark (sieve's compute moved 1.18x with the box,
matmul's 1.69x). binarytrees pays 1.916 with the compiler on and 1.693 with
it off: the tax is not the compiler's. That it is the allocator's is the
leading candidate, consistent with the call counts and with the per-block
picture (sieve builds a fresh 8192-entry table per repetition, 4500 times, per
results-in-machine-phase1-2026-09-04; the others allocate many small objects),
but not separated by any arm here: r3u differs from r2 by the executable,
`lj52_newstate`'s state record, `lj52_alloc`'s dispatch on every call and the
eris link as well as the allocator, and no arm ran the host on `lj_alloc`.

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
does not answer — it is the same question as on 09-22, now asked on a rung
whose four numbers are resolved rather than inside their cells' noise.

**Answered 2026-10-02** ([results-allocator-2026-10-02.md](results-allocator-2026-10-02.md)).
The arm this section lacked — the same host source linked against a shim
whose states keep their blocks in their own `lj_alloc` arena, every other
object the same — puts the rung on the allocator: r3u over that host reads
sieve 2.647, binarytrees 1.785, strings2 1.177 and matmul 1.157, every pair
of cells disjoint, and what the host adds besides (that host over r2) is
1.000–1.025 on three of the four and 1.077 on binarytrees. The question
above has its answer too: under jnlua's convention the allocator jnlua sees
stays `lj52_alloc` and only the store beneath it changes, and since that day
the shim gives every state its own arena. The r3u and r3 rows in this
document were measured on the pre-arena shim object `8ef84b32…`, on the C
library's allocator as described above.

### 3. r3/r3u — the accounting

JIT on: **binarytrees 1.124**, **strings2 1.076**, matmul 1.032, mandelbrot
1.000, sieve 0.995, nqueens 0.990, sha256 0.979, and trampoline 1.143, which
is 8 ms against 7 ms at 1 ms resolution and is not a measurement of anything.
JIT off: **binarytrees 1.137**, matmul 1.007, mandelbrot 1.005, strings2
1.005, sha256 1.000, trampoline 1.000, nqueens 0.998, sieve 0.966.

On the benchmark that exercises it hardest — binarytrees, 14.08 M accounted
calls per run, each a `getluamemory`, the delta arithmetic, the
`lj52_gc_pressure` check and a `setluamemory` — the rung reads 1.124 with
the compiler on and 1.137 with it off, and both pairs of cells are disjoint
(r3u 0.3640–0.3880 against r3 0.4090–0.4260; r3uj 0.4300–0.4550 against r3j
0.4890–0.5070). strings2's 1.076 is disjoint too (0.2100–0.2200 against
0.2260–0.2300); matmul's 1.032 lies inside overlapping cells (0.0940–0.1020
against 0.0970–0.0990). Two more pairs are disjoint, and in both it is the
**accounting** arm that is faster: nqueens with the compiler on, 0.990 (r3u
1.0700–1.0840 against r3 1.0590–1.0650, 5 ms apart), and sieve with it off,
0.966 (r3uj 0.7350–0.7470 against r3j 0.7100–0.7300). The other eleven
pairs, trampoline's two included, overlap. Divided out per call, from the
mins: binarytrees 0.045 s over 14.08 M calls is 3.2 ns per accounted
allocation with the compiler on and 0.059 s / 4.2 ns with it off; strings2
0.016 s over 3.19 M is 5.0 ns (on); matmul 0.003 s over 0.82 M is 3.7 ns
(on), inside its cells' overlap. Those per-call figures are an upper bound
on a mixture, not a measurement of the get/set: if binding the accounting
can resolvably make nqueens 1% and sieve 3% *faster*, something besides the
bookkeeping moves with the arm — the heap layout `realloc` is handed, the
trace tree (binarytrees' `traces_ever` ran 18–33 on r3u against 15–33 on
r3) — and it is inside binarytrees' 1.124/1.137 as well; no arm here
separates the two. On 09-22 the same rung read 1.046 and 1.104 on
binarytrees against cell spreads of 1.83x and 1.45x, so the number was
inside the noise; here it is a number, with that qualification: **binding
the accounting reads 0.97–1.14x on the seven benchmarks with resolvable
times, compiler on or off (0.98–1.12x with it on, 0.97–1.14x with it off),
and 1.12–1.14x on the one that allocates hardest — at most 3–5 ns per
accounted call, of which the bookkeeping's own cost is the leading candidate
for most but is not separated from what else moves with the arm — min of 5
on cells that spread 1.01–1.09x.**

This bounds the shim's part of the roadmap row "Benchmark the accounting's
cost" (`docs/roadmap.md`) and does **not** close the row, for the reason
09-22 gave: the row names a JNI field get and set on every allocation, and the
host's `getluamemory`/`setluamemory` are C functions on a struct, not
`GetIntField`/`SetIntField` through a JVM. That crossing runs 14 M times per
binarytrees run inside rung 4, remains unmeasured, and is one of the things
rung 4's residual contains (section 5). Batching the publish, the row's
proposed trade, would address the JNI part, and this rung says nothing about
how much that part is.

### 4. r3c/r3 — the machine's RAM cap

JIT on: 1.000, 1.021, 1.000, 1.004, 0.977 (sieve), 1.002, 0.978 (strings2),
1.000. JIT off: 1.005, 0.992, 1.005, 1.002, 1.015 (sieve), 0.988, 0.992,
1.000. Spreads in the four cells of each benchmark 1.01–1.07x, trampoline
1.02–1.12x. Fifteen of the sixteen pairs overlap; the one that does not is
sieve JIT off (r3j 0.7170–0.7250 against r3cj 0.7280–0.7370, 1.015; 1.138 on
09-22). 09-22's binarytrees 0.841 and trampoline 1.250 do not reproduce:
1.002 and 1.000.

The cap did not bind, exactly as before. At `--total 3457941` the emergency
collector arms when accounted use exceeds 2 593 456 bytes (headroom total/4 =
864 485); `arms=0 collects=0 bailouts=0 refusals=0` in all 160 rows, and no
OOM row (exit 2) anywhere. Peak accounted use is bounded by that instrument —
an allocation that had crossed the watermark would have counted an arm — and
the host's `used=` at exit per benchmark was:

| benchmark | used at exit, JIT on (r3 / r3c) | JIT off (r3j / r3cj) |
|---|---:|---:|
| mandelbrot | 82 268–97 840 / same | 68 564 / 66 516–68 564 |
| sha256 | 106 629 / 117 325 | 90 069 / 90 069 |
| matmul | 178 311–213 755 / 156 151–213 755 | 150 911–194 207 / same |
| nqueens | 183 193 / 183 193 | 81 813 / 81 813 |
| **sieve** | **795 145–1 254 285 / 795 145** | 63 617–63 657 / 63 657–326 089 |
| binarytrees | 154 961–244 037 / 148 733–277 189 | 113 425–204 593 / 113 425–190 545 |
| strings2 | 294 643–383 703 / 302 927–378 859 | 275 155 / 275 155 |
| trampoline | 85 360 / 85 360 | 81 740 / 81 740 |

The largest under the 3.46 MB cap, sieve's 795 145 bytes, is 23% of the cap
and 31% of the arm threshold (one 64 MB run of sieve exited at 1 254 285, 36%
and 48% of the same two numbers; its `arms=0` is trivial — at 64 MB the
watermark is 50 331 648 bytes — and says nothing about the 3.46 MB one, though
1 254 285 is below 2 593 456 in any case; the collector's pace, not the cap,
decides when a sieve process exits). So this rung shows what the cap
costs when nothing approaches it: the same comparison against a different
number, and this time with cells tight enough to say "nothing" to within
about 2%. It shows nothing about the cost when the collector does arm; the
only measured point where it does is the in-machine sieve of the next
section, and that point is confounded with everything else rung 4 adds — and
today it is the one benchmark that runs faster in the machine.

### 5. rung 4/r3c — the sandbox and the JVM

r3c is the closest standalone rung: same DLL objects, same allocator, same
accounting, the cap at 09-22's harness total (today's four boots reported
3 480 561, 3 485 921, 3 560 281 and 3 513 901; `kernelMemory` 334 833, 340 193,
414 553, 368 173 against the 312 213 the cap encodes). What remains is
`machine.lua`, OpenOS, the watchdog, jnlua's real JNI accessors and the JVM —
on a box that, unlike 09-22's, gives all of that its own cores.

**Pure loops** — mandelbrot **1.148** (JIT off 1.097), sha256 **1.394**
(1.267), matmul **1.641** (1.198). On 09-22 these read 1.711/1.658,
1.806/1.815 and 2.053/1.959. The residual on the pure loops is 0.4–0.8 lower
across the board (mandelbrot 0.56/0.56, sha256 0.41/0.55, matmul 0.41/0.76,
compiled/interpreted), and 09-22's observation that it is "the same to within
0.1 with the compiler on or off" now holds for mandelbrot (0.05 apart) but not
for sha256 (0.13) and not for matmul, whose compiled residual (1.641) is 0.44
above its interpreted one (1.198). Whatever the machine adds to matmul's
compiled run is not added to its interpreted run; the candidates are the
same as for nqueens below (a different trace tree in the sandbox — matmul
made 19–22 traces in the host and no per-benchmark count exists in the
machine — or a compiled loop that is more sensitive than the interpreter to
whatever the JVM does on the neighbouring cores), and none is separated here.
mandelbrot's in-machine cell is also the widest of the pure loops (1.80x:
0.0746–0.1341) — its max is 2.06x the capped host.

**sieve — faster in the machine than in the host, a new anomaly.** JIT on,
in-machine **0.1829** against r3c 0.2170 and r3 0.2160–0.2220: **0.843**.
JIT off, **0.6387** against r3cj 0.7280 and r3j 0.7170: **0.877**. On 09-22
the same two ratios were 1.277 and 1.575. The machine is still 2.15x plain
LuaJIT (r1 0.0850) — the anomaly is against the host rungs, i.e. against the
allocator rung's 2.49x, part of which the machine does not pay. And it is the
one workload where the machine's emergency collector ran: `GC PRESSURE:
arms=800 collects=800 bailouts=0 refusals=0` with the compiler on (160 cycles
per repetition) and `arms=664 collects=664` with it off, against `arms=0` in
every host cell at either cap; the sieve boots' raw heaps held 671 KB (JIT on)
and 471 KB (JIT off) after boot, and the machine's caps were 3 485 921 and
3 513 901 bytes. The sign is the same with the compiler off, so the compiler
is not what makes it. Candidates, named without ranking:

- GC pacing. In the host, at either cap, LuaJIT's incremental collector runs
  at its default pace and lets sieve's discarded 8192-entry tables accumulate
  (795 KB–1.25 MB accounted at exit); in the machine the shim's emergency
  collector ran a full cycle 160 times per repetition, so `realloc` was handed
  a heap repeatedly collected back to a small size. Section 2 placed sieve's
  entire standalone tax in what `realloc` does with each block; a different
  block population is a candidate for a different tax. No host arm ran with a
  cap that binds, so nothing here separates this.
- The trace tree. The sieve boot ended its suite with 485 traces resident
  (`JIT MEMORY`, 487 live, 262 144 B of mcode) against `traces_ever=19` for
  sieve in the host; the compiled code is not the same code. The JIT-off
  sign says this is at most part of it.
- The repetition structure. In the machine the five repetitions share one
  heap and one trace cache and only the first pays for compilation and heap
  growth; standalone, each of the five processes compiles from cold and grows
  its heap from zero inside the timed window. This applies to every
  benchmark, and the other seven are slower in the machine, so it can be at
  most a part; it would favour the machine most on the shortest benchmarks,
  and trampoline, sha256, mandelbrot and matmul, all shorter than sieve
  (0.085 s plain, fifth of eight), are slower in the machine.
- The 28 KB larger cap in the machine: immaterial, per section 4 (the cap's
  value costs nothing when it does not bind, and in the machine it is the
  watermark, not the cap, that acts).

The in-machine sieve cell spreads 1.96x (0.1829–0.3579), so at least one of
the five repetitions ran slower than every host cell; the min is what is
compared, here as everywhere, and the PHASE1 ROW carries min and max only.
The same program's warm encore in the same boot — run after the Phase 1
suite and before the persist tests — read 0.2008 best of three (0.606 with
the compiler off).

**Allocation-heavy** — binarytrees **1.760** (JIT off **1.803**), strings2
**1.366** (**1.689**). On 09-22: 2.913/2.083 and 2.196/2.424. With the
compiler on, binarytrees sits just above the pure-loop band (1.148–1.641) and
strings2 inside it; with the compiler off, where the pure-loop band is tight
(1.097–1.267, nqueens 1.245), both stand clearly above it: binarytrees 1.803
and strings2 1.689 against a band whose top is 1.267. binarytrees makes
14.08 M accounted allocator calls per run and strings2 3.19 M, and in the
machine every one of them is a real JNI `getluamemory` + `setluamemory`
(section 3 read the accounting arm at 1.124/1.137 with plain C accessors, at
most 3–4 ns per call, and not cleanly the bookkeeping's). If the JIT-off
pure-loop factor (1.097–1.267) applied to binarytrees as well, the remainder
would be 0.26–0.34 s over 14.08 M calls,
19–24 ns per call; the same arithmetic on strings2 gives 0.15–0.22 s over
3.19 M calls, 48–68 ns per call. That is arithmetic on an assumption, not a
measurement, and the two per-call figures disagree by about 2.5–3x, which
argues against a single per-allocation cost explaining both; the data cannot
separate the JNI crossing from the sandbox's other costs (strings2's string
building goes through OpenOS's and `machine.lua`'s replaced globals, and no
arm here isolates that).

**pcall-heavy** — trampoline **34.45** (JIT off **8.72**), against 73.6 and
13.43 on 09-22. Two things changed. First, the in-machine time itself: 0.2756
against 0.7364 (2.67x), the largest move of any cell with the box, where the
standalone trampoline moved 1.13x (one clock tick) compiled and 1.45x
interpreted. Second, **the compiler now reaches part of it in the machine**:
compiled 0.2756 against interpreted 0.3577 is 1.30x, where on 09-22 the two
were equal (0.7364 against 0.7389, 1.003x). Standalone the compiler still buys
5.0x on plain LuaJIT and 5.13x in the capped host. The Phase 1 "12x boundary
gap" (0.62 in-machine against 0.051 standalone interpreted on 2026-09-04;
13.4x on 09-22) is 6.9x today (0.2756 against r1j 0.0400; 6.7x against r3cj
0.0410). Inside the machine `pcall` is `machine.lua`'s Lua closure, whose
first act is a `computer.realTime()` upcall (per Phase 1) — one JNI call into
the JVM per trampoline bounce — and its per-call allocations were never
counted, so the in-machine accounted-allocation count for trampoline is
unmeasured (the host's 465 calls per run are under the driver's plain
`pcall`). A cost that is paid once per `pcall` on the Java side is exactly the
kind that a loaded 8-core box would inflate most and a 24-core box least,
which is consistent with trampoline moving 2.67x while the standalone arms
moved 1.13–1.45x; that consistency is not a separation. The gap sits in what
the sandbox does to `pcall` and its callers and whatever else the machine
adds; the ladder places it between r3c and rung 4 and cannot place it more
finely.

**nqueens — faster in the machine than anywhere standalone: reproduced at
the min, on a cell that spreads 2.38x.** JIT on, in-machine **0.6765**
against r1 1.0410, r2 1.0610, r3u 1.0700, r3 1.0590, r3c 1.0650: **0.650x**
plain LuaJIT and 0.632–0.639x every standalone arm of our own build. On
09-22 it was 0.716x and 0.76–0.80x. JIT off it is an ordinary loop again —
1.0884, **1.245x** r3cj and 1.260x r1j, inside the interpreted pure-loop band
(mandelbrot 1.097/1.099, sha256 1.267/1.260, matmul 1.198/1.251). So the
sandbox does not make nqueens's interpreted work cheaper; the compiled code
is what differs. Standalone, the compiler makes nqueens **slower** than the
interpreter on every rung (r1/r1j 1.205; r3c/r3cj 1.219; `traces_ever=118`
on r3u, r3 and r3c, the most of any benchmark); in the machine it makes it
**1.61x faster**.

The qualification is the cell. The in-machine nqueens cell runs 0.6765–1.6082
(spread 2.38x; 1.09x on 09-22), so at least one of the five repetitions ran
1.5x slower than plain LuaJIT while the fastest ran 0.65x of it. Which
repetition was slow — the first, compiling its traces inside the timed
window; one interrupted by a JVM pause; one sampled by the harness's poller —
is not recorded: the PHASE1 ROW carries min and max only. The min is the
compared statistic here as everywhere, and on the min the 09-04 sign
reversal reproduces for the second time on a second box; but this is the one
in-machine row where the max tells the opposite story from the min.

What the data separates: rungs 2, 3u, 3 and 3c all reproduce the standalone
slowness (1.017–1.028 of r1, cells overlapping — the standalone arms agree
with each other to within 3%), so the build flags, the allocator, the
accounting and the cap are not where the change happens; it happens between
r3c and rung 4. What it cannot separate, named without ranking:

- OC's replaced builtins and OpenOS's patched globals — the benchmark's call
  targets differ inside the sandbox, and a trace-heavy program (118 traces
  in the host) can end up with a different trace tree;
- the trace cache the benchmarks ran in. After boot the seven-benchmark
  machine held 371 traces (192 KB of mcode); after the suite the `JIT MEMORY`
  read found **30 traces, 43 live, 131 072 B**, with the shim's
  `trace_flushes` counter still at 0 — so something between the two reads
  emptied the cache without going through the pressure flush, and the seven
  benchmarks compiled into an empty cache (the watchdog's timeout probe, k1,
  runs in that window and is a candidate; the sieve boot, which ran the same
  probe, went from 370 to 485 traces). On 09-22 the same read found 371
  traces after the suite. Whether an emptied cache changes what the compiler
  makes of nqueens is not tested here; no per-benchmark trace or abort count
  exists in these logs (the `JIT PROBE` counts only around boot and its own
  loop: `traces start/stop/abort = 249/126/123` in the seven-benchmark boot,
  `284/152/132` in the sieve boot);
- the watchdog's arm/disarm on every resume;
- `os.clock` — wall time in both rungs (the C `clock()` standalone,
  `machine.cpuTime` in the machine: "Two clocks"), so it charges descheduled
  time in both; it cannot make a program read faster in the machine unless
  the standalone runs were descheduled more, and on this box, at 1–13% load
  with cells spreading 1.01–1.03x on nqueens, they were not;
- the JVM thread and its scheduling;
- position in the boot: nqueens ran sixth of seven in its machine, with
  459 KB free after it (286 KB on 09-22; `arms=0` for that whole boot, so no
  emergency cycle ran).

A rung between r3c and the machine — the bare host running `machine.lua`'s
sandbox over the same driver, with no OpenOS and no JVM — is the measurement
that would split this list, and it does not exist yet.

**2026-10-02 evening:** the standalone half of this — the compiler making
nqueens slower than the interpreter — is the stale-trace mechanism of the
in-game column, on our build and on upstream alike
([nqueens: the same mechanism](#nqueens-the-same-mechanism)). The in-machine
half is not explained by it; pinned to the performance cores the in-machine
min is lower still (0.5639, on a cell spreading 1.93x; the
[addendum](#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores)).

The game itself reads lower than this harness on all three benchmarks it ran:
mandelbrot, matmul and binarytrees at 0.839, 0.641 and 0.782 of rung 4's
mins (see [The in-game column](#the-in-game-column-t7-2026-10-02)).

### 6. JIT against interpreter, inside and outside

The compiler's speedup, interpreted time / compiled time, from the mins
(09-22 in brackets):

| benchmark | plain LuaJIT (r1j/r1) | host, capped (r3cj/r3c) | **in the machine** (off/on) |
|---|---:|---:|---:|
| sha256 | 16.15 [22.60] | 16.06 [24.77] | **14.60** [24.88] |
| mandelbrot | 5.78 [5.91] | 5.80 [5.75] | **5.54** [5.57] |
| matmul | 7.31 [5.59] | 6.23 [4.89] | **4.55** [4.67] |
| sieve | 6.98 [7.63] | 3.35 [3.81] | **3.49** [4.70] |
| strings2 | 1.96 [2.25] | 1.64 [1.79] | **2.02** [1.98] |
| binarytrees | 1.30 [1.21] | 1.20 [1.30] | **1.23** [0.93] |
| trampoline | 5.00 [6.44] | 5.13 [5.50] | **1.30** [1.003] |
| nqueens | 0.830 [0.674] | 0.821 [0.670] | **1.61** [1.54] |

The compiler's leverage itself moved with the box — sha256's fell from 22.6x
to 16.2x on plain LuaJIT because its interpreter gained 1.52x from the new CPU
and its compiled kernel only 1.08x; matmul's rose from 5.6x to 7.3x for the
opposite reason. Within one box, where the work stays inside the VM (sha256,
mandelbrot, matmul) the machine gives the compiler leverage of 0.62–0.96x
plain LuaJIT's: sha256 14.60 against 16.15 (0.90), mandelbrot 5.54 against
5.78 (0.96), and matmul 4.55 against 7.31 (0.62 — on 09-22 this was 0.84;
the drop is section 5's matmul, whose compiled run carries a residual its
interpreted run does not). sieve's leverage halves in the host (6.98 to 3.35,
the allocator rung) and stays there in the machine (3.49). strings2 and
binarytrees keep the compiler's small contribution in the machine (2.02 and
1.23; on 09-22 binarytrees had lost it, 0.93). trampoline keeps a quarter of
it (1.30 against 5.0–5.1 outside; on 09-22 none, 1.003), and nqueens gains a
1.61x it never had outside (0.82–0.83). The boot-time probe's own loop reads
0.0033 s compiled against 0.0113 s interpreted in the seven-benchmark boots
(3.4x), 0.0059 against 0.0125 in the sieve boots (2.1x).

Against the Phase 1 clean experiment (B/C, 2026-09-04: sha256 22.64x,
mandelbrot 5.71x, matmul 4.67x, strings2 1.96x, binarytrees 1.10x, trampoline
1.04x) today's in-machine column reads 14.60, 5.54, 4.55, 2.02, 1.23, 1.30:
the same ordering on the first four, with sha256's leverage lower for the
reason above, and the last two swapped — Phase 1 had binarytrees (1.10) above
trampoline (1.04), today trampoline (1.30) is above binarytrees (1.23) —
trampoline's being the one row whose picture changed.

**2026-10-02 evening: nqueens' 0.830 and 0.821 are the stale-trace
mechanism.** The benchmark makes a new closure of `solve` in each of its six
reps. Standalone, its first rep compiled runs about 2.4x faster than
interpreted, and from the third rep on each rep runs 1.55–1.66x slower than
interpreted, in the trace state the earlier reps' closures left behind. With one
`solve` for all six reps the compiler's leverage on nqueens is 2.4–2.5x on
our build (0.349–0.360 s compiled against 0.866–0.868 s interpreted), and
upstream's compiled run reads the same 0.347–0.351 s
([nqueens: the same mechanism](#nqueens-the-same-mechanism)). The machine
column's 1.61 is not explained by this.

## The in-game column (T7, 2026-10-02)

One run in the real game on this box, three days after the rungs above: the
computer in the OC experiment world, at the OpenOS shell, ran
`./ingame-ladder.lua` (T7 in [docs/in-game-tests.md](../docs/in-game-tests.md)). Transcribed from a
screenshot of its screen:

```
OpenOS 1.8.9 (16384k RAM)
/home # ./ingame-ladder.lua
machine RAM total=16384 KB free=16146 KB  jit global=false
mandelbrot   CHECK=37904620  min=0.0626 s  reps: 0.063 0.063 0.063 0.063 0.063
matmul       CHECK=481.0000  min=0.1031 s  reps: 0.105 0.109 0.103 0.103 0.106
binarytrees  CHECK=7038400  min=0.5586 s  reps: 0.559 0.717 0.941 0.898 0.921
```

All three CHECKs equal the references and every standalone and harness arm
above. **2026-10-03:** T8 re-ran the three files in the same world on the
arena DLL `88b50796…` with the per-rep runner — mandelbrot 0.0637, matmul
0.0946, binarytrees 0.4202 s (0.980 / 1.183 / 2.189x r1), binarytrees' reps
flat at 0.420–0.432 s
([results-allocator-2026-10-02.md](results-allocator-2026-10-02.md#in-game-t8-2026-10-03),
"In game (T8, 2026-10-03)"); the column below stays T7's, measured on the
pre-arena DLL `bcf8715c…` with the load-once runner.

### What ran

- **The same native; the kernel differs by one line.** The mod jar,
  `ocluajit-f32897a-master+f32897a824-dirty.jar` (780 500 B, built on this
  box on 2026-09-29), carries the Windows DLL `bcf8715c…` (830 108 B),
  byte-identical to the one rung 4 ran, and the kernel `machine.lua`
  `089dcbde…` (51 952 B), which is `build/native/kernel/machine.lua`, patched
  from GTNH OC's `machine.lua`. The harness's kernel (`3a1858e9…`,
  53 561 B, CRLF, patched from ocelot-brain's) differs from it by exactly one
  line once line endings are ignored: GTNH's `realTime = computer.realTime,`
  in the sandbox's `computer` table, present in the game and absent in the
  harness. None of the three benchmarks touches `computer`.
- **A different OpenComputers, the same clock.** The game runs
  `OpenComputers-1.12.64-GTNH.jar`; the harness runs ocelot-brain 0.24.2,
  which is based on OC 1.8.9a. Both boot OpenOS 1.8.9. GTNH OC's `os.clock` is the
  machine's `cpuTime`, as ocelot-brain's is (the strings `clock` in
  `li/cil/oc/server/machine/luac/OSAPI.class`, `cpuTime` in
  `OSAPI$$anonfun$initialize$1.class`, `nanoTime` in
  `li/cil/oc/server/machine/Machine.class`): sub-millisecond wall time within
  a resume, the instrument rung 4 used ("Two clocks" in the caveats). The
  benchmarks do not yield, so each timed kernel lies inside one resume.
- **Java 8 in both, configured differently.** The game runs Temurin JRE
  8.0.492 (`javaw.exe`, 1.8.0_492) with a 6000–8000 MB heap and the
  instance's JVM arguments, among them `-XX:+UseConcMarkSweepGC`,
  `-XX:+UseParNewGC`, `-XX:ParallelGCThreads=2`, `-XX:MaxGCPauseMillis=10`,
  `-XX:NewSize=84m` and `-Docluajit.forin=warn`. The harness ran Temurin JDK
  8.0.504 with default flags.
- **A 16 MB machine.** GTNH's `config/OpenComputers.cfg` sets
  `ramScaleFor64Bit=1.8` and `ramSizes=[256,512,1024,2048,4096,8192]` KB, so
  the 16 384 KB machine has its cap at about 16 384 KB x 1.8 = 29 491 KB
  (28.8 MB) plus `kernelMemory`, which the game does not show. The harness
  machine is the 1024 KB tier at ramScale 3.0 (`totalMemory` 3 480 561 B in
  the seven-benchmark boot). The cap did not bind in the harness's
  benchmarks (0 arms) and cannot have in the game, where no arm count was
  read: the shim's emergency collector arms only when headroom falls below a
  quarter of the cap (`total / 4` in `lj52_gc_pressure`), which in the game
  means past about 22 MB of accounted use; the machine reported 16 146 of its
  16 384 KB free before the first benchmark, and the standalone VM's whole
  heap after every binarytrees rep was 131–329 KB (the shared-VM runs below).
  In the harness the collector armed 0 times through the seven benchmarks
  (MEM-2, later in the same boot, arms it by design: 14 881).
- **Minecraft in a world.** The world is visible behind the computer's screen
  in the screenshot. Sampled after the run, idle in the same world, `javaw`
  used 2.33 CPU-seconds in 5 s of wall time, about 47% of one core. The Core
  Ultra 9 285HX is a hybrid part: 8 performance and 16 efficient cores, no
  SMT. The 09-29 standalone and harness chains were launched hidden
  (PowerShell `Start-Process -WindowStyle Hidden` → bash → java or luajit);
  the game was the foreground window.
- **The runner's shape.** `bench/oc/ingame-ladder.lua` as committed at
  `91a25f2`: `loadfile` once per benchmark, the chunk called five times,
  `os.sleep(0)` between calls, each time the benchmark's own `os.clock`. The
  harness suite re-loads the cached source for every rep
  (`test/native/OcljSmoke.scala:2494`, `load(src, "=" .. name)`, one rep per
  0.05 s timer), and each standalone process runs one rep. For mandelbrot and
  matmul, which define no functions, the difference shows nothing (the
  controls below); for binarytrees it is the leading account of reps 2–5 (the
  per-rep runner has not run in the game), and only the first call compares
  with the other arms.
- **`jit global=false`** prints `rawget(_G, "jit") ~= nil`: the sandbox
  exposes no `jit` table, by design. It is not the compiler's state. The
  compiler was on: mandelbrot at 0.0626 s is compiled speed (interpreted it
  reads 0.3760 on r1j and 0.4134 in the machine with the compiler off).

### The numbers

Min of 5, seconds; the other arms from the tables above. binarytrees' min is
its first rep.

| benchmark | in-game | r1 plain | r3c cap 3.46 MB | rung 4 machine | in-game/r1 | in-game/r3c | in-game/rung 4 |
|---|---:|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.0626 | 0.0650 | 0.0650 | 0.0746 | 0.963 | 0.963 | 0.839 |
| matmul | 0.1031 | 0.0800 | 0.0980 | 0.1608 | 1.289 | 1.052 | 0.641 |
| binarytrees | 0.5586 | 0.1920 | 0.4060 | 0.7146 | 2.909 | 1.376 | 0.782 |

Where the runner's shape lets the in-game reps be read as a cell, the cell is
tight: mandelbrot printed 0.063 five times and matmul 0.103–0.109 (1.06x),
against rung 4's 1.80x and 1.22x. binarytrees' five reps are not one cell
(below).

### The reading

**The pure loop shows no cost in the game.** mandelbrot runs 0.963x plain
LuaJIT and the capped host. Every r1 and r3c process read 0.0650–0.0670 on a
clock with 1 ms steps, and a 0.0650 reading means 0.0640–0.0660, so the
game's 0.0626 is 2.2–5.2% faster than the fastest standalone process however
the steps fell. That is not explained. The 09-29 standalone chains were
launched hidden like the harness, so the first candidate below applies to
them too; nothing here tests it. Those arms read within 2–5% of the game
where the harness read 1.19x it (0.0746/0.0626), so placement explains the
harness's excess only if the JVM's machine thread was placed differently
from a hidden `luajit.exe`. Whatever makes the game faster here may sit in
every in-game/r3c ratio below as well, unseparated from the machine's own
cost.

**matmul pays 1.052x the capped host** and 1.289x plain LuaJIT; on the 1 ms
clock r3c's 0.0980 is 0.0970–0.0990, so 1.04–1.06x, and the in-game min sits
0.1–2.1% above r3c's slowest process (0.1020).

**binarytrees pays 1.376x the capped host as tabulated** and 2.909x plain
LuaJIT. r3c's cell is five cold processes, one rep each. The shared-VM runs
below show the same host (at the 64 MB cap, whose value section 4 found
immaterial) running its fresh loads after the first at 0.339–0.375 s (one
0.407), and against those the game's first call reads about 1.49–1.65x
(1.37x against the 0.407) — if the host's first-run step is allocator
warm-up the machine's boot had already paid, which nothing separates (the
side result below). Those reps come from the `t7reps` driver, not the
ladder's, so that figure is approximate.

**Where the cumulative ratios come from**, rung by rung; the factors multiply
to in-game/r1:

| rung | binarytrees | matmul |
|---|---:|---:|
| r2/r1 — flags and patches | 0.990 | 1.025 |
| r3u/r2 — the C library's allocator | **1.916** | **1.146** |
| r3/r3u — the accounting | 1.124 | 1.032 |
| r3c/r3 — the cap, across the two sweeps | 0.993 | 1.010 |
| in-game/r3c — sandbox, OpenOS, JNI, JVM, the game, launch and placement (not separated) | 1.376 | 1.052 |
| **in-game/r1** | **2.909** | **1.289** |

r3c/r3 is taken here across the sweeps (r3c of the cap sweep over r3 of the
interleaved one) so that the column telescopes; within the cap sweep it is
1.002 and 1.000 (section 4). The allocator rung is the largest on both, 61%
of binarytrees' log-ratio and 54% of matmul's; the in-game rung is the
second, 30% and 20%, and it holds the machine's layers together with
whatever made mandelbrot read faster in the game than standalone, which no
arm separates.

**The game against the harness: faster on all three.** In-game/rung 4 reads
0.839, 0.641 and 0.782, so the residual section 5 measured between r3c and
rung 4 — 1.148, 1.641 and 1.760 — is 0.963, 1.052 and 1.376 in the game. On
this box, in this game session against this harness boot, the harness's
rung 4 overstates what a player paid: the cells do not overlap (binarytrees'
one comparable rep sits below rung 4's min), and whether that reproduces
across boots is untested. Candidates for the harness's extra cost, none
separated by any arm run here:

- core placement on a hybrid CPU: the harness JVM ran as a hidden background
  process and the game as the foreground window, on 8 performance and 16
  efficient cores;
- the JVM's flags and collector — ParNew/CMS with a 10 ms pause goal and two
  GC threads in the game, JDK 8's defaults in the harness — and the two JDK 8
  builds;
- the harness's own poller, which wakes every 25 ms beside the machine;
- ocelot-brain 0.24.2 (OC 1.8.9a) against OpenComputers 1.12.64-GTNH: two
  implementations of the machine, its executor and its scheduling;
- the three days between the two runs: the 10-02 `t7reps` controls on the
  bare host read mandelbrot 0.0650–0.0670, as on 09-29, and matmul
  0.0950–0.1000 (09-29 r3 0.0970–0.0990), so the standalone side moved by
  about 2% at most; no rung-4 run was repeated on 10-02.

The kernel's one differing line and the RAM size are not on the list: the
benchmarks never touch `computer`, and the cap bound in neither. The test
that would separate the first candidate is the harness run again with its
JVM pinned to the performance cores, or as a foreground process: if rung 4
falls to the game's numbers, placement was it, and the standalone arms,
launched the same way, would want the same re-run. **2026-10-02 evening:**
that run was made, and pinned to the performance cores rung 4 fell to the
game's numbers (mandelbrot 0.0661, matmul 0.1049, binarytrees 0.5168), so
core placement is confirmed as the main factor, while the standalone arms,
which ran at performance-core speed unpinned (tested on r1, three
benchmarks), did not need the re-run
([Addendum 2026-10-02 evening](#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores)).

### binarytrees' reps: the runner's shape, by the standalone reproduction

The in-game reps climb 0.559 → 0.717 → 0.941, 0.898, 0.921: 1.28x the first
at the second call and 1.61–1.68x at the third to fifth. That is the shape
one loaded chunk called repeatedly produces standalone, on all three builds
run (r1 upstream, r2, r3); the in-game run with the per-rep runner, which
would test this there, has not been made (**2026-10-03:** made, as T8, on
the arena DLL `88b50796…`: reps 0.420, 0.424, 0.432, 0.428, 0.426 s, flat —
consistent with this, though the DLL changed as well;
[results-allocator-2026-10-02.md](results-allocator-2026-10-02.md#in-game-t8-2026-10-03)).
The shared-VM runs (`t7reps`,
2026-10-02, 15:32–15:35, with Minecraft open in-world in the background):
`reps.lua` runs one benchmark for N reps in one process under the driver's
sandbox denials except `arg`, either calling one loaded chunk every rep
(`same`, the in-game runner's shape) or loading the file again for each
(`fresh`, the harness's shape), with or without two full collections before
each rep; per rep it prints the benchmark's own time, the trace start, stop
and abort events during the rep (a non-allocating `jit.attach` callback) and
the heap after it. Arms: r2, our `luajit.exe` `cae31580…` (`lj_alloc`, the
penalty scrub); r3, the bare host `cc6e8509…` (the C library's allocator, the
accounting at 64 MB); r1, pristine upstream `98e24588…`
(`LuaJIT 2.1.1787165859`), on `same` only in the timing runs (it ran `fresh`
once, five reps, for the exit counts below, and stayed flat there:
0.199–0.205 s with the exit handler attached); not timed fresh because an
unscrubbed build may hit the penalty-cache defect (T5). binarytrees, eight
reps, seconds, ranges over the processes:

| arm | shape | processes | rep 1 | rep 2 | rep 3 | reps 4–8 |
|---|---|---|---:|---:|---:|---:|
| r2 | same | 4, 2 with collections | 0.198–0.202 | 0.292–0.302 | 0.378–0.400 | 0.370–0.397 |
| r1 upstream | same | 2, none with | 0.199–0.200 | 0.300–0.311 | 0.397–0.406 | 0.391–0.401 |
| r3 | same | 4, 2 with collections | 0.419–0.440 | 0.522–0.559 | 0.657–0.667 | 0.656–0.673 (reps 4–5), 0.827–1.041 (reps 6–8) |
| r2 | fresh | 4, 2 with collections | 0.194–0.201 | 0.197–0.205 | 0.197–0.203 | 0.193–0.210 |
| r3 | fresh | 4, 2 with collections | 0.420–0.433 | 0.357–0.407 | 0.339–0.359 | 0.342–0.375 |

The collections do not change the shape. Within each process the `same` reps
step up by 1.45–1.56x at the second call and 1.84–2.04x from the third on r2
and r1, and by 1.21–1.33x and 1.50–1.61x (reps 3–5) on r3; the game's 1.28x
and 1.61–1.68x sit nearer r3's, the arm on the game's allocator. The trace
events tell the same story in every `same` process: rep 1 compiles from cold,
reps 2 and 3 each compile another 19–27 traces with no aborts but one (in
one r3 rep 2), and reps 4–7 record nothing (rep 8 shows 1–2 starts, mostly
aborted, in every `same` cell and both controls alike, most likely the
driver's own loops warming). Every `fresh` rep compiles anew (34–100 traces;
33–86 in the `texit` runs).
The heap after every rep of every cell is 131–329 KB: no growth.

Controls, r3, `same`, one process each: mandelbrot 0.0650–0.0670 and matmul
0.0950–0.1000 over all eight reps, flat as in the game. Neither defines a
function.

Exit counts per rep, from separate five-rep runs with a `texit` handler
attached (`reps-texit.lua`; the handler slows every exit, so only the counts
are read):

| arm | shape | rep 1 | rep 2 | rep 3 | rep 4 | rep 5 |
|---|---|---:|---:|---:|---:|---:|
| r2 | same | 4032 | 5373 | 6673 | 6401 | 6401 |
| r2 | fresh | 4418 | 4062 | 4297 | 4125 | 4246 |
| r1 | same | 4285 | 5552 | 6808 | 6534 | 6534 |
| r1 | fresh | 4568 | 3980 | 4296 | 3902 | 4339 |

The slow reps take about 2 200–2 600 more exits than the fast ones (reps
3–5 against the same arm's `fresh` reps or its own first rep). To account for
the 0.17–0.21 s they lose, each extra exit would have to cost 64–95 µs, and
at that price the 4032–4285 exits of each arm's first rep would alone take
0.26–0.41 s, more than the whole of that rep (0.198–0.202 s). So
the extra exits to the interpreter are not where the time goes, unless each
costs far more than one in rep 1. These counts see only those exits: `texit`
is sent from `lj_trace_exit` (`lj_trace.c:928`), and an exit with a side
trace attached is patched to jump straight into it (`lj_asm_patchexit`,
`lj_trace.c:531`), so how often the slow reps' guards fail into side traces
is not counted.

**The mechanism, tested against the closure count: the trace state earlier
calls leave behind.** The first candidate was LuaJIT's closure counter: each
prototype counts the closures made from it in a saturating 3-bit field of
its flags (`lj_func.c:133-135` upstream, `155-157` in our tree, where the
penalty scrub adds 22 lines above it; `PROTO_CLCOUNT 0x20` and
`PROTO_CLC_POLY = 3*PROTO_CLCOUNT`, "Polymorphic threshold", at
`lj_obj.h:409-411`; the field's top bit is also `PROTO_BITOP`, `0x80` at
`lj_obj.h:404`, which the parser sets on a function that uses bit operators
or encloses one that does, at `lj_parse.c:956`, `:1056` and `:2005`, and
keeps at `:1723`, so such a prototype starts past the threshold —
binarytrees uses none), and once a prototype has made three, the recorder
specialises a call to the prototype instead of the closure value
(`lj_record.c:802`, `rec_call_specialize`) and stops constifying immutable
upvalues (`lj_record.c:1795`, `rec_upvalue`); `lj_obj.h` and `lj_record.c`
are identical in the two trees. binarytrees' `make` and `nodes` are recursive
local functions that call themselves through their own upvalues, and each
call of the chunk creates new closures of both. But the second call already
paid 41–58% of each process's climb to the mean of its calls 3–5 (44% of
the game's, on the same window) with both functions still below the
threshold, and from the third call r1 and r2 ran slower than no compiled
code at all, so the count alone could not be it.
The separating test (`t7reps/run-3`, 2026-10-02 16:56–16:57, Minecraft
closed): one loaded chunk called eight times with `jit.flush()` before every
call. A flush (`jit.flush()` runs `lj_trace_flushall`, `lj_trace.c:276-303`)
drops every earlier trace, restoring the bytecode the root traces had
patched, frees their machine code and clears the penalty cache; it leaves
the hot counters (only switching the JIT on, `lj_dispatch.c:209-211`, or
setting `hotloop`, `lib_jit.c:504-505`, re-initialises them) and each
prototype's closure count (only `func_newL`, the parser and `lj_bcread.c:360`
write those bits), so calls 3–8 compile again from an empty trace cache
against prototypes past the threshold. binarytrees, seconds:

| arm | one loaded chunk, eight calls | call 1 | call 2 | calls 3–8 |
|---|---|---:|---:|---:|
| r2 | `jit.flush()` before each, 2 processes | 0.196 | 0.197–0.201 | 0.199–0.207 |
| r1 upstream | `jit.flush()` before each, 2 processes | 0.194–0.195 | 0.191–0.193 | 0.197–0.209 |
| r2 | no flush, same run | 0.191 | 0.299 | 0.383–0.388 |
| r2 | compiler off (`-joff`), 2 processes | 0.261–0.262 | 0.258–0.261 | 0.256–0.267 |
| r1 upstream | compiler off, 1 process | 0.261 | 0.259 | 0.258–0.266 |
| r3 | `jit.flush()` before each, 1 process | 0.409 | 0.348 | 0.339–0.353 |
| r3 | compiler off (`--joff`), 1 process | 0.500 | 0.442 | 0.428–0.589 |

Flushed, the climb is gone: on r1 and r2 every call runs within 8% of the
first, past the threshold or not (calls 3–8 at 1.01–1.08x call 1,
0.197–0.209 s against 0.191–0.201 s for calls 1–2), where unflushed calls
3–8 ran 1.84–2.04x the first. Past the threshold, code compiled from an
empty trace cache is not the 2x slow code, so the closure count does not
make it. It may cost a little: in each of the four flushed r1 and r2
processes calls 3–8 average 3.7–4.9% above call 1 and every one of them is
at or above both earlier calls; the same run's `-joff` arms show no such
shift (0.996–1.002x), but run-1's `fresh` r2 cells, compiled anew on every
call, come close on the same measure (1.003–1.029x) — a candidate for what
specialising to the prototype costs, not separated. The climb needs the
state the flush clears: the earlier calls' traces and their machine code,
and the penalty cache. The traces are the candidate — calls 4–7 record
nothing yet run slower than the interpreter, and a penalty can only keep
code interpreted — but no arm separates the two. The account, from the
recorder's source and the trace events, not measured: call 1's traces are
specialised to call 1's closures; calls 2 and 3 fail those guards and
record 19–27 traces each (most likely side traces off them; the callback
counted event names and did not record parents); every later call enters
call 1's traces through the patched bytecode and leaves them through the
same guards, into what calls 2 and 3 added or, about 2 200–2 400 times a
rep more than in a fast rep, back to the interpreter. By the same source
the counter is why recording stops after the third call — from the third
closure new traces specialise to the prototype, so later closures pass
them — which fits calls 4–7 recording nothing; no arm tested it. The stuck
state is slower than not compiling at all: 0.383–0.388 s against
0.256–0.267 s interpreted through the same driver in the same run,
1.43–1.52x. Which part of the trace tree costs the time — side-trace
transitions on every recursive call, or something else — is not measured
(no `-jdump`), and linked side exits are invisible to the exit counts above.
The flushed r3 run shows the host's first-run step and then its fresh-load
speed (below). r3's second step at rep 6 of the unflushed runs
(0.656–0.673 to 0.827–1.041 s, with no trace events and no heap growth),
which r1 and r2 do not show, is not explained (r3 with the compiler off
rose late too, 0.471 and 0.589 s at calls 7–8 against 0.428–0.430 at calls
3–6, one process, while the flushed r3 run stayed at 0.341–0.347 from
call 5); the in-game run stopped at rep 5.

**A side result: the host's first run.** On r3, the `fresh` reps after the
first ran 0.339–0.375 s (one 0.407) against 0.420–0.433 s for the first, a
step of 1.12–1.27x within each process, the 0.407 aside; r2 shows none
(0.193–0.210 throughout). The C library's allocator is the leading
candidate, since r2 runs on `lj_alloc`, but it is not separated from the
rest of what r3 adds. Every r3-family cell in this document is one rep per
process, so each binarytrees cell among them measures that first run (the
matmul control on r3 shows no comparable step: 0.0990 first, 0.0950–0.1000
after), while rung 4's min is over five fresh loads in one long-lived
machine: against the host's later reps, binarytrees' rung 4 would read about
1.9–2.1x the host rather than section 5's 1.760 (the same instrument caveat
as above).

**For players.** OpenOS's shell loads a program afresh on every run (T5), so
a program's own functions start as new prototypes with no traces on every
run, and re-running it from the shell does not hit this. By the account
above — measured on one program, binarytrees as a chunk loaded once and
called repeatedly — what can pay is a function re-created in one VM while
traces compiled for its earlier closures are still attached (one with no
bit-operator syntax, which would start its prototype past the threshold): a
local function defined inside a loop or inside a function called often
(`bench/oc/nqueens.lua:122` defines `solve` inside its six-rep loop, so every
run makes six closures of it; whether that is behind nqueens'
compiled-slower-than-interpreted reading outside the machine in section 6,
0.830 and 0.821, is untested and now a lead — one that must also explain the
machine column of the same table, where the same file, re-creating `solve`
the same way on every load, gains 1.61x from the compiler), a chunk loaded
once and called repeatedly, or a closure-making function in a library
`require`d once per boot, whose traces outlive every shell run. binarytrees,
which recurses through its upvalues, ran about 2x its first call from the
third call on, on `luajit.exe` and pristine upstream alike — slower than
with the compiler off by 1.43–1.52x on `luajit.exe` in the same run and
1.47–1.57x on upstream across two runs — so it is upstream behaviour and
nothing of ours to fix. A `jit.flush()` before each call kept every later
call at or below 1.08x the first. Until 2026-09-22 `persist()` flushed every
trace whenever it reached a thread parked inside a generic-for loop, as an
idle OpenOS essentially always is, so in practice at every save (Minecraft
autosaves every 45 s; the roadmap's "JIT x persist interaction" row); by
the account above, one flush after a prototype's third closure would end
the climb for it, since what recompiles afterwards specialises to the
prototype — untested, as this arm flushed before every call. Since that
flush was removed, such trees last until the machine's VM is replaced (a
reboot, or a reload that restores the machine into a new, cold VM) or
something flushes them: the memory-pressure flush, or LuaJIT itself when
its 1000 trace slots or its 2 MB machine-code reserve fill
(`lj_trace.c:447`, `:661`; the roadmap's `jit.opt` row). **2026-10-02
evening:** the nqueens lead is confirmed standalone — the same climb, on
our build and upstream alike, and one `solve` for all six reps makes the
benchmark 2.4–2.5x faster than the interpreter — while its machine column
stays unexplained ([nqueens: the same mechanism](#nqueens-the-same-mechanism)).

**The runner now loads per rep.** `bench/oc/ingame-ladder.lua` loads the
file again for every rep, as the harness suite does (changed 2026-10-02,
after this run; its header says why). The copy on the experiment world's
disk is still the load-once version; a re-run should copy the new file first
and expect binarytrees' reps not to climb; on the C-allocator host the fresh
reps after the first ran up to 1.27x faster than the first (the side result
above), so they may step down instead. **2026-10-03:** T8 ran the new copy,
on the arena DLL `88b50796…`: binarytrees' reps 0.420–0.432 s, the first
of them the min — flat, no step down, as on `lj_alloc` standalone (r2
`fresh`, above;
[results-allocator-2026-10-02.md](results-allocator-2026-10-02.md#in-game-t8-2026-10-03)).

### nqueens: the same mechanism

Added on the evening of 2026-10-02. `bench/oc/nqueens.lua` defines `local
function solve` inside its six-rep loop: every rep makes a new
closure over new tables (`cols`, `d1`, `d2`, `count`) that recurses through
its own upvalue — the shape the account above names. Three scratch variants
of the file, each also returning its per-rep times, loaded and called once
per process the way the harness loads a benchmark (`nqlead/run.lua`): the
benchmark as it is (`nq-orig.lua`); the same with `jit.flush()` at the top
of every rep, inside the timed region (`nq-flush.lua`); and one `solve` for
all six reps with its state reset by assignment, so that its upvalues are
now reassigned every rep — a second difference, stated in the file
(`nq-hoist.lua`). Three fresh processes per cell, CHECK `85200` in all 24
runs, Minecraft closed (`nqlead/run-1/run.log`, 21:26–21:27). Seconds,
ranges over the processes:

| variant | arm | total | rep 1 | rep 2 | reps 3–6 |
|---|---|---:|---:|---:|---:|
| as in the benchmark | r2 | 1.056–1.058 | 0.057–0.060 | 0.087–0.089 | 0.227–0.229 |
| as in the benchmark | r1 upstream | 1.055–1.091 | 0.058–0.060 | 0.088–0.089 | 0.226–0.237 |
| `jit.flush()` before each rep | r2 | 0.427–0.429 | 0.058–0.059 | 0.059–0.060 | 0.076–0.078 |
| `jit.flush()` before each rep | r1 upstream | 0.430–0.435 | 0.059 | 0.057–0.058 | 0.077–0.082 |
| one `solve` for all reps | r2 | 0.349–0.360 | 0.059–0.066 | 0.057–0.061 | 0.057–0.059 |
| one `solve` for all reps | r1 upstream | 0.347–0.351 | 0.058–0.059 | 0.059 | 0.056–0.059 |
| as in the benchmark, `-joff` | r2 | 0.865–0.871 | 0.144–0.145 | 0.144–0.146 | 0.143–0.146 |
| one `solve`, `-joff` | r2 | 0.866–0.868 | 0.144–0.145 | 0.144 | 0.143–0.146 |

The climb is binarytrees': compiled, rep 1 runs about 2.4x faster than
interpreted (0.057–0.060 s against 0.143–0.146 s), rep 2 about 1.5x rep 1,
and from rep 3 every rep runs 3.8–4.0x rep 1 — 1.55–1.66x slower than the
interpreter — on our build and on pristine upstream alike, so it is upstream
behaviour. A `jit.flush()` before each rep takes the benchmark from
1.055–1.091 s to 0.427–0.435 s, and one closure for all six reps to
0.347–0.360 s, 2.4–2.5x faster than the same variant interpreted
(0.866–0.868 s). That is section 6's "the compiler makes nqueens slower"
(0.830 on plain LuaJIT, 0.821 in the capped host, a cause the benchmark's
own header recorded as not known until this run): not the compiler's work on
the search itself, but the trace state each rep leaves behind for the next
rep's new closure — the traces the candidate, as for binarytrees, since the
flush also clears the penalty cache and no arm here separates the two.

Unlike binarytrees', the flushed reps 3–6 still run about 1.3x rep 1
(0.076–0.082 s against 0.058–0.059 s, 1.31–1.39x within each process), and
the step comes exactly at the third closure, where the prototype passes
`PROTO_CLC_POLY` and the recorder starts specialising calls to the prototype. The closure count is the
candidate for this 1.3x; no arm separates it from whatever else changes at
the third rep. (The hoisted variant, whose upvalues are reassigned every rep
and so cannot be trace constants, runs every rep at rep-1 speed.) Against
the whole climb's 3.8–4.0x over rep 1 it is the small part; what the flush
removes is 2.8–3.1x (reps 3–6 0.226–0.237 s unflushed against 0.076–0.082 s
flushed).

**What this does not explain is the machine column.** In the machine the
same file reads faster than anywhere standalone (section 5). The six
seven-benchmark runs of 10-02 at tier `threehalf` launched pinned to the
performance cores — the P arm of the addendum below, and the baseline, the
two arena runs and both gate runs of
[results-allocator-2026-10-02.md](results-allocator-2026-10-02.md), the gate
runs with no affinity read back — read mins of 0.4339–0.5639 s and maxes of
1.0871–1.1402 s: every min between the flushed variant's total
(0.427–0.435 s) and the benchmark's own (1.055–1.091 s), every max at or
just above the latter. That is the shape that some loads running with a
flush somewhere among their reps, and others without, would give. The first
gate run's small-tier boots (placement not read back) read 0.5554/1.0995 at
tier one and 0.5458/1.1092 at onehalf on the arena, and 1.0890/1.1207 at
tier one on the pre-arena DLL: that run never read faster than standalone.
The candidate is LuaJIT's own self-flush — at 1000 traces or a full 2 MB
machine-code reserve — landing mid-run in a machine
that already holds the boot's traces (section 5 records the cache emptied
during the 09-29 suite with the shim's `trace_flushes` still 0); untested.

## Addendum 2026-10-02 evening: the harness was on the efficient cores

The in-game column ended on a test: run the harness with its JVM pinned to
the performance cores, and if rung 4 falls to the game's numbers, placement
was it. It was run on 2026-10-02, 21:30–21:35, with Minecraft closed (0
java processes at the start), together with standalone controls.

**How.** The topology, read with `GetSystemCpuSetInformation`
(`pcore/cpusets.exe`): EfficiencyClass 1, the 8 performance cores, is
logical processors 0, 1, 10–13, 22 and 23 (mask `0xC03C03`);
EfficiencyClass 0, the 16 efficient cores, is 2–9 and 14–21 (`0x3FC3FC`).
`pcore/affrun.exe` creates its child suspended, sets the child's affinity
and resumes it; the chain under it (bash → sh → java) inherits the mask, and
25 s into every harness run the java process's own affinity was read back
and logged — `0xC03C03`, `0x3FC3FC` and `0xFFFFFF` (unpinned) in the three
runs. The harness is rung 4's: DLL `bcf8715c…`, the watchdog kernel,
Temurin JDK 8.0.504, tier `threehalf`, the seven non-quarantined benchmarks,
compiler on, `OCLJ_REPS=5`; one run per arm, serialised, all three PASS
56/0. The standalone control is r1, pristine `luajit.exe`, through the
ladder driver, five fresh processes per cell.

The harness, `PHASE1 ROW` min/max, seconds; the 09-29 column is this
document's rung 4:

| benchmark | P, `0xC03C03` | E, `0x3FC3FC` | unpinned, 10-02 | unpinned, 09-29 | in-game (T7) |
|---|---:|---:|---:|---:|---:|
| mandelbrot | 0.0661/0.0676 | 0.0830/0.0893 | 0.0889/0.1187 | 0.0746/0.1341 | 0.0626 |
| binarytrees | 0.5168/0.6081 | 0.8280/0.9930 | 0.7760/1.0700 | 0.7146/0.8649 | 0.5586 (rep 1) |
| trampoline | 0.2276/0.2346 | 0.2887/0.3616 | 0.2814/0.3586 | 0.2756/0.3406 | — |
| matmul | 0.1049/0.1202 | 0.1629/0.1979 | 0.1179/0.2374 | 0.1608/0.1963 | 0.1031 |
| strings2 | 0.2636/0.2761 | 0.2847/0.3659 | 0.3771/0.4384 | 0.3046/0.4236 | — |
| nqueens | 0.5639/1.0871 | 0.7376/1.4677 | 0.8272/1.7375 | 0.6765/1.6082 | — |
| sha256 | 0.0495/0.0536 | 0.0554/0.0870 | 0.0587/0.0643 | 0.0669/0.0939 | — |

Ratios of the mins to the P arm, and the P arm over the capped host r3c of
09-29 (section 5's rung 4/r3c in brackets):

| benchmark | E/P | unpinned 10-02/P | unpinned 09-29/P | in-game/P | P/r3c |
|---|---:|---:|---:|---:|---:|
| mandelbrot | 1.256 | 1.345 | 1.129 | 0.947 | 1.017 [1.148] |
| binarytrees | 1.602 | 1.502 | 1.383 | 1.081 | 1.273 [1.760] |
| trampoline | 1.268 | 1.236 | 1.211 | — | 28.5 [34.45] |
| matmul | 1.553 | 1.124 | 1.533 | 0.983 | 1.070 [1.641] |
| strings2 | 1.080 | 1.431 | 1.156 | — | 1.182 [1.366] |
| nqueens | 1.308 | 1.467 | 1.200 | — | 0.529 [0.635] |
| sha256 | 1.119 | 1.186 | 1.352 | — | 1.031 [1.394] |

Spreads (max/min): P 1.02–1.18x (nqueens 1.93x), E 1.08–1.57x (nqueens
1.99x), unpinned 10-02 1.10–2.01x (nqueens 2.10x).

The standalone control, r1, min–max seconds:

| benchmark | P | E | unpinned | E/P | unpinned/P |
|---|---:|---:|---:|---:|---:|
| mandelbrot | 0.0650–0.0660 | 0.0680–0.0700 | 0.0650 (all five) | 1.05 | 1.00 |
| matmul | 0.0800–0.0840 | 0.0890–0.0910 | 0.0810–0.0830 | 1.11 | 1.01 |
| binarytrees | 0.1950–0.2010 | 0.2130–0.2210 | 0.1880–0.1970 | 1.09 | 0.96 |

- **Pinned to the performance cores, the harness reproduces the game:**
  mandelbrot 0.0661 against the game's 0.0626, matmul 0.1049 against
  0.1031, binarytrees 0.5168 against the game's first rep, 0.5586 —
  in-game/P 0.947, 0.983 and 1.081, where against the unpinned rung 4 of
  09-29 they were 0.839, 0.641 and 0.782 — on cells of 1.02–1.18x. Unpinned,
  its mins sit with the efficient-core arm's (1.12–1.50x the P arm, against
  the E arm's 1.08–1.60x), and its cells include the widest of the three
  (matmul 2.01x, nqueens 2.10x).
- **Standalone processes do not need the pin.** Unpinned, r1 ran at
  performance-core speed (0.96–1.01x the P arm; 1.05–1.11x on the efficient
  cores), and 09-29's r1 mins (0.0650, 0.0800, 0.1920) match the P arm's
  (0.0650, 0.0800, 0.1950) to within 2%. So
  the hidden standalone processes of 09-29 ran at performance-core speed and
  the hidden harness JVM did not — the condition "The reading" of the
  in-game column set for placement to explain the harness's excess.
- **The account these arms support**, without a per-thread record of where
  the machine thread ran: the harness's machine thread, in a hidden
  background JVM, lands on efficient cores, migrates between the two kinds,
  or both; the game, the foreground window, and short CPU-bound standalone
  processes get performance cores.
- **The JVM-hosted machine is far more sensitive to the kind of core than
  standalone LuaJIT**: E/P 1.26x on mandelbrot, 1.55x on matmul and 1.60x on
  binarytrees in the harness, against 1.05–1.11x standalone. Not explained.
- **The in-game column's list of candidates resolves to placement as the
  main factor.** The JVM's flags and collector, the harness's poller and
  ocelot-brain against GTNH OC were not tested separately, and are not
  needed to explain the gap. What stays open is mandelbrot: the game's
  0.0626 is still 2–5% faster than every standalone process, the P-pinned
  ones included (0.0650–0.0660), and that is still not explained.

**The consequence.** Every harness timing on this box must be pinned to the
performance cores, and none of this project's was before 21:30 on
2026-10-02: this document's rung-4 columns, compiler on and off, ran
unpinned on this box, and the 09-22 document's on the old box. On this box
the placement is in every rung-4 number above — section 5's residuals,
section 6's in-machine column, "The box change, in numbers" — and is a
candidate for the width of the in-machine cells ("What this does not say").
Pinned, the residual over the capped host is mandelbrot 1.017, sha256 1.031,
matmul 1.070, binarytrees 1.273, strings2 1.182 and trampoline 28.5, against
section 5's 1.148, 1.394, 1.641, 1.760, 1.366 and 34.45 (a 10-02 harness run
over 09-29's r3c; on these six benchmarks the standalone side moved about
3% at most in those three days — the same evening's r3 read matmul 0.0940
against 09-29's 0.0970 — and the P arm's standalone cells match 09-29's
r1). The interpreter column and sieve were not re-run pinned, and whether
placement mattered on 09-22's box was not tested. `smoke-test.sh` has no
pinning knob yet; `affrun` lives in the scratchpad.

## What this does not say

* **The box changed, and everything with it.** CPU (24C/24T against 8C/16T),
  memory, load (quiesced against 56–62%), compiler (GCC 16.2 against 15.2),
  JDK build (Temurin 8.0.504, pinned) and the native DLL build (`bcf8715c…`,
  built here on 2026-09-29, against 09-22's `4312750e…` pressure-flush build,
  whose `lj52shim.c`/eris source parity with today's is not established —
  `native/lj52shim.c` changed in `f32897a`, the commit that added the 09-22
  document, and which side of it `4312750e…` was built from is unrecorded)
  all changed between the two documents at once. Every ratio *within* this
  document is clean; every
  comparison *between* the documents — including the whole of "The box
  change, in numbers" and the attribution of 09-22's larger residual to its
  loaded host — is confounded by all of these together. The attribution is
  the reading the two documents support, not a measurement that isolates
  load: no arm ran the machine on this box under load or on the old box
  quiesced.
* **The in-machine cells are wider than the old box's, while the standalone
  cells are far tighter.** Standalone spreads are 1.01–1.10x (trampoline JIT
  on 1.12–1.29x, 7–9 ms at 1 ms resolution); in-machine they are 1.21–2.38x
  with the compiler on (nqueens 2.38x, sieve 1.96x, mandelbrot 1.80x) and
  1.16–1.35x with it off, against 1.04–1.54x on 09-22. So on this box the
  min of five estimates the typical standalone run well and the typical
  in-machine run poorly, and the rung-4 ratios inherit the in-machine
  spread. Candidates for the width, none separated: the first repetition
  compiling its traces inside its own timed window (the compiled cells are
  wider than the interpreted ones on six of the eight benchmarks; binarytrees,
  1.21x on against 1.24x off, and trampoline, 1.24x against 1.33x, are wider
  with the compiler off); the JVM's own compilation of ocelot-brain
  during a 100-second boot; the harness's reads of the machine's state, which
  do share the state with the executor — the harness itself logged `raw-state
  read on a dirty stack: getTop=2 (expected 1) -- something else is using
  this state` during the boot-time reads of three of the four boots (never
  inside a Phase 1 window); the emergency collector in the sieve boots. The
  PHASE1 ROW records min and max only, so the shape of each cell is unknown.
* **n = 5, min taken, one box, one OS, one hardware tier**, as before.
* **The k4 negative control failed in the sieve JIT-off boot, and the
  failure is the bound's.** `k4-still-compiled-after-timeout-NEGATIVE-CONTROL`
  asserts that with `jit.off()` the sandbox loop after the timeout takes at
  least 0.010 s; it took 0.0097 s. The bound is absolute and was calibrated
  on the old box; this box's interpreter runs the same 2 M-iteration loop in
  0.0097–0.0150 s across the two JIT-off boots (k3 read 0.0113 and 0.0125,
  k4 0.0150 and 0.0097), straddling it. The probe runs before Phase 0; the
  sieve PHASE1 ROW of that boot (0.6387, CHECK `4626000`) is unaffected and
  is used. That harness run's verdict is FAIL (48/1) for this reason alone.
  The bound was replaced the same day, after these runs: k3/k4 now judge the
  sandbox loop against the same loop run interpreted in the raw state of the
  same run, on a loop the compiler speeds up ~10x rather than ~3x, and the
  same arm re-run on the new instrument passes 48/0 (the 2026-09-29 addendum
  in [docs/research/hook-vs-jit.md](../docs/research/hook-vs-jit.md)). The
  numbers in this document are from the runs before that change; the probe
  they came from is not one of the benchmarks.
* **The teardown crash of 09-22 is gone.** 0 of the 480 standalone processes
  exited abnormally (09-22: 13 of 80 r3/r3j processes exited 139 in the
  interleaved sweep, after their `TIME` line). The host is the `host_close`
  fix of 09-22 (`fixed-2/`, then `126171d5…`) recompiled with GCC 16.2 as
  `cc6e8509…`; both sweeps ran on it, so this document has no two-host
  caveat.
* **Two cap points only**, 64 MB and 3 457 941 bytes, and neither bound
  (`arms=0` in all 160 rows). The cost of the cap when it does bind is not in
  this document except as the in-machine sieve's 800/664 arms — which today
  coincide with sieve running *faster* than the host, a point that a host arm
  with a binding cap would test and that no arm here does.
* **The accounting rung has plain C accessors.** r3/r3u bounds the shim's
  bookkeeping, now as a number (1.12–1.14x on binarytrees, at most 3–4 ns per
  accounted call, a mixture with whatever else moves with the arm — two
  resolved pairs have the accounting arm faster, section 3); jnlua's JNI
  field get and set on every allocation — the thing the roadmap row is about
  — is inside rung 4's residual and is not isolated by any rung here. The row
  is not closed.
* **Four arms would settle the attributions this document hedges, and none
  exists:** the bare host on `lj_alloc` with accounting off, to isolate the
  allocator from the rest of what r3u adds (section 2); a host built on
  jnlua's real JNI accessors under a JVM, to measure the roadmap row's named
  cost (section 3); an in-machine accounted-allocation count for trampoline,
  to test the JNI-per-allocation explanation inside the sandbox (section 5);
  and, new, the host with a cap small enough that sieve arms the emergency
  collector 160 times per run, to test whether the collections are what make
  the in-machine sieve faster than the host (sections 4 and 5).
  **2026-10-02:** the first of these was run
  ([results-allocator-2026-10-02.md](results-allocator-2026-10-02.md)), and
  on it the allocator is the rung: r3u over the host on `lj_alloc` reads
  sieve 2.647, binarytrees 1.785, strings2 1.177 and matmul 1.157. The r3u
  and r3 rows in this document were measured on the pre-arena shim object
  `8ef84b32…`. The other three arms still do not exist.
* **One boot per JIT mode for seven benchmarks.** `arms=0` through the seven
  benchmarks in both boots (MEM-2, later in the JIT-on boot, arms it by
  design: 14 881; the JIT-off boot skips MEM-2), so the emergency collector
  never ran during them, but the benchmarks still ran in a fixed order in a
  shared heap (free after each, JIT on: 739, 595, 764, 751, 637, 459,
  796 KB; JIT off: 983, 874, 919, 957, 746, 930, 994 KB) and, in the JIT-on
  boot, in a trace cache that had
  been emptied after boot (371 traces after boot, 30 after the suite,
  `trace_flushes=0`; 09-22 read 371 after the suite). sieve ran in its own
  machine and its boots reported different `kernelMemory` (340 193 and
  368 173 against 334 833 and 414 553), so its `totalMemory` was 3 485 921
  and 3 513 901 against r3c's 3 457 941 — 27 980 and 55 960 bytes more cap
  than the host rung had.
* **The Phase 0 "within 7%" is closer than on 09-22 but does not reproduce.**
  2026-09-03 measured mandelbrot at 0.104 in-machine against 0.097 standalone;
  today it is 0.0746 in-machine (0.0922 in the Phase 0 probe of the same
  boot, 0.0822 in the warm encore) against 0.0650 on plain LuaJIT and 0.0650
  in the capped host: 1.15x on the Phase 1 min, 1.26x on the encore, 1.42x on
  the Phase 0 probe. 09-22's 1.71–1.73x was measured on the old box and does
  not reproduce here (1.15x); which of the box's changes it was is not
  separated.
* **Two clocks, both wall time, different resolution.** `driver.lua:45` says
  "os.clock is machine.cpuTime in the sandbox", and that is right: the sandbox
  takes `clock = os.clock` from the raw state (`machine.lua:1019`), but by then
  ocelot-brain's `luac/OSAPI.scala:13-19` has replaced the raw state's
  `os.clock` with `machine.cpuTime` — `System.nanoTime()` accumulated from the
  resume's start (`Machine.scala:148`), sub-millisecond, and it keeps advancing
  between resumes because `cpuStart` is only reset on close. The standalone
  rungs are timed by the C library's `clock()`, which on this Windows build
  has 1 ms resolution: every standalone min in this document is a whole number
  of milliseconds and no in-machine min is. Both measure elapsed wall time
  while the benchmark runs, so the rungs are comparable; the resolution only
  matters where the standalone cell is a few milliseconds (trampoline, 7–9 ms).
* **One in-game run.** One boot, five reps per benchmark, three benchmarks
  (sieve quarantined; sha256, nqueens, strings2 and trampoline not in the
  runner — sha256 not for its bit-op path: `compat.lua` took the same
  `operators` path in the harness's sandbox as standalone). Minecraft was in
  a world during the run, its JVM busy with it (about 47% of one core,
  sampled idle in-world afterwards), and the machine had 16 MB at ramScale
  1.8 where every other in-machine row here has 1 MB at 3.0 (the cap bound in
  neither). Reps 2–5 of binarytrees on the load-once runner are re-calls of
  one loaded chunk — by the standalone reproduction, most likely running
  through the traces the earlier calls left behind ("The in-game column";
  the `jit.flush()` test was standalone, and the game had no flush arm) —
  and are comparable only with the shared-VM `same` reps;
  its in-game figure is one rep, the first, so it can only read the same as
  or higher than a min of five would. The standalone clock's 1 ms steps leave
  the in-game mandelbrot comparison at 2–5% faster rather than the printed
  0.963, and matmul's at 1.04–1.06x rather than 1.052.

## Files

- Rebuild of r1 and r3 on this box: `pf2/rebuild.sh`, `pf2/rebuild.log`
  (every md5, the pristine-tree assertions, one mandelbrot through each arm
  shape), `pf2/pristine-make.log`; the old box's binaries under
  `pf2/old-bin/`.
- The chain that ran everything in series: `pf2/chain.sh`, `pf2/chain.log`
  (start-of-chain md5sums of all four binaries, java-process count, stage
  timestamps).
- Interleaved standalone sweep (r1, r1j, r2, r2j, r3u, r3uj, r3, r3j; 320
  rows): `pf2/ladder-1/summary.txt`, `raw.tsv`, `ladder.log` (per-process
  lines with timestamps, CPU load before and after), per-process logs under
  `logs/`.
- Cap sweep (r3, r3c, r3j, r3cj; 160 rows): `pf2/cap-1/summary.txt`,
  `raw.tsv`, `ladder.log`, `logs/`.
- Rung 4: `pf2/run-harness2.sh` (the four arms, `OCLJ_JAVA` pinned),
  `pf2/harness.log` (per-run summary), and `pf2/h-all-jiton/run.log`,
  `h-sieve-jiton/run.log`, `h-all-jitoff/run.log`, `h-sieve-jitoff/run.log`
  (`PHASE1 ROW`, `JIT PROBE`, `GC PRESSURE`, `JIT MEMORY`, `MEM-1`, `GC PACE`
  lines), each with `native.md5`, `exit.txt`, `started.txt`, `finished.txt`.
- Host, driver and sweep scripts, unchanged from 09-22: `pf/T/ladder_host.c`,
  `pf/T/driver.lua`, `pf/T/run-ladder.sh`, `pf/T/summarize.lua`,
  `pf/finish/cap/run-cap.sh`, `pf/finish/cap/summarize-cap.lua`.
- In-game runner: `bench/oc/ingame-ladder.lua`. The T7 run used the
  load-once version committed at `91a25f2`; the file now loads per rep
  (changed 2026-10-02, after the run). The run's output is the screenshot
  transcribed in "The in-game column".
- Shared-VM reps (2026-10-02, 15:32–15:35): `t7reps/reps.lua` (one process,
  N reps of one benchmark; `same` or `fresh`, `gc` or `nogc`; the driver's
  denials except `arg`; trace events and heap per rep),
  `t7reps/reps-texit.lua` (the same plus a `texit` counter, without the
  denials; counts only), `t7reps/run.sh` and `t7reps/run2.sh`, and their logs
  `t7reps/run-1/run.log` (r2 and r3, both shapes, both collection modes, two
  processes each, then the two controls) and `t7reps/run-2/run.log` (r1
  `same`, then the exit counts on r2 and r1).
- The separating test (2026-10-02, 16:56–16:57, Minecraft closed):
  `t7reps/reps-flush.lua` (reps.lua plus a `flush` mode, `jit.flush()` before
  every rep; its header says a flush also resets the hot counters, which is
  wrong — see the mechanism paragraph), `t7reps/run3.sh` and
  `t7reps/run-3/run.log` (r2 and r1 flushed,
  two processes each; r2 and r1 with `-joff`; r2 unflushed in the same run;
  r3 flushed and with `--joff`, one process each).
- nqueens (2026-10-02, 21:26–21:27, Minecraft closed; md5, first eight hex
  digits): `nqlead/nq-orig.lua` `55aa72da`, `nqlead/nq-flush.lua`
  `c4d7bc69`, `nqlead/nq-hoist.lua` `e5e77c08`, `nqlead/run.lua`
  `c75268fc`, and `nqlead/run-1/run.log` `895e4d7e` (a start line, a done
  line and 24 process lines: arm, variant, CHECK, TIME and the six rep
  times).
- Core placement (2026-10-02, 21:30–21:35): `pcore/cpusets.c` `8b58febb` /
  `cpusets.exe` `13e5b7e1` (the topology), `pcore/affrun.c` `79e7f120` /
  `affrun.exe` `fc08cf01`, `pcore/chain.sh` `3dafe006` and `pcore/one.sh`
  `5d42314f` (the three harness arms), `pcore/chain.log` `fb8f92ba` (the
  affinity read-backs and every `PHASE1 ROW`), and `pcore/h-P/`, `h-E/`,
  `h-U/` (each `run.log`, `native.md5`, `exit.txt`, `started.txt`,
  `finished.txt`). The standalone placement cells' per-process times are
  transcribed in the session's data notes, `docs-data-2026-10-02.md`
  (section A); no run log for them was found on disk.

`pf/`, `pf2/`, `t7reps/`, `nqlead/` and `pcore/` are this session's scratchpad
(`%LOCALAPPDATA%/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-…/scratchpad/`);
none of it is committed. The benchmark sources are `bench/oc/*.lua` and
`bench/oc/compat.lua` (md5 `e8684d9c…`, unchanged since the 09-22 cap sweep).
