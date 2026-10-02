# The allocator rung, answered — every machine's blocks in LuaJIT's own allocator

Date: 2026-10-02, 21:36–22:16, on the box of
[results-ladder-2026-09-29.md](results-ladder-2026-09-29.md) (Intel Core Ultra
9 285HX: 8 performance and 16 efficient cores, no SMT; Windows 11 Pro), with
Minecraft closed (0 `javaw` processes) for every timing below. This document
answers the question that ladder's section 2 left open, describes the change
the answer led to, and records the gates the change passed. Every in-machine
timing here was taken with the harness JVM launched pinned to the performance
cores, for the reason in the ladder's
[2026-10-02 evening addendum](results-ladder-2026-09-29.md#addendum-2026-10-02-evening-the-harness-was-on-the-efficient-cores);
the java process's affinity was read back on the chain runs, not on the gate
runs ("What this does not say").
Every number is in a file under this session's scratchpad (Files, at the end;
the churn times survive only in the session's data notes there).
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

* **No in-game number yet.** T8 in
  [docs/in-game-tests.md](../docs/in-game-tests.md), the in-game run on the
  shipping jar, has not been made. If the game tracks the pinned harness as it did at T7
  (mandelbrot 0.0626 against 0.0661, matmul 0.1031 against 0.1049,
  binarytrees 0.5586 against 0.5168), binarytrees would move from T7's
  0.5586 toward about 0.44 s, matmul toward about 0.095 s, and mandelbrot
  not at all. That is an expectation, not a measurement.
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
- Repo outputs of the gates, not committed:
  `build/native/libdir-additive/libjnluajit52-windows-x86_64.dll`
  `88b50796`, `build/native/obj-windows-x86_64/lj52shim.o` `e3392678`,
  `build/native/dist/libjnluajit52-linux-x86_64.so` `c1a9d865`, and the jar
  above.
