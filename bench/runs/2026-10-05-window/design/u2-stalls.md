# u2: what the stalls and the dropin's machine-down show

Survey for the design round on the open roadmap row "A refusal at a credit tier's top can land outside the program's handler" (`docs/roadmap.md:159`). I did not change the repo. The code citations are to the tree at `d9080d4`. The runs cited are under `bench/runs/2026-10-04-wall/logs/chainB/` and `logs/chainC/`.

**How each claim is labelled:**

- **[log]**: read from a run log.
- **[code]**: read from the source.
- **[estimate]**: computed by me from struct sizes or measured object sizes.
- **[inference]**: a conclusion I drew that no log line shows directly.
- **[speculation]**: a hypothesis that is not tested.
- **[not checked]**: I did not look.

My per-run extraction of the CAP lines is at `scratchpad/wall2/u2/chainB.psv` and `chainC.psv`. They are working files, not part of this report.

---

## 0. Findings in brief

1. **Every bad run had a second chance to fail, and stock never gets one.** Five runs went bad: 4 stalls and 1 dropin down.
   - All five reached the **reserve** tier: their `od_peak` is above G/2. All five had at least 2 refusals.
   - Across all 116 of our capacity runs in chains B and C, the refusal count and the tier split exactly:
     - All 95 runs with one refusal stayed in the burst tier (`od_peak <= G/2`).
     - All 21 runs with two or more refusals reached the reserve tier.
   - In the five cells that have a single-refusal comparator, the multi-refusal run held 65-98 more objects. At the measured object sizes that is about 17-21 KB of extra live data, which is about G/2.
   - So in every multi-refusal run, the first refusal opened the reserve tier, but something other than the fill's `pcall` caught it. The fill then kept going and spent the reserve. [log + inference]
   - Stock has no equivalent. A refusal that stock absorbs does not raise its cap, so the fill's next object is refused inside the `pcall`.
   - All five bad outcomes happened at this second crossing: 5 of 21 (24%, 95% CI 8-47%). None happened at a first crossing: 0 of 116 (95% CI 0-3.1%). For the two O string stalls at 256 KB this rests on an `od_peak` argument (§1.3). The small counts are a caveat.
2. **The painted rows identify the stall site, up to two candidates.**
   - In all four stalls the screen reads `filling/N*100` with `batches=N` and `OCLJCAPF=-1/-1`. That means:
     - the stage string of step N was assigned;
     - step N+1 never reached `batches = batches + 1`;
     - the `else` branch never ran.
   - That rules out the stage string, `paint`, and OpenOS's dispatcher. What is left is `event.timer(0, step)` at the end of step N, or the closure handed to `pcall` at the start of step N+1.
   - By byte share, `event.timer` is the more likely of the two: about 0.81 KB in 8 allocations, against 80 B for the closure. [estimate]
   - The results document and `analyze.py` list the stage string as a stall site. In these four runs it was not.
3. **The two O string stalls at 256 KB are deterministic, and they carry a size clue.** They happened twice (B3 and C) at the same count, 3700, with 2 refusals each.
   - Their `od_peak` stops 898 B (B3) and 2918 B (C) below the sandbox's reserve top.
   - If the stall came after the reserve opened, the refused request was larger than 0.9 KB and 2.9 KB. That is bigger than any single allocation the probe makes between batches (192 B at most). [estimate]
   - This tension is not resolved. §1.3 lists the candidates.
4. **OpenOS keeps the machine up through a stall** (§2):
   - The dispatcher calls every handler under `pcall` and hands any failure to `event.onError`, which writes `/tmp/event.log` under its own `pcall`.
   - A one-shot timer is removed *before* its callback runs, so the chain breaks.
   - The heartbeat timer (`times = math.huge`) is never removed.
   - After a stall nothing references `held` any more, so the held data are collected. The C stall's heap sat at 391 KB at the end, which is the post-fill live set (366 KB) plus heartbeat garbage below the cadence's next arm.
5. **The dropin went down with its live data pinned at the top.** Its last proof found the live set 769 B under the sandbox's reserve top, and the reserve tier was still open at the end (`od_state=1`).
   - **My account [inference]:** the fatal refusal landed where the timer chain survived, so `held` stayed reachable and every recovery allocation was refused too. The likely path runs from the dispatcher into the shell and then `init.lua`'s error loop, which has no protection (§1.4).
6. **Could stock stall? Yes, in principle.** It would need its live data to cross the cap within about 0.4-0.8 KB of a batch boundary [estimate].
   - None of the 13 stock configurations observed crossed there. Their refusal positions are all at least about 4 KB of live growth before a boundary, or at a doubling of the held array inside the `pcall` (§3).
   - Stock's outcome is a fixed property of each configuration. Ours also depends on garbage timing and on refusals that something else absorbs.

---

## 1. The stalls and the dropin's down

### 1.1 The numbers

**The constants** [code]:

| quantity | value | source |
|---|---|---|
| G | `total >> 4`, clamped to 32-512 KB | `native/lj52shim.c:1017-1019`, `:1060-1064` |
| sandbox burst top | total + G/2 | `:1094-1095` |
| sandbox reserve top (after a refusal, until a proof finds used <= total) | total + G | `:1069-1077`, `:1113`, `:1157` |
| kernel's slice | +16 384 B on either top, when `wd_depth == 0` or the running thread made the outermost arm | `:1020`, `:1080-1083`, `:1096` |
| refusal in C mode | `:398-401` | |
| refusal in legacy mode | `:460-467` | |
| `od_peak` | the largest `used - total` over granted growths | `:1142-1145` |

**Where the counters come from** [code]: the fields are read from `_OCLJ_WALLSTATS` and `_OCLJ_GCSTATS` around the fill (`test/native/OcljSmoke.scala:3399`, `:3431`, `:3455-3458`). Refusal counts are differences over the whole 8000-tick window, including about 200 s after a stall.

| run | stick / arm | total | G | sandbox burst / reserve top | kernel burst / reserve top | peak heap = total + od_peak | where the peak sat |
|---|---|---|---|---|---|---|---|
| `one-record-r1-E-B3` | 192 KB, E | 518 420 | 32 768 (the floor) | 534 804 / 551 188 | 551 188 / 567 572 | 551 303 | **115 B past** the sandbox's reserve top (on the kernel's slice) |
| `onehalf-string-r1-O-B3` | 256 KB, O | 636 385 | 39 774 | 656 272 / 676 159 | 672 656 / 692 543 | 675 261 | **898 B under** the sandbox's reserve top; above the kernel's burst top, so the reserve was open |
| `threehalf-string-r1-E-B3` | 1024 KB, E | 2 051 962 | 128 247 | 2 116 085 / 2 180 209 | 2 132 469 / 2 196 593 | 2 180 329 | **120 B past** the sandbox's reserve top |
| `onehalf-string-r1-O-C` | 256 KB, O | 636 783 | 39 798 | 656 682 / 676 581 | 673 066 / 692 965 | 673 663 | **2 918 B under** the sandbox's reserve top; 597 B above the kernel's burst top, so the reserve was open |
| `one-closure-r1-L-B3` (dropin, legacy mode, `ccap=0`; total is Java's) | 192 KB, L | 693 444 | 43 340 | 715 114 / 736 784 | 731 498 / 753 168 | 736 915 | **131 B past** the sandbox's reserve top |

All five readings come from the `CAP-GC` line (`od_peak`, `od_limit` = G, `kslice`) and from total on the `b2` milestone line [log].

**The other counters** [log]:

| run | CAP-IDLE refusals | CAP-LIVE used (before fill) | refusals | overdrafts | od_state at end | gc_low | armby | arms / collects | trace flushes | end gctotal | screen |
|---|---|---|---|---|---|---|---|---|---|---|---|
| record E-B3 | +0 | 389 387 | +3 | +807 | 0 | 385 097 | 0 | +683 / +683 | +201 | 399 041 | `filling/600`, batches=6, OCLJCAPF -1/-1 |
| string O-B3 256 | +0 | 352 597 | +2 | +2886 | 0 | 366 077 | 1 | +100 / +100 | +0 | 397 081 | `filling/3700`, batches=37 |
| string E-B3 1024 | +0 | 488 153 | +5 | +11385 | 0 | 393 381 | 2 | +188 / +188 | +37 | 455 557 | `filling/21700`, batches=217 |
| string O-C 256 | +0 | 352 935 | +2 | +2962 | 0 | 366 467 | 1 | +98 / +98 | +0 | 391 247 | `filling/3700`, batches=37 |
| closure L-B3 | +0 | 450 385 | +4 | +1750 | **1** | **736 015** | 1 | **+76 / +75** | +9 | 730 211 (after the stop) | `filling/1700`, batches=17, running=false, `lastError=not enough memory`, `fill_ms=315`, CAP-MID `snaps=10 stopped=1` |

**What the five rows have in common** [log]:

- `bailouts=+0`.
- `park_resets=+0`.
- In the four stalls, CAP-MID reads `snaps=8000 stopped=0 stepmul0=0 parked=0`.
- No refusals in any idle window. Across all 116 of our runs, `CAP-IDLE refusals=+0`.

**The dropin's end state:**

- One arm was never proven: arms +76 against collects +75.
- The end state reads `armed=1 state=0 stepmul=0 threshold=1460200 parked=true`.
- That state was read after the machine stopped. The run README warns that OC's own collection of a stopped machine leaves this same fingerprint, so it is not evidence of a park (`bench/runs/2026-10-04-wall/README.md`, "Notes on the runs").

**`gc_low` and `od_state` at the end of the stalls describe the machine after it recovered, not the moment of the stall.** The window ran 200 s or more past the stall. In the dropin they describe the last proof before the death:

- A proof writes `gc_low = used` and closes the reserve only if `used <= total` (`lj52shim.c:1151-1157`).
- Frees lower `gc_low` only while unarmed (`:1193`). The record ended armed.

### 1.2 What the painted rows say about the failing allocation

**How the rows are written** [code]:

- `paint()` writes rows 15-18 from the probe's upvalues (`OcljSmoke.scala:3158-3164`).
- Two things call it:
  - `step` at its end, under `pcall` (`:3197`);
  - the heartbeat timer every 0.05 s, also under `pcall` (`:3206-3209`).
- The harness reads `held`, `why`, `batches`, `t_first5` and `t_last5` from those rows after the fill window (`:3434-3449`).
- `freeAt` and `totalKB` start at -1 (`:3157`). They are set only in the `else` branch (`:3191-3196`).

**The heartbeat is still painting at the end of a stall** [inference from code].

- Its handler is registered with `times = math.huge`. The dispatcher removes a handler only when `times` reaches 0 (`openos/lib/event.lua:64-70`) or when the callback returns exactly `false` (`:75-76`). An error path removes nothing (`:72-74`).
- So while the machine is up and anything calls `computer.pullSignal`, the rows show the current values of `stage`, `batches` and `freeAt`.
- The collector kept arming and proving through the window: +683, +100, +188 and +98 collects. That is consistent with a live idle machine.
- **[not checked]** The capacity probe never reports `OCLJCTR`, so heartbeat progress after a stall is not in the log.

**What the step does, in order** [code] (`OcljSmoke.scala:3174-3198`):

1. `t0 = os.clock()` (`:3175`). LuaJIT's C `os.clock` returns a number and allocates nothing; the sandbox maps it straight through (`machine.lua:983`).
2. `pcall(function() ... end)`: a new closure, created **outside** the `pcall` (`:3176`).
3. The batch, inside the `pcall` (`:3177-3182`).
4. `batches = batches + 1` (`:3185`). No allocation.
5. `stage = "filling/" .. count` (`:3189`).
6. `event.timer(0, step)` (`:3190`).
7. `pcall(paint)` (`:3197`).

**What the rows rule out**, given `stage = "filling/" .. (100*batches)`, `batches = N` and `OCLJCAPF = -1/-1` in all four stalls:

- **Step N reached step 5, and the stage concat succeeded.** If the concat had been refused, `stage` would still read `filling/(N-1)00` while `batches` read N.
- **The stage string is excluded in all four.** The results document lists it as a stall site (`bench/results-wall-2026-10-04.md:438-442`), and so does `scripts/analyze.py:13-15`.
- **Step N+1 never reached step 4.** No step's `pcall` caught the refusal: a caught one sets `ok = false`, increments `batches` and runs the `else` branch, which writes `freeAt`.
- **`paint` is excluded.** Its refusals are caught (`:3197`, `:3208`), and it runs after `event.timer` anyway.
- **OpenOS's dispatcher and `machine.lua`'s `pullSignal` cannot break the chain.**
  - Step N+1's handler is registered by step N's `event.timer`.
  - The dispatcher removes it only immediately before calling it (`event.lua:64-70`).
  - A refusal in the dispatcher's `table.pack` or `copy` (`:54-59`), or in `machine.lua:1413-1422`, therefore propagates out of `computer.pullSignal` with the next step still registered.
  - Between the removal and the call there is only `pcall(handler.callback, table.unpack(event_data, 1, 0))` (`:72`). By my reading that allocates nothing. [estimate]
- **The kernel would have taken the machine down.** `machine.lua`'s main loop has no `pcall` (`machine.lua:1517-1542`; `pcall(main)` at `:1547` ends the kernel). The four stalls stayed up.

**What remains is two sites, both of which raise out of `step` into the dispatcher's `pcall` (`event.lua:72`):**

- **(a) `event.timer(0, step)` in step N** (`full_event.lua:70-75` → `event.lua:10-29`). [estimate, LuaJIT GC64 sizes]
  - Three `checkArg` calls. Each builds a `check` closure with two fresh upvalues (`machine.lua:68-82`; the sandbox's `checkArg` is that function, `:1042`).
    - Closure: `sizeLfunc(2)` = 56 B (`lj_obj.h:483`).
    - Upvalues: 2 GCupval × 48 B (`lj_obj.h:433-446`).
    - Total 152 B each, 456 B for the three.
  - The handler table from TDUP: 64 + 4 nodes × 24 = 160 B.
  - The fifth key (`handler.timeout`, `event.lua:19`) forces a rehash to 8 nodes: 192 B more.
  - Total about **0.81 KB in 8 allocations**. The largest single one is 192 B.
  - `opt_handlers[id] = handler` (`:27`) reuses the id that step N's own handler freed. No growth expected. [estimate]
- **(b) The closure handed to `pcall` in step N+1.** `sizeLfunc(5)` = **80 B**: its upvalues are `BATCH`, `make`, `count`, `held` and `uniq`.
  - LuaJIT has no closure cache.
  - `lj_func_newL_gc` runs the GC check *before* it allocates (`lj_func.c:157-164`). So an armed cycle completes just before this closure is allocated. That narrows its window further.
- By byte share, (a) is about 10 times more exposed than (b). [estimate] The logs cannot separate the two (§5).

### 1.3 Per-run notes

**`one-record-r1-E-B3` (192 KB, E: JIT off through kernel init, on after)**

- The heap reached the sandbox's reserve top plus 115 B, on the kernel's slice or the norefuse window. At that moment the sandbox had no room at all, so any sandbox request was refused. That is consistent with a small allocation at either site (a) or (b).
- The fill stalled after 600 objects, at the boundary of batch 6. The E reps of the same cell ended at 552 (r2, 1 refusal, burst tier) and 617 (r3, 2 refusals, reserve tier, `od_peak` 32 727).
- So this run was on the same reserve-tier path as r3: an earlier refusal was absorbed and the fill continued past the burst top. Its crossing at the reserve top fell between batches instead of inside one. [inference]
- `gc_low` at the end is 385 097, 4 290 B below the live set before the fill. The trace flushes (+201 over the window) explain that [inference]. The 600 records were freed (§2.3).

**`threehalf-string-r1-E-B3` (1024 KB, E)**

- The peak reached the sandbox's reserve top plus 120 B; 5 refusals.
- In chain C, both JIT-on runs of the same cell also reached the reserve top and had 8 refusals each, but their final refusal landed inside the `pcall`:
  - `threehalf-string-r1-D-C`: held 21 768, `od_peak` = G + 127;
  - `threehalf-string-r1-L-C`: held 21 764, 51 B under the top.
- This run stalled at 21 700, one batch boundary earlier. Its crossing fell on the boundary, theirs at objects 68 and 64 of the next batch. [log; the reading is inference]

**`onehalf-string-r1-O-B3` and `onehalf-string-r1-O-C` (256 KB, O: JIT off throughout)**

- These are deterministic:
  - both stalled at `filling/3700` with `batches=37` and 2 refusals;
  - overdrafts 2886 / 2962, `od_peak` 38 876 / 36 880, collects 100 / 98;
  - `gc_low` sat 13 480 / 13 532 B above the live set before the fill.
- Stage C's changes (site 13 and the flush at w/2) have no effect on arm O, which has no traces (`trace_flushes=+0`). Total differs only by site 13's 398 B. [log]
- O is the only 256 KB string cell of ours with no clean run in either chain.

**The size clue, and why it is unresolved.**

- `used <= total + od_peak` holds for every granted growth outside the norefuse window and outside HOOK_GC (`lj52shim.c:1128`, `:1136`, `:1142-1145`).
- So a sandbox refusal in the reserve tier needs a request larger than `G - od_peak`: **898 B in B3 and 2 918 B in C**. Every single allocation at sites (a) and (b) is 192 B or less [estimate]. That leaves three possibilities:
  - **(i) Order: absorbed, then the stall.** Absorbed refusal → reserve opens → the fill runs on to about 0.93-0.98 G → the stall.
    - In this order the refused request was **at least 0.9 / 2.9 KB**, so it was not one of the probe's small allocations.
    - Candidates, all [speculation]:
      - A Lua stack regrowth: `lj_state.c:110-119` doubles the stack, a realloc of the whole old stack after a GC halved it at `lj_gc.c:320` / `lj_state.c:98-107`. It would have to land at step's entry, or at `computer.uptime`'s host call inside `event.register` (`event.lua:19`).
      - I judge a regrowth at step's entry unlikely. A shrink leaves at least about 2× the depth seen at traversal, and the batch goes deeper than step's entry.
      - A growth in jnlua's `lua_checkstack` (`lj_state.c:167-170`) fails as a Java exception, not as "not enough memory".
      - The norefuse window (about 1.5 KB, `lj52shim.c:1981-1983`, not counted in `od_peak`) could close the B3 gap but not the C gap.
  - **(ii) Order: the stall first, at the burst top.** The refusal opened the reserve, and the heap then climbed to about 0.93-0.98 G before `held` was released.
    - After the stall, `held` is reachable only until the dispatcher replaces `copy` (`event.lua:56`).
    - The sandbox's cadence past the cap re-arms once half the distance to the top is used (`lj52shim.c:1201-1204`). That caps the excursion at roughly the burst top + G/4, which is about 0.75 G [estimate].
    - Reaching 0.93-0.98 G would take about 8 KB of kernel-slice allocations with no sandbox allocation in between. I judge that unlikely [inference].
  - **(iii) Something I have not found.** The interning table's growth and shrink do not fit:
    - Growth is triggered only by creating a string, and nothing between batches creates strings outside `paint` and the stage string (`lj_str.c:308-309`).
    - The shrink needs `str.num <= mask/4` (`lj_gc.c:695-696`), which is impossible with 3 700 held strings unless the table had grown to 32 768 slots (256 KB).

**`gc_low` above the pre-fill live set by about 13.5 KB** after recovery: not explained [not checked]. One candidate is the interning table, which LuaJIT never shrinks unless `num <= mask/4`.

### 1.4 The dropin's machine-down (`one-closure-r1-L-B3`)

**What the log fixes** [log]:

- 17 full batches in 315 ms; the screen froze at `filling/1700`, batches=17.
- 4 refusals; `od_state=1` at the end, so the reserve tier was never closed.
- The heap peaked 131 B past the sandbox's reserve top.
- The last proof found `used = 736 015`: 42 571 B past the cap, **769 B under the sandbox's reserve top**, 17 153 B under the kernel's reserve top.
- So the program's live data had filled the reserve tier and pinned the heap there. After that, any sandbox allocation needing more than about 769 B beyond the live set and uncollected garbage was refused, collect or not.
- `lastError="not enough memory"`.

**Where a "not enough memory" ending can come from** [code]:

- **(a) The sandbox's main coroutine (`init.lua`) died with the memory error.** `machine.lua:1534-1535` turns that into `error(tostring(result[2]), 0)`, and `pcall(main)` returns it (`:1547`, `NativeLuaArchitecture.scala:265-283`).
- **(b) A refusal in the kernel thread itself.** The kernel thread is the `machine.lua` main loop: `table.pack` at `:1532`, `:1539` and `wrapUserdata` at `:1540`, with nothing protecting them. A refusal there ends in the same `pcall(main)` error.
- **(c) A Java-side push between resumes** raises `LuaMemoryAllocationException` → `ExecutionResult.Error("not enough memory")` (`NativeLuaArchitecture.scala:293-294`).

A refusal inside step code would not kill the machine (§2), so the fatal one landed elsewhere.

**My account** [inference, not provable from the log]:

- The refusal landed on the OpenOS path. That is the dispatcher's `table.pack` or `copy` (`event.lua:54-59`), or `machine.lua:1416`. It propagates:
  1. out of `computer.pullSignal`;
  2. into the cursor loop (`lib/core/cursor.lua:246`);
  3. caught by `tty.stream.read`'s `xpcall` (`lib/tty.lua:68`). A memory error does not invoke the message handler (`lj_err.c:813-833`, against `lj_err_run` at `:887-901`).
  4. Re-raised by `assert` (`tty.lua:74`).
  5. Out of the shell's `readLine` (`bin/sh.lua:25`, no `pcall`).
  6. Into `init.lua`'s `xpcall` (`init.lua:17-19`), whose handler builds a traceback string.
  7. Then into `init.lua`'s recovery: `io.stderr:write`, `io.write`, `os.sleep`, `event.pull("key")` (`init.lua:20-24`). **None of it is protected.**
- On this path step 18's timer stays registered, so `held` stays reachable and nothing can be collected. With the live set 769 B under the top, the recovery's allocations are refused too. The error then escapes `init.lua`'s loop and kills the main coroutine, which is case (a).
- The kernel's slice still had about 17 KB of headroom at the last proof, which makes (b) less likely than (a). Neither can be excluded.
- Contrast the stalls: when the refusal breaks the chain, `held` becomes unreachable and is collected (§2.3), so the machine survives.

**The 2026-10-03 matrix, for comparison** (`bench/runs/2026-10-03-ramscale/chain1.log`; this was the DLL before stages A-C, with no credit and no kernel slice):

- 7 of 60 of our runs went down. All had OCLJCAPF -1/-1 and 3-6 refusals:
  - `one-array-r1-E` (6 batches), `one-string-r1-E` (19), `one-record-r2-E` (5), `onehalf-record-r1-O` (8), `onehalf-closure-r1-E` (12), `threehalf-string-r1-E` (195), `threehalf-closure-r1-E` (77).
- None stalled. Every unclean run that stayed up had OCLJCAPF written, which is the "recovery" class.
- Reading [inference]: the same out-of-handler landings used to kill the machine. The kernel's slice (`lj52shim.c:951-957`: "cannot take the kernel down with it on the table.pack it does after every resume") turned them into stalls or into clean runs. **[not checked]** which of those 7 were kernel refusals.

---

## 2. OpenOS's event library, as ocelot-brain ships it

Files: `ocelot-brain/src/main/resources/assets/opencomputers/loot/openos/lib/event.lua` and `lib/core/full_event.lua`. `full_event.lua` is lazy-loaded through `package.delay` (`event.lua:161`). `event.timer` is used at boot, so `full_event.lua` is already loaded when the fill runs.

### 2.1 How a timer callback is called

**Registration.** `event.timer(interval, cb, times)` calls `checkArg` three times, then `event.register(false, cb, interval, times)` (`full_event.lua:70-75`).

- `register` builds `{key, times = times or 1, callback, interval}`, sets `timeout = uptime() + interval`, takes the first free integer id, and stores the handler (`event.lua:10-29`).
- `event.timer(0, step)` is therefore a one-shot handler that is due immediately.

**Dispatch** happens inside the replaced `computer.pullSignal` (`event.lua:33-84`):

1. Compute the nearest timeout (`:49-52`).
2. `event_data = table.pack(handlers(closest - uptime()))` (`:54`). The `__call` goes to `machine.lua`'s `pullSignal`, which yields to the kernel (`machine.lua:1413-1422`).
3. Copy the handler table into `copy` (`:56-59`).
4. For each due handler:
   1. `times = times - 1`;
   2. **remove the handler if `times <= 0`, before calling it** (`:64-70`);
   3. `local result, message = pcall(handler.callback, ...)` (`:72`).

**Who calls `pullSignal`.** In the idle shell:

- `init.lua:17` runs the shell in an `xpcall`.
- The shell reads through `io.stdin:readLine` (`bin/sh.lua:25`), then `tty.stream.read` (`tty.lua:61-74`), then `core.read`'s loop.
- That loop calls `computer.pullSignal` (`core/cursor.lua:246`).
- The probe itself runs from the `init` listener through `xpcall(shell.execute, event.onError, ...)` (`boot/90_filesystem.lua:45-51`) and returns. From then on its code runs only as timer callbacks.

### 2.2 When a timer callback raises "not enough memory"

- **The error is caught.** It is caught by the dispatcher's `pcall` (`event.lua:72`), which then runs `pcall(event.onError, message)` (`:73-74`).
- **`event.onError` logs, and the logging allocates.** It is `io.open("/tmp/event.log", "a")`, then `pcall(log.write, ...)`, then `log:close()` (`full_event.lua:62-68`). This builds an OpenOS buffered stream, calls the tmpfs component, and registers the handle through the intercepted `fs.open` (`boot/01_process.lua:76-83`).
  - Any refusal there is swallowed by the outer `pcall(event.onError, ...)`.
  - The log goes to the machine's tmpfs, which is in memory and was lost. The harness never read it [not checked].
- **The memory error never reaches a message handler.** `lj_err_mem` throws `LUA_ERRMEM` without one (`lj_err.c:813-833`). So `xpcall` handlers such as `debug.traceback` do not run for it. PUC 5.2 behaves the same.
- **What happens to the handlers:**
  - The failing one-shot handler is already gone (`event.lua:68-70`).
  - Nothing else refers to `step`, so the chain is broken.
  - The heartbeat (`times = math.huge`) is never removed.
  - The `ocljcap` listener removed itself when it returned `false` (`OcljSmoke.scala:3204`, `event.lua:75-76`).
- **Why the machine stays up:**
  - The error ends at `event.lua:72`. `computer.pullSignal` returns normally, and the shell goes on waiting for a key.
  - The kernel never sees an error. Its slice also gives its own per-resume `table.pack` 16 KB beyond the sandbox's top (`lj52shim.c:951-957`).
  - The machine sits idle with the heartbeat painting.

### 2.3 Why the stalled heap ended near 391 KB (`onehalf-string-r1-O-C`)

**The held data were freed** [inference from code and log].

`held` is an upvalue shared only by two closures:

- `step` (`OcljSmoke.scala:3174-3198`);
- the `ocljcap` listener (`:3199-3205`).

`paint` and the heartbeat do not capture it (`:3158-3164`, `:3206-3209`).

After the stall:

- The listener has been removed (§2.2).
- `step` was referenced only by its removed one-shot handler, and briefly by the dispatcher's `copy` table and `handler` local. Those became garbage once that dispatch loop moved on (`event.lua:56`, `:60`).

So the next cycle freed the 3 700 strings and the held array: about 3 700 × 72.7 B for the strings plus 32 KB for the array, roughly 300 KB [estimate].

**Where the heap sat afterwards** [log + code]:

- The proof that followed found the heap below the cap. That reset `od_state` to 0 (`lj52shim.c:1157`) and left `gc_low = 366 467`.
- From then on the cadence below the cap re-arms when headroom falls under `min(w, (total - gc_low)/2)` (`:1196-1199`): `min(159 195, 135 158)`. That puts the next arm at about 501 625 B.
- LuaJIT's own threshold was 732 800 (`CAP-GC` end line), which is past the cap. So the shim's arms were doing all the collecting.
- The heap drifts from about 366 KB toward about 502 KB as the heartbeat's garbage builds, then drops back. 391 247 B is one point in that drift, about 25 KB above `gc_low`.
- The other stalls look the same: 397 081 (O-B3), 399 041 (record E-B3), 455 557 (E-B3 1024 KB, whose cadence gate is wider).

---

## 3. Could stock PUC stall? Bytes per step and landing probabilities

### 3.1 Bytes per step

**Inside the fill's `pcall`.** These are the live object sizes measured on 2026-10-03 (`bench/runs/2026-10-03-ramscale/objsize-2026-10-03.txt`):

| shape | ours (LuaJIT, -joff) | stock (PUC 5.2) |
|---|---|---|
| array | 200 B (line 20) | 312 B (line 4) |
| string | 72.7 B (line 25) | 68.5 B (line 9) |
| closure | 208 B (line 28) | 176 B (line 12) |
| record | 300.3 B (line 30) | 353.7 B (line 14) |

**The garbage per iteration** [estimate, LuaJIT; `lj_str.h:29`]: about 132-136 B. It is one `tostring` of 28-32 B, which `uniq` shares through interning, plus the 24-character and 25-character junk strings (52 B each, `OcljSmoke.scala:3181`). The `string.rep` strings are interned and shared.

**Outside the `pcall`, per step:**

- Sites that break the chain: §1.2 (a) and (b), about 0.89 KB.
- Sites whose refusals are absorbed:
  - the step's `paint`: 5 strings of 44-76 B, about 0.29 KB, plus 4 `gpu.set` component calls I did not size;
  - each heartbeat `paint`: the same again.
- OpenOS's path, where a refusal propagates out of `pullSignal`:
  - `machine.lua`'s `table.pack`: 112 B (`lib_table.c:272-284`: `lj_tab_new(L, 0, 1)`);
  - the dispatcher's `table.pack`: 112 B;
  - `copy`: 64 B plus array growth by handler count;
  - about 0.3-0.5 KB in all.

| shape | ours: inside per batch (live + garbage) | ours: live growth per batch | share of bytes at chain-breaking sites | stock: live growth per batch |
|---|---|---|---|---|
| record | ~43.4 KB (30.0 + 13.4) | 30.0 KB | ~2.0% | 35.4 KB |
| array | ~33.4 KB (20.0 + 13.4) | 20.0 KB | ~2.5% | 31.2 KB |
| string | ~20.6 KB (7.3 + 13.3) | 7.3 KB | ~4.0% | 6.8 KB |
| closure | ~34.4 KB (20.8 + 13.6) | 20.8 KB | ~2.5% | 17.6 KB |

The share column is [estimate]: 0.89 KB over the inside bytes plus about 1.6 KB of other outside bytes.

The held array's doublings (8 B per slot on ours, `lj_tab_resize`; 16 B per slot on stock) add one large request at 2^k + 1 objects. That request is always inside the `pcall` (`OcljSmoke.scala:3179`).

### 3.2 (a) Stock's rule: refused only if, after a full GC, live data + request > cap

The rule is at `lua/lmem.c:84-93` (`luaC_fullgc(L, 1)` then a retry; path `C:/Users/astro/Downloads/JNLua-Natives/lua/src/lmem.c`).

**Where stock can land outside the handler.** Garbage never triggers a refusal, so the crossing is set by live data. It lands outside the handler only if the live data after batch N sit within W of the cap. W is the live plus transient memory needed between that batch's last object and the next batch's first. [estimate, PUC sizes]

- 37 B for the stage string.
- `checkArg`: a 48 B closure and two 40 B `UpVal`s, transient.
- The handler table: 216 B, rehashed to 320 B with the old part still allocated.
- PUC 5.2 **caches closures** (`lvm.c:379-395`, `:833-841`). Step's inner closure has the same upvalues every call, so it allocates nothing until a GC clears the cache (`lgc.c:459-460`).
- So **W_stock is about 0.4-0.8 KB** for the chain-breaking sites.
- Stock has no tiers: a refusal in `paint` is followed by more refusals at the same live level. Those land on the OpenOS path (and from there `init.lua`), or in the kernel, where stock has no slice.
- So a stock out-of-handler landing would more often be a **down** than a stall. [inference]

**The probability per configuration** is W over the live growth per batch [estimate]:

| shape | probability | note |
|---|---|---|
| record | 1.1-2.3% | |
| array | 1.3-2.6% | |
| closure | 2.3-4.5% | |
| string | 6-12% if it crept to the cap | every stock string run in chains B and C was refused at a doubling of the held array (held 1024, 2048, 16384), inside the `pcall`. The creep regime appeared once, on 2026-10-03 (`chain1-tables.md`, 192 KB string, min 853). |

**What the stock data show** [log]:

- Stock's outcome is nearly fixed per configuration: held 287 ×6, 508 ×6, 262 ×5 and 226 ×1, 1024 ×6, and so on.
- Its refusal positions (`held mod 100`) are:
  - 87 (192 KB array: 13 objects × 312 B, about 4.1 KB before the boundary);
  - 86 (256 KB array: about 4.4 KB before);
  - 8, 62, 26, 36, 45, 55, 56, 13;
  - doublings at 1024, 2048, 4096, 8192 and 16384, all inside the `pcall`.
- **None of the 13 stock configurations falls within W of a batch boundary**, so none could have stalled.
- 0 of 40 is not evidence of immunity. With independent draws the expected count would be about 0.7, and P(0) is about 0.5 [estimate].

### 3.3 (b) Our rule: refused if live data + garbage since the last cycle + request > tier top

**Two estimates bracket the per-crossing probability** [estimate]:

- **Garbage-driven crossing**, roughly uniform over allocated bytes: the share column in §3.1. Record 2.0%, array 2.5%, string 4.0%, closure 2.5%.
- **Live-driven crossing near a top.**
  - Near a tier top the cadence re-arms whenever half the remaining distance is spent (`lj52shim.c:1201-1204`). The allocating bytecodes check the GC before they allocate (`lj_func.c:163`; table creation does the same).
  - So used is close to live, and the formula is stock's with our sizes: W_ours is about 0.4-0.9 KB.
  - That gives record 1.3-3.0%, array 2.0-4.5%, closure 1.9-4.3%, string 5.5-12%. String is the most exposed because its live growth per batch is the smallest.

**Observed per run** [log]:

- 5 of 116 = **4.3%** (95% CI 1.4-9.8%).
- By shape:
  - record 1 of 30;
  - array 0 of 28;
  - string 3 of 29 (two of them are one deterministic configuration);
  - closure 1 of 29 (the dropin).

**The order that matters more than the per-shape rates.** Five of the 21 crossings at the reserve top went bad (24%; above both estimates). None of the 116 first crossings did (under both estimates). [log]

- Only the bad crossings at the reserve top happen in ours and not in stock, because only ours lets an absorbed refusal raise the top. The absorbers are listed in §4.
- **Why the reserve top lands outside so much more often is unexplained.** Candidates, all [speculation]:
  - In 3 of the 5 bad runs the kernel took the heap past the sandbox's top, against 2 of the 16 clean reserve-top runs.
  - Pushing past it happens only between resumes, which means at batch boundaries (`lj52shim.c:1080-1083`, `:1203`).
  - At a pinned top, a larger request from the step (§1.3) is refused while the program's 72-300 B allocations still fit.
  - Small numbers.

---

## 4. Every refusal in chains B and C

**Totals** [log]: 116 of our runs have data (chain B 67, chain C 49; 1 boot failure in B).

- **Idle window:** refusals +0 in all 116 (`CAP-IDLE`).
- **Over the fill:**

| chain | class | runs | refusals |
|---|---|---|---|
| B | clean, 1 refusal | 52 | 52 |
| B | clean, 2 or more refusals | 11 | 28 |
| B | stalled | 3 | 10 |
| B | down (dropin) | 1 | 4 |
| C | clean, 1 refusal | 43 | 43 |
| C | clean, 2 or more refusals | 5 | 22 |
| C | stalled | 1 | 2 |

**Where they landed.**

**Clean runs with one refusal (95).**

- The one refusal is the fill's own, caught by its `pcall`. All 95 have `od_peak <= G/2`.
- 17 of them refused a single large request below the burst top:
  - **The held array's doubling: 15 runs.**
    - At 2048: the string runs of E-B3 ×3, D-C ×3, L-C, and `onehalf-closure-r1-D-B3`.
    - At 4096: `one-string-r3-D-B3` and `one-string-r1-L-B3`.
    - At 8192: `threehalf-array` E-B3, O-B3, D-C, L-C and O-C.
  - **Two 256 KB string runs** were refused with `od_peak = 0`, never past the cap: `onehalf-string-r1-E-B3` at 2804 and `onehalf-string-r1-D-C` at 2645.
    - Their refused request exceeded headroom + G/2 (more than about 20 KB) at a count that is not a power of two.
    - [speculation] The interning table's doubling fits: `lj_str.c:308-309` → `lj_str_resize` → `lj_mem_newvec`, `:137`. On GC64 that is 8 B per slot, so 64 KB at 8 192 slots.
    - [not checked] whether such a refusal leaves `num > mask`, so that every new string retries it until a sweep.

**Clean runs with two or more refusals (16)** [log]:

| run | refusals | od_peak gap to the sandbox's reserve top | held vs single-refusal reps |
|---|---|---|---|
| `one-array-r1-E-B3` | 2 | 98 B under | 885 vs 791 / 787 |
| `one-array-r1-L-B3` | 2 | 13 742 under | 2048, final refusal at the doubling |
| `one-record-r3-E-B3` | 2 | 41 under | 617 vs 552 |
| `one-record-r3-O-B3` | 2 | 17 under | 673 vs 605 / 605 |
| `one-string-r1-D-B3` | 6 | 105 past | 5469 |
| `one-string-r2-D-B3` | 3 | 10 under | 4667 |
| `onehalf-array-r1-E-B3` | 3 | 1 under | 1465 |
| `onehalf-closure-r1-E-B3` | 2 | 12 under | 1411 |
| `onehalf-string-r1-D-B3` | 2 | 6 under | 6864 |
| `threehalf-closure-r1-E-B3` | 2 | 24 862 under | 8192, the doubling |
| `threehalf-string-r1-D-B3` | 2 | 17 under | 24891 |
| `one-array-r3-D-C` | 2 | 62 under | 881 vs 799 / 795 |
| `one-record-r1-D-C` | 2 | 13 under | 621 vs 549 / 552 |
| `threehalf-closure-r1-D-C` | 2 | 23 987 under | 8192, the doubling |
| `threehalf-string-r1-D-C` | 8 | 127 past | 21768 |
| `threehalf-string-r1-L-C` | 8 | 51 under | 21764 |

- In every one, the final refusal was the fill's own: `done/N/not_enough_memory`. 13 of the 16 reached within 98 B of the sandbox's reserve top or went past it on the kernel's slice. The other three ended at a doubling of the held array.
- The earlier refusals did not end the fill, so something other than its `pcall` absorbed them. They opened the reserve tier for the fill. In the five runs that have comparators, about 65-98 extra objects, roughly 17-21 KB, about G/2 [estimate].

**The candidate absorbers** [code]:

- `pcall(paint)` at the end of the step and in the heartbeat (`OcljSmoke.scala:3197`, `:3208`).
- **The JIT trace recorder.** Recording runs under `lj_vm_cpcall` (`lj_trace.c:776-777`). An error inside it goes to `LJ_TRACE_ERR` and then `trace_abort` (`:753-757`), which drops the error object (`:653`). A refused IR, snapshot or `GCtrace` allocation is therefore invisible to the program, but it still opens the reserve (`lj52shim.c:1113`).
  - Supporting evidence: refusals were absorbed in 18 of 76 JIT-on runs (D, E, L) against 3 of 40 O runs. Fisher's test gives p = 0.04 two-sided [log + estimate].
- **OpenOS's error path:** dispatcher → `tty` `xpcall` → shell → `init.lua`'s recovery and `event.pull("key")`. Survivable if a collection frees room. The timers keep running inside `event.pull`, so the fill would continue. It would leave "Press any key to continue." on the screen, which the harness does not capture.
- **Finalizer errors:** raised under HOOK_GC, where the credit is 0 (`lj52shim.c:1093`). They are swallowed into an ERRFIN event (`lj_gc.c:527-533`). No `__gc` in OpenOS's `lib/` or `boot/` by grep, so this is judged rare.
- `pcall(event.onError)`: only after a stall.

**Stalls (4).** One refusal per run at site (a) or (b) (§1.2), caught by OpenOS's dispatcher `pcall` (`event.lua:72`). The rest were absorbed before or after it. The order cannot be read from the counters (§1.3).

**Down (1).** The fatal refusal was not caught by any handler that led to recovery (§1.4).

**In the kernel.** No kernel-thread refusal can have happened in any of the 115 runs that stayed up: `machine.lua`'s main loop has no `pcall` (`:1517-1542`). The dropin's death is the only candidate, and §1.4 favours the `init.lua` path.

---

## 5. What the logs cannot say, and how to find out

### Not in the logs [not checked]

- The screen beyond rows 15-18 after the fill. The harness prints the whole screen only after boot.
- `/tmp/event.log`, which `onError` writes on the tmpfs.
- The JIT abort counter `__ocljTr`. It is attached for capacity runs (`OcljSmoke.scala:4068-4071`), but `finish()` at `:4227` runs before it is read at `:4236`.
- The size, tier and thread of each refused request. The shim keeps only counts and maxima (`lj52shim.c:1108`, `:1143-1144`).
- `str.num` and `str.mask`, and the size of each Lua stack.
- Whether the heartbeat counter (`OCLJCTR`) kept advancing after a stall.
- The allocations of `paint`'s component calls.

### Instruments that would settle the stall site

These are proposals only; the repo is read-only for this survey. Each one in the sandbox allocates nothing: number upvalues, painted by the heartbeat.

1. **In the probe:**
   - `entered = entered + 1` as `step`'s first statement;
   - `timed = count` after `event.timer` returns;
   - `local okp = pcall(paint) if not okp then pf = pf + 1 end` at both sites;
   - a wrapped `event.onError` that counts errors before calling the original.

   Reading the counters:

   | reading | refusal site |
   |---|---|
   | `entered == batches + 1` | the closure, site (b) |
   | `entered == batches` and `timed < count` | `event.timer`, site (a) |
   | `pf` | refusals absorbed by `paint` |
2. **In the harness:**
   - dump the full screen after the fill;
   - read `/tmp/event.log` through the machine's tmpfs;
   - read `__ocljTr.abort` before and after the fill.

   The `abort` event carries the error object (`lj_trace.c`, the vmevent block in `trace_abort`).
3. **In the shim, a design decision:** add three `_OCLJ_WALLSTATS` fields:
   - the size of the last refused request;
   - whether the refusing thread had the kernel's slice;
   - refusals while `G2J(g)->state != LJ_TRACE_IDLE`, which are absorbed by the recorder.

   With these, the reserve-top asymmetry in §3.3 can be attributed.

---

## 6. Corrections and implications for the record

### Corrections

- **The stage string is not a stall site.** `bench/results-wall-2026-10-04.md:438-442`, `docs/roadmap.md:159` and `scripts/analyze.py:13-15` all list it. In all four stalls the painted rows rule it out. What remains is `event.timer` (more likely by bytes) and the `pcall` closure.
- **The dropin's death has a third path.** "Landed in OpenOS's dispatcher or the kernel" (`results-wall:443-445`) should add the route the error takes from the dispatcher into `init.lua`'s unprotected recovery loop (`init.lua:20-24`). That is my preferred account [inference].

### For the idea on record

The idea is "lend the first crossing after each proof and let the cycle it arms decide". [inference]

- **Where it cannot help.** In the dropin, and at the two reserve tops that were overrun, live data alone sat at or past the top. In the dropin the live set was 769 B under it.
- **Why.** Moving the refusal to the next allocation after a collection only rescues crossings that garbage covers. A top pinned by live data is refused again, wherever that next allocation is.
- **What the logs cannot say.** Whether the stall crossings were covered by garbage.
- **The common factor in all five bad runs** is the second chance described in §0.1: an absorbed refusal gives the fill the reserve tier.
