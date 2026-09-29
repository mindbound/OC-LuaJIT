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
`os = {clock = realos.clock}`; in the machine the sandbox's `os.clock` is the
raw one (`machine.lua:1019`, `clock = os.clock,` in the kernel copy the harness
ran). Both are the C library's `clock()`, which on Windows is wall time since
process start (results-2026-09-01, method note), so both charge the benchmark
for any time the core was given to something else — which, on this box, was
very little.

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
|---|---:|---:|---:|---:|---:|---:|---|---|
| mandelbrot | 0.0650 | 0.0650 | 0.0650 | 0.0650 | 0.0650 | 0.0746 | | `37904620` |
| sha256 | 0.0480 | 0.0470 | 0.0480 | 0.0470 | 0.0480 | 0.0669 | | `4044b974…25a5d` |
| matmul | 0.0800 | 0.0820 | 0.0940 | 0.0970 | 0.0980 | 0.1608 | | `481.0000` |
| nqueens | 1.0410 | 1.0610 | 1.0700 | 1.0590 | 1.0650 | **0.6765** | | `85200` |
| sieve | 0.0850 | 0.0870 | 0.2170 | 0.2160 | 0.2170 | **0.1829** | | `4626000` |
| binarytrees | 0.1920 | 0.1900 | 0.3640 | 0.4090 | 0.4060 | 0.7146 | | `7038400` |
| strings2 | 0.1780 | 0.1770 | 0.2100 | 0.2260 | 0.2230 | 0.3046 | | `12582912-3852468224` |
| trampoline | 0.0080 | 0.0080 | 0.0070 | 0.0080 | 0.0080 | 0.2756 | | `247388` |

The **in-game** column is empty: nothing here ran in Minecraft. It is filled
by T7 in [docs/in-game-tests.md](../docs/in-game-tests.md): `ingame-ladder` at
the OpenOS shell runs mandelbrot, matmul and binarytrees from the same files
(min of 5 with a yield between reps, same checksums), on the same box as the
rungs above.

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
0/0/0/0`, `mcode=0 B`).

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
- `os.clock` — the same C `clock()` in both rungs, wall time since process
  start on Windows, so it charges descheduled time in both; it cannot make a
  program read faster in the machine unless the standalone runs were
  descheduled more, and on this box, at 1–13% load with cells spreading
  1.01–1.03x on nqueens, they were not;
- the JVM thread and its scheduling;
- position in the boot: nqueens ran sixth of seven in its machine, with
  459 KB free after it (286 KB on 09-22; `arms=0` for that whole boot, so no
  emergency cycle ran).

A rung between r3c and the machine — the bare host running `machine.lua`'s
sandbox over the same driver, with no OpenOS and no JVM — is the measurement
that would split this list, and it does not exist yet.

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
* **One boot per JIT mode for seven benchmarks.** `arms=0` for both
  seven-benchmark boots, so the emergency collector never ran in them, but
  the benchmarks still ran in a fixed order in a shared heap (free after
  each, JIT on: 739, 595, 764, 751, 637, 459, 796 KB; JIT off: 983, 874, 919,
  957, 746, 930, 994 KB) and, in the JIT-on boot, in a trace cache that had
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
* **Nothing in Minecraft.** The in-game column is empty by design.

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

`pf/` and `pf2/` are this session's scratchpad
(`%LOCALAPPDATA%/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-…/scratchpad/`);
none of it is committed. The benchmark sources are `bench/oc/*.lua` and
`bench/oc/compat.lua` (md5 `e8684d9c…`, unchanged since the 09-22 cap sweep).
