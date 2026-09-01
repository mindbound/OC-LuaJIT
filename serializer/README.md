# eris-lj — Eris-API-compatible serializer for LuaJIT

Track P's deliverable: transparent persistence for the LuaJIT architecture,
so OC's `PersistenceAPI` and `machine.lua` work unchanged. Design rationale and
the feasibility verdict: [../docs/persistence-study.md](../docs/persistence-study.md).

**Status: M1 complete** — data graphs (nil, booleans, numbers, strings, tables,
metatables, cycles, shared references), the permanents protocol, and the spkey
literal semantics. Functions and threads deliberately raise errors naming the
milestone that will add them (M2, M3).

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

## Next

M2 adds protos, Lua closures, and upvalue identity (reusing `lj_bcwrite`/
`lj_bcread`); M3 adds suspended coroutines using the frame schema validated in
[../prototype/framewalk](../prototype/framewalk/).
