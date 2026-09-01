# M0 — frame-walk validation spike

Read-only validation of the suspended-coroutine serialization schema from
[../../docs/persistence-study.md](../../docs/persistence-study.md), before any
serializer code exists. Creates suspended coroutines in every frame shape the OC
yield protocol can produce, then walks their stacks with LuaJIT's own internal
headers and asserts the invariants Track P depends on.

## Build & run

Requires the LuaJIT tree already cloned and built by `../watchdog`
(pinned commit `1ee778a4`, GC64, static lib):

```bash
cd prototype/watchdog && make all CC=gcc
```

then:

```bash
cd prototype/framewalk && make run CC=gcc
```

Exit status is 0 only if every invariant holds. Last run: [m0-results.txt](m0-results.txt).

## Invariants asserted

| | Invariant | Result |
|---|---|---|
| H1 | `cframe == NULL` and `status == LUA_YIELD` on every suspended thread | holds, all 8 threads |
| H2 | Every frame link decodes to LUA / DELTA / CONT; chain terminates | holds |
| H3 | No interior `FRAME_C`/`FRAME_CP` — only the bottom resume frame | holds |
| H4 | Every continuation address resolves in the closed 9-entry symbol table | holds (`ra`, `cat`, `stitch` observed) |
| H5 | `FRAME_LUA` return PCs land inside the caller proto's bytecode | holds |
| H6 | Open upvalues point into the stack, list sorted by descending slot | holds |
| H7 | `cont_stitch` saved trace is at a known slot | holds — **framebase − 5** |

## Findings that change the M3 plan

1. **The stitch trace slot is `framebase - 5`.** Empirically located (full-stack
   scan found exactly one `LJ_TTRACE`-tagged slot, at 9 with framebase 14) and
   consistent with `vm_x64.dasc:2380` `mov TRACE:ITYPE, [RB-40]`. It sits one
   slot *below* the continuation pair. The study's provisional offset was off by
   one slot — M3 must use `framebase - 5` when writing the zero-payload trace ref.
   Full FR2 stitch-frame layout confirmed at framebase 14:
   `[9]` saved trace, `[10]` cont address, `[11]` contpc, `[12]` func,
   `[13]` ftsz = `0x52` (delta 80 | `FRAME_CONT`).
2. **Frame-type decoding must be two-step.** A Lua frame's `ftsz` is a `BCIns*`
   whose bit 2 is address data, so `frame_typep()` reports `FRAME_LUAP` at random
   on Lua frames; and `frame_type()` alone conflates `CONT`(2) with `PCALL`(6)/
   `PCALLH`(7). Correct order — as the VM's own unwind loops do it — is
   `frame_islua()` first, then `frame_typep()` for delta frames. A serializer
   that gets this wrong silently mislabels every pcall frame.
3. **`pcall`/`xpcall` produce pure Lua-stack `FRAME_PCALL` frames** with deltas 16
   and 24, matching the VM's `pcall`/`xpcall` fast functions exactly — confirming
   no C-frame involvement in protected yields (the property that lets LuaJIT drop
   Eris's entire patched-stdlib continuation subsystem).
4. **Nested coroutines**: `coroutine.resume` clears yielded values off the
   coroutine's stack, so a suspended inner thread must be reached via a live
   reference (this harness keeps one in `_G.INNER`), not from the outer thread's
   stack. Relevant to how M3 enumerates reachable threads.

## Scope

This spike is read-only by design: it walks and validates, never mutates or
serializes. Next milestone (M1) begins the actual serializer with data-only
graphs; the frame decoding validated here is consumed by M3.
