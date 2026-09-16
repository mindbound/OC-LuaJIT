# OC-LuaJIT

A LuaJIT-based CPU architecture addon for [GTNH OpenComputers](https://github.com/GTNewHorizons/OpenComputers) (Minecraft 1.7.10).

Adds a **LuaJIT** architecture selectable with shift+right-click on any OC CPU, alongside the stock Lua 5.2/5.3/5.4 and LuaJ options — additive, never a replacement for any of them.

**Persistence is NOT the trade.** An earlier version of this file said LuaJIT computers would reboot on chunk reload, like OC's LuaJ fallback. That premise was disproved: `serializer/eris_lj.c` persists and restores a full LuaJIT state, suspended coroutines and live for-in loops included, through OC's own `PersistenceAPI`. The harness boots OpenOS 1.8.9, persists it, restores it into a fresh workspace and asserts the machine *resumed* — same boot nonce, counter still counting.

**Status: runs in the harness, not yet in Minecraft.** Real operating systems boot on the LuaJIT VM under [ocelot-brain](https://gitlab.com/cc-ru/ocelot/ocelot-brain), driven by **our own `Architecture` and our own `LuaState` class**, with OpenComputers' stock PUC-Lua 5.2 native loaded alongside in the same JVM:

| run | what it establishes |
|---|---|
| OpenOS 1.8.9, smoke suite | boots to a shell, **persists and resumes** (same boot nonce, counter still counting), the deadline watchdog fires and the machine survives, the RAM cap holds and OOMs at the cap, the bytecode gate refuses — 32 checks, 0 failures |
| AxisOS, census | boots to a login prompt over 14000 ticks, emergency collector refusing nothing |

Both run on `ocljit.arch.OCLuaJITArchitecture` over the additive `libjnluajit52` library, which is the shape the mod ships. The same suite also runs in two control arms — our VM as a drop-in under OpenComputers' own 5.2 architecture, and stock PUC-Lua 5.2 as a baseline — and each arm refuses the others' fingerprint.

The mod-side adapter compiles against the pinned OpenComputers jar and **has never been run**, because running it needs a Minecraft instance. One known gap there: the patched watchdog kernel has no delivery mechanism in a real mod — see [docs/roadmap.md](docs/roadmap.md).

## Documentation

- [docs/feasibility.md](docs/feasibility.md) — the full feasibility study: architecture integration, performance, persistence constraints. Read this first.
- [docs/roadmap.md](docs/roadmap.md) — the living roadmap (v1 interpreter-only → v2 JIT + CHECKHOOK → v3 data persistence, plus Track P).
- [docs/watchdog.md](docs/watchdog.md) — timeout-watchdog design, threat model, and measured prototype results.
- [docs/persistence-study.md](docs/persistence-study.md) — **Track P**: feasibility of a full-VM serializer for LuaJIT (transparent persistence). Positive verdict; M0 validated.
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
- Natives are **planned** to ship at `src/main/resources/assets/opencomputers/lib/` — **OpenComputers'** asset namespace, not ours. That directory does not exist yet and nothing produces it; `native/build-native.sh` writes to `build/native/`. The path is not a preference: it is where OC's `LuaStateFactory` resolves a library from the classpath, and we inherit its loader rather than write one. Minecraft's shared classloader should make a resource in our jar visible there, and the filename `libjnluajit52-*` is ours alone — but **that is reasoned, not measured**, and stays unverified until the mod runs in game. See [docs/research/shipping-model.md](docs/research/shipping-model.md).

## Acknowledgements

- [CCLuaJIT](https://github.com/vereena0x13/CCLuaJIT) — the JNI-bridge precedent for ComputerCraft.
- [OC-Wasm](https://gitlab.com/Hawk777/oc-wasm) / [OC-Wasm-GTNH](https://github.com/DCNick3/OC-Wasm-GTNH) and [OpenPython](https://github.com/OpenPythons/OpenPython) — third-party OC architecture precedents.
- Built on [GTNH ExampleMod1.7.10](https://github.com/GTNewHorizons/ExampleMod1.7.10).
