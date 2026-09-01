# eris-lj — Eris-API-compatible serializer for LuaJIT

Track P's deliverable: transparent persistence for the LuaJIT architecture,
so OC's `PersistenceAPI` and `machine.lua` work unchanged. Design rationale and
the feasibility verdict: [../docs/persistence-study.md](../docs/persistence-study.md).

**Status: M2 complete** — data graphs (nil, booleans, numbers, strings, tables,
metatables, cycles, shared references), the permanents protocol, the full spkey
protocol, and Lua closures: prototypes, **upvalue identity** (closures sharing a
variable still share it after a restore) and function environments. Threads and
userdata deliberately raise errors naming the milestone that will add them (M3).

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

Settings: `spkey` (default `"__persist"`), `path`, `maxrec` (default 2000,
clamped to 3000), `debug`, `spio` (must stay false). This is exactly the surface
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

M3 adds suspended coroutines, using the frame schema validated in
[../prototype/framewalk](../prototype/framewalk/) — including the `cont_stitch`
saved-trace slot at `framebase - 5` that spike pinned down.
