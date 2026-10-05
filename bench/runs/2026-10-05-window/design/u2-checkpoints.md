# u2-checkpoints: where LuaJIT checks the GC threshold, and how long a lend window lasts

This is a read-only survey. Nothing under the repo was changed.

**Sources and conventions**

- `src` means `prototype/watchdog/luajit/src`, the pinned LuaJIT 2.1 with the CHECKHOOK patch. The build copies it and patches only `lj_func.c`, adding the penalty scrub in `lj_func_freeproto` (`native/build-native.sh:23-38`, `:412-432`). Lines in `lj_func.c` cited here are pristine; in the build copy, lines after `lj_func_freeproto` are 22 higher (as reported in `bench/runs/2026-10-04-wall/design/u-luajit-gc.md`).
- The build is GC64: `native/build-native.sh:516-542`, `src/lj_arch.h:597-598`. So `GCRef` is 8 bytes (`lj_obj.h:54-60`) and `Node` is 24 bytes, since it holds val, key and next and has no `freetop` under GC64 (`lj_obj.h:488-495`). An array slot is 8 bytes. That matches the shim's own figure of 64 KB for `sieve` at N=8192 (`native/lj52shim.c:803-807`).
- The shim is cited at HEAD `d9080d4`.
- "Checkpoint" means any code that compares `gc.total >= gc.threshold` and calls the collector when it holds.
- "Lend window" runs from the first allocation that crosses a tier top until the shim latches the proof (white flipped and state `GCSpause`, `lj52shim.c:1151`).

---

## 0. Findings in one page

1. **There are only five kinds of checkpoint** (§1.1):
   - C functions call `lj_gc_check` (48 sites) or `lj_gc_check_fixtop` (1 site, FNEW).
   - `lj_meta_cat` has an inline check that runs after it allocates.
   - The interpreter has three inline compares: `ffgccheck`, TNEW and TDUP. These are the only reads of `gc.total` in `vm_x64.dasc`.
   - Compiled traces have `asm_gc_check`, emitted at the trace head and at LOOP.
   - `lj_trace_exit` calls the step directly, but only in `GCSatomic` or `GCSfinalize`.
2. **No checkpoint runs before or after any of these:**
   - **Table growth** in every form: `lj_tab_newkey` → `rehashtab` → `lj_tab_resize`, reached from TSETV/TSETS/TSETB/TSETR/TSETM/GSET, `rawset`, `table.insert`, `lua_rawset(i)`/`lua_settable`/`lua_setfield`, and NEWREF on trace.
   - **Stack growth** (`lj_state_growstack`).
   - Key interning in `lua_getfield`/`lua_setfield`, and number→string coercion in `lj_lib_checkstr`.
   - Buffer puts on trace (BUFPUT helpers are CALLL/CALLS and are not counted).

   A loop whose only allocations are of these kinds never reaches a checkpoint, interpreted or compiled. Its allocation is bounded only by LuaJIT's size limits: about 1 GiB for an array part, about 1.5 GiB for a hash part, and about 512 KiB per coroutine stack.
3. **Checks before vs after.**
   - These check **before** they allocate: TNEW, TDUP, FNEW, the `ffgccheck` fast functions (`tostring` of a number, `string.char`/`sub`/`reverse`/`lower`/`upper`), `tostring`'s C path, every `lua_push*` of a GC object, `lua_createtable`/`newthread`/`newuserdata`, and compiled sections.
   - These check **after**: `lj_meta_cat` (CAT and `lua_concat`), `string.rep`, `string.format`, `string.dump`, `table.concat`, `table.pack`, and the parser's `keepstr` and constructor template.
   - A check-after site lends its whole operation. That is 2-3 times the result length (a power-of-two `tmpbuf` plus the string), and the program chooses it, up to `LJ_MAX_STR` (about 2 GiB).
4. **An armed cycle (stepmul 0) completes at the first checkpoint that fires, in that same call, when off trace.** There are four exceptions:
   - **On trace:** the step bails at atomic. The GC guard exits the trace (that exit is never patched to a side trace). `lj_trace_exit` restores the snapshot, which may allocate sunk tables and grow the stack, and *then* completes the cycle.
   - **Armed mid-sweep:** the first checkpoint only finishes the old cycle. The shim's park reset happens at the next allocator call, and a *second* checkpoint runs the proving cycle.
   - **Host GCSTOP:** no checkpoint fires at all until GCRESTART. OC brackets every eris persist and unpersist with it.
   - **Finalizers:** no checkpoint can fire inside a finalizer (`threshold = LJ_MAX_MEM`). They run inside the proving step itself.
5. **The shim reads the proof one allocation late.** The latch is in `lj52_gc_pressure`, which runs *after* the grant-or-refuse decision (`lj52shim.c:398-406` in csync mode, `:460-473` in legacy mode). So the first allocator call after a completed cycle is still judged as if unproven. A "lend until proven" rule must read the latch before it decides; otherwise every window grows by one allocation.
6. **Verdict:** "lend until the armed cycle is proven" is **not self-bounding**. It is naturally bounded (by a few KB, from program text) only when the crossing is followed by a check-before operation, with no table or stack growth in between. **These cases need a hard ceiling:**
   - check-after operations;
   - table growth and stack growth;
   - trace sections with large runtime-sized strings, and uncounted trace allocations;
   - string-table growth (a single allocation of 16 bytes × live strings);
   - host-side `rawSet` loops.

   **Under HOOK_GC and GCSTOP the lend must be 0**, as the credit is today (`lj52shim.c:1093`). §5 has the table.
7. **The stall sites named in the roadmap row are all within one operation of a checkpoint:** the probe's closure (FNEW, checks before), its stage string (CAT, checks after), and the table constructors in OpenOS's `event.timer` (TNEW, checks before; OpenOS source not read). So for that scenario the window is short. The open question is the verdict at the proof, not how long the window lasts. (This is an inference from the code, not a measurement.)

---

## 1. Where the checkpoints are, relative to the allocations they guard

### 1.1 The complete set

| Kind | Where | Test | Calls |
|---|---|---|---|
| `lj_gc_check(L)` | macro `lj_gc.h:65-67`; 48 call sites: `lj_api.c` 11, `lib_ffi.c` 10, `lib_buffer.c` 9, `lib_io.c` 3, `lib_string.c` 3, `lib_table.c` 2, `lj_parse.c` 2, `lj_carith.c` 2, and 1 each in `lib_base.c`, `lib_bit.c`, `lib_os.c`, `lj_load.c`, `lj_ccall.c`, `lj_ccallback.c` (grep) | `total >= threshold` | `lj_gc_step` |
| `lj_gc_check_fixtop(L)` | `lj_gc.h:68-70`; one site, `lj_func.c:163` (FNEW) | same | `lj_gc_step_fixtop` (`lj_gc.c:760-764`) |
| `lj_meta_cat`'s own check | `lj_meta.c:382-385` | same | `lj_gc_step` |
| Interpreter inline compares | `vm_x64.dasc:1226-1231` (the `ffgccheck` macro, used at `:1383`, `:1954`, `:1984`, `:2045`); TNEW `:3800-3802`/`:3825`; TDUP `:3832-3834`/`:3849`. **These are the only `gc.total` reads in `vm_x64.dasc`** (grep). | same | `fff_gcstep` (`:2242-2259`) → `lj_gc_step`, or `lj_gc_step_fixtop` |
| Trace `asm_gc_check` | `lj_asm_x86.h:2822-2850`; emitted at the trace head (`lj_asm.c:2587-2591`), at LOOP (`:1691-1692`), and for IR_GCSTEP (`:1182-1193`) | same (`lj_asm_x86.h:2846-2848`) | `lj_gc_step_jit` (`lj_gc.c:768-777`) |
| Trace exit | `lj_trace.c:942-944` | **no threshold test**; only `state == GCSatomic \|\| GCSfinalize`, and not under HOOK_GC | `lj_gc_step` |
| Host | `lua_gc` STEP/COLLECT (`lj_api.c:1255`, `:1262-1270`); RESTART rewrites the threshold (`:1251-1252`) | — | `lj_gc_step` / `lj_gc_fullgc` |

The bytecodes FORL, ITERL, LOOP, CALL, RET, and the table stores and loads, never check. Neither does any code in `lj_tab.c`, `lj_str.c`, `lj_buf.c`, `lj_state.c`, `lj_strfmt.c` or `lj_snap.c`; grep finds no `gc.total` or `lj_gc_check` in them.

### 1.2 Per operation

**Bytecodes and VM paths**

| Operation | Check | Where | Allocations it makes |
|---|---|---|---|
| **TNEW** | **before** | `vm_x64.dasc:3800-3802` → `:3825` → `lj_tab_new` `:3813` | 1 call if asize ≤ 16, colocated (`lj_tab.c:85-88`; `LJ_MAX_COLOSIZE` `lj_def.h:62`). Otherwise up to 3: GCtab `:103`, array `:119`, hash `:124`→`:45`. asize is capped at 0x801 slots, about 16 KB (`vm_x64.dasc:3806`, `:3821`; `lj_parse.c:1940-1941`). hbits comes from the constructor's hash count (`lj_parse.c:1942`). |
| **TDUP** | **before** | `vm_x64.dasc:3832-3834` → `:3849` → `lj_tab_dup` `:3840` | Same as `newtab`, at the template's sizes (`lj_tab.c:168`). |
| **FNEW** | **before** | `lj_func.c:163` (fixtop), then `func_newL` | 1 closure (`lj_func.c:126`), plus one `GCupval` per new open upvalue (`:74`, via `:173`), at most `LJ_MAX_UPVAL` = 60 (`lj_def.h:69`). |
| **CAT** (and `lua_concat`) | **after** | `lj_meta.c:382-385` | `tmpbuf` growth (`:364` → `lj_buf.c:19-49`, doubling to a power of two), then the string (`:379` → `lj_str_alloc`, `lj_str.c:278`), then a possible string-table growth (`lj_str.c:309` → `:139`; old table freed at `:212`). **The `__concat` path returns at `lj_meta.c:345` without checking**, after possibly concatenating one run of strings in an earlier loop iteration (`:313-381`). |
| **TSETV/TSETS/TSETB/GSET** new key | **none** | `vm_x64.dasc:4016-4017` → `vmeta_tsetv` (`:846`) → `lj_meta_tset` (`:859`; `lj_meta.c:166-203`) → `lj_tab_newkey` (`lj_meta.c:187`). TSETS goes direct (`vm_x64.dasc:4101`). | When the hash has no free node: `rehashtab` (`lj_tab.c:446`, `:357-369`) → `lj_tab_resize`, which makes an array realloc (`:249`) or a separated copy (`:244`), a new hash (`:259` → `:45`), and frees the old hash (`:290`). |
| **TSETR** | **none** | `vm_x64.dasc:901` → `lj_tab_setinth` | Same as above. |
| **TSETM** (`{f()}`, `{...}`) | **none** | `vm_x64.dasc:4206` → `lj_tab_reasize` (`lj_tab.c:371-374`) | 1 array realloc, up to the number of values on the stack. |
| **CALL / vararg / C stack checks** | **none** | `lj_state_growstack` (`vm_x64.dasc:485`, `:560`, `:1694`, `:2237`, `:4462`) | 1 realloc (`lj_state.c:72`), doubling, up to `LJ_STACK_MAX` = 65500 slots (`lj_state.c:37`, `:113-118`; `luaconf.h:91`). |

**Library functions and the C API**

| Operation | Check | Where | Allocations it makes |
|---|---|---|---|
| `tostring(number)`, fast path | **before** | `ffgccheck` `vm_x64.dasc:1383`, then `lj_strfmt_num` `:1392-1394` | 1 string. |
| `tostring` C path | **before** | `lib_base.c:337`, then `lj_strfmt_obj` `:338` | 1 string. If `__tostring` exists, it tail-calls the metamethod with no check (`:333-335`). |
| `string.sub`/`char` | **before** | `ffgccheck` `vm_x64.dasc:1984`, `:1954`, run before the argument tests, so the C fallbacks are covered too | 1 string via `fff_newstr` (`:1967-1974`). `string.char`'s fallback also grows `tmpbuf` (`lib_string.c:68`). |
| `string.reverse`/`lower`/`upper` | **before** | `ffgccheck` `vm_x64.dasc:2045` | `tmpbuf` growth (`lj_buf_putstr_*`, `:2063`) and 1 string (`:2065`). |
| `string.rep` | **after** | `lib_string.c:102` | Optional separator concatenation (`:94`), `tmpbuf` growth to rep×len (`lj_buf.c:217-239`), then 1 string (`:101`). |
| `string.format` | **after** | `lib_string.c:666` | `tmpbuf` growth; one string per `%s` of a non-string (`lj_strfmt.c:453`); `__tostring` through `lua_call` (`lj_strfmt.c:434`), which runs Lua code with its own checkpoints; then 1 string. |
| `table.concat` | **after** | `lib_table.c:168` | `tmpbuf` growth about log₂(n) times inside `lj_buf_puttab` (`lj_buf.c:241-270`), then 1 string (`lib_table.c:167`). |
| `table.pack` | **after** | `lib_table.c:283` | 1-3 calls (`:276`). |
| `table.insert` | **none** | `lib_table.c:79-106` | `lj_tab_setint` → newkey/rehash. |
| `rawset` | **none** | `lib_base.c:196-203` → `lua_rawset` (`lj_api.c:990-1000`) | newkey/rehash. |
| `string.gsub`, `gmatch`, captures (luaL_Buffer) | **before**, at each flush | `lua_pushlstring` `lj_api.c:641`, from `lib_aux.c:189` and `:227`; `lua_concat` (after, via `lj_meta_cat`) `lib_aux.c:208`, `:241` | One string per `LUAL_BUFFERSIZE` (`luaconf.h:113`: BUFSIZ if ≤ 16384, else 8192; which CRT's BUFSIZ applies was not checked). |
| `string.byte`, `unpack`, `select` | **none** | — | Stack growth only. |
| `coroutine.create` | **before** | `lib_base.c:608` → `lua_newthread` `lj_api.c:741` | Thread plus stack. |
| `load` / parser | before, plus periodic | `lj_load.c:74`; `lj_parse.c:265` (after each kept string constant); `lj_parse.c:1944-1946` (after a constant constructor template) | Bytecode, constant and proto vectors between checks; bounded by the chunk. The parser was not audited further. |
| `lua_push{l,}string`, `pushfstring`, `pushcclosure`, `createtable`, `newthread`, `newuserdata` | **before** | `lj_api.c:641`, `:653`, `:663`, `:671`, `:681`, `:710`, `:741`, `:751` | 1 object (+ string-table growth). |
| `lua_tolstring`, `luaL_check/optlstring` on a number | **before** | `lj_api.c:500`, `:519`, `:541` | 1 string. |
| `lj_lib_checkstr` on a number | **none** | `lj_lib.c:203` | 1 string. |
| `lua_getfield`/`lua_setfield` | **none** | key interned at `lj_api.c:803`, `:976`; then `lj_meta_tget`/`tset` | 1 string (+ string-table growth); for setfield, also newkey/rehash. |
| `lua_settable`/`rawseti`/`rawset` | **none** | `lj_api.c:951-968`, `:1002-1012`, `:990-1000` | newkey/rehash. |

**On trace**

| Operation | Check | Where | Allocations it makes |
|---|---|---|---|
| Counted allocations: SNEW, TNEW, TDUP, BUFSTR, TOSTR, CALLA, CNEW(I) | **before**, at the section head | `lj_asm.c:1149`, `:1161`, `:1174`, `:1296`, `:1309`, `:1904-1905`; `lj_asm_x86.h:1864` | All the counted allocations in one section. |
| NEWREF (`lj_tab_newkey`) | **none** | `lj_asm.c:1363-1375` (not counted) | newkey/rehash. |
| BUFPUT helpers (`lj_buf_put*`, `lj_strfmt_put*`) | **none** of their own | CALLL/CALLS, not CALLA (`lj_ircall.h:161-177`) | `tmpbuf` or SBuf growth. A BUFSTR, which *is* counted, normally ends the chain (`lj_ffrecord.c:996`, `:1525`; `lj_record.c:2145`). |

**Interning (`lj_str_new`, `lj_str.c:314-357`) never checks.** Whether a check comes before or after depends entirely on the caller:
- **before:** `lua_pushlstring`, `ffgccheck`, `tostring`;
- **after:** CAT, `rep`, `format`, `concat`, `keepstr`;
- **none:** `getfield`/`setfield` keys, `lj_lib_checkstr`, error messages.

**Table resizing (`lj_tab_resize`/`rehashtab`) never checks, at any caller.** Only *creating* a table checks: TNEW, TDUP, `lua_createtable`, and `table.pack` (which checks after). The parser's `lj_tab_reasize` checks after (`lj_parse.c:1944-1946`).

**`lj_buf` growth (`buf_grow`, `lj_buf.c:19-49`) never checks itself.** It doubles the buffer until it fits (`:24-25`), with one `lj_mem_realloc` per call (`:34`). Atomic halves `tmpbuf` on every cycle (`lj_gc.c:651`, `lj_buf.c:88-97`), so after a cycle the next big concatenation pays to regrow.

---

## 2. The most allocation that can happen between two consecutive checkpoints

### 2.1 Inside one bytecode

| Bytecode | Allocator calls after the last check | Bytes |
|---|---|---|
| TNEW / TDUP | ≤ 3 | GCtab, plus 8 × asize (≤ 0x801 slots for TNEW, about 16 KB), plus 24 × 2^hbits. hbits is bounded by the constructor in the source, and above 26 the table errors (`lj_tab.c:41-43`). |
| FNEW | ≤ 61 | The closure plus ≤ 60 upvalues. A few KB at most (sizes not computed). |
| CAT | ≤ 3 grows + 1 free | Up to 2 × tlen (`tmpbuf` rounded to a power of two, and only if it must grow) + tlen + header, plus a string-table growth. tlen < `LJ_MAX_STR` = 0x7fffff00 (`lj_meta.c:362`, `lj_def.h:54`). The check comes **after** these. |
| Table store hitting a rehash | 1-3 grows + 1 free | New array 8 × asize after doubling, plus new hash 24 × 2^hbits. **No check before or after.** |
| TSETM | 1 | 8 × the number of values. **No check.** |
| CALL / vararg | 1 stack realloc | Up to 65500 × 8 ≈ 512 KiB in total. The last doubling alone is about +256 KiB. **No check.** |

### 2.2 Inside one C library call

Every standard library loop that allocates repeatedly does one of two things. Either it checks at each step (luaL_Buffer users, through `lua_pushlstring`), or it reallocates about log₂(n) times and checks once at the end (`table.concat`, `string.format`, `string.rep`). **No standard library C function allocates an unbounded number of times without a check**, with two exceptions:
- `table.insert` and `rawset` make one table growth per call, unchecked;
- stack growth from `unpack`, `string.byte(s,1,-1)` and `select` is unchecked but bounded by 65500 slots.

The *bytes* in one check-after call are unbounded except by the arguments. `string.rep("x", 2^22)` lends a 4 MiB `tmpbuf` plus a 4 MiB string before the check at `lib_string.c:102`.

### 2.3 Inside a metamethod sequence

- `__index`/`__newindex` chains run up to `LJ_MAX_IDXCHAIN` = 100 levels (`lj_def.h:71`; `lj_meta.c:170`). They allocate nothing except the final new key (newkey/rehash, unchecked).
- Function metamethods are calls (`mmcall`, `lj_meta.c:194`). Their bodies have their own checkpoints.
- `__concat`: each `lj_meta_cat` entry concatenates at most one run of strings. If that run is followed by a non-string, it returns at `:345` **without** reaching the check at `:382-385`. The continuation then re-enters `lj_meta_cat`, so a chain like `s..obj..s..obj` allocates a string run per metamethod with no checkpoint of its own (Lua code inside the metamethods aside). Each run is bounded by its operands.
- `__tostring` reached through `tostring` is a tail call with no check (`lib_base.c:333-335`).

### 2.4 Inside a compiled trace

- **Placement.** The assembler works backwards and counts allocations into `as->gcsteps`. When it reaches LOOP, it emits a check for the loop body (`lj_asm.c:1691-1692`). At the end it emits the head check for the pre-loop part (`:2587-2591`, guarded by snapshot 0). So **each check sits at the top of its section and runs before the allocations it counts**. A looping trace checks once per iteration. An IR_GCSTEP, which a side trace emits after re-materialising sunk allocations from its parent (`lj_snap.c:687-688`), puts a check right there and stops implicit checks further up (`lj_asm.c:1182-1193`).
- **How many allocations per check.** All counted allocations in one section. That is bounded by the recorded IR (`maxrecord` = 4000, `lj_jit.h:110`), and their *sizes* are decided at run time. A loop body doing `s:sub(1, n)` on a large string, or `string.rep(x, n)`, lends n or 3n bytes per iteration before the next check. Loop unrolling puts several source iterations into one section: `instunroll` 4 and `loopunroll` 15 (`lj_jit.h:120-121`). I did not derive the per-section maximum beyond the `maxrecord` bound.
- **Uncounted allocations.** These are NEWREF (newkey/rehash) and BUFPUT helpers that write to a buffer *object* without ending in BUFSTR. A trace containing only these has no check at all (`as->gcsteps` stays 0). The canonical case is a table-fill loop: `t[i]=v` grows through the interpreter, or through a side trace's NEWREF, at each power of two. It allocates with no checkpoint, compiled or not.
- **Sunk allocations** are not emitted on trace. They are skipped as unused (`lj_asm.c:2572-2573`), and NEWREF returns early for `RID_SINK` (`:1368-1369`). They are materialised at exit:
  - `lj_snap_restore` (`lj_snap.c:940-`) recreates tables (`:894-895`) and cdata (`:846`) and replays sunk stores, which can call `lj_tab_set` → newkey;
  - the stack may also grow (`:968`).

  All of this runs **after** the last on-trace check. It is bounded by the number of sunk objects in the exit's snapshot and their sizes, which are trace constants. I did not check whether loop-carried (PHI) allocations can be sunk.
- **The GC exit itself.** `asm_gc_check` exits when `lj_gc_step_jit` returns 1, that is in `GCSatomic`/`GCSfinalize` (`lj_asm_x86.h:2830-2833`, `lj_gc.c:776`). That exit is **never patched to a side trace** (`lj_asm_x86.h:3157-3164`), so it always reaches `lj_trace_exit`.

### 2.5 `lj_str_new`

- At most 2 grows and 1 free: the string (`lj_str.c:278`) and, when `num > mask`, a string table twice the size (`:309`, `:139`; the old one is freed at `:212`).
- **The string-table growth is the largest single allocation that a tiny string can trigger:** (2 × (mask+1)) × 8 bytes.
  - At 16,384 interned strings the new table is 256 KiB, with 128 KiB net.
  - At 8,192 strings it is 128 KiB.
  - The actual string count in an OC machine was not checked.
- The shrink during sweep (`lj_gc.c:695-696`) allocates half a table *inside* the proving cycle.

### 2.6 Inside the JIT

- **What allocates.** Recording, optimisation and assembly allocate with no checkpoint:
  - IR buffer growth (`lj_ir.c:78-109`);
  - the snapshot buffer and map (`lj_snap.c:43`, `:54`);
  - the trace vector (`lj_trace.c:75`);
  - the trace copy itself (`lj_trace_alloc`, `lj_trace.c:121-130`).
- **Bound.** Per trace this is limited by `maxrecord` 4000, `maxirconst` 500 and `maxsnap` 500 (`lj_jit.h:110-113`). Tens of KB, not measured.
- **A refusal here is caught.** `lj_trace_ins` runs `trace_state` under `lj_vm_cpcall` and turns any error into `LJ_TRACE_ERR` → `trace_abort` (`lj_trace.c:770-778`, `:754-760`). From reading, then, a refusal inside the JIT costs a trace abort, not a program error. I did not confirm that every JIT allocation happens inside `trace_state`.
- **The shim can tell where it is being called from.** `g->vmstate` is `~LJ_VMST_RECORD`/`OPT`/`ASM` during the JIT (`lj_trace.c:700`, `:725`, `:743`), `~GC` in the collector (`lj_gc.c:733`, `:785`), `~EXIT` during a trace exit (`vm_x64.dasc:2461`), `~C` in a C function (`:4908`), and a trace number (≥ 0) on trace (`lj_asm.c:1925`, `:2036`). So the allocator can classify its caller coarsely. This is a possible design lever, **not evaluated here**.

### 2.7 Host calls: jnlua, OC, and the shim's wrappers

- **jnlua** runs nearly every operation as `lua_pushcfunction(L, x_protected)` plus `JNLUA_PCALL` (e.g. `OC-JNLua/native/src/jnlua.c:1355-1370`). In this build, `lua_pushcfunction` is `lj52_pushcfunction`. It runs under `norefuse` (`lj52shim.c:2013-2018`), and its warm path allocates nothing (`:178`).
- Each jnlua call then makes O(1) allocations. Pushes check before (§1.2). `rawset`/`rawseti`/`settable`/`setfield` do not check, and `getfield`/`setfield` intern their key unchecked.
- **The Java side loops.**
  - `ExtendedLuaState.pushList` (`ocelot-brain/.../machine/ExtendedLuaState.scala:64-76`) does `newTable()` (checked) and then, per element, `pushValue` and `rawSet`. Numbers allocate nothing, so **an Array of n numbers grows a table to 8 × nextpow2(n) bytes with no checkpoint**.
  - `pushTable` (`:79-95`) presizes the hash part (`newTable(0, size)`), so its `setTable` calls should not grow it.
  - Strings are checked per push.
  - These run between resumes or inside component callbacks.
- **The shim's own wrappers:**
  - `lj52_setfield` (`lj52shim.c:568-576`) is `lua_setfield`, unchecked.
  - `luaL_tolstring` (`:2299-2320`) pushes through checked APIs or calls `__tostring`.
  - `luaL_getsubtable` (`:2266`) mixes checked and unchecked calls.
  - The `norefuse` window is already never refused and never arms (`:398`, `:460`, `:1128`).

---

## 3. How long an armed cycle can stay unproven

The arm (`lj52shim.c:1046-1058`) sets `stepmul = 0` and `threshold = total`. When a checkpoint fires off trace, `lj_gc_step` gets `lim = LJ_MAX_MEM` (`lj_gc.c:735-736`) and debt `+0` (`:737-738`). It then runs mark, atomic (flipping the white at `:654`), sweep and finalize to `GCSpause` (`:741-745`) **in that one call**. Only two returns do not advance, and both are on trace (`:674-675`, `:709-710`). The shim latches the proof at the **next allocator call** (`lj52shim.c:1151-1167`). The last sweep frees happen before `state = GCSpause` is written (`lj_gc.c:700`/`:718`), so the latch never fires inside the cycle.

| Situation | What happens | Window |
|---|---|---|
| **Off trace, armed at `GCSpause` or `GCSpropagate`** | The first checkpoint that fires completes the cycle. | Crossing → next checkpoint, + 1 allocator call (the latch, §0 point 5). |
| **Frees after the arm** | `total` dips below the arm-time threshold, so `>=` fails until `total` climbs back. The park reset needs `gc_moved` (`lj52shim.c:1169`), so it does not help at `GCSpause`. | Longer in allocator calls; **unchanged in net bytes**. The excursion should be measured as net `used - top`, not as a count of grants. |
| **On trace (C1)** | 1. The head or loop check fires → `lj_gc_step_jit` (`lj_gc.c:768-777`). The first step marks and then bails at atomic with `LJ_MAX_MEM`; with debt 0 that leaves `threshold = total + 1024` and returns −1 (`:747-750`). The loop stops (`:773`) and returns 1 (`:776`). 2. The guard exits (`lj_asm_x86.h:2831`, never patched). 3. `vm_exit_handler` clears `jit_base` (`vm_x64.dasc:2489`). 4. `lj_trace_exit` runs `trace_exit_cp` (`lj_trace.c:921`): the snapshot restore, which may **allocate** (§2.4). 5. Then, because the state is `GCSatomic`, it calls `lj_gc_step` (`:942-944`) off trace, and stepmul 0 completes the cycle. | Crossing → next check on the trace, + the exit restore's allocations, + 1 allocator call. |
| **On trace with `HOOK_PROFILE` set** | The exit does not step (`lj_trace.c:940-941`). The cycle sits in `GCSatomic` with `threshold = total + 1024` until an interpreter checkpoint fires. OC does not use the profiler (not checked beyond this). | + ≥ 1024 bytes + one more interpreter interval. |
| **Trace with no counted allocations** | No on-trace check ever fires. `lj_trace_exit` steps only in `GCSatomic`/`GCSfinalize`, so ordinary exits do not start an armed cycle that is at `GCSpause`. | Until the program reaches an interpreter or C checkpoint (§4). |
| **Armed mid-sweep** (`GCSsweepstring`, `GCSsweep`, `GCSfinalize`) | 1. Checkpoint 1 finishes the *old* cycle without atomic and sets `threshold = 2 × estimate` (`lj_gc.c:742`). The white has not flipped, so there is no proof. 2. At the next allocator call the park reset writes `threshold = total` (`lj52shim.c:1169-1175`). 3. Checkpoint 2 runs a full cycle. 4. The next allocator call latches it. If checkpoint 1 is on trace with udata pending, the step bails at `:709-710` and the exit finishes it (`lj_trace.c:942-944`). That is still not a proof. | Two checkpoint intervals + 2 allocator calls. |
| **Finalizers** | Pending finalizers run inside the proving step itself (`GCSfinalize`, cost 100 each against `LJ_MAX_MEM`), and it ends at `GCSpause` (`lj_gc.c:706-718`). Inside a finalizer: `threshold = LJ_MAX_MEM` (`:516`), so **no checkpoint can fire**, and it is put back at `:526`. Errors, ERRMEM included, are caught and reported as ERRFIN (`:522`, `:527-534`). The shim neither lends nor latches under HOOK_GC (`lj52shim.c:1093`, `:1136-1139`). In OC the finalizers are host userdata `__gc` (jnlua). The sandbox's wrapped `__gc` (`machine.lua:780-806`, only with `allowGC`) sits on table metatables, and **LuaJIT never finalizes tables**: `lj_gc_separateudata` walks only the udata list (`lj_gc.c:142-167`). So sandbox `__gc` is inert under LuaJIT. | The finalizers' allocations are inside the window, but they are uncredited today and must stay that way. |
| **Host GCSTOP** | `threshold = LJ_MAX_MEM` (`lj_api.c:1248-1249`), so no checkpoint fires. It ends at GCRESTART with data 0 (`threshold = total`, `lj_api.c:1251-1252`, so the next checkpoint runs the armed cycle, stepmul still 0) or at COLLECT (`lj_gc_fullgc`, `lj_gc.c:781-803`, which flips the white and so proves). OC brackets eris `persist` and `unpersist` with STOP/RESTART (`ocelot-brain/.../luac/PersistenceAPI.scala:125-148`, `:158-172`). The window is everything eris allocates: the whole serialised state, unbounded by the VM. Today there is no credit (`lj52shim.c:1093`). | Unbounded, so it **must be 0**. |
| **Program never reaches a checkpoint** | See §4. No *standard* C function loops on allocation without a check (§2.2). The unchecked loops are Lua-level (table growth, recursion) or host-level (`pushList` → `rawSet`). | Until the loop ends and the next check-before or check-after operation runs. |
| **The ARMCAP valve** | After 65,536 growth attempts while armed, the shim disarms without a proof (`lj52shim.c:1176-1189`). Checkpoint-free regions grow geometrically, so they make few calls. The valve bounds **calls, not bytes**, and it would also end a "lend until proven" window with no proof. The rule needs a defined outcome for that case. | — |

---

## 4. Unbounded allocation with no checkpoint, worst cases with sizes

1. **Table fill or growth loops**, interpreted or compiled. Examples are `for i=1,N do t[i]=x end`, `t[#t+1]=x`, `table.insert(t,x)`, `rawset`, and a hash fill with fresh numeric or interned keys.
   - The path is `lj_tab_newkey` → `rehashtab` → `lj_tab_resize`. There is no check at any layer (§1.2). On trace it is NEWREF, which is not counted; the array part is reached through ABC-guarded exits, then the interpreter or a side trace.
   - Bytes: the array part grows in place by realloc, so its positive deltas telescope to the final size. That is 8 × 2^k, with a cap of `LJ_MAX_ASIZE` = 2^27+1 slots, about 1 GiB (`lj_def.h:60-61`). The single largest step is half the final size, e.g. +512 KiB going from 2^16 to 2^17 slots.
   - The hash part makes a new allocation of 24 × 2^hbits and frees the old one at each rehash (`lj_tab.c:259`, `:290`), up to 2^26 nodes, about 1.5 GiB (`lj_def.h:59`).
   - The shim's own `sieve` figures (64 KB at N=8192, 512 KB at N=65536; `lj52shim.c:803-807`) are this case.
2. **Stack growth.** Deep non-tail recursion, `unpack` or `table.unpack` of many values, `string.byte(s,1,-1)` and varargs, through `lj_state_growstack`.
   - At most 65500 slots, about 512 KiB per coroutine (`lj_state.c:37`, `:110-118`), plus `LJ_STACK_EXTRA` while handling the overflow.
   - The last doubling is one realloc of about +256 KiB.
   - A new coroutine costs a checkpoint (`lj_api.c:741`), so N coroutines × 512 KiB needs N checkpoints, but each one may pass before its stack grows.
3. **Check-after library calls** (`string.rep`, `string.format`, `table.concat`, CAT on long strings).
   - One call, program-chosen size, about 3 × the result before the check, up to `LJ_MAX_STR`.
   - A *single* allocation larger than any ceiling is simply refused. The lend only matters for allocations that fit under it.
4. **Trace sections with runtime-sized strings** (SNEW/BUFSTR): one iteration's strings before the next loop-head check.
5. **Buffer objects (`string.buffer`) on trace**: puts are uncounted CALLL/CALLS (`lj_ircall.h:170-177`), so a `buf:put` loop has no check.
   - Reachability from the OC sandbox: `machine.lua` and the repo's `native/kernel/patch-machine-lua.lua` contain no `require`, `string.buffer`, `newproxy` or `jit` (grep). It is very likely unreachable, but not proven exhaustively.
6. **Host `rawSet` loops** (`ExtendedLuaState.scala:64-76`): a component returning n numbers grows the table to 8 × nextpow2(n) unchecked. The size depends on the component (not surveyed).
7. **String-table growth**: one allocation of 16 × live strings (§2.5), triggered by any new string at any site, checked or not.
8. **JIT internals**: per trace, bounded, refusal-tolerant (§2.6).

---

## 5. Conclusion: what "lend from the first crossing until the armed cycle is proven" would grant

"Lent" means net bytes past the tier top during the window. "+1" means one more allocator call, which goes away if the rule reads the latch (white ≠ latched and state == pause, `lj52shim.c:1151`) *before* the grant decision instead of after it as today (`:398-406`, `:460-473`).

| # | Crossing occurs in… and the next checkpoint is… | Worst case lent before the proof | Hard ceiling needed? |
|---|---|---|---|
| 1 | Any allocation, followed by a **check-before** operation (TNEW, TDUP, FNEW, ffgccheck fast functions, `tostring`, `lua_push*`, `coroutine.create`), with no table or stack growth in between | The rest of the crossing operation: at most one table (≤ ~16 KB of array plus a hash bounded by the source), one closure with ≤ 60 upvalues, or one string. Plus string-table growth if a string was interned (16 B × live strings), plus 1 call. | Not for the operation, which is bounded by program text. **Yes for string-table growth**, which can reach hundreds of KB. |
| 2 | A **check-after** operation (CAT/`lua_concat`, `string.rep`/`format`/`dump`, `table.concat`/`pack`, parser `keepstr`/template) | The whole operation: about 2-3 × the result, program-chosen, up to ~2 GiB, plus 1 call | **Yes** |
| 3 | **Table growth or stack growth** with no checkpoint until a loop ends (interpreter or trace NEWREF, `table.insert`, `rawset`, `lua_rawset(i)`, `setfield`, host `pushList`) | Unbounded for tables (to ~1 GiB array, ~1.5 GiB hash); ≤ ~512 KiB per coroutine for stacks | **Yes** |
| 4 | **On trace, with counted allocations** | One section (one iteration, or an unrolled group) of allocations with runtime sizes, plus the exit restore (sunk objects at that snapshot, plus stack growth), plus 1 call. With HOOK_PROFILE, add ≥ 1024 B and an interpreter interval. | **Yes** (runtime-sized SNEW/BUFSTR) |
| 5 | **On trace, with uncounted allocations only** (NEWREF, buffer-object puts) | Unbounded, as in row 3 | **Yes** |
| 6 | **Armed mid-sweep** (the park) | Two intervals of rows 1-5, plus the call that performs the park reset, plus 1 | Same as the rows it combines |
| 7 | **HOOK_GC** (inside a finalizer) | No checkpoint can fire there; the window ends only when the proving step returns | **Lend must be 0** (as now, `lj52shim.c:1093`). A refusal there is swallowed as ERRFIN. |
| 8 | **Host GCSTOP** (eris persist or unpersist) | Unbounded until GCRESTART | **Lend must be 0** (as now) |
| 9 | **JIT internals** (vmstate RECORD/OPT/ASM) | Bounded per trace (tens of KB, not measured) | Not needed for safety: a refusal there aborts the trace (from reading). A ceiling or no lend both work. |
| 10 | **`norefuse` window** (`lj52_pushcfunction`) | Never refused today. The warm path allocates nothing. | Unchanged |

**Overall.** The rule bounds itself only in row 1, by program text and string sizes. Every other row needs the absolute ceiling the shim already enforces: `used + delta ≤ total + G (+ KSLICE)` with G = clamp(total/16, 32 KB, 512 KB) (`lj52shim.c:1060-1064`, `:1087-1099`). Rows 7 and 8 need a ceiling of zero. The window's *length* never needs to be bounded in allocator calls, because ARMCAP bounds calls and not bytes. What must be bounded is its **net bytes**. A "lend until proven" rule is therefore, in effect, "lend up to a ceiling until proven". What it changes from today is *which* ceiling applies to the first crossing (the burst tier's G/2 today), not *whether* there is one.

---

## Not checked

- What `str.num` and the string-table size are in a running OC machine (row 1's string-table term).
- Whether LuaJIT's sink pass sinks loop-carried (PHI) allocations into the loop snapshot (§2.4).
- The exact per-section allocation maximum under loop unrolling, beyond `maxrecord`.
- Every JIT allocation site being inside `trace_state`'s `cpcall` (§2.6).
- The parser between its two checks; the bytecode reader.
- jnlua's `__gc` body; component return sizes (§2.7).
- OpenOS's `event.timer` source (§0 point 7).
- Which CRT's `BUFSIZ` sets `LUAL_BUFFERSIZE`.
- Nothing here was measured. Every statement comes from reading the cited lines.
