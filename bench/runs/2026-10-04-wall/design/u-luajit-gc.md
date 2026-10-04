# The collector at the wall: a reading of LuaJIT's GC (read-only)

`src` means `build/native/luajit-windows-x86_64/src`. Its `.c`, `.h` and `.dasc` files match `prototype/watchdog/luajit/src` except `lj_func.c`, which carries the penalty-scrub patch and so has 22 extra lines. Every C1–C6 line number in memory-accounting.md §11 still points at the same code. PUC means `JNLua-Natives/lua/src`.

## 1. The step machinery

- **How a step is triggered.** `lj_gc_check` and `lj_gc_check_fixtop` (`lj_gc.h:65-70`) call the collector when `total >= threshold`. The fixtop variant first sets `L->top = curr_topL(L)` when the current frame is a Lua function (`lj_gc.c:760-764`).
- **C call sites: 48 `lj_gc_check` plus 1 `lj_gc_check_fixtop`.**
  - `lj_api.c` has 11 (`:500-751`), `lib_ffi` 10, `lib_buffer` 9, `lib_string` 3, `lib_io` 3, `lib_table` 2, `lj_parse` 2 and `lj_carith` 2. `lib_base`, `lib_bit`, `lib_os`, `lj_load`, `lj_ccall` and `lj_ccallback` have 1 each.
  - The fixtop site is closure creation (`lj_func.c:185`).
  - `lj_meta_cat` has its own inline check (`lj_meta.c:382-385`), which runs after it allocates. The library functions also mostly check after allocating (`lib_string.c:101-102`, `string.rep`).
  - There are none in `lj_tab.c`, `lj_str.c`, `lj_buf.c`, `lj_state.c`, `lj_strfmt.c` or `lj_snap.c` (grep). So table insertion and resizing, stack growth and buffer growth never reach a checkpoint.
- **Interpreter checks (`vm_x64.dasc`).**
  - The `ffgccheck` macro (`:1226-1231`) calls `fff_gcstep`, which sets `L->top` before calling `lj_gc_step` (`:2242-2252`). It is used in `tostring` (`:1383`), `string.char` (`:1954`), `string.sub` (`:1984`), and `string.reverse`, `lower` and `upper` (`:2045`, `:2069-2071`).
  - BC_TNEW (`:3800-3802`, `:3825`) and BC_TDUP (`:3832-3834`, `:3849`) check before allocating. BC_FNEW goes through `lj_func_newL_gc` (`:3785`) and BC_CAT through `lj_meta_cat` (`:3508`).
- **On-trace checks.**
  - `asm_gc_check` (`lj_asm_x86.h:2822-2850`) is emitted at the trace head (`lj_asm.c:2587-2591`), at LOOP (`:1691`), and for IR_GCSTEP (`:1183-1192`). IR_GCSTEP is only emitted by `lj_snap.c:687-688`.
  - Its `steps` argument counts the SNEW, TNEW, TDUP, BUFSTR, TOSTR, CALLA and CNEW instructions in the section (`lj_asm.c:1149,1161,1174,1296,1309,1905`; `lj_asm_x86.h:1864`). NEWREF, i.e. `lj_tab_newkey`, is not counted.
  - `lj_gc_step_jit` (`lj_gc.c:768-777`) repairs `L->base` and `L->top`, steps while `lj_gc_step` returns 0, and returns 1 in GCSatomic or GCSfinalize. That return value is a guard that exits the trace. `lj_trace_exit` then steps the collector off-trace (`lj_trace.c:942-944`) unless HOOK_GC is set.
- **Debt and threshold arithmetic.**
  - GCSTEPSIZE is 1024 (`:32`). The budget is `lim = (1024/100)*stepmul`, which is 2000 at the default stepmul of 200 (`:734`; `luaconf.h:94`).
  - When over the threshold, `debt += total - threshold` (`:737-738`).
  - Step costs: propagating an object costs its size in bytes (`:335-358`); a sweep step covers 40 objects and costs 400 (`:33-34`, `:704`); a string chain costs 10 (`:687`); a finalizer costs 100 (`:716`).
  - When a cycle ends: `threshold = estimate/100*pause`, return 1 (`:741-744`).
  - When the budget runs out mid-cycle: if `debt < 1024`, `threshold = total + 1024` and return -1; otherwise `debt -= 1024`, `threshold = total` and return 0 (`:747-755`).
- **What `stepmul = 0` does.**
  - `lim = LJ_MAX_MEM` (`:735-736`), so the step runs to GCSpause in one call. The exception is a step that returns LJ_MAX_MEM, which happens on trace at GCSatomic (`:674-675`) or GCSfinalize (`:709-710`).
  - That return drives `lim` to 0 or below, the loop exits, and the step sets `threshold = total + 1024`. `lj_gc_step_jit` then forces a trace exit, and `lj_trace_exit` finishes the cycle.

## 2. `lj_gc_fullgc`, and C1–C6 re-checked

`lj_gc_fullgc` (`lj_gc.c:781-803`) works like this:
- If the state is GCSatomic or earlier, it drops the gray lists and sweeps everything under the unchanged white, so nothing is freed (`:786-793`).
- It finishes any sweep in progress (`:794-795`), which can call `lj_str_resize` at `:696`.
- It forces GCSpause and loops on the state value (`:799-800`) through mark, atomic, sweep and finalize. Finalize runs `__gc` through `lj_vm_pcall` (`:522`).
- It sets `threshold = 2 × estimate` (`:801`).

It accepts any starting state. It is only safe off-trace, with `L->top` correct, outside the collector and outside a finalizer, and when the caller holds no unanchored objects. Its only caller is `lua_gc(LUA_GCCOLLECT)` (`lj_api.c:1255`).

| | Verdict |
|---|---|
| C1 | **Holds.** `:674-675` returns without advancing the state, `:799-800` loops on the state, and `:709-710` is the second non-advancing return. The doc's corrections still hold (`:259`, `:636`, `:740`/`:746`). |
| C2 | **Holds in effect; its mechanism is wrong.** At `:696` the root list is fully swept (`:694` tests `*sweep == NULL`). A refusal there leaves GCSsweep at the end of the list, and the next step retries the shrink. The state can be resumed; it is not "partially swept". The real hazards are the throw out through the outer allocation, and C7 below. The shim reference `:290` is stale: shrinks pass at `lj52shim.c:378` and `:440`. |
| C3 | **Holds.** See `:874-875` and `:888-889`; the sole caller is `:1255`. PUC's `lua_gc` passes `isemergency = 0` (`lapi.c:1036-1037`). |
| C4 | **Holds for the VM.** `lua_gc` has no HOOK_GC guard (`lj_api.c:1246-1271`), and `gc_call_finalizer` puts back the old threshold at `:526`, overwriting anything set inside. **The sandbox half can't be checked here:** `machine.lua` is not in this tree. |
| C5 | **Holds.** The table is linked at `lj_gc.c:893-895` from `lj_tab.c:88`/`:103`, then allocated into at `:123-124` and written at `:45-48`. Q4 lists more sites. |
| C6 | **Holds, with a correction and a stronger consequence.** `allocf` runs at `:887`, before the link at `:893-895`, so the object being allocated is never rooted when the refusal happens. The rooted, partly built object is an earlier allocation in a constructor that allocates more than once, which is C5's case. The consequence is worse than stale: atomic sets every slot above `th->top` to nil (`:314-318`). A concrete case: `fff_newstr` (`vm_x64.dasc:1967-1974`) sets `L->base` but not `L->top`, then `lj_str_new` copies from `string.sub`'s source string, which is held only at BASE. |

## 3. When `allocf` returns NULL

- **Entry points.** `lj_mem_realloc` (`:873-875`) and `lj_mem_newgco` (`:887-889`) call `lj_err_mem` before updating `total` and before linking anything.
- **`lj_err_mem` (`lj_err.c:813-833`).**
  - If the status is LUA_ERRERR it raises "error in error handling" (`:815-816`).
  - On trace it sets `L->base = jit_base` (`:819-822`). In a Lua frame it sets `L->top` to the frame top, and puts in a dummy frame if that is past maxstack (`:823-830`).
  - It pushes the "not enough memory" string. That string is preallocated and fixed (`lj_state.c:202`), so `lj_str_new` finds it without allocating (`lj_str.c:331-337`). Then it calls `lj_err_throw` (`:768-798`).
- **On trace, the trace does not exit first.**
  - The Windows x64 build has `LJ_UNWIND_EXT` and `LJ_UNWIND_JIT` (`lj_arch.h:717-724`). `lj_err_throw` aborts any recording (`lj_trace.h:45`), then `err_unwind_win_jit` (`lj_err.c:347-373`, `:379-383`) runs.
  - It walks up to the frame with no `.pdata` (the machine code). `lj_trace_unwind` (`lj_trace.c:978-1010`) maps that address to the covering snapshot's exit stub, and the unwinder stores the error code in `J->exitcode`.
  - `vm_exit_handler` clears `jit_base` (`vm_x64.dasc:2489`). `lj_trace_exit` keeps the error (`:899-902`), restores the snapshot in a protected call (`:921`, `:835-845`), and returns `-exitcode` (`:938-939`).
  - `lj_err_trace` (`vm_x64.dasc:2582`) then rethrows off-trace. `lj_trace_err` is not involved. If the walk fails, the result is panic and exit (`lj_err.c:382`, `:783-797`).
- **New finding: restoring a snapshot can allocate.** Sunk TNEW/TDUP objects and cdata are created during the restore (`lj_snap.c:894-895`, `:846`). So at the cap, *any* trace exit, ordinary guard exits included, can turn into ERRMEM (`lj_trace.c:921-923`).
- **Inside `__gc`.** The finalizer runs under `lj_vm_pcall` (`:522`) with `threshold = LJ_MAX_MEM` (`:516`). A refusal is caught there and only reported as an ERRFIN event (`:527-534`), so in practice it is swallowed. The shim still refuses, and skips arming under HOOK_GC (`lj52shim.c:897`).
- **`lj_str_resize`.** It allocates first (`lj_str.c:139`), so a refusal leaves nothing changed. When called from `lj_str_alloc`, the new string is already linked and counted (`:303-308`); the table simply stays over 100% load until the next resize.
- **`lj_tab_resize` and table creation.**
  - If the array `realloc` is refused, the old array is intact (`:249`). If a table's second allocation is refused, the table left behind is valid and empty (`:107-115`). A half-built closure is safe because `nupvalues` stays 0 until its upvalues exist (`lj_func.c:151`).
  - **One real inconsistency:** the array part grows (`:236-256`) before the hash part is created. If `newhpart` is refused (`:259`), integer keys in `[oldasize, asize)` are hidden behind nil array slots (`lj_tab.h:81-82`), so after a caught OOM those entries read as nil. PUC has the same order (`ltable.c:304-311`), so this is shared and not ours.

## 4. Could a full collection at the refused allocation ever be safe?

A collect-and-retry inside `lj_mem_realloc` would need all of these:

- **(a) Off trace (`jit_base == NULL`).** Atomic cannot run on trace (C1; "Avoids syncing GC objects", `lj_asm_x86.h:2830`). On trace nothing can be reclaimed at the refusal.
- **(b) Not re-entrant.** The VM state must not be GC (`:733`, `:785`), and HOOK_GC must be clear.
- **(c) Every live slot of the running thread at or below `L->top`.** This fails at helper calls: `fff_newstr`, the BC_TNEW/TDUP fast paths (`vm_x64.dasc:3796-3812`, `:3829-3842`), and table stores reaching `lj_tab_newkey`. The clearing at `:314-318` turns this into corruption.
- **(d) No unanchored new object further up the C stack (C5).** Sites:
  - `newtab` (`lj_tab.c:88/103` then `:119`/`:124`) and `lj_tab_dup` (`:168`)
  - `lj_str_alloc`: links at `lj_str.c:307`, then resizes at `:309`. The sweep would free the new string (`lj_gc.c:446-450`) and the caller would get a dangling pointer.
  - `lj_func_newL_empty` (`lj_func.c:164` then `:168`) and `lj_func_newL_gc` (`:186` then `:195` then `:76`)
  - `lj_state_new` (`lj_state.c:364` then `:375` then `:175`)
  - The parser and bytecode reader were not audited.
- **(e) New, call it C7: the block being reallocated must not be one the collector itself reallocates.**
  - `g->tmpbuf` grows in `buf_grow` (`lj_buf.c:34`), and atomic shrinks it (`lj_gc.c:651`, `lj_buf.c:90-99`). The retry would then `realloc` a block that has already been freed.
  - A thread's stack grows in `resizestack` (`lj_state.c:72`), and the collector's `shrinkstack` (`lj_gc.c:320`, `lj_state.c:102-106`) can shrink the same stack when `4*used < stacksize`.
  - String-table growth captures the old table (`lj_str.c:132`) before allocating (`:139`). The sweep's shrink (`lj_gc.c:695-696`) can free that table in between.
  - PUC switches exactly these three off during an emergency collection (`lgc.c:703`, `:780-784`).
- **(f) No finalizers.** PUC skips them (`lgc.c:1193-1194`, `:1214`); `lj_gc_fullgc` runs them.

**Verdict.** The allocator cannot see which site is calling it, and no site it can identify meets (c) through (e). Inside an off-trace C library function, (c) is met (`fff_fallback` sets `L->top`, `vm_x64.dasc:2198`), but (d) and (e) still fail inside library calls (`lib_string.c:101`).

Doing it PUC's way means VM changes:
- an emergency flag and a new collector entry point;
- guards at `lj_gc.c:320`, `:651` and `:696`;
- a retry gated in `:869-897`;
- reordering or anchoring in `newtab`, `lj_str_alloc`, `lj_func.c` (two sites) and `lj_state.c`;
- a fix for `L->top` (per site, or conservative marking of the whole stack without clearing — whether that is safe can't be settled by reading).

Even then, nothing changes on trace.

## 5. Alternatives that don't collect in the allocator

- **(A) Bounded overdraft, in the shim only (zero VM lines).**
  - Rule: when a positive allocation would pass the cap and no cycle has been proven since the arm, grant it if `used + delta <= total + G`, and arm as today. After the proof, refuse as now.
  - What it needs from the VM: a checkpoint within G bytes. That exists for TNEW, TDUP and FNEW and for `ffgccheck` (check before), for library functions and `lj_meta_cat` (check after, in the same call), and for traces that contain allocation instructions.
  - Where it gets none: table insertion, stack growth, and buffer growth inside one C call.
  - The "one short string refused" recoveries fit the covered case (`lj_meta.c:382-385` checks after allocating). This is from reading, not measured.
  - Difference from PUC: only on a true OOM, where the error moves to a later allocation and real use can reach cap + G.
  - Open question: `freeMemory` can go negative; how OC handles that can't be settled by reading.
  - Prerequisite: the problem-(3) fix in Q6.
- **(B) Raise the error at a checkpoint.** LuaJIT has no hook here: there is no GC VM event, and `lj_gc_step` calls nothing back. This would need about 10 lines in `lj_gc_step` at the end of a cycle (`lj_gc.c:741-745`). Every checkpoint caller already tolerates ERRMEM from a step, because stock reaches it via `:696`; on trace, the check carries a snapshot (`lj_asm.c:2589`). The hazard: the checkpoint can fall outside the pcall that covered the overdrawn allocation, so the error escapes it — the "machine down" mode.
- **(C) The instruction hook as the safe point, in the shim.**
  - `lj52_wd_inject` (`lj52shim.c:1117-1123`) already sets a count=1 hook.
  - When that hook runs, `lj_dispatch_ins` has fixed `L->top` exactly (`lj_dispatch.c:420-422`) and recording has been aborted (`:372`). Execution is off-trace, because the CHECKHOOK guard makes traces exit (`lj_record.c:2953-2972`). The hook never runs inside a finalizer (`lj_dispatch.c:370`; `lj_obj.h:683-684`).
  - So a collection there meets (a) through (e). It still runs finalizers (C3), and it would need lifting the collector gate in `build-native.sh` and sharing the hook inside `lj52_wd_hook` (`:1046-1112`), bypassing its thread filter.
  - Raising the error from the hook is worse than (B), since the next instruction can come after pcall has returned. Use it to collect only, together with (A), so the overdraft window shrinks to one instruction or one trace iteration.
- **(D) Exit the trace and re-execute.** This needs a special exit code that `lj_trace_exit` treats as an ordinary exit (`lj_trace.c:899-902`, `:938-939`; it is set at `lj_err.c:363`). Whether re-executing from the covering snapshot after a helper has partly run is idempotent can't be settled by reading.

## 6. Estimate, the pause, and what a re-armed cycle costs

- **What `estimate` means.**
  - It is set to `total - udsize` at atomic (`:657`) and reduced by what each sweep step frees (`:686`, `:693`) and by finalizer adjustments (`:712-715`).
  - At the end of a cycle it is the live objects **plus every non-object allocation counted in `total`**: the string table, stacks, tmpbuf, JIT buffers, and GCtrace objects kept alive by `pt->trace` (`:287`). Objects allocated after atomic are in `total` but not in `estimate`.
  - An armed cycle started at GCSpause off-trace allocates nothing while it runs, so at its end `estimate == total`, less 100 per finalizer.
- **Why the threshold is 2 × estimate.** It is `(estimate/100)*pause` (`:742`, `:801`), which is PUC's "pause until memory is at 200%" (`luaconf.h:93`): the next cycle starts after about `estimate` more bytes. Once `estimate > cap/2`, that schedule can never fire again, and only the shim's arm starts cycles.
- **Problem (3) is confirmed by reading.**
  1. The shim arms while the collector is in GCSsweep or GCSfinalize.
  2. The next step finishes the old cycle without running atomic, and `:742` sets the threshold to 2 × estimate.
  3. The white has not flipped, so the shim stays armed (`lj52shim.c:902-904`).
  4. If 2 × estimate is above the cap, no checkpoint ever fires. The collector stays parked until ARMCAP, 65 536 allocator calls, counted as a bailout (`:865`, `:916-925`).

  A shim-only fix: while armed, if the state is GCSpause and the white has not changed and `threshold > total`, set `threshold = total` again.
- **Cost of one armed cycle.**
  - It is O(N) in a single call: mark ∝ live bytes (`:324-364`); atomic ∝ the running thread's stack size (`:314-318`); string sweep ∝ the string-table size plus the number of strings; sweep ∝ all objects, live and dead (`:405-428`); plus any finalizers.
  - On trace it also costs a trace exit (`lj_trace.c:942-944`).
- **Problem (2) by the same arithmetic.** After a proven cycle that leaves `used > total - w`, the next allocator call re-arms (`lj52shim.c:930-941`), so every checkpoint pays O(N). Stock pays an amortized ~2× the bytes allocated (stepmul 200). The ratio grows with N divided by the allocation between checkpoints, which fits 20–120x, though the exact factor can't be derived without timings.
- **A possible remedy.** Hysteresis, re-arming only after a fixed fraction of the headroom left after the last cycle has been used, would bound full cycles to O(log headroom) per approach to the wall.