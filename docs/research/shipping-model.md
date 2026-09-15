# How this mod ships: our own Architecture, not native substitution

*Resolved 2026-09-15, by reading the real GTNH OpenComputers artifacts that
`dependencies.gradle` builds against.*

Everything this project has proven — OpenOS booting, the JIT running, `eris`
persisting and restoring, the RAM cap, the watchdog — was proven by
**substituting our native library beneath OpenComputers' own PUC-Lua
architecture**. We have never used our own `Architecture` class;
`LuaJITArchitecture.java` is a stub whose `runThreaded` returns an error.

So there were two candidate products, and we had validated the one the roadmap
does not plan:

* **(a)** ship a replacement native library that OC's existing architecture loads
* **(b)** ship our own `Architecture`, registered with OC

**The answer is (b). (a) cannot be a product, for a reason that is structural
rather than a matter of taste.** Keep (a) — it is the harness, and it is doing
exactly the job it should.

## (a) exists in the shipping mod, and we still cannot use it

The override is real, and it is not an ocelot-brain invention:

```scala
li/cil/oc/server/machine/luac/LuaStateFactory.scala:200-210
  if (!Strings.isNullOrEmpty(Settings.get.forceNativeLibPathFirst)) {
    val libraryTest = new File(Settings.get.forceNativeLibPathFirst, libraryName)
    if (libraryTest.canRead) { tmpLibFile = libraryTest; currentLib = ... }
```

backed by `Settings.scala:459` reading `debug.forceNativeLibPathFirst`, default
`""` at `application.conf:1576`, whose own documentation says *"Use this if you
want to use custom native libraries, or are on an unsupported platform. If
unsure, leave blank."* When it hits, no extraction happens — the file loads in
place.

**The blocker is load order, and it is absolute.** OC reads its config and loads
its native in the *same* `preInit`:

```scala
common/Proxy.scala:32   Settings.load(e.getSuggestedConfigurationFile)
common/Proxy.scala:74   if (LuaStateFactory.isAvailable)     // forces Lua52/53/54 objects
LuaStateFactory.scala   init() runs in each object's constructor body -> System.load
```

and our mod declares `dependencies = "required-after:OpenComputers;"`
(`OCLuaJIT.java:15`), so FML sorts us **after** OC. By the time any of our code
executes — even in `preInit` — the DLL is resolved and loaded. There is no
moment at which we could set the key.

Four further problems, any one of which would be enough:

* It is a `debug.*` key defaulting to empty, with no code path that ever sets it.
  A player must hand-edit `config/opencomputers.cfg`.
* No first-class supply mechanism exists. OC's `IMC.java` offers ten hooks —
  assembler filters and templates, wrench tools, ink, power systems, disk labels
  — and **nothing for natives**.
* It is global and destructive rather than additive. To win, our DLL must be
  *named* `libjnlua52-windows-x86_64.dll` and impersonate OC's Lua 5.2. Every
  computer in the world switches at once, and stock 5.2 becomes unreachable —
  there is no fallback once `currentLib` is set.
* Our own harness is the proof it is a fixture: `smoke-test.sh:285` writes the
  key into a generated config, and `OcljSmoke.scala` guards against a silently
  mis-resolved DLL.

## (b) is the documented extension point

`api.Machine.add(Class<? extends Architecture>)` (`api/Machine.java:33`), which
OC's own source describes as exactly this use case:

> *"Registering an architecture will make it possible to configure CPUs to run
> that architecture. **This allows providing architectures without implementing
> a custom CPU item.**"* — `api/Machine.java:26-29`
>
> *"This allows the introduction of other languages, e.g. computers that run
> assembly or some other language interpreter."* — `api/machine/Architecture.java:15-18`

There is no comparable language anywhere about third-party natives.

**Our stub already complies with the two contracts that matter.** Registration
happens in `FMLInitializationEvent` (`OCLuaJIT.java:22-28`), honouring
*"should not be called in the pre-init phase … only start calling these methods
in the init phase or later"* (`api/Machine.java:19-21`); and
`@Architecture.Name("LuaJIT")` is present (`LuaJITArchitecture.java:26`). The one
unstated requirement is a public constructor taking `Machine`, enforced
reflectively at `server/machine/Machine.scala:1079-1082` — our stub has it.

**Player-facing:** sneak + right-click the CPU item cycles architectures
(`common/item/traits/CPULike.scala:28-48`), with the choice stored on the
`ItemStack` as `opencomputers:archClass` / `archName`
(`integration/opencomputers/DriverCPU.scala:62-67`). Two consequences worth
having: an un-tagged CPU defaults to the *first registered* (`DriverCPU.scala:59`),
and OC registers its own in `preInit` while we register in `init`, so **we can
never become the silent default**. And if our mod is removed, `DriverCPU.scala:52-57`
resets the CPU to the default rather than breaking the save.

OC ships a precedent for precisely this shape: **LuaJ** is a fully separate
package with its own six `ArchitectureAPI` subclasses and its own VM, registered
conditionally, and `application.conf:1633-1636` exists only to make it appear in
the CPU cycle list — *"In that case it is possible to switch between the two like
any other registered architecture."*

## What (b) costs

Ten interface methods (`api/machine/Architecture.java`), measured against OC's
own `NativeLuaArchitecture.scala` (438 lines):

| | methods | notes |
|---|---|---|
| trivial | `isInitialized`, `close`, `onSignal`, `onConnect` | ~15 lines total; `onSignal` is literally `{}` |
| small | `recomputeMemory` | ~17 lines; ours must install the counting allocator at `lua_newstate` time, already noted at `LuaJITArchitecture.java:55-57` |
| medium, but fronting the bulk | `initialize` | 20 lines itself — behind it sit **seven `ArchitectureAPI` subclasses, ~823 lines** (`Component`, `Computer`, `OS`, `System`, `Unicode`, `Userdata`, `Persistence`). `PersistenceAPI` must go last |
| hard | `runThreaded` | ~107 lines: the yield-classification state machine (function ⇒ `SynchronizedCall`, boolean ⇒ `Shutdown`, number ⇒ `Sleep`), first-run init with its fake zero sleep, dead-kernel handling, exception mapping — **and it must self-enforce `Settings.timeout`** (`Architecture.java:98-101`) |
| hard | `runSynchronized` | short but a strict stack-shape protocol; a leaked exception logs *"Faulty architecture implementation for synchronized calls"* and crashes the computer (`Machine.scala:624`) |
| hard | `save` / `load` | ~90 lines, and the only part that reaches **outside the API**: `SaveHandler` and a cast to the internal `li.cil.oc.server.machine.Machine` for `state` |

**The good news, and it is substantial: this is a diff-port, not a from-scratch
write.** ocelot-brain's `NativeLuaArchitecture.scala` is a direct port of OC's —
~85% identical, with `runThreaded`, `runSynchronized`, `initialize` and `close`
effectively byte-identical modulo the logger. Divergences are exactly the
Minecraft-shaped ones: package and logger names, dropped annotations,
`Iterable[ItemStack]` vs `Iterable[Entity]`, ocelot's extra
`freeMemory`/`totalMemory` overrides (which belong in `ComputerAPI` on the OC
side), the persistence sink, and state access. **ocelot-brain left OC's original
lines commented out directly above each replacement** — verified at all four
persistence sites — so the reverse port is mechanical.

## What this de-risks, and it is more than the question asked

Three things the whole project rests on turn out to be the same in the harness
and in the shipping mod. Until now that was an assumption.

* **The kernel text.** GTNH OC 1.12.58's `machine.lua` differs from the harness's
  by **one line** in 1548 — GTNH adds `realTime = computer.realTime` to the
  sandbox `computer` table. Confirmed against both the 1.12.55 sources jar and
  the 1.12.58 dev jar we build against. *(A naive `diff` reports 3095 changed
  lines; that is CRLF vs LF. Always `--strip-trailing-cr` here.)*
* **The kernel transformation.** `native/kernel/patch-machine-lua.lua` applies
  cleanly to the real GTNH kernel: `ok 47162 -> 47607 bytes, 4 sites, 3
  debug.sethook left`, exit 0. The patcher refuses when an anchor misses
  (`smoke-test.sh:314` treats that as fatal), so this is a real pass.
* **The substitution point.** `LuaStateFactory` is a line-for-line port between
  the two, `forceNativeLibPathFirst` block included.

## Open, and how each would be settled

1. **Whether our Eris-format output round-trips through OC's `PersistenceAPI`
   in a real save / chunk-unload / reload cycle.** Nothing in the OC source
   answers it. Settled by an in-game test.
2. **Whether `SaveHandler` and the `Machine.state` cast are reachable from our
   classloader in a production (obfuscated) environment.** Both are in the `-dev`
   jar and absent from the `-api` jar. Settled by a probe in `runClient`.
   Mitigation if not: track the sync-call flag ourselves from our own
   `runThreaded`/`runSynchronized` transitions, which OC's own source recommends
   anyway (`NativeLuaArchitecture.scala:343-346` marks the cast deprecated).
3. **Whether `NativeLuaArchitecture` changed between 1.12.55 and 1.12.58.** Only
   `-dev` is cached for .58; the `Architecture` interface and
   `forceNativeLibPathFirst` are confirmed unchanged, which covers every claim
   here, but the implementation bodies were not diffed. Settled by fetching the
   1.12.58 sources jar.
4. **Whether GTNH would take an upstream hook for third-party natives or
   architectures.** Settled by asking, not by reading.
