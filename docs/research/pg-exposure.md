# How exposed is a real OpenComputers computer to the `for-in` refusal?

Everything below is measured against the **shipped, unmodified** `erislj_test.exe` (rebuilt from the untouched `C:\Users\astro\Downloads\OC-LuaJIT\serializer\eris_lj.c`, fingerprint `1ee778a4…|LuaJIT 2.1.1787165859`, format 1). I wrote nothing into the repo; all probes are in the session scratchpad. `git status` is byte-for-byte what it was on arrival.

---

## 1. The trigger rule

**The save is refused iff, at the instant of the save, at least one `for … in pairs(t)` / `for … in next, t` loop is still executing anywhere in the coroutine graph reachable from the persisted root.**

"Still executing" means the loop has been entered and has not yet exited. Nothing else matters — not depth, not which coroutine, not the table's shape.

Three axes, all measured (`scratchpad/arm_boundary.lua`, 27 shapes; `arm_boundary2.lua`, 10 shapes):

**(a) Which loop form.** Only the two forms LuaJIT specialises to `BC_ISNEXT`/`BC_ITERN` — a bare global/local/upvalue named exactly `pairs` or `next` at the head of the loop expression (`lj_parse.c predict_next`). Everything else round-trips:

| form | result |
|---|---|
| `for k,v in pairs(t)` | **REFUSED** |
| `for k,v in next, t` | **REFUSED** |
| `local f,s,c = pairs(t); for k,v in f,s,c` | persists |
| `local nx = next; for k,v in nx, t` | persists |
| `for k,v in box.pairs(t)` (any table-field access) | persists |
| `ipairs`, numeric `for`, closure iterators, `while` + `next(t,k)` | persists |

Caveat on the "safe" forms: per `docs/research/fu-forin-gap.md` they persist but restore with a **silently different traversal order** across processes. They are not safer, only unrefused.

**(b) Where the yield is — irrelevant.** Refused with the yield in the loop body, 1 or 3 call frames below it, inside a `pcall`, inside a metamethod invoked from the body, on the first or the last iteration, over a hash table or a pure array, over a perms table (`_G`). The **only** escape is a **tail call out of the loop** (`return f()`): it reuses the frame and drops the control slot. That is exactly why `machine.lua:1155` (`for name, direct in pairs(methods) do … return invoke(…)`) is safe.

**(c) Which coroutine — not just the saved one.** Refused if *any reachable* thread is in that state: held in a local, an upvalue, a plain table, a **weak-valued** table, or an OC-style Lua `coroutine.wrap` closure. A **dead** coroutine that finished its loop is fine — `p_thread` normalises a dead stack to empty (`eris_lj.c:750`).

**No false positives.** A loop that has already exited never trips it. I fuzzed 1200 register layouts (5 nestings × 3 yield depths × 0–3 locals before × 0–4 locals after × 0–3 yield args): **0 false refusals**, and 60 live-loop layouts: **0 misses** (`scratchpad/fuzz_stale.lua`). The rule is exact and deterministic, not a flaky register-reuse artefact — the slot loop at `eris_lj.c:769` only walks `[1+LJ_FR2, top)`, and a finished loop's triple is always at or above `top`.

---

## 2. Where an OC computer actually sits

There are exactly **three** yield primitives in the sandbox:

- **`computer.pullSignal(timeout)`** — `machine.lua:1418`. Everything blocking bottoms out here: `event.pull`/`pullFiltered`/`pullMultiple` (`event.lua:149`), `os.sleep` (`boot/02_os.lua:29`), `term.read`/`io.read`, thread waits.
- **any component or userdata method** — `machine.lua:1094`, `coroutine.yield(function() … end)`. Yields when the callback is not `direct`, **and also when it is direct but the per-tick budget is spent**: `consumeCallBudget` throws `LimitReachedException` (`Machine.scala:290`) → `NativeLuaArchitecture.invoke` catches it and pushes **0 results** (`:76`) → `machine.lua:1097` sees `result.n == 0`, sets `result = nil`, falls into the yielding branch. Budgets are 0.5/1.0/1.5 per tick by CPU tier (`application.conf:162`). So `gpu.set`, `io.write`, `print`, `term.write` are yield sites under load.
- **`computer.shutdown`** — `machine.lua:1409`.

Stack at a save: kernel `main` at `machine.lua:1540` → bios co → OpenOS init/shell/program cos (nested through the sandbox's Lua `coroutine.resume`, `machine.lua:856`) → deepest frame at one of the above.

**Idle is clean** (`scratchpad/oc_shape.lua`, faithful reproduction of `machine.lua` + `event.lua`): a program blocked in `event.pull`, with or without non-yielding handlers, saves fine (3913 B / 4403 B). The `pairs` loop at `event.lua:50` completes before the yield at `:54`; the one at `:57` has not started.

**But OpenOS's own signal dispatcher is a `pairs` loop with a user callback inside it:**

```lua
event.lua:60   for id,handler in pairs(copy) do
event.lua:66     -- we have to remove handlers before making the callback in case of timers that pull
event.lua:72     local result, message = pcall(handler.callback, table.unpack(event_data, 1, event_data.n))
```

The comment at `:66` says outright that OpenOS expects callbacks that block. Byte-identical between OC 1.8.5 and the GTNH fork (`diff` clean).

Measured OC shapes:

| scenario | result |
|---|---|
| S1 idle at `event.pull`, no handlers | SAVE-OK |
| S2 idle + 2 non-yielding `event.listen` handlers | SAVE-OK |
| S3 `event.pull()` inside a user `pairs` loop | **REFUSED** |
| S4 component call inside a user `pairs` loop (budget out) | **REFUSED** |
| S5 an `event.listen` callback that calls `event.pull` | **REFUSED** |
| S6 an event handler doing a `gpu` call | **REFUSED** |
| S7 a thread sysyield bubbling out of the dispatch loop | **REFUSED** |

And with the **verbatim** `pipe.lua` / `thread.lua` bodies (`scratchpad/oc_thread.lua`):

| | |
|---|---|
| T1 thread that only waits for events (`yield_past` root) | SAVE-OK |
| **T2 thread that makes a component call** | **REFUSED** |
| T3 same call from the main process, no thread | SAVE-OK |

T2 is the important one. The sysyield value for a component call is a *function*, so `target ~= co` at `pipe.lua:33` and `pco.resume` yields **onward** at `:37` — straight out of `pcall(handler.callback)` at `event.lua:72`, leaving the machine parked inside `pairs(copy)`. Every `thread.create` registers `mt.private_resume` as an event handler (`thread.lua:211`). **There is no `pairs` anywhere in the user's code in that scenario.**

---

## 3. How often it bites — duty cycle

The right metric is the fraction of **wall-clock time** parked at a refusable yield: a world save lands at a uniformly random instant, and `Machine.save` only bails on `isExecuting` (`Machine.scala:827`) — the machine is parked, not executing, essentially all the time.

Parking costs from OC's own state machine: a synchronized call runs in the **next** server `update()` (`Machine.scala:597`), so the machine sits at `machine.lua:1094` for **≈1 tick = 50 ms per component call**; a sleep parks for its timeout (`:544`/`:584`).

Measured by attempting a persist at *every successive sysyield* (`scratchpad/oc_duty.lua`):

| workload | yields refused | **wall time refused** |
|---|---|---|
| D1 idle at `event.pull` | 0/40 | **0.0 %** |
| D2 daemon, `for i=1,#list` + component calls | 0/40 | **0.0 %** |
| D3 **same daemon, `for addr in pairs(list)`** | 34/40 | **22.1 %** |
| D4 `event.timer(1.0)` callback polling 3 components | 30/40 | **14.8 %** |
| D5 `event.timer(0.5)` callback polling 5 components | 33/40 | **45.2 %** |
| D6 one-shot `pairs` loop printing 5 rows, then idle | 5/40 | **0.1 %** |

The measurements match the analytic model: D5 predicts 5 × 50 ms / 500 ms = 50 % (got 45.2 %), D4 predicts 15 % (got 14.8 %), D3 predicts 20 % (got 22.1 %).

**Evidence for how common each shape is.**

*Shipped OpenOS.* My scanner (`scratchpad/scan_pairs.py`, results in `scan_openos.txt`) over all 129 OpenOS Lua files found **11 `pairs` loops with a yielding call in the body across 9 files**, including three on every install:
- `bin/df.lua:42` — `for proxy, path in pairs(mounts) do … proxy.getLabel() … proxy.spaceUsed(), proxy.spaceTotal()`. Three component calls per iteration, and the keys are **proxy tables** (pointer-hashed) — the worst case for any key-based fix.
- `bin/lshw.lua:36` — `for address, info in pairs(devices) do io.write(…)`
- `bin/components.lua:24`, `bin/set.lua:4`, `lib/core/install_basics.lua:105`, `lib/devfs.lua:40`, `bin/rc.lua:21/57`, `bin/du.lua:54`, `bin/edit.lua:74`
These are interactive one-shots, so on their own they are D6 territory (~0.1 %).

*Stock OpenOS core, no user code at all.* `boot/91_gpu.lua:3` `onComponentAvailable` is a shipped `event.listen` handler that calls `gpu.getScreen()`, `gpu.bind()`, `gpu.getDepth()` — inside `event.lua:60`. Fires on boot and on every gpu/screen hotplug.

*The dominant GTNH control-program architecture.* `Navatusein/GTNH-OC-God-Forge-Control` `lib/program-lib.lua` builds a table of `event.timer(…)` and `thread.create(…)` entries and re-registers them on resume; it also has `for _, line in pairs(self.logo) do term.write(" "..line.."\n") end`. Every poll from such a callback is D4/D5. `MuXiu1997/GTNH-OC-scripts/nuclearReactor.lua:47` has exactly one `pairs` loop and it is `for slot, preset in pairs(LAYOUT) do transposer.getStackInSlot(…)` — pure D3. Conversely `DylanTaylor1/GTNH-Stocking/autoStock.lua` uses `for address in component.list('level_maintainer')` (the `__call` iterator → ITERC → safe) and `for i=1,#stockList` — **0 %**.

**Honest verdict: bimodal, not rare-unlucky.**

- An **idle** computer — shell at a prompt, program blocked in `event.pull`/`os.sleep`, daemon polling with numeric `for` or `component.list` — is at **essentially 0 %**. Measured 0/40 twice.
- A **polling controller**, the standard GTNH shape, is at **15–45 %** whenever its component calls happen inside a `pairs` loop *or* inside an `event.timer`/`event.listen`/`thread` callback. The timer/thread case needs no `pairs` in user code — OpenOS's dispatcher supplies it.

One word decides it: changing `for i=1,#list` to `for addr in pairs(list)` moved D2 → D3, **0 % → 22 %**.

Scale: MC autosaves every 900 ticks (45 s) and snapshots every loaded computer at once, but only the **last** save before a world reload determines what comes back — so P(this computer returns off) ≈ its duty cycle. A base with 20 pairs-driven controllers at 20 % each gives P(at least one returns off) ≈ 99 % per reload.

---

## 4. The consequence, traced end to end

1. `eris.persist` raises a Lua error (`eris_lj.c:931-939`).
2. `PersistenceAPI.persist` rethrows after popping (`luac_PersistenceAPI.scala:131-137`).
3. `NativeLuaArchitecture.save` catches `LuaRuntimeException` → logs one WARN, `"Could not persist computer @ <pos>"` plus the Lua traceback → **`nbt.removeTag("state")`** (`luac_NativeLuaArchitecture.scala:426-432`).
4. Everything `Machine.save` wrote *before* `architecture.save` survives: component list, user list, and **`/tmp`** (`SaveHandler.scheduleSave(host, nbt, node.address + "_tmp", fs.save _)`, `Machine.scala:854`).
5. On load, `nbt.getIntArray("state")` is empty → `state.nonEmpty` is false → the `else` branch calls `close()` (`Machine.scala:774`, `815-818`), which pushes `Machine.State.Stopped`.
6. Nothing restarts it. The tile entity *derives* its flag from the machine (`setRunning(machine.isRunning)`, `Computer.scala:163`), it does not drive it.

**User-visible effect: that one computer comes back SWITCHED OFF — not rebooted.** Blank screen, dark case, and it stays that way until a player right-clicks it or a redstone/network `computer.start()` fires. The only other trace is one server-log WARN. Other computers are unaffected; each tile entity saves independently.

**This corrects the ARM's premise.** "Stopped", not "rebooted" — and that is the *worse* outcome for a player: a controller that rebooted would resume its job, whereas one that is off silently stops the factory until someone notices.

**What is lost beyond in-memory state:**
- **Nothing on real filesystems.** Disks/floppies/HDDs are separate components with their own NBT, saved independently of the machine state.
- **`/tmp` survives** in NBT (written before the failing call), though a later boot may erase it per `eraseTmpOnReboot`.
- **Lost:** the entire Lua heap — shell session, program state, in-flight computation, registered handlers/timers, and **unflushed OpenOS write buffers**. `lib/buffer.lua:19` defaults `bufferMode = "full"`, so a file opened `io.open(path,"w")` holds up to `bufferSize` bytes in Lua memory; those bytes are gone. (stdout/stderr are `setvbuf("no")`, `boot/03_io.lua:13-14`, so console output is unaffected.)
- The machine's queued `signals`, `uptime`, `cpuTime` are written to NBT but never read back — the read is guarded by `state.nonEmpty`.

---

## Probe files (all in the session scratchpad, nothing written to the repo)

`C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\`
- `arm_boundary.lua`, `arm_boundary2.lua` — the 37-shape trigger-boundary map
- `fuzz_stale.lua` — 1200 completed-loop layouts + 60 live-loop layouts
- `oc_shape.lua` — `machine.lua` + `event.lua` reproduction, scenarios S1–S7
- `oc_thread.lua` — verbatim `pipe.lua`/`thread.lua` bodies, T1–T4
- `oc_duty.lua` — the duty-cycle measurement, D1–D6
- `scan_pairs.py` / `scan_openos.txt` — OpenOS static scan
- OpenOS + OC sources read from `oc58full/assets/opencomputers/loot/openos/` and `gtnh-oc/src/main/resources/…/openos/`

## One thing worth flagging separately

`lib/thread.lua:311` installs `handlers_mt.__pairs`. **LuaJIT does not implement `__pairs`** (it is a 5.2 metamethod LuaJIT never adopted). On a LuaJIT-backed OC architecture, OpenOS's per-process handler separation would silently stop working. Out of scope for this ARM, but it is in the same file and it will bite M4.

# KEY CLAIMS
- [high] The trigger rule is exact and binary: refused iff a `for … in pairs(t)` / `for … in next, t` loop is still executing in ANY coroutine reachable from the persisted root — at any call depth, in any table shape. A completed loop never trips it (0 false positives across 1200 fuzzed register layouts); a live one always does (0 misses across 60). The only escape from a live loop is a tail call out of it.
- [high] Exposure is bimodal, measured as fraction of wall-clock time parked at a refusable yield: an idle computer (shell at a prompt, blocked in event.pull/os.sleep, or polling with numeric `for`/`component.list`) is at 0.0%; a polling controller whose component calls sit inside a `pairs` loop or an event.timer callback is at 14.8–45.2%. Changing `for i=1,#list` to `for addr in pairs(list)` alone moved a daemon from 0% to 22.1%.
- [high] Stock OpenOS supplies the `pairs` loop itself: event.lua:60 `for id,handler in pairs(copy) do … pcall(handler.callback, …)` is the signal dispatcher, and it explicitly expects blocking callbacks (comment at :66, "timers that pull"). Verified byte-identical in the GTNH fork. Consequently a plain `thread.create(...)` making one component call trips the refusal with NO `pairs` anywhere in user code — the sysyield bubbles onward at pipe.lua:37 out of the handler, leaving the machine inside pairs(copy). Reproduced with the verbatim pipe.lua/thread.lua bodies.
- [high] The user-visible consequence is that the computer comes back SWITCHED OFF, not rebooted: eris.persist raises → NativeLuaArchitecture.save:426-432 logs and calls nbt.removeTag("state") → Machine.load:774 sees state.nonEmpty false → close() pushes State.Stopped, and Computer.scala:163 derives the tile flag from the machine so nothing restarts it. Files on real filesystem components and /tmp survive; the Lua heap and unflushed OpenOS write buffers (buffer.lua:19 defaults to "full") do not.

## VERIFICATION
CLAIM: The trigger rule is exact and binary: refused iff a `for … in pairs(t)` / `for … in next, t` loop is still executing in ANY coroutine reachable from the persisted root — at any call depth, in any table shape. A completed loop never trips it (0 false positives across 1200 fuzzed register layouts); a live one always does (0 misses across 60). The only escape from a live loop is a tail call out of it.
VERDICT: refuted
EVIDENCE: REFUTED in BOTH directions. The claim's directional core is real — a live *specialised* ITERN loop is refused very robustly, and register reuse alone never produces a false positive — but "exact and binary", "0 misses", "the only escape is a tail call", and above all "statically predictable from source" are all wrong. All results below are mine, this session, against the shipped unmodified serializer (sha1 651b0169..., `make` reported "Nothing to be done"). Probes: C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/fi/{a,b,b3,c,d,e2,final,save,load,save2,load2,shared,shared2,common}.lua

WHAT I CONFIRMED (a.lua, c.lua, 24 cases): a live loop is refused at call depth 0/4/100; over hash-only, array-only, mixed and single-key tables; over a perms table (`string`); with jit on, jit off, and after 2500 hot iterations; reachable via nested tables or a closure upvalue. Completed loops, `break`-ed loops, nested completed loops and 0..8 trailing locals all persist (C11: 9/9 OK). `for k,v in pairs(t) do return tail() end` persists (tail call escapes) while `return (tail())` — the non-tail form — is refused, so that clause is right. An unreachable suspended-in-loop coroutine is not refused, so the reachability qualifier is right.
I also found the *reason* the register-layout fuzz finds 0 false positives, rather than just reproducing it: parse_for_iter puts the control slot at base-1 (lj_parse.c:2895 `base = fs->freereg + 3`; ITERN reads [RA-24]/[RA-16]/[RA-8]), freereg resets to base-3 when the loop ends, and p_thread scans only slots [1+LJ_FR2, co->top) (eris_lj.c:768). Anything that raises top above base-1 — a later local, a call setup, or a callee's own slot 0, which lands exactly on base-1 — must overwrite it first. A stale keyindex can never be simultaneously un-overwritten and below co->top. That half of the claim is structurally sound, not luck.

REFUTATION 1 — MISSES (a live `pairs`/`next` loop that is NOT refused), and they are the dangerous kind.
BC_ISNEXT permanently rewrites the *prototype* in place the first time its guard fails: `mov PC_OP, BC_JMP` on the ISNEXT and `mov byte [PC], BC_ITERC` on the target ITERN (vm_x64.dasc:4370-4402). I measured the mutation directly with jit.util.funcbc (e2.lua): pc=4 op=72 ISNEXT / pc=9 op=70 ITERN  ->  pc=4 op=88 JMP / pc=9 op=69 ITERC. After that the control slot is a plain last-key, so eris-lj sees nothing to refuse.
(a) FULLY STOCK, no monkeypatching (final.lua, one process, one prototype, one source line `for k, v in next, t, start do`):
    scan(hash, nil)  [call #1]                  REFUSED
    ... one intervening call scan(hash, next(hash)) ...
    scan(hash, nil)  [after one non-nil start]  PERSIST OK (218 bytes)
    scan(hash, nil)  [and again]                PERSIST OK (218 bytes)
  Identical call, identical arguments, opposite verdict, decided by an earlier call's data.
(b) A Lua-5.2 `__pairs` shim over the global `pairs` — exactly the sandbox wrapper an OC-shaped host installs (d.lua): `walk(t)` with `for k, v in pairs(t)` is REFUSED pristine; after ONE call over a `__pairs` table it is PERSIST OK (217 B) for every later plain-table call and every closure of that prototype (D4/D5/D6).
CROSS-PROCESS DAMAGE of the accepted blob (save.lua/load.lua, save2.lua/load2.lua — separate erislj_test.exe invocations, blob via disk):
  - 12 string keys, 6 consumed, 321-byte blob: 6/6 fresh processes returned ret=6 and visited ONLY the 6 already-seen keys — MISSING=6 [alpha,bravo,charlie,delta,echo,foxtrot], no error, no warning. (In the restoring process the prototype is pristine, so the loop bottom is ITERN, which reads the control slot's low 32 bits as a raw index; a string's low-32 lands past hmask and the loop exits instantly.)
  - Array keys 1..12, 6 consumed, 273-byte blob: 3/3 fresh processes produced order 1,2,3,4,5,6,1,2,3,4,5,6,7,8,9,10,11,12 and ret=18 — the loop body RE-RAN for six keys already processed (a double 6.0 has low-32 = 0, so ITERN restarts at array index 0). Silent duplicated side effects from a save eris-lj accepted.
  - If the loading process also despecialises the same line (both ITERC), it degrades to the doc's nondeterministic rotation: over 6 fresh processes I got MISSING=6, MISSING=2, MISSING=6, DUP=1, DUP=4, DUP=2 from the one blob.

REFUTATION 2 — FALSE POSITIVE with no coroutine at all (b3.lua, final.lua).
LuaJIT names the hidden for-in slots (lj_parse.c:2906-2908 VARNAME_FOR_GEN/STATE/CTL; surfaced by lj_debug.c:161-174), so `debug.getlocal(co, 1, 3)` returns "(for control)" and hands the keyindex out as a first-class Lua value (`userdata: NULL`). Stash it, run the loop to completion (coroutine dead, zero loops executing anywhere), then persist `{ctl}` — a plain table containing no thread — and eris-lj raises the exact pairs-gap message. The check is a value-level test on `(I->L->top-1)->u32.hi == LJ_KEYINDEX` (eris_lj.c:935), not any analysis of loops, so the diagnostic is also actively wrong there.

Working tree left as found: I wrote nothing under C:/Users/astro/Downloads/OC-LuaJIT (every probe path is absolute into the scratchpad), built nothing new, and did not touch serializer/eris_lj.c. Note the tree already carried modifications to eris_lj.c, docs/* and tests/m1-m2 before I started — the same pre-existing state docs/research/fu-forin-gap.md records — which does not match this session's start-of-conversation git snapshot; that is not my doing.
CORRECTION: The rule is value-level, not source-level, and it is neither exact nor binary at the source level.

Accurate statement: eris-lj refuses iff a lightuserdata carrying itype LJ_KEYINDEX is reachable from the persisted root. That is *usually* the control slot of a live BC_ITERN loop, but it is neither necessary nor sufficient for "a `for … in pairs(t)` loop is executing":
1. NOT NECESSARY (miss). Whether a given `for … in pairs/next` site uses ITERN at all is a mutable runtime property of the *prototype*, not of the source. BC_ISNEXT patches ISNEXT->JMP and ITERN->ITERC in place, permanently, the first time its guard fails (iterator not the `next` fastfunc, state not a table, or control not nil). One earlier call with a non-nil start key — `for k,v in next,t,start` — or one call through a `__pairs`/wrapped-`pairs` shim poisons that source line for the rest of the process, for every closure of that prototype and every later plain-table call. The same line then persists silently and corrupts across processes: I measured 6/6 fresh processes silently dropping half the keys (string keys) and 3/3 re-running the loop body for six already-processed keys, ret=18 instead of 12 (array keys). This is strictly worse than the refusal it replaces, because eris-lj currently accepts it.
2. NOT SUFFICIENT (false positive). `debug.getlocal(co, level, 3)` hands the "(for control)" keyindex out as an ordinary Lua value; storing it and persisting a plain table with no thread in it at all triggers the same refusal with the same (now false) message.
3. The escape list is incomplete: a tail call out of the body, OR the site having been despecialised, OR the split-iterator form (`local f,s,c = pairs(t); for k,v in f,s,c`) — the last two are not escapes into safety, they are escapes into silent cross-process corruption.

Consequences for the stated motivation. A source-level lint is unsound in the direction that matters: it flags sites that are already ITERC (harmless-looking refusals it would tell you to rewrite) and, worse, it certifies as "will be refused" sites that in fact persist and corrupt. If you want a static rule you must pair it with a dynamic one: treat *any* live generic-for over a table — ITERN or ITERC — as unpersistable. The cheap concrete fix is to extend the persist-time refusal from "control slot is a keyindex" to "a Lua frame's return pc follows a BC_ITERC whose state slot is a table" (eris_lj.c already switches on bc_op(pc[-1]) at line 1478 and already accepts ITERC there), so the split form and every despecialised pairs loop fail loudly at save instead of silently at resume. Scoping the M4 key-snapshot fix to ITERN alone would leave the ITERC path — which is reachable from ordinary `for k,v in pairs(t)` source — permanently broken.

## VERIFICATION
CLAIM: Exposure is bimodal, measured as fraction of wall-clock time parked at a refusable yield: an idle computer (shell at a prompt, blocked in event.pull/os.sleep, or polling with numeric `for`/`component.list`) is at 0.0%; a polling controller whose component calls sit inside a `pairs` loop or an event.timer callback is at 14.8–45.2%. Changing `for i=1,#list` to `for addr in pairs(list)` alone moved a daemon from 0% to 22.1%.
VERDICT: confirmed
EVIDENCE: I tried to break this claim and failed on every load-bearing point. All probes are mine, in C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\adv2\ (ocenv.lua, b_shapes.lua, c_duty.lua, d_stale.lua, e_sweep.lua, f_direct.lua). They run the REAL OpenOS lib/event.lua and lib/core/cursor.lua out of the extracted OC jar at scratchpad\ocsrc, the REAL machine.lua yield shapes, and ask the REAL erislj_test.exe at each park. Repo working tree unchanged (git status --porcelain identical before and after).

PARK MODEL, taken from source not assumed. server_machine_Machine.scala:1008-1020 — sysyield number>0 with no signals => State.Sleeping remainIdle=ticks; number<=0 => Yielded, next tick; a yielded function => State.SynchronizedCall, run in the NEXT update() (:597-608) => ~1 tick = 50 ms. Machine.save (:821) saves whenever state != Stopped, with no exclusion for SynchronizedCall — so a world save can and does land on the component-call yield. Corroborated by machine.lua itself: invoke() does `args = nil -- clear upvalue, avoids trying to persist it` at :1084 and :1097, i.e. OC already persists parked exactly there.

1. IDLE = 0.0% — CONFIRMED, and robust rather than lucky. Measured over a 20 s simulated horizon (c_duty.lua): shell at a prompt (cursor.lua:246 `computer.pullSignal(.5)` inside a plain `while true`) 0.0% (0/40 yields); blocked in event.pull() forever 0.0%; `os.sleep(1)` loop 0.0%; poll with `for i=1,#list` 0.0% (0/132); poll with a component.list-style iterator 0.0% (0/132).
   The real threat to this was OpenOS event.lua:50, which scans `for _,handler in pairs(handlers)` FOUR LINES before it parks at :54 — if the dead ITERN control slot survived in that frame, idle would be 100%, not 0%. It does not. d_stale.lua generated and parked 3388 shapes (0-6 locals before the loop, 0-4 after, yield 0-3 frames deeper, 0-3 args, full and empty tables, plus the exact event.lua:49-54 shape parameterised): ZERO refused. Register allocation reclaims the loop base, so a finished pairs loop is never refusable. Idle 0.0% survives with 3 and with 23 handlers registered.

2. POLLING CONTROLLER 14.8–45.2% — reproduced inside the band. N=8 non-direct component calls per poll, 1 s poll: `for a in pairs(list)` = 29.5% (118/132 yields, 5.90 s of 20.00 s parked). event.timer callback = 38.0% (152/172).

3. THE SWAP, 0% -> ~22% — CONFIRMED. Identical daemon, only the loop header changed: `for i=1,#list` 0.0% -> `for a in pairs(list)` 29.5%; at N=6/1 s the pairs version is 23.0%, bracketing the quoted 22.1%.

MECHANISM CHECKS (b_shapes.lua, 20 shapes). Refusal is stack-wide, not frame-local: a pairs loop 2 and 4 frames above the yield still refuses, which is what makes the polling case real. Refused: yield inside pairs; invoke inside pairs at any depth; `for k,v in next, t`. Persisted: numeric for, ipairs, a component.list-style iterator function, and a detached `local f,s,c = pairs(t)` triplet.

ATTACKS THAT FAILED. (a) Cross-process instability: 6 fresh processes gave identical percentages to 0.1% — unlike the correctness bug, exposure carries no per-VM randomness. (b) "GTNH uses DIRECT methods, which never yield, so exposure is 0 anyway": false. machine.lua:1086-1088 turns a direct call into a SynchronizedCall once the per-tick budget is spent (application.conf:162-166, callBudgets [0.5,1.0,1.5]). f_direct.lua: a pairs loop over direct calls at 15/tick is 0.0% at 8 slots but 4.8% at 16, 9.2% at 32, 16.8% at 64; at 4/tick, 43.3% at 64 slots. Budget exhaustion reintroduces the yield inside the loop.
CORRECTION: Two refinements, neither of which overturns the claim.

(1) "14.8–45.2%" is a sample range, not a property of the category — do not quote it as a bound. e_sweep.lua sweeps the same program shape over realistic (yielding calls per poll N, poll period T) and gets a continuum, not a cluster: N=2/T=10 s = 1.0%, N=2/T=2 s = 4.8%, N=6/T=1 s = 23.0%, N=8/T=0.5 s = 45.0%, N=20/T=0.5 s = 66.7%, N=40/T=0.5 s = 80.0%. Both tails run well past the quoted interval — a two-transposer 5-second poller is a genuine pairs-polling controller sitting at 2.0%, and a fast 40-call scanner is at 80%. The governing formula is just exposure ~ N x 50 ms / (N x 50 ms + T). So "bimodal" is correct only in the coarse sense 0% versus not-0%; the sharp, structural dichotomy is whether a refusable iteration form is anywhere on the stack at the park, and the magnitude above zero is a smooth function of the poll duty cycle.

(2) The clause-3 framing ("changing the loop alone moved it") holds only for main-loop daemons. If the daemon's work runs in an event.timer/event.listen callback, swapping pairs for numeric `for` is not a mitigation: OpenOS dispatches every handler from inside `for id,handler in pairs(copy)` at lib/event.lua:60, so my timer callback using `for i=1,#list` measured 38.0% — identical to the pairs version, and b_shapes.lua confirms "timer callback with numeric for + invoke" is REFUSED. The claim does list event.timer as its own high-exposure category, so this is a gap in the remedy, not a contradiction.

