# The smoke suite on OUR architecture — persistence, not just boot

**2026-09-16.** The first run in which OpenComputers' full persistence,
deadline, RAM-cap and bytecode-gate suite is driven by `OCLuaJITArchitecture`
over the additive `libjnluajit52` library — the shape the mod ships.

    OCLJ_NATIVE=additive OCLJ_LIBDIR=build/native/libdir-additive \
      OCLJ_BENCH_ONLY="" sh test/native/smoke-test.sh

## Why this run exists

A roadmap audit found that every milestone in the suite had been measured on the
**drop-in** shape — our VM under OpenComputers' own `NativeLua52Architecture`.
`OcljSmoke` pinned that class unconditionally and its `guard()` refused
`ocljit.native=additive` outright. So our `Architecture` was proven to BOOT
(AxisOS, `../2026-09-15-census-axisos-additive/`) and had never saved a machine.

That distinction is not pedantic. `LuaStateLuaJIT` redeclares 82 natives into its
own JNI symbol family, and five of them are exactly what `PersistenceAPI` drives:
`lua_dump`, `lua_pushbytearray`, `lua_tobytearray`, `lua_next`, `lua_rawset`. A
persistence result from the drop-in is a result about a **different binding**.
Inheriting `save`/`load` was a reason to expect this to work, not evidence.

## Result — 32 checks, 0 failures

    architecture pinned to ocljit.arch.OCLuaJITArchitecture   (ocljit.native=additive)
    FINGERPRINT: native=luajit/LuaJIT 2.1.ROLLING | class=LuaStateLuaJIT | ...

    f1-persist-blob                 persist ok, 160355 bytes in 35 ms
    f2-restore-same-vm              boot nonce before == after
    f3-restore-counter-continues    counter 151 -> 442, running=true
    f4-restore-no-error             lastError null
    f5-restore-memory-accounted     kernelMemory 356466
    k1-deadline-still-fires         too_long_without_yielding after 280 ticks, machine survived
    m2-persist-flush-observed       mcode 196608 -> 0 B, traces 292 -> 0
    e1-e4                           cap holds, frees credited, OOM at the cap
    g1-g3                           bytecode refused, text still loads, eris path open

## The three arms, and what separates them

| arm | architecture | LuaState class | checks |
|---|---|---|---|
| additive (this run) | `OCLuaJITArchitecture` | **`LuaStateLuaJIT`** | 32 / 0 |
| dropin | `NativeLua52Architecture` | `LuaState` | 32 / 0 |
| stock baseline | `NativeLua52Architecture` | (PUC) | 28 / 0 |

`class=` is new to the fingerprint and is the only thing that can tell the first
two apart: they are the same LuaJIT behind different JNI symbol families, so the
`_OCLJ_NATIVE` marker reads identically in both. The guard now refuses each arm's
fingerprint in the other's mode.

## Two defects this run exposed, both silent

**`setArchitecture` requires registration.** `MutableProcessor.setArchitecture`
checks the class against `MachineAPI`'s registry and throws `"Unsupported
processor type."` for anything absent (`MutableProcessor.scala:26-29`). The
adapter's own comment claimed `register()` was optional "because setArchitecture
takes a class directly". It does, and then rejects it. `CensusOs` happened to
register; `OcljSmoke` did not, and died at the pin.

**`m2-persist-flush-observed` was gated on the literal `nativeMode == "luajit"`**,
so it was SKIPPED for the additive arm — the one shape we ship. A skipped
milestone prints nothing and reads exactly like a passing one. It is gated on
`!= "stock"` now, and passes here.
