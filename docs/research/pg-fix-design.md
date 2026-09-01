# A correct fix exists. It is the replay iterator (A), and it needs exactly one bytecode edit.

**Verdict: recommend design (A′) — "replay iterator + despecialisation".** I proved both halves with probes. (B) collapses into (A) and is strictly worse. (C) is real but narrower and shakier than it looks. (D) is dead.

Working tree untouched (I wrote nothing under `C:/Users/astro/Downloads/OC-LuaJIT`; `serializer/eris_lj.c` sha1 `651b016995be8552ae3cc4967c07aae0469c45e3`, unchanged). All probes live in
`C:\Users\astro\AppData\Local\Temp\claude\C--Users-astro-Downloads-OC-LuaJIT\b355bc57-105f-4f62-a48e-26f24e7e01db\scratchpad\forin\`.

---

## 1. The two source facts that settle the ARM's questions

### Q: "Does BC_ITERN de-specialise at runtime? Is there a `->vmeta_itern`?"

**No, and no.** `BC_ITERN` (`C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/vm_x64.dasc:4306-4366`) performs **zero validation**:

```
|  mov TAB:RB, [BASE+RA*8-16]     // state slot
|  cleartp TAB:RB                 // <-- masking, NOT a check
|  mov RCd, [BASE+RA*8-8]         // low 32 bits of ctl, used as a raw index
```
`cleartp` is `shl reg,17; shr reg,17` (`vm_x64.dasc:259`) — it strips the type tag rather than testing it. It never reads the func slot at all. `grep -rn vmeta_itern` over the whole tree returns nothing. So **installing a replacement iterator triple while the opcode is still ITERN is memory-unsafe**: the VM would read `asize`/`array`/`hmask`/`node` out of whatever pointer bits sit in the state slot.

All despecialisation lives in `BC_ISNEXT` (`vm_x64.dasc:4370-4402`), which runs **once at loop entry** and is therefore never re-executed by a resumed loop. **Bytecode surgery is mandatory**, not optional.

### Q: "Does `lj_bcwrite` normalise ITERN back to ITERC?"

**No.** `bcwrite_bytecode` (`.../lj_bcwrite.c:292-319`) unpatches only `IFORL/IITERL/ILOOP/JFORI` and `JFORL/JITERL/JLOOP`. `ITERN` and `ISNEXT` are what the *parser* emits (`lj_parse.c:2921, 2930`), so a restored proto comes back specialised. A proto that was already despecialised does round-trip as `ITERC`, since bcwrite copies the opcode byte verbatim.

### The fact that makes the edit safe

`ITERN` and `ITERC` are emitted with **identical operands** — `bcemit_ABC(fs, isnext ? BC_ITERN : BC_ITERC, base, nvars-3+1, 2+1)` (`lj_parse.c:2930`) — as are `ISNEXT`/`JMP` (`lj_parse.c:2921`). So despecialisation is a pure opcode-byte swap, and LuaJIT already ships the exact routine, `blacklist_pc` (`lj_trace.c:380-388`):

```c
if (bc_op(*pc) == BC_ITERN) {
  setbc_op(pc, BC_ITERC);
  setbc_op(pc+1+bc_j(pc[1]), BC_JMP);   /* the ISNEXT at the loop head */
}
```

It runs on **live, mid-execution loops**, and correctness for a thread parked on a keyindex control var is guaranteed by `lj_tab_keyindex`'s passthrough at `lj_tab.c:594` (`/* Despecialized ITERN while running. */`). This is not a hack we invent; it is a supported VM state.

---

## 2. The design (A′)

Everything the resumed loop needs is expressible in types eris-lj **already persists**, which is what makes this small.

**Replay triple**, replacing the loop's hidden `(func, state, ctl)` at slots `RA-3, RA-2, RA-1`:

| slot | new content | persists as |
|---|---|---|
| `RA-3` func | one C function `elj_forin_replay` | new tag, no payload (precedent: the `cont_addr[]` symbol table at `eris_lj.c:1461-1520`) |
| `RA-2` state | `{ [1]=t, [2]=keys(1..n), [3]=pos(key→i) }` — a plain table | existing `TAG_TABLE` |
| `RA-1` ctl | `nil` at install, thereafter the previous key | existing scalar/`TAG_REF` |

```c
/* f(s, ctl) -> key, value */
i = (ctl == nil) ? 0 : s.pos[ctl];
repeat i = i+1; k = s.keys[i]; if k == nil then return nil end
until rawget(s.t, k) ~= nil          /* skip keys deleted mid-loop */
return k, rawget(s.t, k)             /* LIVE value, raw, like next() */
```

Three properties fall out for free:
* **Values stay live.** The loop reads `t` at iteration time, so a body that mutates `t[k]` later in the loop sees the new value.
* **`for k in pairs(t) do t[k] = nil end` just works** — the audit's Case B, which the keyindex patch turned into an *unloadable save*. We never need the parked key to still exist.
* **A second save mid-replay needs no new code**: state is a table, ctl is a key, func has a tag.

**Locating the loop** (persist side): the control slot is self-identifying (`u32.hi == LJ_KEYINDEX`, `lj_obj.h:288`). Slot `i` ⇒ `RA = i - frame_base + 1`. Then scan the owning frame's proto for the `BC_ITERN` whose loop body (`[ITERL_target, ITERN_pos)`) contains that frame's pc. At most one match: two loops sharing a base register cannot nest, and sequential loops have disjoint bodies. Every Lua frame's pc is already recoverable — `p_thread` records each frame's bcofs relative to its *caller's* proto (`eris_lj.c:800-803`), so frame *k*'s own pc is frame *k−1*'s recorded return pc.

**Flush traces first.** Non-negotiable, and I measured why (§3, probe 5): when a trace starts at the ITERN, `trace_stop` overwrites it with `BCINS_AD(BC_JLOOP, J->cur.snap[0].nslots, traceno)` (`lj_trace.c:522-526`) — **`bc_a` of that JLOOP is a slot count, not the loop base**, and the following `ITERL` may be `JITERL` whose `D` field is a trace number, not a jump offset. One call to `luaJIT_setmode(L, 0, LUAJIT_MODE_FLUSH|LUAJIT_MODE_ENGINE)` (or `lj_trace_flushall`, `lj_trace.c:276`) runs `trace_unpatch` over every root trace and restores plain `ITERN`/`ITERL`.

**Patch at restore, not at persist.** The blob carries the ITERN bcofs; the reader patches. This (a) leaves the saving VM completely unmutated, and (b) covers the case persist-side patching cannot: a closure that came from **perms**, whose proto is never dumped and is the host's own proto in the new VM — still `ITERN`, and would execute our triple as raw memory. The restore must also flush traces before patching a perms proto, and must validate `bc_op(bc[ofs]) ∈ {ITERN, ITERC}` and `bc_a == RA` before writing. Idempotent, so two threads suspended in the same loop are fine.

**The arm you must not omit.** `predict_next` (`lj_parse.c:2865`) is a syntactic name match, so `local nx = next; for k,v in nx, t do` compiles to `ITERC` + real `next` with a **plain key** in the control slot. That form persists *today* and silently corrupts cross-process (the earlier audit measured it). Critically, **a `pairs` loop in a JIT-blacklisted proto has exactly this shape**, because `blacklist_pc` already despecialised it. So closing the `pairs` gap requires the same arm: for every enclosing loop of every Lua frame's pc, if the func slot is a `GCfunc` with `ffid == FF_next_N` (`lj_bc.h:240`) and the state slot is a table, convert it to a replay triple as well — with **no bytecode edit at all**, since it is already `ITERC`. Remaining keys come from `lj_tab_keyindex(t, ctlkey)` then the same array/node walk.

---

## 3. Feasibility evidence — probes I built and ran

**Probe A — VM surgery on a live loop.** `...\scratchpad\forin\forin.c`, built against `prototype/watchdog/libluajit_stock.a`. A C function called from inside a running `pairs` body locates the ITERN, despecialises it, snapshots remaining keys, and installs the replay triple. All five cases pass:

| case | result |
|---|---|
| 12 string keys, hijack after 4, then `t.k12='MUTATED'` and `t.k11=nil` | 11 visits, 0 dup, 0 missing, **`k12=MUTATED` observed** |
| `for k in pairs(t) do t[k]=nil end` (the keyindex patch's unloadable-save case) | visited 8 of 8, 0 leftover |
| mixed array + hash part | 7 visits over 7 keys |
| **re-entering the patched proto with real `pairs()`** | 7 / 7 / 7 — despecialisation does not break later runs |
| **JIT-compiled loop (JLOOP)** | fails without a flush (`RA=8`, refused); after `lj_trace_flushall` → `RA=6`, correct, 9 / 9 |

**Probe B — cross-process, the experiment that killed the keyindex design.** `rcommon.lua` / `rsave.lua` / `rload.lua`, run through the **unmodified shipped `erislj_test.exe`** (the replay iterator written in Lua so the current serializer can carry it). One blob, 6 keys consumed, 14-key string table, restored in **20 fresh processes**:

```
20 host ret=DONE:14 visits=14/14 DUP=[] MISSING=[]  OK
20 own  ret=DONE:14 visits=14/14 DUP=[] MISSING=[]  OK
```

`host` is the case the earlier audit reported as the keyindex design's worst: the iterated table is a **perms entry**, rebuilt fresh in the restoring VM. Keyindex scored 4/20 (own) and 0/6 exact (host). Replay: **20/20 and 20/20**.

---

## 4. Concrete patch shape, wire format, cost

`ERIS_LJ_FORMAT` 1 → 2 (`eris_lj.h:29`). Two new tags after `TAG_UPVALOPEN = 13` (14 is reserved for userdata):

```
TAG_FORIN_REPLAY = 15   /* thread slots only, replaces the ctl slot */
    uleb  itern_bcofs   /* 0 = already ITERC (the next/blacklisted form) */
    uleb  n             /* remaining key count */
    n x   <value>       /* the remaining keys, in the SAVING VM's order */
TAG_FORIN_ITER   = 16   /* the replay C function; no payload */
```

Changes in `C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c`:

* `p_thread` (~line 730): call the trace flush; add a pre-pass building `(frame_base, proto, pc)` per Lua frame **before** the slot loop at line 769 (today the frame walk runs after it — this is the one structural refactor).
* Slot loop: when a slot is a keyindex, emit `TAG_FORIN_REPLAY` instead of falling into the refusal at `eris_lj.c:929-937`; walk `t->array[idx..asize)` then `t->node[idx-asize..hmask]` collecting non-nil entries. Also scan each frame's enclosing loops for the `ITERC`+`FF_next_N` shape.
* `p_function`: recognise `elj_forin_replay` by C pointer identity → `TAG_FORIN_ITER`.
* `u_thread` pass 1: build `keys`/`pos`/state, write func+state into slots `i-2`/`i-1`, `nil` into slot `i`, record `(slot, bcofs)`.
* `u_thread` pass 3: after protos are bound, flush traces, validate the opcode/`bc_a` at `bcofs`, then `setbc_op(ITERC)` + `setbc_op(ISNEXT→JMP)`.

**Cost.** ~250–350 LOC. One new LuaJIT header dependency (`lj_bc.h`; `lj_tab.h`/`lj_jit.h` if you use the internal flush). Wire: O(remaining keys) — a 1000-entry table yielded at key 1 costs ~1000 key records (strings dedupe by `TAG_REF`). Runtime: the affected loop is permanently `ITERC` in the restoring VM and un-traceable for the remainder of that one execution (the JIT will not trace through a C iterator); a *later* entry to the same loop runs `ITERC` + real `next`, which `recff_next` does trace. Persist-side: one trace flush per `persist()` call.

---

## 5. How to test it — this is the part that has to be right

Same-process tests **provably cannot** see this bug class: in one VM the key strings already carry their sids, so a rebuilt table lands them on the same nodes. Every test below must therefore fork.

1. **Fresh process per restore, N ≥ 20, require N/N.** The failure is *intermittent* — keyindex was correct in 4 of 20 runs. One green fresh-process run proves nothing.
2. **Assert the exact key multiset**, not the count: `DUP=[]` and `MISSING=[]` against the live table, plus the coroutine's own returned iteration count. Both skips and duplicates occur, and skips are silent.
3. **Include the perms-table case.** Register the iterated table as a permanent, rebuild it fresh in the loader, and `assert(rawequal(...))`. This is where keyindex failed 6/6, and it is OC's common shape (component lists, sandboxed globals).
4. **Make divergence deterministic instead of hoping for it — this is the highest-value item.** A string key's node slot is `hashmask(t, s->sid)` (`lj_tab.h:42`), so interning K throwaway strings *before* unpersisting rotates the whole hash part by K. Zero C changes, controlled from Lua. I validated the hook (`...\scratchpad\forin\cload2.lua`):
   ```
   K=0 → 1..8,other,name     K=2 → 1..8,name,other
   K=4 → 1..8,other,name     K=6 → 1..8,name,other
   ```
   Sweep `K = 0..63` (one fresh process each) and require **every** K to pass. That converts a 20 %-flaky bug into a deterministic matrix. Still needs a fresh process — the pad must be interned before the blob's keys are.
5. **Negative control.** Run the same harness against a build carrying the naive keyindex patch and *require it to fail*. Without this the suite has no demonstrated power to detect the defect it exists for.
6. **Case matrix:** string keys; keys deleted mid-loop (`t[k]=nil`, delete-current / delete-other / delete-then-readd); values mutated after the yield; `false` values; mixed array+hash; nested `pairs` loops; two sequential loops sharing a base register; a loop inside a **perms** closure (unserialized proto); a JIT-warmed loop (≥400 iterations before yielding, to force the JLOOP path); **save → restore → save → restore** twice through the replay state; and `local nx = next; for k,v in nx,t`.
7. Harness plumbing: `test_main.c` ignores `argv[2]` — either pass mode/`K` via `os.getenv` (as my probes do) or forward extra argv.

---

## 6. The other options

**(B) visited-set + skip — reject.** The skip has to live in an iterator, ITERN has no iterator, so B needs the same despecialisation as A and is not cheaper. It cannot live in the loop body (we do not control user code). Its one advantage is wire size when the loop yields late (O(consumed) vs O(remaining)); its cost is that the remainder is then visited in the *restoring* VM's order, so any residual bug is again non-deterministic and untestable. Keep it as an encoding variant inside A′ if profiling ever demands it, never as the mechanism.

**(C) accept array-only tables — real, but narrower and shakier than it looks. I verified it myself.** Nine integer-keyed shapes persisted and restored in 20 fresh processes (`csave.lua`/`cload.lua`): dense, constructor, sparse, holes, zero-based, 300-element, descending-insert, and pure hash-part integers — **20/20 byte-identical order for all of them**. (Integer keys hash by value bits via `hashnum`, not by `sid`, so they are deterministic.) The mixed table `1..8 + name,other` split **7/20 vs 13/20** — string keys, as expected.

Two caveats that must not be glossed:
* The soundness condition is *not* "integer keys". It is "**no live keys in the hash part**". With a live hash part, a control index inside the array part still forces the entire hash phase, and any integer key that landed in the array in VM1 but the hash in VM2 gets **duplicated**.
* Even the pure-array case depends on the restored table's `asize`, which `u_table` (`eris_lj.c:1259`) does not control — it just calls `lua_newtable`. If VM2 leaves some integer key in the hash part, index `i` lands in the hash phase and duplicates keys `< i`. It happened not to in 20/20 runs, but that is a heuristic, not a proof. To make it sound, carry the saved `asize` as a `lua_createtable` hint in the table record — a separate wire change that also speeds up restore.

So (C) is a defensible ~30 LOC *interim* that unblocks `for i,v in pairs(array)`, but only with the "no live hash keys" gate **and** the asize hint. It leaves an arbitrary refusal boundary and does nothing for the `ITERC`/`next` silent corruption. If you are going to build the asize hint anyway, build (A′) and keep the array index as an O(1) encoding variant of the same record.

**(D) control sid assignment at restore — dead.** Three independent kills: (i) non-string keys hash by **pointer** (`hashgcref` → `hashlohi` on the address bits, `lj_tab.h:49-52`), which no amount of interning control can reproduce; (ii) forcing `g->str.id` to the saving VM's values would collide with the restoring VM's own strings, and LuaJIT's chained-scatter invariant requires every key to be reachable from its own main position, so you cannot place keys at chosen indices anyway; (iii) it means disabling `LUAJIT_SECURITY_STRID` globally, which exists precisely to randomise this. The correction already recorded in `docs/research/fu-forin-gap.md` says the same thing and it holds.

---

## 7. What I have *not* proven

I proved the two halves separately: the VM surgery in-process (probe A, 5 cases including JIT-compiled), and the replay data cross-process through the shipped serializer (probe B, 20/20 including the perms case). I did **not** build the full patch into `eris_lj.c` and run *that* cross-process — I was asked not to edit the file, and the frame/slot pre-pass refactor is the one genuinely fiddly part. The residual risk is concentrated there (slot→frame attribution for non-innermost frames, and the deferred bcofs patch in pass 3), not in the mechanism. Budget the first day of implementation for the pre-pass and stand up the fresh-process sweep from §5 before writing any of the persist side.

# KEY CLAIMS
- [high] BC_ITERN performs zero validation — `cleartp` (vm_x64.dasc:259) masks the type tag rather than testing it, it never reads the func slot, and no `vmeta_itern` exists anywhere in the tree — so a replacement iterator triple is memory-unsafe until the opcode is changed. But the change is a two-instruction in-place patch that LuaJIT itself already performs on running loops (`blacklist_pc`, lj_trace.c:380-388), and ITERN/ITERC plus ISNEXT/JMP are emitted with identical operands (lj_parse.c:2921,2930).
- [high] The replay design is correct cross-process where the keyindex design is not. One blob, 14 string keys, 6 consumed, restored in 20 fresh processes: 20/20 exact (0 dup, 0 missing) both when the iterated table is serialized in the blob and when it is a PERMS entry rebuilt fresh in the loader. The keyindex design scored 4/20 and 0/6 on the same experiment.
- [high] Persist must flush JIT traces before locating the loop. When a trace starts at the ITERN, trace_stop overwrites it with BCINS_AD(BC_JLOOP, snap[0].nslots, traceno) (lj_trace.c:522-526), so bc_a is a slot count rather than the loop base, and the following ITERL may be JITERL whose D field is a trace number rather than a jump offset. Measured: my probe read RA=8 instead of 6 and refused; after lj_trace_flushall it read RA=6 and completed correctly.
- [high] The pairs gap is not closed without also handling the ITERC + real-`next` form. predict_next is a syntactic name match (lj_parse.c:2865), and blacklist_pc permanently despecialises hot-but-untraceable pairs loops to ITERC, so such a loop's control slot holds a plain key with no keyindex marker. That form persists today and silently corrupts across processes. It needs the same replay treatment but no bytecode edit at all.

## VERIFICATION
CLAIM: BC_ITERN performs zero validation — `cleartp` (vm_x64.dasc:259) masks the type tag rather than testing it, it never reads the func slot, and no `vmeta_itern` exists anywhere in the tree — so a replacement iterator triple is memory-unsafe until the opcode is changed. But the change is a two-instruction in-place patch that LuaJIT itself already performs on running loops (`blacklist_pc`, lj_trace.c:380-388), and ITERN/ITERC plus ISNEXT/JMP are emitted with identical operands (lj_parse.c:2921,2930).
VERDICT: confirmed
EVIDENCE: Verified against the exact pinned tree the serializer links (C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit @ 1ee778a4, libluajit_stock.a).

TEXTUAL — all five sub-claims check out at the cited lines:

1. vm_x64.dasc:259 is literally `|.macro cleartp, reg; shl reg, 17; shr reg, 17; .endmacro` — a shl/shr pair that discards the 17-bit type tag. No test, no branch.

2. The BC_ITERN body (vm_x64.dasc, `case BC_ITERN:` / `->vm_IITERN:`) touches exactly two slots:
   `mov TAB:RB, [BASE+RA*8-16]` then `cleartp TAB:RB`   (state, untyped)
   `mov RCd, [BASE+RA*8-8]`                              (control, low 32 bits only, tag ignored)
   The func slot `[BASE+RA*8-24]` is never referenced. All four guards — `checkfunc`, `checktptp LJ_TTAB`, nil-control, `ffid == FF_next_N` — live in BC_ISNEXT, i.e. at loop *entry* only, never on the resume path.

3. `grep -rn vmeta_itern` over the entire repo: 0 hits.

4. lj_trace.c:380-388 `blacklist_pc` is exactly two `setbc_op` calls (383, 384): ITERN→ITERC and `pc+1+bc_j(pc[1])`→JMP.

5. lj_parse.c:2921 `bcemit_AJ(fs, isnext ? BC_ISNEXT : BC_JMP, base, NO_JMP)` and :2930 `bcemit_ABC(fs, isnext ? BC_ITERN : BC_ITERC, base, nvars-3+1, 2+1)` — the operand expressions are shared verbatim; only the opcode moves with the ternary.

Corroborating find the claim did not cite: lj_tab.c:594 in lj_tab_keyindex has `if (key->u32.hi == LJ_KEYINDEX) /* Despecialized ITERN while running. */ return key->u32.lo;` — upstream built a dedicated recovery branch for precisely the mid-flight patch.

EMPIRICAL — probe at C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/iternprobe/itern_probe.c, linked against libluajit_stock.a, one process per mode, run twice (JIT off and JIT on — identical outcomes). Suspends a coroutine two yields into `for k,v in pairs(t)`, locates the LJ_KEYINDEX control slot by scanning the thread stack, then meddles:

- Confirmed blacklist_pc's target arithmetic at runtime: `itern + 1 + bc_j(itern[1])` resolved to bytecode index 4 == the ISNEXT. The "two instructions" really are ITERN and ISNEXT.
- ignorefunc (replace ONLY the func slot with a Lua closure, no patch): closure never called; loop produced the full unaltered 8-key traversal. Option (A) with no bytecode surgery is silently ignored — exactly as claimed.
- unsafe (func=closure, state=nil, ctl=nil, no patch): SEGFAULT, exit 139.
- unsafeobj (state = a GCfunc, no patch): no crash — silently truncated and reported "finished cleanly". A GCfunc read as a GCtab, including a wild deref of whatever 8 bytes sat at the `node` offset. Silent corruption, strictly worse than the segfault.
- patched (same replacement triple + the two setbc_op): correct. VISITED = "key1 key2 REPL_A REPL_B REPL_C" — the replacement closure ran and the loop terminated on its nil return.
- patchonly (patch applied, original next/table/keyindex triple left alone): full correct 8-key traversal, confirming the lj_tab.c:594 in-flight despecialization path.

Incidental corroboration of the surrounding context: each process reported a different starting key (key1/key5/key6/key7), the per-process node-order rotation described in docs/research/fu-forin-gap.md.

Both halves hold: a replacement iterator triple is genuinely memory-unsafe (and can fail silently) under an unmodified ITERN, and the two-instruction in-place patch is sufficient, is what LuaJIT itself does, and works on an already-running loop.
CORRECTION: Two refinements, neither of which changes the conclusion:

1. "BC_ITERN performs zero validation" is overstated as literally written. ITERN does range-check the traversal index: `cmp RCd, TMPRd; jae >5` against asize, then `sub RCd, TMPRd; cmp RCd, TAB:RB->hmask; ja <3` to end the loop. So an out-of-range index is bounded, not a wild access. But those bounds are loaded *through* the unvalidated state pointer (`TAB:RB->asize`, `TAB:RB->hmask`), so the check is worthless the moment the state slot is not a real table — which is exactly what the unsafeobj run demonstrated. The precise statement is "zero *type* validation"; the memory-safety conclusion is unaffected, and if anything the bounds check makes things worse by converting some type confusions into silent wrong answers instead of crashes.

2. Design note for the restore path, not a defect in the claim: the patch mutates the shared GCproto, so it de-optimizes that loop for every closure of that prototype, process-wide and permanently (same property blacklist_pc has, and LuaJIT accepts it). Also, blacklist_pc's ITERN branch is guarded on `bc_op(*pc) == BC_ITERN`, so it is not idempotent — a second call falls into the else branch and rewrites the opcode as a loop instruction. The restore path should issue the two setbc_op itself under its own `bc_op == BC_ITERN` guard rather than calling blacklist_pc.

## VERIFICATION
CLAIM: The replay design is correct cross-process where the keyindex design is not. One blob, 14 string keys, 6 consumed, restored in 20 fresh processes: 20/20 exact (0 dup, 0 missing) both when the iterated table is serialized in the blob and when it is a PERMS entry rebuilt fresh in the loader. The keyindex design scored 4/20 and 0/6 on the same experiment.
VERDICT: confirmed
EVIDENCE: I could not refute the load-bearing claim. I rebuilt the shipped serializer clean and re-ran the experiment from scratch with my own probes and my own 14 key names (deliberately not the NATO names the earlier probe used), in C:/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b355bc57-105f-4f62-a48e-26f24e7e01db/scratchpad/vfy/ (vcommon.lua, vsave.lua, vload.lua, vksave.lua, vkload.lua, vstress_save.lua, vstress_load.lua, vresave.lua, vload2.lua).

SETUP. Forced rebuild of C:/Users/astro/Downloads/OC-LuaJIT/serializer/eris_lj.c (md5 7469c7a2d0a16229be50a24c92d72bfb, unmodified) at -O2 -Wall -Wextra, zero warnings; harness reports format 1, i.e. no keyindex support. Sanity gate inside vsave.lua: a coroutine suspended in a real `for k,v in pairs(t)` is still refused -- "eris-lj: cannot persist a thread suspended inside a generic for-in loop over pairs()/next". So the gap is genuinely open and the replay case is going through the shipped code path unaided.

ONE BLOB, FOUR LOOPS, 14 STRING KEYS, 6 CONSUMED. R_own = replay iterator over a table serialized in the blob; R_host = replay iterator over a PERMS entry rebuilt fresh by the loader; N_own / N_host = the same shape driven by `local nx = next; for k,v in nx,t,nil` (ITERC), which resumes from the LAST KEY against the live layout -- exactly the semantics the keyindex design restores. All four in one blob so every case sees the identical process.

RESULT, ROUND 1 (20 fresh processes):
  R_own  20/20 EXACT (0 dup, 0 missing, ret DONE:14)
  R_host 20/20 EXACT
  N_own   1/20, N_host 1/20 -- up to 8 keys skipped (cusp,girder,marlin,plinth,ratchet,tandem,thistle,vellum), up to 5 duplicated (flange,quark,sprocket,wobble,zeta)
Non-vacuity check: 19 of the 20 loaders printed a rotated pairs() order vs the save process; the single N-case that scored EXACT (proc 17) is the one whose rotation happened to match the save process. So the harness really is seeing the per-VM string-id rotation.

RESULT, ROUND 2 (fresh save process, save-order rotated to "tandem vellum plinth ...", 20 more fresh loaders): R_own 20/20, R_host 20/20, N_own 0/20, N_host 0/20, 20/20 loaders rotated. 80 loop-completions total on the replay side, zero dup, zero missing.

KEYINDEX SIDE, MEASURED NOT ASSUMED. Ran the actual keyindex-patched build (scratchpad/vkey2/vkey2.exe -- TAG_KEYINDEX=15, lj_tab_keyindex at u_thread) on real `for k,v in pairs(t)` loops over the same two tables, same 14 keys, same 6 consumed, 20 fresh processes: K_own 1/20 EXACT, K_host 1/20 EXACT. Failures ranged from 7/14 visits (7 keys silently dropped) to 19/14 (5 duplicated), all with no error.

EXTRA ATTEMPTS TO BREAK REPLAY (all beyond the claim, all pass):
  - mixed key shapes (array 1..5 + 5 string hash keys + 4 sparse numeric hash keys + true/false + 1.5): 12/12 EXACT.
  - table-valued (pointer-hashed) keys, 10 of them: 12/12 EXACT.
  - delete-as-you-go over a PERMS table (`for k in ... do t[k]=nil end`) -- the idiom that made the keyindex patch produce a blob that persists but cannot be loaded: replay persisted, loaded, and visited all 14 keys exactly once in 12/12 processes.
  - save -> load -> advance 3 -> re-save -> load, across three processes with three different rotations: 12/12 EXACT both cases. The replay state is itself re-persistable.

SCOPE LIMITS I want on the record (they bound the claim, they do not contradict it):
  1. This validates the DATA half only, and in Lua. Untouched: extracting the remaining key sequence from t->asize/t->node at persist time, installing synthetic func/state/control slots, and the BC_ITERN -> BC_ITERC prototype patch with the JLOOP unpatch dance. That is where the JIT interaction lives.
  2. In the PERMS case exactness assumes the loader rebuilds the same key set. A snapshot list tolerates keys the host removed (my iterator skips nil values) but can never visit keys the host ADDED between save and load. Inherent to any snapshot design; worth adopting deliberately rather than by accident.
  3. In the delete-as-you-go perms run, 6 entries were left in the table after the loop finished -- that is the pre-save deletions being lost because a perms table is not serialized, a property of perms, not of replay. The visit sequence was still exact.

Working tree left exactly as found: `git status --porcelain` identical to session start, eris_lj.c md5 unchanged, M1 82/82, M2 55/55, M3 52/52.
CORRECTION: Only the comparison numbers for the keyindex design are off. The claim says keyindex "scored 4/20 and 0/6 on the same experiment"; on my key set it scored 1/20 for the in-blob table and 1/20 for the perms table (not 4/20 and 0/6). The exact hit rate is just the chance that a loader's per-process string-id rotation coincides with the save process's, so it moves with the key names and is not a stable figure -- it should be quoted as "1-4 of 20, and the hits are the processes whose rotation happened to match" rather than as a fixed score. Also, the parenthetical framing that the perms case is where keyindex "failed completely" is slightly too strong: in my run the perms and in-blob cases failed identically (same dup/missing sets in every one of the 20 processes), because the divergence comes from the loader VM's node layout either way, not from whether the table travelled in the blob. Everything else in the claim held, including the headline 20/20 for both cases, which I reproduced twice with independent save processes (80 clean loop-completions, 0 dup, 0 missing).

