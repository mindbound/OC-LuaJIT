# M3 ARM — the cross-process frame codec

**Bottom line: it works.** A genuine symbolic round trip now runs end-to-end on **8 frame shapes** — vararg + tailcall + `pcall`, `cont_ra`, `cont_cat`, `cont_nop`, `cont_condf`, an `ITERC` frame, `FRAME_PCALL` from `xpcall`, and a JIT **`cont_stitch`** frame — with **zero** frame words copied raw, decoded against protos that came out of `lua_dump`/`lua_load` and are different objects at different addresses. All 8 resume to results byte-identical to the original. The exhaustive negative sweep rejects **103/103** in-range-but-wrong `FRAME_LUA` bytecode offsets.

Probes (scratchpad, working tree untouched):
* `C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\m3\m3frames.c` — the round trip
* `...\scratchpad\m3\m3trace.c` — the stitch-aux value question, settled by two SIGSEGVs

Build: `gcc -std=c11 -O2 -g -Wall -Wextra -I prototype/watchdog/luajit/src <f>.c prototype/watchdog/libluajit_stock.a -lm -o <f>.exe`

> Note: `git status` in the repo already shows ` M .gitignore` and `?? prototype/coclone/` — both pre-existed this session (the opening snapshot was stale); I created nothing under the repo.

---

## 1. `FRAME_LUA`

### The caller-proto rule, and why it is always well-defined

For a Lua frame word `f` (frame base `= f+1`), `f->ftsz` is a `BCIns*` into the bytecode of **`frame_func(frame_prevl(f))`** — the function of the *next-outer frame word*, not necessarily the "calling function's frame" in the intuitive sense. That single rule covers every case, and the probe confirms all of them:

| what `frame_prevl(f)` lands on | `frame_func(prev)` is | seen in |
|---|---|---|
| another `FRAME_LUA` | the caller Lua function | every scenario |
| `FRAME_VARG` | **a copy of the vararg callee itself**, which *is* the function containing the CALL | `m3frames` scenario 1, frame [0]→[1] |
| `FRAME_CONT` | the metamethod (Lua) that is executing | `cont_ra`/`cont_cat`/`cont_nop`/`cont_condf` scenarios |
| `FRAME_PCALL`/`PCALLH` | the function `pcall`/`xpcall` was told to run | scenario 1 frame [2]→[3], xpcall scenario |
| the bottom `FRAME_CP` | **the coroutine's entry function** | all 8 scenarios, slot 2 |

The `FRAME_VARG` case is the one that looks like a counterexample and isn't. `BC_IFUNCV` (`vm_x64.dasc:4845-4870`) copies the LFUNC up: `mov [RD-16], LFUNC:KBASE` — so a vararg activation has *two* frame words, a lower `FRAME_LUA` (func = the vararg fn, ftsz = the real return PC) and an upper `FRAME_VARG` (func = a copy of the same fn, ftsz = delta). A callee inside the vararg function has `frame_prevl` land on the `FRAME_VARG` word, whose func slot is exactly the proto that owns the PC. Uniform rule, no special case.

The bottom-most Lua frame is well-defined because `lj_vm_resume` (`vm_x64.dasc:575`) leaves the entry function at stack slot 2 under a `FRAME_CP` word at slot 3 (`ftsz = 16|FRAME_CP = 0x15`, observed identical in all 8 scenarios), and `base = 4`. A coroutine whose body is a *C* function can never be suspended (yield across a C boundary errors), so `frame_func(prev)` for a `FRAME_LUA` is always a Lua function — and the decoder must check it anyway.

### Encode

```c
/* f is the frame word; stack = tvref(co->stack) */
TValue *prev = frame_prevl(f);                    /* lj_frame.h:108 */
GCproto *pt  = funcproto(funcV(prev - 1));        /* must be checked isluafunc */
rec.kind  = FRAME_LUA;
rec.bcofs = (uint32_t)(frame_pc(f) - proto_bc(pt));   /* lj_obj.h:421 */
rec.link  = (uint64_t)((char *)f - (char *)prev);     /* == 8*(2 + bc_a(pc[-1])) */
```

`rec.link` is **redundant but load-bearing**: it is the only way the decoder can find the caller's func slot *before* it has a PC, and it is then re-derived and checked (below). It costs one ULEB byte in practice (observed values 16, 32, 40, 48, 64).

### Decode

```c
TValue *prev = (TValue *)((char *)f - rec.link);
/* ... all pass-1 bounds already checked; see §4 ... */
if (!tvisfunc(prev-1) || !isluafunc(funcV(prev-1))) ERR("caller not a Lua function");
GCproto *pt = funcproto(funcV(prev-1));
if (rec.bcofs < 1 || rec.bcofs >= pt->sizebc)      ERR("bc offset out of range");
const BCIns *pc = proto_bc(pt) + rec.bcofs;

setframe_pc(f, pc);            /* lj_frame.h:51 — see below */

if (frame_prevl(f) != prev)                        ERR("bc_a disagrees with link");
switch (bc_op(pc[-1])) {
  case BC_CALL: case BC_CALLM: case BC_ITERC: case BC_ITERN: break;
  default:                                         ERR("return pc does not follow a call");
}
```

**Is the raw u64 write right?** Yes, and `setframe_pc` is exactly it. Under FR2, `lj_frame.h:51` is

```c
#define setframe_pc(f, pc)  ((f)->ftsz = (int64_t)(intptr_t)(pc))
```

and `ftsz` is a full `int64_t` member of the `TValue` union (`lj_obj.h`, `#if LJ_FR2 int64_t ftsz;`), so it overwrites all 8 bytes — no tag survives, no read-modify-write. Use the macro rather than `f->u64 = ...`; it is the same store and it documents intent. The stored value's `itype` is `(u64 >> 47) == 0` for any x86-64 user-space pointer, i.e. the GC sees a denormal double and never treats it as a reference (`lj_obj.h:784`, `lj_obj.h:812`) — which is why the VM can park a raw pointer in a live stack slot at all.

`CALLT`/`CALLMT` never appear as `pc[-1]`: a tailcall reuses the frame, so the frame keeps the *original* caller's PC. The 8-scenario probe confirms the whitelist is exactly `{CALL, CALLM, ITERC, ITERN}` — nothing legitimate trips it. Note scenario 1 contains a tailcall (`mid` does `return leaf(...)`), collapsed exactly as expected.

### Bounds a crafted blob must satisfy, and what a wrong PC does

* `1 <= bcofs < pt->sizebc`. `sizebc` counts the `BC_FUNCF`/`BC_FUNCV` header at index 0, and the VM reads `pc[-1]`, so offset 0 is illegal; the last instruction of every proto is a `RET*`, so `sizebc` itself is unreachable.
* `frame_prevl(f) == prev`, i.e. `bc_a(pc[-1]) == rec.link/8 - 2`.
* `bc_op(pc[-1]) ∈ {CALL, CALLM, ITERC, ITERN}`.

An **in-range-but-wrong** PC is memory-unsafe, not merely wrong. On resume-after-yield the VM loads `PC = [BASE-8]` and, for a Lua frame, jumps to `BC_RET_Z` (`vm_x64.dasc:575-609`, `:4490`). `BC_RET_Z` then does

```
movzx RAd, PC_RA          ; bc_a of pc[-1]
neg   RA
lea   BASE, [BASE+RA*8-16]        ; base = base - (RA+2)*8
mov   LFUNC:KBASE, [BASE-16]      ; the caller's func slot
mov   KBASE, LFUNC:KBASE->pc      ; ** wild dereference if that slot isn't an LFUNC **
```

so a wrong `bc_a` shifts `BASE` to an arbitrary stack offset and immediately dereferences whatever sits at `BASE-2` as a `GCfuncL`. It also uses `PC_RB` to decide how many results to keep/nil-fill, writing below the shifted base. That is arbitrary read *and* write in the host process. The `frame_prevl == prev` + call-op pair is what closes it: the exhaustive sweep in the probe corrupted **every** valid offset of **every** `FRAME_LUA` frame in all 8 scenarios — 103 mutations — and rejected 103/103. (With only the `frame_prevl` check, 2 of 3 tried offsets slipped through in the first run; the call-op check is what caught them. Keep both.)

---

## 2. `FRAME_CONT`

Layout (`lj_frame.h:35-46, 90-91`), frame base `b = f+1`:

| slot | contents | accessor |
|---|---|---|
| `b-5` = `f-4` | **aux**, meaning depends on the continuation | — |
| `b-4` = `f-3` | continuation, raw ASM address (u64) | `frame_contv(f)` |
| `b-3` = `f-2` | contpc, a `BCIns*` | `frame_contpc(f)` |
| `b-2` = `f-1` | func | `frame_func(f)` |
| `b-1` = `f-0` | `ftsz = delta \| FRAME_CONT` | `frame_ftsz(f)` |

`cont_dispatch` (`vm_x64.dasc:690-711`) reads `[RB-24]` (contpc), `[RB-32]` (cont) and ends in **`jmp RA`** — a computed jump to whatever u64 the blob put in `f-3`. **This is the single most dangerous word in the whole M3 format.**

### Symbol table

`lj_vm.h:108-114` is the complete, closed set. Wire ids must be a fixed enum, never raw addresses:

| id | symbol | handler | aux slot `b-5` |
|---|---|---|---|
| 0 | `lj_cont_cat` | `vm_x64.dasc:721` | not used by the handler (plain caller slot) |
| 1 | `lj_cont_ra` | `:790` | ditto |
| 2 | `lj_cont_nop` | `:868` | ditto |
| 3 | `lj_cont_condt` | `:939` | ditto |
| 4 | `lj_cont_condf` | `:948` | ditto |
| 5 | `lj_cont_hook` | `:2316` | **raw MULTRES int — REFUSE** |
| 6 | `lj_cont_stitch` | `:2376` | saved `GCtrace` ref — must be neutralised |

Plus the two integer specials at `lj_frame.h:87`: `LJ_CONT_TAILCALL == 0` and `LJ_CONT_FFI_CALLBACK == 1`. Both are FFI-only on this build — `LJ_CONT_TAILCALL` is written solely by `lj_meta_tailcall` (`lj_meta.c:82-107`, inside `#if LJ_HASFFI`) and `LJ_CONT_FFI_CALLBACK` by `lj_ccallback.c:592`. Under the no-FFI constraint, **refuse both**. Note `lj_meta_tailcall` also writes `setframe_gc(top, obj2gco(L), LJ_TTHREAD)` — a *dummy* frame whose func slot holds the thread, not a function (the shape `lj_debug.c:29` skips). Refusing them keeps "every func slot holds a function" as an unconditional rule.

On x64 `lj_ptr_sign(ptr, ctx)` is the identity (`lj_obj.h:1105`), so these are plain code addresses; `contptr`/`setcont` for FR2 are `(void*)(f)` / `(o)->u64 = (uint64_t)(uintptr_t)f` (`lj_obj.h:897-898`). ASLR means the addresses differ per process, which is precisely why they must be symbolised.

### What `contpc` is, and whose proto it belongs to

It is a `BCIns*` — a second, independent (proto, bcpos) pair — and its owner is **`frame_func(frame_prevd(f))`**, i.e. the *running* Lua function, which for a CONT frame is always the frame immediately below. Two independent derivations:

* metamethod dispatch, e.g. `vmeta_tgetv` (`vm_x64.dasc:~1090-1110`): `mov RA, L:RB->top; mov [RA-24], PC` writes the *current* PC (already advanced past the triggering instruction), and `lea PC,[RA+FRAME_CONT]; sub PC,BASE` makes `frame_sized` exactly `newbase - BASE`, so `frame_prevd` lands on the running function's frame word.
* `recff_stitch` (`lj_ffrecord.c:110-140`): `pc = frame_pc(base-1)`, `pframe = frame_prevl(base-1)`, `setframe_ftsz(nframe, (char*)nframe - (char*)pframe + FRAME_CONT)`, `setframe_pc(base, pc)` — same identity.

Unlike a `FRAME_LUA` return PC, `contpc` may follow **any** metamethod-triggering opcode (`TGETS`, `TSETS`, `CAT`, `ISLT`, arithmetic …), so the call-op whitelist must **not** be applied to it. Only `1 <= cbcofs < pt->sizebc` applies.

### Encode / decode

```c
/* encode */
uint64_t cv = frame_contv(f);
if (cv == LJ_CONT_TAILCALL || cv == LJ_CONT_FFI_CALLBACK) ERR("FFI continuation");
int cs = cont_symbol_of(cv);                    /* linear scan of the 7 addrs */
if (cs < 0)          ERR("unknown continuation");
if (cs == CS_HOOK)   ERR("lj_cont_hook frame");
GCproto *pt = funcproto(funcV(frame_prevd(f) - 1));   /* checked isluafunc */
rec.kind = FRAME_CONT;
rec.link   = (uint64_t)frame_sized(f);
rec.cs     = (uint8_t)cs;
rec.cbcofs = (uint32_t)(frame_contpc(f) - proto_bc(pt));

/* decode, after the slot pass has populated func slots */
TValue *prev = (TValue *)((char *)f - rec.link);
if (rec.cs >= CS_MAX || rec.cs == CS_HOOK)   ERR(...);
if (!tvisfunc(prev-1) || !isluafunc(funcV(prev-1))) ERR(...);
GCproto *pt = funcproto(funcV(prev-1));
if (rec.cbcofs < 1 || rec.cbcofs >= pt->sizebc)     ERR(...);
(f - 3)->u64 = cont_addr[rec.cs];                   /* [base-4] */
setframe_pc(f - 2, proto_bc(pt) + rec.cbcofs);      /* [base-3] */
setframe_ftsz(f, (int64_t)(rec.link | FRAME_CONT)); /* [base-1] */
if (rec.cs == CS_STITCH)
  (f - 4)->u64 = 0;                                 /* [base-5]; see below   */
```

### `cont_stitch`: the aux slot — **write `+0.0`, i.e. raw `u64 == 0`. Do NOT write a zero-payload trace ref.**

`vm_x64.dasc:2380-2404`:

```
mov  TRACE:ITYPE, [RB-40]     ; RB = frame base -> framebase-5
cleartp TRACE:ITYPE           ; macro at :259 = shl 17 / shr 17  (keep low 47)
...
test TRACE:ITYPE, TRACE:ITYPE
jz   ->cont_nop               ; :2404
```

so the requirement is **`(u64 << 17) >> 17 == 0`**. `nil` fails it: `cleartp(0xffffffffffffffff) = 0x7fffffffffff ≠ 0`, and the VM would then execute `movzx RBd, word TRACE:ITYPE->traceno` on `0x7fffffffffff` — confirming the ARM's premise. (Note `recff_stitch` does `setnilV(base-1-LJ_FR2)` at `lj_ffrecord.c:139` with the comment "Incorrect, but rec_check_slots() won't run anymore" — that nil is transient and undone at `:147`; it never reaches a resumable state.)

Two values satisfy the test. **Only one is GC-safe.** `m3trace` measures it:

```
A: trace|NULL   raw=0xfffb000000000000  itype=0xfffffff6  cleartp=0  tvisgcv=1  gcval=0x0
B: +0.0         raw=0x0000000000000000  itype=0x00000000  cleartp=0  tvisgcv=0  tvisnum=1
   nil          raw=0xffffffffffffffff  itype=0xffffffff  cleartp=0x7fffffffffff
```

`LJ_TTRACE` is `~9u`, and `tvisgcv` (`lj_obj.h:812`) is **true** for it. `gc_traverse_thread` (`lj_gc.c:309-313`) calls `gc_marktv` on every slot in `[stack+1+LJ_FR2, top)`; `gc_marktv` (`lj_gc.c:45-48`) is `if (tviswhite(tv)) gc_mark(g, gcV(tv))` and `tviswhite(x) = tvisgcv(x) && iswhite(gcV(x))` (`lj_gc.h:35`), with `iswhite(x) = (x)->gch.marked & LJ_GC_WHITES` (`lj_gc.h:32`) — a **NULL dereference**. Measured, both in a table array slot and in a plain local slot of a suspended coroutine:

```
tab B -> exit 0      co B -> exit 0
tab A -> exit 139    co A -> exit 139     (SIGSEGV inside lua_gc(LUA_GCCOLLECT))
```

`+0.0` is a plain double: `tvisgcv == 0`, the GC ignores it, and `cleartp == 0` sends `cont_stitch` straight to `cont_nop`. **Proven by the round trip**: the stitch scenario in `m3frames` writes `(f-4)->u64 = 0`, survives a full `lua_gc(LUA_GCCOLLECT)` and resumes to `st=1 [80601]`, identical to the original.

```c
/* the only correct value for the cont_stitch aux slot */
(f - 4)->u64 = 0;   /* +0.0: cleartp()==0 (-> cont_nop) and NOT a GC value */
```

### Refusing `lj_cont_hook` — and how to detect it

`lua_yield` from inside an active hook (`lj_api.c:1204-1216`) builds:

```c
(top++)->u64 = cframe_multres(cf);          /* framebase-5: a RAW MULTRES int  */
setcont(top, lj_cont_hook);                 /* framebase-4                     */
setframe_pc(top, cframe_pc(cf)-1);          /* framebase-3                     */
setframe_gc(top, obj2gco(L), LJ_TTHREAD);   /* framebase-2: DUMMY, not a func! */
setframe_ftsz(top, ... + FRAME_CONT);       /* framebase-1                     */
```

Two independent reasons to refuse: the aux slot is a raw C-frame `MULTRES` count with no cross-process meaning (`cont_hook` reloads it verbatim, `vm_x64.dasc:2319`), and the func slot holds the **thread**, so the frame violates the "func slot is a function" invariant every other check depends on.

Detection is a plain equality on the cont word — do it in *both* directions:

```c
/* persist side */
if (frame_iscont(f) && frame_contv(f) == (uint64_t)(uintptr_t)(void *)lj_cont_hook)
  luaL_error(L, "eris-lj: cannot persist a coroutine suspended from a debug "
                "hook (lj_cont_hook frame)");
/* restore side */
if (rec.cs == CS_HOOK) ERR("lj_cont_hook continuation refused");
```

This matters concretely for OC: the CHECKHOOK watchdog installs a debug hook. **The watchdog hook must never call `coroutine.yield`** — if it does, every coroutine suspended that way becomes unpersistable.

---

## 3. Ordering — and the three-pass restore

**Emit top-down (walk order). Do not store frame positions at all; derive them.**

Rationale:

* The topmost frame word is the only position known a priori: it is exactly `base-1`, and `lua_resume` proves it — resume-after-yield does `mov PC, [BASE-8]` (`vm_x64.dasc:597`) and dispatches on that word alone. Every other position follows from a link.
* Storing per-frame stack indices (what Eris does — `eris_savestackidx(thread, ci->func)`, `eris_master.c:1728-1735`) means the restorer must *trust and validate* N attacker-supplied indices. LuaJIT's frame links make that unnecessary: derive each position from the previous frame's link and the chain is self-consistent by construction. The only remaining structural obligation is that it **terminates exactly at `stack + LJ_FR2`**, which is a single equality at the end.
* Proto availability is *not* the ordering constraint people expect: a frame's caller proto lives in a **stack slot**, and all slots are restored before any frame word is written (same as Eris, `eris_master.c:1858-1872` before `:1901`). So both orders would work for protos. The decision is driven purely by validation.

The wrinkle: for `FRAME_LUA` the link is *derived from the PC* (`frame_prevl` reads `bc_a(pc[-1])`), and the PC needs the caller's proto, which needs the position. Break the cycle by storing `link` for every frame kind uniformly and re-deriving it afterwards:

**Wire record (uniform, ~3-6 bytes):**

```
u8    kind        /* == frame_typep value: 0 LUA, 1 C, 2 CONT, 3 VARG,
                                           5 CP, 6 PCALL, 7 PCALLH        */
uleb  link        /* bytes down to the next-outer frame word              */
kind==LUA  : uleb bcofs
kind==CONT : u8 contsym, uleb cbcofs
```

For delta frames `link` *is* the ftsz payload (`frame_sized`, `lj_frame.h:85`). For Lua frames it is only used to locate the caller and is then re-derived and checked.

**Restore, three passes:**

```
pass 0  lua_newthread; lj_state_cpgrowstack(co, need - current_maxstack)
        (protected: cframe==NULL on a coroutine would panic an unprotected grow)

pass 1  read the frame records; walk f = base_ofs-1 downwards using `link` ONLY.
        No protos needed. Validate everything in §4 that is structural.
        Record pos[i]; mark isframeword[] for f, and for CONT also f-2, f-3,
        and f-4 when contsym == stitch.

pass 2  read the stack values for every slot in [1+LJ_FR2, top_ofs) whose
        isframeword[] bit is clear, ascending, keeping
            co->top = stack + i + 1
        after each write.  (Mandatory: gc_traverse_thread nils every slot at
        or above top during GCSatomic, lj_gc.c:314-317.)
        Leave co->base at stack+1+LJ_FR2 throughout, so gc_traverse_frames
        (lj_gc.c:292-306) sees an empty chain and cannot walk a half-built one.
        Then re-open upvalues and back-patch referrers.

pass 3  walk pos[] again and write the frame words, resolving protos out of
        the now-populated func slots; re-derive and check every FRAME_LUA link.

finally co->base   = stack + base_ofs;
        co->top    = stack + top_ofs;
        co->status = LUA_YIELD;
        co->cframe = NULL;
        setgcrefr(co->env, <restored env>);   /* NOBARRIER: lua_State */
```

Any failure before the final block leaves an inert, perfectly usable thread (`status == LUA_OK`, `base == top == stack+1+LJ_FR2`, frame words still nil) — exactly the "catchable error leaving a usable state" the constraints demand. `probe3.c` already showed a half-built thread that Lua code resumes fails safely.

---

## 4. The validation checklist

Every item is `luaL_error` (catchable) on failure. Grouped by pass so each check runs at the earliest point it can.

### Thread header

| # | check | why |
|---|---|---|
| T1 | `status ∈ {LUA_OK, LUA_YIELD}` | `lua_resume` gates on `status <= LUA_YIELD` (`lj_api.c:1231`). A blob claiming 3 or 200 makes `coroutine.status` and the resume gate disagree. Dead-with-error threads (`status==2`, `coclone2` §C) carry no frames — persist them as `LUA_OK`/no-frames or refuse. |
| T2 | `stacksize` request ≤ `LUAI_MAXSTACK` (65500, `luaconf.h:91`) | `lj_state_growstack` raises a stack-overflow error above it (`lj_state.c:120-152`); on a coroutine that must be routed through `lj_state_cpgrowstack` (`lj_state.c:167`). `coclone2` §D: `LUA_ERRRUN`, `cframe` left NULL, clean. Check the number *before* asking for it, so the error is yours not the VM's. |
| T3 | `1+LJ_FR2 <= base_ofs <= top_ofs <= stacksize - 1 - LJ_STACK_EXTRA` | `LJ_STACK_EXTRA = 5+3*LJ_FR2 = 8` (`lj_def.h:72`); `maxstack = stack + (stacksize-1-EXTRA)` (`lj_state.c:68,77`). `top > maxstack` means every metamethod's 5-slot headroom writes past the allocation. `base > top` makes `lua_resume`'s `RD = (top - RA)>>3 + 1` (`vm_x64.dasc:592-595`) a huge result count. |
| T4 | `status == LUA_YIELD` ⇒ at least one frame; `status == LUA_OK` ⇒ **zero** frames and `base_ofs == 1+LJ_FR2` | measured shapes (`coclone2` §C): never-started and dead-normal are both `status=0, base_ofs=2`. A `LUA_OK` thread with frames would have `lua_resume` take the "initial resume (like a call)" branch (`vm_x64.dasc:589`) over an existing chain. |
| T5 | `cframe` is forced to `NULL`, never read from the blob | it is a host stack address; anything else is a wild `cframe_prev` walk during unwinding. |

### Frame chain — pass 1 (structural, no protos)

| # | check | why |
|---|---|---|
| F1 | first frame word is at exactly `base_ofs - 1` | that is the only word `lua_resume` reads to decide how to re-enter (`vm_x64.dasc:597-601`). Not stored, so not forgeable. |
| F2 | `link % 8 == 0` | the low 3 bits are the frame type. A link with bits set silently rewrites `kind`, turning e.g. a `VARG` frame into a `PCALLH` one. |
| F3 | `link >= 16` (2 slots) | the minimum FR2 frame is `[func][ftsz]`. A smaller link makes the "previous frame" overlap this one; the walk stops descending and the guard below never fires. |
| F4 | `link <= (f - (stack+LJ_FR2)) * 8` and the derived `prev > stack+LJ_FR2` for every non-final frame | keeps the chain inside the stack. Without it, `frame_prevd` produces a pointer below the allocation and `frame_func(prev)` reads freed heap. |
| F5 | chain is **strictly descending** — implied by F3+F4 but assert it | a non-descending link is an infinite loop in `gc_traverse_frames` (`lj_gc.c:296`), `lj_debug_frame` (`lj_debug.c:29-46`) and `lj_err`'s unwind loops (`lj_err.c:120-190`). |
| F6 | the chain **terminates exactly at `stack + LJ_FR2`**, not merely at-or-below | every VM walker uses `frame > bot` with `bot = tvref(stack)+LJ_FR2`. Undershoot = the bottom frame is never seen; overshoot = the loop reads slot 0/1. |
| F7 | `f < top_ofs` for every frame word | frame words above `top` are nil'd by `gc_traverse_thread` during `GCSatomic` (`lj_gc.c:314-317`) — the chain would silently become `ftsz == -1`. |
| F8 | **only the last record may be `FRAME_C`/`FRAME_CP`; every other kind is forbidden there** | framewalk H3: no interior C frame is reachable on a suspended thread, because a live C frame means `cframe != NULL` and yields error out. An interior `FRAME_C` makes `lj_err`'s unwinder pop a `cframe` that does not exist (`lj_err.c:141-149`). Conversely a non-C bottom frame means the chain never hands control back to `lj_vm_resume`. |
| F9 | `kind` is one of `{0,1,2,3,5,6,7}` | 4 (`FRAME_LUAP`) is not a real delta type; it exists only as an artifact of `frame_typep` on a Lua PC. |
| F10 | `FRAME_CONT`: `f-3 > stack+LJ_FR2`; if `contsym == stitch`, `f-4 > stack+LJ_FR2` | `cont_dispatch` unconditionally reads `[RB-24]`/`[RB-32]` and `cont_stitch` reads `[RB-40]`. A CONT frame too close to the bottom makes those reads leave the stack. |
| F11 | `contsym < 7` **and** `contsym != CS_HOOK` **and** the integer specials 0/1 are not representable in the symbol space | `cont_dispatch` ends in `jmp RA` with the raw word (`vm_x64.dasc:711`). This one check is the difference between a corrupt coroutine and arbitrary code execution. Keep the wire form a small enum with no escape hatch — never a raw address, never an index into a runtime-built table. |

### Frame chain — pass 3 (needs the restored slots)

| # | check | why |
|---|---|---|
| F12 | for **every** frame, `tvisfunc(f-1)` | `gc_traverse_frames` does `frame_func(frame)` then `isluafunc(fn)` then `funcproto(fn)->framesize` on every frame of every marked thread (`lj_gc.c:296-299`) — a non-function slot is a wild read on the next GC, before any resume. `BC_RET_Z` and `cont_dispatch` also reload `KBASE` from `[BASE-16]`. This is also what rejects the `LJ_TTHREAD` dummy frames from `lj_meta_tailcall`/`lua_yield`-from-hook. |
| F13 | `FRAME_LUA`/`FRAME_CONT`: `tvisfunc(prev-1) && isluafunc(funcV(prev-1))` | the proto source. A C function there means `funcproto()` reads `fn->l.pc` out of a `GCfuncC`. |
| F14 | `1 <= bcofs < pt->sizebc` (and same for `cbcofs`) | §1. |
| F15 | `FRAME_LUA`: `frame_prevl(f) == prev` after the PC is written | §1 — the check that makes a wrong-but-in-range PC non-exploitable. |
| F16 | `FRAME_LUA`: `bc_op(pc[-1]) ∈ {CALL, CALLM, ITERC, ITERN}` | §1 — catches the residue F15 misses (measured: 2 of the first 3 mutations). Do **not** apply to `cbcofs`. |
| F17 | `FRAME_VARG`: `funcproto(funcV(f-1))->flags & PROTO_VARARG` | `BC_IFUNCV` only ever produces a VARG frame for a vararg proto; the frame below must also be that same function's `FRAME_LUA`. A forged VARG frame over a fixarg function desynchronises `BC_RET`'s `7: // Tailcall from a vararg function` path (`vm_x64.dasc:4278-4288`). |
| F18 | reject `FRAME_PCALLH` unless a hook is actually active | `PCALLH` makes `vm_returnp` take the hooked path; with no hook state to match it, the restored thread returns into a hook that was never entered. |

### Open upvalues

| # | check | why |
|---|---|---|
| U1 | every `uv->v` slot is in `[1+LJ_FR2, top_ofs)` | `resizestack` relocates `uvval(uv) + delta` for every entry (`lj_state.c:85-86`) — an out-of-stack `uv->v` becomes a wild pointer the first time the stack moves, and `lj_gc_closeuv` then `copyTV`s from it. Slots at or above `top` get nil'd in `GCSatomic` (`lj_gc.c:316`). |
| U2 | the per-thread list is **strictly descending by slot** | `func_finduv` inserts assuming it (`lj_func.c:37-69`) and `lj_func_closeuv` stops at the first entry below `level` (`lj_func.c:83-99`) — an unsorted list leaves upvalues open over a dead frame. Build the list with `elj_finduv` (which enforces the order) rather than trusting the blob's order, and reject duplicate slots. |
| U3 | `uv->closed == 0`, `uv->v != &uv->tv` | asserted by `lj_func_closeuv`; a "closed" entry on the open list is freed twice. |
| U4 | every closure that shared an upvalue before still shares the *same* `GCupval` after | identity, not just value — this is the M2 contract extended onto the stack. `coclone`'s back-patch loop is the mechanism; M3 must drive it from the deserializer's referrer list, not by scanning the stack (a sharer may live inside a table). |

### Also worth stating

* The `top` slot rule during pass 2 (`co->top = stack + i + 1` after each write) is a **correctness** requirement, not hygiene: `gc_traverse_thread` nils everything from `top` up during `GCSatomic`.
* Keep `co->base` at `stack+1+LJ_FR2` until the very end so `gc_traverse_frames` never walks a partially written chain.
* The host stopping the GC covers most of this, but writing the code to be GC-safe at every allocation point costs nothing and removes a whole class of "someone forgot the guard" bugs.
* `jit.flush()` before persist is still required — it is what removes live `GCtrace` objects, so the only trace reference that can appear is the `cont_stitch` aux, which we neutralise.

---

## 5. The probe — full symbolic round trip, in one process

`...\scratchpad\m3\m3frames.c`. Structure: `src` = a coroutine from an in-process chunk; `twin` = the identical chunk pushed through `lua_dump` → `lua_load` → resumed to the same point, so every `GCproto` is a different object; `nc` = a fresh thread whose **values** come from `twin` and whose **frame words** come from `src`'s symbolic encoding, decoded against `twin`'s protos. Not one frame word is copied. The probe asserts `src` and `twin` produce *identical symbolic encodings* while their raw `FRAME_LUA` ftsz words differ, then runs a full `lua_gc(LUA_GCCOLLECT)` over the restored thread before resuming it.

```
m3frames: symbolic cross-process frame codec (GC64=1 FR2=1)

===== vararg + pcall + open upvalues =====
  src  stacksize=105 base_ofs=23 top_ofs=23 frames=6
   [0] slot= 22 LUA    link=16  bcofs=10  rawftsz=...ae92bb8 / twin ...ae9cb68
   [1] slot= 20 VARG   link=40             rawftsz=0x2b      / twin 0x2b
   [2] slot= 15 LUA    link=16  bcofs=6    rawftsz=...ae9bea8 / twin ...ae9d578
   [3] slot= 13 PCALL  link=16             rawftsz=0x16      / twin 0x16
   [4] slot= 11 LUA    link=64  bcofs=9    rawftsz=...ae9bfa4 / twin ...ae9d62c
   [5] slot=  3 CP     link=16             rawftsz=0x15      / twin 0x15
  4 frame func slots hold Lua closures with FRESH protos
  reopened 6 upvalue(s) at slots 9 8 7 6 5 4
  original : st=0 [10,15]
  restored : st=0 [10,15]
  negative: 30/30 in-range-but-wrong FRAME_LUA offsets rejected
  ...
===== JIT stitch frame (cont_stitch) =====
   [0] slot= 13 CONT   link=80  cont=stitch cbcofs=11
   [1] slot=  3 CP     link=16
  original : st=1 [80601]
  restored : st=1 [80601]

RESULT: OK (0 failures)
```

All eight scenarios pass: `vararg+pcall`, `cont_ra`, `cont_cat`, `cont_nop`, `cont_condf`, `ITERC`, `xpcall`/`FRAME_PCALL`, `cont_stitch`. Totals across the run: **103/103** wrong-but-in-range `FRAME_LUA` offsets rejected; short-bottom-link rejected in all 8; out-of-range cont symbol rejected in all 5 CONT scenarios.

### Shapes that cannot work, and are refused rather than mishandled

1. **`lj_cont_hook` frames** (a coroutine that yielded from inside a debug hook, `lj_api.c:1204-1216`). The aux slot is a raw `MULTRES` count and the func slot is the thread itself. No symbolic form exists. Refuse on both sides.
2. **`LJ_CONT_TAILCALL` / `LJ_CONT_FFI_CALLBACK` frames** — FFI-only, and `LJ_CONT_TAILCALL` also carries a dummy `LJ_TTHREAD` func slot. Out of scope by constraint; refuse explicitly rather than letting the symbol lookup fail with a vague message.
3. **Interior `FRAME_C`/`FRAME_CP`** — cannot occur on a suspended thread, and cannot be reconstructed if forged (there is no host C frame to return into).
4. **A live `GCtrace` reference in the stitch aux** — not reconstructable across processes; degraded to `+0.0`, which the VM itself treats as "no previous trace" (`vm_x64.dasc:2403-2404`). This is a semantic downgrade, not a fidelity loss: the restored coroutine re-enters the interpreter and re-JITs.

### One thing the probe does *not* cover

The upvalue referrer back-patch is done by scanning the restored thread's own slots (as `coclone` did). That is sufficient for these scenarios but not for the real serializer, where a sharer can live anywhere in the object graph. M3 must drive the back-patch from the deserializer's own referrer list (checklist U4), which is a bookkeeping extension of the M2 upvalue-id machinery, not a new mechanism.

# KEY CLAIMS
- [high] A genuine cross-process symbolic frame round trip works: 8 frame shapes (vararg+tailcall+pcall, cont_ra/cat/nop/condf, ITERC, FRAME_PCALL, cont_stitch) encode to (link, bcofs) / (link, contsym, cbcofs) / (link, type), decode against protos that came from lua_dump+lua_load (different objects), and resume to identical results with zero frame words copied raw.
- [high] The cont_stitch aux slot at framebase-5 must be written as raw u64 == 0 (+0.0), NOT as a zero-payload LJ_TTRACE ref: LJ_TTRACE satisfies tvisgcv(), so gc_marktv -> tviswhite -> iswhite(NULL) segfaults on the next GC. Measured: candidate A exits 139 (SIGSEGV) in both a table slot and a coroutine stack slot; candidate B survives a full GC and resumes correctly.
- [high] For every FRAME_LUA, the proto owning the return PC is uniformly funcproto(frame_func(frame_prevl(f))) — including when frame_prevl lands on a FRAME_VARG frame (BC_IFUNCV copies the LFUNC up, vm_x64.dasc:4845-4870, so its func slot IS the proto containing the CALL), on a CONT/PCALL frame, or on the bottom FRAME_CP frame (whose func slot is the coroutine entry function at stack slot 2).
- [high] An in-range-but-wrong FRAME_LUA bcofs is memory-unsafe (BC_RET_Z computes base = base-(bc_a+2)*8 then dereferences [base-16] as an LFUNC, vm_x64.dasc:4490-4520), and the pair of checks 'frame_prevl(f)==prev' plus 'bc_op(pc[-1]) in {CALL,CALLM,ITERC,ITERN}' rejects it. Exhaustive sweep: 103/103 wrong offsets rejected; frame_prevl alone missed 2 of the first 3.
- [high] Frames should be emitted top-down with NO stored stack positions: only a per-frame link (bytes to the next-outer frame word), with positions derived at restore and the chain required to terminate exactly at stack+LJ_FR2. Restore is three passes: derive+validate positions from links alone, then read slot values (keeping co->top above every write and co->base at the bottom), then write frame words and re-derive every FRAME_LUA link.
