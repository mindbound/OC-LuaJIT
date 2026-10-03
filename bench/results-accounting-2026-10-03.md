# The memory accounting without a JNI crossing per allocation (2026-10-03)

Until this change every allocation a machine made crossed into the JVM:
`lj52_alloc` called jnlua's `getthreadenv`, read `luaMemoryTotal` and
`luaMemoryUsed` with two `GetIntField` and wrote `luaMemoryUsed` back with a
`SetIntField`, so that OpenComputers could read an exact `freeMemory` at any
moment. Measured the same day
([results-allocator-2026-10-02.md](results-allocator-2026-10-02.md#what-the-machine-still-pays-per-allocation-the-jni-crossing-2026-10-03)):
binarytrees 0.389–0.399 s in a plain JVM with that accounting, 0.209–0.222 s
without it, and three cached prototypes that each failed `mem_test`.

The change keeps both figures in the shim's per-state record and synchronises
with Java only where Java can write or read them: the capped constructor and
`setTotalMemory` hand the cap down, `getFreeMemory` reads the used figure up.
Every allocation after the hand-over is plain C. The design, and why the
boundary is closed (jnlua's three accessors are the only readers and writers
of the two fields, all `synchronized`, all dispatched virtually from every
caller), is [docs/accounting-sync.md](../docs/accounting-sync.md).

**Result.** binarytrees in a plain JVM through the real class, capped, falls
from 0.385–0.399 s to 0.217–0.234 s, level with the same state uncapped
(0.207–0.219 s). In the pinned harness machine, with the class the only
difference, binarytrees reads 0.2500–0.2564 s against 0.4239–0.4247 s,
strings2 0.2003–0.2103 against 0.2386–0.2392, matmul 0.0881–0.0888 against
0.0947–0.0957; the pure loops do not move.
`getFreeMemory()` stayed exact at every reading taken: to the byte against
LuaJIT's own count, inside a Lua->Java call, in both modes.

## What was built

- **`native/lj52shim.c`.** The record gains `used`, `total` and `csync`.
  Every state starts in **legacy mode** -- the old path, unchanged, plus
  `used` kept in step -- and enters **C mode** at its first
  `lj52_mem_settotal`. In C mode `lj52_alloc` makes no JNI call: the delta,
  the refusal (`total - used < delta`, unless `norefuse`) and
  `lj52_gc_pressure` run on the record's fields, under the one predicate
  `accounting && total > 0`. Two cores, `lj52_mem_used` (-1 before the
  hand-over or without a record) and `lj52_mem_settotal`, and two JNI natives
  over them, compiled only into the additive build. `_OCLJ_GCSTATS` returns 20
  values: 15 native cap, 16 native used, 17 `csync`, 18 reads of the figure,
  19 allocator calls, 20 of them through JNI.
- **`LuaStateLuaJIT.java`**, through its generator: the capped constructor
  hands the cap over; `getFreeMemory()` and `setTotalMemory(int)` are
  `synchronized` overrides; `ocljUsedMemory` and `ocljSetTotalMemory` are
  private natives. An uncapped state asks no native at all.
- **The dropin** backs OpenComputers' own `LuaState`, which cannot carry the
  overrides, so it never hands over: legacy mode, and its cost, as before.
  That is the harness's default arm.

## Measured

### In a plain JVM (`JniArm`)

The arm from the allocator document's JNI section, extended: the old pair
(HEAD's class, the shipping DLL `88b50796`) against the new pair (the working
tree's class, the DLL built from it, `cb29485d`), interleaved by process, each
`java` launched through `affrun` with the performance-core mask, 0 java
processes at the start; binarytrees loaded afresh for each of 5 reps, 3 JVMs
per cell (`accsync/jni/run-1`, 13:32:34–13:32:54).

| pair | capped (64 MB), s | uncapped, s | JNI crossings, capped run |
|---|---:|---:|---:|
| old: HEAD class + `88b50796` | 0.385–0.399 | 0.210–0.218 | every allocator call |
| new: this class + `cb29485d` | 0.217–0.234 | 0.207–0.219 | 63 of 70 384 725 |

The 63 crossings are the `LuaState` constructor's own work, before its
subclass hands the cap over. Capped against uncapped, the new pair's minimums
differ by 0.005–0.010 s across the three JVMs (0.217/0.220/0.221 against
0.209/0.207/0.212): what is left of the accounting is its C arithmetic. Old
against new capped, at the minimums: 0.164–0.177 s a run, 11.7–12.6 ns per
accounted call over binarytrees' 14.08 M.

The mismatched pairs, once each: a **new class on the old DLL** throws
`UnsatisfiedLinkError: ...LuaStateLuaJIT.ocljSetTotalMemory(I)V` from the
capped constructor, and runs uncapped (no native is asked); an **old class on
the new DLL** stays in legacy mode (`csync` 0, 28 153 343 of 28 153 549 calls
through JNI) at the old speed, 0.398–0.400 s.

### In the machine (the ocelot-brain harness, pinned)

Same chain (`accsync/h2`, 13:08–13:16, 0 java processes at the start, all launched through `affrun`, JIT on, min
of 5): the additive arm, in C mode, against the dropin arm, in legacy mode.
The two also differ in the architecture class driving the machine
(`OCLuaJITArchitecture` against `NativeLua52Architecture`); the class-only
A/B below removes that.

| benchmark | additive, C mode | dropin, legacy | ratio |
|---|---:|---:|---:|
| mandelbrot | 0.0636 | 0.0639 | 0.995 |
| binarytrees | 0.2451 | 0.4177 | 0.587 |
| trampoline | 0.2217 | 0.2368 | 0.936 |
| matmul | 0.0910 | 0.0949 | 0.959 |
| strings2 | 0.2075 | 0.2334 | 0.889 |
| nqueens | 0.5586 | 0.5431 | 1.029 |
| sha256 | 0.0483 | 0.0490 | 0.986 |

**The class-only A/B** (`accsync/h3`, 13:33–13:40, 0 java processes at the
start, pinned, JIT on): one DLL (`cb29485d`), one architecture
(`OCLuaJITArchitecture`), all seven benchmarks; the only difference is the
`LuaStateLuaJIT` compiled into the harness -- HEAD's, which never hands over,
against the working tree's. Interleaved new, old, new, old; each cell is the
two runs' minimums of 5. `acc-2` read 92.4 M allocator calls a run in every
arm: none through JNI with the new class, every one with HEAD's.

| benchmark | new class, C mode | HEAD's class, legacy | new / old |
|---|---:|---:|---:|
| mandelbrot | 0.0643–0.0665 | 0.0632–0.0636 | 1.01–1.05 |
| binarytrees | 0.2500–0.2564 | 0.4239–0.4247 | 0.589–0.605 |
| trampoline | 0.2219–0.2237 | 0.2215–0.2229 | 1.00 |
| matmul | 0.0881–0.0888 | 0.0947–0.0957 | 0.92–0.94 |
| strings2 | 0.2003–0.2103 | 0.2386–0.2392 | 0.84–0.88 |
| nqueens | 0.5445–0.5715 | 0.5337–0.5468 | cells overlap |
| sha256 | 0.0469–0.0486 | 0.0485–0.0490 | 0.96–1.00 |

mandelbrot's cells are disjoint, the new class's 1–5% slower, but it makes
under 800 allocator calls a run, so the accounting cannot account for it; in
h2 the same comparison read 0.995. Not separated. (Five runs a cell after T9
do not reproduce it: 1.003 at the medians, [below](#the-three-arm-chain-after-t9-accsynch4).)

Also in h2, additive: JIT off binarytrees 0.3431 s (the 10-02 shipping DLL,
JIT off, read 0.5025 in its own chain), sieve 0.1041 s (0.1007 then): sieve's
~210 ns a call, the outlier of the allocator document, is not this cost.
`acc-2` counted 92 374 662 allocator calls between boot and the end of the
persistence milestones, none through JNI; the dropin arm, 92 385 582, every
one through JNI.

## In game (T9, 2026-10-03)

T9 in [docs/in-game-tests.md](../docs/in-game-tests.md), run in the game
session that began at 15:36 (the instance's `latest.log`: world joined
15:39:50, screenshot saved 15:41:02, game stopped 15:43:09), in the same
world and on the same 16 MB machine as T7 and T8. Checked before this section
was written: the only `ocluajit-*.jar` in the instance's `mods/` is
`ocluajit-0c656ac-master+0c656aca22-dirty.jar` (782 707 B), whose Windows
native is `cb29485d` and whose kernel is `089dcbde`; the runner on the
computer's disk is byte-identical to the repo's `bench/oc/ingame-ladder.lua`
(`a20fdf67`). Nothing in the game reads `csync` (the sandbox never sees
`_OCLJ_GCSTATS`), so that the game's machine ran in C mode rests on the jar
and on the harness, where every state the additive factory makes hands over
(`acc-1`, `acc-1r`). Transcribed from a screenshot of the computer's screen:

```
/home # ./ingame-ladder.lua
machine RAM total=16384 KB free=15888 KB  jit global=false
mandelbrot   CHECK=37904620  min=0.0657 s  reps: 0.067 0.067 0.068 0.066 0.066
matmul       CHECK=481.0000  min=0.0862 s  reps: 0.089 0.086 0.088 0.086 0.087
binarytrees  CHECK=7038400  min=0.2521 s  reps: 0.252 0.254 0.260 0.259 0.256
```

All three CHECKs equal the references. Min of 5, seconds; T8 and T7 as in
the allocator document's T8 table (T7's binarytrees its first rep); r1 plain
LuaJIT and r3l the arena host with the 64 MB accounting, both min of 5 fresh
processes from that table:

| benchmark | T9 `cb29485d` | T8 `88b50796` | T7 `bcf8715c` | T9/T8 | T9/r1 | T9/r3l |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.0657 | 0.0637 | 0.0626 | 1.031 | 1.011 | 1.011 |
| matmul | 0.0862 | 0.0946 | 0.1031 | **0.911** | 1.078 | 1.014 |
| binarytrees | 0.2521 | 0.4202 | 0.5586 | **0.600** | 1.313 | 1.064 |

- **The prediction is met on binarytrees and beaten on matmul**: T9
  printed binarytrees near 0.25 s and matmul near 0.089 before the run; they
  read 0.2521 and 0.0862. binarytrees' first rep is its min and its reps are
  flat (0.252–0.260, 1.03x); matmul's are 0.086–0.089.
- **The pinned harness tracked the game a third time, closely rather than
  exactly.** Before the game, h3's two runs (the source of the prediction)
  read binarytrees 0.2500–0.2564, which holds the game's 0.2521, and matmul
  0.0881–0.0888, which the game's 0.0862 is 2.2% below (T8's matmul was 0.8%
  below its chain's faster run). In the three-arm chain run after the game
  (below), T9's pair reads binarytrees 0.2431–0.2485 (the game 1.4% above the
  slowest, which is the disturbed run below; 1.7% above the slowest of the
  other four, 0.2480) and matmul 0.0862–0.0934 (the game on the fastest). T9
  over T8 in the game, 0.600 on binarytrees and 0.911 on matmul, against that
  chain's 0.569–0.595 (0.594 without the disturbed run) and 0.878–0.996
  between the two pairs' runs (0.578 and 0.923 at the medians): matmul's
  inside, binarytrees' just above the top, as its time is above the slowest
  run.
- **mandelbrot read 1.031x T8**, where T9 predicted no change. It is not this
  change, by three readings: mandelbrot makes under 800 allocator calls a
  run; in the chain below, with the class the only difference, it reads 1.003
  at the medians; and between the two libraries the harness moves it the
  other way (the new DLL 0.958x the old at the medians, cells overlapping at
  0.0641–0.0651). The game's three runs read 0.0626, 0.0637 and 0.0657, on
  three jars and in three sessions; one pair's five runs in one harness chain
  spread up to 3.4% leaving out the disturbed run below (T8's pair,
  0.0641–0.0663; T9's pair 2.9% without it, 15.8% with it). Read as variation between
  game sessions; not separated.
- **What remains over the bare host is now small.** Against r3l the game pays
  0.0151 s a binarytrees run (T8: 0.1832 s) and 0.0012 s on matmul (T8:
  0.0096): 1.064x and 1.014x. The crossing was about 92% of T8's binarytrees
  remainder; what is left is about 1.1 ns a call spread over binarytrees'
  14.08 M (a per-call equivalent). r3l is the 10-02 host, cold processes, in
  another session; the rest is not separated.
- **`free=15888 KB` at the runner's start**, against T8's 16 133 and T7's
  16 146 KB: the sandbox held 496 KB above the kernel's share where T8's held
  251 KB (OpenComputers' units: installed RAM minus free). The figure is now
  the shim's, so the harness was checked for a dependence on the mode and
  shows none: in the fifteen runs below, the machine's `getFreeMemory()`
  right after boot (`b2`) took the same two values, 3 140 697 and 3 114 676
  bytes, in all three arms, and the kernel's boot-time measurement spread
  alike in the two arms that differ only in the mode (the new DLL in legacy
  mode 335 193–412 601, T9's pair 334 601–413 193). T8's pair, on the old
  DLL, stayed within 339 281–347 861; the four readings above 350 K came in
  rounds 4 and 5, on the new DLL in both modes, while T8's pair read 347 093
  and 346 069 in the same rounds, and the eleven earlier runs on `cb29485d`
  today (h2 and h3, leaving out h2's `getFreeMemory` sabotage, which measures
  its own stale figure) read 334 513–357 545; not separated. In the game it is one
  reading of what the
  sandbox held when the runner started, which garbage not yet collected
  moves; not separated.

### The three-arm chain after T9 (`accsync/h4`)

15:44–16:10, after the game had been closed: no other java process at the
start or at the end (the fingerprint listing them was proven on a JDK 17
process before being trusted), every harness JVM's affinity read back
`0xC03C03` 25 s into its run. Five rounds of three arms in rotating order,
the full suite, JIT on, min of 5 per run; each cell is the five runs'
minimums, min–max (median). The old class is `0c656ac`'s, from before the
change; `acc-2` counted 92.4–92.5 M allocator calls a run in the new DLL's
arms, every one through JNI with the old class and none with the new.

| benchmark | T8's pair: `88b50796` + old class | new DLL + old class (legacy) | T9's pair: `cb29485d` + new class | T9/T8, medians |
|---|---:|---:|---:|---:|
| mandelbrot | 0.0641–0.0663 (0.0661) | 0.0631–0.0651 (0.0633) | 0.0631–0.0731 (0.0635) | 0.961 |
| binarytrees | 0.4173–0.4270 (0.4217) | 0.4169–0.4446 (0.4208) | 0.2431–0.2485 (0.2438) | **0.578** |
| trampoline | 0.2223–0.2252 (0.2248) | 0.2202–0.2259 (0.2246) | 0.2226–0.2315 (0.2247) | 1.000 |
| matmul | 0.0938–0.0982 (0.0949) | 0.0940–0.0987 (0.0969) | 0.0862–0.0934 (0.0876) | **0.923** |
| strings2 | 0.2305–0.2451 (0.2377) | 0.2247–0.2460 (0.2322) | 0.1849–0.2022 (0.1968) | **0.828** |
| nqueens | 0.4534–0.5506 (0.5376) | 0.4863–0.5602 (0.5458) | 0.4463–0.5480 (0.5425) | cells overlap |
| sha256 | 0.0483–0.0497 (0.0486) | 0.0484–0.0498 (0.0493) | 0.0472–0.0496 (0.0487) | 1.002 |

- **The library's legacy path costs nothing measurable.** The new DLL in
  legacy mode against T8's pair: binarytrees 0.998 at the medians, strings2
  0.977, matmul 1.021, every cell overlapping. That is the path the dropin
  stays on, and every state before its hand-over.
- **h3's mandelbrot hint does not reproduce.** With the class the only
  difference mandelbrot reads 1.003 at the medians here, where h3's two runs
  a cell had read 1.01–1.05x.
- **T9's pair's first run (t9-1, 15:48–15:49) was disturbed**: its pair's
  highest maxima on every benchmark but sha256 (mandelbrot 0.0833, binarytrees
  0.3127, matmul 0.1182; on mandelbrot, matmul and nqueens the chain's highest
  too) and its pair's highest mandelbrot, binarytrees, trampoline and matmul
  minimums (mandelbrot's 0.0731 and trampoline's 0.2315 the chain's highest).
  Without it the pair reads mandelbrot 0.0631–0.0649, binarytrees
  0.2431–0.2480, trampoline 0.2226–0.2264 and matmul 0.0862–0.0882. What ran then was not identified.
  Most medians are not its values, but strings2's is: its 0.1968 is the
  pair's median, and without it the other four's median, 0.1939, reads 0.816
  of T8's rather than 0.828 -- so the table's 0.828 is the conservative end.

## Exact, everywhere it was read

- `mem_test` C0b, C2a, C2c, C7: the native figure equals LuaJIT's
  `g->gc.total` to the byte, absolute, at the hand-over, after 20 000 tables,
  after a collection, and with the accounting switched off; M3c: legacy mode
  keeps it too.
- The harness's `acc-3`: inside one Lua->Java call, `getTotalMemory() -
  getFreeMemory()` against LuaJIT's count read in the same call, after an
  allocation, after a 100 000-byte string and after a collection: equal,
  2 066 596 / 2 297 696 / 177 176, in the additive arm and in the dropin arm.
- `JniArm`, after the run, both pairs: equal (219 982 old, 176 442 new;
  `accsync/jni/run-2`).
- The cap: `acc-1` and `acc-1r` find the shim's cap equal to Java's after
  boot and on a restored machine, `acc-2` after the persistence milestones'
  saves (each raises the cap to `Integer.MAX_VALUE` and puts it back);
  `acc-4`'s constructor-only state stopped at a native used of 4 194 319
  against its 4 194 304 cap -- 15 bytes over, jnlua's unrefusable pushes while
  it raised, charged (M7, C6) -- and a cap lowered under that read
  `getFreeMemory() == 0` and reached the shim at once.

## The gates, and every new check seen to fail first

Gate chain `accsync/g1` (13:03–13:06) and harness chain `accsync/h2`
(13:08–13:32), on the working tree after the review's fixes.

| gate | result | seen to fail first |
|---|---|---|
| Windows natives | dropin `f556d839` 87 `Java_*` / 89 PE names; additive `cb29485d` 89 / 91, both accounting natives by exact name; warning-clean; serializer `8c5a1168` | the export greps on the shipping additive `88b50796`: 87 / 89, 0 accounting natives |
| object gate (`nm`) | both cores in both variants; the two natives in the additive only | on the pre-change object `e3392678`: 0 of 2 cores |
| regenerate-and-diff (additive) | `LuaStateLuaJIT.java` == the generator's output, Windows and WSL | a mirror whose class carries one hand edit: the build refuses |
| Linux native (WSL) | `.so` `90be1300`, same gates; `mem_test` on Linux 49/0 | -- |
| jar | `ocluajit-0c656ac-master+0c656aca22-dirty.jar`, 782 707 B, DLL `cb29485d`, `.so` `90be1300`, kernel `089dcbde`; `javap` shows both overrides `synchronized` and both natives `private native` | `verifyModAssets` on the shipping `88b50796` / `c1a9d865`: refused, both |
| `mem_test` | 49/0 (was 29: C0a-d, C1, C2a-c, C3a-b, C4a-c, C5a-b, C6, C7, C8, M3c, M9) | pre-change object, `-DMEMTEST_OLD`: exactly the twelve C-mode checks fail (M3c, C0a-d, C1, C2a-c, C7, C8, M9) and C3-C6 pass on the legacy path; without the switch it does not link. Nine sabotaged shims: free uncredited -> C2a C2c C4c C7; cap dropped -> C0b C3a C4b C5a C5b C6; no pressure -> C5a C5b; `norefuse` ignored -> the process dies at C6; legacy `used` not kept -> M3c C0b C2a C2c C5a C5b C6 C7; C path dead -> C1; reads uncounted -> C2b; `-1` lost -> C0a C8; `getthreadenv` called in C mode -> C1 |
| watchdog, penalty, race, security, shim_test | 35/0, 6/0, 2/0, 37/0, 57/0 | -- |
| `negative-control.sh` (mirrored; its paths are stale) | the memory controls PASS with their lists brought up to date; `standinghook` FAILS on an extra W10g, as it does on HEAD's tree | its memory lists, run unchanged: stale since 09-22 (the trace-flush cases) and again now |
| harness, additive, JIT on / off / sieve | 65/0, 63/0, 59/0 | -- |
| harness, dropin; stock | 62/0 (legacy asserted: `csync` 0, every call through JNI); 41/0 (`acc-*` SKIP) | -- |
| harness sabotages (`OCLJ_JAVA_SRC`) | -- | no `getFreeMemory` override -> acc-2 acc-3 acc-4 acc-7 e2 e3 mem-2; no constructor hand-over -> acc-4; `setTotalMemory` not forwarded -> acc-1 acc-1r acc-2 acc-4 mem-2, then e4 runs to the harness timeout; not `synchronized` -> acc-7; HEAD's class on the new DLL -> acc-1 acc-1r acc-2 acc-4 acc-7, the machine running in legacy mode; the new class on the old DLL -> the machine does not start |

## The review

An adversarial review of the change as built (four lenses -- the C side, Java
and OpenComputers semantics, the tests, the build and packaging -- each
finding checked by a separate skeptic) found no defect in the C or Java
logic. What it found, and what was done:

- **acc-3 failed in both arms for a reason of its own** (confirmed; found
  independently by the first harness run): see the next section. Fixed.
- **`gcstats` read `getTop` outside its `try`**, and acc-2 did not guard a
  stopped machine: a dead machine would have aborted the harness. Fixed.
- **A new class on an old library, uncapped** (`computer.lua.limitMemory=false`):
  the first override asked the native on every `getFreeMemory()`, which on
  that pairing would have thrown mid-run. The override now asks nothing of an
  uncapped state; the JVM arm's mismatched pair runs it.
- **acc-4's `used <= cap` could not fail**, `getFreeMemory` being clamped:
  it now reads the native figure, and also asserts the clamp and the forward
  of a lowered cap.
- **No check saw `getthreadenv`**, a third of the crossing's cost: `mem_test`
  now counts it (C0d, C1), and a ninth sabotage proves C1 sees it.
- **The generator used `Path.write_text(newline=)`**, Python 3.10+, while the
  build accepts any Python 3. Replaced.
- **`negative-control.sh`'s `nopending` anchor** no longer matched. Fixed,
  and both memory lists re-pinned against a run, with HEAD's tree run the
  same way to separate the drift that predates this change.
- The design document's stats numbering. Fixed.

## Two instrument faults, found on the way

- **C5a's first draft said the emergency collector would not arm against the
  native cap.** The setup's two full collections flipped the GC white twice,
  back to the colour a latched cycle had been armed under (the safe point's
  trace flush re-arms one), so the latch never saw its cycle end and the churn
  stopped on that stale disarm. With a settle loop, the baseline then carried
  garbage and the cycle restored the headroom. Fixed by settling on
  observation and asserting "not armed" as a precondition.
- **acc-3 read Java's figure 48 bytes short of LuaJIT's count, on its first
  reading only, in both arms.** jnlua's `gc()` pushes `gc_protected`, and the
  first push in a state allocates the shim's memo entry -- a 48-byte `GCfunc`
  -- inside the call that reads the count. The probe is now warmed and reads
  the count first. The legacy arm failing identically was what showed it was
  the instrument; the JVM arm's exactness line had the same fault and was
  re-run the same way.

## What this does not say

- **One game run.** T9 is one run in one session; the comparisons rest on
  the harness's interleaved chains, which the game has now tracked three
  times.
- **The dropin keeps the old cost**, by design. It is the harness's default
  arm; numbers from it are legacy-mode numbers from now on.
- **macOS** was not built.
- What remains of binarytrees' in-machine cost over the bare host -- 0.015 s
  in game against the 10-02 arena host, a cold-process baseline from another
  session -- is not separated: the sandbox, OpenOS, the machine's executor
  and the host's own baseline are all in it.

## Files

`native/lj52shim.c`, `native/lj52shim.h`, `native/jnlua/gen-luastate-subclass.py`,
`src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java` (generated),
`native/build-native.sh`, `build.gradle.kts`, `test/native/mem_test.c`,
`test/native/run-mem.sh`, `test/native/OcljSmoke.scala`,
`test/native/negative-control.sh`, `docs/accounting-sync.md`. Run logs in the
session scratchpad under `accsync/` (`g1`, `h1`, `h2`, `h3`, `h4`,
`jni/run-1`, `jni/run-2`, `ff-mem-1`, `b1`).
