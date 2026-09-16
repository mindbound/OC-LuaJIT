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

> **SUPERSEDED 2026-09-15 by "The port is a subclass, not a port", below.** This
> table prices a from-scratch implementation of `Architecture`. That turned out
> not to be the job: `NativeLuaArchitecture` is a `public abstract class` with
> exactly one abstract member, and OpenComputers' own three VMs are one-line
> subclasses of it. Almost every row below is inherited rather than written. The
> table is kept because the reasoning that chose (b) over (a) is unchanged, and
> because it is the estimate the later measurement should be read against.

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

## The binding layer, which the first version of this document missed

**CORRECTED 2026-09-15.** The cost table above prices (b) as ten `Architecture`
methods plus the `ArchitectureAPI` glue. That is incomplete, and the omission
matters, because an `Architecture` needs a Java `LuaState` to drive and ours
cannot be OpenComputers' own.

**Why not.** `native/lj52shim.h:42-43` does this deliberately:

```c
#undef  LUA_VERSION_NUM
#define LUA_VERSION_NUM 502   /* gives li.cil...jnlua.LuaState with no suffix */
```

because `jnlua.c:42-53` selects both the JNI class and the symbol suffix from
`LUA_VERSION_NUM` — 504 → `LuaStateFiveFour`, 503 → `LuaStateFiveThree`,
502 → `LuaState`, anything else → `#error`. So our native exports exactly one
family, `Java_li_cil_repack_com_naef_jnlua_LuaState_*`, and **is by construction
a replacement for OC's 5.2 native.** That is what makes the harness work, and it
is mechanism (a).

It cannot be what the mod ships. OpenComputers loads its own 5.2 native in
`preInit` and binds `li.cil.repack.com.naef.jnlua.LuaState`'s natives to it.
Two libraries exporting the same JNI symbols cannot both back one class, so an
`Architecture` reusing that class would get PUC Lua, not ours — and a mod that
*did* win the binding would have replaced OC's 5.2 for every computer in the
world, which is the additive principle inverted.

**The fix is the shape OC already uses to run three VMs in one JVM.** They do
not collide because each binds a *different class*:

| native | Java class | symbol family |
|---|---|---|
| `libjnlua52` | `LuaState` | `Java_…_LuaState_*` |
| `libjnlua53` | `LuaStateFiveThree` | `Java_…_LuaStateFiveThree_*` |
| `libjnlua54` | `LuaStateFiveFour` | `Java_…_LuaStateFiveFour_*` |

We become the fourth. `LuaStateFiveThree.java` is **332 lines** and
`LuaStateFiveFour.java` **290**, against `LuaState.java`'s 3145 — because a
version class is a thin subclass that **redeclares all 88 native methods with
`@Override`**. That redeclaration *is* the mechanism: it mints the distinct
symbol family. The rest is two version-specific id mappings
(`arith_operator_id`, `gc_action_id`) and constructors.

So `LuaStateLuaJIT extends LuaState`, ~300 lines, almost entirely mechanical,
with two working templates to copy.

**And the native needs a repack step.** The suffix and `JNI_LUASTATE_CLASS` come
from that closed `#if` chain, with no arm for us and no `-D` hook, so the build
must copy `jnlua.c` into the build directory and rewrite both there. A symbol
rename alone (`objcopy --redefine-sym`) is *not* enough — `JNI_LUASTATE_CLASS`
is a string used for `FindClass` at runtime, so it has to be a source
transform.

That is precisely the operation OpenComputers performed to turn upstream
`com.naef.jnlua` into `li.cil.repack.com.naef.jnlua`: OC-JNLua *is* a repack.
We would be doing what they did, for the same reason.

**What this costs the "unmodified `jnlua.c`" claim.** It narrows it rather than
killing it. The checkout stays pristine and `build-native.sh`'s `git status`
assertion keeps its meaning — it becomes a statement about the *input* to the
repack rather than about the compiled artifact. What must not happen is a fork
of `jnlua.c`'s *logic*; renaming its JNI surface is a build step, not a fork.

### Built and proven to link, 2026-09-15

`native/jnlua/gen-luastate-subclass.py` generates the class,
`native/jnlua/repack.sh` renames the C side, `build-native.sh` takes
`OCLJ_VARIANT=dropin|additive`, and `test/native/LinkProbe.java` loads the
result in a JVM and runs Lua through it: **5/5**, with the `_OCLJ_NATIVE`
marker reading `luajit/LuaJIT 2.1.ROLLING`. The additive library exports
**87 `LuaStateLuaJIT_*` symbols and zero in OpenComputers' `LuaState` family**,
so non-collision is a measured property of the binary rather than an argument
about macros.

**The nested `LuaDebug` is mandatory, and inspection could not have shown it.**
Compilation passed, `objdump` showed exactly the right export names, and the
library still would not load: `jnlua.c:1741` does
`referenceclass(JNI_LUASTATE_CLASS "$LuaDebug")`, so renaming the class string
renamed a nested class that did not exist, and `System.load` threw
`NoClassDefFoundError` before a single Lua call. It needs a `(JZ)V` constructor
and a `long luaDebug` field (`:1742-1743`).

**Emitting it as a subclass of `LuaState.LuaDebug` closes a hazard rather than
working around it.** The base's `getName()`/`getNameWhat()` dispatch virtually,
so they land on our overridden natives — meaning a handle produced by our
`lua_getstack` is read by *our* library and not by OpenComputers' PUC code,
which would be type confusion across two VMs. The constructor calls
`super(_, false)` deliberately: the base's finalize guardian calls *its own*
`lua_debugfree`, which would bind to OC's library and fire during GC.

Two Java-level details that cost a compile each, recorded because both are
counter-intuitive. `lua_getinfo`'s **parameter** must stay
`LuaState.LuaDebug` — Java parameter types are invariant, and only returns are
covariant — while `lua_getstack`'s **return** is deliberately left as the bare
(narrowed) `LuaDebug`, because that covariance is what carries our natives
along with the handle.

> **SUPERSEDED the same day, by "The port is a subclass, not a port" below.**
> This paragraph read *"Still outstanding: the factory. Nothing yet drives a
> machine through `LuaStateLuaJIT`; the probe runs bare Lua. The `Architecture`
> port needs a factory path … the one piece with no template on either side."*
> A machine does drive it now (AxisOS, to a login prompt), and the premise was
> wrong twice over: the factory has a template on **both** sides — an abstract
> `LuaStateFactory` with `version`/`create`/`openLibs` — and "loads our
> differently-named library" turned out to be the one thing we must **not** do
> ourselves, because the loader's private state is what `createState()` reads.

**Scope note for anyone reading the sections above.** Wherever this document or
the roadmap says "drop-in replacement for OC's 5.2 native", that describes the
HARNESS. The shipped mod replaces nothing: fourth class, fourth symbol family,
fourth entry in the CPU cycle, OC's three untouched.

## The port is a subclass, not a port, 2026-09-15

The cost table above is wrong, in our favour, and by a wide margin. It priced
writing `Architecture`. Nobody has to: **`NativeLuaArchitecture` is a
`public abstract class` whose only abstract member is `factory()`**, and
OpenComputers' own three VMs are one-line subclasses of it. Measured with
`javap` against the 1.12.58 `-dev` jar we build against:

```
public abstract class li.cil.oc.server.machine.luac.NativeLuaArchitecture
        implements li.cil.oc.api.machine.Architecture {
  public abstract LuaStateFactory factory();      <- the only abstract member
  public LuaState lua();                          public boolean initialize();
  public int kernelMemory();                      public ExecutionResult runThreaded(boolean);
  public double ramScale();                       public void runSynchronized();
  public boolean recomputeMemory(Iterable<ItemStack>);
  public void load(NBTTagCompound);               public void save(NBTTagCompound);
}
public class NativeLua52Architecture extends NativeLuaArchitecture {
  public LuaStateFactory$Lua52$ factory();        <- that is the entire class
}
```

`LuaStateFactory` is the same shape, and it is where every difference between
the VMs actually lives:

```
public abstract class li.cil.oc.server.machine.luac.LuaStateFactory {
  public abstract String version();
  public abstract LuaState create(scala.Option<Object>);
  public abstract void openLibs(LuaState);
  public void init();  public boolean isAvailable();  public Option<LuaState> createState();
}
```

So `runThreaded`, `runSynchronized`, `save`/`load`, and all seven
`ArchitectureAPI` subclasses — the ~823 lines the table called the bulk, and the
three rows it called hard — are **inherited, not ported**. The mod-side
adapter is `src/main/java/io/github/astronfo/ocluajit/arch/LuaJITArchitecture.java`:
a constructor and `factory()`.

### `version()` is the whole hook, and it is why the artifact got renamed

`LuaStateFactory` computes

```
libraryName = "libjnlua" + version() + "-" + platform + extension
```

as a **private** field, resolves and `System.load`s it in `init()`, and records
the outcome in **private** state that `createState()` reads. A subclass can
override `version()`, `create()` and `openLibs()`, and can touch none of the
rest. That single fact decides several things at once:

* Declaring `version() = "jit52"` points OpenComputers' own loader at
  `libjnluajit52-<platform><ext>`. The additive artifact was renamed from
  `libocluajit52-*` to exactly that (`native/build-native.sh`), so there is one
  name and nothing translates between a "harness name" and a "shipped name".
* We must let the base class do the loading. Overriding `init()` to load the
  library ourselves would leave those private fields unset and `createState()`
  returning `None` — which is what "native libraries not available" means, and
  is the error the first additive run produced for an unrelated reason.
* Therefore ~110 lines of `createState()` are inherited too, and that is the
  part worth having. It is where OpenComputers shapes the sandbox:
  `os.setlocale("C")`, removal of the 5.1 compat entries (`unpack`,
  `loadstring`, `math.log10`, `table.maxn`), dropping `dofile`/`loadfile`, and
  the per-state RNG. A copy of that in our source would be a second definition
  of OpenComputers' sandbox shape, and the first upstream change to it would
  make our architecture quietly different from the other three in a
  security-relevant way.

### Where the library has to live in the shipped mod

When `debug.forceNativeLibPathFirst` is unset — i.e. always, for a player —
`init()` resolves the library as a classpath resource at
`/assets/opencomputers/lib/<libraryName>`, built from **OpenComputers'** resource
domain. We cannot change that path without overriding `init()`, which strands us
on the wrong side of those private fields. Minecraft gives every mod one shared
classloader, so a resource shipped in **our** jar under
`assets/opencomputers/lib/` is found by that lookup. It is another mod's asset
namespace and we are a guest in it; what makes it safe is that the filename is
ours alone — `libjnluajit52-*` collides with nothing OpenComputers ships, and
`build-native.sh` fails the build if our library exports a single symbol in
OpenComputers' `LuaState` family. **Not yet verified in game.**

### What it costs

A dependency on `li.cil.oc.server.*`, which is OpenComputers' implementation
rather than its published `li.cil.oc.api`. Deliberate, and the alternative is
worse: reimplementing against the public API alone means maintaining our own
copy of the sandbox setup and the persistence protocol, and a divergence there
is a silent behavioural difference between architectures rather than a compile
error. Inheriting makes an upstream break a **build** failure, which is the
failure mode to prefer.

**That holds at build time only, and the gap is real.** We compile against a
version pinned in `dependencies.gradle`, but the `@Mod` dependency string is
`required-after:OpenComputers;` with no version range, so a player can load this
jar against an OpenComputers whose `NativeLuaArchitecture` has changed shape.
The result is a `NoSuchMethodError`/`AbstractMethodError` at class load — a
startup crash, not a build failure. Bounding the dependency is on the roadmap,
deliberately not guessed at here: a malformed FML version range stops the mod
loading entirely and nothing in this repository can run FML to check one.

### Proven by running it, on the side where running is possible

`test/native/OcljArch.scala` is the same construction against ocelot-brain,
whose `NativeLuaArchitecture` is a port of OpenComputers' and is if anything
*more* restrictive (there `lua`/`kernelMemory`/`ramScale` are `private[machine]`;
in OC they are public). A real machine boots AxisOS on it:

```
architecture   = ocljit.arch.OCLuaJITArchitecture
native marker  = luajit/LuaJIT 2.1.ROLLING
kernel (final) = watchdog
coexistence    = OpenComputers' own LuaState reports <stock PUC>
```

That last line is the one this whole document was written to establish, and it
is now measured rather than argued: with `forceNativeLibPathFirst` pointing at a
directory holding only `libjnluajit52-*`, OpenComputers' 5.2 factory misses,
falls back to its own bundled PUC-Lua native, and **our library and
OpenComputers' own 5.2 native are loaded together** — ours driving the machine,
OpenComputers' answering as a separate VM when asked. The no-collision claim
previously rested on a symbol count in `build-native.sh`.

State that precisely, because several natives were always loaded.
`Ocelot.initialize` calls `init()` on all three stock factories every run
(`LuaStateFactory.scala:42-44`), so PUC 5.3 and 5.4 load regardless — the
drop-in runs had three libraries in the JVM too. Coexistence *in general* was
never in doubt. What is new is that the native our drop-in **replaces** is
present at the same time as ours, and it is the only one that could ever have
collided: the drop-in is `libjnlua52`, binding the same `LuaState` class OC's
5.2 native binds, whereas 5.3 and 5.4 bind `LuaStateFiveThree` and
`LuaStateFiveFour` and were never contended.

What has **not** been run is the mod-side file, because running it needs a
Minecraft instance.

**AND IT PERSISTS, which took a second change to establish.** For a while this
was only a boot: `OcljSmoke`, which owns every persistence, deadline, RAM-cap and
bytecode-gate milestone, pinned `NativeLua52Architecture` unconditionally and its
`guard()` refused `ocljit.native=additive` outright, so those milestones had only
ever been measured on the DROP-IN shape. That mattered concretely rather than
pedantically: the natives `PersistenceAPI` drives (`lua_dump`,
`lua_pushbytearray`, `lua_tobytearray`, `lua_next`, `lua_rawset`) are redeclared
into our own JNI symbol family by `LuaStateLuaJIT`, so a persistence result from
the drop-in was a result about a **different binding**. Inheriting `save`/`load`
was a reason to expect it to work, not evidence that it did.

The suite now takes the architecture from the same switch as the native, and on
the additive arm reports **32 checks, 0 failures**: persist 160 355 bytes in
35 ms, restore into a fresh workspace with an identical boot nonce and the
counter advanced 151 -> 442, `lastError` null, the deadline firing with the
machine surviving, and the RAM cap OOMing at the cap. Two things had to be
fixed to get there, both of which had been invisible: `setArchitecture` checks
the class against `MachineAPI`'s registry and throws for anything unregistered
(so `register()` is required, not optional, and this document's adapter comment
said the opposite); and `m2-persist-flush-observed` was gated on the literal
`nativeMode == "luajit"`, which SKIPPED it for the one shape we ship -- and a
skipped milestone reads exactly like a passing one.

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
