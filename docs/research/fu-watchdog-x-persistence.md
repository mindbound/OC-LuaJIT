# Watchdog × persistence: cross-component interactions

All probes are in `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\wd\`. The working tree is exactly as found: `C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c` is unpatched (line 747 still reads `base_ofs = top_ofs = 1 + LJ_FR2;`), no binaries were added to the repo, and `m1/m2/m3` still pass 82/55/39 with the shipping binary. OC sources read directly from `C:\Users\astro\Downloads\OpenComputers-GTNH\`.

---

## (1) A hook armed WHILE persist / unpersist is running

**1.1 Can a hook fire inside eris's own C code at all? — NO GAP.**
`wdpersist.c` mode A arms a *native* C hook (`lua_sethook(L, hook, CALL|RET|COUNT, 1)`) from a second OS thread at 1 / 3 / 5 / 8 / 12 ms into a **17 ms**, callback-free `eris.persist` of a 4000-node graph (565 559-byte blob). In all five runs: `hook_fired=false inside_eris=false` during persist; the hook fired on the first bytecode *after* persist returned. LuaJIT dispatches hooks only from interpreter instruction/call/return dispatch, which eris never enters except through its two documented callbacks. So the exposure surface is exactly the two places the arm named, and nothing else.

**1.2 Unwinding out of a spkey `__persist` callback / a reconstruction closure — NO GAP.**
`wdpersist` mode B: hook fired **6 µs** after arming, inside the `__persist` callback (`inside_eris=1`); the error propagated out of `eris.persist` as an ordinary catchable Lua error; the state was fully usable afterwards (a later persist plus a complete round trip both succeeded). Mode C, same on the load side (hook inside the reconstruction closure, 4 µs): error propagates, a retry unpersist works, a following full GC is clean. Lua-level duplicates in `p1_hookmid.lua` (P1a) and `p1cd.lua` (P1c) agree, including that the restored graph is intact on retry (`w() = 7`).

**1.3 The `__gc`-owned write buffer on the longjmp path — GAP, minor, resolvable.**
It *is* freed, but only at the next GC. Counting-allocator measurement (`uvdead2.c`): aborting a persist whose partial blob was ~240 KB left **274 912 bytes live immediately after the abort**, and −192 bytes after two full GCs. `NativeLuaArchitecture.save`'s failure path (`NativeLuaArchitecture.scala:424-433`) skips the `lua.gc(LuaState.GcAction.COLLECT, 0)` that the success path runs and goes straight to `recomputeMemory`, which re-imposes the per-computer cap. On a small-RAM computer whose cap is under the orphaned buffer, the very next allocation fails → `LuaMemoryAllocationException` → "not enough memory" crash on a machine that was otherwise healthy and merely failed to save.
*Fix:* one line — `lua.gc(COLLECT, 0)` in the `case e: LuaRuntimeException` catch, before `recomputeMemory`.

**1.4 A still-armed count=1 hook poisons every later host→Lua call — GAP, resolvable by discipline.**
`p1b.lua` uses the watchdog's actual shape (count=1, self-re-arming, *not* self-disarming — `docs/watchdog.md` §2). `pcall(eris.persist, …)` caught fire #1 correctly; **fire #2 killed the whole script two instructions later**, outside any protection (`error: WATCHDOG-REARM#2`, exit 2). Whatever the host runs next on that state dies until the hook is cleared. In OC's save path that is `api.save(nbt)` and `lua.gc(COLLECT,0)`; in `runThreaded`'s error path it is everything downstream.
*Fix:* `docs/watchdog.md:37`'s "Always clear the hook before the next resume" is too weak. It must be **unconditional disarm in a `finally` before `runThreaded` returns**, covering `LuaRuntimeException`, `LuaGcMetamethodException`, `LuaMemoryAllocationException` and the `java.lang.Error("not enough memory")` case that `NativeLuaArchitecture.scala:285-300` already catches.

**1.5 Does a deadline at save time silently cost the computer its state? — the premise needs correcting, and (4) closes the window.**
The failure path is `NativeLuaArchitecture.save` → catch → log `"Could not persist computer @…"` → `nbt.removeTag("state")`. On load, `Machine.load` (`Machine.scala:753-818`) reads an empty state array, so `state.nonEmpty` is false and the **else branch calls `close()`**. The computer therefore comes back **switched off, not rebooted**; the filesystem survives, the running state does not, and the only signal is a server-log warning. Given (4) this can only happen if the arm/disarm discipline is broken.

---

## (2) Does persist/unpersist leave hook state disturbed?

**2.1 NO GAP.** `grep -n 'sethook|hookmask|hookf|hookcount'` over `eris_lj.c` returns **nothing** — eris never writes hook state. The only contact is two *reads* of `hook_active(G(L))` (`eris_lj.c:829` write side, `:1377` read side). Measured (`p1cd.lua` P1d): around a persist+unpersist of a graph holding a suspended coroutine, an open upvalue and a closure, `debug.gethook()` returns the identical function, mask `"cr"` and count 7777 before and after; the restored thread resumes correctly. P1e: persist and unpersist both run correctly with a hook armed-but-not-yet-firing (count 100000) and leave it armed and unchanged.

**2.2 The PCALLH guard is coupled to a VM-global the watchdog owns — NO GAP today, worth writing down.**
Both sides refuse `FRAME_PCALLH` unless `hook_active` — i.e. always, at any Java-driven save/load point, which is the intent. The undocumented coupling: `hook_active` is *also* set by `hook_entergc` during GC finalizers and by `hook_vmevent` (`lj_obj.h:681-686`). The guard's correctness therefore rests on the precondition **"the host never calls `eris.persist`/`eris.unpersist` from inside a hook, a GC finalizer, or a vmevent handler."** True for OC (persist is driven from `NativeLuaArchitecture.save/load` on the Java side), but it should be stated, because a read-side `hook_active == true` would *accept* a forged PCALLH frame and latch `HOOK_ACTIVE` permanently — killing the watchdog, the exact failure the F18 check exists to prevent.

---

## (3) The watchdog's error-raise vs. restored coroutines

**3.1 The observable semantics of a restored dead thread are right — NO GAP.**
`p3_dead.lua`: dead-by-error, dead-by-hook-error and dead-by-return threads all restore with `coroutine.status == "dead"` and `coroutine.resume → false, "cannot resume dead coroutine"`. machine.lua's sandbox resume wrapper (`machine.lua:844-864`, transcribed literally into P3d) returns `false, "cannot resume dead coroutine"` — which is what its caller handles. Refusals also behave: a "normal" (resuming) thread, the running thread and the main thread are all rejected with the right messages (P3f).

**3.2 GAP — REAL, HIGH SEVERITY, FIX VALIDATED. A dead-by-error thread that still owns open upvalues persists successfully and can never be loaded again.**

A thread that dies **by error does not close its open upvalues**; only a normal return does. Direct reads of `co->openupval` (`uvdead.c`, `uvdead2.c`):

| death | status | base | top | openupval |
|---|---|---|---|---|
| RETURN | 0 | 2 | 2 | **0** |
| ERROR | 2 | 8 | 8 | **1 [slot 4]** |
| HOOK ERROR (jit off) | 2 | 4 | 11 | **1 [slot 4]** |

and the escaped closure keeps reading the dead thread's stack (`bump()` → 1, 2).

`p_thread` normalises a dead thread to `base_ofs = top_ofs = 1 + LJ_FR2` (`eris_lj.c:747`) but **still writes the open-upvalue list unconditionally** (`eris_lj.c:846-856`) with the original slot indices, and writes none of those slots' values. So the write side succeeds and the read side always rejects. Measured (`p4_deaduv.lua`), thread killed by a real deadline-hook error:

- `{dead thread, escaped closure}` → persist **304 B ok**, unpersist → `eris-lj: open upvalue slot 4 outside the live stack`
- **the dead thread alone**, closure not even reachable → persist **86 B ok**, same rejection
- three open upvalues (`p6_fixcheck.lua`) → `eris-lj: thread claims more open upvalues than slots`
- controls all pass: dead-by-return with an escaped closure round-trips; a *suspended* thread with an escaped open upvalue round-trips; an error-killed thread with **no** open upvalues round-trips.

Why this is more than a watchdog issue: the soft abort *is* "raise an error inside the running coroutine", and every running Lua program has open upvalues (a top-level `local` captured by a `local function` stays open for the program's whole life). But control C shows a plain `error("boom")` reproduces it identically — so any OpenOS process that dies from an ordinary runtime error and is still referenced (process table, `event.listen` registry) at world-save time writes an **unloadable save**. `Machine.load` catches `Throwable`, logs *"Unexpected error loading a state of computer at … please report this!"*, and `close()`s the machine.

*Fix (validated, patch applied only to a scratchpad copy):* keep the slot span covering the still-open upvalues instead of collapsing it — in `p_thread`, replace `base_ofs = top_ofs = 1 + LJ_FR2;` with a scan of `co->openupval` for the highest slot and `top_ofs = highest + 1`, leaving `base_ofs` at the bottom so no frame chain is walked and the thread still reports "dead". The read side already permits this (`u_thread` constrains `base_ofs` when `nframes == 0` but not `top_ofs`, `eris_lj.c:1345-1349`). Results with the patch: **m1 82 / m2 55 / m3 39 still pass**; every p4 case round-trips; `p6_fixcheck.lua` shows full value fidelity (`ga()` continues 102 → 103), preserved upvalue *sharing* between two closures over one slot, survival of five full GCs, and a clean re-persist of the restored graph.
*Rejected alternative:* closing the upvalues at persist time (`lj_func_closeuv`) is semantically free for a dead thread but unsafe mid-walk — a closure over that upvalue may already have been encoded as `TAG_UPVALOPEN(thread, slot)` before the thread is reached.

---

## (4) Arm/disarm discipline for M4

**Established facts (GTNH sources).**
- `Machine.run()` — the pool-thread entry that calls `architecture.runThreaded` — is `Machine.this.synchronized` **for its entire body** (`Machine.scala:983`).
- `Machine.save` is `Machine.this.synchronized(state.synchronized{…})`, bails on `isExecuting`, and `pause(0.05)` before touching the architecture (`Machine.scala:821-833`). `Machine.load` takes the same monitor (`:753`).
- ⇒ **save/load and `runThreaded` are mutually exclusive by the machine monitor**, not merely by the `isExecuting` check. **No genuine overlap window exists**, provided arming is scoped to the resume.
- `Machine.update()`'s `SynchronizedCall` branch calls `architecture.runSynchronized()` — which does `lua.call(0,1)`, i.e. real Lua (`machine.lua:1094-1100`) — **without** the machine monitor, on the server main thread, with state `Running` so `isExecuting` is true (`Machine.scala:596-628`). That `isExecuting` bail is what protects the re-entrant save the code comments about (SpongeForge saving during `robot.move`).

**The discipline M4 must implement, precisely:**

1. Arm **only** around the single `lua.resume(1, …)` inside `runThreaded`. **Never** around `runSynchronized`'s `lua.call` — that runs on the server main thread and an error there lands in `Machine.update`'s `case e: Throwable => crash("gui.Error.InternalError")`, not the timeout path. (Consequence: a wedged synchronized-call closure stays unprotected. Stock OC has the same hole — its Lua hook is armed on `co`, not on the main state — so this is inherited, not introduced.)
2. **Never** derive "a resume is in flight" from `Machine.isExecuting` or the state stack; `runSynchronized` sets `Running` too.
3. Per-machine (per-`lua_State`) lock plus a monotonic epoch:
 - `runThreaded`: `lock { epoch++; myEpoch = epoch; inResume = true; deadline = now + timeout }` → resume → `lock { inResume = false; lua_sethook(L, NULL, 0, 0) }`.
 - watchdog thread: `lock { if (inResume && epoch == myEpoch && now >= deadline) lua_sethook(L, hook, CALL|RET|COUNT, 1) }`.
 The disarm must be **inside** the lock. Without exactly this ordering, a watchdog waking at the deadline can arm microseconds after `runThreaded` returned, and the next thing to run Lua on that state is `Machine.save` → `persistence.persist(1)` → the 1.4 / 1.5 failure.
4. The disarm goes in a `finally` covering **every** exit from `runThreaded`, including all four exception cases already caught at `NativeLuaArchitecture.scala:285-300`.
5. Because `lua_sethook` is VM-global, one watchdog thread serving many machines must key strictly by `lua_State`. There is no per-coroutine hook state to get wrong — and no per-coroutine isolation either.
6. HARD and ABANDON deliberately leave the hook armed after `Machine.run()` returns (`docs/watchdog.md` §3-4). Those states must set a per-machine `condemned` flag — see 5.1.

---

## (5) Other cross-component invariants not yet written down

**5.1 An abandoned thread vs. save and close — GAP, hard at the C level, resolvable at the Java level.**
In ABANDON, `Machine.run()` returns (releasing the machine monitor) while the runner thread is still executing the state. `Machine.save` then acquires the monitor, sees `isExecuting == false` (run()'s post-processing pushed `Paused`/`Stopping`), and calls `architecture.save` → `persistence.persist(1)` **on a `lua_State` another thread is concurrently mutating**. `check_persistable_thread`'s `co->cframe != NULL` test would usually refuse — but reading `cframe` is itself a data race and eris then walks the whole live heap. Separately, `Machine.update`'s `Stopping` branch reaches `tryClose()` (`Machine.scala:927-938`) → `close()` → `architecture.close()` → `lua_close`, guarded *only* by `isExecuting` — precisely the CCLuaJIT use-after-free the design claims to fix. `docs/watchdog.md:39` says "leak the runner + state"; it does **not** say that `save`, `load` and `close` must also be suppressed.
*Fix:* a per-machine `condemned` flag checked by the architecture's `save`, `load` and `close`, and stated in `docs/watchdog.md` §4.

**5.2 CHECKHOOK and other build flags vs. the blob fingerprint — GAP, resolvable.**
`ERIS_LJ_FINGERPRINT` is `ERIS_LJ_COMMIT "|" LUAJIT_VERSION` (`eris_lj.c:85`) — commit and version only, no XCFLAGS. CHECKHOOK itself is benign (it only adds a guard in `lj_record.c`; no layout or bytecode change — which is why `serializer/Makefile` can link `libluajit_stock.a` while the mod ships the CHECKHOOK build, and blobs stay interchangeable). But `LUAJIT_ENABLE_LUA52COMPAT` (set by both watchdog builds, `prototype/watchdog/Makefile:16-17`), `LUAJIT_NUMMODE`, and any non-GC64/32-bit build change semantics or object layout and are equally invisible to the fingerprint.
*Fix:* bake the XCFLAGS set (or its hash) plus `LJ_GC64`/`LJ_FR2`/`LJ_DUALNUM` into the fingerprint string.

**5.3 `jit.flush` before persist — NO GAP, but the docs contradict each other (harmlessly).**
`docs/research/m3-frame-codec.md:343` and `ps-coroutine-frames.md:89` say flush *before* persist; `ps-object-model.md:70,122` and `ps-serializer-foundation.md:26` say persist *before* flush, because `bcwrite_bytecode` needs live traces to un-patch `JLOOP` (`lj_bcwrite.c:300-315`: `memcpy(q, &traceref(J, rd)->startins, 4)`). **Both orders are safe**: `lj_trace_flushall` (`lj_trace.c:276-303`) unpatches every root trace via `trace_flushroot → trace_unpatch` *before* nulling `J->trace[i]`, so after a flush no J-variant opcode is left to resolve; without a flush the traces bcwrite consults are live. Measured with the JIT on (`p5_jit.lua`): a hot proto round-trips to the identical result with no flush, with `jit.flush()` first, and under `jit.off(f)` blacklisting (the `PROTO_ILOOP`/I-variant path); a coroutine suspended out of a compiled loop round-trips and resumes to the correct total (12 502 500) both with and without a flush.
*Action:* keep the flush (it is what makes the `cont_stitch` aux slot the only trace reference that can survive a suspend), and correct the two documents that give the opposite order.

**5.4 Cross-thread `lua_sethook` vs. the persist path — NO GAP beyond threat-model row 11; one invariant to name.**
`lua_sethook` calls `lj_trace_abort(g)`, which is only `G2J(g)->state &= ~LJ_TRACE_ACTIVE` (`lj_trace.h:45`) — a non-atomic RMW on one word of `jit_State`. It never frees a trace, so it cannot invalidate the `traceref(J, rd)` that `bcwrite_bytecode` dereferences. The genuinely dangerous cross-thread JIT call is `luaJIT_setmode` / `jit.flush`, which *does* free traces and mcode (`lj_dispatch.c:257`, `lj_trace.c:297-298`).
*Invariant to write down, next to "the hook must raise, never yield":* **only the VM thread may call `jit.flush`/`luaJIT_setmode`; the watchdog thread may call nothing but `lua_sethook`.** `docs/research/wd-async-precedents.md:89` states the general form; it belongs in `docs/watchdog.md`.

**5.5 The memory-cap allocator during persist/unpersist — GAP, low severity, resolvable.**
OC lifts the cap for the whole of `save`/`load` (`lua.setTotalMemory(Integer.MAX_VALUE)`, `NativeLuaArchitecture.scala:349-356, 396-401`). Two consequences to state: (a) persist and unpersist are **unbounded work with no watchdog and no memory cap**, holding the machine monitor, on the server save path — a very large graph is a server stall with no diagnostic, and the watchdog cannot help because arming during save is forbidden by (4); (b) the orphaned-buffer interaction of 1.3. Mitigation is a blob-size ceiling plus a log warning, not a hook.

**5.6 GC finalizers vs. everything — NO GAP under current settings; a conditional to record.**
Hooks are suppressed during finalizers (`hook_entergc`, `lj_obj.h:683-684`), so the watchdog can never interrupt one — threat-model row 9, mitigated by `allowGC=false`. Two persistence-side consequences **if `allowGC` is ever enabled**: `lua.gc(COLLECT,0)` inside `architecture.save`/`load` runs sandboxed user `__gc` through machine.lua's `sgc` → `coroutine.resume(sgcco)` with `HOOK_ACTIVE` set, so any `pcall` inside a user finalizer builds a `FRAME_PCALLH` frame that eris will then refuse; and machine.lua's own deadline machinery for `sgc` (`machine.lua:708-726`) is built on the standing `debug.sethook` this port deletes, so it must be re-implemented or `allowGC` must stay off. Related and same condition: a finalizer running during a persist-triggered GC step could mutate a table eris has already walked (`p_thread` already re-derives `stack` after every recursive `persist()` because a GC can *move* a coroutine stack, but nothing guards against *mutation*).

**5.7 Incidental re-confirmation.** The stock (non-CHECKHOOK) build again failed to interrupt a JIT-compiled loop promptly: `wdpersist` mode D measured 620 ms deadline→hook latency (the hook only lands at a trace exit), and `p3_dead.lua` P3b saw a compiled 1e9-iteration loop run to completion un-interrupted. Consistent with `docs/watchdog.md`'s A/B result; no new information, but it means every probe above that needed a hook inside Lua had to run with `jit.off()`.

---

## Priority

1. **3.2** — fix before M4. Silent unloadable saves, reachable without the watchdog, with a two-part fix already validated against the full test suite.
2. **4 (items 3 and 4)** — the late-arm race and the missing `finally` disarm are the only ways to reach the 1.4 / 1.5 failures at all.
3. **5.1** — the abandon path currently reaches both a concurrent-heap persist and a `lua_close` on a live state.
4. **1.3, 5.2, 5.3** — one-line / documentation fixes.



# KEY CLAIMS
- [high] A coroutine that dies BY ERROR does not close its open upvalues (only a normal return does); p_thread normalises such a thread to an empty stack yet still writes its open-upvalue list with the original slot indices, so the blob persists successfully (86 bytes for the thread alone) and unpersist ALWAYS rejects it with 'open upvalue slot N outside the live stack'.
- [high] A hook cannot fire inside eris's own C code — only inside the two Lua callbacks (spkey __persist on save, reconstruction closures on load) — and an error raised there unwinds cleanly, leaving the state fully usable.
- [high] Machine.run() (which calls runThreaded) and Machine.save/load are both Machine.this.synchronized for their whole bodies, so they are mutually exclusive by monitor, not merely by the isExecuting check — there is no genuine overlap window, only the risk of a watchdog arming microseconds AFTER the resume returned.
- [high] A still-armed count=1 watchdog hook — the shape docs/watchdog.md prescribes — poisons every subsequent host-driven Lua call on that state: pcall caught the first fire, and the second fire two instructions later killed the process outright.
- [high] jit.flush before persist is neither required nor harmful for the bytecode path — lj_bcwrite un-patches J-variant opcodes from live traces, and lj_trace_flushall un-patches every root trace before nulling J->trace[i], so both orders are safe; four project documents currently give two contradictory orders.

## VERIFICATION
CLAIM: A coroutine that dies BY ERROR does not close its open upvalues (only a normal return does); p_thread normalises such a thread to an empty stack yet still writes its open-upvalue list with the original slot indices, so the blob persists successfully (86 bytes for the thread alone) and unpersist ALWAYS rejects it with 'open upvalue slot N outside the live stack'.
VERDICT: confirmed
EVIDENCE: The bug is real and I reproduced it end-to-end, including the exact 86-byte figure. Only one detail of the claim is wrong (see `correction`): the rejection message is not always the one quoted.

ROOT CAUSE, AT SOURCE (C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/lj_err.c, `err_unwind`, FRAME_CP branch):

    case FRAME_CP:  /* Protected C frame. */
      if (cframe_canyield(cf)) {  /* Resume? */
        if (errcode) {
          hook_leave(G(L));
          L->cframe = NULL;
          L->status = (uint8_t)errcode;
        }
        return cf;            <-- returns WITHOUT calling unwindstack()
      }
      if (errcode) {
        ...
        unwindstack(L, frame - LJ_FR2);   <-- the non-resume path DOES
      }

`unwindstack()` (lj_err.c:99) is the only error-path caller of `lj_func_closeuv`. When an error escapes a coroutine it unwinds to the resume cframe (`cframe_canyield`), which takes the early return, so the thread dies with its open upvalues still open. Confirmed by grep: the only other `lj_func_closeuv` call sites are `close_state`, `lua_close`, and `lj_state_free` (lj_state.c:217/340/390) — none of which run on coroutine death.

SERIALIZER SIDE (C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c, `p_thread`): the normalisation

    if (co->status > LUA_YIELD) { base_ofs = top_ofs = 1 + LJ_FR2; }

is applied before the slot loop, but the open-upvalue block later in `p_thread` is unconditional and writes `uvval(&o->uv) - tvref(co->stack)` — the original, un-normalised slot index. In `u_thread` the two guards are `if (nuv > top_ofs)` ("thread claims more open upvalues than slots") and `if (slot < 1+LJ_FR2 || slot >= top_ofs)` ("open upvalue slot %d outside the live stack"). With `top_ofs == 1+LJ_FR2 == 2` on this GC64 build, the admissible slot range `[2,2)` is empty, so ANY nuv > 0 is unconditionally rejected.

PROBE RESULTS (pinned build, fingerprint `1ee778a4e37122d8ca7d5733c590a47dafd6b15c|LuaJIT 2.1.1787165859`, run via ./erislj_test.exe; probes in scratchpad, since deleted):

  nuv=0  dead  persist ok  84 bytes  unpersist OK
  nuv=1  dead  persist ok  86 bytes  unpersist FAILS: "eris-lj: open upvalue slot 4 outside the live stack"
  nuv=2  dead  persist ok  88 bytes  unpersist FAILS: "eris-lj: open upvalue slot 5 outside the live stack"
  nuv=3  dead  persist ok  90 bytes  unpersist FAILS: "eris-lj: thread claims more open upvalues than slots"

  Same coroutine shape, three endings:
    dies by error()          -> 86 bytes, unpersist FAILS
    normal return            -> 84 bytes, unpersist OK (upvalues were closed)
    yield then return        -> 84 bytes, unpersist OK
    error caught by inner pcall, then return -> 84 bytes, unpersist OK

  Wire size is 84 + 2*nuv, so the claim's "86 bytes for the thread alone" is exactly the one-open-upvalue case.

Additional scenarios, all persist fine and all fail to unpersist with the same class of error:
  (a) the capturing closure is UNREFERENCED and two full `collectgarbage("collect")` cycles run first — the open upvalue survives on the dead thread's `openupval` list anyway (86 bytes, same failure). The bug does not require a live closure reference.
  (b) closure reachable only through the dead thread's own graph — same.
  (c) thread nested in an OpenOS-ish `{co=..., name=..., handler=...}` table — 348 bytes, same failure, so it is not an artefact of persisting the thread as the root.
  (d) THE WATCHDOG SHAPE: error raised from an injected count hook (`debug.sethook(co, fn, "", N)` with `jit.off()`), matching docs/watchdog.md stage 2 ("soft error", `lua_sethook(...COUNT, 1)` -> hook raises `tooLongWithoutYielding`) — 86 bytes, "open upvalue slot 4 outside the live stack".
  (e) control: a LIVE suspended thread with open upvalues round-trips fine (577 bytes) — so this is specifically the dead-by-error normalisation, not open-upvalue support in general.

FIX VALIDATED INDEPENDENTLY (in a scratch copy; C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c was NOT edited): scanning `co->openupval` for the highest slot and setting `top_ofs = hi` while leaving `base_ofs = 1 + LJ_FR2` makes every case above round-trip, and m1 82 / m2 55 / m3 39 all still pass. Value fidelity and sharing hold: two closures over one upvalue in a dead-by-error thread restore sharing it (get()=41, inc(), get()=42, original untouched at 41), the restored thread reports "dead" and refuses resume, survives two full GCs, and re-persist is byte-stable (798 == 798).

CAVEAT ON THE FIX I ALSO CONFIRMED: the obvious reading "set base_ofs = top_ofs = hi" does NOT work — it trips a different u_thread guard, `if (nframes == 0 && base_ofs != 1 + LJ_FR2)` -> "eris-lj: thread has no frames but base is at 5, not the stack bottom (2)". Only `top_ofs` may be raised; `base_ofs` must stay at the stack bottom. Notably that broken variant still passes m1 82 / m2 55 / m3 39, i.e. the suite has zero coverage of this path — a regression test for a dead-by-error thread with a surviving open upvalue is needed alongside the fix.

Working tree left exactly as found (repo mtimes unchanged; scratch build and probe binaries deleted).
CORRECTION: Two corrections, neither of which changes the substance:

1. "unpersist ALWAYS rejects it with 'open upvalue slot N outside the live stack'" is over-specified. The rejection is indeed unconditional whenever the dead thread has >= 1 surviving open upvalue, but the message depends on how many: with 1 or 2 open upvalues you get "eris-lj: open upvalue slot N outside the live stack"; with 3 or more the earlier guard `if (nuv > top_ofs)` fires first (top_ofs is normalised to 1+LJ_FR2 = 2 on this GC64 build), giving "eris-lj: thread claims more open upvalues than slots". A third variant, "eris-lj: open upvalue slot %d outside the thread's live stack", lives in u_function's TAG_UPVALOPEN path and can surface instead depending on graph traversal order. Anyone grepping logs for the single quoted string will miss most real cases.

2. "every running Lua program has open upvalues" / "any OpenOS process that dies ... bricks the save" is slightly too broad. A dead-by-error thread with ZERO surviving open upvalues (e.g. `coroutine.create(function() error("x") end)`) persists to 84 bytes and unpersists cleanly. The trigger is: died by error AND had at least one open upvalue at the moment of death. In practice that is nearly every non-trivial process, and my probe (a) shows it is even easier to hit than the claim states — the open upvalue survives on the dead thread's list even when nothing references the capturing closure and two full GC cycles have run.

Also worth recording with the fix: raising top_ofs re-serializes the dead thread's stack slots up to the highest open-upvalue slot (86 -> 560 bytes in the nuv=1 probe), because the crashed frame's locals and the closures themselves now go on the wire. That is correct but is a real size regression the normalisation was originally avoiding.

## VERIFICATION
CLAIM: A hook cannot fire inside eris's own C code — only inside the two Lua callbacks (spkey __persist on save, reconstruction closures on load) — and an error raised there unwinds cleanly, leaving the state fully usable.
VERDICT: refuted
EVIDENCE: The claim is two conjuncts. The second holds and is even stronger than stated; the first — the *enumeration* that bounds the exposure surface — is incomplete, and that enumeration is the load-bearing half.

WHAT I DID. Probe at C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\hookprobe.lua, run against the existing C:/Users/astro/Downloads/OC-LuaJIT/serializer/erislj_test.exe (rebuild was a no-op; m3.lua still 39/39). Instead of naming C frames, the hook walks the stack and compares `debug.getinfo(lvl,"f").func` by identity against `eris.persist` / `eris.unpersist`, so "did a hook fire while eris was on the stack" is decided by object identity, not heuristics. 24/24 probe assertions pass.

A. CONTROL — the structural core is right. A count=1 hook armed across a callback-free persist of a suspended coroutine: 357 hook fires total, 0 of them with eris on the stack (564-byte blob). Corroborated structurally: LuaJIT dispatches count/line hooks only from bytecode dispatch, and the one other way Lua could run under eris's allocations — a `__gc` finalizer — is hook-suppressed by `hook_entergc` at prototype/watchdog/luajit/src/lj_gc.c:514 (`lj_obj.h:683` sets HOOK_ACTIVE|HOOK_GC). So no hook fires in eris's own C code.

B. THE REFUTATION — there is a THIRD callback site, hit far more often than either named one. eris_lj.c:965 (save, `persist_keyed`) and eris_lj.c:1563 (load, `u_permanent`) look the object up with `lua_gettable(L, PERMIDX)` on the *user-supplied* perms/uperms table — deliberately, per the comment at eris_lj.c:959 ("lua_gettable: __index applies"). `lua_gettable` in the pinned build (lj_api.c:786-797) falls through to `lj_vm_call` when `lj_meta_tget` returns NULL, so a Lua `__index` on the perms table executes bytecode inside eris. Measured: perms `__index` called 13 times during one persist, hook fired 78 times with `eris.persist` on the stack; the stack seen from inside the hook is `Lua:__index@hookprobe.lua:117 <- C:persist@[C] <- main`. Same on the load side via uperms `__index` (B4). Frequency vs the documented site (case F): 19 perms-`__index` calls vs 1 spkey `__persist` call for the same value — this is the per-object lookup path, not an opt-in metafield. It is reached on every string, table, function and thread that is not already referenced, including from inside `u_thread`'s slot pass while a coroutine is half-built.

I checked the rest of eris's C-API surface for other metamethod escapes and found none: every other table access is `lua_rawget/rawset/rawgeti/rawseti/lua_next`, `lua_objlen` is raw for tables in this build (lj_api.c:565-572), `lua_getfield` is used only on eris's own internal settings table, and there is no `lua_settable`/`lua_setfield` on any user table (so no `__newindex` site).

C/D/E. THE SECOND CONJUNCT HOLDS, at the new site too. Hook raising `error()` inside perms `__index` on save: catchable out of `eris.persist`, hook dispatch still alive afterwards (HOOK_ACTIVE not latched — the pcall predates the hook so it is FRAME_PCALL and `err_unwind` runs `hook_leave`), full round trip works. On load I boomed at uperms `__index` calls #1-#4, i.e. mid-`u_thread` slot pass, then forced several full GCs plus 30k-table churn so the GC would walk and shrink the abandoned half-built thread: no crash in any of the four, hooks alive, and the same blob reloaded and ran correctly each time. This is what the code is built for — eris_lj.c:1291-1310 parks `co->top` at `stack+need` and leaves `co->base` at the bottom and `co->status` at LUA_OK until pass 5 (eris_lj.c:1540-1545), so an abandoned thread is GC-walkable. The two documented sites behave identically (E1-E5). Per-call state is all stack-local (`Info I`) or stack-anchored (reftbl/upv tables, the WBuf userdata with its `__gc` at eris_lj.c:262-264), so nothing global is left inconsistent.

CAVEAT ON SEVERITY: for OC as designed the practical surface really is the two named callbacks, because OC's `PersistenceAPI` hands eris a flat plain table (docs/research/m3-oc-shapes.md:225). The claim is wrong as a general statement about the serializer, not as a statement about the shipped OC configuration — but it is stated generally and used to bound the exposure surface, and a host that ever passes a lazy/proxy perms table (a memoising or on-demand uperms is an obvious optimisation for a big `_G` flattening) silently moves from "one callback per spkey table" to "one callback per object".
CORRECTION: Replace "only inside the two Lua callbacks (spkey __persist on save, reconstruction closures on load)" with THREE callback kinds, four sites:

1. spkey `__persist` on save — eris_lj.c:889 (`lua_call`)
2. reconstruction closure on load — eris_lj.c:1221 (`lua_call`)
3. `__index` on the perms table, save — eris_lj.c:965 (`lua_gettable(L, PERMIDX)`)
4. `__index` on the uperms table, load — eris_lj.c:1563 (`lua_gettable(L, PERMIDX)`)

Sites 3/4 are the ones that matter for bounding the surface: they run once per not-yet-referenced object rather than once per opt-in table (measured 19 vs 1 on the same value), and site 4 can run while a coroutine is half-built inside `u_thread`. They exist by design — the comment at eris_lj.c:959 says so — and `lua_gettable` reaches Lua code via `lj_vm_call` (lj_api.c:790-795).

Everything else in the claim stands, and is now verified at the new sites as well: no hook can fire in eris's own C code (no bytecode there; `__gc` finalizers are hook-suppressed by `hook_entergc`, lj_gc.c:514), and an error raised in any of the four callbacks is an ordinary catchable Lua error that unwinds without latching HOOK_ACTIVE, without leaving a GC-hostile half-built thread, and without breaking a following full round trip — including when it lands mid-`u_thread`.

Practical qualifier worth recording alongside the correction: OC's own perms table is flat and plain (docs/research/m3-oc-shapes.md:225), so in the shipped configuration the two named callbacks are the whole surface. If that is the intended scope, the claim should say "with a plain perms table" rather than "only"; otherwise the host contract should state that the perms/uperms table must not carry a Lua `__index`.

## VERIFICATION
CLAIM: Machine.run() (which calls runThreaded) and Machine.save/load are both Machine.this.synchronized for their whole bodies, so they are mutually exclusive by monitor, not merely by the isExecuting check — there is no genuine overlap window, only the risk of a watchdog arming microseconds AFTER the resume returned.
VERDICT: confirmed
EVIDENCE: TRIED HARD TO REFUTE; THE CORE HELD. All evidence is first-hand, from the PINNED dependency (C:/Users/astro/Downloads/OC-LuaJIT/dependencies.gradle -> com.github.GTNewHorizons:OpenComputers:1.12.58-GTNH:dev), not from memory. OC is not vendored in this repo, so I probed the artifact itself.

PROBE 1 — javap -v on li.cil.oc.server.machine.Machine from the 1.12.58 dev jar (C:/Users/astro/.gradle/caches/modules-2/files-2.1/com.github.GTNewHorizons/OpenComputers/1.12.58-GTNH/6317dc8c8362cc4f00bc1b61f509356c351e7977/OpenComputers-1.12.58-GTNH-dev.jar; disassembly kept at <scratchpad>/machine58.javap and machine58.verbose):
* "public synchronized void run();  flags: ACC_PUBLIC, ACC_SYNCHRONIZED"
* "public synchronized void save(net.minecraft.nbt.NBTTagCompound);  flags: ACC_PUBLIC, ACC_SYNCHRONIZED"
These are the ONLY two ACC_SYNCHRONIZED methods in the class. scalac folded `Machine.this.synchronized { <entire body> }` into the method flag, so the monitor on the Machine instance is held for the whole body by construction.
* run() body: monitorenter@6 / monitorexit@101,152 is only the inner `state` monitor; `170: invokeinterface Architecture.runThreaded:(Z)LExecutionResult` sits OUTSIDE that inner region but inside the method-level monitor on `this`. `isExecuting()`@824 (the post-run assert). Grep of the whole disassembly for Object.wait / .await / LockSupport / Thread.join found NOTHING, so the monitor is never released mid-body.
* save() body: `6: monitorenter` (state), `8: invokevirtual isExecuting()`, early `15: monitorexit; 16: return`; `238: invokespecial liftedTree2$1` -> `Architecture.save(nbt)` (liftedTree2$1 disassembly confirms `invokeinterface Architecture.load/save`).
* load() is NOT ACC_SYNCHRONIZED but does it explicitly: `0: aload_0; 1: dup; 2: astore_2; 3: monitorenter` (lock on `this`), `10: monitorenter` (state), `291: invokespecial liftedTree1$1` -> `Architecture.load`, `306/308: monitorexit` (+ handler copies 311/314). Whole body, same guarantee.
=> run()/runThreaded vs save()/load() ARE mutually exclusive by the Machine monitor on the pinned build. Confirmed.

PROBE 2 — the same disassembly for update(): NOT synchronized; `1002: invokeinterface Architecture.runSynchronized:()V`. Its exception table shows the nearest monitor region is 627..639 on `state` (`627: monitorenter ... 638: monitorexit`, i.e. the `state.synchronized(state.top)` match scrutinee, released BEFORE the match body), and the try range wrapping runSynchronized is 993..1215 with no monitor held. => runSynchronized runs on the server main thread with NO Machine monitor. The claim's second half is confirmed too.

PROBE 3 — killed the strongest refutation candidate. If the eris persist were deferred into a SaveHandler callback it would escape the monitor entirely. javap of li.cil.oc.server.machine.luac.NativeLuaArchitecture.save (same jar) shows `86: PersistenceAPI.persist:(I)[B` then `89: SaveHandler$.scheduleSave:(...;[B)V` (and 216/219 for the "_stack" slot) — persist is EAGER, returns Array[Byte], only the byte array's disk write is deferred. So the actual Lua persist executes synchronously inside save()'s ACC_SYNCHRONIZED body. No escape hatch.

CROSS-CHECK — sole callers, from the 1.12.55-GTNH sources jar (nearest sources available; bytecode above shows 1.12.58 has the identical shape), extracted to <scratchpad>/ocsrc: `architecture.runThreaded` appears exactly once outside javadoc, Machine.scala:1000, inside run(); `architecture.runSynchronized()` exactly once, Machine.scala:603, inside update(). Machine.scala:982 carries the author's own comment: "This is a really high level lock that we only use for saving and loading."

TREE STATE: I wrote nothing into the repo — every artifact (extracted jars, javap dumps) is under the session scratchpad; no binaries built, no repo file edited. Note that `git status` in the repo now shows modifications to .gitignore, docs/persistence-study.md, docs/roadmap.md, docs/watchdog.md, serializer/README.md, serializer/eris_lj.c and serializer/tests/m1.lua that were NOT in this session's start-of-conversation snapshot; none of them are mine (probably a sibling agent), and I deliberately did not "restore" them.
CORRECTION: The claim is right and the rule it implies is right, but two of its supporting sentences need sharpening before you build on them.

1. "not merely by the isExecuting check" understates it — `if (isExecuting) return` in save() is LOAD-BEARING, not redundant, and there IS a genuine overlap window; it just isn't the one you were worried about. OC's own comment immediately above that line (Machine.scala:821-826 in the sources jar) says the lock "should guarantee that this never happens regularly. If something other than regular saving tries to save while we are executing code, e.g. SpongeForge saving during robot.move due to block changes being captured, just don't save this at all." That window is real and reachable: update() calls runSynchronized() with NO Machine monitor (probe 2), so a save re-entered from inside a synchronized Lua call finds the monitor FREE, acquires it, and is stopped only by isExecuting. So: "no overlap between runThreaded and save/load" = true; "no overlap between Lua execution and save" = false. Do not delete or weaken that check, and do not assume monitor-held implies not-executing.

2. The monitor is not what protects you from the watchdog. The watchdog timer thread never acquires the Machine monitor, so the monitor gives ZERO exclusion against it: it can lua_sethook at any instant, including after run() has returned and released the monitor while save()/load() is inside eris persist/unpersist on the same lua_State. Your per-machine lock + epoch + disarm-in-finally is therefore the whole safety property, not a belt-and-braces addition to the monitor. Keep arm and disarm both inside run()'s monitored body (they naturally are, bracketing the single lua_resume in runThreaded) and make the epoch check the timer thread's only authority to touch the state.

3. One operational consequence worth writing down: the exclusion is BLOCKING, not bail-out. A save arriving during runThreaded parks the server main thread on the Machine monitor until the resume returns — so a wedged resume stalls the saving thread, which is exactly what the HARD/ABANDON staging in docs/watchdog.md has to survive.

