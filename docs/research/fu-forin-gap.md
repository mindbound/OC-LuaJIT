# The for-in gap, scoped

Working tree untouched: I read the repo, never wrote to it. All probes, and a patched
*copy* of the serializer, live in
`C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\`.
(Note: `git status` already showed `M serializer/eris_lj.c`, `M docs/*`, `M serializer/README.md`,
`M serializer/tests/m1.lua` when I arrived — those predate this task; `serializer/eris_lj.c` mtime is
18:57, before my first command at 19:01. I did not touch any of them.)

Headline: **(B) can be closed now, host-side, with zero C changes and it is exactly correct.
(A) cannot — the proposed fix compiles, passes the whole suite, and silently corrupts data across
processes. I built it and measured the corruption.**

---

## (A) `for k,v in pairs(t)` — the BC_ITERN keyindex control slot

### Mechanism: every claim in the ARM checks out

* `uint32_t LJ_FASTCALL lj_tab_keyindex(GCtab *t, cTValue *key)` —
  `prototype/watchdog/luajit/src/lj_tab.h:86`, defined at `lj_tab.c:573`. Not static, `LJ_FUNC`,
  statically linked, and I confirmed it links from `eris_lj.c` by building against it.
* Index space is documented in-place at `lj_tab.c:565-570`: array keys `[0..asize-1]`, hash keys
  `[asize..asize+hmask]`, invalid `~0u`. The function returns the **successor** index of `key`:
  `k+1` for an array key `k < asize`; `asize + (n+1 - node)` for a node key; `0` for nil (start);
  `~0u` for a key not in the table; and — this is the ITERN→ITERC fallback the ARM asks about —
  it passes `key->u32.lo` straight through when the key is *itself* a keyindex lightud
  (`lj_tab.c:594`, comment "Despecialized ITERN while running").
* That successor index is **exactly** what the control slot holds. `BC_ITERN`
  (`vm_x64.dasc:4306-4366`) loads `[BASE+RA*8-8]` as a 32-bit index and writes back `RC+1` in the
  array part and `node_idx + asize + 1` in the hash part. `BC_ISNEXT` (`4370-4380`) initialises it
  to `(uint64_t)LJ_KEYINDEX << 32`, i.e. lo = 0.
* `LJ_KEYINDEX = 0xfffe7fff` (`lj_obj.h:288`) is an itype of `LJ_TLIGHTUD` with lightud segment
  0xff — the segment `lj_udata.c:50` deliberately reserves ("Leave last segment unused to avoid
  clash with ITERN key"). Hence `lua_type` says light userdata and `persist_typed`
  (`serializer/eris_lj.c:911`) refuses it.
* **The table is one slot below the control slot**, not two: ITERN reads `[RA-24]` func,
  `[RA-16]` state, `[RA-8]` control. So the fix fits in `p_thread`'s generic slot loop with no
  frame context, confirming the correction already noted in `m3-verification.md:1471`.
* Encode/decode: `idx == 0` → "not started"; else `p = idx-1`; if `p < t->asize` the last key
  returned is the *number* `p` (ITERN returns the array index as the key); else it is
  `noderef(t->node)[p - asize].key`.
* JIT: `IRSLOAD_KEYINDEX` (`lj_ir.h:239`), `SNAP_KEYINDEX` (`lj_jit.h:199`), `rec_itern`
  (`lj_record.c:675-706`), `recff_next` (`lj_ffrecord.c:600-615`) all treat the slot as an integer
  index behind a `LJ_KEYINDEX` itype guard. A restored slot is bit-identical to a live one, so
  traces need nothing extra, and the despecialized ITERC path works on a restored slot by design
  (`lj_tab.c:594`).
* When is ITERN even emitted? `predict_next` (`lj_parse.c:2865-2892`) is a *syntactic* name match:
  the loop expression starts with a GGET/MOV/UGET of something named `pairs` or `next`. So
  `for k,v in pairs(t)` **and** `for k,v in next, t` get ISNEXT+ITERN; anything else (including
  `local f,s,c = pairs(t); for k,v in f,s,c do`) gets JMP+ITERC and round-trips today.

### It is implementable now — I implemented it

I ported the reviewer's patch (`m3-verification.md:1345-1419`) onto the **current** `eris_lj.c`
(the `scratchpad/vkey/` copy is stale — it predates `RThread` and the dead-thread normalisation).
Patched copy + build: `…\scratchpad\vkey2\eris_lj.c`, `…\scratchpad\vkey2\vkey2.exe`.
~45 added lines: `#include "lj_tab.h"`, `TAG_KEYINDEX = 15` (wire format bump 1 → 2), one hunk in
`p_thread`'s slot loop, one hunk in `u_thread` pass 1. It builds clean at `-Wall -Wextra` and
**passes m1 (82), m2 (55), m3 (39/39)**, and it persists every pairs shape I threw at it.

### And it is wrong. Measured, not argued.

The restored iteration is **merely guaranteed not to crash**. It is not guaranteed to visit each
remaining key once — and the corruption is silent and non-deterministic.

Root cause: re-deriving the index from a key restores `next(t,k)` semantics against the *new*
table's traversal order, and that order differs across processes for any hash-part key.
`g->str.seed = lj_prng_u64(&g->prng)` at state open (`lj_str.c:367`, with
`LUAJIT_SECURITY_STRHASH = 1` at `lj_arch.h:753-755`), so every string's hash — and therefore its
main position, and therefore pairs() order — is different in every VM.

Probes `…\scratchpad\k1.lua` (write) / `k2.lua` (read) / `k3.lua` / `k4.lua`, run under
`vkey2.exe` in three separate processes:

| case | same process | process 2 | process 3 |
|---|---|---|---|
| A: 12 string keys, 4 consumed | exact | **missing k8,k9,k10,k11,k12** | **missing k10,k11,k12** |
| B: `for k in pairs(t) do t[k]=nil end`, hash keys | **UNPERSIST FAILS** | UNPERSIST FAILS | UNPERSIST FAILS |
| C: pure array 1..10 | exact | exact | exact |
| D: array, delete-as-you-go | exact | exact | exact |
| E: integer keys in the hash part | order differs | **missing 800,400,700** | **missing 800,400,700** |
| F: yielded before the loop started (idx 0) | exact | exact | exact |
| G: 100-element array, 60 deleted | exact | exact (40/40) | exact (40/40) |
| H: **iterated table is a PERMS entry** | exact | **duplicates p8,p9** | **duplicates p8,p9,p10** |

Three things there matter more than the rest:

1. **Case A is silent.** No error, no warning, a different number of dropped keys per process.
   And it is *green in-process*, which is exactly why the earlier review passed it: a round-trip
   test inside one `lua_State` cannot see this bug.
2. **Case H kills the stated escape hatch.** `m3-verification.md:1469` says the fix "is exact
   whenever the iterated table is a perms entry". That is a same-process artifact. When the table
   is a permanent it is never serialized at all — it is the *host's own table in the new VM* — and
   its node layout is still different, so the resume point lands earlier in the new order and the
   loop re-visits keys it already yielded. For OC this is the common shape (component lists,
   sandboxed globals).
3. **Case B is worse than silent: persist succeeds, load fails.** `for k in pairs(t) do t[k]=nil end`
   is an everyday Lua idiom. The persist side only checks `tvisnil(&n->key)`; the deleted key's
   *value* is nil, so `u_table` never emits it, and `lj_tab_keyindex` returns `~0u` at restore →
   `"the key a for-in loop was suspended on is no longer in its table"`. A world-save that cannot
   be loaded is the worst failure class in this project, and the patch manufactures it out of a
   case that is currently a clean persist-time refusal.

I also ran the same experiment through the **unpatched, shipped** serializer using the ITERC form
(`local nx = next; for k,v in nx, t, nil do …`), which round-trips today
(`…\scratchpad\p3w.lua` / `p3r.lua`): cross-process it duplicated `k2` and skipped `k12`,`k14`,
and gave different answers in processes 2 and 3. **So this silent corruption already ships** for
the split/aliased iterator form. That is an independent existing defect, not something the
keyindex work would introduce.

### Why "re-derive harder" cannot rescue it

Any resume keyed on a *key* inherits the new table's order. Making it exact needs the node layout
reproduced, and that is impossible across processes: a key's main position is
`s->hash & t->hmask` with a per-VM random seed, and LuaJIT's chained-scatter invariant requires
every key to be reachable from *its own* main position (`lj_tab.c` `hashkey` + `lj_tab_newkey`'s
Brent relocation). You cannot place keys at chosen indices under a new seed. Same for
pointer-hashed keys (tables/functions as keys).

### What I recommend for (A) now

**A0 — close the message, not the gap (~10 LOC, no wire bump).** Detect the keyindex in
`p_thread`'s slot loop and raise something true:
`"eris-lj: cannot persist a thread suspended inside a `for … in pairs(t)`/`next` loop; the
traversal index cannot be re-derived against a table rebuilt in another VM"`.
Today's message — *"cannot persist light userdata by value … put it in the perms table"* — is
actively misleading: there is nothing a host can put in perms, and no way for Lua to name the value.
Document the ITERC workaround **with its caveat** (exact for array-like tables, order-divergent
for hash keys), and consider refusing/flagging the ITERC case too.

**A1 — ship the keyindex patch anyway.** Only defensible if the project explicitly adopts
"PUC-Lua/upstream-Eris parity" as the target semantics (there the control var *is* the key, and
those implementations skip/duplicate identically). If taken, it needs at minimum a persist-time
rejection when the resume key's value is nil, so case B fails at save rather than at load. Cost:
~45 LOC, `ERIS_LJ_FORMAT` 1→2, one new LuaJIT dependency (`lj_tab_keyindex`). My recommendation is
**do not ship as-is.**

**A2 — the correct fix, and it is an M4, not a follow-up.** Snapshot the *remaining key sequence*
into the wire record and drive the rest of the loop from it: new tag carrying the key list +
position; at restore replace the loop's func/state/control slots with a synthetic iterator that
walks the list and reads values live from the table; force the ITERC path by patching that
prototype's `BC_ITERN` → `BC_ITERC` (this is exactly the VM's own despecialization, including the
JLOOP unpatch dance at `vm_x64.dasc:4392-4402`, so it is safe for other threads); and make the
synthetic iterator itself re-persistable so a second save mid-loop works. ~250-400 LOC, real JIT
interaction, and it is the only design that gives exact semantics.

---

## (B) `for i,v in ipairs(t)` — the hidden aux function

### Closable NOW. Zero C changes. Exactly correct, including cross-process.

* `ipairs(t)` returns `ipairs_aux`, a **singleton** GCfunc created once per `lua_State` during
  `luaL_openlibs` (`lib_base.c:113`, `LJLIB_NOREGUV`; created in `lj_lib_register`'s loop,
  `lj_lib.c:96-110`). ffid `FF_ipairs_aux` = 6 (`lj_ffdef.h:7`; confirmed at runtime —
  `tostring` prints `function: builtin#6`). No upvalues of its own; `LJLIB_PUSH(lastcl)` makes it
  **upvalue 1 of `ipairs`**.
* It is obtainable from Lua two ways, both verified: `select(1, ipairs({}))` and
  `debug.getupvalue(ipairs, 1)` (name `""`, value identical). Identity is stable across calls.
* For completeness: `pairs`'s iterator is the ordinary global `next` — `FF_next == FF_next_N == 4`
  (`lib_base.c:76-77`, `lj_bc.h:240`), so a flattened-`_G` perms table already covers it. The
  pairs blocker is only the control slot.
* Measured (`…\scratchpad\p4.lua`, `p4r.lua`): with the aux in perms, a coroutine suspended mid-
  `ipairs` persists (549 bytes) and resumes **exactly**, in-process and in a fresh process —
  consumed `a,b`, resumed `c,d,e,f`, final `1=a,2=b,3=c,4=d,5=e,6=f`. Correctness here is
  unconditional: `ipairs` compiles to ITERC (predict_next matches only `pairs`/`next`), its control
  var is a plain integer, and array-index order is layout-independent.

**Recommend option (ii), implemented generically** rather than as a hardcoded `ipairs({})` trick —
one extra arm in the perms flattener (`tests/m3.lua`'s `build_perms`, and OC's
`PersistenceAPI.scala` `flattenAndStore`):

```lua
local i = 1
while true do
  local n, uv = debug.getupvalue(fn, i)
  if n == nil then break end
  if type(uv) == "function" or type(uv) == "table" then add(uv, name .. "#" .. i) end
  i = i + 1
end
```

I measured what this sweeps up across the whole stdlib: **exactly two** function-valued upvalues,
`next` (already named) and `ipairs_aux`. So the arm is cheap, complete for the singleton case, and
names nothing by hand.

### Why not (i), ffid-symbolic

ffids *are* stable within the pinned build (generated `lj_ffdef.h`; `ERIS_LJ_FINGERPRINT` already
pins the commit) and are even readable from Lua as `builtin#N`. The blocker is reconstruction:
there is **no reverse lookup and none can be built from outside LuaJIT**. Recreating a fast
function needs `fn->c.f` and `fn->c.pc` as well as the ffid; the handlers are `static`
(`#define LJLIB_CF(name) static int lj_cf_##name`, `LJLIB_ASM` likewise — `lj_lib.h:81-82`), and
the pc must point into `G->bcff[…]` at an index only the generated `lj_lib_init_*` arrays know
(see the self-described "Really ugly workaround" `setpc_wrap_aux`, `lib_base.c:685-688`). The only
runtime ffid→object map is "an object that happens to have that ffid" — i.e. an exemplar obtained
by calling the public constructor, which *is* option (ii). So (i) collapses into (ii) unless you
patch LuaJIT to export a table, which the pinned-build discipline argues against.

### The real residue of (B), which neither (i) nor (ii) covers

Two other hidden auxes are **per-call closures carrying state**, so no perms entry can ever name
them:

* `string.gmatch` → `lj_lib_pushcc(L, lj_cf_string_gmatch_aux, FF_string_gmatch_aux, 3)`
  (`lib_string.c:552-556`) with 3 upvalues: subject string, pattern string, and a raw TValue whose
  `u32.lo` is the byte position. (Good news if you ever do this: that position TValue is a double
  whose *bits* are the offset, and `p_number` (`eris_lj.c:403-422`) sends non-integral doubles as
  raw 8 bytes, so it round-trips bit-exactly.)
* `coroutine.wrap` → `lj_lib_pushcc(…, FF_coroutine_wrap_aux, 1)` with the coroutine as upvalue 1
  plus a hand-patched pc (`lib_base.c:643, 680-688`).

These need **option (iii)**: a dedicated tag with a small closed enum
`{IPAIRS_AUX, GMATCH_AUX, WRAP_AUX}`, restored by calling the public constructor
(`ipairs({})`, `string.gmatch(s,p)`, `coroutine.wrap(dummy)`) and then overwriting upvalues via
`lua_setupvalue`. ~80-120 LOC, one wire tag, bounded and low-risk — but it is **not** needed for
ipairs and is **not** what blocks for-in. Treat it as a separate "hidden builtins" item; a thread
holding a live `coroutine.wrap` result or a half-consumed `gmatch` is unpersistable today
regardless of for-in.

---

## Bottom line

* **(B): close it now.** One arm in the host's perms flattener. No C change, no wire bump, verified
  exact cross-process. `for i,v in ipairs(t)` with a yield then works end-to-end — the one for-in
  form that can be made correct today. Add an `m3.lua` case and a line in `serializer/README.md`
  saying the perms builder must walk builtin upvalues.
* **(A): do not close it now.** The proposed patch is implementable (I built it, 39/39 green) but
  it converts a clean refusal into silent, non-deterministic key loss across processes, plus one
  unloadable-save case from a common idiom. Land the honest error message instead, decide
  explicitly whether ITERC's existing same-shape corruption is acceptable, and schedule the
  key-snapshot design as its own milestone.



# KEY CLAIMS
- [high] The proposed (A) fix — store the last key, re-derive with lj_tab_keyindex — is implementable against this pinned build (I ported it onto the current eris_lj.c, built it, and it passes m1/m2/m3 39/39), but it silently skips or duplicates keys when the restore happens in a different process, because g->str.seed is per-VM random (lj_str.c:367, LUAJIT_SECURITY_STRHASH=1) so hash-part traversal order differs in every VM. Measured: a 12-string-key pairs loop lost 5 keys in one process and 3 in another, with no error.
- [high] The stated escape hatch — 'exact whenever the iterated table is a perms entry' — is a same-process artifact. With the iterated table a permanent (never serialized, the host's own table in the new VM), the cross-process resume re-visited keys p8,p9 in one run and p8,p9,p10 in another.
- [high] The patch turns a clean persist-time refusal into a load-time failure for `for k in pairs(t) do t[k] = nil end` over string keys: it checks the node's key is non-nil but not its value, so u_table never emits that key and lj_tab_keyindex returns ~0u at restore. Persist wrote 453 bytes; unpersist failed, even in the same process.
- [high] (B) is closable now with zero C changes: ipairs_aux is a per-VM singleton (ffid 6, lj_ffdef.h:7) reachable from Lua as debug.getupvalue(ipairs,1) or select(1, ipairs({})). With it in perms, a coroutine suspended mid-ipairs persists and resumes exactly, verified in a fresh process. Sweeping function-valued upvalues of every builtin finds exactly two objects — next and ipairs_aux — so one generic arm in the perms flattener is complete for the singleton case.
- [high] Symbolic ffid serialization (option i) cannot be built from outside LuaJIT: reconstructing a fast function needs fn->c.f and fn->c.pc as well as the ffid, the handlers are static (LJLIB_CF/LJLIB_ASM expand to `static int`), and the pc index lives only in generated lj_lib_init_* arrays. The only runtime ffid→object map is a live exemplar, which reduces (i) to (ii). The genuine residue is coroutine.wrap and string.gmatch, whose auxes are per-call closures with state and need a dedicated tag (option iii).

## VERIFICATION
CLAIM: The proposed (A) fix — store the last key, re-derive with lj_tab_keyindex — is implementable against this pinned build (I ported it onto the current eris_lj.c, built it, and it passes m1/m2/m3 39/39), but it silently skips or duplicates keys when the restore happens in a different process, because g->str.seed is per-VM random (lj_str.c:367, LUAJIT_SECURITY_STRHASH=1) so hash-part traversal order differs in every VM. Measured: a 12-string-key pairs loop lost 5 keys in one process and 3 in another, with no error.
VERDICT: confirmed
EVIDENCE: CONFIRMED on the load-bearing point (the (A) fix silently skips/duplicates keys across processes and same-process tests cannot see it), REFUTED on the stated cause (g->str.seed / LUAJIT_SECURITY_STRHASH is irrelevant to traversal order). All evidence below is mine, obtained this session.

1) I ported (A) myself and reproduced the pass. I copied eris_lj.c to a scratchpad build dir and applied the three hunks from docs/research/m3-verification.md:1341-1425 (include lj_tab.h; TAG_KEYINDEX=15; the p_thread control-slot arm; the u_thread lj_tab_keyindex arm) via my own patch script, built it against ../prototype/watchdog/libluajit_stock.a, and ran the suites unchanged: M1 82/82, M2 55/55, M3 39/39. So "implementable, builds, suites green" is true.

2) REAL end-to-end cross-process test (the gold standard). Save side: t with 12 string keys; co = coroutine.create(function() local n=0 for k,v in pairs(t) do n=n+1 coroutine.yield(k) end return "DONE:"..n end); resumed 6 times; eris.persist(perms, {co=co, t=t, seen=seen}) -> 616-byte blob written to disk. Same process restore+resume: ret=DONE:12, 12 visits, 0 missing, 0 duplicated -- perfect, every time. Twenty SEPARATE processes each unpersisted that blob and resumed to completion:
   4/20  DONE:12  MISSING=0 DUP=0                    (correct)
   2/20  DONE:6   MISSING=6 [foxtrot,golf,hotel,india,juliet,kilo]
   1/20  DONE:7   MISSING=5 [golf,hotel,india,juliet,kilo]
   1/20  DONE:8   MISSING=4 ; 2/20 DONE:9 MISSING=3 ; 1/20 DONE:10 MISSING=2 ; 1/20 DONE:11 MISSING=1
   1/20  DONE:13  DUP=1 [lima] ; 2/20 DONE:14 DUP=2 ; 3/20 DONE:15 DUP=3 ; 1/20 DONE:16 DUP=4 ; 1/20 DONE:17 DUP=5
   16 of 20 restores visited the wrong key set with no error, no warning, and a wrong loop count returned by the coroutine itself. The claim's "lost 5 keys in one process and 3 in another" sits inside this distribution; I also measured losses of 6 and duplication up to 5, which the claim did not mention.

3) Independent Lua-level confirmation without any patch: lj_tab.c:602-625 shows lj_tab_next() IS lj_tab_keyindex()+scan, so `next(t,k)` is exactly (A)'s re-derivation. Persisting a plain data table + last key, then resuming with next() in 20 fresh processes: 4 clean, 16 wrong (MISSING up to 5, DUP up to 5); same-process restore always clean.

4) The stated MECHANISM is wrong, and I proved it two ways. lj_tab.h:42 defines `hashstr(t, s) hashmask(t, (s)->sid)` -- LuaJIT indexes string keys into the node array by the interning counter s->sid (lj_obj.h:303,310), NOT by the seed-derived s->hash. g->str.seed (lj_str.c:319,367) only keys the intern/dedup table.
   (a) C probe (built against libluajit_stock.a, dumping the live GCtab): in 3 fresh processes every occupied node satisfied node_index == sid & hmask exactly, while s->hash was uncorrelated with position ("alpha" hash 0x9b68e122 at node 13 in one process, 0xdc67c75a at node 4 in another). asize=0 hmask=15 in all runs; the order is always a rotation of interning order.
   (b) Control probe: leaving the random seed untouched (4 distinct seeds observed: 0x9bcecf44..., 0x1c06490f..., 0x7baca38e..., 0xb85c6eb7...) but pinning only g->str.id/idreseed before the chunk produced a byte-identical traversal order in 4/4 processes. Fixing the sid counter fixes the order; the hash seed has no effect on it.
   The randomness is LUAJIT_SECURITY_STRID=1 (lj_arch.h:758-760, no XCFLAGS override in prototype/watchdog/Makefile): lj_str.c:265-292 assigns s->sid = g->str.id++ and reseeds g->str.id from the PRNG at a random interval < 2^8.

5) Why same-process tests cannot see it: in one VM the key strings already carry their sids, so a rebuilt table lands the same keys on the same nodes and traversal order is preserved (measured: clean in every same-process run). Integer-keyed tables live in the array part and are order-stable in every process (measured), which is exactly why the existing "resumed loop over the REBUILT table sums 1..20 exactly once" check passes.

Working tree left as found: I edited nothing in the repo (serializer/eris_lj.c still mtime 18:57, `make` reported "Nothing to be done"); all probes, the patched copy and its binary lived in the scratchpad, and the probe binaries are deleted.
CORRECTION: The conclusion stands but the cause is misattributed, and that misattribution would send the fix in a useless direction. Hash-part traversal order in this build does not depend on g->str.seed / LUAJIT_SECURITY_STRHASH at all: lj_tab.h:42 places string keys by `hashmask(t, s->sid)`, i.e. by the string-ID counter randomized per VM and re-randomized every <2^8 interned strings by LUAJIT_SECURITY_STRID=1 (lj_str.c:265-292). Pinning the string hash seed, or building with LUAJIT_SECURITY_STRHASH=0, would change nothing -- my pinned-sid control shows the order tracks sid alone. Two further corrections of degree: (i) "order differs in every VM" is too strong -- order is a rotation of interning order and happened to match in 4 of 20 fresh processes (20%), so the corruption is intermittent, which makes it even harder to catch; and (ii) the damage is not only skips -- I measured duplicate visits (up to 5 keys visited twice) about as often as skips, plus a silently wrong iteration count returned by the coroutine. Note also that LUAJIT_SECURITY_STRID=0 would not rescue (A) either: it only makes sids sequential, and the saving and restoring VMs still have different interning histories. Any real fix has to make the resume position independent of node layout (e.g. persist the remaining key set / a stable key order and drive the resumed traversal from that), not try to make the layout reproducible.

## VERIFICATION
CLAIM: The stated escape hatch — 'exact whenever the iterated table is a perms entry' — is a same-process artifact. With the iterated table a permanent (never serialized, the host's own table in the new VM), the cross-process resume re-visited keys p8,p9 in one run and p8,p9,p10 in another.
VERDICT: confirmed
EVIDENCE: CONFIRMED by cross-process probe against the SHIPPED serializer, plus the mechanism in the pinned LuaJIT source.

MECHANISM (source, pinned tree):
- C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/lj_tab.h:42 — `#define hashstr(t, s) hashmask(t, (s)->sid)`. A string key's node slot is its interned string ID masked by t->hmask, NOT a content hash.
- lj_str.c:283-295 (lj_str_alloc) — `s->sid = g->str.id++` with `if (!g->str.idreseed--) { uint64_t r = lj_prng_u64(&g->prng); g->str.id = (StrID)r; ... }`, i.e. a counter reseeded from the OS-seeded PRNG at random intervals (<256 strings). lj_arch.h:753-759 confirms LUAJIT_SECURITY_STRID defaults to 1 and LUAJIT_SECURITY_PRNG to 1 (secure-from-OS), and the serializer Makefile overrides neither.
Consequence: consecutively interned keys get consecutive sids, so a host-built table's `next` order is the SAME cyclic sequence rotated by a per-process random offset. `next(t,k)` after restore continues from k's position in the NEW rotation — keys ahead of k in the new rotation are skipped, keys behind it wrap around and are revisited.

PROBE (mine, scratchpad only; iterated table is a genuine perms entry — registered as perms["HOSTTAB"], built fresh in each process, never in the blob; `rawequal(iterated_table, host_table)` asserted true in the restored coroutine in every run):
Files: .../scratchpad/vperm/{common.lua,save.lua,load.lua,same_process.lua}; blob written to disk and reloaded by separate erislj_test.exe invocations. Two perms targets: a host-built `p1..p12` table and the `string` library table (a real OC-shaped perms entry). Coroutine yields after 6 keys, persisted, resumed in a fresh process.

SAME PROCESS (reproduces the review's permtab.lua): ref order p9,p10,p11,p12,p1..p8; visited(12) identical; "EXACT (== reference order, each key once): true". So the review's observation is real — and is exactly the same-VM artifact the claim names.

CROSS PROCESS, one saved blob, six loads (A's order was p1..p12 / dump,find,match,...):
- ptab: load1 exact; load2 exact; load3 REVISITED [p1]; load4 SKIPPED [p7..p12] (only 6 of 12 visited); load5 REVISITED [p1,p2,p3,p4,p5] (17 visits of 12 keys); load6 SKIPPED [p11,p12].
- string lib: load1 SKIPPED [lower,upper]; load2 SKIPPED 8 of 14 keys [byte,char,len,lower,rep,reverse,sub,upper]; load3 SKIPPED 6; load4 REVISITED [dump,find,match,gmatch,gsub] (19 visits of 14 keys); load5 SKIPPED 5; load6 REVISITED 4.
An earlier round (before I added the identity assertion) gave REVISITED [p2,p3,p4,p5] / [p2,p3] / SKIPPED [p1,p9..p12] across three loads.
Every outcome is predicted exactly by the printed per-process rotation, e.g. load4: B's order p7..p12,p1..p6 puts the control key p6 last, so next(T,"p6") returns nil immediately and the loop ends having silently visited 6 of 12.

So the escape hatch "exact whenever the iterated table is a perms entry" holds only within a single VM. Being a permanent is precisely no protection: the host's table in the new VM is a different object with a different node rotation, and the failure is nondeterministic run to run.
CORRECTION: Three refinements, none of which weaken the claim:
1. The literal key sets in the claim ("re-visited p8,p9 in one run and p8,p9,p10 in another") are run-specific; I did not reproduce those exact sets, and the revisit/skip pattern is a function of the random rotation offset and the yield point. What reproduces is the substance: same blob, same host table, different outcome every process.
2. The claim understates the damage by naming only revisits. SKIPS are the more common and more dangerous mode here (4 of 6 loads on the string table silently omitted 2-8 keys, one ptab load omitted half the table). A revisit is loud (double side effects); a skip is silent.
3. Scope note on which code this bites today: the shipped C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c does NOT contain the review's KEYINDEX fix (no "keyindex" anywhere; BC_ITERN appears only in the frame-walk switch at line 1450), so `for k,v in pairs(t)` still fails to persist at all. My probe therefore used the split form (`local nx,ctl = next,nil`), which the shipped build does accept. The defect thus applies (a) to the split/`next` form on the shipped build right now, and (b) to the review's proposed KEYINDEX fix, which re-derives the index from the last key and so inherits the same `next(t,k)` semantics. Any real fix must encode traversal position independently of the new VM's node layout (e.g. carry the remaining key set, or an index into an order the host can reproduce) rather than relying on the key's position in the restored table.

## VERIFICATION
CLAIM: The patch turns a clean persist-time refusal into a load-time failure for `for k in pairs(t) do t[k] = nil end` over string keys: it checks the node's key is non-nil but not its value, so u_table never emits that key and lj_tab_keyindex returns ~0u at restore. Persist wrote 453 bytes; unpersist failed, even in the same process.
VERDICT: confirmed
EVIDENCE: CONFIRMED, with one scoping correction: "the patch" is not in serializer/eris_lj.c today — it is the proposed TAG_KEYINDEX fix written out in C:/Users/astro/Downloads/OC-LuaJIT/docs/research/m3-verification.md:1341-1420. The shipped eris_lj.c has no keyindex handling at all (TAG_MAX_M3 = TAG_UPVALOPEN = 13, eris_lj.c:124-126; no LJ_KEYINDEX anywhere), and I verified against the live erislj_test.exe that `for k in pairs(t)` in a suspended coroutine still refuses cleanly at persist time: "eris-lj: cannot persist light userdata by value (process-local pointer); put it in the perms table". So the "before" half of the claim is real.

The "after" half is also real. I applied the doc's three hunks verbatim to a scratchpad copy, built it against the pinned LuaJIT (gcc, clean, no warnings), and ran the claimed idiom:

  == A: for k in pairs(t) do t[k]=nil end  (string keys, t={k1..k6})
     PERSIST OK: 492 bytes
     >>> UNPERSIST FAILED: eris-lj: the key a for-in loop was suspended on is no longer in its table
  == D: minimal 2-key delete-current  -> persist 446B, same unpersist failure

Same process, same perms table (flattened _G, as in tests/m3.lua's build_perms). A blob that writes successfully and cannot be read back, exactly as claimed.

MECHANISM, isolated by four discriminating cases on the patched build:
  delete-current     : persist 440B ; unpersist FAIL
  delete-other       : persist 463B ; unpersist OK
  delete-then-readd  : persist 461B ; unpersist OK
  value=false (live) : persist 443B ; unpersist OK
Only nil-ing the key the loop is currently parked on breaks it, which pins the cause to the node's VALUE, not its key. The claim's diagnosis is right: hunk (b) guards only `if (tvisnil(&n->key))` before `copyTV(L, L->top, (TValue *)&n->key)`. `t[k] = nil` leaves LuaJIT's node in place with the key intact and the value nil — that tombstone is precisely why lj_tab_keyindex (lj_tab.c:573-598) still finds it in the live table and why deleting during a for-in is legal Lua. But the table is rebuilt from p_literaltable's `lua_next` walk (eris_lj.c:473-484), and lua_next cannot emit a nil-valued pair, so the restored table has no such node, lj_tab_keyindex returns ~0u, and hunk (c)'s `if (idx == ~0u) luaL_error(...)` fires.

One wording fix to the claim: the omission is on the WRITE side (p_literaltable / lua_next), not in u_table — u_table is the reader and only rejects an explicit nil value as malformed (eris_lj.c:1237-1239). Byte count is incidental and table-dependent; I measured 440-492, not 453.

SCOPE IS WIDER THAN "string keys": every hash-part key type fails — sparse integers (439B), floats (463B), and a realistic `for name in pairs(registry) do registry[name] = nil end` sweep (489B) all fail identically. The dense-array case survives only by luck: lj_tab_keyindex returns k+1 for any int < asize without ever consulting the value, so it never notices the deletion. Push those same integers into the hash part and it fails too.

The M3 suite does not catch this: on the patched build m1 82/82, m2 55/55, m3 39/39 all still pass. tests/m3.lua contains no pairs-in-a-coroutine case at all (its only loop-under-yield test is a numeric for).

Files: C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c (unmodified — sha1 2d9bc78e86b52333fd622d51838b6049de21bffd, git status identical to session start); patch text at C:/Users/astro/Downloads/OC-LuaJIT/docs/research/m3-verification.md:1341-1420. Probe binaries deleted; all probe sources kept in the scratchpad only.
CORRECTION: Verdict is confirmed, so this is a fix rather than a correction — and I validated it rather than just proposing it. Erroring at load is the wrong response to ~0u: the right move is to reinstate the tombstone the live table had. In hunk (c), replace the `if (idx == ~0u) luaL_error(...)` with a set-then-clear through the raw API (which gets the write barrier right, unlike a bare lj_tab_set + setnilV), then re-derive:

  idx = lj_tab_keyindex(tabV(st), L->top - 1);
  if (idx == ~0u) {
    settabV(L, L->top, tabV(st)); L->top++;   /* key tbl */
    lua_pushvalue(L, -2); lua_pushboolean(L, 1); lua_rawset(L, -3);
    lua_pushvalue(L, -2); lua_pushnil(L);     lua_rawset(L, -3);
    lua_pop(L, 1);                            /* key */
    stack = tvref(co->stack); st = stack + (i - 1);   /* rawset can realloc */
    idx = lj_tab_keyindex(tabV(st), L->top - 1);
    if (idx == ~0u) luaL_error(L, "eris-lj: cannot re-derive the for-in traversal index");
  }

The first rawset creates the node with a barrier; the second clears the value and leaves the node standing, which is exactly the state `t[k] = nil` produced in the original. Measured on a build of this: the claimed repro now persists and unpersists, the restored loop runs to completion visiting all six keys exactly once with no duplicates, nested pairs with an outer delete round-trips, and m1 82/82, m2 55/55, m3 39/39 still pass. Note that hunk (b)'s existing `tvisnil(&n->key)` guard must stay — it rejects a genuinely empty node — and the array branch should get the same treatment for the sparse-int case. Worth adding the four discriminator cases (delete-current, delete-other, delete-then-readd, sparse-int) to tests/m3.lua alongside the patch, since the suite is green either way.

