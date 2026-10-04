# Stock OpenComputers on PUC 5.2: how memory refusal and collection work

**What was read.** PUC Lua 5.2.4 in `C:/Users/astro/Downloads/JNLua-Natives/lua/src` (cited as `lua/…`). Its only commit, 156e6e7, is titled "normal lua and jnlua without repack or eris". OC ships an Eris-patched 5.2, so whether Eris changes `lmem.c` or `lgc.c` is **not determinable by reading** this tree. `OC-JNLua/native/src/jnlua.c` is cited as `jnlua.c`. OC sources come from the GTNH 1.12.55 sources jar; I unpacked them into the scratchpad. No build or run was done, and nothing below was executed.

## 1. `luaM_realloc_` and the emergency collection

- **Failure path.** It calls `frealloc` once. If that returns NULL and `nsize > 0`, it checks `g->gcrunning`. If the collector is running, it calls `luaC_fullgc(L, 1)` and then calls `frealloc` once more. If the retry also returns NULL, it calls `luaD_throw(L, LUA_ERRMEM)` (`lua/lmem.c:84-93`). If `gcrunning == 0`, nothing is collected and the throw happens immediately (`:88`). `GCdebt` is only charged on success (`:96`). `HARDMEMTESTS` is not defined: `build.gradle:6-9` defines only NDEBUG, _REENTRANT and LUA_USE_LINUX.
- **What emergency mode skips:**
  - **Finalizers.** `callallpendingfinalizers` is skipped both before and after the cycle (`lua/lgc.c:1193-1198, 1214-1215`). `atomic()` still runs `separatetobefnz` and `markbeingfnz` (`:1022-1024`). So unreachable objects that have `__gc`, and everything they reference, are resurrected and are not freed by this cycle. They are finalized later, at a normal step (`:1169-1170`) or at a non-emergency full collection.
  - **String table shrink and concat buffer free.** `checkSizes` does nothing in emergency mode (`:778-786`). The string table is not halved, and `luaZ_freebuffer(&g->buff)`, the concatenation buffer, is skipped.
  - **Thread stack shrink.** `sweepthread` skips `luaD_shrinkstack` (`:702-704`). Extra CallInfo slots *are* freed (`:701`).
- **Cycle shape.** If a cycle is in propagate or atomic, everything is first re-whitened through `entersweep`, which collects nothing. Then the collector runs to pause, starts a fresh cycle, and runs that cycle to pause (`:1199-1207`). The partial incremental work is thrown away, and a complete mark from scratch is guaranteed.
- **Pause after the cycle.** `setpause(g, gettotalbytes(g))` sets threshold = 2 × the post-collection total (`:1213`, `:913-921`).
- **What is raised.** `seterrorobj` reuses `g->memerrmsg` (`lua/ldo.c:86-87`). That string is the preallocated, fixed literal "not enough memory" (`lua/lstate.c:42, 192-193`), so raising the error allocates nothing. Because `luaD_throw` is called directly, `luaG_errormsg` (`lua/ldebug.c:590-599`) never runs, so **an xpcall message handler is not called for a memory error**. It is caught as `false, "not enough memory"`.

## 2. JNLua's allocator (`l_alloc_checked`, `jnlua.c:251-288`)

- **Every call** briefly swaps the allocator to `l_alloc_unchecked` to call `getjavastate` (a `lua_getfield` on the registry), then swaps it back (`:255-257`). It then makes two JNI `GetIntField` calls (`:1950-1953`).
- **Free** (`nsize == 0`): calls `free(ptr)` and then `setluamemory(used - osize)` (`:262-266`).
- **Grow or allocate.** `delta` is `nsize` for a new block and `nsize - osize` for a realloc (`:268-273`). The call is allowed if `total <= 0`, or `delta <= 0` (shrinks never fail, `:274-276`), or `total - used >= delta`. Otherwise it **returns NULL** and leaves `used` unchanged (`:276-281`). A realloc is charged only its growth.
- **Across an emergency collection.** There is no reservation and no lock. Every free during `luaC_fullgc` goes through the free path above, so `used` drops immediately, one JNI `SetIntField` per freed object. The retry at `lmem.c:90` re-reads `total` and `used` from Java. A stock full collection therefore pays one JNI round-trip per freed block.
- **Uncounted bytes.** `luaL_newstate()` runs on the default allocator before `lua_setallocf(l_alloc_checked)` (`jnlua.c:289-297`). Its own allocations are never counted, so `used` slightly under-counts the real heap.
- **How OC reads `used`.** `getFreeMemory` = `max(0, total - used)` (`OC-JNLua/src/main/java/.../LuaState.java:503-508`). `kernelMemory` = `total - free` taken right after a non-emergency collect (`NativeLuaArchitecture.scala:220-221`). The cap is `kernelMemory + ram × ramScale` (`:158`).

## 3. When a sandbox program sees "not enough memory" on stock

**The base rule.** Only when, after a non-finalizing full collection, `used_after + delta > total`. But `used_after` is more than the live data:

- **Not reclaimable in emergency mode:**
  - Objects pending finalization and everything they reference (§1). This includes JNLua's Java-object userdata, which always carry a `__gc` (`jnlua.c:226-227`).
  - The concat buffer `G(L)->buff`. After `a..b..c`, `luaV_concat` leaves a buffer the size of the result allocated and counted (`lua/lvm.c:319`, `lua/lzio.c:68-73`) until a non-emergency cycle ends.
  - An oversized string table.
  - Thread stacks that are oversized after deep recursion.
- **Transient peaks count, not just the final block:**
  - Table rehash allocates the new node vector before freeing the old one (`lua/ltable.c:312` vs `:333`).
  - Concat holds the operands, the buffer and the result string at once.
  - `luaL_Buffer` doubles into a new userdata before dropping the old one (`lua/lauxlib.c:441-451`). This covers `string.rep`, `table.concat` and `string.format`.
- **String table growth.** When `nuse >= size`, `luaS_resize(size*2)` is called (`lua/lstring.c:121-122`), and it goes through the same failing path (`:64-75`). Creating a short string can be refused because of a jump of size × 8 bytes, even when the string itself would fit.
- **Stack growth.** `luaD_growstack` → `luaD_reallocstack` → realloc can raise `LUA_ERRMEM` (`lua/ldo.c:161-190`). `LUAI_MAXSTACK` is 1,000,000 slots (`lua/luaconf.h:357`), so on small RAM, deep Lua recursion fails with "not enough memory" before "stack overflow". CallInfo is also allocated per call level (`lua/lstate.c:112-113`).
- **No emergency collection at all when `gcrunning == 0`:**
  - Inside every `__gc` finalizer, because GCTM clears `gcrunning` (`lua/lgc.c:818-826`).
  - Under a GC STOP (`lua/lapi.c:1027-1029`). OC stops the collector only during persist and unpersist, with the limit lifted (`PersistenceAPI.scala:125/148, 158/172`; `NativeLuaArchitecture.scala:354, 399`).
- **C and Java allocations:**
  - Every Lua-internal allocation goes through the checked allocator.
  - Java pushes made from callbacks run protected. For example, `lua_1pushstring` uses `JNLUA_PCALL` (`jnlua.c:33-38, 712-725`), so a refusal surfaces as `LuaMemoryAllocationException` (`jnlua.c:2313-2315`).
  - OC's callback wrapper turns that exception into the return values `true, nil, "not enough memory"` (`NativeLuaArchitecture.scala:82-90`). The program sees a **return value, not an error**.
  - In a synchronized call it becomes `OutOfMemoryError` (`:185-190`).
  - When the failure happens while pushing signal arguments at resume time (`:229-233`), `runThreaded` returns `Error("not enough memory")` (`:295-296`) and the machine stops.
- **How an uncaught error stops the machine.** A memory error the program does not catch reaches `coroutine.resume` in the kernel. The kernel then calls `error(...)` (`machine.lua:1533-1536`), its own pcall catches that, and OC returns `ExecutionResult.Error` (`:265-285`). Kernel allocations such as `table.pack` per resume (`machine.lua:1533`) fail the same way.

## 4. Pacing near the wall on stock

- **Defaults, not changed anywhere.** pause = 200 and stepmul = 200 (`lua/lstate.c:29-38, 304-306`). Neither OC nor JNLua changes them. The OC Scala sources call only COLLECT, STOP and RESTART. `jnlua.c:384-389` is a generic pass-through. The sandbox does not expose `collectgarbage` at all: its only use is `machine.lua:1527`. Generational mode is never enabled (`lstate.c:278`).
- **Far from the cap.** A cycle starts at total ≈ 2 × the estimate (`lgc.c:913-921`, PAUSEADJ = 100). `incstep` then does roughly stepmul / STEPMULADJ = 1 traversed byte per allocated byte (`:1139-1157`), so a cycle needs about one more live-size of headroom to finish.
- **Near the cap** (roughly cap < 2-3 × live): the cap is hit before the threshold or mid-cycle. Each refusal then runs one emergency full collection, discarding the partial cycle (`:1199-1203`). Afterwards the threshold sits at 2 × the post-collection total, which is above the cap, so **no incremental work happens between refusals**.
- **The cost model (derived by reading, not measured).** Each refusal costs one full mark plus sweep, about the size of the heap, plus a JNI call per free. Each refusal frees about cap − live. GC cost per allocated byte therefore grows like cap / (cap − live): about 4 at 75% full, 10 at 90%, 20 at 95%. This slowdown is **hyperbolic in fullness but paid per (cap − live) bytes allocated, never per checkpoint**. That shape fits stock's 1.4-9x in the probe's last batches, but whether the batches sat at those fill levels is not determinable by reading.

## 5. Collections triggered by OC itself

- **`machine.lua:1524-1530`.** `collectgarbage("collect")` runs every 10th iteration of the main loop, which is one per resume of the user coroutine, sync-call returns included. It is gated on `persistKey`, which is set only for the native architecture (`PersistenceAPI.scala:13-21`). It runs after `deadline` is set but outside the user hook.
  - **Stock:** `luaC_fullgc(L, 0)` (`lapi.c:1036-1038`). It runs all pending finalizers before and after, shrinks the string table, frees the concat buffer, shrinks stacks, and resets the pause to 2 × live. This periodically clears the residue that emergency collections leave behind.
  - **Ours:** `lj_gc_fullgc` (`build/.../lj_api.c:1254-1255`; `lj_gc.c:781-803`). It runs finalizers through the GCSfinalize state (`lj_gc.c:711`), shrinks the temp buffer and string table (`:651, :696`), and sets threshold = estimate × pause. It leaves `stepmul` alone (0 if armed); the shim's latch (`native/lj52shim.c:903-904`) restores it once currentwhite has flipped and the state is pause. It does not flush traces.
- **`NativeLuaArchitecture.scala:220`.** A collect after the init run, with the limit at `Int.MaxValue` (`LuaStateFactory.scala:353`), then `kernelMemory` = `used`. On stock this baseline is post-normal-collection, with the string table and buffer shrunk and no JIT component. On ours it includes kernel-init traces, which is problem (4).
- **`load` (`:383`) and `save` (`:421`).** A collect with the limit lifted, after unpersist or persist, which themselves run with the GC stopped. The limit is restored afterwards (`:393, :436`).
  - **GC RESTART on stock** sets debt 0 (`lapi.c:1031-1033`).
  - **GC RESTART on ours** sets threshold = total because `data` is 0 (`lj_api.c:1251-1252`). So persist forces a step at the next checkpoint.

## 6. Parity: what to reproduce, and what not to

**Must reproduce:**
1. **The observable contract.** "Not enough memory" is raised only when a full, non-finalizing, from-scratch collection run at that point could not make room for the request, counting only the growth for reallocs (`lmem.c:88-93`, `jnlua.c:268-276`). A program that catches the error and drops its data must have its next allocation succeed. This is problem (1).
2. **Collection rate proportional to bytes, not checkpoints.** Near the wall, stock does zero GC work between refusals and one full cycle per (cap − live) bytes (`lgc.c:1213`). A per-checkpoint re-arm is the 20-120x of problem (2).
3. **A full means a complete mark from GCSpause.** A collection armed mid-sweep must not count as full (`lgc.c:1199-1207`; LuaJIT's own `lj_gc_fullgc` does the same at `lj_gc.c:786-800`). This is the parking risk in problem (3).
4. **No finalizers in the emergency path** (`lgc.c:1193-1198`). Running them later, at a checkpoint, is fine.
5. **Raising allocates nothing.** The message is preallocated and xpcall handlers are bypassed. LuaJIT already fixes the string at `lj_state.c:202`.
6. **Shrinks never fail**, and frees credit the budget immediately.
7. **A stock-equivalent kernelMemory baseline**, measured after a normal collection. JIT traces should not be counted in it if they are flushed later. This is problem (4).

**Deliberately should not reproduce:**
- **JNI per allocation and per free** (`jnlua.c:252-261`). The shim already avoids this.
- **The uncounted pre-`setallocf` allocations** (`jnlua.c:289-297`).
- **Calling `lua_getfield` on the main state from inside the allocator** (`jnlua.c:255-257`).
- **The skipped string-table, concat-buffer and stack shrinks** (`lgc.c:780-785, 703-704`). These are quirks that reduce capacity, not requirements. LuaJIT's normal cycle does those shrinks at a checkpoint, which is safe.
- **The `int delta` truncation** (`jnlua.c:268-277`, reading only, not run). A request of 2^31 bytes or more becomes negative or tiny, so it passes the cap. For example, `string.rep("xx", 2^31-1)` is about 4 GB, and the sandbox exposes `string.rep` raw (`machine.lua:896`; `lstrlib.c:111-119`). This is a stock cap escape; the shim's accounting should stay 64-bit (`lj52shim.c:373, 434` use `long long`).