## Collector at the wall: gates, evidence, and fail-first criteria (read-only)

I edited and ran nothing. The only shell work was reading files, two `diff -q` calls and some awk tallies over `chain1.log`. The build copy's `lj_gc.c` and `lj_api.c` are byte-identical to the pristine checkout (`diff -q` printed nothing), so the LuaJIT line numbers below hold for both.

### 1. `test/native/mem_test.c`

Checks that touch the collector, the cap or refusals:

| id | asserts | line |
|---|---|---|
| M5 | used+192 KB cap, unbounded live growth: `LUA_ERRMEM` and used ≤ total (legacy mode) | 532-536 |
| M6a / M6b / M7 | at used == total: `lua_pushcfunction` succeeds, a raw `lua_pushcclosure` is refused, the memo push is still charged (the norefuse window) | 543-572 |
| P0 | at least 24 resident traces | 621-625 |
| P1a-d | 1 MB of headroom, 64 KB garbage churn (≤400 steps): arms and collects advance, bailouts and refusals unchanged, `flush_wanted` 0, `arm()` leaves traces alone, `trace_flushes` 0 | 642-661 |
| P2a-h | 160 KB live under a 256 KB headroom: armed (a); cycle completes with headroom still under `wmark` (b); `flush_wanted` 1 (c); no flush yet (d); `arm()` flushes once (e); 0 traces live (f); flag consumed and cycle re-armed (g); used drops by ≥ `flush_bytes` − 1 KB (h) | 671-722 |
| C3a / C3b | lowered native cap refuses; raised cap admits | 823-835 |
| C4a-c | OC's save pattern: MAX cap persist; restored cap reads free 0 and refuses growth; runs again once garbage is collected | 843-867 |
| C5a / C5b | C mode: arms against the native cap and completes (precondition `armed0 == 0`); live data under the watermark gives armed, proven, flush wanted | 874-908 |
| C6 / C7 | the M6 coupling at the native cap; accounting off refuses nothing | 914-946 |
| C0c | `_OCLJ_GCSTATS` returns exactly 20 values | 782-784 |

- **Helpers:** `wmark` mirrors the watermark (385-388), `settle_gc` (342-349), `churn` runs under `lua_cpcall` (361-382), and the stat positions are at 311-332. Positions 7/8/9 (threshold, stepmul, state) exist (`lj52shim.c:1600-1603`) but are unused.
- **Not covered at all:** recovery after a caught refusal, the re-arm rate in the last quarter, an arm landing mid-sweep, and a positive bailout count.
- **`run-mem.sh`:** needs `build-native.sh` first. It links `$OCLJ_BUILD/obj-$PLATFORM/{lj52shim.o,eris_lj.o}` and `luajit-$PLATFORM/src/libluajit.a` (60-73) and compiles with `-include lj52shim.h` into `$OCLJ_BUILD/mem_test.exe`, then runs it (81-86). `OCLJ_JNI` is required (65-70). Exit is 0 iff every check passes (`mem_test.c:994`).
- **Time:** the test "runs in milliseconds" (`mem_test.c:8`). The build-plus-run time is not recorded. The whole 10-03 native gate chain took 13:03-13:06 (`results-accounting-2026-10-03.md:273`).
- **Switches:**
  - `OCLJ_SHIMOBJ` links another object for a fail-first A/B (`run-mem.sh:7-9,62`).
  - `OCLJ_MEMTEST_CFLAGS=-DMEMTEST_OLD` models the class before the handover (`mem_test.c:148-164,963-966`). On the pre-change object it must fail exactly M3c, C0a-d, C1, C2a-c, C7, C8 and M9 (`results-accounting:283`).
  - Nine hand-made sabotaged shims were run for the accounting change; the collector one is "no pressure -> C5a C5b". Their logs live in a session scratchpad, not the repo (`:283,353-355`).

### 2. `negative-control.sh`

- **Memory half (309-388):**
  - `memcanon` must fail nothing.
  - `stopgap` (`accounting = 0`, 326) must fail exactly M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 (343-344). The collector ids fail because nothing arms against an uncharged cap.
  - `nopending` must fail M4b M5 M7 M3c C0b (378).
  - `norefuse` must kill the process after `PASS M5` and before the summary (`expect_death`, 283-307, 381-388).
- **No sabotage targets `lj52_gc_pressure` itself.** The sed anchors still match the shim (`lj52shim.c:415,535,1725,1727`).
- **Stale paths:** it reads `$OCLJ_BUILD/luajit/src` and `obj/eris_lj.o` (47, 57-58, 74, 255). Neither exists any more (only `luajit-windows-x86_64` and `obj-windows-x86_64` do), so it fails at setup unless it is run through a mirror of the old layout (`roadmap.md:164`; `results-accounting:285`).
- `standinghook` also fails on an extra W10g (`roadmap.md:164`).
- It runs `rm -rf $OCLJ_BUILD/negctl` at the start (61), so copy those logs out before a rerun.

### 3. The harness

- **mem-2** (`OcljSmoke.scala:456-600`): passes iff the program survived, `trace_flushes` advanced by at least 1, and `traces_live` read ≤ max(2, 5% of the count before) while the program was still stepping (582). It SKIPs on the stock kernel and with the JIT off (462-470).
- **GC PRESSURE** (4538-4541) prints arms, collects, bailouts, refusals, armed, gcstate, trace_flushes and flush_bytes. It gates `gc-emergency-collects-resolve` (collects == arms and bailouts == 0, 4546) and `gc-emergency-not-stuck-armed` (4551). At 1.8: arms 3760, collects 3760, bailouts 0, refusals 0 (`logs/full18-additive-on-r2.log:159-161`).
- **acc-1 / acc-1r** (1807-1823): 20 values, csync 1, native cap == Java total; csync 0 on the dropin.
- **acc-2** (5109-5135): more than 100 000 allocator calls since boot, 0 through JNI, caps equal, and one `getFreeMemory` costs exactly one native read.
- **acc-3..7** run on private states (1825-2006).
- **Related milestones:** `e4-oom-at-the-cap` (1738-1761: unbounded live growth must throw and stop at or under the cap), `al-1` (3758-3770), `b2` (3718), `f5` (kernelMemory > 10000).
- **Capacity probe** (3054-3241):
  - `CAP-IDLE`: arms, refusals and flushes over 400 ticks.
  - `CAP-LIVE`: three collects, then used, kernelMemory and user.
  - `CAPACITY`: held, why, `t_first5`/`t_last5`, batches, `OCLJCAPF`, arms, refusals, flushes, `fill_ms`, running, lastError.
  - The outcome classes of the `cap-1` message (3226-3240): pass (`done/N/not_enough_memory`, running); stopped before the signal; down (`running=false`, "not enough memory"); stopped otherwise; stuck at `filling` with no `OCLJCAPF` (refusal path never reached); recovery refused (`filling` with a numeric `OCLJCAPF`); never finished; ended without a memory refusal.
  - **It prints only stat positions 1, 4 and 10** (3179, 3223-3224). Collects, bailouts, armed, stepmul, threshold and state are missing, so whether the collector ever parked in the matrix cannot be determined from the archive.
- **Run time:**

| run | time | source |
|---|---|---|
| capacity, clean or down | ~27 s | `one-record-r1-D.log`: WALL 22.4 s, +27 s |
| capacity, recovery refused | ~276 s, because the fill waits up to 8000 ticks at 25 ms (3200) | `final-check-one-record-D.log`: `fill_ms` 250142, WALL 270.9 s |
| capacity matrix | 82 runs, 87 min | `results-ramscale:95` |
| full suite, one arm | 78-95 s | `chain3.log` |

- **How to run one:** `cap.sh <run-dir> <additive|stock> <jit on|off> <jitearly -|off> <one|onehalf|threehalf> <scale> <shape>`.
  - It refuses a run directory that already exists (`cap.sh:11`).
  - It hard-codes another session's scratchpad for `OCLJ_LIBS` (`cap.sh:7,23`), and `chain1.sh:76` adds pinning through that scratchpad's `affrun.exe` (`affrun C03C03`).
  - It also needs JDK 8, `~/Downloads/ocelot-brain` and `build/native/libdir-additive`.
  - Chains belong in the main session, under nohup plus Monitor.

### 4. Failure signatures and pass/fail criteria

**Recovery refused** (12 runs):
- `held=? why=? running=true lastError=<null>`, `freeKB_at_end/totalKB=0/<stick>`, `fill_ms` 249 788-250 065, exit 1.
- refusals +2 (11 of 12), +3 once.
- The screen stays at `OCLJCAP=filling/N`, a multiple of 100 (for example `filling/1200`, `final-check…log:77-78`).
- Mechanism: the step's `"done/" .. count` concatenation raises after `held = nil`. `lj_meta_cat` allocates before its GC check (`lj_meta.c:379-385`).

**Machine down** (7 runs; 6 in E, 1 in O):
- `running=false lastError=not enough memory`, `freeKB_at_end/totalKB=-1/-1` (the recovery path was never reached).
- `fill_ms` 190-8705, refusals +3 to +6.

**Near-wall slowdown:**
- `t_last5`: ours 0.040-0.463 s against stock's 0.0010-0.0082 s, which is 21-121x (`chain1-tables.md:62-73`).
- Arms per batch, worked out from `chain1.log`: 143-389 (for example 2848/13, 6878/48, 2336/6).
- Stock's `last/first` is 1.00-1.24.

Proposed criteria. Each must first be seen to fail on today's DLL `cb29485d`.

- **(a) Recovery at the wall**
  - The 60-run matrix gives 0 "recovery refused" and 0 "down" across D, E and O. Today: 19 of 60.
  - Every clean run still records refusals ≥ +1, so the wall was really reached.
  - Held medians are no worse than today's tables (O/S ≥ 0.95 at the 1024 KB closure cell).
  - `e4`, M5, C3a and C4b still refuse truly live growth.
- **(b) Near-wall throughput**
  - Per cell, median ours `t_last5` ≤ 3× stock's in the same pinned chain (today 21-121x).
  - Emergency arms during the fill ≤ 3 per batch (today ≥ 143).
  - The hermetic bound in section 5.
- **(c) The parked collector**
  - Hermetic fail-first as in section 5.
  - In the harness: bailouts == 0 and collects == arms everywhere.
  - The fingerprint armed = 1, stepmul 0, state 0, threshold > `c_total` is never read. This needs `CAP-*` to print positions 2, 3, 5, 7, 8, 9 and 15.
- **(d) Deterministic kernelMemory**
  - D's kernelMemory is identical across at least 3 replicates per stick, as S (174 605) and E/O (164 393) already are. Today D reads 335 513-413 193 (`chain1-tables.md:41-54`).
  - No traces are live at the measurement.
  - The figure holds on a loaded or unpinned host.
  - Removing the windfall exposes E's idle behaviour, so require ≤ about 63 idle arms over 400 ticks and 0 flushes at 192 KB. Today E reads 1390-2964 arms and 16-29 flushes.

### 5. Hermetic reproductions (no JVM; one state in C mode, built like the C section)

- **(1) Recovery at the wall.**
  - Cap = used + 512 KB.
  - Pre-size the holder from C (`lua_createtable(L, 1<<16, 0)`) so every fill allocation is ≤ 64 B. Then run: `local ok, err = pcall(fill)  held = nil  local s = string.rep("x", 256)`.
  - The headroom after the refusal is smaller than the largest fill object, which is smaller than 256 B. So by reading, the current shim must refuse the `rep`: `string.rep` allocates before its GC check, so the pending armed cycle cannot help.
  - Pass: status 0, `err` is "not enough memory", used ≤ cap, bailouts 0. Repeat three rounds.
  - Add variants for a JIT-hot fill (refusal on trace; C1 says an on-trace full collect hangs, so add a wd_test-style 10 s alarm) and a record-shape fill (C5: verify held contents are intact before the drop).
  - Run the same chunk on PUC 5.2.4 with a capping allocator as the baseline. PUC retries only when `gcrunning` (`lmem.c:84-93`).
  - The "down" mode cannot be reproduced hermetically: the logs do not say where it raised.
- **(2) The last quarter.**
  - Live set 256 KB. Run the same `churn(asize 0, N=2000)` twice: once with a cap leaving 4w of headroom, once with w/2.
  - By reading, today's shim does about one cycle per two allocations (arm at an allocation, cycle at the next `lj_gc_check`, disarm at that allocation; `lj52shim.c:902-941`), so roughly 1000 collects.
  - Pass: collects in the w/2 run ≤ ceil(bytes allocated / (h/2)) + 2, and the time ratio near/far ≤ 3 in the same process.
  - P2b, P2c and C5b must still hold (the flush flag is raised only at a proven short cycle).
  - P1a must still hold: 64 KB bursts get no refusals, so any throttle may not delay the first arm.
- **(3) Parked collector.** Cap 64 MB, about 800 KB live, about 100 KB garbage. Then:
  1. Call `lua_gc(LUA_GCSTEP, 0)` until stat 9 reads 4 (`GCSsweep`).
  2. Lower the cap to used + w − 64 and allocate one table. Assert armed = 1 with state 4.
  3. Allocate a second table. Assert state 0, armed 1, stepmul 0, and threshold (position 7) > cap. That is `estimate × 200/100` (`lj_gc.c:699-702,741-744`; `luaconf.h:93`), and while armed the shim neither re-arms nor rewrites the threshold (`lj52shim.c:902-928`).
  4. Churn 64 B garbage. By reading, today it refuses after about headroom/64 (~4-5k) steps with collects unchanged. The bailout needs 65 536 calls (`:865,916`), and the kernel's collect fires every 10th resume only (`machine.lua:1617-1622`).
  - Pass: no refusal, collects advance, bailouts 0, not armed at rest.
- **(4) kernelMemory.** OC measures it in Java, so the measurement itself has no hermetic form. Only the shim-side mechanism can be tested, for example `TRACE_CHUNK` then `GC_CUSED` after the chosen flush or collect, in the style of P2h.
- **Time:** all four touch at most a few thousand allocations on a heap of 1 MB or less, comparable to P1/P2, so they should take well under a second (an estimate; nothing was run).

### 6. Other gates a change must keep passing

- **The `_OCLJ_GCSTATS` value count is pinned at 20:** `mem_test.c:784`, `OcljSmoke.scala:1784,1796,1810-1811,3170`. Twenty is also `LUA_MINSTACK` (`lj52shim.c:1613-1621`), so appending a stat needs a `checkstack` and touches every one of those sites.
- **`build-native.sh` collector gate:** no `lj_gc_fullgc|lj_gc_step|luaC_|lua_gc(|LUA_GCCOLLECT|LUA_GCSTEP` may appear in the shim (340-347), plus the `GCSpause` enum check (311-322). The deferred collect-at-safe-point design (`memory-accounting.md:1019-1028`) would sit in `lj52_wd_arm`, inside the shim. So the gate has to be deliberately re-scoped, with its own fail-first.
- **Both refusal sites** (`:378-381` C mode, `:440-447` legacy) need the fix: the dropin arm (62/0) runs legacy.
- **`security_test` (37/0), `shim_test` (57/0), `race_test` (2/0):** they create no capped state, so they never reach `lj52_gc_pressure`, but they still link the shim. Their runners have stale paths (`run.sh:22,34`, `run-race.sh:22,32`, `run-security.sh:29,42-43`), so they need the mirror.
- **`wd_test` (35/0):** accounting is off (230), but every arm passes the flush check (`lj52shim.c:1406`). Any work added at the safe point lands on W6b's absolute 20 ms bound (`wd_test.c:319-320`). The 10 s alarm is at 129-149.
- **`penalty_test` (6/0):** runs on `crt_alloc` with no shim (22-24, 172), so it is unaffected unless LuaJIT itself is patched.
- **Harness arms:** additive JIT on, off and sieve-only (65, 63, 59 checks), dropin (62), stock (47); 78-95 s each. The 10-03 `h2` chain took 24 min. The `OCLJ_JAVA_SRC` sabotages (`results-accounting:286-288`) and the sieve acceptance test (arms ≥ 1, collects == arms, bailouts 0, refusals 0; `memory-accounting.md:783-794`) also apply.
- **Times not determinable by reading:** individual native-test run times and the build time.