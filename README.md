# OC-LuaJIT

A LuaJIT-based CPU architecture addon for [GTNH OpenComputers](https://github.com/GTNewHorizons/OpenComputers) (Minecraft 1.7.10).

Adds a **LuaJIT** architecture selectable with shift+right-click on any OC CPU, alongside the stock Lua 5.2/5.3/5.4 and LuaJ options — additive, never a replacement for any of them.

**Persistence is NOT the trade.** An earlier version of this file said LuaJIT computers would reboot on chunk reload, like OC's LuaJ fallback. That premise was disproved: `serializer/eris_lj.c` persists and restores a full LuaJIT state, suspended coroutines and live for-in loops included, through OC's own `PersistenceAPI`. The harness boots OpenOS 1.8.9, persists it, restores it into a fresh workspace and asserts the machine *resumed* — same boot nonce, counter still counting.

**Status: runs in Minecraft and in the harness; not released.** Since 2026-09-16 the mod has run in a real GTNH-based instance on OpenComputers 1.12.61-GTNH and 1.12.64-GTNH: OpenOS boots on it with the JIT on, and a machine persists across save-and-quit, a live REPL with an open file included — see [docs/in-game-tests.md](docs/in-game-tests.md). Under [ocelot-brain](https://gitlab.com/cc-ru/ocelot/ocelot-brain), real operating systems boot on the same VM, driven by **our own `Architecture` and our own `LuaState` class**, with OpenComputers' stock PUC-Lua 5.2 native loaded alongside in the same JVM:

| run | what it establishes |
|---|---|
| OpenOS 1.8.9, smoke suite | boots to a shell, **persists and resumes** (same boot nonce, counter still counting), the deadline watchdog fires and the machine survives, the RAM cap holds and OOMs at the cap, the bytecode gate refuses — 65 checks, 0 failures (2026-10-03, JIT on) |
| AxisOS, census | boots to a login prompt over 14000 ticks, emergency collector refusing nothing |

Both run on `ocljit.arch.OCLuaJITArchitecture` over the additive `libjnluajit52` library, which is the shape the mod ships. The same suite also runs in two control arms — our VM as a drop-in under OpenComputers' own 5.2 architecture, and stock PUC-Lua 5.2 as a baseline — and each arm refuses the others' fingerprint.

The mod-side adapter is the same construction, compiled against the pinned OpenComputers jar (1.12.58-GTNH) and run in game on 1.12.61 and 1.12.64. Its jar carries the patched watchdog kernel under our own asset domain and loads it in place of OpenComputers' after `initialize()`. What is still open, release blockers included, is in [docs/roadmap.md](docs/roadmap.md).

## Documentation

- [docs/feasibility.md](docs/feasibility.md) — the full feasibility study: architecture integration, performance, persistence constraints. Read this first.
- [docs/roadmap.md](docs/roadmap.md) — the living roadmap: v0.5 the ocelot-brain harness, v1 the working architecture, v2 the JIT and its watchdog, v3 a persistence fallback Track P made unnecessary, and Track P, full transparent persistence.
- [docs/watchdog.md](docs/watchdog.md) — timeout-watchdog design, threat model, and measured prototype results.
- [docs/persistence-study.md](docs/persistence-study.md) — **Track P**: feasibility of a full-VM serializer for LuaJIT (transparent persistence). Positive verdict, since built: `serializer/eris_lj.c`, with the protocol in [docs/shell-fill.md](docs/shell-fill.md).
- [docs/openpython-persistence.md](docs/openpython-persistence.md) — case study of the only OC architecture with true mid-execution persistence.
- [docs/research/](docs/research/) — the raw multi-agent research reports behind all of the above, with file:line citations.
- [bench/](bench/) — benchmark suite and [measured results](bench/results-2026-09-01.md) (LuaJIT vs Lua 5.3/5.4).
- [prototype/watchdog/](prototype/watchdog/) — C harness validating async interruption of JIT-compiled Lua.
- [prototype/framewalk/](prototype/framewalk/) — M0 spike validating the suspended-coroutine serialization schema.

## Building

Requires a JDK 17+ to run Gradle (the mod itself compiles to Java 8 bytecode via the GTNH toolchain):

```bash
./gradlew build
```

Dev-run the client with OpenComputers present:

```bash
./gradlew runClient
```

## Layout

- `src/main/java/io/github/astronfo/ocluajit/` — mod entry point ([OCLuaJIT.java](src/main/java/io/github/astronfo/ocluajit/OCLuaJIT.java)) and the architecture ([arch/](src/main/java/io/github/astronfo/ocluajit/arch/)), which is a subclass of OpenComputers' own `NativeLuaArchitecture` plus a `LuaStateFactory` — not an implementation of `Architecture` from scratch.
- Natives ship inside the jar at `assets/opencomputers/lib/` — **OpenComputers'** asset namespace, not ours. `native/build-native.sh` builds them into `build/native/dist/`, `build.gradle.kts` stages them into the jar, and no binary is checked in. The path is not a preference: it is where OC's `LuaStateFactory` resolves a library from the classpath, and we inherit its loader rather than write one; the filename `libjnluajit52-*` is ours alone. Seen working in game since 2026-09-16: OpenComputers' own loader logs `Found a compatible native library` for our file. The patched kernel ships beside it under our own domain, at `assets/ocluajit/lua/machine.lua`. See [docs/research/shipping-model.md](docs/research/shipping-model.md).

## Acknowledgements

- [CCLuaJIT](https://github.com/vereena0x13/CCLuaJIT) — the JNI-bridge precedent for ComputerCraft.
- [OC-Wasm](https://gitlab.com/Hawk777/oc-wasm) / [OC-Wasm-GTNH](https://github.com/DCNick3/OC-Wasm-GTNH) and [OpenPython](https://github.com/OpenPythons/OpenPython) — third-party OC architecture precedents.
- Built on [GTNH ExampleMod1.7.10](https://github.com/GTNewHorizons/ExampleMod1.7.10).
- The shipped library contains [LuaJIT](https://luajit.org) and [OC-JNLua](https://github.com/MightyPirates/OC-JNLua), and its serializer derives from [Eris](https://github.com/fnuecke/eris). The jar also ships [OpenComputers](https://github.com/MightyPirates/OpenComputers)' `machine.lua`, patched. The test harness is [ocelot-brain](https://gitlab.com/cc-ru/ocelot/ocelot-brain). A proper NOTICE file is still to come (see the licensing row in [docs/roadmap.md](docs/roadmap.md)).
