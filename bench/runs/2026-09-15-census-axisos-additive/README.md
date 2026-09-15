# AxisOS on the ADDITIVE architecture — the Architecture port, running

**2026-09-15.** The first run in which an OpenComputers machine is driven by
OC-LuaJIT's own `Architecture` and its own `LuaState` class, rather than by
OpenComputers' 5.2 architecture over a substituted native.

    OCLJ_NATIVE=additive OCLJ_LIBDIR=build/native/libdir-additive \
      sh test/native/census-os.sh <axis-os>/src/kernel AxisOS <axis-os>/eeprom/boot.lua 14000

## Result

    architecture   = ocljit.arch.OCLuaJITArchitecture
    native marker  = luajit/LuaJIT 2.1.ROLLING
    kernel (final) = watchdog
    coexistence    = OpenComputers' own LuaState reports <stock PUC>
    ticks run      = 14000 of 14000   (running=true)
    lastError      = <none>
    GC PRESSURE    = arms=141316 collects=141315 bailouts=0 refusals=0

Screen ends at `localhost login:`.

## What is new here, against `../2026-09-15-census-axisos/`

That run booted the same system on the **dropin** library — our LuaJIT wearing
OpenComputers' `libjnlua52` name, driven by OC's own `NativeLua52Architecture`.
Only one VM existed in the JVM, and it was ours.

This run is the shipped shape. `forceNativeLibPathFirst` points at a directory
holding only `libjnluajit52-*`, so OpenComputers' 5.2 factory **misses**, falls
back to its own bundled PUC-Lua native, and both are live at once. The
`coexistence` line is a PUC 5.2 state created alongside the running machine and
asked which VM it is; it answers `<stock PUC>` while our machine answers
`luajit/LuaJIT 2.1.ROLLING`. Before this, "the two libraries cannot collide"
rested on a symbol count in `build-native.sh`.

**Be precise about what is new, because several VMs were always in the JVM.**
`Ocelot.initialize` calls `init()` on all three stock factories every run
(`LuaStateFactory.scala:42-44`), so the PUC 5.3 and 5.4 natives load whatever
else is happening — the drop-in runs had three libraries loaded too. Multiple
natives coexisting was never in doubt. What is new is that **OpenComputers' own
5.2 native** is loaded beside ours, and that is the only one that could ever
have collided: the drop-in IS `libjnlua52`, binding the `LuaState` class OC's
5.2 native binds. 5.3 and 5.4 bind `LuaStateFiveThree` and `LuaStateFiveFour`
and were never contended. So the claim this run establishes is narrow and exact:
*our library and the one native it could have collided with are loaded together,
and each answers as itself.*

## Side by side

| | dropin (`../2026-09-15-census-axisos/`) | additive (here) |
|---|---|---|
| architecture | `NativeLua52Architecture` (OC's) | `OCLuaJITArchitecture` (ours) |
| native libraries loaded | 3: ours-as-5.2, PUC 5.3, PUC 5.4 | 4: ours, **PUC 5.2**, PUC 5.3, PUC 5.4 |
| OC's own 5.2 native present | no — ours occupies that name | **yes, at the same time as ours** |
| result | `localhost login:` | `localhost login:` |
| peak used | 2 621 157 B | 2 741 421 B |
| kernelMemory | 326 085 B | 389 825 B |
| emergency GC arms | 99 542 | 141 316 |
| refusals | 0 | 0 |

**Read the memory and arm figures as the same result, not as a regression.**
The two runs are not a controlled comparison of the architectures: the tick
budget is the same but the boot is not deterministic, LuaJIT's allocator is not
either, and the additive run's `kernelMemory` (389 825 B) differs from a
2000-tick additive run of the same build (320 493 B) by more than it differs
from the dropin's. What the numbers do support is the claim that matters here —
the architecture change does not move the machine near its cap, and the
allocator still refuses **nothing** across ~141 000 emergency cycles.

## Caveats

`census.txt` is the census section of `run.log` verbatim. An earlier copy was
filtered with `grep "^CENSUS|"`, which silently dropped the screen dump — the
screen lines carry no prefix — leaving the AxisOS login prompt as an empty block
between its own delimiters. The one curated artifact for this run could not
support the claim it is cited for.

`run.log` ends in `SMOKE FAIL`. That is the bug this run exposed, not a result:
the harness's verdict gates were hard-coded to the OpenOS main, so **every**
census run ever taken ended that way regardless of outcome. Fixed in the same
commit (`OCLJ_VERDICT=census`); re-running now prints `CENSUS PASS`. The census
main's own verdict, `CENSUS| VERDICT: no panic text on screen`, was correct
throughout and is the line to read in this log.
