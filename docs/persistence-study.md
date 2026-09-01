# LuaJIT full-VM persistence: feasibility study

*Completed 2026-09-01. Five research arms over the pinned LuaJIT tree (`1ee778a4`, v2.1, GC64), Eris sources, and OC's persistence machinery, with adversarial verification. This supersedes the "persistence is impossible" verdict of [feasibility.md §2](feasibility.md) with a sharper claim: porting **Eris as-is** is impossible; implementing an **Eris-API-compatible serializer against our pinned LuaJIT build** is feasible, one-author-scale, and has no structural blocker.*

## Verdict

**GO, with eyes open.** Every "impossible" statement on record dissolves under inspection into either (a) a true statement about *reusing existing code/formats* or (b) a maintenance-scope decision. Eris issue #4 (read in full) raised exactly three points — PUC-internals dependence, then-unknown coroutine layout, re-jitting after restore — and closed on resourcing ("you'd probably be on your own"), not impossibility. Mike Pall's statements are consistent: Pluto *cannot be reused* (true), a suspended coroutine "could be serialized with some effort" (2008), and `coroutine.clone` would be "theoretically possible [but] difficult under all circumstances" (issue #612, 2020) — and our OC constraints delete precisely the difficult circumstances (C-frame suspends, cdata, cross-version formats, mid-trace state).

## Why it's tractable: the mechanism, source-verified

**A suspended LuaJIT coroutine is pure Lua-stack state.** `coroutine.yield` sets `L->cframe = NULL` and `L->status = LUA_YIELD` (verified in both the ASM fast function and `lua_yield`); `cframe == NULL` is a *checked precondition* of both resume paths. The C stack is fully unwound at yield. A suspended stack can provably never contain an interior live-C frame — both yield paths refuse unless the top C frame is the resume frame, which no longer exists after yield.

**Frame links decode into three symbolic forms** (plus one amendment found by verification):

1. `FRAME_LUA` → `(proto, bytecode offset)` — like Eris's savedpc trick.
2. Delta frames (`VARG/PCALL/PCALLH/CP/C`) → `(type, byte delta)`, position-independent.
3. `FRAME_CONT` → delta + a **continuation symbol from a closed 9-entry set** (`lj_cont_cat/ra/nop/condt/condf/hook/stitch` + two integer specials) + continuation PC. Raw ASM addresses relocate through a 9-entry table.
4. **Amendment (verifier-caught, then measured):** a coroutine that yielded from inside a compiled trace sits under a `cont_stitch` frame whose aux slot holds a `GCtrace` reference — common on OC's hot path, not an edge case. On persist, write **plain `+0.0` (raw `u64 == 0`)**; the VM's own blacklist path then degrades resumption to `cont_nop`/interpreter — the same mechanism `jit.flush` relies on. *(Corrected 2026-09-01: this document originally said to write a "zero-payload trace reference". That is wrong and crashes — such a value still satisfies `tvisgcv`, so the next `gc_traverse_thread` dereferences a NULL payload. Measured: SIGSEGV, exit 139, in both a table slot and a coroutine stack slot; `+0.0` survives a full GC and resumes correctly. `nil` is also wrong: its NaN-boxed payload is non-zero, so the VM does not take the blacklist path at all.)* **M0 located the slot empirically: `framebase - 5`**, one below the continuation pair ([prototype/framewalk](../prototype/framewalk/)). Hook-yield frames (raw multres integer) are refused, matching Eris's own "cannot persist yielded hooks."

> **M0 status: complete and passing.** All seven invariants above are now hard assertions in a running harness across eight suspended threads in seven frame shapes. See [prototype/framewalk/README.md](../prototype/framewalk/README.md) for results and the two schema corrections it produced.

**Everything else maps.** Complete per-type serialization plans exist for the whole object model (see the study reports): strings re-intern (all hash/sid state is process-random — rebuild, never blit), tables rebuild by pre-sized re-insertion, closures via proto-ref + first-class `GCupval` objects (identity = sharing; open upvalues restore as `(thread, slot)` through a `func_finduv` equivalent that regenerates all list invariants), protos ride the **existing in-tree `lj_bcwrite`/`lj_bcread`** (bit-exact constants; un-patches JIT-modified bytecode — dump *before* `jit.flush`), `math.random` state is a plain 32-byte PRNG userdata (and OC replaces it host-side anyway). Restore runs on a fresh state with the GC **pinned** in `GCSpause` (threshold trick, in-tree idiom) making the whole reconstruction barrier-free; ordering: strings implicit-first → protos → two-phase tables/closures → per-thread stacks → open upvalues → uvptr patching.

## What "Eris-API-compatible" actually requires

OC's whole contract (verified in `PersistenceAPI.scala` + machine.lua + jnlua.c) is tiny and Lua-level: a global `eris` with `persist(perms, v) → binary string`, `unpersist(uperms, s) → v`, `settings("spkey", key)` + `settings("path", bool)`, the spkey-metafield protocol (`f(obj)` on save returning a closure; closure called `f()` on load; pre-reserved ref slot), perms lookup **at every graph node**, and all failures as catchable Lua errors. Nothing in OC reads the bytes (opaque `byte[]` through SaveHandler), and Eris's own wire format is unversioned — **we define our own format freely** (with magic, format version, and a build fingerprint).

The failure-containment chain is inherited and verified end-to-end: Lua error → jnlua pcall → `LuaRuntimeException` → `NativeLuaArchitecture.save` catch → `nbt.removeTag("state")` → machine loads stopped → reboot. Conservative reject-and-reboot is the *sanctioned* outcome.

## Eris: design port, not code port

Eris (`eris.c`, 2741 lines, MIT) measures out as roughly **60–65% public-API code that transfers** (settings, primitive I/O, tables/spkey/perms/reference-dedup logic — modulo a small 5.2-API shim) and a **~900-line VM-state core that is rewritten** against LuaJIT structs. LuaJIT structurally *eliminates* two Eris subsystems (the patched-stdlib continuation perms for yielded pcall — pcall is a stack frame tag here; and the whole CallInfo rebuild — frames live in the stack) and *adds* two (bcread-style single-allocation proto restore; symbolic continuation relocation). All four licenses involved (Eris, LuaJIT, OC, JNLua) are MIT.

## Implementation path

**Sidecar file compiled into the pinned build** (`eris-lj.c` + two lines of build glue), modeled on Eris's architecture, reusing `lj_bcwrite`/`lj_bcread` for protos — NOT an extension of `lj_serialize.c` (string.buffer): that path entangles with the JIT recorder's tag contract, collides with upstream's reserved tag space (the "(yet)" in ext_buffer.html signals upstream intent), and diffs six JIT-coupled files instead of ~none. `lj_bcdump.h:36-38` explicitly sanctions private formats (version ≥ 0x80). Plan for **zero upstreaming** (Mike Pall self-commits everything; no visible WIP on the "(yet)"); any upstreamable piece is a bonus.

## Prior art (fresh sweep)

Nobody has shipped this. Closest artifacts: **lua-marshal** serializes closures *with upvalues* and cyclic tables on LuaJIT using only the public API — proving threads are the *only* piece that requires private headers. Tarantool (owns a LuaJIT fork) deliberately chose data-only snapshots; bitser/binser (LuaJIT game saves) use perms-style registries and refuse coroutines; RaptorJIT snapshots memory one-way for diagnostics. Academic Lua-migration work converges on "capture at cooperative yield points" — exactly OC's protocol.

## Effort model

~3–4k LOC of C total (Eris itself is 2741 for a friendlier VM but a broader scope), months part-time for a user+AI pair:

- **M0 — validation spike first**: a read-only frame-chain walker run against live OC kernel states, proving the "no C frames at suspend" invariant and cataloging real frame shapes *before* any serialization code.
- **M1** data-only serializer with shared-ref/cycle map, perms-at-every-node, format header + checksums (~0.8–1.2k LOC; public API only).
- **M2** protos + closures + upvalue identity via bcwrite/bcread + dedup (~0.6–1k LOC). Checkpoint: `debug.upvalueid` equality survives restore.
- **M3** suspended coroutines — the schedule risk and the core deliverable (the persisted root *is always* a thread): frame decode/rewrite, PC relocation, open-upvalue relinking, hard reject rules (`cframe != NULL`, interior C frames, unknown cont symbols) (~0.8–1.2k LOC, most of the debugging).
- **M4** spkey/perms protocol polish + OC/JNLua-bridge integration (~0.4–0.6k C + ~0.5k bridge). Checkpoint: OpenOS boots, persists mid-`pullSignal`, restores, continues.
- **M5** hardening: randomized round-trip property tests, persist→unpersist→persist oracle, OpenOS save/load soak, error injection (truncated/corrupted blobs must reject, never crash), GC-stress builds with LuaJIT assertions.

## The two failure modes, stated honestly

1. **Silent state corruption after restore** is strictly worse than no persistence. Mitigations are all cheap and mandatory: per-section + whole-blob checksums, build-fingerprint header, conservative reject-and-reboot on *anything* unexpected (never best-effort), a canary self-test structure persisted alongside the kernel and verified on load, and the round-trip oracle as a standing CI tripwire.
2. **Pinned-commit lock-in**: the format encodes struct-level facts of one build. Acceptable by construction — the format lives inside one shipped natives version; upgrades reboot computers (OC's existing cross-version precedent). Every LuaJIT patch we take = format version bump, loudly.

## Study reports

Full per-arm reports with file:line citations (session scratchpad; regenerate from this doc's claims if needed): object-model map, coroutine-frame schema, Eris anatomy + OC contract, serializer foundations + prior art, scope & risk. Primary sources: pinned LuaJIT tree in [../prototype/LuaJIT](../prototype/LuaJIT/), fnuecke/eris @ master + master-lua5.3, GTNH OC persistence sources, LuaJIT issues #612/#4, lua-l 2008-09.
