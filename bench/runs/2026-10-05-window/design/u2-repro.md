# u2: the residual reproduced hermetically (a refusal at a credit tier's top lands outside the handler)

Survey and prototype for the roadmap row "A refusal at a credit tier's top can land outside the program's handler" (docs/roadmap.md:159). Everything runs against the stage-C object (`wall2/objC/lj52shim.o`, md5 `0259f0d1`), with no JVM. The repo was only read. All work is in `wall2/repro/` (paths below are relative to it).

## Summary

- **Reproduced, deterministically.** The program is the capacity probe's shape: a fill inside `pcall`, plus the probe's between-batch allocations (stage string, `event.timer` record, `pcall(paint)`), run as a sandbox coroutine that the kernel resumes under `_OCLJ_WATCHDOG.arm`.
  - Over 16 384 caps (4 shapes × cap offsets 0..65 535 B, 16 B apart), **431 runs (2.63 %) refused outside the batch's handler**:
    - 219 "stalls": the refusal escaped `step()` into the dispatcher's `pcall`.
    - 212 "sandbox down": the dispatcher's own allocation was refused and the coroutine died.
  - The remaining 15 953 runs refused inside the handler.
  - Stock PUC 5.2.4 running the same program over the same 16 384 rooms: **0 outside**. The same holds in every variant: 0 in all 90 112 PUC runs across 10 sweeps.
- **Every outside refusal was one garbage would have covered.** This held for all 431 runs:
  - A site pass ran two full collections immediately *before* the refused allocation, in a deterministic re-run, frames included.
  - The live set it found plus the **whole** object fits under the tier's top with 100 to 1 140 B to spare.
  - At the refusal, garbage was 212 to 1 208 B.
  - Each outside refusal was the run's **first** refusal (`refusals = 1`). All were in the burst tier (G/2 = 16 384 B past the cap), with the live data already 15 252 to 16 076 B past the cap.
- **Exact deterministic reproducers.** Twelve (shape, offset) pairs are listed below, each giving the same outcome:
  - in two fixed-seed runs (byte-identical output);
  - in **20 of 20** runs of the unwrapped binary, which has a random string-hash seed.
  - Example: `lj_repro_Cf.exe probe2.lua record 10816 10816 16 384 0 1 1 0 0 -1` gives a stall at the stage string (a 40 B request). `top - used` = 12 B, garbage = 304 B.
- **Three proximate mechanisms**, all allowed by the cadence (traced with an allocator ring):
  - **M1:** the last cycle runs at a checkpoint *inside* the batch, while the batch's churn is still in its frame, and frees nothing. The batch returns. The next allocate-first request (the stage string, or `lj_tab_dup`'s hash part) does not fit, and the cadence never re-arms at `used == gc_low`.
  - **M2:** the same, but the request arms on its first part (the record's 64 B `GCtab`) and is refused on its second (the 192 B hash part), with no checkpoint between.
  - **M3:** between resumes, the kernel spends its 16 KB slice near the sandbox's top without arming. The sandbox's first allocation (the dispatcher's `table.pack`) is refused.
- **The PUC-like rule on LuaJIT's own trajectory** (an uncapped run, live set measured at every marker) places **0** refusals definitely outside. A band of 0.6 to 1.0 % of caps is ambiguous between inside and outside. This holds at the cap and at our top alike.
- **Proposed test: mem_test W16 (code below).** Against the stage-C object it **FAILS in 30 of 30 random-seed runs**: 6 or 7 covered stalls among 96 caps, and the other 68 checks pass. A control with every program allocation inside a handler **passes 10 of 10**.

## 1. What was built

| file | what |
|---|---|
| `probe2.lua` | The probe program (Lua; runs on both runtimes). Faithful to `test/native/OcljSmoke.scala:3143-3210`: makers, `BATCH = 100`, `uniq(24, count) .. "!"` churn, `pcall(paint)`, `stage = "filling/" .. count`, `event.timer(0, step)`. It is modelled as a 5-field handler record. A dispatcher `table.pack(coroutine.yield())` sits outside any handler, and a kernel loop does `arm`, `resume`, `table.pack`, `disarm`. `os.clock` is replaced by a constant, because a varying formatted string is a varying interning hit. Site hooks (`msite`) and measurement hooks are inert unless set. |
| `lj_repro.c`, `build.sh` | The driver, linked exactly as `test/native/run-mem.sh:83-88` links mem_test: `-include lj52shim.h`, the given `lj52shim.o`, the build's `eris_lj.o` and `libluajit.a`. Builds: `_C` (stage-C object), `_Cf` (stage-C object with a fixed string-hash seed), `_I`/`_If` (instrumented), `_Rf` (with the ring). Fresh state per run, C mode (`OCLJ_LEGACY=1` stays legacy), JIT off unless asked, `cap = base + 384 KB + off`. One TSV line per run. |
| `mkinstr.py`, `mkring.py`, `mkfull.py` | Instrumented **copies** of `native/lj52shim.c`. They record the refused request's delta and the record's state at the refusal (`oclj_ref_*`), a ring of the last 256 allocator calls, and a full delta log. No branch of the logic changes. |
| `sitepass.py` | Re-runs each outside run with the site hook set at the refused allocation's site. Collects twice there and reads the live set. |
| `puc_repro.c`, `puc/` | Stock PUC 5.2.4 (`JNLua-Natives/lua/src`, unmodified, `-DLUA_COMPAT_ALL` as its Makefile builds it). It uses jnlua's `l_alloc_checked` rule (OC-JNLua `native/src/jnlua.c:251-288`: refuse when `total - used < delta`). `luaM_realloc_` then runs `luaC_fullgc(L, 1)` and retries (lmem.c:85-93). |
| `traj.c`, `probe3.lua`, `model.py` | The PUC-like model on LuaJIT's trajectory (§6). |
| `mem_test_w16.c` (`mem_test_w16.diff`), `w16_chunk.c.txt`, `w16_case.c.txt`, `mkw16.py` | The proposed W16 case, inserted into a copy of `test/native/mem_test.c` after W11. |
| `w16probe.lua` | The W16 program in probe form, for both drivers. |
| `out*/` | Every measurement. Nothing was cleared; each pass went to a fresh directory. |

**Object identity.** Compiling the repo's `native/lj52shim.c` (last changed in 85faa0e) with build-native.sh's line (native/build-native.sh:557-559), plus `-DLJ52_ADDITIVE`, reproduces `0259f0d14032e4920e7e7b110d102f62` **byte for byte** (`shim_plain.o`). The object is the additive variant: it defines both `ocljUsedMemory` and `ocljSetTotalMemory`. So the instrumented copies are the stage-C shim plus recording only.

**Instrument check.** The instrumented binary and the stage-C binary give identical values in every column they share (shape … live, refusals, collects, arms, bailouts, odpeak, batches) for all 16 384 runs (`out5/If_a.tsv` vs `out5/Cf_a.tsv`).

**Determinism.**
- The one source of run-to-run variation is LuaJIT's string-hash seed. It is drawn from a secure PRNG (lj_state.c:257, lj_str.c:367) and changes the incremental collector's sweepstring progress, and so the collect counts.
- `-Wl,--wrap=lj_prng_seed_secure` with a fixed seed (`OCLJ_SEED`, default 1) makes reruns byte-identical (`out4`, `out5`: `Cf_a == Cf_b`, md5 `e3010561`).
- Unwrapped, the classification still moves by at most 4 runs per 4 096 (`out5/C_rand.tsv`: record 12/31 against 12/35; the other shapes identical).

## 2. Counts per variant, stage-C object

Default configuration: JIT off, sandbox under the arm, paint on, no heartbeat, `capk = 384`, junk 24, `BATCH = 100`, offsets 0..65 535 step 16 (4 096 per shape), seed 1. Cells read inside / stall (outside, caught by the dispatcher) / sandbox down (the dispatcher's own allocation), of 4 096 runs.

| variant | record | array | string | closure | outside total |
|---|---|---|---|---|---|
| **default** (`out5/If_a.tsv`) | 4049/12/35 | 4043/30/23 | 3843/132/121 | 4018/45/33 | **431 (2.63 %)** |
| default, random seed (`_C`) | 4053/12/31 | 4043/30/23 | 3843/132/121 | 4018/45/33 | 427 |
| legacy (dropin) path | identical to C mode, byte for byte (md5 `93c7401e`; 19 704 JNI round-trips per run confirm the mode) | | | | 431 |
| no `pcall(paint)` | 4082/13/1 | 4072/24/0 | 3953/132/11 | 4057/39/0 | 220 (1.34 %) |
| heartbeat every 3rd resume | 4054/11/31 | 4043/30/23 | 3832/132/132 | 4017/45/34 | 438 (2.67 %) |
| control: stage + timer inside the batch's pcall | 4070/0/26 | 4080/0/16 | 4008/0/88 | 4075/0/21 | 151 (0.92 %): no stalls left; the dispatcher site remains |
| JIT on (deterministic with the seed fixed) | 4039/18/39 | 4042/26/28 | 3714/203/179 | 4044/30/22 | 545 (3.33 %), including 37 "1,2" (see §4) |
| no watchdog arm (every allocation gets the kernel's slice) | 4064/15/3 + kernel 14 | 4058/30/0 + 8 | 3931/121/11 + 33 | 4058/30/0 + 8 | 273, of which 63 are the kernel's own refusals (status ≠ 0) |
| junk 8 / 16 / 32 / 48 / 64 / 96 (offsets 0..16 383, 1 024 per shape) | | | | | 135 / 168 / 119 / 88 / 58 / 56 (3.3 % → 1.4 %; record has 0 at junk ≥ 32 in this range) |

**Stock PUC 5.2.4** on `probe2.lua`, same rooms, every variant run (default, no paint, control, hb3, 6 junk lengths): **0 outside in 65 536 + 24 576 runs**, every run `1,6`. In PUC the batch-boundary window shows up first as a refused stack growth (an 800 B request) in `pcall(paint)`. It is swallowed, and the next batch is refused inside (`3,1,6`, record off 45 776..45 968; `out6/puc_a.tsv`).

The real matrix (bench/results-wall-2026-10-04.md:436-455, 597-598) read 4 of 68 runs on stage B and 1 of 49 on stage C, against 0 of 40 on stock. The hermetic rate of 1.3 to 3.3 % is the same order.

## 3. Would a collection at that moment have made room? (all 431 outside runs)

`sitepass.py` → `out5/site_If.tsv`. Site from the refused delta: 40 B is the stage string (site 1); 64/192 B is the timer record's `GCtab`/hash part (site 2, whole object 256 B); 80/48 B is the dispatcher's `table.pack` table/hash part (site 3, 128 B). "Slack" is `top - live_at_site - whole_object`.

| shape | stall: site1 / site2 (armed at refusal) | down: site3 (armed) | covered | garbage at refusal (stall / down) | slack min / median / max (stall / down) |
|---|---|---|---|---|---|
| record | 4 / 8 (6) | 35 (9) | **47/47** | 212-344 / 592-1208 | 108/276/292 · 428/668/1140 |
| array | 6 / 24 (7) | 23 (4) | **53/53** | 212-344 / 716-856 | 100/268/340 · 468/756/852 |
| string | 22 / 110 (22) | 121 (33) | **253/253** | 212-400 / 592-856 | 116/268/356 · 468/708/852 |
| closure | 9 / 36 (11) | 33 (9) | **78/78** | 212-344 / 716-856 | 100/268/340 · 468/756/852 |

Every outside refusal was the run's first (`refusals = 1`), in the burst tier (`tier = 0`), in sandbox context (`kernel = 0`). Each had the live set past the cap: `covered_cap = 0`, so at those live sizes the request would not have fit under the cap itself. Stock would have refused earlier, when its live data reached the cap; see §6 for where that lands. `od_peak` was 16 196-16 680 B.

For comparison, inside refusals (measured at the inner catch, which excludes the frame's transients, so this is an upper bound on "covered"):
- **record and string: all garbage-covered.**
- **array and closure: 996 and 994 not covered.** These are `held`'s array doubling at count 2048, a single 16 384 B request (`out5/If_m1.tsv`), refused by stock as well.

## 4. The mechanism (allocator ring, `OCLJ_RING=1 lj_repro_Rf.exe …`)

**M1, stage string.** record off 10816. Cap 457 530, top = cap + G/2 = 473 914. The tail of the ring (seq, delta, used before, gc_low, armed, collects):

```
10070  52  473834  473786  0  30
10071  52  473850  473786  1  30     <- 10070's grant armed: top-used < (top-low)/2
10072  40  473902  473902  0  31     REFUSED   (proof just recorded: used == gc_low; top-used = 12)
```

- The cycle armed at 10070/10071 ran at the next checkpoint, inside the batch's last iteration, and **freed nothing**: `used` went 473 850 + 52 = 473 902, which is exactly the post-proof figure.
- The interpreter's checkpoint marks the whole frame. `lj_gc_step_fixtop` sets `L->top = curr_topL(L)` (lj_gc.c:760-764), and `gc_traverse_thread` marks `[stack, top)` (lj_gc.c:309-313). So the iteration's dead strings in registers survive that cycle. *Labelled inference: it is consistent with the 0 B freed and with the 304 B that a collection after the batch returns does free.*
- The batch returns and `"filling/" .. count` is built. CAT is allocate-first: `lj_meta_cat` allocates and only then steps (lj_meta.c:382-385).
- The request does not fit: `M->total + credit - M->used < delta` (lj52shim.c:398-399, with `lj52_gc_credit` = G/2 for the sandbox in burst, lj52shim.c:1095).
- Nothing armed. Past the cap, the cadence arms only when `top - used < (top - gc_low) >> 1` (lj52shim.c:1200-1205). At `used == gc_low`, which the proof has just set (lj52shim.c:1156), that is never true.
- The refusal then arms (lj52shim.c:1105-1116), too late.

**M2, timer record.** record off 10944:
- The `GCtab` (64 B) of `{key=…, times=…}` is granted and crosses the halving gate (armed).
- `lj_tab_dup` → `newtab` then allocates the hash part (lj_tab.c:164-168, 81-119; `lj_mem_newvec` at :45), 192 B, with no checkpoint between. It is refused.
- The TDUP's own check ran *before* the `GCtab` (it is a pre-check, like `lj_func_newL_gc`'s at lj_func.c:163), so it could not help.

**M3, dispatcher's pack after the kernel's slice.**
- record off 10928: a proof leaves the heap 4 B under the sandbox's top (low 474 022, top 474 026). The kernel's own allocations between resumes, its `table.pack` (80 + 48 B) and a 36 B one, are granted on the slice, taking `used` to 474 186.
- record off 11024: the same allocations leave 60 B under the top.
- Either way the cadence's gate, with the kernel allocating, counts the slice in its top (lj52shim.c:1203; `lj52_gc_kernel` lj52shim.c:1080-1083), so nothing arms.
- The next resume's first sandbox allocation, OpenOS-style `table.pack(coroutine.yield())` (lib_table.c:276 allocates; the check is at :283, after), is refused outside every handler.
- 59 of the 212 downs had `used` already past the sandbox's top before the request. The rest were within the request's size of it.

**M4, JIT on only, mechanism not checked.** 37 runs (all string shape) show `1,2`: an inside refusal, then the probe's own `done/…` string refused at the *reserve* top (`tier = 1`, `used` 6 B under total + G). That is also a stall in the harness's terms: the result line is never painted.

The common root is that we refuse when `used`, which is live data plus everything since the last proof plus what the frame still pins, plus the request, passes the tier's top. That happens at whichever allocation comes next, and the residual is the subset where no checkpoint lies between the crossing and the request. THE CREDIT's own comment names the single-request form of this (lj52shim.c:963-966; W9). These cases are its multi-allocation form at the tier's top.

## 5. Exact parameters that reproduce it deterministically

Run with `lj_repro_Cf.exe probe2.lua <shape> <off> <off> 16 384 0 1 1 0 0 -1` (JIT off, arm on, paint on, no heartbeat, no control, junk 24, batch 100).
- Each line was run twice with seed 1, with identical output.
- Each was run once instrumented, for the refused request.
- Each was run 20 times with the **random** seed (`lj_repro_C.exe`). Every run gave the same outcome (`out5/robust.txt`).

| shape | off | outcome | refused request | used at refusal / top | random-seed outcome |
|---|---|---|---|---|---|
| record | 10816 | stall (site 1) | 40 | 473 902 / 473 914 | 20/20 stall |
| record | 10864 | stall (site 2) | 192 | 473 874 / 473 962 | 20/20 |
| record | 10928 | sandbox down (site 3) | 80 | 474 186 / 474 026 | 20/20 |
| array | 11728 / 11776 / 11904 | stall / stall / down | 40 / 192 / 80 | 474 445/474 449 · 474 417/474 497 · 474 729/474 625 | 20/20 each |
| string | 224 / 288 / 384 | stall / stall / down | 40 / 192 / 80 | 462 856/462 860 · 462 828/462 924 · 463 140/463 020 | 20/20 each |
| closure | 6928 / 6976 / 7088 | stall / stall / down | 40 / 192 / 80 | 469 762/469 766 · 469 734/469 814 · 470 046/469 926 | 20/20 each |

Base for `probe2.lua` (used after setup, two collections, settle) is record 53 498, array 53 121, string 53 036, closure 53 238; `cap = base + 393 216 + off`. Every row has `covered = 1` (§3). The legacy path reproduces the same rows (§2).

## 6. How a PUC-Lua-like rule behaves on the same runs

**(a) Stock PUC 5.2.4, the same program:** 0 outside in every sweep (§2). Its string seed is randomized too (lstate.c:49-51, 89-99, time and addresses). Two runs agree on every classification, with 1 691 rows differing in other columns.

**(b) The rule on LuaJIT's own trajectory**, as the task suggests (`traj.c`, `probe3.lua`, `model.py`, `out8/`):
- **Method:**
  - One uncapped run per shape (cap 64 MB, seed 1), with the full allocator log.
  - At every marker (each batch iteration, the step's outside code, paint, the dispatcher, the kernel), one full collection gives the live set L.
  - For a limit X the rule refuses at the first request with live + request > X, where live is bracketed between L (nothing since the marker kept) and L + the growth since it (everything kept). A refusal in paint is swallowed and the search continues.
  - X = base + 384 KB + off (the cap, stock) and the same + G/2 (our burst top, "collect at the refusal, our credit").
- **Result (per 4 096 caps):**

  | shape | definite outside | ambiguous (lower bound says outside, upper bound inside) |
  |---|---|---|
  | record | 0 | 32 (cap) / 32 (top) |
  | array | 0 | 24 / 24 |
  | string | 0 | 44 / 44 |
  | closure | 0 | 26 / 39 |

  The rest are inside.
- **Reading:** the band is where the batch's last allocations and the timer record compete. The marker collections perturb interning, so the trajectory is a model, not a replay. So the bound is: a collect-at-refusal rule lands outside in at most 0.6 to 1.0 % of these runs, and PUC itself showed 0. Our measured rate is 2.6 % with every case garbage-covered.

## 7. The proposed mem_test case: W16 (fails on stage C for this reason)

Insert the chunk and recorder before `main`, and the case after W11 (`mem_test_w16.diff`, 160 lines; `mkw16.py` does it). Results against the stage-C object, same link line as run-mem.sh:

- `out5/mem_test_w16_final2.log`: `FAIL W16 … 96 caps, base + 384 KB + 0..6080 B: inside 90, stall 6, sandbox down 0, other 0; outside with room after a collection for the largest outside object (256 B): 6; first at cap = base + 384 KB + 0: stall, used 458063 at the refusal, live 455160, top 458091`, and `checks=69 failures=1`. The other 68 pass.
- **Robust under the random seed:**
  - 96×64: FAIL in 30 of 30 runs (6 covered stalls in 21 runs, 7 in 9).
  - 48×128: FAIL in 30 of 30 (4 every time).
- **Full 64 KB sweep (4 096×16):** inside 3 938, stall 158, all 158 covered.
- **Cost:** mem_test 0.32 s → 1.11 s (96×64), about 0.7 s with 48×128.
- **Can pass (control 2):**
  - `mem_test_w16_control2.c` puts the stage string, the timer record and the dispatcher's pack inside handlers. It **passes 10 of 10** and the suite reads 69/0.
  - Moving only stage and timer (control 1) still fails: 1 covered sandbox down at offset 512. That is M3, which the test also catches.
- **On PUC:** the same program (`w16probe.lua`) has 0 outside in 4 096 caps (`out9/puc_w16.tsv`). On stage C it has 146 stalls and 22 downs in 4 096 (`out9/lj_w16.tsv`).
- **What it does not count:**
  - An outside refusal where the live set plus the largest outside object does not fit under `cap + G/2`. That is stock's behaviour too, and was seen with the JIT on (§2: 23 such site-2 refusals).
  - The kernel's own refusals ("other"), which are reported in the detail but not asserted.
- **Bound:** under negative-control.sh's stopgap (no cap) the fill stops at 400 steps, and `nin > 0` then fails.

```c
#ifndef W16_N
#define W16_N 96             /* caps in the sweep */
#endif
#ifndef W16_STEP
#define W16_STEP 64          /* bytes between them: 96 x 64 B is one step of the fill */
#endif
/* W16's program: the capacity probe's shape (OcljSmoke.scala, OCLJ_PROBE=
 * capacity), the residual the collector at the wall left (docs/roadmap.md, "A
 * refusal at a credit tier's top can land outside the program's handler").  A
 * sandbox coroutine, resumed under the watchdog's arm as machine.lua resumes
 * it, fills 100 held 32-character strings per step INSIDE a pcall, with a
 * churn string per object; BETWEEN steps, outside any handler of its own, it
 * does what the probe does: the stage string, and event.timer's record for
 * the next step -- and the dispatcher packs each signal (OpenOS's
 * pullSignal) outside any handler at all.  The kernel's loop arms, resumes,
 * packs the results and disarms.  __w16rec(code) records, allocating
 * nothing: 1 refused inside the handler (the probe's normal end), 2 escaped
 * step() into the dispatcher's pcall (the probe's STALL), 3 killed the
 * sandbox (a machine down).  Bounded at 400 steps (40 000 strings, ~3 MB, seven
 * times the cap; see W1's note on bounds). */
static const char *W16_CHUNK =
  "local rec, held, count, stage, slot = __w16rec, {}, 0, 'filling/0', {} "
  "__w16h = held "
  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
  "local step "
  "step = function() "
  "  local ok = pcall(function() "
  "    for k = 1, 100 do "
  "      count = count + 1 held[count] = uniq(32, count) "
  "      local junk = uniq(24, count) .. '!' "
  "    end "
  "  end) "
  "  if not ok then rec(1) return end "
  "  stage = 'filling/' .. count "
  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "end "
  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "local co = coroutine.create(function() "
  "  for r = 1, 400 do "
  "    local sig = table.pack(coroutine.yield()) "
  "    local hd = slot[1] "
  "    if not hd then return end "
  "    slot[1] = nil "
  "    if not pcall(hd.callback) then rec(2) return end "
  "  end "
  "end) "
  "local cb = function() end "
  "__w16k = function() "
  "  for r = 1, 402 do "
  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "    local res = table.pack(coroutine.resume(co, 'timer')) "
  "    _OCLJ_WATCHDOG.disarm(t) "
  "    if not res[1] then rec(3) return end "
  "    if coroutine.status(co) == 'dead' then return end "
  "  end "
  "end "
  /* the largest single object the program allocates outside a handler: the
   * stage string, event.timer's record, the dispatcher's pack -- measured
   * here, with the collector stopped, so the case never hardcodes LuaJIT's
   * object sizes.  The third round counts: the first also pays one-time
   * allocations (the string buffer, table.pack's first call). */
  "for round = 1, 3 do "
  "  collectgarbage('stop') "
  "  local c0 = collectgarbage('count') "
  "  local s1 = 'filling/' .. (12345 + round) "
  "  local c1 = collectgarbage('count') "
  "  local t1 = { key = false, times = 1, callback = cb, interval = 0, timeout = 0 } "
  "  local c2 = collectgarbage('count') "
  "  local p1 = table.pack('timer') "
  "  local c3 = collectgarbage('count') "
  "  collectgarbage('restart') "
  "  __w16dmax = math.max(c1 - c0, c2 - c1, c3 - c2) * 1024 "
  "end";

/* W16's recorder: what landed where, and the accounted figure at that
 * moment.  A C function the chunk calls: nothing allocated. */
static int W16_CODE = 0;
static long long W16_USED = -1;
static int w16_rec(lua_State *L) {
  W16_CODE = (int)lua_tointeger(L, 1);
  W16_USED = j_core_used(L);
  return 0;
}
```

And in `main`, inside the W block after W11:

```c
    /* ---- W16: a refusal at the credit's top lands outside the handler -- */
    /* The residual row (docs/roadmap.md, found 2026-10-04): stage B saw 3
     * stalls and a dropin down in 68 capacity runs, stage C one stall in 49,
     * stock none.  Hermetically (wall2/repro, 2026-10-04): with the live data
     * inside the burst tier, the last cycle the cadence arms runs at a
     * checkpoint inside the batch, while the batch's own churn is still in
     * its frame; the batch returns, that churn is garbage, and the next
     * request -- the stage string or event.timer's record (allocate-first:
     * lj_meta_cat, lj_tab_dup's hash part), or the dispatcher's pack on the
     * next resume after the kernel spent its slice -- does not fit under
     * cap + G/2 and is refused before any checkpoint can collect it.  Stock
     * collects at the refusal (lmem.c:85-93) and the request fits.
     *
     * The sweep moves the cap through one step's worth of the fill (100
     * strings of ~60 B: one period of where the top falls in the program).
     * For every run whose refusal landed OUTSIDE the batch's handler (the
     * stall, or the sandbox killed) it collects twice and asks whether the
     * live set the refusal left, plus the LARGEST object the program
     * allocates outside a handler (measured, not hardcoded), fits under the
     * sandbox's burst top.  If it does, a collection at the refusal would have
     * made room and the program would have gone on: that is the failure.  A
     * refusal outside the handler that garbage could NOT have covered is
     * stock's behaviour too and is not counted. */
    {
      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;
      long long dmax = 0, L16, top16, off;
      char first[200];
      first[0] = 0;
      for (k = 0; k < W16_N; k++) {
        off = (long long)k * W16_STEP;
        W = w_newstate(&WS, 64 * 1024 * 1024, 1);
        if (!W) { printf("  FAIL  W16: no state\n"); return 1; }
        runstr(W, "jit.off() __w16k = false __w16dmax = 0");
        lua_pushcfunction(W, w16_rec);
        lua_setglobal(W, "__w16rec");
        if (runstr(W, W16_CHUNK) != 0) { printf("  FAIL  W16: the chunk: %s\n", errtop(W)); return 1; }
        lua_getglobal(W, "__w16dmax");
        dmax = (long long)lua_tonumber(W, -1);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        lua_getglobal(W, "__w16k");             /* on the stack while there is room */
        base = j_used(W, &WS);
        cap = base + 384 * 1024 + off;
        W16_CODE = 0; W16_USED = -1;
        w_setcap(W, &WS, cap, 1);
        st = lua_pcall(W, 0, 0, 0);
        w_setcap(W, &WS, 64 * 1024 * 1024, 1);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        L16 = j_used(W, &WS);                   /* the live set the refusal left */
        top16 = cap + w_odmax(cap) / 2;         /* the sandbox's burst tier: no slice */
        if (st != 0 || W16_CODE == 0) nother++;
        else if (W16_CODE == 1) nin++;
        else {
          if (W16_CODE == 2) nstall++; else ndown++;
          if (L16 + dmax <= top16) {
            if (ncov == 0)
              sprintf(first, "; first at cap = base + 384 KB + %lld: %s, used %lld at the refusal, live %lld, top %lld",
                      off, W16_CODE == 2 ? "stall" : "sandbox down", W16_USED, L16, top16);
            ncov++;
          }
        }
        clear_javastate(W);
        lua_close(W);
      }
      sprintf(d, "%d caps, base + 384 KB + 0..%d B: inside %d, stall %d, sandbox down %d, other %d; "
                 "outside with room after a collection for the largest outside object (%lld B): %d%.180s",
              W16_N, (W16_N - 1) * W16_STEP, nin, nstall, ndown, nother, dmax, ncov, first);
      ok(nin > 0 && ncov == 0, "W16 no refusal outside the handler that garbage covers", d);
    }
```

`j_core_used`, `j_used`, `runstr`, `errtop`, `settle_gc`, `w_newstate`, `w_setcap` and `w_odmax` are mem_test's own helpers (test/native/mem_test.c:149-171, 266-274, 343-350, 442-470).

## 8. Exploratory, not a design: the on-record idea, sketched

`mklend.py` / `mklend2.py` → `shim_lend2.o`.
- **The sketch:** lend crossings, up to 1 KB in all, from a proof that found the heap under the tier's top until the cycle the first one armed is proven, and arm it. A proof that finds the heap past the top stops lending.
- **What it does:**
  - Outside landings drop from 431 to 64 (0.39 %) on `probe2.lua` (`out12/L2_probe2.tsv`).
  - On the W16 program they drop from 168 to 43 of 4 096.
  - W16 still FAILS (2 covered: 1 stall, 1 down).
  - **C6 and W7 fail by construction**, because both assert a refusal at the exact top. A one-allocation-per-proof first version left 5.
- **Not checked:** the remaining cases were not analysed (the ring patch did not apply to the sketch).

The bearing on design is only this: the idea, as worded, does not by itself cover a multi-part object or M3, and it changes what C6/W7 pin.

## 9. Not checked / caveats

- **OpenOS's real dispatcher and `event.timer`:** modelled, not run (`event.timer`'s record is one 5-field table; the dispatcher is one `table.pack`). The kernel is a 6-line loop, not machine.lua. So the absolute rates are the model's; the mechanisms and the "covered" property are what transfer. The harness's one stage-C stall (`onehalf-string-r1-O-C`) was not traced to a site; not checked.
- **"Covered" in §3** uses the live set measured just before the site, where the frame is intact, plus the whole object. It does not model what a collect-at-refusal inside LuaJIT would actually free (it cannot run there; constraints C1-C7, lj52shim.c:754-765).
- **JIT on:** the site pass is weaker. The measuring re-run adds a branch to compiled code. 23 site-2 refusals came out not covered (by 4-44 B) and 37 (all string shape) are the M4 class.
- **The PUC model (§6b)** brackets live, it does not replay. The marker collections change interning.
- **Other configurations:** caps other than 384 KB (G at its 32 KB floor), batch sizes other than 100, and the 1024-KB stick (G > 32 KB) were not swept.
