# Emergency-collector design history: memory-accounting.md §8–12, the roadmap rows and accounting-sync.md

Abbreviations: **MA** `C:\Users\astro\Downloads\OC-LuaJIT\docs\research\memory-accounting.md`, **RM** `...\docs\roadmap.md` (line numbers), **AS** `...\docs\accounting-sync.md`, **SHIM** `...\native\lj52shim.c`, **RS** `...\bench\results-ramscale-2026-10-03.md`, **NLA** `C:\Users\astro\Downloads\OpenComputers-GTNH\src\main\scala\li\cil\oc\server\machine\luac\NativeLuaArchitecture.scala`.

## 1. Every design considered, and what happened to it

| Design | Fate | Reason given |
|---|---|---|
| **Collect at the refusal and retry**, copying PUC (a full GC that skips finalizers, then a retry in `lj_mem_realloc`) | Rejected | "Not a collect at the point of refusal. C1, C2 and C6 each independently forbid it … a transliteration of PUC that does not survive contact with this VM, and C3 says the finalizer half of it was aimed at a hazard LuaJIT does not have" (MA:1013-1017). C6 adds: "the allocator is the one place in this tree that provably never collects, and it must stay that way" (MA:1008-1009). |
| **VM surgery: an `isemergency` mode in `lj_gc.c`** | First called "the faithful fix", then retired. Never built. | At first: "VM surgery, not a six-line patch" (MA:416-420). Then C3 overturned it: "Do **not** add an `isemergency`-style guard to `lj_gc_fullgc` … The open question is whether to *add* an emergency variant" (MA:985-989). The built collector has "zero VM lines" (MA:722-723). |
| **GC pacing** (`pause` / `stepmul`) | Not shipped. Grep finds no `setpause`/`setstepmul` call in `native/`, `src/` or the built kernel. | First: "measured *marginal* — `pause=110, stepmul=400` passed in one sweep and failed in another … buys its margin with collector CPU" (MA:406-411), and "0/3 at `ramScale` 1.8 with pause 150 / stepmul 400" (MA:1035-1038). Re-measured in §8e: "a real mitigation and provably not a fix" (MA:712) and "worth shipping as a complement" (MA:1047-1048), but "No pacing value retires it" (MA:1066). `pause` does nothing under churn (MA:669-674). |
| **Emulating the collector in Lua** | Cannot be run | `collectgarbage` is not in the sandbox (MA:551-565). |
| **Deferred collect** ("the allocator refuses … records the pressure, and the next ordinary safepoint … does the collect and the retry") | Built in a changed form as §8f | MA:1019-1027. What shipped arms before the wall, and the VM collects at its own GC checkpoints. There is **no retry**: the refused allocation has already raised (SHIM:378-381). |
| **Runtime watermark estimator** | Deleted before commit; the only trace in git is the note in 8c279a3 | "the proxy available inside the allocator measures the collector's RUN rate, not safepoint density, and cannot observe the quantity its own correctness condition names" (SHIM:787-790). The fixed `max(total/4, 128 KB)` replaced it, justified because `lj_tab_resize` reallocs, "so the positive deltas telescope to the FINAL array size" (SHIM:781-787). Side benefit: deleting it "left no per-state parameter to lose across `eris`" (MA:798-800). |
| **The 5-way judge panel** | Its result is recorded only outside the repo | No repo document mentions it, and commit 8c279a3 has a subject line only. The only record is the auto-memory note `oc-luajit-status.md:310-311`: "The design came from a 5-way judge panel; the winning idea was the currentwhite latch and the discriminator was threshold=gc.total." The losing candidates and their scores cannot be determined by reading. |
| **Writing `threshold = 0`** | Rejected in design review | `debt += total - threshold` would count the whole heap as debt, and the collector would then repay 1024 B per step (MA:743-749). |
| **Disarming on `GCSpause` alone** | Rejected | `GCSpause` is reached from `GCSsweep`/`GCSfinalize` "without ever calling `atomic()`" (MA:751-759). |
| **Including `lj_gc.h`** | Rejected | The shim uses a literal 0 instead, and a build gate checks the enum (MA:761-767). |
| **Flushing traces in the allocator, or whenever the collector arms** | Rejected. The flush runs at the `wd_arm` safe point, after a proven cycle. | The allocator runs inside traces and recording (SHIM:818-825). On arming: "Never raised merely on arming — a small machine idling near its watermark arms constantly" (RM:197). The census boot of AxisOS made 99 542 arms (SHIM:812-816). |
| **Calibrating the RAM scale instead** | Superseded | Old text: "calibration is the answer, not pacing" (RM:157). Now: "a larger scale moves the wall and changes nothing at it" (RS:148-150). |
| **`maxtrace` scaled to RAM** | Open, "now optional" | RM:197 |

**Inconsistency in the docs:** MA:1013 names **C1, C2, C6** as the constraints that forbid collecting at the refusal. MA:725, RM:157 and SHIM:734-744 name **C1, C5, C6**.

## 2. C1–C6, and "What the fix therefore has to look like"

The header says "All nine came back PARTIAL" (MA:950-951), but only six constraints are written down. Which three are missing cannot be determined by reading.

- **C1.** A full collect driven from the allocator hangs on-trace, unconditionally. `lj_gc_fullgc` loops on *state* (`lj_gc.c:800`). `GCSatomic` returns `LJ_MAX_MEM` without advancing while `jit_base` is set (`:673-677`), and `:799` forces `GCSpause` first. A second return that does not advance is at `GCSfinalize` (`:706-710`). Corrections: the guard is executing mcode, not recording, and in `lj_gc_step` `LJ_MAX_MEM` is an "abandon this budget" sentinel (MA:956-972).
- **C2.** It re-enters the allocator. The live site is sweep: `lj_str_resize` → `lj_mem_realloc` (`lj_gc.c:696`, `lj_str.c:139`). A nested refusal longjmps out mid-sweep, with `gc.sweep` pointing into a partially swept list (MA:974-980).
- **C3.** "The finalizer objection is backwards". Nothing drives a GC from the allocator (`lj_gc.c:874-875`, `:888-889`), and `lj_gc_fullgc`'s only caller is `lua_gc(LUA_GCCOLLECT)`, where running finalizers is correct (MA:982-989).
- **C4.** There is no re-entrancy guard, and `threshold = LJ_MAX_MEM` mutes only the implicit triggers. A `collectgarbage` call from inside `__gc` re-enters. It is unreachable only because OC leaves `collectgarbage` out of the sandbox, which is "a mitigation by the host, not by the VM" (MA:991-999).
- **C5.** A collect at `lj_tab.c:123-124` frees the table under construction, so `newtab` writes through a dangling pointer at `:46-48` (MA:1001-1004).
- **C6.** `L->top` is stale at arbitrary allocation points. Inside `lj_mem_newgco` the object is partly initialised and already rooted and whitened (`lj_gc.c:893-895`) (MA:1006-1009).

**What the fix has to look like** (MA:1011-1031):
1. It is not a collect at the point of refusal.
2. The shim can reach the VM: `lj_obj.h`, `G(M->L)`, `gc.total` and `gc.threshold` are all in reach, which makes a **deferred** design possible ("the next ordinary safepoint (where `L->top` is sound and `jit_base` is clear) does the collect and the retry").
3. "Whatever the shape, it gets its own adversarial review … nothing is gated on it."

## 3. The documented residual, and whether a proposal exists

- **Ours:** `live + largest inter-safepoint burst <= cap`. **PUC's:** `live + largest single allocation <= cap`. The docs call the gap "real and irreducible without a finer safepoint, which would reintroduce C5 and C6. This narrows the divergence of §8; it does not close it" (MA:846-856, SHIM:792-797, MA:1093-1098).
- **Only observation before 2026-10-03:** `sieveN8` at `pause=110`, with `arms=1, refusals=1`, where PUC died of the deadline instead (MA:838-842; RM:157 cites `bench/runs/2026-09-15-205900-gcfix-scale/rows.tsv:8`). It has not been re-run since the arena.
- **Accepted as the standing divergence** in 1314de5. Hours later the capacity probe showed it is "not rare" (RM:157-158). RS:146-148 treats the "recovery refused" mode as this same residual.
- **No proposal for closing it is written.** RM:158 ends "Next: the design." The nearest existing texts:
  - the deferred-retry idea (MA:1024-1027), whose retry half was never built;
  - C3's "whether to *add* an emergency variant" (MA:988-989).
- **Open point the docs do not settle:** whether any GC checkpoint runs between the probe's caught `pcall` and its next allocation. All 12 "recovery refused" runs show the next allocation refused (RS:137-143), which suggests none does, but this cannot be determined by reading the docs.

## 4. Precedents for a bounded exception to the cap

1. **The `lua_pushcfunction` window: charged, never refused** (MA:182-199; SHIM:1689-1727, where `norefuse` brackets the whole body). The docs give four things that made it acceptable:
   - The bound is a compile-time constant: 38 distinct statics, 48 B each (MA:186-189), about 1.5 KB with the memo table's growth (SHIM:1691-1694). Sandbox code "cannot add a 39th".
   - The bytes are still charged, "so `freeMemory` stays honest". The next allocation refuses "cleanly, where a protected frame exists" (MA:190-192).
   - It covers the whole body, because lightuserdata interning, `rawset` and `incr_top` can each allocate (MA:193-199).
   - The alternative is worse: a refusal there kills the process silently, without reaching `lua_atpanic`, and a negative control proves it (MA:163-175).
   - The collector is also suppressed inside the window (SHIM:889).
2. **The `pending` bank** (MA:230-256; SHIM:400-418). Allocations made before the Java binding exists cannot be refused. They are banked and charged at the first chargeable call. Dropping them instead made `used` go negative and starved OpenOS.
3. **Shrinks are always allowed**, even over the cap. This is in stock jnlua: "Lua expects reduction to not fail" (`OC-JNLua/native/src/jnlua.c:276-278`; SHIM:313-315).
4. **OC lifts the cap itself** to `Int.MaxValue`, for windows the host controls:
   - persisting (NLA:397-400) and unpersisting (NLA:352-354);
   - close (NLA:332-333);
   - converting a kernel error to a string (NLA:277-278);
   - inside `recomputeMemory` (NLA:156);
   - construction: kernel init runs uncapped (AS:169-171).
5. **An overshoot reads as zero free, never negative:** `Math.max(0L, total - used)` (AS:133), and OC clamps `freeMemory` (`ComputerAPI.scala:43-45`).
6. **Anti-precedent.** Machine code (mcode) is outside the cap, unbounded up to 2 MB. The docs treat this as a defect to bound, not as accepted: "an operator sizing a server needs the real figure" (MA:1079-1087; RM:150).

## 5. Statements about OC's contract that a design must keep

- **Enforced like stock:** an unbounded allocation stops *at* the cap as `LuaMemoryAllocationException`, giving "not enough memory", "exactly as on stock OpenComputers" (RM:151). The motivating failure was that "A runaway allocation consumed the server's heap" (MA:36-37).
- **Host safety:** a refusal in a bare JNI frame kills the JVM with no diagnostic. "Enforcing the cap without fixing this is strictly worse than not enforcing it" (MA:163-175).
- **`freeMemory` is exact** at every call, including mid-slice, and "the cap applies to the very next allocation after `setTotalMemory`" (AS:164-166). Java changes the cap around every save, so caching it is wrong (AS:24-26).
- **The cap counts requested bytes, not backing bytes** (MA:147-148). It is "enforced for `allocf` traffic" only (MA:1079). No doc says "a hard ceiling on real bytes" in those words.
- **`kernelMemory`:**
  - taken once per boot, after a full collect at the kernel's first yield (NLA:207-222);
  - granted on top: cap = `kernelMemory + ceil(RAM × scale)` (NLA:158);
  - the sandbox sees `(total - kernelMemory) / scale` (RS:38-47);
  - saved to NBT as `kernelMemory / ramScale` (NLA:377, :415);
  - a bad saved value starves the machine (MA:911-916; that section's "Nothing has run in Minecraft" is stale).
- **The player picks both the allocation rate and the wall** (`ramScaleFor64Bit` and the tiers are settings), so no tuning bound suffices (MA:396-401).
- **Per-state settings do not cross `eris`.** Anything put on `global_State` must be re-established at restore (MA:639-645).
- **The 5 s per-resume deadline:** a design that turns "not enough memory" into "too long without yielding" has "moved the failure". The caveat is that PUC hits the deadline there too (MA:817-830).
- **No `collectgarbage` in the sandbox** is a host property that C4's safety relies on (MA:995-999).
- **User preference** (from your request in this run): the more compatibility with default settings, the better.

## 6. The `kernelMemory` windfall

**Where the traces come from:**
- The harness says the "~200 traces" come from "the bogomips loop and the sandbox build" (`test\native\OcljArch.scala:89-90`).
- `calcHookInterval` (`build\native\kernel\machine.lua:14-46`) spins for a wall-clock 0.05 s (`:15-16`, `:21-22`) under a count hook (`:33`). It was left in on purpose, as "harmless" (`native\kernel\patch-machine-lua.lua:141-143`).
- A hook armed together with CHECKHOOK makes traces re-record rather than abort (RM:147). That suggests the count depends on host speed; this is untested (RS:132-133).
- Why the figure is bimodal (335 513–413 193 B) cannot be determined by reading.

**Kernel init runs uncapped.** The state is built at `Integer.MAX_VALUE` (AS:169-171), and the cap is applied only once `kernelMemory > 0` (NLA:157). The measurement point is `coroutine.yield()` at `machine.lua:1603-1605` ("Yield once to get a memory baseline"), followed by `lua.gc(COLLECT)` at NLA:220-221.

**Could the patched kernel make `kernelMemory` trace-free? By reading, mostly yes:**
- `jit` is a raw-state global: `luaopen_jit` runs at every new state (SHIM:1852; RM:191), and the harness runs `jit.off() jit.flush()` as a raw chunk (`OcljArch.scala:95`).
- The kernel references `jit` nowhere today, and the sandbox gets no `jit` (`machine.lua:1037`).
- So a 13th patch site that calls `jit.flush()` just before `:1605` would unlink every trace, and OC's own COLLECT would sweep the `GCtrace` objects before NLA:221 reads the figure.
- The mod inherits `runThreaded` (`LuaJITArchitecture.java:34`), so the kernel is the only seam between init and the measurement.

**It would not exactly match arm E's 164 393 B.** `lj_trace_flushall` (`build\native\luajit-windows-x86_64\src\lj_trace.c:276-303`) clears `J->trace[i]` and frees mcode. It does **not** free the `J->trace` vector or `irbuf`/`snapbuf`/`snapmapbuf`, which are freed only in `lj_trace_freestate` (`:370-373`). Those recorder buffers, grown during init, would stay in `kernelMemory`. Their size cannot be determined by reading.

**What it would cost small machines today:** the shipped configuration would behave like arm E. On a 192 KB stick:

| | Arm E (trace-free) | Arm D (shipped) |
|---|---|---|
| Idle distance above the 128 KiB watermark floor | 4–22 KB | — |
| Arms in 10 s idle | 1390–2964 | 0–20 |
| Trace flushes in 10 s idle | 16–29 | 0 |
| Boot failures | 1 in 12 | 0 |
| Capacity vs stock (record / array / string / closure) | 1.93 / 2.55 / 1.95 / 1.37x | 4.37 / 5.46 / 4.49 / 3.10x |
| Clean fills | 5/12 | 9/12 |
| Machines down | 3 | 0 |

Sources: RS:161-166, RS:105, RS:113.

So the windfall currently hides problem (2), and removing it before the collector is fixed would expose it. The trace-free figure (164 393 B) is still below stock's 174 605 B (RS:126-127), and E's capacity stays at or above stock in every measured 192 KB cell.