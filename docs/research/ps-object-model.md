# LuaJIT (GC64, pinned 1ee778a4) heap object model — full serialization map

Build facts that shape the wire format (all from source):

- `LJ_GC64=1` on x64/arm64 (`lj_arch.h:597-601`), which forces `LJ_FR2=1` (`lj_arch.h:604-608`). TValues are 8 bytes; GC references are 47-bit pointers with a 4-bit itype in bits 47..50 under a NaN-boxed layout (`lj_obj.h:242-259`, `lj_obj.h:291`).
- **DUALNUM differs across the two pinned targets**: x64 is `LJ_NUMMODE_SINGLE_DUAL` (dual OFF unless `LUAJIT_NUMMODE=2`, `lj_arch.h:200,580-586`); arm64 is `LJ_NUMMODE_DUAL` (dual ON, `lj_arch.h:305`). A DUALNUM VM materializes int-tagged TValues (`LJ_TISNUM`); a non-dual VM has only doubles. The wire format must encode numbers canonically (int-vs-double flag, restore via `setint64V`/`setnumV`, `lj_obj.h:953-968`) if the same save should ever load on the other arch; within one build it is a non-issue per the stated constraint.
- Security defaults (`lj_arch.h:748-761`): `STRHASH=1`, `STRID=1`, `PRNG=1`. So the string hash seed (`g->str.seed`, `lj_str.c:367`) and string IDs (`sid`, reseeded from PRNG, `lj_str.c:285-296`) are **process-random**. Anything derived from them is not portable across a save/load.

## TValue tags (`lj_obj.h:260-274`)

| itype | wire handling |
|---|---|
| `LJ_TNIL/TFALSE/TTRUE` | 1-byte tag; restore `setnilV`/`setboolV` (`lj_obj.h:875-877`) |
| `LJ_TLIGHTUD` | segmented 8+39-bit encoding (`lj_obj.h:295-298`, decode `lightudV` `lj_obj.h:848-857`, intern `lj_lightud_intern` `lj_udata.c:37-61`). The raw pointer is host memory — **perms-only** (OC uses lightud only for its persistKey sentinel). Never serialize the bit pattern; the segment map (`g->gc.lightudseg`) is per-process. |
| `LJ_TSTR` | ref to GCstr |
| `LJ_TUPVAL` | never appears in a user-visible TValue slot; GCupval reached only from GCfuncL/uvhead/openupval lists |
| `LJ_TTHREAD` | ref to lua_State |
| `LJ_TPROTO` | ref to GCproto (appears on stacks only transiently during load; treat as internal) |
| `LJ_TFUNC` | ref to GCfunc |
| `LJ_TTRACE` | JIT only; excluded by jit.flush precondition |
| `LJ_TCDATA` | detect via itype / `gct == ~LJ_TCDATA` and **fail persist** (no FFI in sandbox); note BC_KCDATA proto constants flagged by `PROTO_FFI` (`lj_obj.h:401`) |
| `LJ_TTAB` | ref to GCtab |
| `LJ_TUDATA` | ref to GCudata (perms/special-persist) |
| numbers | double bit pattern, or int when DUALNUM (`tvisint` `lj_obj.h:806`); `LJ_KEYINDEX` (0xfffe7fff, `lj_obj.h:288`) is a lightud-tagged iterator-state marker that can live in a suspended `next()` loop's stack slot — must round-trip bit-exactly (frames arm) |

## Per-type map

### GCstr (`lj_obj.h:306-313`)
- **Serialize:** `len` + bytes only.
- **Do NOT serialize:** `sid` (random, reseeded — `lj_str.c:285-296`), `hash`/`hashalg` (keyed by random `g->str.seed`, dense rehash migrates strings between algorithms at runtime — `lj_str.c:177-197,248-251`), `reserved` (lexer keyword index, set once by `lj_lex_init` `lj_lex.c:538-547`), GC bits.
- **Restore:** always through `lj_str_new` (`lj_str.c:314-356`). Interning dedupes against strings already created by fresh-state init (keywords keep their `reserved` and `LJ_GC_FIXED` marks; error messages are `fixstring`ed at `lj_state.c:202-203`). This preserves every interning invariant (chain membership, sid allocation, 100%-load-factor resize `lj_str.c:308-309`) for free.
- **Hazard:** because `hashstr` for table lookup uses `sid` (`lj_tab.h:42`), *no structure keyed by string identity survives a reload* — see GCtab.

### GCtab (`lj_obj.h:499-512`)
- **Serialize:** `asize`, `hmask` (as size hints), all non-nil array slots `[0..asize-1]`, all non-nil hash pairs (walk `node[0..hmask]`, skip `tvisnil(&n->val)`; dead keys with nil values are deliberately retained garbage — `lj_obj.h:132-141` — and must be skipped), `metatable` ref. `nomm` is a negative metamethod cache invalidated on any `lj_tab_set` (`lj_tab.c:539`) — restore as recomputed (fresh table starts `~0`, first stores clear it).
- **Do NOT serialize:** `colo` (colocation is an allocation detail; `newtab` decides by size `lj_tab.c:85-101`, resize separates `lj_tab.c:241-247`), `freetop`, node layout/chains, `gclist`.
- **Restore:** `lj_tab_new(L, asize, hbits)` with the recorded geometry (`hbits = hmask>0 ? lj_fls(hmask)+1 : 0`, same formula as `lj_tab_dup` `lj_tab.c:168`), then blit-free re-insertion: array slots direct, hash pairs via `lj_tab_set` (`lj_tab.c:536-561`). Pre-sizing guarantees no rehash during refill (#entries ≤ hmask+1; `rehashtab` only fires when the free-node pool is exhausted, `lj_tab.c:444-449`). `lj_tab_dup`'s memcpy trick (`lj_tab.c:164-202`) is NOT usable across processes — node positions are `sid`/seed-dependent.
- **Weakness:** there is no persistent weak flag on the table. `LJ_GC_WEAKKEY/WEAKVAL` marked-bits are re-derived from the metatable's `__mode` string every GC cycle (`lj_gc.c:174-201`). Serializing metatable ref restores weakness automatically. Hazard: like Eris, entries whose keys/values were awaiting collection at persist time get resurrected; run `lj_gc_fullgc` before persisting to minimize this.
- **Iteration order** changes across reload (string hash positions differ). PUC-Eris has the same property; OC tolerates it.

### GCfunc — FuncL (`lj_obj.h:465-468,455-457`)
- **Serialize:** proto ref, `nupvalues`, per-slot refs to the GCupval **objects** (`uvptr[]` holds pointers to GCupval, not values — sharing is object identity, `lj_obj.h:467`), `env` ref (per-closure environment, `lj_obj.h:457`; `setfenv` can change it).
- **Derived, don't serialize:** `pc` = `proto_bc(pt)` (`lj_func.c:131`); `ffid=FF_LUA`; `gclist`.
- **Restore:** create via `lj_func_newL_empty(L, pt, env)` (`lj_func.c:140-154`) then overwrite each `uvptr[i]` with the restored shared GCupval (this is exactly what `lua_upvaluejoin` does, `lj_api.c:917-928`, including the needed `lj_gc_objbarrier`), or hand-construct with `func_newL` semantics. Note `lj_func_newL_empty` allocates fresh closed-nil upvalues that get dropped — a dedicated constructor in the patched build avoids the garbage.
- Side effect to accept: `PROTO_CLCOUNT` saturating closure counter bumps on creation (`lj_func.c:133-135`) — JIT heuristic only.

### GCfunc — FuncC (`lj_obj.h:459-463`)
- Fields: `f` (raw C pointer), `ffid` (`FF_C=1` for API closures, `>1` for built-in fast functions, `lj_obj.h:475-479`), inline `TValue upvalue[nupvalues]` (values, not objects — no sharing semantics, confirmed by `lua_upvalueid` returning `&fn->c.upvalue[n]` `lj_api.c:913-914`), `env`, `pc` → `&g->bc_cfunc_ext/int` or a `bcff` slot in GG_State (`lj_func.c:118`, `lj_lib.c:104-107`, `lj_dispatch.h:109`).
- **Perms-only**, as stipulated. Two sub-cases:
  - Built-ins (`ffid > FF_C`): the (library, name) pair or ffid itself is a stable perms key within the pinned build — `lj_lib_register` assigns ffids deterministically from generated tables (`lj_lib.c:80,101`). Their upvalues (e.g. math.random's PRNG userdata, `lib_math.c:131-135`) are re-created by fresh `luaopen_*`; the serializer should *re-associate* rather than re-create (see PRNG below).
  - API closures made by the host (`lua_pushcclosure`, `lj_api.c:678-691`): perms table keyed by identity, upvalue TValues may be serialized and re-pushed if the perms protocol wants (Eris does this via its special-persistence; simplest is whole-closure perms as OC does).
  - Stateful C closures not in perms (gmatch iterators): persist failure, per the accepted OC fallback.

### GCupval (`lj_obj.h:433-446`)
- Fields: `closed`, `immutable`, union { closed: `tv` value | open: `prev/next` GCRefs into the **global uvhead ring** }, `v` (points at thread stack slot when open, at own `tv` when closed), `dhash`.
- **Identity is the whole point:** closures sharing a variable share one GCupval; capture that by serializing GCupval as a first-class ref-tracked object (persist-side key: the GCupval address, i.e. `lua_upvalueid`).
- **Open upvalue plumbing (all must be reconstructed, never stored):**
  - Per-thread list: `L->openupval`, a singly-linked list through the upvalue's **`nextgc` field**, sorted by stack slot, highest slot first (`func_finduv` insert walk, `lj_func.c:44-61`). While open, `nextgc` is *not* a GC-root-list link — open upvalues are not on `g->gc.root` at all.
  - Global list: doubly-linked ring through `prev`/`next` anchored at `g->uvhead` (`lj_func.c:62-65`, anchor init `lj_state.c:294-295`); GC marks open upvalue values by walking this ring (`gc_mark_uv`, `lj_gc.c:116-125`).
  - On close (`lj_gc_closeuv`, `lj_gc.c:835-843`): value copied into `tv`, `v` repointed, unlinked from both lists, and **only then** chained onto `g->gc.root` via `nextgc`.
- **Serialize:** `closed` flag, `immutable` flag; if closed: the value; if open: (owning thread ref, stack slot index) — slot index = `uvval(uv) - tvref(th->stack)`.
- **Restore:** closed → `func_emptyuv` equivalent (`lj_func.c:72-80`) + write `tv` + set `immutable`. Open → after the owning thread's stack is materialized, a `func_finduv` equivalent for (thread, slot) — this automatically restores sorted-list order, uvhead ring membership, and sharing among all closures over the same slot (`lj_func.c:37-69`). `func_finduv` is static; the patched build must export it or replicate it.
- `dhash`: address-derived (`(uintptr_t)pt ^ (v<<24)` / parent-pc variant, `lj_func.c:149,175`), consumed only by JIT alias analysis (`lj_record.c:1812`) with the contract "dh1 != dh2 ⇒ cannot alias" (`lj_obj.h:445`). Recompute with the same formula at restore (equal values are merely conservative). Never persist the old value.
- `immutable` must be restored exactly: the JIT constant-folds through immutable upvalues; it is derivable from the proto's uv table bit `PROTO_UV_IMMUTABLE` (`lj_obj.h:414`, `lj_func.c:148,174`), so recomputation is safe.

### GCproto (`lj_obj.h:372-396`) and lj_bcwrite/lj_bcread fidelity
One colocated allocation: header + bytecode + kgc (grows down from `k`) + knum (grows up) + uv table + debug arrays (layout computed in `lj_bcread_proto`, `lj_bcread.c:339-346`).

- **Serialize via `lj_bcwrite` with STRIP off and `BCDUMP_F_DETERMINISTIC` if reproducible saves are wanted** (`lj_bcwrite.c:432-453`, format grammar `lj_bcdump.h:14-29`). What the roundtrip does, verified in source:
  - Bytecode: instruction 0 (`FUNCF/FUNCV` header) is omitted on write (`lj_bcwrite.c:294`) and regenerated from flags/framesize on read (`lj_bcread.c:286-291`) — faithful. Hot-patched `ILOOP/IFORL/IITERL/JFORI/JFORL/JITERL/JLOOP` instructions are un-patched back to the original ops, JLOOP via the trace's saved `startins` (`lj_bcwrite.c:300-315`). Requires traces still alive at dump time — so **dump before `jit.flush`**, or accept that `pt->trace` must be 0/valid; safest order: persist first, flush after (the write consults `traceref(J, rd)->startins`).
  - Flags: only `PROTO_CHILD|PROTO_VARARG|PROTO_FFI|PROTO_BITOP` are written (`lj_bcwrite.c:343`); `PROTO_ILOOP` (correct — bytecode was unpatched), the 3-bit `PROTO_CLCOUNT` closure counter (`lj_obj.h:409-411`), and `pt->trace` (zeroed at read, `lj_bcread.c:361`) are lost — all JIT-warmth state, sanctioned losses under the jit.flush regime.
  - knum: written as 33-bit ULEB128 (int) or lo/hi pair (double) (`lj_bcwrite.c:259-289`), read back bit-exactly (`lj_bcread.c:266-280`); narrowing to int only when `lj_num2int_check` proves exactness and never for `-0` or the `LJ_KEYINDEX` guard (`lj_bcwrite.c:271-274`). **Double constants are bit-exact.**
  - kgc: strings by bytes (re-interned via `lj_str_new` at read, `lj_bcread.c:233-236`), child protos positionally via a stack (`BCDUMP_KGC_CHILD`, `lj_bcread.c:254-261`), template tables re-built by insertion with the nil-value-marker convention preserved (`lj_bcwrite.c:74-75`, `lj_bcread.c:194-195`); template-table internal layout may differ after reload — harmless, they are only cloned by `BC_TDUP`. I64/U64/complex kgc are cdata — FFI-only, absent here.
  - uv table (16-bit entries with `PROTO_UV_LOCAL/IMMUTABLE` bits): copied verbatim (`lj_bcwrite.c:362`, `lj_bcread.c:300-312`).
  - Debug info when not stripped: `firstline`, `numline`, packed lineinfo/uvinfo/varinfo copied verbatim (`lj_bcwrite.c:350-358,370-374`; `lj_bcread.c:376-389`); chunkname preserved in the dump header (`lj_bcwrite.c:390-404`). **STRIP loses**: chunkname (replaced by `=?`), line numbers, local/upvalue names — i.e. tracebacks and `debug.*` introspection. For OC persistence use non-stripped.
- **Proto identity:** `lj_bcread` always allocates fresh protos. Two closures over the same function must resolve to one GCproto after reload → ref-map protos at persist (address key). A child proto is embedded in its parent's dump; address any live proto as (dump-root proto ID, path of kgc indices), where the dump root is its topmost live ancestor. Dumping overlapping subtrees twice would silently duplicate protos.

### GCudata (`lj_obj.h:323-331`)
- Fields: `udtype` (`lj_obj.h:334-340`), `env`, `len`, `metatable`, 8-byte-aligned payload.
- Regular userdata (`UDTYPE_USERDATA`): Eris-style special persistence only — metatable+env refs are serializable, payload meaning is C-side. OC's persistKey/spkey protocol supplies the reconstructor.
- `UDTYPE_IO_FILE`: perms (io.stdout etc. are `GCROOT_IO_INPUT/OUTPUT`, `lj_obj.h:581-582`) or unpersistable.
- `UDTYPE_BUFFER`: payload is an `SBufExt` full of raw pointers (`lj_buf.h:23-33`) — unpersistable by value; the OC sandbox does not expose `string.buffer`, so detection + refusal suffices.
- Note: `lj_udata_new` chains userdata after the main thread on the GC root list so finalizers sweep in order (`lj_udata.c:26-27`); using it at restore preserves the invariant automatically.
- **math.random state lives here:** `luaopen_math` allocates a plain 32-byte userdata holding `PRNGState {uint64_t u[4]}` (`lib_math.c:198-204`, `lj_def.h:390-392`) and stashes it as **upvalue 1 of the `math.random`/`math.randomseed` C closures** (`lib_math.c:131-135,183-186`). It is a Tausworthe generator whose state is pure data → persist = memcpy 32 bytes out, restore = locate the fresh state's math.random upvalue userdata (`lj_lib_upvalue`) and memcpy back. Fully dumpable/restorable. The *global* `g->prng` (`lj_obj.h:663`) seeds the allocator, string seed, and sid reseeds — it must NOT be restored (and does not need to be).

### GCcdata (`lj_obj.h:348-358`)
Out of scope; detect via `gct == ~LJ_TCDATA` / `tviscdata` and fail persist with a typed error. Also refuse protos with `PROTO_FFI` flag defensively.

### lua_State / GCthread (`lj_obj.h:692-706`) — non-stack fields
(stack/frame contents deferred to the frames arm)
- `status`: serialize (LUA_OK for fresh/dead, LUA_YIELD for suspended; the errored/running states should not occur at OC persist points).
- `dummy_ffid`: constant FF_C (`lj_state.c:366`), don't serialize.
- `glref`: rebind to the new global_State.
- `gclist`: GC-transient, rebuild-free.
- `base`, `top`: serialize as *offsets* from `stack` (all intra-stack pointers must be relocated exactly as `resizestack` does, `lj_state.c:63-87`).
- `stack`/`maxstack`/`stacksize`: recreate via `lj_state_new` (`lj_state.c:362-378`) then `lj_state_growstack` to the recorded `stacksize`; note real size = requested + 1 + `LJ_STACK_EXTRA` and slot 0 holds the thread itself with a nil in slot 1 for FR2 (`stack_init`, `lj_state.c:173-185`).
- `openupval`: never serialized as a list — reconstructed implicitly, in order, by the open-upvalue restore procedure (see GCupval).
- `env`: serialize ref (the thread's globals table; child threads inherit at creation, `lj_state.c:374`, but `lua_setfenv` on a thread can change it).
- `cframe`: must be NULL for any persistable coroutine — this is precisely the "not suspended across a C boundary" constraint (c); a non-NULL cframe at persist ⇒ unpersistable, matching Eris's "cannot persist C frame" error class.
- The **main thread** is colocated inside `GG_State` with `global_State` (`lj_dispatch.h:90-110`, `lj_state.c:276-279`) and marked `FIXED|SFIXED`; it is never serialized as an object — the restore maps "old main thread" → new state's main thread via the ref table.

## Global anchors (not GC objects; decide per-anchor)

| anchor | treatment |
|---|---|
| registry (`g->registrytv`, `lj_obj.h:650`, `registry(L)` `lj_obj.h:709`) | an ordinary GCtab created at init (`lj_state.c:198`); holds `luaL_newmetatable` tables etc. Serialize as a root **or** rely on fresh init + perms, per host policy (OC persists selected roots, not the registry) |
| globals (`L->env`) | serialize as a root (OC persists the sandbox globals) |
| `g->gcroot[]` (`lj_obj.h:576-587,664`): MM name strings, base-type metatables, io defaults | reconstructed by fresh `luaopen_*`; hazard: user-visible mutations to base metatables (e.g. via debug lib) would be lost — OC sandbox does not expose those mutators |
| string table (`g->str`, `lj_obj.h:622-632`) | rebuilt implicitly by interning |
| `g->uvhead` (`lj_obj.h:652`) | ring anchor; relinked implicitly by open-upvalue creation |
| `g->tmpbuf` / lexer SBufs (`lj_obj.h:647`, `lj_buf.h:85-91`) | transient scratch, dead between resumes; never serialize. No SBuf is reachable from Lua values except inside `UDTYPE_BUFFER` udata |
| `g->prng` | do not restore (allocator/seed entropy) |
| `cur_L`, `jit_base`, hookmask/hookf, dispatch tables | runtime/host state, reconstructed |

## Restoration order & GC-invariant constraints

1. **Run restore on a freshly initialized state (post-`luaopen_*`), with the GC in `GCSpause`** (fresh state starts there, `lj_state.c:304`; or force `lj_gc_fullgc` + stopped GC). Then every pre-existing object is white or fixed-gray and every restored object is created white — per the barrier rules (`lj_obj.h:92-146`) no store during restore can violate the black→white invariant, so plain `setgcref` stores are legal without barriers. If restore instead runs with GC enabled mid-cycle, every field store needs the appropriate `lj_gc_*barrier`, and any allocation can trigger a GC step that sweeps half-initialized objects — keep GC off until the graph is complete and all placeholder objects are fully populated.
2. **Strings first** — automatic, since every constructor that needs a string (`lj_tab_set` with string key, `bcread_kgc`, chunknames) interns on demand; the only rule is *never* fabricate a GCstr around interning.
3. **Protos before Lua closures** (`funcproto`/`pc` derivation, `lj_obj.h:480-481`, `lj_func.c:131`); child protos arrive with their dump root.
4. **Two-phase for cyclic types**: allocate GCtab (right-sized, empty) and GCfunc (upvalue slots pointing at placeholders) on first encounter, register in the ref map, populate after — same as Eris. GCudata likewise (metatable/env patched after).
5. **Threads before their open upvalues, open upvalues before (or joined into) the closures that capture them**: a thread's stack must exist at its final size before `func_finduv`-style creation, because `v` points into the stack and `resizestack` must be able to relocate it (`lj_state.c:85-86`). Practical order per thread: create thread → grow stack to recorded size → fill stack slots (frames arm) → create open upvalues by (thread, slot) → patch closure `uvptr` entries. Threads therefore restore *late in structure but before closure-upvalue patching* — not strictly "last"; what must be last is closing the loop of `uvptr` patches and any stack slot that references a closure (two-phase handles the cycle).
6. **Persist before `jit.flush`**, since `bcwrite_bytecode` needs live traces to un-patch `JLOOP` (`lj_bcwrite.c:310-313`); after restore, protos come back with `trace=0` and unpatched bytecode, so re-warming is clean.

## Consolidated hazards
- Anything derived from `g->str.seed`, `sid`, or object addresses (string hashes, table node layout, `dhash`, lightud bit patterns) is process-local. Rebuild, never blit.
- Open-upvalue `nextgc` doubles as the thread-list link (`lj_func.c:60-61`) — a naive "chain every restored object onto gc.root" corrupts open upvalues; only closed upvalues belong on gc.root (`lj_gc.c:842-843`).
- DUALNUM divergence x64 vs arm64 makes number TValue encoding build-specific; canonicalize numbers on the wire if arch portability is ever wanted.
- Weak-table entries pending collection get resurrected (mitigate with a full GC pre-persist); iteration order changes across reload.
- `-0` table keys are normalized to `+0` at insert (`lj_tab.c:504-505`) — re-insertion preserves this automatically; a blit-based restore would not.
- Stripped bytecode dumps lose chunkname/lineinfo/varinfo; use non-stripped for OC (tracebacks survive).
- Protos duplicated if overlapping kgc subtrees are dumped independently — canonicalize dump roots.
- `cframe != NULL` or status==running threads: refuse persist (matches constraint (c) and Eris's failure class).

# KEY CLAIMS
- [high] All string- and hash-derived structure is process-random under the build's default security settings (str.seed from PRNG at lj_str.c:367, sid reseeding at lj_str.c:285-296, table string-hash keyed by sid at lj_tab.h:42), so restore must re-intern every string via lj_str_new and rebuild every table hash part by re-insertion into a pre-sized table; no memory image of strings or hash parts can be reused.
- [high] Upvalue identity is reconstructible: open upvalues live in a per-thread list threaded through their nextgc field sorted by descending stack slot (lj_func.c:44-61) plus the global uvhead ring (lj_func.c:62-65, marked via lj_gc.c:116-125), and only move to the gc.root list when closed (lj_gc.c:835-843); restoring an open upvalue as (thread, slot-index) through a func_finduv-equivalent regenerates all list invariants and closure sharing automatically, while closed upvalues are ref-tracked objects restorable via lua_upvaluejoin semantics (lj_api.c:917-928).
- [high] lj_bcwrite/lj_bcread round-trip a GCproto with full semantic fidelity when not stripped: double constants are bit-exact (33-bit ULEB int-narrowing only on proven-exact conversion, lj_bcwrite.c:259-289 / lj_bcread.c:266-280), hot-patched ILOOP/JLOOP bytecode is un-patched using live trace startins (lj_bcwrite.c:300-315), and the only losses are JIT-warmth state (trace anchor, PROTO_ILOOP, closure-count flag bits at lj_bcwrite.c:343) which the jit.flush regime already discards — but the dump must be taken BEFORE jit.flush so JLOOP un-patching can consult traces.
- [high] math.random state is a plain 32-byte PRNGState (lj_def.h:390-392) stored in an ordinary UDTYPE_USERDATA payload held as upvalue 1 of the math.random/math.randomseed C closures (lib_math.c:131-135, 198-204); it persists as a raw 32-byte copy and restores by locating the fresh state's upvalue userdata, while the global g->prng (allocator/string-seed entropy) must not be restored.
- [medium] Running restore on a freshly initialized state with the GC in GCSpause makes the whole reconstruction barrier-free (every object is white or a GC root per the rules at lj_obj.h:92-146), with ordering constraints: strings implicit-first, protos before closures, two-phase allocate-then-fill for tables/closures/udata cycles, and per-thread stack materialization before open-upvalue creation because uv->v points into the stack and resizestack relocates it (lj_state.c:85-86).

## VERIFICATION
CLAIM: Running restore on a freshly initialized state with the GC in GCSpause makes the whole reconstruction barrier-free (every object is white or a GC root per the rules at lj_obj.h:92-146), with ordering constraints: strings implicit-first, protos before closures, two-phase allocate-then-fill for tables/closures/udata cycles, and per-thread stack materialization before open-upvalue creation because uv->v points into the stack and resizestack relocates it (lj_state.c:85-86).
VERDICT: confirmed
EVIDENCE: Core claim verified against the pinned tree. (1) Barrier rules: lj_obj.h:92-146 is verbatim the cited comment; the invariant is "a black object never points to a white object" (:96-98), with barrier-omission cases for GC roots/global_State (:102), lua_State fields ("threads are never black", :103), stack slots (:104), open upvalues (:105), and newly created white objects (:106-107). (2) No black objects can exist in GCSpause: every barrier macro is conditional on isblack(target) (lj_gc.h:93-109); marking only begins when gc_onestep's GCSpause case runs gc_mark_start (lj_gc.c:665-667, 102-113); both cycle exits return to GCSpause only after sweep has flipped all survivors white (lj_gc.c:700, 718); all new objects are allocated white (newwhite, lj_gc.c:895); lj_gc_barrierback even asserts state != GCSpause (lj_gc.h:86-87). So with the GC held in GCSpause, omitted barriers are provably no-ops. (3) In-tree precedents for exactly this pattern: lj_state.c:196 "NOBARRIER: State initialization, all objects are white."; the lj_serialize.c decoder builds tables two-phase with "NOBARRIER: The table is new (marked white)" (lj_serialize.c:395-411); lj_func.c:59,117,130,144,165. (4) Ordering: protos-before-closures is structural — func_newL needs the proto at allocation time (sizeLfunc(pt->sizeuv), fn->l.pc=proto_bc(pt), lj_func.c:126,131), and proto constants form a DAG (bcread ktab holds only primitives/strings). Two-phase allocate-then-fill is the in-tree idiom (lj_serialize.c:395-397; lj_func.c:129 "Set to zero until upvalues are initialized"). Stack-before-open-upvalues: lj_state.c:85-86 verified verbatim (resizestack relocates uv->v over L->openupval), and func_finduv takes a raw TValue* slot inserted into an address-sorted list (lj_func.c:37-61), so the slot must exist when the upvalue is created. (5) GC steps cannot occur spontaneously: lj_mem_realloc/lj_mem_newgco never advance the GC and have no emergency-GC fallback (lj_gc.c:869-897); the GC advances only via lj_gc_check (lj_gc.h:65-67) or explicit fullgc.
CORRECTION: Two crucial nuances. (A) GCSpause at restore START is not sufficient — the claim's guarantee requires the GC to be pinned in GCSpause for the WHOLE restore. lj_obj.h:106-107 states the proviso explicitly ("But make sure nothing invokes the GC inbetween"), and a fresh state has a finite threshold (g->gc.threshold = 4*g->gc.total, lj_state.c:204), which a large restore will cross. Any lj_gc_check on the path then starts marking and creates black objects mid-restore: check sites include the public C API allocators (lj_api.c:641-751), lua_load (lj_load.c:74), and lj_func_newL_gc itself (lj_func.c:163). The driver must therefore either use only internal constructors (lj_tab_new, lj_str_new, func_finduv, lj_bcread — none contain gc checks) or pin the threshold, per the in-tree idiom "g->gc.threshold = LJ_MAX_MEM; /* Prevent GC steps. */" (lj_gc.c:516/526). Also, after sandbox/library init the state may no longer be in GCSpause, so the driver must force it first (lj_gc_fullgc ends at GCSpause, lj_gc.c:799-801). (B) The causal rationale for stack-before-upvalues is inverted: resizestack's uv->v relocation (lj_state.c:85-86) is a REPAIR mechanism — upvalues properly linked into L->openupval survive stack resizes. The hard constraints are that func_finduv requires a live TValue* into the currently allocated stack (address-sorted insert, lj_func.c:37-61) and that any driver-held raw TValue* references into a stack dangle across a resize (resizestack fixes only uv->v, L->base, L->top, jit_base). The ordering conclusion stands; the stated mechanism does not.
