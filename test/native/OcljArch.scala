package ocljit.arch

import li.cil.repack.com.naef.jnlua
import li.cil.repack.com.naef.jnlua.{LuaState, LuaStateLuaJIT}
import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.machine.{Machine, MachineAPI}
import totoro.ocelot.brain.entity.machine.luac.{LuaStateFactory, NativeLuaArchitecture}

import java.nio.file.{Files, Path, Paths}

/**
  * THE OCELOT-BRAIN ADAPTER: OC-LuaJIT as a real OpenComputers architecture.
  *
  * This is one of the two adapters in the shipping design.  The other targets
  * OpenComputers itself and cannot run outside Minecraft; this one runs here,
  * which is why it is written first -- the alternative was ~1000 lines of
  * OC-side code that nothing could execute until a game existed to load it.
  *
  * WHAT IT IS NOT.  It is not a port of NativeLuaArchitecture.  The survey of
  * that class (444 lines) found exactly one reference to `factory` in the whole
  * body -- `factory.createState()` in initialize() -- and NO version-conditional
  * logic anywhere: no branch on 5.2 vs 5.3, no bit32/utf8 special-casing, no
  * read of factory.version.  Everything that differs between OpenComputers'
  * three VMs lives in LuaStateFactory.  So the architecture is a one-liner and
  * the real work is the factory below, which is as it should be: the VM is the
  * thing we are replacing, and the machine around it is not.
  *
  * WHAT IT PROVES THAT LinkProbe DOES NOT.  LinkProbe runs bare Lua through
  * LuaStateLuaJIT.  This runs a MACHINE: OC's own machine.lua kernel, the
  * component/computer/os/system/unicode/userdata APIs, the RAM cap, the
  * deadline hook, and eris persistence -- all of it inherited, none of it
  * reimplemented.  And when the harness points forceNativeLibPathFirst at a
  * directory holding only our additive library, OpenComputers' real PUC-Lua 5.2
  * native loads alongside ours in the same JVM.  That is the shipped
  * configuration, and it tests the no-collision claim by running it rather than
  * by counting symbols.
  *
  * DELIBERATELY OUTSIDE totoro.ocelot.brain.*.  `lua`, `kernelMemory`,
  * `ramScale`, `persistence` and `apis` are all private[machine]; from this
  * package they are invisible.  That is the point.  A third-party mod cannot
  * reach them either, so an adapter that quietly did would prove nothing about
  * whether the real one can be built.
  */
class OCLuaJITArchitecture(machine: Machine) extends NativeLuaArchitecture(machine) {

  /**
    * Swap in OC-LuaJIT's patched kernel, WITHOUT reimplementing initialize().
    *
    * THE PROBLEM. `NativeLuaArchitecture.initialize()` loads the kernel with
    * `classOf[Machine].getResourceAsStream(Settings.scriptPath + "machine.lua")`
    * -- a fixed path in OPENCOMPUTERS' resource domain. The harness gets its
    * patched kernel in by putting it first on the classpath so it shadows OC's,
    * which works only because the harness builds that classpath. A Minecraft
    * instance does not let us: FML loads mod jars in an order we do not choose,
    * and OC's own jar holds that exact resource. Unlike the native, where the
    * FILENAME is ours alone, here the path is byte-identical -- so "ours wins"
    * is a coin flip, and every deadline and JIT result depends on it.
    *
    * WHY NOT OVERRIDE initialize() OUTRIGHT. It is only sixteen lines, but four
    * of them are `apis.foreach(_.initialize())`, and `apis` is private with no
    * accessor in EITHER host -- so those four lines cannot be reproduced from
    * outside the package at all. super.initialize() is not a convenience here,
    * it is the only way to get the APIs installed.
    *
    * WHY NOT INTERCEPT debug.sethook IN THE NATIVE, which would need no kernel
    * of ours at all: the kernel's three deadline arms are
    * `debug.sethook(co, checkDeadline, "", hookInterval)`, but machine.lua:47
    * calls `debug.sethook(coroutine.running(), checkDeadline, "", 1)` -- the
    * SAME function with a different count, deliberately firing at once. Telling
    * those apart from C means pattern-matching the kernel's internals, which is
    * MORE coupled to its exact shape than patching its text, and which would
    * mis-fire silently where patch-machine-lua.lua refuses loudly.
    *
    * SO: let initialize() do all of its work, then replace only what it loaded.
    * It leaves the kernel thread as the first stack value; we drop that, load
    * ours from OUR OWN resource domain, and make a thread of it again. Six
    * lines, no path collision, and identical in the harness and in the mod --
    * the mod reads `lua()` directly, which OpenComputers exposes publicly,
    * while ocelot-brain makes it private[machine] and needs the reflection
    * below. Same sequence either way, so the harness genuinely tests it.
    */
  override def initialize(): Boolean = {
    if (!super.initialize()) return false
    val patched = classOf[OCLuaJITArchitecture].getResourceAsStream(OCLuaJITArchitecture.KernelResource)
    if (patched == null) {
      // NOT silent. Falling back to OpenComputers' kernel still RUNS -- that is
      // the OCLJ_KERNEL=stock arm -- but it reinstates the standing count hook,
      // which is what stops traces being entered at all: measured 0.47 s for a
      // sandbox loop against 0.0046 s with the watchdog. A hundredfold
      // slowdown is not something to discover from a benchmark.
      Ocelot.log.warn("OC-LuaJIT: no patched kernel at " + OCLuaJITArchitecture.KernelResource +
        " -- falling back to OpenComputers' own machine.lua and its standing deadline hook. " +
        "The JIT will thrash. Check that the build placed the patched kernel.")
      System.err.println("[ocljit] no patched kernel at " + OCLuaJITArchitecture.KernelResource)
      return true
    }
    val l = OCLuaJITArchitecture.luaOf(this)
    l.pop(1)                       // initialize() left OC's kernel thread here
    l.load(patched, "=machine", "t")
    l.newThread()                  // and runThreaded expects a thread at index 1
    true
  }

  /** The only other member this architecture overrides.  ensureInitialized() rides
    * here because Ocelot.initialize() calls init() on the THREE factories it
    * knows about and has no fourth entry to copy -- and factory is reached
    * exactly once, from initialize(), before any state is created. */
  override protected def factory: LuaStateFactory = {
    OCLuaJITStateFactory.ensureInitialized()
    OCLuaJITStateFactory
  }
}

/**
  * The LuaJIT LuaState factory: `version` is the whole hook.
  *
  * LuaStateFactory computes `libraryName = "libjnlua" + version + "-" +
  * platform + ext` as a PRIVATE val, loads it in init(), and records the result
  * in two PRIVATE fields that createState() reads.  A subclass can override
  * `version`, `create` and `openLibs`, and can touch none of the rest.
  *
  * So declaring version "jit52" makes the base class's own loader go looking
  * for libjnluajit52-<platform><ext> -- the name build-native.sh gives the
  * additive variant -- and on finding it, set its own private state.  Roughly
  * 110 lines of sandbox preparation in createState() (os.setlocale("C"), the
  * removal of the 5.1 compat entries unpack/loadstring/math.log10/table.maxn,
  * dropping dofile/loadfile, and the per-state RNG that replaces C rand()) are
  * then INHERITED rather than copied.  Copying them would have been a second
  * implementation of OpenComputers' sandbox shape, drifting silently the first
  * time upstream changed it -- and that shape is security-relevant.
  */
object OCLuaJITArchitecture {

  /** OUR resource domain, deliberately. The whole point is not to contend with
    * OpenComputers for /assets/opencomputers/lua/machine.lua. */
  val KernelResource = "/assets/ocluajit/lua/machine.lua"

  /**
    * ocelot-brain declares `lua` as private[machine], so an adapter outside
    * that package cannot see it. The mod side needs no such thing -- OC exposes
    * `lua()` publicly -- but the harness is where this mechanism can actually
    * be RUN, so it reaches the field the way CensusOs already does.
    */
  def luaOf(arch: NativeLuaArchitecture): LuaState = {
    val f = classOf[NativeLuaArchitecture].getDeclaredField("lua")
    f.setAccessible(true)
    f.get(arch).asInstanceOf[LuaState]
  }
}

object OCLuaJITStateFactory extends LuaStateFactory {

  /** Chosen so libraryName() comes out as libjnluajit52-<platform><ext>.
    * Changing it renames the file the loader hunts for, so build-native.sh's
    * DLL_NAME and the mod adapter's LuaJITStateFactory.version() must agree. */
  override def version: String = "jit52"

  override protected def create(maxMemory: Option[Int]): jnlua.LuaState =
    maxMemory.fold(new LuaStateLuaJIT())(new LuaStateLuaJIT(_))

  /**
    * OpenComputers' 5.2 library set, exactly.
    *
    * BIT32 and not UTF8: we are a 5.2-class VM (LuaJIT is 5.1 plus partial 5.2
    * compat), machine.lua is written against that surface, and the split is not
    * cosmetic -- it is why QuickOS boots on neither us nor OC's own 5.2 native
    * (docs/research/os-shape-census.md).  Diverging here would make us a fourth
    * dialect nobody's OS targets.
    */
  override protected def openLibs(state: jnlua.LuaState): Unit = {
    state.openLib(jnlua.LuaState.Library.BASE)
    state.openLib(jnlua.LuaState.Library.BIT32)
    state.openLib(jnlua.LuaState.Library.COROUTINE)
    state.openLib(jnlua.LuaState.Library.DEBUG)
    state.openLib(jnlua.LuaState.Library.ERIS)
    state.openLib(jnlua.LuaState.Library.MATH)
    state.openLib(jnlua.LuaState.Library.STRING)
    state.openLib(jnlua.LuaState.Library.TABLE)
    state.pop(8)
  }

  // ------------------------------------------------------------------ //

  private var initAttempted = false

  /** Where init() unpacks a library it had to take from a jar.  Irrelevant when
    * forceNativeLibPathFirst hits, which is the harness's normal path; it
    * matters only for the fallback, and a wrong value there fails loudly. */
  private def librariesPath: Path =
    Paths.get(sys.props.getOrElse("ocljit.librariespath", "."))

  /**
    * Load the native once, and SAY SO EITHER WAY.
    *
    * A factory that is merely unavailable produces None from createState(),
    * which surfaces as a machine that will not start -- a symptom that looks
    * identical to a dozen unrelated faults.  The base class logs its own
    * failure only at trace level unless logFullLibLoadErrors is set, so this
    * prints the outcome at info level with the name it was hunting for.
    */
  def ensureInitialized(): Unit = synchronized {
    if (initAttempted) return
    initAttempted = true
    val path = librariesPath
    try Files.createDirectories(path) catch { case _: Throwable => /* init will complain */ }
    init(path)
    // STDERR AS WELL AS THE LOG, because the log is not guaranteed to reach
    // anyone.  This harness runs log4j with no configuration, so its default
    // console appender emits ERROR and drops INFO and WARN -- which is how the
    // first additive run reported nothing but "native libraries not available",
    // a message from the MACHINE that says nothing about which file was missing
    // or where it was looked for.
    val msg =
      if (isAvailable) s"OC-LuaJIT: native ready (version=$version, from $path)"
      else s"OC-LuaJIT: NO NATIVE for version=$version -- the loader wanted " +
           s"libjnlua$version-<platform><ext>, either under " +
           s"debug.forceNativeLibPathFirst or as a bundled resource. " +
           s"Machines on this architecture will not start."
    if (isAvailable) Ocelot.log.info(msg) else Ocelot.log.warn(msg)
    System.err.println("[ocljit] " + msg)
  }

  /**
    * Register with ocelot-brain. REQUIRED BEFORE setArchitecture, not optional.
    *
    * An earlier version of this comment said it was optional, on the reasoning
    * that setArchitecture takes a class directly. It does, and then checks that
    * class against MachineAPI's registry and throws "Unsupported processor
    * type." if it is absent (MutableProcessor.scala:26-29). ocelot-brain
    * registers its own three during Ocelot.initialize; ours is a fourth nothing
    * else knows about, so every caller must do this first.
    */
  def register(name: String = "LuaJIT"): Unit =
    MachineAPI.add(classOf[OCLuaJITArchitecture], name)
}
