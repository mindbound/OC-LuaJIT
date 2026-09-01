# Case study: how OpenPython achieves "Fully persistable"

*Extracted verbatim from https://github.com/OpenPythons/OpenPython (master, MC 1.12.2) on 2026-09-01. Relevant to us as (a) proof of what full persistence costs, and (b) a reusable template for the v3 data-persistence machinery (external save files, file-handle and Value persistence).*

## The mechanism in one sentence

OpenPython never runs MicroPython natively: it cross-compiles real MicroPython C code to bare-metal ARM Cortex-M0 firmware and *interprets that firmware* with a software ARM Thumb emulator written in Kotlin — so the entire VM is 17 integer registers plus four flat byte arrays, and persistence is just gzipping them.

## The snapshot

`OpenPythonVirtualMachineV1.save()` writes to NBT:

- `LATEST_FIRMWARE {name, protocol}` — load crashes the machine with "Invalid firmware" if the name doesn't match the compiled-in firmware.
- `cpu.regs` — the full register file, `IntArray(17)` (R0–R12, SP, LR, PC, CPSR).
- `cpu.memory` — each mapped region (`FLASH` 256 KB RX at 0x08000000, `SRAM` 64 KB, `RAM` 256 KB, `SYSCALL` 16 KB) as `{address, size, flag, gzip(buffer)}`. A `MemoryRegion` is nothing but `begin`, `size`, a flag, and one flat `ByteArray(size)` — no MMU, no host pointers.
- `state` — host-side tables: `fdMap` (open files as `(fd, component address, handle int, pos)` — the real open handle lives in, and is persisted by, the OC filesystem *component*) and `valueMap` (opaque OC `Value` objects persisted by class name + `value.save(nbt)`, restored via `Class.forName(...).newInstance()` + `load`).

On load, a fresh VM is initialized (firmware re-flashed, PC at the reset vector), then regs and buffers are bulk-overwritten, and execution resumes at the saved PC on the next timeslice — genuinely mid-program, even mid-C-function inside MicroPython.

## Why the snapshot is always consistent

The Kotlin Thumb interpreter (`thumbsf/CPU.kt`) only ever leaves the emulator *between emulated instructions*: the instruction budget runs out (10M/timeslice), or the SVC syscall handler throws a `ControlPauseSignal`/`ControlStopSignal`, and a `finally` block commits the cached registers back to the 17-int array first. Elegant detail: a *pause* leaves PC pointing **at** the `SVC` instruction, so an in-flight component call is never persisted — after restore (or just the next timeslice) the syscall simply re-executes and re-requests what it wanted. A *stop* advances PC past it.

## Big blobs stay out of chunk NBT

`OpenComputersLikeSaveHandler` (its header comment: `// li.cil.oc.common.SaveHandler`) is a re-implementation of OC's external save scheme, because the addon API doesn't expose OC's own: the machine's chunk NBT gets only `{dimension, chunkX, chunkZ, compress}`; the actual blob is cached in RAM and flushed by a Forge `ChunkDataEvent.Save` hook to `<world>/<oc-savePath>/state/<dim>/<cx>.<cz>/<node-address>`, with the OC save path discovered by reflection on `li.cil.oc.Settings.savePath()`. We will need the 1.7.10 equivalent of exactly this for v3.

## Known rough edges (their code, our lessons)

- `fdCount` is saved as a literal `3` regardless of the live value — fd reuse bug after restore.
- RAM size is not persisted; shrinking installed memory before a load crashes the restore (`InvalidMemoryException`).
- "Invalid firmware" crash is missing a `return` — restore continues into the crashed machine.
- Old state files are orphaned on disk rather than deleted.
- `Value` restore requires a public no-arg constructor.

## Why this doesn't transfer to LuaJIT

The whole trick depends on the guest VM being a closed, flat memory image with a program counter. A JNI-embedded LuaJIT is the opposite: its state is native process memory — host-pointer-laden GC objects, C stacks, JIT trace machine code — with no serializable representation. OpenPython pays for its property with performance: an interpreted, emulated CPU running interpreted Python is orders of magnitude slower than even LuaJ, let alone JIT-compiled LuaJIT. The two projects sit at opposite ends of the persistence-vs-speed trade; OC-Wasm sits in the middle (snapshot linear memory + globals, no call stack, programs restart from `run()`), which is the model our v3 opt-in data persistence follows.
