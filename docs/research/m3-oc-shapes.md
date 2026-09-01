ര# M3 — suspended coroutines: what OC produces, what to refuse, and the restore contract

All LuaJIT line numbers are `C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/<file>` at the pinned commit. Eris references are `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\eris\eris_master.c`.

## 0. Probes I ran (all under the scratchpad, repo left clean)

| file | proves |
|---|---|
| `…\scratchpad\m3probe\m3probe.c` | status matrix; hand-built dead / dead-error threads; yield-from-C-function shape + resume semantics; "normal" thread has `cframe != NULL`; main thread idle has `cframe == NULL`; top func slot of a yield frame is a C function |
| `…\scratchpad\m3probe\m3probe2.c` | Lua `debug.sethook` hooks **cannot** yield; the CLOSED→OPEN upvalue backpatch on two `lua_loadx` closures survives a full GC and keeps sharing (40 → 42 → 47) |
| `…\scratchpad\m3probe\m3probe3.c` | a **native C** hook *can* yield → a real `lj_cont_hook` frame; layout + resumability |
| `…\scratchpad\m3probe\m3probe4.c` | the OC kernel frame chain, end to end |

I also re-ran `prototype/coclone` (`make run CC=gcc`) — 0 failures — and removed the binaries afterwards (`git status` is back to the state I found: ` M .gitignore`, `?? prototype/coclone/`, `?? serializer/tests/m3.lua`, none of which are mine).

---

## 1. What OpenComputers actually produces

### The kernel coroutine and where it is frozen

`machine.lua` is loaded as a chunk and made into a thread (`lua.newThread`), then driven by `lua_resume` from Java. Its last statement is

```lua
-- machine.lua:1548
return pcallTimeoutCheck(pcall(main))
```

and inside `main()` the steady-state suspension point is exactly one line:

```lua
-- machine.lua:1540
      args = table.pack(coroutine.yield(result[2])) -- system yielded value
```

There is one other, boot-only yield — `coroutine.yield()` at `machine.lua:1512` ("Yield once to get a memory baseline") — which OC can also be saved at, and it produces the identical chain minus the yielded value.

`m3probe4.c` reduces `machine.lua` to that exact shape (vararg main chunk → `pcall(main)` → `main()` resuming a bios coroutine → `coroutine.yield(sysval)`), runs it via `lua_newthread` + `lua_resume` from C, and walks it:

```
-- KERNEL at its system yield: status=1 cframe=NULL base=22 top=22 stacksize=105 -> suspended
   [0] slot= 21 LUA    C ffid=35        <- coroutine.yield  (lj_ffdef.h #35)
   [1] slot= 14 PCALL  delta= 16 Lua    <- main()
   [2] slot= 12 LUA    C ffid=21        <- pcall            (lj_ffdef.h #21)
   [3] slot=  5 VARG   delta= 16 Lua    <- the machine.lua chunk (vararg)
   [4] slot=  3 CP     delta= 16        <- bottom resume frame from vm_resume
   depth = 5 frames
```

**So the kernel chain is exactly five frames and uses four of the five frame encodings** — `LUA`, `PCALL`, `VARG`, `CP`. Note the `VARG` frame: OC's kernel is a *main chunk*, which is a vararg function, so `ins_call` pushes a `FRAME_VARG` delta frame that a coroutine created from a plain `function() … end` never has. Your current mini-kernel test does not produce it (§6.M).

### Everything else OC persists

`NativeLuaArchitecture.save()` persists the kernel thread at stack index 1, "plus index 2 when suspended inside a synchronized call" (`docs/research/report-persistence-internals.md:7`). The rest of the graph hangs off the kernel's stack:

* **the bios coroutine** — `bootstrap()` (`machine.lua:1493-1506`) does `return coroutine.create(bios), {n=0}`; it lives in `main`'s local `co` at a fixed slot of the `PCALL` frame. Its own chain is `CP / VARG(bios chunk) / … / LUA(coroutine.yield)`.
* **a chain of nested coroutines**, not a single one. OpenOS runs each process as its own coroutine, and the sandbox's resume wrapper *itself* suspends while its child is suspended:
  ```lua
  -- machine.lua:848-857
          local result = table.pack(coroutine.resume(co, table.unpack(args,1,args.n)))
          …
          elseif result[2] ~= nil then -- yield: (true, sysval)
            args = table.pack(coroutine.yield(result[2]))
  ```
  so a realistic save is kernel → bios → init → shell → program, i.e. **4–6 suspended threads deep**, each with a Lua frame chain of realistically 10–40 frames (`computer.pullSignal` at `machine.lua:1418` sits under `event.pull`, the program, the shell, `init`).
* **`sgcco`** (`machine.lua:699`), the sandboxed-`__gc` coroutine, suspended at `self, gc = coroutine.yield(pcall(gc, self))` (`machine.lua:703`) or dead (it is nil'd when dead, `machine.lua:722-724`).
* **the synchronized-call closure** — `invoke` yields a *function* (`machine.lua:1094-1100`); that closure captures `args` and `target` as upvalues. This is the "index 2" case.
* every wrapped-userdata proxy, reached via the `__persist`-keyed metafields (`machine.lua:1061`, `1134`) — already M2 territory.

### One more OC fact that matters

`debug.sethook(co, checkDeadline, "", hookInterval)` is armed on `co` whenever the kernel resumes it (`machine.lua:1532`, `847`) and is *not* cleared in `main`'s loop. In LuaJIT hooks live in `global_State` (`g->hookf`/`g->hookmask`), not in `lua_State` — **there is no per-thread hook state to persist**, and (see §4) OC's Lua hooks cannot produce a `cont_hook` frame.

---

## 2. The running-thread rule — the exact check

`lua_status()` is just `return L->status` (`lj_api.c:97-100`); it is **useless** here, because a *running* thread and a *dead-by-return* thread both report `LUA_OK`. `G(L)->cur_L` is also wrong: it is only written at hook / GC / error / vmevent / callback boundaries (`lj_dispatch.c:385,564`, `lj_gc.c:523`, `lj_err.c:183`, `lj_ccallback.c:732`), not on every C call.

The single reliable discriminator is **`cframe`**. Both resume paths use it as the precondition (`lj_api.c:1231`, `lib_base.c:620`), and `m3probe.c` P5 confirms empirically that a mid-resume-chain ("normal") thread has `cframe != NULL`:

```
    outer: status=0 cframe=0x…fa41 base_ofs=6 costatus=normal
    inner: status=0 cframe=0x…f9f1 costatus=running
```

The main thread, however, is **not** caught by that test. `m3probe2.c` Q3 (`lua_resume(kernel)` driven from C, i.e. OC's exact pattern) shows:

```
  kernel: status=1 cframe=NULL -> "suspended"
  main  : status=0 cframe=NULL base=2 top=6 -> "running"   (only because co==L there)
```

With the main thread idle and `base == stack+1+LJ_FR2`, `coroutine_status`'s chain (`lib_base.c:574-579`) would classify it "suspended" from any other thread's point of view. So it needs its own test.

```c
/* p_thread preamble — runs before a single byte is written. */
static void p_thread_refuse(Info *I, lua_State *co)
{
  lua_State *L = I->L;

  /* (a) the thread executing eris.persist right now. Subsumed by (b) in every
   * reachable case (a running thread always sits under a vm_call/vm_pcall/
   * vm_resume cframe), but it earns a precise message and costs nothing. */
  if (co == L)
    luaL_error(L, "eris-lj: cannot persist a running thread");

  /* (b) anything with a live C activation: the running thread, and every
   * "normal" thread in the resume chain above it. cframe==NULL is exactly the
   * precondition both resume paths check (lj_api.c:1231, lib_base.c:620), and
   * is set by both yield paths (lj_api.c:1201, vm_x64.dasc:1710). */
  if (co->cframe != NULL)
    luaL_error(L, "eris-lj: cannot persist a running thread (it has a live C "
                  "stack frame: it is executing, or it is resuming another "
                  "coroutine)");

  /* (c) the main thread. NOT covered by (b): when the host drives a coroutine
   * with lua_resume() straight from C — which is exactly what OC does — the
   * main thread is idle with cframe == NULL and would look persistable.
   * Restoring it would mean handing back a lua_State that is not
   * gcref(g->mainthref), so its identity silently changes. */
  if (co == mainthread(G(L)))
    luaL_error(L, "eris-lj: cannot persist the main thread; "
                  "put it in the perms table if the host needs it by name");
}
```

**Is refusing the main thread right?** Yes, and it is not a real restriction for OC: OC's persisted root is always the kernel *coroutine* created by `lua.newThread`, never the state's main thread, and nothing in `machine.lua` can obtain the main thread (`coroutine.running()` returns **nil** on the main thread in 5.1 — `lib_base.c:585-596`, the non-`LJ_52` branch). And the escape hatch already exists for free: `persist_keyed` consults `PERMIDX` *before* `persist_typed` (`serializer/eris_lj.c:637-646`), so a host that registers the main thread as a permanent gets it by name with no code change.

For comparison, upstream Eris is strictly weaker here: `p_thread` only tests `thread == info->L` (`eris_master.c:1667-1670`, message `"cannot persist currently running thread"`, `eris_master.c:201`) and lets "normal" threads through, relying on `eris_assert`s that compile out in release builds (`eris_master.c:1866-1868`).

---

## 3. Thread statuses on the wire — and the coclone2 discrepancy, resolved

`coroutine.status` is **derived**, not stored (`lib_base.c:567-582`):

```c
  if (co == L) s = "running";
  else if (co->status == LUA_YIELD) s = "suspended";
  else if (co->status != LUA_OK) s = "dead";
  else if (co->base > tvref(co->stack)+1+LJ_FR2) s = "normal";
  else if (co->top == co->base) s = "dead";
  else s = "suspended";
```

and `ffh_resume` refuses on three conditions (`lib_base.c:619-622`):

```c
  if (co->cframe != NULL || co->status > LUA_YIELD ||
      (co->status == LUA_OK && co->top == co->base)) {
    ErrMsg em = co->cframe ? LJ_ERR_CORUN : LJ_ERR_CODEAD;
```

(`LJ_ERR_CORUN` = "cannot resume running coroutine", `LJ_ERR_CODEAD` = "cannot resume dead coroutine", `LJ_ERR_COSUSP` = "cannot resume non-suspended coroutine" — `lj_errmsg.h:79-81`.)

### The discrepancy

`coclone2.c` printed `dead(normal)` as `"suspended"` because it finished the coroutine with **`lua_resume` from C**, which leaves the return values on the coroutine's stack, so `top != base` and the last `else` fires. The `coroutine.resume` fast function copies the results out and then *clears the coroutine stack* (`vm_x64.dasc:1631-1633`), leaving `top == base`. `m3probe.c` P1/P1b shows both sides of it:

```
  dead(normal, Lua)       status=0 cframe=NULL base=2 top=2 -> "dead"
  dead(normal, C)         status=0 cframe=NULL base=2 top=3 -> "suspended"   nres left on co = 1
  dead(normal, C, popped) status=0 cframe=NULL base=2 top=2 -> "dead"
```

**Conclusion: your draft test's expectation ("a dead coroutine restores as dead") is correct**, because it drives the coroutine with Lua's `coroutine.resume`. `coclone2` was measuring a different, C-API-specific artifact. There is nothing to change in the test — but there *is* something the implementation must not do: it must round-trip `top_ofs` and `base_ofs` faithfully and must not "helpfully" normalise them, because `top == base` is the *only* thing distinguishing dead from never-started.

### The mapping table

| shape | `status` | `base_ofs` | `top_ofs` | `coroutine.status` | `coroutine.resume` | restore must produce |
|---|---|---|---|---|---|---|
| never started | `LUA_OK` (0) | `1+LJ_FR2` | `base+1` (fn at `base`) | `"suspended"` | runs from the top | fn at `stack[base_ofs]`, `top=base+1` |
| suspended | `LUA_YIELD` (1) | `> 1+LJ_FR2` | `>= base` | `"suspended"` | resumes at the yield | full slots + frames |
| dead, returned | `LUA_OK` (0) | `1+LJ_FR2` | `== base_ofs` | `"dead"` | `false, "cannot resume dead coroutine"` | empty stack, `top == base` |
| dead, error | `LUA_ERRRUN`(2)/`ERRMEM`/`ERRERR` | any | any | `"dead"` | `false, "cannot resume dead coroutine"` | keep the status byte; normalise the stack to empty |
| running | any | any | any | `"running"` | `false, "cannot resume running coroutine"` | **refused at persist** |
| normal | `LUA_OK` | `> 1+LJ_FR2` | any | `"normal"` | `false, "cannot resume running coroutine"` | **refused at persist** |

`m3probe.c` P2/P3 verify the two hand-built dead shapes end to end:

```
  built-dead      status=0 base=2 top=2 -> "dead"   coroutine.resume -> false, cannot resume dead coroutine
  built-dead-err  status=2 base=2 top=2 -> "dead"   coroutine.resume -> false, cannot resume dead coroutine
```

Two implementation consequences:

1. **A restored `LUA_OK` thread must never carry `base_ofs > 1+LJ_FR2`.** That combination makes `coroutine.status` say `"normal"` — a thread that is neither resumable nor dead. A crafted or buggy blob could produce it, so validate it on the read side (§7).
2. `lua_resume` from **C** on a restored dead-by-return thread does *not* refuse cleanly: `m3probe.c` P2 got `st=2 msg="attempt to call a nil value"` (because `lua_resume` only checks `cframe==NULL && status<=LUA_YIELD`, `lj_api.c:1229-1234`, then calls `api_call_base`). Restoring dead-by-*error* gives the clean `"cannot resume non-suspended coroutine"` instead. This is pre-existing LuaJIT behaviour, not something M3 introduces, but it is worth one sentence in the docs: hosts that C-resume a restored thread should check `coroutine.status` first. For OC it is a non-issue — a dead kernel is `error("computer halted", 0)` anyway (`machine.lua:1537-1538`).

---

## 4. What M3 must refuse

| shape | can OC produce it? | verdict | error message |
|---|---|---|---|
| the thread calling `eris.persist` | yes (only if user code calls persist) | **refuse** | `cannot persist a running thread` |
| any thread with `cframe != NULL` ("normal") | yes — every ancestor of the running thread | **refuse** | `cannot persist a running thread (it has a live C stack frame: …)` |
| the main thread | no (kernel is a `lua_newthread` coroutine) | **refuse** | `cannot persist the main thread; put it in the perms table …` |
| dead with a pending error status | yes (`sgcco` after a failed `__gc`; a crashed user coroutine) | **support** — normalise stack to empty, keep the status byte | — |
| `cont_hook` frames | **no** (see below) | **refuse** | `cannot persist a thread suspended inside a debug hook` |
| yield from inside a C function | no (OC yields only from Lua) | **support** — it needs no special code | — |
| `cont_stitch` frames | **yes, this is the common case** | **support** — zero the aux slot | — |
| `coroutine.wrap` objects | no (OC re-implements wrap in Lua, `machine.lua:867-877`) | **refuse** (falls out of M2's C-function rule) | `cannot persist a C function by value…` |

### Yield from inside a C function — legal, and it needs no special handling

`m3probe.c` P4 registers a C function that does `return lua_yield(L, 2)` and suspends a coroutine in it:

```
  suspended-in-C  status=1 cframe=NULL base=6 top=6 -> "suspended"
     top frame: islua=1   funcslot: isfunc=1 isluafunc=0 ffid=1   (FF_C)
  2nd resume    coroutine.resume -> true, after:nil,nil
```

The frame is a **plain `FRAME_LUA` link with a C function in the func slot** — structurally identical to a normal `coroutine.yield` suspension. On resume the C body is *not* re-entered; the resume arguments become the C function's return values (LuaJIT has no `lua_yieldk`). So the generic slot+frame machinery handles it, provided the C closure is reachable in `perms`. Do **not** add a refusal for it: any check that tried to would also reject every ordinary yield.

That is because — `m3probe.c` P8 —

```
  func slot of a thread suspended at coroutine.yield: isfunc=1 isluafunc=0 ffid=35
```

**`coroutine.yield` itself is a C function sitting in the persisted slot range** (`base-1-LJ_FR2`, which is inside `[1+LJ_FR2, top)`). It will hit `persist_typed`'s "cannot persist a C function by value; put it in the perms table" (`serializer/eris_lj.c:585-587`) unless it is a permanent. OC's `PersistenceAPI` flattens everything reachable from globals, and your test harness's `build_perms` reaches `_G.coroutine.yield`, so this works today — but it is a silent hard dependency and deserves an explicit assertion in the suite (§6.R).

### `cont_hook` — reachable in principle, unreachable in OC

`m3probe2.c` Q1a: a Lua hook installed with `debug.sethook` **cannot yield**:

```
  -> false / …:2: attempt to yield across C-call boundary
```

Reason: `callhook` (`lj_dispatch.c:366-392`) invokes `g->hookf`, and `lib_debug.c`'s hook trampoline calls the Lua function through `lua_call`, which pushes a fresh cframe *without* `CFRAME_RESUME` (`lj_frame.h:275`), so both the yield ffunc's `test aword L:RB->cframe, CFRAME_RESUME` (`vm_x64.dasc:1705`) and `cframe_canyield` (`lj_frame.h:292`) fail.

`m3probe3.c` (JIT off, so count hooks actually fire) shows the frame *is* producible from a **native C** hook that calls `lua_yield` directly, taking `lj_api.c:1204-1222`:

```
  lua_resume -> st=1 (LUA_YIELD) fired=1 status=1 cframe=NULL   base=15 top=15
   [ 14] type=2 delta=88 cont=0x7ff7…557 HOOK=1  aux[base-5]=0x0 (multres slot)
   [  3] type=5 delta=16
  resume again -> st=0 res=5000050000
```

Its layout, read off `lj_api.c:1206-1214`, is `[base-5]=multres (a raw u64, not a TValue)`, `[base-4]=cont`, `[base-3]=contpc`, `[base-2]=the thread itself as a `LJ_TTHREAD` TValue in a func slot`, `[base-1]=ftsz`. **OC installs only Lua hook functions**, so it cannot reach this. Refuse it — the func slot holding a thread rather than a function would also break every "func slot must be a function" validation you want on the read side. Eris takes the same position (`eris_master.c:1752`, `"cannot persist yielded hooks"`).

### `cont_stitch` — must be supported, and the aux slot must be raw zero

`vm_x64.dasc:2376-2405`:

```
  |->cont_stitch:
  |  mov TRACE:ITYPE, [RB-40]   // RB = framebase; -40 bytes = -5 slots
  |  cleartp TRACE:ITYPE
  …
  |  test TRACE:ITYPE, TRACE:ITYPE
  |  jz ->cont_nop
```

`framewalk`'s M0 run observed exactly this slot holding an `LJ_TTRACE`-tagged value at `framebase-5` (`prototype/framewalk/m0-results.txt`, scenario 7). So:

* persist: emit the aux slot as a **raw `u64`** record, not a value record — `lua_type()` on an `LJ_TTRACE` TValue is meaningless — and write `0`.
* restore: `(f-4)->u64 = 0;` with the continuation symbol left as **`stitch`**, not rewritten to `nop`. `cont_stitch` moves the results down *before* the zero test; jumping straight to `cont_nop` would skip those moves and corrupt the frame.

Note that this is required **even though `jit.flush()` runs first**: a flush blacklists trace links (`lj_trace.c:288`) but does not unwind stacks, so stitch frames created before the flush survive on suspended stacks.

---

## 5. Open upvalues across threads — the ordering constraint and the fix

### The constraint, stated precisely

Two facts collide:

1. An **open** `GCupval` can only be created once the owning thread's stack exists at the right address — `func_finduv` stores `setmref(uv->v, slot)` into the thread's sorted `openupval` list (`lj_func.c:37-69`).
2. Every closure `u_function` builds comes from `lua_loadx`, and `lj_func_newL_empty` gives it **closed** upvalues (`func_emptyuv`, `lj_func.c:71-79`) — proven in `m3probe2.c` Q2 (`A.uv closed=1  B.uv closed=1`).

The writer's encounter order is fixed and can put either object first, and **neither hoisting nor eager creation can fix it**:

* You cannot force the *thread* to be written before the closure. Hoisting means recursing into the thread's stack, which routinely contains that very closure; the closure's id is reserved by `persist_keyed` (`serializer/eris_lj.c:626-629`) but on the read side `u_function` only registers the object *after* `lua_loadx` returns, so the back-reference would resolve to a nil `REFTIDX` entry — "dangling reference".
* You cannot force the *closure* first either: at that moment nothing tells you the upvalue is open into a thread the writer has not reached yet.

So the graph order is genuinely free, and the only correct mechanism is a **deferred referrer back-patch list**.

### What upstream Eris does

Exactly this. `p_upval` is nothing but `persist(info)` — the upvalue's *value* (`eris_master.c:1373-1376`). `u_upval` returns a **table placeholder**, not an upvalue (`eris_master.c:1378-1391`), and `u_closure` records every `(closure, upvalue-slot)` pair that binds it into that table starting at index `UVTREF` (`eris_master.c:1599-1640`). Then `u_thread`, once the stack exists, calls `eris_findupval(thread, stk)` and rewrites every recorded referrer (`eris_master.c:1989-2050`):

```c
        /* Open the upvalue by pointing to the stack and register in GC. */
        cl->upvals[nup - 1] = nuv;
        luaC_objbarrier(info->L, cl, nuv);
```

The comment at `eris_master.c:1396-1401` states the invariant outright: *"we will restore any upvalues of Lua closures as closed as first … When loading a thread containing the upvalue (meaning it's the actual owner of the upvalue) we open it."*

That convention has a second, free benefit worth keeping: an open upvalue whose owning thread is **not in the graph** correctly comes back closed with its last value. Nothing can ever observe the difference, because the frame that owned the slot is unreachable.

### The LuaJIT mechanics — proven

`m3probe2.c` Q2 runs the whole sequence on real `lua_loadx` closures: load one dumped proto twice → join B to A's closed upvalue → create an open upvalue on a thread slot holding `40` → re-point both closures → full GC → call each:

```
  A nupvalues=1  B nupvalues=1
  A.uv closed=1  B.uv closed=1  same object=0
  joined: A.uv==B.uv? 1
  after backpatch+GC: A.uv==B.uv? 1  open=1  tracks slot=1 value=40
  A(2) -> 42   (thread slot now 42)
  B(5) -> 47   (thread slot now 47)
```

Two things this pins down:

* `lj_gc_objbarrier(L, fn, obj2gco(uv))` is **required**, not decorative — the referrer closures were created earlier in the parse and may already be black; the fresh `GCupval` is white.
* An in-place `closed → open` mutation of the existing `GCupval` (tempting, because it would need no referrer list at all) is **not** a safe alternative: `gc_mark` does `gray2black(o)` for closed upvalues (`lj_gc.c:78-83`), while `lj_func_closeuv` asserts `!isblack(o)` for open ones (`lj_func.c:88`), and the open form's `prev`/`next` share a union with the closed form's `tv` (`lj_obj.h:437-443`). Use the referrer list.

### Concrete changes to `eris_lj.c`

Reinterpret the two existing upvalue tables (they are already a separate id space, `serializer/eris_lj.c:89-96`):

```
UPVIDX [id] -> lightuserdata(GCupval *)          the upvalue object itself
UPVNIDX[id] -> { cl1, n1, cl2, n2, … }          every closure slot bound to it
```

`UPVIDX` may now name an upvalue with **no owning closure** (created by a thread record), which is why `lua_upvaluejoin` has to go: it can only join a slot to *another closure's* slot. Replace it with a direct pointer write — you are already inside `lj_obj.h`.

```c
/* Anchoring note: a lightuserdata GCupval* is safe for the life of the parse
 * because whatever created it is itself anchored in REFTIDX — the owning
 * thread (open upvalues live on co->openupval) or the creating closure
 * (closed upvalues are held by fn->l.uvptr[]). */

static GCupval *elj_upv_get(Info *I, uint64_t id)
{
  lua_State *L = I->L;
  void *p;
  if (id == 0 || id > (uint64_t)I->upvcount)
    luaL_error(L, "eris-lj: upvalue reference %d out of range (%d known)",
               (int)id, (int)I->upvcount);
  lua_rawgeti(L, UPVIDX, (int)id);
  p = lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (!p) luaL_error(L, "eris-lj: corrupt upvalue reference %d", (int)id);
  return (GCupval *)p;
}

/* Bind closure slot `n` of the function at stack index `fidx` to upvalue
 * `id`, and remember the binding so a later thread record can re-point it. */
static void elj_upv_bind(Info *I, uint64_t id, int fidx, int n, GCupval *uv)
{
  lua_State *L = I->L;
  GCfunc *fn = funcV(L->base + fidx - 1);
  int k;
  setgcref(fn->l.uvptr[n - 1], obj2gco(uv));
  lj_gc_objbarrier(L, fn, obj2gco(uv));       /* fn may already be black */

  lua_rawgeti(L, UPVNIDX, (int)id);           /* referrer list | nil */
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_rawseti(L, UPVNIDX, (int)id);
  }
  k = (int)lua_objlen(L, -1);
  lua_pushvalue(L, fidx);   lua_rawseti(L, -2, k + 1);
  lua_pushinteger(L, n);    lua_rawseti(L, -2, k + 2);
  lua_pop(L, 1);
}

/* Called from u_thread once the stack exists: replace whatever closed
 * upvalue the referrers currently share with the open one at `slot`. */
static void elj_upv_open(Info *I, uint64_t id, GCupval *uv)
{
  lua_State *L = I->L;
  lua_rawgeti(L, UPVNIDX, (int)id);
  if (lua_istable(L, -1)) {
    int n = (int)lua_objlen(L, -1), j;
    for (j = 1; j + 1 <= n; j += 2) {
      GCfunc *fn; int nup;
      lua_rawgeti(L, -1, j);
      if (!lua_isfunction(L, -1) || lua_iscfunction(L, -1))
        luaL_error(L, "eris-lj: corrupt upvalue referrer list");
      fn = funcV(L->top - 1); lua_pop(L, 1);
      lua_rawgeti(L, -1, j + 1); nup = (int)lua_tointeger(L, -1); lua_pop(L, 1);
      if (nup < 1 || nup > (int)fn->l.nupvalues)
        luaL_error(L, "eris-lj: corrupt upvalue referrer slot");
      setgcref(fn->l.uvptr[nup - 1], obj2gco(uv));
      lj_gc_objbarrier(L, fn, obj2gco(uv));
    }
  }
  lua_pop(L, 1);
  lua_pushlightuserdata(L, uv);
  lua_rawseti(L, UPVIDX, (int)id);            /* later joins get the open one */
}
```

`u_function`'s two branches become:

* **`TAG_UPVAL`** — `id = ++I->upvcount;` take the closed upvalue `lua_loadx` already made (`&gcref(funcV(...)->l.uvptr[i-1])->uv`), `lua_pushlightuserdata`/`rawseti` it into `UPVIDX[id]`, `elj_upv_bind(I, id, fidx, i, uv)`, **then** `unpersist(I)` the value and `lua_setupvalue`. Publishing before reading the value is exactly the reason the M2 comment at `serializer/eris_lj.c:743-749` gives, and it still holds.
* **`TAG_UPVALREF id`** — `uv = elj_upv_get(I, id); elj_upv_bind(I, id, fidx, i, uv);`. This works whether `id` names a still-closed upvalue or one a thread already opened.

And `p_function`'s upvalue loop needs no change *except* that `p_thread` must be allowed to allocate ids too (§7), so that a thread encountered before its closures is the creator; a closure met later then writes `TAG_UPVALREF`. Both orders are covered.

---

## 6. Review of `serializer/tests/m3.lua`

### Expectations that are wrong or vacuous

**A. `m3.lua:236-241` is dead code and asserts nothing.**

```lua
  local ok_, err = pcall(function()
    return eris.persist(BASEP, coroutine.running() or "main")
  end)
```

On the main thread `coroutine.running()` is `nil` (`lib_base.c:585-596`), so this persists the *string* `"main"`, succeeds, and `ok_`/`err` are never read. Delete it, or turn it into a positive assertion. The second half of that block (`m3.lua:242-247`) is structurally correct; pin the message with `tostring(inner_err):find("running", 1, true)`.

**B. `m3.lua:227-235` (dead coroutine) is CORRECT — keep it.** My initial suspicion from `coclone2` was wrong: that probe used C `lua_resume`, which leaves results on the coroutine stack (`top != base` → `"suspended"`); Lua's `coroutine.resume` clears them (`vm_x64.dasc:1631-1633`) so `top == base` → `"dead"` (`m3probe.c` P1/P1b). Strengthen it: also assert the refusal *message* is `"cannot resume dead coroutine"`, and add a dead-**by-error** sibling (`coroutine.create(function() error("x") end)`, resumed once) which travels the `status > LUA_YIELD` path instead.

**C. `m3.lua:173`, `m3.lua:188` (open-upvalue tests) are correct but under-assert.** They never check that the *original* and the *restored* upvalues are independent after the restore. Add `bump(); ok(select(2, coroutine.resume(co)) == 2)` alongside the clone's `== 2` from a *different* upvalue object.

**D. `m3.lua:210` weakens the nested-coroutine test** by passing `inner` explicitly. The real question is whether a thread reachable **only** through another thread's frame slot round-trips; persist just `co` and pull `inner` back out of the restored outer's own logic.

**E. Everything else structurally checks out**, including the `__index`/`__concat` continuation tests (`m3.lua:139-158` — these produce the `cont=ra` and `cont=cat` frames that `m0-results.txt` scenarios 3–4 already validated), the `pcall`/`xpcall` frames (`FRAME_PCALL` deltas 16/24, scenario 2), and the vararg chain (`m3.lua:86-97` → `FRAME_VARG` delta 40, scenario 5).

### Missing scenarios, in rough priority order

**F. (highest) The JIT-stitch case is absent, and the research says it is OC's *common* case, not an edge case.** `coroutine.yield` has no JIT recorder, so a yield from a compiled loop goes through `recff_nyi` → stitch and leaves a `cont_stitch` frame with a live `GCtrace` reference at `framebase-5`. Nothing in the current suite ever compiles a loop that yields. Add three variants: (i) hot loop yields, persist **without** `jit.flush()`; (ii) same, **with** `jit.flush()` between suspend and persist; (iii) restore and resume for many more iterations so the restored thread re-enters the interpreter path (`cont_nop`) and still computes the right sum.

**G. The "normal" (mid-resume-chain) refusal.** Nothing tests it, and it is the failure mode most likely to be silently accepted by a naive `co == L` check:
```lua
local outer
outer = coroutine.create(function()
  local inner = coroutine.create(function()
    return select(2, pcall(eris.persist, BASEP, outer))  -- outer is 'normal'
  end)
  return select(2, coroutine.resume(inner))
end)
local _, err = coroutine.resume(outer)
ok(tostring(err):find("running", 1, true), "a resuming ('normal') thread is refused", err)
```

**H. `coroutine.wrap` refusal.** `coroutine.wrap(f)` is a C closure (`ffid` 37, `coroutine_wrap_aux`) holding the thread as an upvalue; M2's C-function rule already refuses it, but nothing asserts the message is comprehensible. OC dodges this by re-implementing `wrap` in Lua (`machine.lua:867-877`) — worth a test that documents why.

**I. Thread identity/dedup:** `local g = roundtrip({a = co, b = co}); ok(rawequal(g.a, g.b))`.

**J. Self-reference:** a coroutine whose own stack holds a reference to itself (`local me = coroutine.running()` before the yield), and a table containing the thread that the thread's stack also references. This exercises the "register the thread in `REFTIDX` before reading its slots" ordering.

**K. An open upvalue whose owning thread is *not* persisted** — must come back closed with its value:
```lua
local co = coroutine.create(function() local n=5 coroutine.yield(function() n=n+1 return n end) end)
local _, f = coroutine.resume(co)
local g = roundtrip(f)            -- only the closure travels
ok(g() == 6, "an orphaned open upvalue restores closed, with its value")
```

**L. The real OC kernel shape** — a `load()`ed **chunk** (vararg) run as a thread and suspended through `pcall(main)` → `coroutine.yield(x)`, so the `FRAME_VARG` + `LUA(pcall ffunc)` + `FRAME_PCALL` combination from `m3probe4.c` is actually exercised. Your `make_kernel` (`m3.lua:256-267`) is a plain `function() end` coroutine and produces neither.

**M. The OC nesting shape**: a chain of ≥3 suspended threads where each intermediate one is suspended *inside its own resume wrapper* — literally `machine.lua:848-857` — persisted from the outermost only.

**N. The synchronized-call shape**: a coroutine that yields a *closure* capturing locals, restored and then called.

**O. A genuine serialization boundary.** Nothing in the suite proves the blob is self-contained rather than a same-process shortcut. At least one test should do `local blob = eris.persist(p, co); co = nil; collectgarbage("collect"); collectgarbage("collect"); local g = eris.unpersist(u, blob)`.

**P. Malformed-blob robustness for thread records** — the M1/M2 suites cover this for other tags and the thread record adds the largest new attack surface: `base_ofs > top_ofs`, `top_ofs` past `LUAI_MAXSTACK` (`coclone2.c` §D proves `lj_state_cpgrowstack` returns `LUA_ERRRUN` + a clean `"stack overflow"` string past 65500), a frame slot outside `[1+LJ_FR2, base_ofs)`, an unknown continuation symbol, a `pcofs` past `pt->sizebc`, an open-upvalue slot ≥ `top_ofs`, and `status = LUA_OK` with `base_ofs > 1+LJ_FR2`. Each must be a catchable error leaving the state usable.

**Q. Failure leaves a usable state**: after each refusal above, assert that an ordinary `roundtrip({1,2,3})` still works.

**R. Assert the hidden perms dependency**, so a future perms change fails loudly instead of mysteriously:
```lua
ok(BASEP[coroutine.yield] ~= nil,
   "coroutine.yield must be a permanent: it sits in the func slot of every "..
   "suspended frame and would otherwise be refused as a C function")
```

---

## 7. Wire format and the restore contract

### Record layout (new tags)

```
TAG_THREAD   = 12    /* value slot */
TAG_RAWSLOT  = 14    /* thread slot array only: u64le raw bits, no TValue tag */
```

```
TAG_THREAD:
  u8    status                 LUA_OK | LUA_YIELD | LUA_ERR*
  uleb  top_ofs
  uleb  base_ofs
  <top_ofs - (1+LJ_FR2) value records>       slots [1+LJ_FR2, top_ofs)
  u32le nframes
  <frame records>                            innermost -> outermost
  uleb  nopenuv
  <(uleb slot, uleb upvalue_id, u8 immutable) * nopenuv>
  <value record>                             the thread env

frame record:
  uleb  frame_slot                           index of the ftsz word
  u8    kind
   0 LUA   : uleb owner_func_slot, uleb pcofs
   1 DELTA : u8 type (C|CP|VARG|PCALL|PCALLH), uleb delta_bytes
   2 CONT  : uleb delta_bytes, u8 cont_sym, uleb owner_func_slot, uleb contpc_ofs
```

Recording `frame_slot` explicitly (rather than re-deriving the chain) is what makes every read-side bound check possible and removes any order coupling between the slot array and the frame list.

### The GC hazards — this is the part the prior spikes did not cover

`u_thread` allocates on `L` between every slot write, so an incremental GC step can land on a *half-built* thread. Three source facts constrain the build order:

1. `gc_traverse_thread` marks only `[stack+1+LJ_FR2, top)`, and **in the atomic phase it `setnilV`s every slot from `top` to `stacksize`** (`lj_gc.c:309-317`). A slot written above `top` can therefore be silently nil'd.
2. `lj_state_shrinkstack(th, gc_traverse_frames(g, th))` runs on every thread traverse (`lj_gc.c:320`), and shrinks when `4*used < stacksize` (`lj_state.c:98-107`). `coclone.c` observed exactly this — a clone grown to `stacksize=114` came back from a full GC at `66`, with `base`/`top`/open upvalues correctly relocated by `resizestack` (`lj_state.c:63-87`).
3. `gc_traverse_frames` walks the chain from `th->base-1` and dereferences `frame_func(frame)` / `funcproto(fn)` (`lj_gc.c:291-306`). On a half-built thread those are garbage.

The clean answer is a build order, not Eris's `L->stack = NULL` LOCK/UNLOCK hack (`eris_master.c:1815-1826`):

* **Set `co->top` to its final value immediately after growing**, with the slots still nil. Then every slot you write is inside the marked range, `shrinkstack`'s `used` is already `top_ofs`, and no shrink can ever drop below what you need.
* **Leave `co->base` at `stack+1+LJ_FR2` for the entire build.** That makes `gc_traverse_frames`'s loop condition `frame > bot+LJ_FR2` false on entry, so it never touches a garbage frame link or a non-function func slot. Set `base`, `status` and `env` together as the very last step.
* **Re-fetch `tvref(co->stack)` after every `unpersist()`** — the stack can move under you.
* **No write barrier is needed for slot writes**: `propagatemark` re-greys threads with the comment *"Threads are never black."* (`lj_gc.c:345-351`). Same for `setgcrefr(co->env, …)`.

### `u_thread` sketch

```c
static void u_thread(Info *I)
{
  lua_State *L = I->L, *co;
  uint64_t top_ofs, base_ofs;
  unsigned char status;
  uint32_t nframes, k, nuv;
  MSize i;

  luaL_checkstack(L, 6, "eris-lj thread");
  co = lua_newthread(L);                    /* ... co */
  registerobject(I);                        /* BEFORE the slots: cycles resolve */

  status   = r_byte(I);
  top_ofs  = r_uleb(I);
  base_ofs = r_uleb(I);
  if (top_ofs < 1u + LJ_FR2 || top_ofs >= (uint64_t)LUAI_MAXSTACK)
    luaL_error(L, "eris-lj: thread top offset %d out of range", (int)top_ofs);
  if (base_ofs < 1u + LJ_FR2 || base_ofs > top_ofs)
    luaL_error(L, "eris-lj: thread base offset %d out of range", (int)base_ofs);
  switch (status) {
  case LUA_OK:
    /* Otherwise coroutine.status() would report "normal" (lib_base.c:577):
     * neither resumable nor dead. Never a legal restored shape. */
    if (base_ofs != 1u + LJ_FR2)
      luaL_error(L, "eris-lj: a non-suspended thread cannot have live frames");
    break;
  case LUA_YIELD:
    break;
  case LUA_ERRRUN: case LUA_ERRMEM: case LUA_ERRERR: case LUA_ERRSYNTAX:
    break;                                  /* dead by error; see below */
  default:
    luaL_error(L, "eris-lj: invalid thread status byte %d", (int)status);
  }

  /* Grow once; then publish `top` so every slot below it is GC-visible and
   * shrinkstack cannot undercut us (see the GC-hazard notes). */
  {
    MSize have = (MSize)(mref(co->maxstack, TValue) - tvref(co->stack));
    if ((MSize)top_ofs > have &&
        lj_state_cpgrowstack(co, (MSize)top_ofs - have) != LUA_OK) {
      co->top = tvref(co->stack) + 1 + LJ_FR2;   /* drop its error object */
      luaL_error(L, "eris-lj: cannot grow the restored thread to %d slots",
                 (int)top_ofs);
    }
  }
  co->top = tvref(co->stack) + top_ofs;
  /* co->base deliberately stays at stack+1+LJ_FR2 until the very end. */

  for (i = 1 + LJ_FR2; i < (MSize)top_ofs; i++) {
    if (I->in[I->pos] == TAG_RAWSLOT) {     /* stitch aux, never a TValue */
      (void)r_byte(I);
      tvref(co->stack)[i].u64 = r_u64le(I);
    } else {
      unpersist(I);                         /* ... co v  (may reallocate) */
      copyTV(co, tvref(co->stack) + i, L->top - 1);   /* NOBARRIER */
      lua_pop(L, 1);
    }
  }

  nframes = r_u32le(I);
  for (k = 0; k < nframes; k++) u_frame(I, co, base_ofs);   /* §7 validation */

  nuv = (uint32_t)r_uleb(I);
  for (k = 0; k < nuv; k++) {
    uint64_t slot = r_uleb(I), id = r_uleb(I);
    unsigned char imm = r_byte(I);
    GCupval *uv;
    if (slot < 1u + LJ_FR2 || slot >= top_ofs)
      luaL_error(L, "eris-lj: open upvalue slot %d outside [%d,%d)",
                 (int)slot, 1 + LJ_FR2, (int)top_ofs);
    uv = elj_finduv(L, co, tvref(co->stack) + (MSize)slot, 0, imm != 0);
    if (id > (uint64_t)I->upvcount) {       /* the thread is the creator */
      if (id != (uint64_t)I->upvcount + 1)
        luaL_error(L, "eris-lj: upvalue id %d out of sequence", (int)id);
      ++I->upvcount;
    }
    elj_upv_open(I, id, uv);                /* publish + back-patch referrers */
  }

  unpersist(I);                             /* ... co env */
  if (!lua_istable(L, -1))
    luaL_error(L, "eris-lj: thread environment is a %s", luaL_typename(L, -1));
  setgcref(co->env, obj2gco(tabV(L->top - 1)));   /* NOBARRIER: never black */
  lua_pop(L, 1);

  /* Dead-by-error: nothing on such a stack is observable from Lua
   * (coroutine.status -> "dead" on `status != LUA_OK` alone, lib_base.c:576;
   * ffh_resume refuses on `status > LUA_YIELD`, lib_base.c:620), so drop it. */
  if (status > LUA_YIELD) {
    co->top = co->base = tvref(co->stack) + 1 + LJ_FR2;
  } else {
    co->base = tvref(co->stack) + base_ofs;
    co->top  = tvref(co->stack) + top_ofs;
  }
  co->status = status;
  /* co->cframe is already NULL from lua_newthread (lj_state.c:362-378). */
}
```

`elj_finduv` is `coclone.c`'s replica of `func_finduv` minus the resurrect branch, **allocating on `L`, not on `co`** — `co->cframe == NULL` would panic. `dhash` can be left 0: it is only a JIT alias-disambiguation hint (`lj_obj.h:445`) and is address-derived anyway. `immutable` **must** be carried faithfully — the recorder constant-folds immutable upvalues, so a wrong value is a miscompile, not a perf loss.

### `u_frame` validation

```c
  uleb fs;  if (fs < 1u+LJ_FR2 || fs >= base_ofs) -> error
  LUA   : owner_func_slot must hold a Lua function (tvisfunc && isluafunc);
          0 < pcofs <= pt->sizebc;  setframe_pc(f, proto_bc(pt) + pcofs)
  DELTA : type in {C,CP,VARG,PCALL,PCALLH}; delta 8-byte aligned; nonzero;
          f - delta/8 >= stack + LJ_FR2;  setframe_ftsz(f, (int64_t)delta|type)
  CONT  : fs >= 4 + LJ_FR2 (5 if sym == STITCH); sym < TCONT__MAX and != HOOK;
          setcont(f - 3, elj_conts[sym]);          /* [base-4], lj_frame.h:91  */
          setframe_pc(f - 2, proto_bc(cpt) + cpcofs);  /* [base-3], :89       */
          setframe_ftsz(f, (int64_t)delta | FRAME_CONT);
          if (sym == TCONT_STITCH) (f - 4)->u64 = 0;   /* [base-5] = [RB-40]  */
```

Frame decoding on the persist side **must test `frame_islua()` before `frame_typep()`** — a Lua frame's `ftsz` is a `BCIns*` whose bit 2 is address data, so `frame_typep()` reports `FRAME_LUAP` at random (`prototype/framewalk/README.md`, finding 2).

The continuation relocation table is built once at load time from `lj_vm.h:108-114`:

```c
static const void *const elj_conts[] = {
  NULL, NULL,                                    /* LJ_CONT_TAILCALL / FFI_CB */
  (const void *)lj_cont_cat,   (const void *)lj_cont_ra,
  (const void *)lj_cont_nop,   (const void *)lj_cont_condt,
  (const void *)lj_cont_condf, (const void *)lj_cont_hook,   /* refused */
  (const void *)lj_cont_stitch
};
```

---

## 8. The honest scope boundary for M3

**In scope, and OC needs all of it:** threads suspended at `coroutine.yield` in Lua code; `FRAME_LUA` / `FRAME_VARG` / `FRAME_PCALL` / `FRAME_PCALLH` / bottom `FRAME_CP` frames; `FRAME_CONT` with `ra`/`nop`/`cat`/`condt`/`condf`; `cont_stitch` with a zeroed aux slot; never-started and both flavours of dead; arbitrary nesting of suspended threads; open upvalues shared across the thread boundary in either graph order.

**Out of scope, refused with a documented error:** anything with `cframe != NULL` (running or "normal"); the main thread (unless the host puts it in perms); `cont_hook` frames; unknown continuation addresses; a Lua frame whose caller slot is not a Lua function; a C function in any func slot that is not in the perms table.

**In scope but unexercised by OC, and free:** yield from inside a C function — it needs no code, only the C closure in perms.

**Load-bearing assumptions inherited from the constraints, not re-proved here:** `jit.flush()` before persist (removes J-variant bytecode, `lj_trace.c:204-232`); the host stops the GC and unlimits memory (the build-order rules in §7 mean M3 survives a GC anyway, which `coclone.c`'s mid-build `LUA_GCCOLLECT` and `m3probe2.c` Q2 both demonstrate, but the invariants are subtle enough that I would not want to lean on them); `PROTO_ILOOP`-blacklisted bytecode is normalised at dump time, per `lj_bcwrite.c:300-315`.


# KEY CLAIMS
- [high] coclone2's "dead(normal) prints as suspended" was a C-API artifact, not a real ambiguity: coroutine.status is derived state (lib_base.c:567-582), and lua_resume leaves results on the coroutine stack so top != base, while the coroutine.resume ffunc clears them (vm_x64.dasc:1631-1633) giving top == base -> "dead". The draft test's expectation that a dead coroutine restores as dead is therefore CORRECT, provided the wire round-trips top_ofs/base_ofs faithfully.
- [high] cframe != NULL is the necessary and sufficient test for a thread that is running or resuming another (proven: a mid-chain thread reports coroutine.status "normal" with cframe != NULL), but it does NOT catch the main thread: when the host drives a coroutine with lua_resume straight from C — OC's exact pattern — the main thread is idle with cframe == NULL and would look persistable. lua_status() and G(L)->cur_L are both unusable as discriminators.
- [high] The closed-upvalue -> open-upvalue back-patch is the only correct fix for the cross-thread ordering problem, and it works on real lua_loadx closures: two closures joined to one closed upvalue were re-pointed to a fresh open upvalue on a thread's stack slot, survived a full GC, kept sharing, and both mutated the thread slot (40 -> 42 -> 47). lj_gc_objbarrier on each referrer is required, not optional. In-place closed->open mutation is unsafe (gc_mark blackens closed upvalues, lj_gc.c:78-83, while lj_func_closeuv asserts open ones are never black).
- [high] A cont_hook frame is reachable ONLY from a native C hook calling lua_yield (lj_api.c:1204-1222); a Lua hook installed with debug.sethook cannot yield at all — it fails with "attempt to yield across C-call boundary" because callhook invokes it through lua_call, which pushes a cframe without CFRAME_RESUME. OC installs only Lua hooks, so it can never produce one.
- [high] The OC kernel is suspended at machine.lua:1540 (`coroutine.yield(result[2])`) inside pcall(main) at machine.lua:1548, and its frame chain is exactly five frames deep: CP(bottom) / VARG(the vararg main chunk) / LUA(the pcall ffunc) / PCALL(main) / LUA(coroutine.yield). The FRAME_VARG frame comes from the kernel being a main chunk and is not produced by any test in the current suite.
