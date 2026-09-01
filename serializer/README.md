# eris-lj — Eris-API-compatible serializer for LuaJIT

Track P's deliverable: transparent persistence for the LuaJIT architecture,
so OC's `PersistenceAPI` and `machine.lua` work unchanged. Design rationale and
the feasibility verdict: [../docs/persistence-study.md](../docs/persistence-study.md).

**Status: M3 complete** — data graphs, the permanents protocol, the full spkey
protocol, Lua closures with **upvalue identity** and environments, and
**suspended coroutines**: a thread round-trips and resumes exactly where it left
off, with its frame chain, open upvalues and nested coroutines intact. Userdata
still raises an error naming the milestone that will add it.

## Build & test

Requires the pinned LuaJIT static lib built by `../prototype/watchdog`:

```bash
cd prototype/watchdog && make all CC=gcc
```

then:

```bash
cd serializer && make test CC=gcc
```

## API

```lua
eris.persist([perms,] value)   --> binary string
eris.unpersist([uperms,] blob) --> value
eris.settings(name [, value])  --> previous value; nil resets to the default
eris.version()                 --> version, build fingerprint, format number
```

Settings: `spkey` (default `"__persist"`), `path`, `maxrec` (default 2000, and
clamped there: M3 frame records cost ~160 bytes of C stack per level), `debug`, `spio` (must stay false). This is exactly the surface
OC touches, so `PersistenceAPI.scala` needs no changes.

## Format

```
'E' 'L' 'J' | u8 format | u8 fplen | fingerprint | value record | u32le crc32
```

The fingerprint pins the blob to one natives build: a blob from a different
LuaJIT commit is refused outright rather than misparsed. Numbers are canonical
(exact integers as zigzag varints, everything else as raw IEEE bytes), so blobs
are identical on DUALNUM (arm64) and non-DUALNUM (x64) builds.

Nothing in OC depends on the byte layout — persisted blobs are opaque `byte[]`
through `SaveHandler` — so the format is ours to evolve. Any change bumps
`ERIS_LJ_FORMAT`, and old blobs are then cleanly rejected (computers reboot,
OC's sanctioned degraded path).

## Design notes

- **Reference ordering follows Eris exactly.** Objects are registered *before*
  descending into them, so cycles emit a back-reference; a permanent's id is
  reserved *before* its key is read back. Persist and unpersist must assign ids
  in the identical sequence or every graph with sharing silently corrupts.
  The same discipline applies to **upvalues**: the reader publishes an
  upvalue's owner before reading its value, because that value can reach
  another closure sharing the very same upvalue (the ordinary module shape —
  two members capturing one local and the module table).
- **Upvalue identity, not just value.** Each distinct upvalue is written once,
  keyed by `lua_upvalueid`; later closures emit a join record replayed with
  `lua_upvaluejoin`. Upvalues use a separate id space from values — they are
  not first-class Lua values, so a crafted blob cannot resolve a value
  reference into one.
- **LuaJIT is Lua 5.1**, so a closure carries a function environment as well as
  upvalues; both round-trip. A consequence worth knowing: persisting a closure
  reaches the globals it can see, so hosts must flatten `_G` into perms (OC's
  `PersistenceAPI` does exactly this) or a one-line closure drags in the whole
  standard library.
- **Dumps are deterministic** (`BCDUMP_F_DETERMINISTIC` via `lj_bcwrite`, since
  the public `lua_dump` cannot ask for it) so blob sizes are stable and the
  idempotence oracle is meaningful. `eris.settings("debug", false)` strips debug
  info, which dominates a typical blob — at the cost of tracebacks and line
  numbers in restored code.

### Known limitations

- **Prototypes are not deduplicated**: each closure carries its own dump, so N
  closures built from one prototype cost N dumps in the blob and N distinct
  prototypes after restore. Correctness is unaffected (upvalue sharing is
  handled separately); it is a size and memory cost. Proper dedup means
  serializing `GCproto` objects through `lj_bcwrite`/`lj_bcread_proto`
  directly — a candidate for a later milestone.
- **A `__persist` callback runs while any enclosing table is mid-traversal**,
  so it must not add or remove keys of a table currently being persisted —
  Lua leaves `next` undefined after such a mutation. Upstream Eris has the
  same constraint.
- **An upvalue shared between a permanent closure and a persisted one is split
  on restore.** Permanents short-circuit before their upvalues are ever
  examined, so the persisted closure gets an independent copy. This matches
  upstream Eris, and is the natural reading of "this object already exists on
  the other side".
- **The write buffer is invisible to `collectgarbage("count")`.** It is
  allocated through the host's own `lua_Alloc` (deliberately, so it stays
  inside OC's per-machine accounting) but outside LuaJIT's `gc.total`, so
  Lua-level memory readings under-report during a persist.
- **Perms keys must round-trip to an equal key** — strings and numbers always
  do; a bare table does not (it restores as a distinct object) unless it is
  itself a permanent. Upstream Eris behaves the same; OC uses dotted string
  names throughout.
- **Hostile input is assumed.** Every read is bounds-checked, every wire byte
  that indexes anything is range-checked, recursion is bounded symmetrically on
  both sides, and the buffer is a `__gc`-owned block from the host's own
  `lua_Alloc` (inside OC's memory accounting; freed even on a longjmp).
- **A checksum is not a MAC.** CRC32 catches corruption, not tampering — any
  save can be re-sealed by an attacker. Parser robustness, not the checksum, is
  what makes crafted blobs safe.

## Review history

The first M1 build passed all 68 tests and still contained two crash bugs. A
four-lens adversarial review (stack/longjmp discipline, hostile-blob handling,
semantic fidelity vs Eris, resource limits) reproduced every finding before it
was accepted. Fixed, each with a regression test:

| Severity | Defect |
|---|---|
| critical | An out-of-range permanent type byte reached `lua_typename()`, an unchecked array index in LuaJIT — out-of-bounds read, **SIGSEGV** from a crafted blob |
| high | A graph at exactly `maxrec` depth persisted into a blob that could never be read back — silent write-only save data |
| high | `maxrec` had no upper clamp, so a 24 KB crafted blob exhausted the native C stack — **uncatchable crash** on a 1 MB JVM thread stack |
| medium | The `TAG_REF` range check was defeated by a signed cast for ids ≥ 2^63 |
| medium | `settings(name, nil)` read instead of resetting to the default, diverging from Eris |
| medium | The `maxrec` getter reported a value unrelated to the limit actually enforced |
| medium | Peak persist memory was ~4x the blob: superseded write buffers accumulated (now grown in place) |
| low | An over-long varint was silently truncated instead of rejected |
| low | A nil table value was silently dropped where Eris errors |
| low | (tests) The structural oracle mismatched graphs with several table-valued keys |

Both crashes are verified fixed on 2 MB and 1 MB stacks. Two further findings
were accepted as deliberate: the nibble-table CRC32 stays (a `const` table has
no lazy-init race across the many `lua_State`s a host runs concurrently, and a
few ms per MB is immaterial at save time), and perms-key semantics match Eris.

M2 was reviewed the same way (upvalue identity, the dump/load path, spkey
parity with Eris, and a mock-OC integration lens). Four lenses independently
reproduced the same critical defect:

| Severity | Defect |
|---|---|
| critical | The reader published an upvalue's owner **after** reading its value, so an upvalue whose value reached a co-sharing closure produced a blob that persisted cleanly and could never be loaded — triggered by the ordinary module pattern |
| medium | Dumps were not byte-reproducible (template-table constants follow the per-process hash seed), so blob sizes drifted and the idempotence oracle was meaningless |
| medium | The `debug` setting was accepted, stored and reported but never applied — `lua_dump` cannot strip, so every blob carried full debug info |
| medium | The `maxrec` ceiling was derived from M1 table records; M2 records cost ~160 B/level, putting the old 3000 limit past the stack budget |
| medium | The write buffer waited for a GC cycle the host has stopped (now freed eagerly) |
| low | A `__persist` closure capturing its own proxy failed later as an opaque "dangling reference" instead of being named |

Each has a regression test. One reported finding was refuted on inspection (a
permanent closure's upvalues splitting is correct Eris behaviour) and is now
documented above rather than "fixed".

## Next

M4 wires this into OpenComputers: the `eris` global registered at state
creation, a `PersistenceAPI` equivalent, and an end-to-end OpenOS boot →
persist mid-`pullSignal` → restore → continue. M5 is hardening: fuzzing,
corrupted-blob soak tests, and the two known gaps below.


## Suspended coroutines (M3)

A thread is written as: status, stack span, base/top offsets, its slot values, a
top-down frame list, its open-upvalue slots, and its environment. **No stack
address ever reaches the wire** — each frame carries only a *link* (bytes to the
next-outer frame word), and positions are re-derived and re-validated on restore.
Frame contents are symbolic: a Lua frame's return PC becomes `(proto, bytecode
offset)`, and a continuation frame's raw `lj_cont_*` machine address becomes a
small enum with no escape hatch, because `cont_dispatch` jumps to that word
directly.

Restore runs in passes: create the thread and register it (so cycles resolve) →
grow the stack once → write slot values → validate and write frame words →
create open upvalues through a replica of LuaJIT's static `func_finduv` → set
base/top/status with `cframe` forced to NULL.

**Open upvalues** are the subtle part. If the thread owning an aliased slot is
part of the graph, the upvalue is identified by `(thread, slot)` and every
closure referring to it is re-pointed at the restored open upvalue once it
exists; a closure whose upvalue aliases a frame nobody is saving is written by
value instead, since there is no frame on the other side to alias.

### Known gaps

- **`ipairs` — solved, host-side.** The iterator LuaJIT leaves on the stack is
  a hidden singleton no name in `_G` reaches, but it *is* obtainable as an
  upvalue of `ipairs` itself. Sweeping the function-valued upvalues of every
  named builtin picks it up (exactly two objects on this build: `next` and the
  `ipairs` aux), after which a coroutine suspended mid-`ipairs` persists and
  resumes normally. `tests/m2.lua` and `tests/m3.lua` do this in
  `build_perms`, and **a real host wants the same arm in its perms flattener**.
  No serializer change was needed.
- **`pairs` — solved by replaying the remaining keys instead of carrying the
  position.** A generic for-in loop's control slot holds an index into the
  table's *current* node layout: `BC_ITERN` keeps it tagged `LJ_KEYINDEX`, and
  the despecialised `BC_ITERC` form keeps the previous key, which
  `lj_tab_keyindex` turns straight back into such an index. Neither survives a
  move to another process — LuaJIT places a string key at
  `hashmask(t, s->sid)` and `sid` comes from a per-VM counter reseeded from
  the PRNG, so a rebuilt table has a different node order and the resumed loop
  silently skips or repeats keys.

  So the position is not persisted at all. The keys the loop has **not yet
  reached** are snapshotted in the saving VM's own traversal order, and the
  loop's hidden `(func, state, control)` triple at registers `RA-3/RA-2/RA-1`
  is rewritten **on the wire only** — the saving coroutine keeps iterating
  exactly as it was — to drive the rest of the loop from that list:

      func    = the replay iterator (a C function, `TAG_FORIN_ITER`)
      state   = { [1]=t, [2]=keys, [3]=pos }   (an ordinary table)
      control = nil, and thereafter the previous key

  Values are still read live out of `t`, so a body that assigns `t[k]` later in
  the loop sees the new value. `for k in pairs(t) do t[k] = nil end` works,
  which the position-carrying design could not save at all.

  What is snapshotted is the **traversal slots**, not the entries that happen
  to be live at that instant: a real traversal decides when it *reaches* a
  slot, and LuaJIT nils a deleted value while keeping its node, so a program
  that blanks an entry and restores it before the cursor arrives still has it
  visited. The replay iterator re-checks `t[key]` on arrival and skips one
  that is still absent, which reproduces `next` exactly — and matters because
  in a host like OpenComputers the save point is the host's choice, not the
  program's.

  A loop is identified by its **control slot**, never by the func slot or the
  opcode. `BC_ITERN` never reads the func slot, so it need not hold `next` at
  all: `table.foreach`'s loop — compiled into every `lua_State` at LuaJIT
  build time, and reachable because its callback can yield — leaves it nil,
  because `genlibbc.lua` rewrites its `PAIRS(t)` into `nil, t, 0x4dp80` and
  then patches the resulting `ITERC` byte back to `ITERN`. That same loop's
  head is a plain `BC_JMP` that never was an `ISNEXT`.

  Persisting a thread that was **already restored once** re-snapshots from the
  keys that actually remain, so a blob does not carry the exhausted prefix
  forward or keep already-visited keys alive; and it still emits a record,
  because the prototype in the next VM is not necessarily in the state this
  one is — one that comes back from `uperms` is the host's own, recompiled per
  process, so it can be `BC_ITERN` over there even when it is `BC_ITERC` here.

  On restore the loop is despecialised first — `ITERN`→`ITERC` and its
  `ISNEXT`→`JMP` — because `BC_ITERN` validates nothing (it *masks* the state
  slot's type tag rather than testing it, and never reads the func slot), so a
  replay triple under a live `ITERN` would be read as a raw `GCtab` layout.
  That edit is a pure opcode-byte swap: the parser emits both pairs with
  identical operands (`lj_parse.c:2921,2930`), and it is the same edit LuaJIT
  itself performs on running loops in `blacklist_pc` (`lj_trace.c:380`). The
  The restore does not take the blob's word for any of this: after applying
  the records it sweeps the restored frames itself and despecialises any
  `BC_ITERN` still sitting over a replay triple, so the guarantee holds even
  if a blob under-reports.

  **Measured.** 17 loop shapes × 64 hash-layout rotations = **1088
  fresh-process restores, every one visiting the exact key multiset** (no
  duplicates, no omissions). Eight of the shapes additionally go through a
  *third* process that loads and re-saves, so the final restore resumes a loop
  that is already in replay form. Covered: the iterated table as a permanent
  rebuilt by the loader; the loop's prototype supplied through perms and never
  serialized; `table.foreach`'s build-time loop; the despecialised `ITERC`
  form; delete-as-you-go on both arms; JIT-warmed loops; nested and
  register-sharing loops.

  The harness carries a **negative control** — the pre-fix behaviour, resuming
  `next` from a saved key — which diverges in 60+ of 64 rotations, so the green
  results have demonstrated power. The position-carrying design scored 4/20 on
  the same experiment. See `tests/forin.lua` and `tests/run-forin.sh`.

  What it costs, stated plainly:

  - Blob size is O(keys not yet visited): a 1000-entry table yielded at its
    first key costs ~1000 key records (strings dedupe to `TAG_REF`).
  - The loop runs as `ITERC` for the rest of that execution and the prototype
    stays despecialised in the restoring VM, so it loses the `ITERN` fast path.
    Correctness is unaffected and a later fresh entry to the same loop still
    iterates normally.
  - `persist()` flushes JIT traces once, the first time a call reaches a
    thread **that contains a generic-for loop at all**. A trace overwrites the
    very instruction the scan reads (`trace_stop` replaces the loop head with
    `BC_JLOOP`, whose A operand is a slot count, and the following `ITERL`
    becomes a `JITERL` whose D field is a trace number), so it is not optional
    there — but gating it matters, because the flush discards every compiled
    trace in the VM and is *refused* while a GC hook is active. Saving a
    coroutine with no for-in loop, or a dead one, therefore neither resets the
    host's JIT nor fails from inside a `__gc` finalizer.
  - Keys **added** during a traversal are not visited. Lua already leaves that
    undefined.
  - One residual gap is left open deliberately, because it is not soundly
    closeable: a loop whose iterator is a **Lua closure wrapping `next`**
    rather than `next` itself. Its `ffid` is not `FF_next_N`, so the scan
    cannot see it, yet its control slot carries the same layout dependence.
    That shape is indistinguishable from a legitimate custom iterator with its
    own ordering, and rewriting the latter would silently change its
    semantics. `pairs(t)` returns the raw `next`, so ordinary code is
    unaffected — but **a sandbox whose `__pairs` returns a wrapper would be**,
    which is a constraint on the OC integration: return the raw `next`.
  - One shape is refused rather than guessed at: a frame whose bytecode
    position cannot be recovered *and* which holds an unmarked `next`-shaped
    triple. Without the position, three ordinary locals holding
    `(next, a table, one of its keys)` are indistinguishable from a live loop,
    and rewriting them would corrupt live data. A refusal is the third option.

- **Numeric `for` loops are fine**, as are `while`/`repeat`.

## Review history (M3)

M3 was reviewed harder than M1 or M2, in two halves, because it writes raw frame
words into a live VM stack.

First, the **design foundation was verified** — ten claims the implementation had
been built on, which an earlier workflow had failed to check because it gated
verification on the *design agents' own* confidence, and they had rated
everything "high". Eight confirmed, one refuted, one materially corrected:

- **Refuted:** that the two frame-offset checks are a *complete* filter. They
  reliably reject the memory-unsafe offsets, but a prototype with several call
  sites sharing a base register admits offsets that pass both checks and
  silently change behaviour (demonstrated against the shipped code: a resealed
  blob skipped a yield, another returned early). No new capability for an
  attacker — blobs already carry unverified bytecode — but the claim as written
  over-promised.
- **Corrected:** that a `cont_hook` frame is unreachable because "OC installs
  only Lua hooks". True of stock OC; **false of this port**, whose watchdog
  installs a *native* C hook. The guard is safe only because that hook raises
  instead of yielding — now recorded as a cross-component invariant in
  [../docs/watchdog.md](../docs/watchdog.md).

Then a **four-lens review of the implementation** found 16 defects, 4 critical:

| Severity | Defect |
|---|---|
| critical | A GC during the slot pass could **shrink the thread's stack out from under the restore** — a heap buffer overflow reachable from an ordinary ~40-frame coroutine, with no tampering and no explicit `collectgarbage()`. `co->top` is now parked at the full reserved span for the whole restore, so `lj_state_shrinkstack` cannot fire |
| critical | A continuation symbol was trusted without checking it matched its site; every handler decodes the surrounding bytecode assuming it attached the frame, so a valid-but-wrong symbol produced a resumable coroutine that segfaulted on resume. Now cross-checked against the opcode's metamethod |
| critical | A recursive `local function` on a suspended stack made the blob unloadable (the closure captures its own slot, which the old bound rejected) |
| high | With no frames, `base` was not pinned to the stack bottom, so the next GC walked blob values as a frame chain |
| high | A continuation frame's link was not required to clear its own continuation words, so the next-outer frame's `ftsz` could overwrite the validated continuation address — a wild computed jump |
| high | The open-upvalue bound used a thread's *in-flight* `co->top`, so ordinary coroutines failed to restore |
| high | A thread suspended in a `pairs()` loop could not be persisted (now documented above) |
| medium | `F18` (a `PCALLH` frame with no active hook) was omitted on both sides; `elj_finduv` dropped `func_finduv`'s resurrect branch, but pass-4 upvalues really can be dead-coloured; `p_thread` held a stack pointer across a loop that can reallocate; a thread that died by error could not be persisted at all |
| low | The `immutable` flag was lost on a restored open upvalue |

A follow-up audit then re-checked every one of those fixes against the code
rather than the changelog, and found that **one of them was a regression**: the
fix for "a thread that died by error can never be persisted" removed the
refusal and normalised such a thread to an empty stack, but a coroutine that
dies *by error* does **not** close its open upvalues (the error path returns at
the resume frame without reaching the `unwindstack` that would close them), and
those records were still being emitted against slots that no longer existed. The
result was a blob that saved happily and could never load — the same write-only
save-data class this project rated high in the M1 review, reintroduced by a fix
for something else. It also let an 86-byte blob rebuild a 228 KB stack. Now
fixed properly: a dead thread emits no open-upvalue records, declares a minimal
stack span, and is never selected as an open upvalue's owner.

All fixed. Regression tests were added for the shapes that hid them —
recursive and mutually recursive locals, a forward-declared local captured before
assignment, and a 40-frame coroutine with a payload (the existing tests were all
too shallow to reach the stack-shrink guard).
