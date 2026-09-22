package ocljit.arch

import li.cil.repack.com.naef.jnlua
import li.cil.repack.com.naef.jnlua.{LuaGcMetamethodException, LuaRuntimeException, LuaState, LuaStateLuaJIT}
import totoro.ocelot.brain.{Ocelot, Settings}
import totoro.ocelot.brain.entity.machine.{Machine, MachineAPI}
import totoro.ocelot.brain.entity.machine.luac.{LuaStateFactory, NativeLuaAPI, NativeLuaArchitecture, PersistenceAPI}
import totoro.ocelot.brain.nbt.NBTTagCompound

import java.nio.file.{Files, Path, Paths}
import scala.collection.mutable

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
    // The state exists and eris is open (openLibs): set the for-in diagnostic
    // mode HERE, before the kernel swap, so both branches below get it.  The
    // mod does the same at the same point (LuaJITArchitecture.initialize).
    applyForinMode()
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

  // ------------------------------------------------------------------ //
  // The for-in diagnostic: -Docluajit.forin=ignore|warn|refuse
  // ------------------------------------------------------------------ //

  /**
    * The same half the mod carries (LuaJITArchitecture.java, same section):
    * set eris.settings("forin", mode) once the state exists, and after every
    * persist that RETURNED drain eris.diagnostics() -- the loops the
    * serializer could not replay, an OS author's own `next`-wrapper each
    * (docs/forin-iterator-gap.md, "The #9 diagnostic") -- to the log, each
    * distinct message once per machine.  Nothing here may fail a save or stop
    * a machine: every Lua step runs through LuaState methods that jnlua
    * protects with lua_pcall on the native side, so a refusal arrives as a
    * LuaRuntimeException, and each failure class is logged once.
    *
    * WHAT THE HARNESS ADDS: `forinDiagnostics`, every message the drains of
    * this machine's saves returned, in order, duplicates included -- the dg-1
    * milestone counts what ONE save produced -- and `lastSaveError`, the text
    * of a save that failed (refuse mode's evidence).  The BundleRoots=OFF
    * negative control falls through to super.save and drains nothing.
    */
  val forinDiagnostics: mutable.ArrayBuffer[String] = mutable.ArrayBuffer.empty[String]
  private val forinLogged = mutable.HashSet.empty[String]
  private var forinSettingFailed = false
  private var forinDrainFailed = false
  var lastSaveError: String = ""

  private def whichMachine(): String =
    try "computer " + machine.node.address catch { case _: Exception => "computer <unknown>" }

  private def applyForinMode(): Unit = {
    val mode = OCLuaJITArchitecture.ForinMode
    try OCLuaJITArchitecture.forinApply(OCLuaJITArchitecture.luaOf(this), mode)
    catch {
      case e: Exception =>
        if (!forinSettingFailed) {
          forinSettingFailed = true
          val msg = "OC-LuaJIT " + whichMachine() + ": could not set eris.settings(\"forin\", \"" + mode + "\"): " + e +
            " -- the for-in diagnostic is OFF for this machine. A serializer that predates the setting answers " +
            "exactly this way; the machine starts regardless."
          Ocelot.log.warn(msg)
          System.err.println("[ocljit] " + msg)
        }
    }
  }

  private def drainForinDiagnostics(lua: LuaState): Unit = {
    val mode = OCLuaJITArchitecture.ForinMode
    if (mode == "ignore") return
    try {
      val msgs = OCLuaJITArchitecture.forinDrain(lua)
      forinDiagnostics ++= msgs
      for (m <- msgs if forinLogged.add(m)) {
        val line = "OC-LuaJIT " + whichMachine() + " (for-in diagnostic, -D" + OCLuaJITArchitecture.ForinProperty +
          "=" + mode + "): " + m
        Ocelot.log.warn(line)
        System.err.println("[ocljit] " + line)
      }
    } catch {
      case e: Exception =>
        if (!forinDrainFailed) {
          forinDrainFailed = true
          val msg = "OC-LuaJIT " + whichMachine() + ": could not read eris.diagnostics() after a save: " + e +
            " (logged once; the save itself is unaffected)"
          Ocelot.log.warn(msg)
          System.err.println("[ocljit] " + msg)
        }
    }
  }

  // ------------------------------------------------------------------ //
  // Persistence: ONE blob, not two.
  // ------------------------------------------------------------------ //

  /**
    * WHY save() AND load() ARE OVERRIDDEN WHOLESALE -- the same override as the
    * mod's (LuaJITArchitecture.java, same section), against ocelot-brain's port
    * of the class (NativeLuaArchitecture.scala load :347-395, save :397-442;
    * OC's own is :349-437 and differs only in SaveHandler vs nbt.setByteArray
    * and in the log text).
    *
    * NativeLuaArchitecture.save persists a running computer as TWO roots in
    * TWO eris.persist calls: persist(1), the kernel coroutine, into
    * "<address>_kernel", and, while the machine's state stack holds
    * SynchronizedCall or SynchronizedReturn, persist(2) -- the closure the
    * kernel yielded for the driver call, or the result table -- into
    * "<address>_stack". Each call is its own reference space. The closure
    * (machine.lua:1116-1124) holds four OPEN upvalues into the kernel
    * coroutine's stack: args, target, unwrapUserdata, wrapUserdata. Under our
    * serializer an open upvalue whose owning thread is not already in the
    * reference table makes p_function chase the owner (eris_lj.c:543,
    * elj_find_owner_any) and write the WHOLE kernel thread into the stack blob.
    *
    * THAT IS A SECOND KERNEL UNIVERSE. Measured on binary 1a9e8e17
    * (serializer/tests/stack-universe.lua, U1): the stack blob is 11640 bytes
    * against a kernel of 11377; two persisted proxies cost FOUR userdata.load
    * calls; the restored closure's upvalue-id / args-slot / registry all point
    * at the second kernel; and a sync call whose result is a host Value comes
    * back NOT-UNWRAPPED -- a plain table the live kernel's registry has never
    * seen. Nothing raises. That is the silent mode.
    *
    * THE FIX NEEDS NO SERIALIZER CHANGE (U2/U2r/U3 pass on the shipping
    * binary): persist ONE table {[1]=kernel thread, [2]=closure-or-table} in
    * ONE call. The closure's upvalues then find the thread already in the
    * reference table and go out as TAG_UPVALOPEN into the same blob: 11650
    * bytes = kernel + 273, one load per proxy, upvalue-id / args-slot /
    * registry identical to a never-saved machine. On load, unpersist once and
    * push t[1] to index 1 and t[2] (when present) to index 2 -- the exact stack
    * shape runThreaded and runSynchronized assert (:172-174, :200-201).
    *
    * WHOLESALE, NOT WRAPPED: super.save/super.load do their persists
    * unconditionally with no hook between, so both are reproduced here line by
    * line -- every side effect, in order, including the failure protocol
    * (nbt.removeTag("state")) that Machine relies on. Each line below carries
    * the ocelot-brain source line it reproduces.
    *
    * THE ONE REFLECTIVE READ. The PersistenceAPI instance lives in the private
    * 'apis' array, as its LAST element ("Persistence has to go last", :36-44).
    * It must be THAT instance and not a fresh one: it owns the persistKey the
    * kernel's shell-fill recipes were keyed with at load (machine.lua:1085,
    * :1158), and its load(nbt) restores that key from NBT exactly as stock
    * does. A fresh PersistenceAPI mints a new random key, and every recipe
    * keyed with the old one is silently missed. Here three more members need
    * the same treatment, because ocelot-brain makes them private[machine]:
    * kernelMemory and ramScale on the architecture, and Machine.state plus the
    * MachineAPI.State values themselves (the object is private[machine] too).
    *
    * NO MIGRATION PATH, deliberately. A blob written in the old two-call shape
    * has a bare THREAD as its "_kernel" root, not a table, and load() below
    * refuses that shape by name ("Invalid kernel.") -- the fingerprint would
    * NOT catch a two-call blob from this same native; the shape check does.
    * The bundle reuses the "_kernel" tag and writes no "_stack".
    *
    * THE SWITCH: OCLuaJITArchitecture.BundleRoots, below. OFF falls through to
    * super.save/super.load, i.e. the two-call shape -- the harness's NEGATIVE
    * CONTROL, and nothing else. Default ON.
    */
  private var resolvedApis: Array[NativeLuaAPI] = _
  private var resolvedPersistence: PersistenceAPI = _

  private def resolveApis(): Unit = {
    if (resolvedPersistence != null) return
    val found = OCLuaJITArchitecture.apisOf(this)
    if (found == null || found.isEmpty || !found.last.isInstanceOf[PersistenceAPI]) {
      throw new IllegalStateException("NativeLuaArchitecture.apis does not end in a PersistenceAPI (" +
        (if (found == null) "null"
         else s"${found.length} entries, last ${if (found.isEmpty) "none" else found.last.getClass.getName}") +
        "): 'Persistence has to go last' no longer holds and this adapter cannot persist against this ocelot-brain build")
    }
    resolvedApis = found
    resolvedPersistence = found.last.asInstanceOf[PersistenceAPI]
  }
  // At construction, not on the first save: a renamed field must be a machine
  // that refuses to start, not a world that cannot be saved.
  resolveApis()

  /** `"\tat " + e.getLuaStackTrace.mkString("\n\tat ")`, or "" when empty (:390, :433). */
  private def luaTrace(e: LuaRuntimeException): String =
    if (e.getLuaStackTrace.isEmpty) "" else "\tat " + e.getLuaStackTrace.mkString("\n\tat ")

  /**
    * Build {[1]=the thread at index 1, [2]=the value at index 2 when withStack}
    * above the live stack, persist it through the ONE PersistenceAPI, and take
    * it down again -- also when persist throws, so a failed save leaves the
    * running machine's stack exactly as it found it.
    */
  private def persistBundle(lua: LuaState, withStack: Boolean): Array[Byte] = {
    val top = lua.getTop
    try {
      lua.newTable()          // ... t
      lua.pushValue(1)        // ... t thread
      lua.rawSet(-2, 1)       // ... t            t[1] = kernel thread
      if (withStack) {
        lua.pushValue(2)      // ... t v
        lua.rawSet(-2, 2)     // ... t            t[2] = closure | result table
      }
      resolvedPersistence.persist(top + 1)
    } finally lua.setTop(top)
  }

  override def save(nbt: NBTTagCompound): Unit = {
    if (!OCLuaJITArchitecture.BundleRoots) {
      super.save(nbt) // the two-call shape, NativeLuaArchitecture.scala:397-442
      return
    }
    resolveApis()
    val lua = OCLuaJITArchitecture.luaOf(this)

    // Unlimit memory while persisting.                                          (:399-401)
    if (Settings.get.limitMemory) {
      lua.setTotalMemory(Integer.MAX_VALUE)
    }

    lastSaveError = ""
    try {
      // Save the kernel state (which is always at stack index one).             (:406)
      assert(lua.isThread(1))
      // While in a driver call we have one object on the global stack: either
      // the function to call the driver with, or the result of the call.       (:411-414)
      // The bundle takes index 1 ALWAYS and index 2 ONLY in the two sync
      // states: save also runs in Restarting/Stopping, where index 2 may be a
      // boolean or an error string, and the original does not persist it.
      val inCall = OCLuaJITArchitecture.inState(machine, OCLuaJITArchitecture.SynchronizedCall)
      val withStack = inCall || OCLuaJITArchitecture.inState(machine, OCLuaJITArchitecture.SynchronizedReturn)
      if (withStack) {
        assert(if (inCall) lua.isFunction(2) else lua.isTable(2))
      }
      // ONE persist of {[1]=kernel, [2]=closure|table} under the "_kernel"
      // tag -- was persist(1) to "_kernel" and persist(2) to "_stack".         (:409, :417)
      nbt.setByteArray(machine.node.address + "_kernel", persistBundle(lua, withStack))
      // The persist RETURNED: drain what it queued about loops it could not
      // replay (a no-op under the default mode; never a failure).
      drainForinDiagnostics(lua)

      nbt.setInteger("kernelMemory",                                             // (:420)
        math.ceil(OCLuaJITArchitecture.kernelMemoryOf(this) / OCLuaJITArchitecture.ramScaleOf(this)).toInt)

      for (api <- resolvedApis) {                                                // (:422-424)
        api.save(nbt)
      }

      try lua.gc(LuaState.GcAction.COLLECT, 0) catch {                           // (:426-430)
        case _: Throwable =>
          Ocelot.log.warn("Error cleaning up loaded computer. This either means the server is badly overloaded or a user created an evil __gc method, accidentally or not.")
          machine.crash("error in garbage collector, most likely __gc method timed out")
      }
    } catch {
      case e: LuaRuntimeException =>                                             // (:432-434)
        lastSaveError = e.toString
        Ocelot.log.warn(s"Could not persist computer.\n${e.toString}" + luaTrace(e))
        nbt.removeTag("state")
      case e: LuaGcMetamethodException =>                                        // (:435-437)
        lastSaveError = e.toString
        Ocelot.log.warn(s"Could not persist computer.\n${e.toString}")
        nbt.removeTag("state")
    }

    // Limit memory again.                                                       (:441)
    recomputeMemory(machine.host.inventory.entities)
  }

  override def load(nbt: NBTTagCompound): Unit = {
    if (!OCLuaJITArchitecture.BundleRoots) {
      super.load(nbt) // the two-call shape, NativeLuaArchitecture.scala:347-395
      return
    }
    if (!machine.isRunning) return                                               // (:348)
    resolveApis()
    val lua = OCLuaJITArchitecture.luaOf(this)

    // Unlimit memory use while unpersisting.                                    (:351-353)
    if (Settings.get.limitMemory) {
      lua.setTotalMemory(Integer.MAX_VALUE)
    }

    try {
      // Try unpersisting Lua, because that's what all of the rest depends
      // on. First, clear the stack, meaning the current kernel.                 (:358)
      lua.setTop(0)

      // ONE unpersist of the bundle -- was "_kernel" and then, in the sync
      // states, "_stack".                                                        (:361, :370)
      resolvedPersistence.unpersist(nbt.getByteArray(machine.node.address + "_kernel"))
      // The bundle is a table. Anything else -- nothing at all because
      // allowPersistence is off, or a bare thread because the blob was written
      // in the old shape (which the fingerprint gate refuses before this) -- is
      // the corrupt-save case the original answers with this same message.
      if (lua.getTop != 1 || !lua.isTable(1)) {
        throw new LuaRuntimeException("Invalid kernel.")
      }
      val inCall = OCLuaJITArchitecture.inState(machine, OCLuaJITArchitecture.SynchronizedCall)
      val withStack = inCall || OCLuaJITArchitecture.inState(machine, OCLuaJITArchitecture.SynchronizedReturn)
      lua.rawGet(1, 1)                        // bundle thread
      if (withStack) lua.rawGet(1, 2)         // bundle thread v
      lua.remove(1)                           // thread [v]  -- what runThreaded/runSynchronized assert
      if (!lua.isThread(1)) {                                                    // (:363-367)
        // This shouldn't really happen, but there's a chance it does if
        // the save was corrupt (maybe someone modified the Lua files).
        throw new LuaRuntimeException("Invalid kernel.")
      }
      if (withStack && !(if (inCall) lua.isFunction(2) else lua.isTable(2))) {   // (:368-376)
        // Same as with the above, should not really happen normally, but
        // could for the same reasons.
        throw new LuaRuntimeException("Invalid stack.")
      }

      OCLuaJITArchitecture.setKernelMemory(this,                                 // (:378)
        (nbt.getInteger("kernelMemory") * OCLuaJITArchitecture.ramScaleOf(this)).toInt)

      for (api <- resolvedApis) {                                                // (:380-382)
        api.load(nbt)
      }

      try lua.gc(LuaState.GcAction.COLLECT, 0) catch {                           // (:384-388)
        case _: Throwable =>
          Ocelot.log.warn("Error cleaning up loaded computer. This either means the server is badly overloaded or a user created an evil __gc method, accidentally or not.")
          machine.crash("error in garbage collector, most likely __gc method timed out")
      }
    } catch {
      case e: LuaRuntimeException => throw new Exception(e.toString + luaTrace(e), e)   // (:390)
    }

    // Limit memory again.                                                       (:394)
    recomputeMemory(machine.host.inventory.entities)
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
    * THE SWITCH for the persistence override (see the class): default ON.
    * -Docljit.persist.bundle=false, or OCLJ_PERSIST_BUNDLE=off in the
    * environment (which smoke-test.sh's JVM inherits, so no script change is
    * needed), falls through to super.save/super.load -- OpenComputers' two-call
    * shape -- for the harness's NEGATIVE CONTROL. The mod's Java class has NO
    * such switch, deliberately: one here is what lets the gate be shown to
    * fail; one there would be readable from a server's environment.
    */
  val BundleRoots: Boolean = {
    var v = System.getProperty("ocljit.persist.bundle")
    if (v == null) v = System.getenv("OCLJ_PERSIST_BUNDLE")
    val on = v == null || !Set("0", "false", "off", "no").contains(v.trim.toLowerCase(java.util.Locale.ROOT))
    // STDERR AS WELL AS THE LOG, for the reason ensureInitialized gives.
    val msg = "OC-LuaJIT persistence: bundled roots " +
      (if (on) "ON (one blob: {kernel, closure|table})"
       else "OFF -- OpenComputers' two-call shape; the NEGATIVE CONTROL, a save made mid-sync-call restores a second kernel")
    if (on) Ocelot.log.info(msg) else Ocelot.log.warn(msg)
    System.err.println("[ocljit] " + msg)
    on
  }

  /**
    * THE FOR-IN DIAGNOSTIC's mode, from -Docluajit.forin -- the MOD's property
    * name, deliberately, so the harness's JAVA_TOOL_OPTIONS reads exactly as a
    * server's would: ignore (default; absent) | warn | refuse.  Anything else
    * is warned about once and treated as ignore, as the mod does.
    */
  val ForinProperty = "ocluajit.forin"

  val ForinMode: String = {
    val raw = System.getProperty(ForinProperty)
    val v = if (raw == null) "ignore" else raw.trim.toLowerCase(java.util.Locale.ROOT)
    val mode = if (v == "ignore" || v == "warn" || v == "refuse") v else "ignore"
    val msg =
      if (raw == null) "OC-LuaJIT for-in diagnostic: -D" + ForinProperty + " absent -> ignore (the default: the persist does not look)"
      else if (mode == v) "OC-LuaJIT for-in diagnostic: -D" + ForinProperty + "=" + mode
      else "OC-LuaJIT for-in diagnostic: -D" + ForinProperty + "=" + raw + " is not one of ignore|warn|refuse; treating it as ignore"
    if (mode == v) Ocelot.log.info(msg) else Ocelot.log.warn(msg)
    System.err.println("[ocljit] " + msg)
    mode
  }

  /**
    * eris.settings("forin", mode) on a state, the way PersistenceAPI.configure
    * sets spkey: getGlobal, getField, two pushes, call(2, 0) -- each a
    * lua_pcall-protected jnlua entry, so a refusal ("invalid option 'forin'"
    * from a serializer that predates the setting) is a LuaRuntimeException,
    * never an unprotected longjmp through a JNI frame.  The stack is left as
    * found on every path.  Throws; the caller decides what a refusal means.
    */
  def forinApply(lua: LuaState, mode: String): Unit = {
    val top = lua.getTop
    try {
      lua.getGlobal("eris")                                       // ... eris
      if (!lua.isTable(-1)) throw new IllegalStateException("no 'eris' global: " + lua.`type`(-1))
      lua.getField(-1, "settings")                                // ... eris settings
      if (!lua.isFunction(-1)) throw new IllegalStateException("eris.settings is " + lua.`type`(-1))
      lua.pushString("forin")
      lua.pushString(mode)
      lua.call(2, 0)                                              // ... eris
    } finally lua.setTop(top)
  }

  /**
    * eris.diagnostics(): the pending messages as strings, in order.  The call
    * CLEARS the list (the table handed back is the list and the registry
    * forgets it), so two reads in a row give the messages and then nothing.
    * Throws when the library lacks the function (a serializer that predates
    * it) -- the caller must not read that as "no diagnostics".
    */
  def forinDrain(lua: LuaState): List[String] = {
    val top = lua.getTop
    try {
      lua.getGlobal("eris")                                       // ... eris
      if (!lua.isTable(-1)) throw new IllegalStateException("no 'eris' global: " + lua.`type`(-1))
      lua.getField(-1, "diagnostics")                             // ... eris diagnostics
      if (!lua.isFunction(-1))
        throw new IllegalStateException("eris.diagnostics is " + lua.`type`(-1) + " (a serializer older than the setting?)")
      lua.call(0, 1)                                              // ... eris list
      if (!lua.isTable(-1)) throw new IllegalStateException("eris.diagnostics() returned " + lua.`type`(-1))
      val n = lua.rawLen(-1)
      val out = mutable.ListBuffer.empty[String]
      var i = 1
      while (i <= n) {
        lua.rawGet(-1, i)                                         // ... eris list msg
        out += (if (lua.isString(-1)) lua.toString(-1) else "<" + lua.`type`(-1) + ">")
        lua.pop(1)                                                // ... eris list
        i += 1
      }
      out.toList
    } finally lua.setTop(top)
  }

  /**
    * ocelot-brain declares `lua`, `kernelMemory`, `ramScale` and `apis` as
    * private[machine], so an adapter outside that package cannot see them. The
    * mod side needs this only for `apis` -- OC exposes the other three publicly
    * -- but the harness is where this mechanism can actually be RUN, so it
    * reaches the fields the way CensusOs already does. A missing field is a
    * changed ocelot-brain and is reported as such, by name.
    */
  private def field(name: String): java.lang.reflect.Field = {
    val f = try classOf[NativeLuaArchitecture].getDeclaredField(name) catch {
      case e: NoSuchFieldException =>
        throw new IllegalStateException("NativeLuaArchitecture has no private field '" + name +
          "': ocelot-brain has changed shape and this adapter cannot drive it", e)
    }
    f.setAccessible(true)
    f
  }

  def luaOf(arch: NativeLuaArchitecture): LuaState = field("lua").get(arch).asInstanceOf[LuaState]

  /** The private `apis` array. Its LAST element is the PersistenceAPI that owns
    * this machine's persistKey ("Persistence has to go last"); the caller checks. */
  def apisOf(arch: NativeLuaArchitecture): Array[NativeLuaAPI] =
    field("apis").get(arch).asInstanceOf[Array[NativeLuaAPI]]

  def kernelMemoryOf(arch: NativeLuaArchitecture): Int = field("kernelMemory").getInt(arch)
  def setKernelMemory(arch: NativeLuaArchitecture, value: Int): Unit = field("kernelMemory").setInt(arch, value)
  def ramScaleOf(arch: NativeLuaArchitecture): Double = field("ramScale").getDouble(arch)

  /** Machine.state is private[machine]; its accessor is public at the JVM
    * level. The harness can inspect the state stack through this too. */
  def stateOf(machine: Machine): mutable.Stack[Enumeration#Value] =
    classOf[Machine].getMethod("state").invoke(machine).asInstanceOf[mutable.Stack[Enumeration#Value]]

  /** MachineAPI.State is private[machine] as well, so its values come off the
    * enumeration's MODULE$ by name. */
  private lazy val stateModule: AnyRef =
    Class.forName("totoro.ocelot.brain.entity.machine.MachineAPI$State$").getField("MODULE$").get(null)

  def stateValue(name: String): Enumeration#Value =
    stateModule.getClass.getMethod(name).invoke(stateModule).asInstanceOf[Enumeration#Value]

  lazy val SynchronizedCall: Enumeration#Value = stateValue("SynchronizedCall")
  lazy val SynchronizedReturn: Enumeration#Value = stateValue("SynchronizedReturn")

  /** The original's `state.contains(...)` (:345), on the same Stack. */
  def inState(machine: Machine, s: Enumeration#Value): Boolean = stateOf(machine).contains(s)
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
