# The allocator rung, answered — every machine's blocks in LuaJIT's own allocator

Date: 2026-10-02, 21:36–22:16, on the box of
[results-ladder-2026-09-29.md](results-ladder-2026-09-29.md) (Intel Core Ultra
9 285HX: 8 performance and 16 efficient cores, no SMT; Windows 11 Pro), with
Minecraft closed (0 `javaw` processes) for every timing below but the
in-game section's (T8, added 2026-10-03). This document
answers the question that ladder's section 2 left open, describes the change
the answer led to, and records the gates the change passed. Every in-machine
timing here was taken with the harness JVM launched pinned to the performance
cores, for the reason in the ladder's
[2026-10-02 evening addendum](results-ladder-2026-09-29.md#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores);
the java process's affinity was read back on the chain runs, not on the gate
runs ("What this does not say").
Every number outside the in-game section is in a file under this session's
scratchpad (Files, at the end; the churn times survive only in the session's
data notes there); that section's T8 figures are transcribed from a
screenshot of the game, and what it quotes from the ladder (T7, r1, r3c, the
shared-VM reps, the 09-29 call counts) is that document's.
The same evening's two other findings — that the unpinned harness had been
reading in the efficient-core arm's range, and that nqueens'
compiled-slower-than-interpreted reading is the stale-trace mechanism — are
written up in the ladder document, as its
[core-placement addendum](results-ladder-2026-09-29.md#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores)
and its subsection
[nqueens: the same mechanism](results-ladder-2026-09-29.md#nqueens-the-same-mechanism).

## The question

The ladder's rung 2, r3u/r2, is our VM in a bare C host on the C library's
`realloc`/`free` against the same VM as `luajit.exe` on LuaJIT's own
`lj_alloc`. On 2026-09-29 it was the largest standalone rung, on disjoint
cells: sieve 2.494, binarytrees 1.916, strings2 1.186 and matmul 1.146 with
the compiler on, binarytrees 1.693 with it off, and 0.875–1.021 on the four
benchmarks that make under 800 allocator calls a run. In the in-game column
(T7) it was 61% of binarytrees' log-ratio to plain LuaJIT and 54% of matmul's.

Two things were missing.

- **The arm.** r3u differs from r2 by the executable, `lj52_newstate`'s
  state record, `lj52_alloc`'s dispatch on every call and the eris link as
  well as by the allocator, and no arm ran the host on `lj_alloc`. So the
  allocator was the leading candidate for the rung, not a measured cause
  (ladder section 2; its "What this does not say" lists the arm first among
  four that did not exist).
- **Whether the fix was possible.** jnlua creates every state through
  `lua_newstate` with a caller-supplied allocator, so LuaJIT never uses
  `lj_alloc` for it. The ladder asked whether an `lj_alloc`-backed accounting
  allocator is possible under jnlua's `lua_setallocf` convention, and did not
  answer.

Both are answered here: the arm exists — the same host linked against a shim
whose states keep their blocks in `lj_alloc` — it puts the rung on the
allocator, and the same construction now ships.

## The change

`lj_alloc` is reachable without being the state's allocator. From a state's
birth jnlua sees `lj52_alloc` as its allocator, and jnlua's `lua_setallocf`
calls never replace it: `lj52_setallocf` only turns the accounting on or off
(the "allocator ownership" note in `native/lj52shim.h`). What `lj52_alloc`
does with a block once the accounting is done is the shim's own business,
and until this change it was `realloc`/`free`. The change replaces that
backing store and nothing above it.

- **One arena per state.** The per-state record `lj52_mem` gains
  `void *heap`, the state's own `lj_alloc` arena. `lj52_back(M, ptr, osize,
  nsize)` is `lj_alloc_f(M->heap, ptr, osize, nsize)`, or `lj52_libc` when
  `heap` is NULL, and `lj52_alloc`'s three touches of memory — the path that
  banks a delta while nobody can be told yet, the free, and the
  allocate/resize — all go through it (`native/lj52shim.c`). The accounting
  arithmetic is unchanged and counts requested sizes, not the backing: in the
  smoke run binarytrees made 14 076 162 gets and 14 076 163 sets on the arena
  host against 14 075 754 and 14 075 755 on the C-library host.
- **Life cycle.** `lj52_newstate` seeds a stack PRNG
  (`lj_prng_seed_secure`) and creates the arena (`lj_alloc_create`)
  **before** `lua_newstate`, so the state's first allocation, the
  `GG_State`, lands in it. `lj_alloc_create` uses the PRNG it is handed for
  its first segment and does not keep it, so the arena is pointed at the
  stack PRNG at once (`lj_alloc_setprng`) and re-pointed at the state's own
  `G(L)->prng` once the state exists, as `lj_state_newstate` does for
  LuaJIT's internal allocator. `lj52_close` stops the watchdog, turns the
  accounting off and clears `javaref` (jnlua turns the accounting off before
  every close already; this makes a close that skipped that step safe too),
  calls `lua_close` — which frees every block, the `GG_State` last, through
  `lj52_alloc` into the arena — and only then `lj_alloc_destroy`. Every block
  of a state is allocated, resized and freed in one arena for the state's
  whole life, so the hazard the allocator-ownership note describes — a block
  changing allocators — cannot arise.
- **The fallback.** If the PRNG cannot be seeded or the arena cannot be
  created, `heap` stays NULL and the state lives on the C library for its
  whole life, accounted exactly as before. A second fallback is older and is
  kept as it was: if `lua_newstate` itself fails, `lj52_newstate` returns
  `luaL_newstate()`, a state on LuaJIT's internal allocator with **no
  accounting record**, its RAM cap silently unenforced. The comments now say
  so (`lj52shim.c`, and stage 1b of `native/build-native.sh`); whether it
  should return NULL instead is open.
- **The fingerprint.** `_OCLJ_GCSTATS` returns a 14th value, `heap`: 1 when
  the state's blocks live in its own arena, 0 on the C-library fallback, -1
  when the state has no record (created outside `lj52_newstate`, or by the
  `luaL_newstate` fallback). `lj52_back` chooses by the same pointer `heap`
  reports, so the arena's existence is its use.
- **The checks.** `native/build-native.sh` asserts with `nm -u` that the
  shim object references `lj_alloc_create`, `lj_alloc_f`,
  `lj_alloc_destroy`, `lj_alloc_setprng` and `lj_prng_seed_secure`, and
  fails if `-DLUAJIT_USE_SYSMALLOC` (which compiles `lj_alloc` out) reached
  the LuaJIT build. `test/native/mem_test.c` gains M0, M0b and M0c (`heap ==
  1` for both of its states at birth, and for the first again at the end).
  `test/native/OcljSmoke.scala` gains the milestone
  `al-1-machine-heap-is-lj-alloc`, which reads the machine's `heap`, names
  each wrong reading, and prints a SKIP line on stock PUC. Which of these was
  seen to fail first is in "The gates".

## Standalone: the arm the ladder was missing

The ladder's own host source and driver (`pf/T/ladder_host.c`,
`pf/T/driver.lua`) and the same eight `bench/oc` files. Five arms:

| arm | binary | backing store | accounting |
|---|---|---|---|
| r2 | ours, `luajit.exe` `cae31580…` | `lj_alloc`, LuaJIT's own state setup | none |
| r3u | the 09-29 host `cc6e8509…` (shim object `8ef84b32…`), `--nocap` | the C library | off (`sets == 0`) |
| r3 | same, 64 MB | the C library | bound |
| r3ul | the same host source linked against the prototype shim object `36e4b93b…` (`ladder_host_lj.exe` `75a061ea…`), `--nocap` | the state's own `lj_alloc` arena | off (`sets == 0`) |
| r3l | same, 64 MB | the arena | bound |

r3ul and r3l link the same `libluajit.a` (`13878386…`) and `eris_lj.o`
(`8c94e8b0…`) as r3u and r3, so the pairs differ by the shim object, whose
only change in the prototype was the backing store. Eight benchmarks x five
arms x five fresh processes, round-robin: 200 rows, 21:36–21:37, unpinned
(unpinned standalone processes ran at performance-core speed on this box: the
ladder's addendum), 0 abnormal exits, one CHECK per benchmark across all
arms. Min of 5 (max), seconds:

| benchmark | r2 ours | r3u libc | r3 libc + accounting | r3ul arena | r3l arena + accounting | CHECK |
|---|---:|---:|---:|---:|---:|---|
| mandelbrot | 0.0660 (0.0660) | 0.0660 (0.0670) | 0.0650 (0.0660) | 0.0650 (0.0670) | 0.0650 (0.0670) | `37904620` |
| sha256 | 0.0470 (0.0500) | 0.0490 (0.0500) | 0.0470 (0.0480) | 0.0470 (0.0500) | 0.0470 (0.0480) | `4044b974…25a5d` |
| matmul | 0.0810 (0.0830) | 0.0960 (0.1000) | 0.0940 (0.1030) | 0.0830 (0.0850) | 0.0850 (0.0860) | `481.0000` |
| nqueens | 1.0570 (1.0680) | 1.0600 (1.0710) | 1.0590 (1.0720) | 1.0610 (1.0830) | 1.0600 (1.0690) | `85200` |
| sieve | 0.0850 (0.0990) | 0.2250 (0.2300) | 0.2270 (0.2310) | 0.0850 (0.1020) | 0.0860 (0.0880) | `4626000` |
| binarytrees | 0.1940 (0.1980) | 0.3730 (0.4100) | 0.4040 (0.4370) | 0.2090 (0.2160) | 0.2370 (0.2460) | `7038400` |
| strings2 | 0.1770 (0.1810) | 0.2130 (0.2220) | 0.2220 (0.2320) | 0.1810 (0.1850) | 0.1880 (0.1940) | `12582912-3852468224` |
| trampoline | 0.0070 (0.0090) | 0.0080 (0.0080) | 0.0080 (0.0090) | 0.0070 (0.0090) | 0.0080 (0.0090) | `247388` |

Ratios from the mins; > 1 means slower than the arm after the slash:

| benchmark | r3u/r2, the ladder's rung 2 | **r3u/r3ul, the allocator alone** | r3ul/r2, the rest of the host | r3l/r3ul, accounting on the arena | r3l/r2 | **r3l/r3, what the change buys** |
|---|---:|---:|---:|---:|---:|---:|
| sieve | 2.647 | **2.647** | 1.000 | 1.012 | 1.012 | **0.379** |
| binarytrees | 1.923 | **1.785** | 1.077 | 1.134 | 1.222 | **0.587** |
| strings2 | 1.203 | **1.177** | 1.023 | 1.039 | 1.062 | **0.847** |
| matmul | 1.185 | **1.157** | 1.025 | 1.024 | 1.049 | **0.904** |
| sha256 | 1.043 | 1.043 | 1.000 | 1.000 | 1.000 | 1.000 |
| mandelbrot | 1.000 | 1.015 | 0.985 | 1.000 | 0.985 | 1.000 |
| nqueens | 1.003 | 0.999 | 1.004 | 0.999 | 1.003 | 1.001 |
| trampoline | 1.143 | 1.143 | 1.000 | 1.143 | 1.143 | 1.000 |

trampoline runs 7–8 ms on a 1 ms clock in every arm; its ratios are one
tick. Spreads (max/min) are 1.00–1.10x in every other cell but sieve's r2
and r3ul cells, 1.16x and 1.20x.

**The rung is the allocator.** The ladder's rung reproduces (r3u/r2 sieve
2.647, binarytrees 1.923, strings2 1.203, matmul 1.185, against 09-29's
2.494, 1.916, 1.186 and 1.146), and swapping only the backing store under the
same host takes back all of sieve's and most of the other three's: r3u/r3ul
is 2.647, 1.785, 1.177 and 1.157, every pair of cells disjoint (sieve
0.2250–0.2300 against 0.0850–0.1020; binarytrees 0.3730–0.4100 against
0.2090–0.2160; strings2 0.2130–0.2220 against 0.1810–0.1850; matmul
0.0960–0.1000 against 0.0830–0.0850). This is the arm the ladder lacked, and
on it the allocator is a measured cause of the rung rather than the leading
candidate.

**What the host adds besides** is r3ul/r2: 1.000 on sieve, 1.023 and 1.025
on strings2 and matmul (cells touching at one value, 0.1810 and 0.0830), and
**1.077 on binarytrees** (0.2090–0.2160 against 0.1940–0.1980, disjoint):
the state record, `lj52_alloc`'s dispatch, the eris link and the executable
together. This arm does not separate them.

**The accounting on the arena** reads 1.134 on binarytrees, 1.039 on
strings2, 1.024 on matmul and 1.012 on sieve (binarytrees' and strings2's
cells disjoint, matmul's touching, sieve's overlapping). On the C library
the same rung read 1.083, 1.042, 0.979 and 1.009 today (r3/r3u) and 1.124,
1.076, 1.032 and 0.995 on 09-29. Divided per call on binarytrees from the
mins, 0.028 s over 14.08 M accounted calls is about 2.0 ns on the arena and
today's 0.031 s about 2.2 ns on the C library — an upper bound on a mixture,
for the reason ladder section 3 gives.

**Net**, the host with the accounting bound now costs 1.222 on binarytrees,
1.062 on strings2, 1.049 on matmul and 1.012 on sieve against `luajit.exe`,
where on the C library it cost 2.082, 1.254, 1.160 and 2.671 (r3/r2, same
sweep). r3l/r3, what the change buys in the host: sieve 0.379, binarytrees
0.587, strings2 0.847, matmul 0.904, the other four 1.000–1.001.

## In the machine

The prototype shim, built into the additive DLL by the repo's own
`build-native.sh` pointed at a scratch shim and build directory
(`OCLJ_SHIM`, `OCLJ_BUILD`): DLL `324c3aaa…`. The baseline is `bcf8715c…`,
the DLL of the ladder's rung 4 and of T7. The harness is rung 4's
(ocelot-brain, Temurin JDK 8.0.504, the watchdog kernel, tier `threehalf`,
`OCLJ_REPS=5`, compiler on); every run was started through `affrun` with the
performance-core mask, and 25 s into each the java process's own affinity
read back `0xC03C03`. Order: proto-1, base-1, proto-2 (21:38–21:43), then a
sieve machine on each DLL (21:43–21:46); 0 java processes at the start. The
shipping column is the gate run of the final code (DLL `88b50796…`,
22:08–22:16, launched through `affrun` with the same mask but with no
affinity read-back recorded, so it carries no placement fingerprint; "The
gates"). `PHASE1 ROW` min/max, seconds:

| benchmark | base-1 `bcf8715c` | P arm, same DLL (addendum, 21:30) | proto-1 `324c3aaa` | proto-2 `324c3aaa` | proto-1/base-1 | shipping `88b50796` |
|---|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.0632/0.0672 | 0.0661/0.0676 | 0.0630/0.0679 | 0.0637/0.0673 | 0.997 | 0.0662/0.0706 |
| binarytrees | 0.5391/0.6263 | 0.5168/0.6081 | **0.4117/0.4162** | **0.4111/0.4209** | **0.764** | 0.4105/0.4207 |
| trampoline | 0.2238/0.2258 | 0.2276/0.2346 | 0.2277/0.2365 | 0.2249/0.2306 | 1.017 | 0.2381/0.2939 |
| matmul | 0.1046/0.1144 | 0.1049/0.1202 | **0.0946/0.0960** | **0.0942/0.0964** | **0.904** | 0.0962/0.0978 |
| strings2 | 0.2587/0.2751 | 0.2636/0.2761 | **0.2301/0.2402** | **0.2348/0.2445** | **0.889** | 0.2399/0.2543 |
| nqueens | 0.4339/1.0978 | 0.5639/1.0871 | 0.5358/1.0951 | 0.5374/1.0899 | 1.235 | 0.5437/1.1208 |
| sha256 | 0.0491/0.0559 | 0.0495/0.0536 | 0.0483/0.0514 | 0.0495/0.0517 | 0.984 | 0.0511/0.0625 |
| sieve, own machine | 0.1612/0.2394 | — | **0.1037/0.1099** | — | **0.643** | 0.1007/0.1029, n = 4 |

All five chain runs PASS (56/0 the seven-benchmark boots, 50/0 the sieve
boots). The sieve machines armed the emergency collector 800 times on both
DLLs (`arms=800 collects=800`, as on 09-29; the shipping sieve row, four
reps, 640). proto-1's seven-benchmark boot showed `GC PRESSURE: arms=54
collects=54 bailouts=0 refusals=0` where base-1, proto-2 and both gate runs'
JIT-on seven-benchmark boots at tier threehalf showed 0 — not explained;
every collect completed and nothing was refused. With the compiler off the shipping DLL read mandelbrot 0.3814,
binarytrees 0.5025, trampoline 0.2761, matmul 0.6223, strings2 0.4356,
nqueens 0.9292 and sha256 0.8055; no pinned JIT-off baseline was run.

- **The four allocating benchmarks are faster on the arena, every pair of
  cells disjoint against both baseline runs**: binarytrees 0.4111–0.4209
  against 0.5168–0.6263, matmul 0.0942–0.0964 against 0.1046–0.1202,
  strings2 0.2301–0.2445 against 0.2587–0.2761, sieve 0.1037–0.1099 against
  0.1612–0.2394. proto-1/base-1 is 0.764, 0.904, 0.889 and 0.643; proto-2's
  0.763, 0.901 and 0.908; the shipping DLL's 0.761, 0.920, 0.927 and 0.625.
  The arena's binarytrees and matmul cells are also tighter: 1.01–1.02x
  against 1.09–1.18x.
- **mandelbrot, sha256 and trampoline stay within a few percent** (proto-1
  0.984–1.017 of base-1). trampoline's proto-1 min sits 2 ms above base-1's
  max but inside the P arm's cell of the same baseline DLL. The shipping gate
  run's trampoline, 0.2381/0.2939, sat above both baseline cells (1.064x
  base-1's min), on a run with no placement fingerprint; the fingerprinted
  re-run below reads 1.009–1.027x, so that reading was the run, not the DLL.
- **The shipping DLL, fingerprinted** (`ljalloc/ship-ab/`, 23:07–23:14,
  after `gradlew --stop`: 0 java processes at the start; every run through
  `affrun` with the performance-core mask and java's affinity read back
  `0xC03C03`; order ship-1, base-2, ship-2, then a sieve machine on the
  shipping DLL). `PHASE1 ROW` min/max, seconds:

  | benchmark | ship-1 `88b50796` | base-2 `bcf8715c` | ship-2 `88b50796` | ship/base |
  |---|---:|---:|---:|---:|
  | mandelbrot | 0.0637/0.0685 | 0.0671/0.0691 | 0.0638/0.0698 | 0.949–0.951 |
  | binarytrees | **0.4295/0.4376** | 0.5671/0.6419 | **0.4127/0.4239** | **0.728–0.757** |
  | trampoline | 0.2284/0.2345 | 0.2223/0.2271 | 0.2244/0.2304 | 1.009–1.027 |
  | matmul | **0.0978/0.0991** | 0.1102/0.1154 | **0.0954/0.1008** | **0.866–0.887** |
  | strings2 | **0.2509/0.2588** | 0.2737/0.2853 | **0.2383/0.2458** | **0.871–0.917** |
  | nqueens | 0.5508/1.1124 | 0.4833/0.5671 | 0.4940/1.1255 | not read |
  | sha256 | 0.0492/0.0515 | 0.0495/0.0508 | 0.0493/0.0562 | 0.994–0.996 |
  | sieve, own machine | 0.1013/0.1052, n = 4 | (21:45: 0.1612/0.2394) | — | 0.628 |

  ship-1 and ship-2 PASS 57/0 (al-1 `14:1`), the sieve machine 51/0; base-2
  57/1, the one failure al-1 (`13:nil`), its fail-first once more. The
  allocating benchmarks' cells are disjoint from base-2's in both shipping
  runs; trampoline's are 1–3% apart and ship-2's overlaps. This is the
  shipping column to quote; the gate run's agrees with it on everything
  but trampoline.
- **nqueens' min moves the other way** (1.235) on cells that spread
  1.9–2.5x in every arm; it is not read here. Ladder subsection
  [nqueens: the same mechanism](results-ladder-2026-09-29.md#nqueens-the-same-mechanism)
  is about what that cell holds.
- **The machine gains fewer seconds than the host on two of the four.**
  binarytrees saves 0.127 s a run in the machine (proto-1 against base-1)
  and 0.167 s in the host (r3 to r3l); sieve 0.058 s against 0.141 s;
  strings2 (0.029 against 0.034 s) and matmul (0.010 against 0.009 s) save
  about the same. Candidates, not separated: the machine's five reps share
  one long-lived heap that the C library had already grown, where each host
  process starts cold (the ladder's side result: on the C-library host the
  first run took 1.12–1.27x its later fresh loads, and `luajit.exe` on
  `lj_alloc` showed no such step); and sieve's 800 emergency collections per
  machine, which hand either allocator a heap collected back to a small size
  (09-29's candidate for sieve reading faster in the machine than in the
  host).
- **Over the arena host**, the machine now reads binarytrees 1.737,
  strings2 1.224, sieve 1.206, matmul 1.113, sha256 1.028 and mandelbrot
  0.969 (proto-1 over r3l: a pinned machine over unpinned standalone
  processes, which ran at performance-core speed).

**Why every run here is pinned.** On this box the harness's machine thread,
in a hidden background JVM, is not reliably on a performance core: pinned to
the efficient cores the baseline DLL read 1.26x, 1.55x and 1.60x its
performance-core times on mandelbrot, matmul and binarytrees; unpinned it
read 1.12–1.50x its performance-core times, the efficient-core arm's range
but not benchmark by benchmark (matmul 1.12x against the efficient cores'
1.55x); only pinned to the performance cores did it reproduce the game's T7
numbers, on cells of 1.02–1.18x (nqueens aside) — the ladder's
[evening addendum](results-ladder-2026-09-29.md#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores).
An A/B whose two arms could land on different kinds of core would measure the
placement as much as the allocator. Pinned, base-1 reproduced the earlier P
arm of the same DLL to within 5% on every benchmark but nqueens (binarytrees
0.5391 against 0.5168, matmul 0.1046 against 0.1049, mandelbrot 0.0632
against 0.0661; nqueens 0.4339 against 0.5639). Standalone processes needed
no pin: unpinned, they ran at performance-core speed in the
same addendum.

## In game (T8, 2026-10-03)

The game's side of the A/B above: T8 in
[docs/in-game-tests.md](../docs/in-game-tests.md), run on 2026-10-03 in the
game session that began at 10:20 (the instance's `latest.log`: world joined
10:24:36, screenshot saved 10:25:10, so the run lies between the two), on
this box, in the same world and on the same 16 MB machine as T7, a day and
one game session after it. Checked before this section was written: the only
`ocluajit-*.jar` in the instance's `mods/` is
`ocluajit-d20a14d-master+d20a14d376-dirty.jar` (780 887 B), whose Windows
native is `88b50796…`, the shipping DLL of the gates and of the
fingerprinted A/B above; and the runner on the computer's disk is
byte-identical to the repo's `bench/oc/ingame-ladder.lua` (`a20fdf67`), the
version that loads the file afresh for every rep. Nothing in the game reads
`heap` (the sandbox never sees `_OCLJ_GCSTATS`), so that the game's machine
ran on the arena rests on the jar, not on a reading. Transcribed from a
screenshot of the computer's screen:

```
OpenOS 1.8.9 (16384k RAM)
/home # ./ingame-ladder.lua
machine RAM total=16384 KB free=16133 KB  jit global=false
mandelbrot   CHECK=37904620  min=0.0637 s  reps: 0.064 0.066 0.066 0.065 0.067
matmul       CHECK=481.0000  min=0.0946 s  reps: 0.097 0.095 0.116 0.095 0.097
binarytrees  CHECK=7038400   min=0.4202 s  reps: 0.420 0.424 0.432 0.428 0.426
```

All three CHECKs equal the references. Min of 5, seconds. T7 is the
2026-10-02 run on the pre-arena DLL `bcf8715c…` with the load-once runner
(binarytrees: its first rep, the only comparable one); ship-1 and ship-2 are
the fingerprinted shipping runs in "In the machine"; r1 is plain LuaJIT
(the ladder's, 09-29) and r3l the arena host with the 64 MB accounting
(above), both min of 5 fresh processes:

| benchmark | T8 `88b50796` | T7 `bcf8715c` | ship-1 / ship-2 | T8/T7 | r1 | T8/r1 | r3l | T8/r3l |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mandelbrot | 0.0637 | 0.0626 | 0.0637 / 0.0638 | 1.018 | 0.0650 | 0.980 | 0.0650 | 0.980 |
| matmul | 0.0946 | 0.1031 | 0.0978 / 0.0954 | **0.918** | 0.0800 | 1.183 | 0.0850 | 1.113 |
| binarytrees | 0.4202 | 0.5586 | 0.4295 / 0.4127 | **0.752** | 0.1920 | 2.189 | 0.2370 | 1.773 |

- **The prediction is met.** The expectation T8 printed before the run, if
  the game tracked the pinned harness as it did at T7: binarytrees from
  T7's 0.5586 toward about 0.44 s, matmul toward about 0.095 s, mandelbrot
  not at all. binarytrees read 0.4202 (0.752x; its first rep against T7's
  first, 0.420/0.559, 0.751x), a little below the expectation; matmul
  0.0946 (0.918x); mandelbrot, which makes under 800 allocator calls a run,
  1.018x, inside the 0.0632–0.0671 that the pinned harness's mins of the
  two DLLs spread over in all six of its runs (base-1, base-2, ship-1,
  ship-2, the P arm and the gate run). That is about what the harness
  moved: shipping over pre-arena reads 0.728–0.797 on binarytrees and
  0.866–0.935 on matmul across the two fingerprinted shipping runs and the
  two pre-arena ones (base-1, base-2). Within the 23:07 chain alone
  (base-2) the ranges are 0.728–0.757 and 0.866–0.887: binarytrees' 0.752
  falls inside its range, matmul's 0.918 only with base-1, from the 21:38
  chain.
- **The pinned harness predicted the game again.** binarytrees' 0.4202 sits
  between the two shipping runs' mins (0.4127, 0.4295), mandelbrot's 0.0637
  on them (0.0637, 0.0638), and matmul's 0.0946 0.8% below the faster
  (0.0954), inside the prototype's 0.0942–0.0946. As at T7 it is one game
  run against one chain; the game has now tracked the pinned harness twice,
  on two DLLs.
- **binarytrees' reps are flat**: 0.420, 0.424, 0.432, 0.428, 0.426
  (1.03x), where T7's climbed 0.559 → 0.717 → 0.941 (1.68x). This is
  consistent in game with the ladder's runner-shape finding
  ([binarytrees' reps](results-ladder-2026-09-29.md#binarytrees-reps-the-runners-shape-by-the-standalone-reproduction)):
  standalone, the climb belonged to one loaded chunk called five times, and
  the per-rep runner loads the chunk afresh. Two things changed between T7
  and T8, the DLL and the runner, and this run alone does not separate them;
  but the climb is a within-run shape, and standalone one loaded chunk
  climbed on `lj_alloc` (r2) and on the C library (r3) alike while fresh
  loads did not climb on either, so the allocator is not needed to explain
  it (the arena host itself was not run in the load-once shape). At the
  first rep binarytrees' own chunk is a fresh load in both runs; the runners
  differ in what the earlier benchmarks left in the VM before it (five loads
  each of mandelbrot and matmul at T8, one each, called five times, at T7).
  No arm varied that, and what attributes the first rep's drop to the DLL
  is the pinned harness's A/B (ship over base 0.728–0.797, the first reps'
  0.751 inside it). T8's first rep is also its min — no
  step down after it, as on `lj_alloc` standalone (r2 fresh 0.193–0.210 s),
  where the C-library host's fresh reps had run up to 1.27x faster than its
  first.
- **matmul's third rep read 0.116** against 0.095–0.097 for the other four
  (1.23x the min); one rep, not explained. mandelbrot's reps spread
  0.064–0.067 (1.05x), where T7 printed 0.063 five times.
- **Cumulative against plain LuaJIT** (r1): mandelbrot 0.980, matmul 1.183,
  binarytrees 2.189x, against T7's 0.963, 1.289 and 2.909x. mandelbrot is
  still faster in the game than every standalone process: on the 1 ms clock
  r1's 0.0650 means 0.0640–0.0660, so 0.5–3.5% faster (T7: 2.2–5.2%); not
  explained. Over the arena host the game reads 0.980, 1.113 and 1.773, as
  the pinned prototype did (0.969, 1.113 and 1.737; "In the machine").

**What remains on binarytrees, on both DLLs.** Take the bare host from the
game: T7 sat 0.153 s a run above the C-library host with the cap (0.5586
against the ladder's r3c, 0.4060, 09-29), T8 sits 0.183 s above the arena
host with the accounting (0.4202 against r3l, 0.2370). Both host readings
are one rep per cold process. On the C library that is the host's slow first
run: in one process its later fresh loads ran 0.339–0.375 s (r3, 64 MB; the
ladder's side result, a step of 1.12–1.27x), a step the long-lived machine
may already have paid, and against them T7's remainder would be 0.18–0.22 s.
No arm looked for such a step on the arena host (`luajit.exe` on `lj_alloc`
showed none). The allocator change took its cost out of the host (0.4060 →
0.2370 s standalone) and the game fell with it; an in-machine cost of about
0.15–0.18 s a run over cold host processes (0.18–0.22 s for T7 on the
later-loads reading) remained on both DLLs. Spread over the run's 14.08 M
accounted allocator calls (the standalone count; no in-game count was read),
that is about 11–13 ns a call (up to 16 ns on that reading) — a per-call
equivalent, not a per-call measurement.

Across the benchmarks it grows with allocation. mandelbrot, 472–497 calls a
run, shows none of it (0.980x the arena host); in the game matmul, about
0.82 M calls, sits 0.0096 s above r3l, 11.8 ns a call, against binarytrees'
13.0 ns. Over r3l the pinned harness's shipping runs (ship-1, ship-2) come to
12.5–13.7 ns a call on binarytrees, 12.7–15.7 on matmul and 15.8–19.7 on
strings2 (3.19 M calls), near enough to fit one per-call cost; sieve does
not, at about 210 ns (0.1013 against 0.0860 s over 72.5 K calls), in its own
machine (the sieve machines above armed the emergency collector 640–800
times). The ladder's 09-29 arithmetic (the unpinned harness, the compiler
off, an assumed pure-loop factor) put binarytrees and strings2 2.5–3x apart
per call (19–24 against 48–68 ns) and read that as against a single
per-allocation cost; pinned, with the compiler on, they are 1.2–1.6x apart.
Candidates, none separated by any arm here, and not ranked by these figures,
which any cost that grows with allocation would fit: the JNI crossing on
every allocation — in a machine each accounted call goes through jnlua's
`getthreadenv`, `getluamemory` and `setluamemory`, which the bare host
replaces with plain C accessors on a struct; the machine's arena, long-lived
and already used by OpenOS's boot and the earlier benchmarks, against each
host process's fresh one ("In the machine" names the long-lived heap for the
harness's smaller gain too); the collections binarytrees triggers, which in
a machine traverse a state that also holds OpenOS and the kernel; the
sandbox (OC's replaced builtins, OpenOS's patched globals, the per-resume
watchdog arm/disarm, in-sandbox trace aborts); the JVM. The crossing is
unmeasured: for it to be all of the remainder, a call through the JNI
accessors would have to cost about 11–13 ns more than through the plain C
ones, where the plain-C accounting as a whole costs about 2 ns a call on the
arena (r3l/r3ul, above). The arm that would measure it is a host on jnlua's
real JNI accessors under a JVM, or a batched-publish prototype (the
roadmap's "Benchmark the accounting's cost" row). The first of those has
since run ([the JNI crossing](#what-the-machine-still-pays-per-allocation-the-jni-crossing-2026-10-03),
2026-10-03): in a plain JVM the crossing costs about 0.15 s a binarytrees
run, about 10.6 ns a call more than the plain C accessors (0.149 s against
the matched cell at the mins), and binarytrees with it reads 0.389–0.399 s,
0.024–0.041 s under the machine's mins.
The 0.03 s between T7's and T8's remainders is the machine gaining fewer seconds
than the host — the game
0.138 s, the host 0.169 s — as in the harness ("In the machine": 0.127
against 0.167 s), across two days, two game sessions and two host baselines
(r3c on 09-29, r3l on 10-02). It is no larger than what the choice of T7's
host reading moves: against the later loads the host would gain
0.10–0.14 s, no more than the game's 0.138. The host's first-run step is a
candidate for it, as "In the machine" names it for the harness's gap.

## What the machine still pays per allocation: the JNI crossing (2026-10-03)

Arms for three of the candidates T8's remainder names, run on 2026-10-03,
11:07–11:10, on the same box: two chains, each starting with 0 java
processes, every process launched through `affrun` with the
performance-core mask. Each knob varies one candidate for binarytrees'
0.183 s a run over the arena host at T8 and leaves out everything else a
machine has: a live ballast and a prewarm in a bare host and `luajit.exe`,
the crossing in a plain JVM through jnlua's real JNI accessors. binarytrees
only, the file loaded afresh for every rep. Both
chains time with `os.clock`, which here is the C library's `clock()` (1 ms
steps), as in every standalone table above; the machine's is
`machine.cpuTime` (the ladder's "Two clocks": both wall time).

**Ballast and prewarm, in a bare process.** `residual/residual.lua` builds
an optional LIVE ballast held for the whole run — small tables and strings,
grown until `collectgarbage("count")` reads N KB more than at the start,
with a full collect every 64 entries, then measured after two more full
collects (it read 400 and 1200 to the KB in every process) — so
every collection binarytrees triggers has that much more to traverse, as a
machine's do over OpenOS and the kernel; and an optional prewarm, mandelbrot
and matmul loaded and run five times each first, the in-game runner's order,
so the heap binarytrees allocates into has been used before. 400 KB is about
a machine's resident heap: the harness's b2 milestone read `used` 364 973 and
383 157 B in ship-1 and ship-2 (339 184–444 925 B across the nine chain runs
of 10-02); 1200 KB is three times that. Three arms: the arena host relinked
against the shipping shim object (`residual/ladder_host_ship.exe`
`5a51bef8…`, `lj52shim.o` `e3392678…`) with the 64 MB accounting and with it
off, and our `luajit.exe` (`c6f70712…`, rebuilt by the gates; r2). Two
processes per cell, 5 reps each, every CHECK `7038400`. Min–max over the 10
reps, seconds (`residual/run-1/run.log`, 11:07:21–11:08:16):

| live ballast | prewarm | host, accounting | host, accounting off | r2 `luajit.exe` |
|---:|:---:|---:|---:|---:|
| 0 | — | 0.2370–0.2560 | 0.2060–0.2190 | 0.1930–0.2010 |
| 0 | yes | 0.2330–0.2440 | 0.2070–0.2230 | 0.1940–0.2020 |
| 400 KB | — | 0.2350–0.2450 | 0.2070–0.2210 | 0.1900–0.1980 |
| 400 KB | yes | 0.2340–0.2410 | 0.2100–0.2180 | 0.1920–0.2040 |
| 1200 KB | — | 0.2410–0.2620 | 0.2180–0.2280 | 0.2000–0.2110 |
| 1200 KB | yes | 0.2430–0.2510 | 0.2210–0.2270 | 0.2030–0.2180 |

**The JNI crossing, in a plain JVM.** `residual/jni/JniArm.java` loads the
shipping additive DLL (`88b50796…`, its md5 logged at the chain's start)
with `System.load` into a plain JVM — Temurin JDK 8.0.504, the harness's;
no OC, no OpenOS, no sandbox, no machine thread — and creates the state
through our `LuaStateLuaJIT`, compiled with OC-JNLua's Java sources, as
OC's factory does. `new LuaStateLuaJIT(67108864)` installs jnlua's capped
allocator, which the shim intercepts by turning its own accounting on, so
every allocation calls jnlua's `getthreadenv`, `getluamemory` (two
`GetIntField`s) and `setluamemory` (one `SetIntField`) through JNI
(`lj52_alloc`); `new LuaStateLuaJIT()` leaves the accounting off, and
nothing crosses per allocation. The arm opens whichever of jnlua's
libraries the native accepts, hands the benchmark sources in as a global,
and runs `jnidriver.lua`, `residual.lua`'s loop without ballast or prewarm,
on the JVM's main thread through `L.call`. Every JVM read `_OCLJ_GCSTATS`
`heap = 1` and every CHECK was `7038400`; at the end the accounting JVMs'
`getFreeMemory()` read 66 844 386–66 954 214 of 67 108 864 (the shim
publishing into jnlua's fields), the others 0 of 0. Three JVMs per arm,
alternating; min/max of each JVM's 5 reps, seconds
(`residual/jni/run-2/run.log`, 11:09:59–11:10:09):

| arm | JVM 1 | JVM 2 | JVM 3 | all 15 reps |
|---|---:|---:|---:|---:|
| accounting on, `LuaStateLuaJIT(67108864)` | 0.3920/0.3990 | 0.3890/0.3970 | 0.3900/0.3970 | **0.389–0.399** |
| accounting off, `LuaStateLuaJIT()` | 0.2180/0.2220 | 0.2130/0.2220 | 0.2090/0.2140 | **0.209–0.222** |

A first attempt (`residual/jni/run-1/`, 11:09:16) stopped in every JVM at
jnlua's `openLibs()` with `illegal library`: the native accepts only OC's
set. It is recorded here, not a measurement.

- **Ballast and prewarm move binarytrees by a few milliseconds.** With 400 KB,
  with the prewarm, or with both, every arm's min is 0.983–1.019x its min
  with neither (−0.004 to +0.004 s), every pair of cells overlapping. 1200 KB
  costs 1.017–1.068x against no ballast at the same prewarm setting
  (0.004–0.014 s; one pair of the six disjoint, r2 with the prewarm). As
  this run reproduces them, collections over a resident heap of a machine's
  size and a heap the earlier benchmarks have used account for at most
  about 0.004 s of the 0.183 s, and 0.014 s at three times the size.
- **In a plain JVM, the crossing is most of the rest's size.** In the JVM
  the accounting costs 0.180 s a run at the mins (0.389 against 0.209;
  0.167–0.190 across the reps), 12.8 ns a call (11.9–13.5) over
  binarytrees' 14.08 M accounted calls (the host's count, 70.38–70.39 M
  gets per five-rep process without the prewarm). In the bare host the same
  pair, on plain C accessors, is 0.031 s at the mins with neither ballast
  nor prewarm (0.022–0.031 s across the six cells; 2.2 ns a call, as
  r3l/r3ul's 0.028 s on 10-02). Net of that, the JNI crossing costs about
  0.15 s a run: 0.149 s against that matched cell at the mins, 10.6 ns a
  call; with both pairs' spreads in that cell (JVM 0.167–0.190 s, host
  0.018–0.050 s), 0.117–0.172 s, 8.3–12.2 ns — near the 11–13 ns T8 said it
  would need to be all of the remainder.
- **The JVM adds nothing measurable with the accounting off**: 0.209–0.222 s
  against the bare host's 0.206–0.219 (mins 1.015x, cells overlapping).
  Loading the native into a JVM and driving the state through jnlua's Java
  layer costs about 0.003 s here, no more, when nothing crosses per
  allocation.
- **About 0.03 s remains.** The JVM with the accounting (0.389–0.399) sits
  0.024–0.041 s under the machine's binarytrees mins: the pinned harness's
  shipping runs, 0.4127 (ship-2) and 0.4295 (ship-1), and T8's 0.4202
  (0.031 s). Of T8's 0.183 s over the arena host (r3l, 0.2370; this run's
  accounting min reads 0.2370 too), the JVM arm reproduces 0.152 s (0.389
  − 0.237). The other 0.024–0.041 s is unseparated (min to min; against the
  JVM arm's max, 0.399, it is 0.014–0.031 s, and ship-1 and ship-2 alone
  differ by 0.017 s); its candidates are the sandbox, OpenOS, the machine's
  executor and coroutine resume, the per-resume watchdog and the rest of
  T8's list; the ballast arm puts collections over a resident heap of
  OpenOS's size at about 0.004 s of it at most, as reproduced.

What these arms do not say:

- **That the machine pays the same 0.15 s is inferred**, from the JVM arm's
  agreement with the machine, not measured in a machine: no machine has run
  without the crossing. A batched-publish prototype in the machine would be
  that arm; the roadmap's "Benchmark the accounting's cost" row carries the
  proposal and its open questions.
- **One arm per candidate, one benchmark, one box**: n = 3 JVMs per arm and 2
  processes per ballast cell. The other allocating benchmarks were not run
  through the JVM: over r3l, matmul's in-machine cost comes to 11.8 ns a
  call at T8 and 12.7–15.7 in the harness, strings2's to 15.8–19.7 in the
  harness, against binarytrees' 12.5–13.7, and how much of each the same
  crossing is was not measured; sieve's ~210 ns is far beyond it and still
  not explained.
- **The 14.08 M calls are the bare host's count**; the JVM arm read none, and
  its per-call figures assume the same benchmark makes the same calls there.
  Netting the host pair from the JVM pair assumes the accounting's
  arithmetic costs the same in both: the same `lj52_alloc`, handed different
  accessors.
- **The two proxies are proxies.** The ballast is small tables and strings,
  not OpenOS's mix of closures, prototypes and strings; its size is LuaJIT's
  own count after two full collects, where b2's is the accounted `used` at
  boot, and a machine's live heap at binarytrees' turn was not read. The
  prewarm is two benchmarks in a fresh process, not OpenOS's boot and a
  machine's life.
- **The bare host read no `heap`.** No build log for `ladder_host_ship.exe`
  is on disk; that it ran on the arena rests on its link and on its times
  (accounting 0.2370 at the min, r3l's on 10-02 exactly; accounting off
  0.2060 against r3ul's 0.2090 and the C-library host's 0.3730). The JVM
  arm read `heap = 1`.
- **Neither chain read affinity back.** The host chain sent `affrun`'s
  stderr to `/dev/null` and the JVM chain's log keeps only the benchmark's
  lines; that every process ran on the performance cores rests on the mask
  and on the times (the JVM with the accounting off reads like the bare
  host, and the bare host like r3l and r3ul).
- **The JVM arm is not a machine in other ways**: the benchmark runs on the
  JVM's main thread through `L.call`, not in a coroutine a machine thread
  resumes; no watchdog is armed; the cap is 64 MB, as r3l's, where the
  harness's machine has about 3.5 MB (b2's `totalMemory`) and T8's 16 MB; and
  which libraries opened is not logged (the run script kept only the `FP`,
  `REP` and `JVM` lines; `os` was among them, since the driver found
  `os.clock`). Nor is the JIT state: the JVM arm logged none (the host's
  `HOST end` lines read `jit=on`). By the source nothing in `JniArm`, the
  driver or `LuaStateLuaJIT` sets it, so it is the same in both JVM arms and
  the on/off pair is unaffected; that the JVM with the accounting off reads
  like the bare host suggests it was on.
- **A 1 ms clock.** Every time in this section is a whole number of
  milliseconds; the ballast and prewarm readings at 400 KB are up to four
  ticks.

### What each part of the crossing costs: three prototypes (2026-10-03)

Three scratch copies of the shim, each built into its own DLL by
`build-native.sh` (`OCLJ_SHIM`/`OCLJ_BUILD` in the scratchpad; the repo was
not touched), timed in the same JVM arm (binarytrees, 64 MB cap, 5 fresh
loads per JVM, 3 JVMs per variant, round-robin, pinned; `jnivar/run-1/run.log`,
11:13-11:14) and run against `mem_test` (`OCLJ_SHIMOBJ` = each variant's object):

| variant | per allocation | binarytrees, s | mem_test |
|---|---|---:|---|
| shipping `88b50796` | `getthreadenv` + 2 `GetIntField` + 1 `SetIntField` | 0.385-0.397 | 29/0 |
| A `d746243e` | `getthreadenv` + 1 `SetIntField`; total/used cached, re-read every 4096 calls and before refusing | 0.354-0.383 | 29/3: M6b, P1a, P2a |
| B `4735055a` | A, publishing `used` only after 1 KB of drift | 0.296-0.303 | 29/6: + M3b, M4c, M7 |
| C `a9e7390e` | B, calling `getthreadenv` only when a read or publish is due | 0.250-0.259 | 29/6: as B |
| shipping, accounting off | none | 0.208-0.218 | - |

By difference, of the ~0.18 s: the two reads ~0.03 s, the write ~0.06 s,
`getthreadenv` ~0.05 s, and the accounting arithmetic and the cache ~0.04 s
(the bare host's on/off pair is 0.022-0.031 s). The failures are the point:
A's cached total misses the caps `mem_test` sets from the Java side between
steps, so the cap was not tight (M6b) and the emergency collector never armed
(P1a, P2a: `used` read past `total` because `total` was stale) -- the same
thing OC does around every save (`setTotalMemory(Int.MaxValue)` and back).
B and C add a `freeMemory` up to 1 KB stale (M3b, M4c, M7 read the Java field
right after an allocation). So a per-allocation cache is not shippable as
built; the precise variant needs `total` read and `used` published at every
boundary where Java can write or read them (the proposal in the roadmap's
accounting row), and C's 0.25 s is what that would be worth on binarytrees if
the boundaries cost nothing.

## Where it loses

Two synthetic loops, `bigchurn.lua` and `smallchurn.lua`
(`ljalloc/churnbench/`), five fresh processes each, min–max seconds:

| workload | r2 `luajit.exe` | C-library host (r3, 64 MB accounting) | arena host (r3l) | CHECK |
|---|---:|---:|---:|---|
| bigchurn: 400 x (256 KB string + 64 K-slot array) | 0.1890–0.2260 | 0.1300–0.1410 | 0.1870–0.2250 | `131152200` |
| smallchurn: 40 000 x (4 KB string + 512-slot array) | 0.0410–0.0430 | 0.0480–0.0500 | 0.0410–0.0430 | `184439997` |

By the source, `lj_alloc` maps a request of 128 KB or more directly from the
OS when the arena's free chunks and top cannot hold it, and unmaps it when it
is freed (`alloc_sys`, `DEFAULT_MMAP_THRESHOLD`): the candidate for what
follows, since no arm varied the block size or the threshold. Both of
bigchurn's blocks are past that line, and there the arena runs 1.44x the
C library at the min (1.44–1.60x across the cells), as plain `luajit.exe`
does: it is `lj_alloc`'s behaviour, not the shim's. The same loop on small
blocks runs 1.17x faster on the arena. No benchmark of the eight lost on the
arena (r3l/r3 0.379–1.001); how often OpenComputers programs churn blocks of
128 KB or more is not counted here.

From the review, from the source, **not measured**:

- each machine's arena keeps roughly its peak size until the machine
  closes: on Windows `CALL_MUNMAP` releases only whole regions, and
  `release_unused_segments` never frees the first segment;
- memory one machine frees is no longer reusable by another machine in the
  same process, where the C library's heap was shared by all of them;
- each machine's arena starts with a 128 KB first segment.

The accounting counts requested sizes, so none of this is charged to a
machine's RAM cap, as the C library's own overhead was not; it is the host
process's resident memory.

A possible follow-up, not built: a size split — blocks of 128 KB or more to
the C library and the rest to the arena, chosen by `osize`, which LuaJIT
always passes exactly, with a move from one to the other when a resize
crosses the threshold.

## The gates, and every check seen to fail first

The second gate run (`ljalloc/gates2/summary.txt`, 22:07–22:16), on the
working tree with the review's fixes applied:

| gate | result | seen to fail first |
|---|---|---|
| Windows native (additive) | DLL `88b50796…`, `lj52shim.o` `e3392678…`, warning-clean, serializer hash `8c5a1168` unchanged | — |
| `nm -u` arena-symbol check (`build-native.sh`) | all five referenced, Windows and Linux | on the pre-arena object `8ef84b32…`: 0 of 5 found |
| `LUAJIT_USE_SYSMALLOC` refusal (`build-native.sh`) | passes (flag absent) | **not run against a build with the flag** |
| Linux native via WSL | `.so` `c1a9d865…`, warning-clean, same serializer hash | — |
| jar | `build/libs/ocluajit-d20a14d-master+d20a14d376-dirty.jar`, 780 887 B, carrying exactly those two natives and kernel `089dcbde` | — |
| `mem_test` | 29/0; M0, M0b, M0c PASS with `heap=1` | on the pre-arena object: exactly M0/M0b/M0c FAIL, `heap=-1`; on a sabotaged shim whose arena is never created: exactly M0/M0b/M0c FAIL, `heap=0`, while **every accounting check passes** on the C-library fallback — the reason M0 exists |
| watchdog unit test | 35/0 | — |
| penalty-cache test | 6/0 | — |
| race, security, shim_test | 2/0, 37/0, 57/0 | — |
| harness, JIT on, pinned | 57/0, `al-1` PASS `14:1` | with the pre-arena DLL `bcf8715c…`: exactly `al-1` FAIL, `13:nil` ("a 13-value _OCLJ_GCSTATS: a native from before the arena change") |
| harness, JIT off, pinned | 55/0, `al-1` PASS | — |
| harness, sieve only, pinned | 51/0, `al-1` PASS; four reps | — |
| harness, stock PUC | 41/0, `al-1` SKIP | — |

- race, security and shim_test ran against a scratch mirror of the old
  `obj/` layout, because `run.sh`, `run-race.sh` and `run-security.sh` still
  look for `$OCLJ_BUILD/obj` and `luajit/src`, stale since the per-platform
  build move; this change does not fix that.
- The `LUAJIT_USE_SYSMALLOC` refusal is the one new check not seen to fail.
- gates2 began with 2 java processes alive: the idle Gradle daemons left by
  the first gate run's jar build.
- **The first gate run** (`ljalloc/gates/summary.txt`, 21:50–22:00; the
  onehalf run and the pre-arena tier-one control, 22:00–22:03, are in
  `ljalloc/gates/h-h-new-tier-onehalf/` and `h-g-pre-tier-one/`, not in the
  summary), before the review's fixes — DLL `cf33778f…`, shim object
  `f1333880…`, `.so` `f5aba579…`; `mem_test` then had M0 alone (27/0, and M0 failed first on the
  pre-arena object) — gave the same results, plus two harness runs at small
  RAM tiers: tier one 57/1 and tier onehalf 57/2. Those failures are
  `SKIP-LOWMEM` rows, which the harness counts as milestone failures:
  p1-strings2 at tier one (261 KB free against the 504 KB it needs), and at
  onehalf p1-strings2 and p1-matmul (348 KB < 504 KB, 337 KB < 368 KB). The
  control with the pre-arena DLL at tier one skipped strings2 too (392 KB <
  504 KB), so the tier-one strings2 refusal is pre-existing. The onehalf
  matmul refusal had no pre-arena control, and the free figure the guard read
  at tier one was 131 KB lower on the arena (261 against 392 KB, one run
  each; not examined), so whether the arena moves small-tier refusals is
  open.
- **What the review changed between the two runs:** the arena pointed at the
  stack PRNG as soon as it is created; `lj52_close` turning the accounting
  off and clearing `javaref` before `lua_close`; the fallback's comments
  saying what it really does; `al-1`'s message per wrong reading and its
  SKIP on stock; M0b and M0c; and the `nm -u` and `LUAJIT_USE_SYSMALLOC`
  checks with the corrected stage-1b text in `build-native.sh`. The
  prototype measured in the two A/B sections above had none of these and
  returned 13 values from `_OCLJ_GCSTATS`. Its missing early PRNG pointer
  does not touch those timings: by the source, Windows never consults the
  PRNG.

## What this does not say

* **One in-game run on the arena.** T8 ([In game](#in-game-t8-2026-10-03))
  is one game session against one fingerprinted chain, a day after T7 and
  with the runner changed as well as the DLL (the standalone runs put
  binarytrees' later reps on the runner; at its first rep the runners differ
  in what the earlier benchmarks left in the VM, which no arm varied).
  Nothing in the game reads `heap`, so that the game's machine ran on the
  arena rests on the jar. The 0.15–0.18 s a run the game pays over cold
  bare-host processes on binarytrees, on both DLLs (0.18–0.22 s for T7
  against the C-library host's later loads), is not separated; the JNI
  crossing, the machine's long-lived arena and collections over the OpenOS
  heap are among its candidates, none measured and none ranked. Since
  measured outside a machine, for T8's 0.183 s on the arena DLL
  ([the JNI crossing](#what-the-machine-still-pays-per-allocation-the-jni-crossing-2026-10-03)):
  the crossing at about 0.15 s in a plain JVM; a live 400 KB ballast and a
  prewarmed arena at a few milliseconds, as a bare host reproduces them. No
  arm ran on the C-library DLL (T7's), where the host's first-run step is
  1.12–1.27x; in a machine none is separated yet.
* **Resident memory across many machines is unmeasured.** The review's three
  notes (each arena held near its peak until close, no reuse across machines,
  a 128 KB first segment per machine) come from the source; no run here had
  more than one machine in a JVM.
* **proto-1's `arms=54`** in a seven-benchmark boot that read 0 on every
  other tier-threehalf seven-benchmark run, baseline or arena, is not
  explained.
* **The unaccounted fallback is pre-existing and kept.** A state whose
  `lua_newstate` fails still comes back from `luaL_newstate` with no
  accounting record; `_OCLJ_GCSTATS` then reads `heap = -1` and the
  harness's b2 and `al-1` fail. Whether it should return NULL is open.
* **aarch64 was not built.** The change was built for Windows x64 and Linux
  x64 only, and nothing in the gates ran on Linux beyond the build and its
  symbol check.
* **The prototype runs carry no fingerprint.** The standalone A/B and the
  in-machine chain ran the prototype, which returned 13 values; that they
  ran on the arena rests on the build (the object calls `lj_alloc_f`
  whenever the arena exists, and a failed arena falls back silently) and on
  the timings, not on a reading. The shipping runs read `heap = 1`.
* **The shipping in-machine column ran beside two idle Gradle daemons**
  (gates2 began with 2 java processes); the prototype and baseline chain
  began with 0.
* **The gate runs carry no placement fingerprint** (the fingerprinted
  shipping A/B in "In the machine" was run afterwards to close this).
  `gates.sh` and
  `gates2.sh` started every harness run through `affrun` with the
  performance-core mask, sent affrun's stderr (its one line saying what it
  applied) to `/dev/null`, and never read the java process's affinity back;
  only the chain runs here and the ladder addendum's three arms read it
  back. The shipping column is such a run. (gates2's stock-PUC run, which
  kept affrun's stderr, logs `effective=0xC03C03` for affrun's child.)
* **sieve's shipping row is four reps**, not five (`PHASE1 ROW` n = 4,
  `arms=640`); why the harness ran four was not examined.
* **The host's remainder on binarytrees (r3ul/r2 1.077)** and **the
  machine's smaller gain on binarytrees and sieve** are not separated.
* **n = 5, min taken, one box**; the standalone A/B unpinned, on a 1 ms
  clock.

## Files

All under this session's scratchpad
(`%LOCALAPPDATA%/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-…/scratchpad/`),
none of it committed. md5, first eight hex digits:

- The prototype and the standalone A/B: `ljalloc/make-proto.py` `c170ac48`
  (copies `native/lj52shim.c` to `ljalloc/lj52shim.c` `912107bc` with the
  arena added), `ljalloc/build-and-measure.sh` `b2bd24af`,
  `ljalloc/lj52shim-lj.o` `36e4b93b`, `ljalloc/ladder_host_lj.exe`
  `75a061ea`; `ljalloc/run-1/build.log` `92854ec2` (every binary's md5),
  `smoke.log` `c245ce91` (every host line, the get/set counts),
  `raw.tsv` `604261f5` (the 200 rows); `ljalloc/summarize.py` `9a340746`.
  The C-library host is the ladder's `pf/T/ladder_host.exe` `cc6e8509`.
- The churn loops: `ljalloc/churnbench/bigchurn.lua` `73ff5993`,
  `smallchurn.lua` `6a8c81a7` (with `compat.lua` `e8684d9c`). Their times
  are transcribed in the session's data notes, `docs-data-2026-10-02.md`
  (section C2); no run log for them was found on disk.
- The prototype in the machine: `ljalloc/build-dll.sh` `8120c571`
  (`build-native.sh` with `OCLJ_SHIM`/`OCLJ_BUILD` in the scratchpad;
  `ljalloc/build-dll.log`), the DLL
  `ljalloc/build/libdir-additive/libjnluajit52-windows-x86_64.dll`
  `324c3aaa`; `ljalloc/chain-machine.sh` `f5ee8df5`,
  `ljalloc/chain-machine.log` `1415342c`, and `ljalloc/h-proto-1/`,
  `h-base-1/`, `h-proto-2/`, `h-proto-sieve/`, `h-base-sieve/` (each
  `run.log`, `native.md5`, `exit.txt`, `started.txt`, `finished.txt`).
  Pinning: `pcore/affrun.exe` `fc08cf01` (source `affrun.c` `79e7f120`).
- The pre-arena controls: `ljalloc/old/lj52shim-pre.o` `8ef84b32`,
  `ljalloc/old/libdir-additive/libjnluajit52-windows-x86_64.dll`
  `bcf8715c`; the sabotage: `ljalloc/make-noarena.py` `a6abad2a`,
  `ljalloc/noarena/lj52shim.c` `643ff8f9`, `lj52shim-noarena.o` `5eea99bc`.
- The shipping change: `ljalloc/ship-patch.py` `317ff535`,
  `ljalloc/ship-harness.py` `bbc3d490`, `ljalloc/review-fixes.py`
  `2b66af86`; the result is the repo's working tree (`native/lj52shim.c`,
  `native/lj52shim.h`, `native/build-native.sh`, `test/native/mem_test.c`,
  `test/native/OcljSmoke.scala`).
- The gates: `ljalloc/gates.sh` `1437000d` with `ljalloc/gates/summary.txt`
  `dfa3215a` and per-step logs and harness runs under `ljalloc/gates/`;
  `ljalloc/gates2.sh` `3c4fc52b` with `ljalloc/gates2/summary.txt`
  `6c22f01d` and the same under `ljalloc/gates2/`.
- The JNI-crossing section (2026-10-03), under `residual/`: `residual.lua`
  `8758aaec`, `run-ab.sh` `342c2058`, `summ.py` `cf24219d` (the per-cell
  min–max), `ladder_host_ship.exe` `5a51bef8` (no build log on disk),
  `run-1/run.log` `b01b5c3c`; `jni/JniArm.java` `445221f9` and
  `jni/jnidriver.lua` `f2656e9d` (the versions run-2 compiled and ran;
  run-1's `JniArm` called `openLibs()` and drove `residual.lua`),
  `jni/build-run.sh` `93d48695` (run-1), `jni/build-run2.sh` `0610192e`
  (run-2), `jni/sources.txt` `b76a3fa1` (the 25 sources compiled),
  `jni/run-1/run.log` `b4c828d6` (the failed attempt), `jni/run-2/run.log`
  `aa3ad46b`. `luajit.exe` `c6f70712` is the repo's build output
  (`build/native/luajit-windows-x86_64/src/luajit.exe`), not committed.
- Repo outputs of the gates, not committed:
  `build/native/libdir-additive/libjnluajit52-windows-x86_64.dll`
  `88b50796`, `build/native/obj-windows-x86_64/lj52shim.o` `e3392678`,
  `build/native/dist/libjnluajit52-linux-x86_64.so` `c1a9d865`, and the jar
  above.
