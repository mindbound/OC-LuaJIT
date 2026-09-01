# OC-LuaJIT

A LuaJIT-based CPU architecture addon for [GTNH OpenComputers](https://github.com/GTNewHorizons/OpenComputers) (Minecraft 1.7.10).

Adds a **LuaJIT** architecture selectable with shift+right-click on any OC CPU, alongside the stock Lua 5.2/5.3/5.4 and LuaJ options. The trade: roughly 3–15× faster compute-bound Lua in exchange for persistence — LuaJIT computers reboot on chunk reload, exactly like OC's LuaJ fallback (a mode OC supports first-class).

**Status: skeleton.** The architecture registers and appears in CPU cycling, but the native LuaJIT bridge is not implemented yet — booting a LuaJIT computer produces a "not implemented" crash screen.

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

- `src/main/java/io/github/astronfo/ocluajit/` — mod entry point ([OCLuaJIT.java](src/main/java/io/github/astronfo/ocluajit/OCLuaJIT.java)) and the architecture stub ([arch/LuaJITArchitecture.java](src/main/java/io/github/astronfo/ocluajit/arch/LuaJITArchitecture.java)).
- Planned: `src/main/cpp/` for the JNI bridge, `src/main/resources/assets/ocluajit/lib/` for per-platform LuaJIT natives (shipped and extracted the same way OC ships JNLua).

## Acknowledgements

- [CCLuaJIT](https://github.com/vereena0x13/CCLuaJIT) — the JNI-bridge precedent for ComputerCraft.
- [OC-Wasm](https://gitlab.com/Hawk777/oc-wasm) / [OC-Wasm-GTNH](https://github.com/DCNick3/OC-Wasm-GTNH) and [OpenPython](https://github.com/OpenPythons/OpenPython) — third-party OC architecture precedents.
- Built on [GTNH ExampleMod1.7.10](https://github.com/GTNewHorizons/ExampleMod1.7.10).
