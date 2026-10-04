# A faithful collect-and-retry at the wall: where PUC's emergency collection is safe inside LuaJIT

## Verdict

- **A faithful retry at every refused allocation can't be made safe with a minimal patch.** Condition (d) of u-luajit-gc.md §4 is not a list of five constructors. LuaJIT relies everywhere on the rule that nothing is collected between checkpoints, and PUC relies on the opposite. I verified three counterexamples to the survey's list:
  - `lua_setfield` holds a new key string in a C local across `lj_meta_tset`, and so across a rehash (`lj_api.c:976-977`). PUC puts the same key on the stack first (`lapi.c:763`).
  - `lj_parse_keepstr` creates a string and then inserts it with `lj_tab_setstr` while the string is unanchored (`lj_parse.c:262-263`). PUC's version of the same function says "temporarily anchor it in stack" (`llex.c:127-129`). This one can be reached from the sandbox through `load`.
  - In `BC_TSETM`, the MULTRES values lie above `curr_topL` while `lj_tab_reasize` allocates (`vm_x64.dasc:4199-4206`). Atomic would clear them (`lj_gc.c:314-318`), which breaks (c).

  The 21 sandbox-reachable source files contain about 240 allocating call sites (grep heuristic). If one is missed, the result is a use-after-free at the wall, which can take down the JVM. That is strictly worse than today's refusal.
- **A faithful retry inside the interpreter is feasible**, gated on `vmstate == ~LJ_VMST_INTERP`. Every `lua_CFunction` call runs under `~LJ_VMST_C` (`vm_x64.dasc:4908/4918`), and so does every host API call after the VM returns (`:424`, `:502`). The gate therefore excludes all three counterexamples above by construction. It leaves a closed audit set of about 25 functions: the VM helpers, the C halves of the fast functions, and hooks. The change is about 70 VM lines in 9 files.
- **Everything else falls back to a bounded, charged loan in the shim:** code on a trace, trace exits, C library functions, host pushes and four no-collect regions. The VM half and the shim half can be adopted separately. The shim half on its own is the fallback with zero VM lines.

## 1. Mechanism

**P1, the VM half.** When `allocf` returns NULL, `lj_mem_realloc` and `lj_mem_newgco` check `lj_gc_canemerg(g)`. If it holds, they call `lj_gc_emergency(L)` and retry once; this is what PUC's `lmem.c:88-90` does. `lj_gc_canemerg(g)` requires all of the following:
- `vmstate == INTERP`, which rules out C1 (on trace), C2 (vmstate GC), trace exits (EXIT, `:2461`) and the recorder;
- `jit_base == NULL`;
- `HOOK_GC` clear and `threshold != LJ_MAX_MEM`, which is PUC's `!gcrunning` covering finalizers, C4 and host GCSTOP;
- the recorder in `LJ_TRACE_IDLE`;
- no-collect depth 0.

`lj_gc_emergency` runs a cycle from scratch and never calls a finalizer. It is `lj_gc_fullgc`'s body (`:781-803`), except that it stops at `GCSpause` *or* `GCSfinalize`, so pending finalizers wait for a later normal step or the kernel's collect, as on stock. While it runs it sets an emergency bit that:
- **(C7)** skips `lj_state_shrinkstack` (`:320`), `lj_buf_shrink(tmpbuf)` (`:651`) and the string-table shrink (`:695-696`). PUC skips the same three (`lgc.c:703`, `:780-784`).
- **(C6/c)** makes `gc_traverse_thread` mark up to `max(th->top, the largest frame extent)`, using the value `gc_traverse_frames` already computes. Before the cycle, the emergency raises the allocating thread's top to `base + cur_topslot(...)`, and restores it afterwards. `cur_topslot` is the MULTRES-aware top that `lj_dispatch_ins` uses before hooks (`lj_dispatch.c:397-408`, `:421-422`); it covers TSETM, CALLM and RETM. This generalises stock's own fix in `lj_meta.c:383` (`if (!fromc) L->top = curr_topL(L)`).
- **(C5/d)** Under the INTERP gate, only three constructors still hold an unanchored object across a second allocation. Each gets a no-collect bracket:
  - `newtab` after its `GCtab` allocation;
  - `lj_func_newL_gc` around its upvalue loop;
  - `lj_str_resize` around its vector allocation. This covers `lj_str_alloc`'s link-then-grow at `lj_str.c:307-309`.

  `lj_state_new` and `lj_func_newL_empty` are reached only from C functions (`coroutine.create`, `load`), so the gate excludes them.

**P1, the shim half (loans).** When an allocation would cross the cap, `lj52_gc_wall` decides what happens:
- If the VM can collect, the shim returns NULL and the VM collects. The next growing call is necessarily the VM's retry, because the emergency's own calls are all frees. If the retry does not fit, that is a real out-of-memory: count it and refuse.
- If the code is in a finalizer or under GCSTOP, refuse. This is faithful.
- Otherwise **lend**, and arm so that the next checkpoint repays the loan with a full cycle. The lending state `gc_wall` takes four values:

| State | Meaning | A crossing allocation is granted while |
|---|---|---|
| OPEN | no wall event outstanding | `used+Δ ≤ total+L` (becomes LOAN) |
| LOAN | lent, repayment pending | `used+Δ ≤ total+L` |
| FULL | a cycle finished with `used > total` | never: refuse (becomes REFUSED) |
| REFUSED | an error has been raised since the last cycle | `used+Δ ≤ total+2L` (room to recover) |

  Here `L = max(32 KB, total/32)`. At the end of a cycle (an armed cycle proving itself, or an emergency) the state becomes FULL if `used > total` and OPEN otherwise. The REFUSED row is what makes the probe's pattern work: `pcall(fill)`, then `held=nil`, then `string.rep`.

  Two more P1 shapes are covered:
  - **A request larger than the headroom while the headroom is still above the watermark.** In the interpreter, the emergency collects and the retry succeeds. Elsewhere the request is lent if it is no more than L past the cap.
  - **Trace exits at the cap.** These run under vmstate EXIT, so they borrow.

**P2.** The watermark arm (`S:930-941`) is deleted. Arms now happen only when a loan is granted, when an allocation is refused, or after a flush. In the interpreter, each refusal costs one cycle, which frees about (cap − live). In borrowing contexts, each wall crossing costs one loan and one cycle. Pacing stays at `pause` 200, so, as on stock, nothing is collected between refusals once live > cap/2.

**P3.**
- While armed, every allocator call first checks `if (threshold > gc.total) threshold = gc.total`. That re-pokes the collector whatever state it is in, so a cycle that finished in the middle of a sweep, or stopped at `GCSfinalize`, cannot park it.
- The 65 536-call bailout now counts only growing calls, so the armed cycle's own sweep frees no longer trip it.

**P4.**
- A 13th site in `patch-machine-lua.lua` puts `if jit and jit.flush then jit.flush() end` right before the baseline `coroutine.yield()` (`machine.lua:1603-1605`). OC's own COLLECT (NLA:220) then sweeps the GCtrace objects before it reads `kernelMemory`.
- The idle arm-and-flush loop on a 192 KB stick disappears, because nothing arms at idle any more.
- The trace-flush rule changes. It now runs only at the end of a cycle at the wall, and only when the resident trace metadata is at least the headroom left after the cycle. Each flush at least doubles the remaining runway, so there are none at idle and O(log) of them per approach to the wall.

## 2. The code change

**VM:** `native/luajit/emergency.diff` (about 70 code lines in 9 files), every hunk carrying the marker `OCLJ-EMERG`.
- **`lj_obj.h:599`** `uint8_t unused0` becomes `uint8_t emerg`. Bit 7 means "in an emergency"; bits 0-6 hold the no-collect depth. This uses spare padding, so neither `GCState` nor the asm offsets move. Add the prototype for `lj_gc_canemerg` here, because the shim must not include `lj_gc.h`.
- **`lj_gc.c`**:
  - the `gc_traverse_thread` change: in an emergency, set `top = max(top, bot + gc_traverse_frames())`, mark and clear from there, and skip the shrink (+5 lines);
  - two one-line guards at `:651` and `:695`;
  - `lj_gc_canemerg` (8 lines);
  - `lj_gc_emergency`: factor `lj_gc_fullgc` into `gc_full(L, em)`, then save/raise/restore the top with `lj_dispatch_topslot`, run with vmstate GC and `emerg = 0x80`, stop at pause or finalize, set `debt = 0`, then `threshold = estimate/100*pause` (about 25 lines);
  - the retry in `:869-881` and `:884-897`. Keep the original `p` for the second `allocf` (2×4 lines).
- **`lj_gc.h`**: the `lj_gc_emergency` prototype.
- **`lj_err.c:770`**, in `lj_err_throw`: `g->gc.emerg = 0;`. The no-collect regions never call Lua, so any throw leaves all of them.
- **`lj_dispatch.c`/`.h`**: export `lj_dispatch_topslot(L)`, a wrapper around the static `cur_topslot` built from `cframe_pc`/`cframe_multres_n` (6 lines).
- **`lj_tab.c` (`newtab`)**: `emerg++` after the first allocation in each branch, and `emerg--` before returning (3 lines).
- **`lj_func.c`**: brackets around the upvalue loop of `lj_func_newL_gc` (2 lines).
- **`lj_str.c:139`**: brackets around `lj_mem_newvec` (2 lines).

**How it is applied.** `patch-emergency.sh`, about 80 lines in the style of `patch-penalty-scrub.sh`:
- It runs after the scrub on the pristine copy that `build-native.sh` re-copies before every run.
- It pins the sha256 of the 9 input files (`lj_func.c` as it is after the scrub), runs `patch --dry-run` and then the real `patch`, and requires every marker exactly once.
- It verifies an already-patched copy and leaves it unchanged, and it contains no backslashes.
- `build-native.sh` greps the copies `make` is about to compile and checks that `lj_gc.o` was rebuilt.
- Only `vm_x64.dasc` is involved for windows and linux x86_64, and it is not edited.

**Shim, in C mode (`S:378-381`) and legacy mode (`S:440-447`).** Both refusal sites become `if (!lj52_gc_wall(M,total,used,delta)) return NULL;`, then the code falls through to the grant path. Legacy mode `setmem`s `used+Δ`, which may exceed `total`; OC clamps free memory at 0.
- **New fields in `lj52_mem`:**
  - `int gc_wall` (OPEN/LOAN/FULL/REFUSED);
  - `int gc_empending` (we told the VM to collect, and the next growing call is its retry);
  - `volatile long gc_emreqs, gc_emfails, gc_odgrants`;
  - `long long gc_odpeak` (the largest `used−total` seen).
- **Constants:** `LJ52_GC_ODMIN 32768` and `LJ52_GC_ODDIV 32`, giving `L = max(ODMIN, total/ODDIV)`. The excursion is at most 2L, plus the existing push window of about 1.5 KB. L is sized for the bursts that actually failed, which were concatenation strings and `table.pack` per resume, all at most 1 KB. A burst larger than L is the documented residual. `LJ52_GC_WMIN` is deleted.
- **`gc_pressure`:**
  - delete the unarmed watermark branch;
  - in the armed branch, add the re-poke, take a `grow` flag for the bailout, and at the proof set `gc_wall` and run the flush rule;
  - reset `gc_wall` to OPEN whenever `used ≤ total`.
- **`_OCLJ_GCSTATS`** grows from 20 to 25 values, with `lua_checkstack`. The 20 is pinned in five places, all of which change on purpose: `mem_test.c:784` and `OcljSmoke` 1784, 1796, 1810-1811, 3170.
- **Gate:** `build-native.sh` adds `lj_gc_emergency` to the collector gate's forbidden regex, and asserts that `lj_gc_canemerg` appears exactly once, inside `lj52_gc_wall`. Each addition gets its own fail-first.

## 3. Edge cases

- **On trace.**
  - A loan, or a refusal at `total+L`.
  - Repayment happens at the trace's `asm_gc_check` (`lj_gc_step_jit` exits at atomic, `lj_trace.c:942-944`).
  - A NEWREF-only loop has no check at all (`lj_asm.c:1190`), so it is refused at `total+L`. Array growth leaves the trace through a guard and is resized in the interpreter, where it gets the faithful path.
- **Trace exits.** These run under vmstate EXIT, so snapshot restore borrows; today it raises ERRMEM.
- **The `norefuse` window.** Unchanged: it never refuses, so it never triggers an emergency, and `gc_pressure` stays inert.
- **Finalizers (`HOOK_GC`).** No emergency and no loan, so the allocation is refused, as on PUC (`lgc.c:818-826`). Pending finalizers stay marked through the emergency cycle (`gc_mark_mmudata`).
- **Host GCSTOP and GCRESTART.** Under STOP, refuse. RESTART sets `threshold = total`, which has no interaction with this design.
- **OC lifting the cap around persist.** No refusals happen while it is lifted. After the cap is restored, growth is handled by the emergency or a loan; `gc_wall` resets as soon as `used ≤ total`.
- **eris.** Nothing crosses a save. `emerg` is 0 at rest, and `lj_err_throw` zeroes it. The shim's fields are per state and start fresh at load.
- **Dropin legacy path.**
  - It calls the same `lj52_gc_wall`.
  - Every free during an emergency costs two JNI calls, as jnlua costs on stock.
  - No legacy-mode refusal happens while `M->L` is NULL: allocations made then are banked unrefused.
- **Sandbox code driving the mechanism without bound:**
  - at most one emergency per refusal, each costing O(heap), the same as stock, and inside the 5 s deadline;
  - loans never exceed 2L, and FULL forbids a second loan;
  - no re-entry, because the emergency runs under vmstate GC;
  - `collectgarbage` is still absent from the sandbox, but the design no longer depends on that.
- **Host GCSETSTEPMUL while armed** (`S:904/922`). An existing hazard this design leaves alone.

## 4. Fail-first tests

Every check below must first be run against DLL `cb29485d` and seen to fail.

**Hermetic `mem_test` checks.** C mode, plus a legacy variant of T1 and T2.
- **T1 (P1, recovery).** Cap = used + 512 KB, holder pre-sized from C. Run `ok,err=pcall(fill); held=nil` followed by three recovery shapes:
  - (a) JIT off, `local s="d"..n` plus `{}` (the interpreter's emergency path);
  - (b) `string.rep("x",256)` (a C function, borrowing);
  - (c) a JIT-hot fill and recovery.

  Pass when, for all three rounds: `err=="not enough memory"`, the recovery returns 0, `bailouts=0`, and `used ≤ total+2L` throughout. Also require `emreqs` to rise in (a) and `odgrants` to rise in (b). Today (b) is refused by reading (u-tests §5).
- **T2 (P1, second shape).** Cap = used + 1 MB, 700 KB of garbage, JIT off. Run `local s = a..a` with `a` a live 300 KB string. Pass when it succeeds with one emergency request. Today it is refused without an arm.
- **T3 (P2).** 256 KB live; `churn(asize 0, N=2000)` once with ample headroom and once with tight headroom. Pass when the cycles (emergency requests plus collects) in each run are at most ⌈bytes/(headroom/2)⌉+2, and near/far time is at most 3× in the same process. Today it is about 1000 collects.
- **T4 (P3).** u-tests' parked-collector recipe: step to `GCSsweep`, then trigger a loan from a C function. Pass when `threshold ≤ c_total` while armed, collects advance, there is no refusal with garbage on the heap, and `bailouts=0`. **T4b:** an armed cycle freeing about 2.5 MB of 40-byte garbage gives `bailouts=0` (today it is at least 1).
- **T5 (P4).** Run `TRACE_CHUNK` and the kernel snippet, then `lua_gc(COLLECT)` and read `used`. Pass when three fresh states read identical values, and the gap to a state that never enabled the JIT is at most the recorder-buffer bound. Without the snippet, the gap is at least the trace metadata, so it fails.
- **T6 (R5 bound).** Unbounded live growth on trace stops with `odpeak ≤ 2L`; a JIT-off variant stops at `used ≤ total`. Sabotages in `negative-control.sh`:

| Sabotage | Must fail |
|---|---|
| unbounded loan | T6 |
| no re-poke | T4 |
| no VM retry | T2 |
| shim never defers to the VM | T1a's `emreqs` |

  `negative-control.sh`'s stale paths need fixing first.

**The VM gate.** A stress build with `-DLUAJIT_EMERG_STRESS`:
- It runs `lj_gc_emergency` before *every* growing allocation that passes the gate, as PUC's `HARDMEMTESTS` does (`lmem.c:80-83`). It is built with `LUA_USE_ASSERT` and with `lj52_back` poisoning freed blocks with 0xDB.
- It runs over `mem_test`, `shim_test`, `security_test`, `TRACE_CHUNK` and a corpus of Lua programs, plus a sampled stress DLL for one harness arm.
- **Canaries, which must crash:**
  - with the `newtab` bracket removed: `{x=1,y=2}` in a loop;
  - with the gate widened to vmstate C: a `load` with more than 64 string constants (`lj_parse_keepstr`) and `lua_setfield` under stress;
  - with the extent and top-slot hunk removed: a `{unpack(t)}` and stale-top `string.sub` corpus.

  If a canary does not crash, the stress gate cannot see that class of bug and is not trusted.

**Review.**
- Each of the roughly 25 functions reachable under INTERP is signed off by name as "no unanchored GC object across an allocation, and every live slot below the marked top": `lj_tab_new/dup/newkey/resize/reasize`, `newtab`, `lj_func_newL_gc`, `lj_meta_cat/tset`, `lj_str_new/alloc/resize`, `lj_strfmt_number/num/obj`, `lj_buf_putstr_*/tostr`, `buf_grow`, `lj_state_growstack`, the C halves of the fast functions (`tostring`, `string_char/sub/byte/reverse/lower/upper`, `coroutine_resume/wrap_aux`, `pcall/xpcall`), the shim's `lj52_wd_hook`, and message building in `lj_err_*`.
- A second reviewer re-derives the vmstate claim.
- All of this is repeated on every LuaJIT bump.

**Existing checks rewritten on purpose** (each with its own fail-first):
- M5 becomes `≤ total+2L` on trace;
- P1a becomes "no refusal, no arm, no delay";
- P2a-h move to the new flush rule;
- C5a/b, C4b (live growth only) and harness `e4`.

**Harness capacity matrix** (`bench/runs/2026-10-03-ramscale/scripts/`, dropin included):
- 0 "recovery refused" and 0 "down" across D, E and O (today 19 of 60), with refusals at least +1 in every clean run;
- held medians O/S ≥ 0.95 at the 1024 KB closure cell;
- per-cell median `t_last5` ours/stock ≤ 3 (today 21-121×);
- wall events (emergency requests plus loans) ≤ 3 per batch;
- `collects == arms` and `bailouts == 0` at rest;
- the park fingerprint is never read (`CAP-*` printing positions 2, 3, 5, 7, 8, 9, 15 and the new 21-25);
- `kernelMemory` for D identical across at least 3 replicates;
- a 192 KB stick idle: arms ≤ 63 per 400 ticks and 0 flushes;
- `odpeak ≤ 2L` everywhere.

## 5. What it does not fix

- **Bursts in borrowing contexts.** A burst larger than L, with no checkpoint, inside a C function (`string.rep`, `table.concat`, `string.format`, Java callbacks), in a NEWREF-only trace, or in string-table growth, is refused even when the garbage would have covered it.
- **Late errors.** A real out-of-memory in those contexts surfaces up to L bytes late. It can then land outside the `pcall` that covered the allocation that crossed the cap: a bounded "machine down" risk.
- Trace metadata counts against the cap until the flush rule fires.
- Machine code stays outside the cap.
- The recorder buffers stay in `kernelMemory`, because `lj_trace_flushall` does not free them.
- The VM half's memory safety rests on the audit plus the stress gate, not on proof.

**Residual divergence:** in the interpreter, off trace, we raise "not enough memory" exactly where stock does; on traces, in trace exits, inside C library functions and in host pushes, a refused allocation instead borrows up to max(32 KB, cap/32) past the cap (twice that after an error), repaid by a full collection at the next GC checkpoint, so a larger burst with no checkpoint can be refused where stock would have collected.

## 6. Self-assessment

| R | Verdict | Why |
|---|---|---|
| R1 | PARTLY | Exact in the interpreter. The table's "REFUSED" state gives C-function and trace recovery up to 2L. Bursts larger than L in borrowing contexts diverge. |
| R2 | MET by construction | One cycle per wall event, with the watermark gone. Unmeasured until the matrix runs. |
| R3 | MET | The re-poke plus the bailout counting only growing calls (T4, T4b). |
| R4 | PARTLY | Trace-free except the recorder buffers, which are probably constant; T5 checks. The idle arm loop is structurally gone. |
| R5 | MET for the bound | ≤ 2L + 1.5 KB, charged, clamped at 0, and the FULL state blocks repeats. Host safety now also depends on R6. |
| R6 | PARTLY | C1-C4 and C7 hold structurally. C5 and C6 rest on the gate, three brackets, the extent/top-slot rule, an audit and the stress gate. It breaks "no collection inside the allocator" as written: the collection runs in `lj_mem_realloc` after `lua_Alloc` has returned, though the shim itself still never collects. |
| R7 | NOT MET | About 70 VM lines in 9 files, each justified. The collector gate is extended with its own fail-first. A fallback with zero VM lines exists. |
| R8 | MET | Nothing in `global_State` needs to survive a save. |
| R9 | MET | The success path is untouched in both the VM and the shim; one branch per GC cycle. |
| R10 | MET (plan) | P1-P4 each have a hermetic fail-first. The legacy dropin is covered. The VM part has canaries that must crash. |
| R11 | MET | No knob is added; `ramScaleFor64Bit` is still inherited. |

The claim I'm least sure of is that `vmstate == INTERP` exactly separates the code that holds no unanchored objects. It rests on reading `vm_x64.dasc:424/502/4908` and on a hand audit of about 25 functions. Only the stress gate's canaries can show that this check can fail.