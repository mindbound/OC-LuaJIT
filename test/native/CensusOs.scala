package ocljit.census

import li.cil.repack.com.naef.jnlua.LuaState
import ocljit.arch.{OCLuaJITArchitecture, OCLuaJITStateFactory}
import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.machine.luac.{LuaStateFactory, NativeLua52Architecture, NativeLua53Architecture, NativeLuaArchitecture}
import totoro.ocelot.brain.entity.{CPU, Case, DataCard, EEPROM, GraphicsCard, HDDManaged, Memory, Screen}
import totoro.ocelot.brain.loot.Loot
import totoro.ocelot.brain.util.{ExtendedTier, Tier}
import totoro.ocelot.brain.workspace.Workspace

import java.nio.file.{Files, Path, Paths}

/**
 * Boot a REAL third-party OpenComputers OS on our native and report what it
 * costs, in the same terms the rest of this project measures in.
 *
 * WHY THIS EXISTS, AND WHY IT IS IN THE REPOSITORY.  There was a runner for
 * this before -- `totoro.ocelot.demo.CustomOs`, written into ocelot-brain's
 * demo tree -- and it produced a finding nobody can now check: axis-os panicked
 * with "not enough memory" four times during PatchGuard's Tier3 file hashing.
 * The runner is gone, the finding was never written up, and the log survives
 * only by luck.  That is the same durability failure `bench/runs/` and
 * `bench/oc/matrix.sh` were built to fix, one layer up: we lost the TOOL, not
 * just the output.  So this lives here, and its results archive the same way.
 *
 * WHAT IT MEASURES, and why each number is here.
 *
 *   GC PRESSURE  -- `_OCLJ_GCSTATS`, the emergency collector's instrument
 *       (memory-accounting.md 8f).  The axis-os panic above is a REAL-WORLD OOM
 *       in real OS code, as against `sieve`, which is a benchmark written to
 *       provoke exactly this.  If `refusals` is 0 across a boot that used to
 *       panic, that is the collector's first result on code nobody wrote for it.
 *
 *   PEAK USED    -- sampled every tick.  Section 11's calibration item wants
 *       peak `used` over a full boot of OpenOS *and* the census systems, in
 *       order to set our architecture's `ramScaleFor64Bit` default from
 *       measurement rather than from arithmetic.  Nothing else produces it.
 *
 *   The screen, verbatim -- because a panic prints there and nowhere else.
 *
 * USAGE (see census-os.sh, which supplies the classpath and the native):
 *   CensusOs <kernel-root> <name> <eeprom.lua> [ticks]
 *
 * The OS tree is mounted by `customRealPath`, so the kernel root is used in
 * place, read-only as far as this runner is concerned, and is never copied.
 */
object CensusOs {

  def p(s: String): Unit = { println("CENSUS| " + s); System.out.flush() }

  /** Is there anything ON the screen, including things made of no characters?
    *
    * A CHARACTER-ONLY READ CANNOT SEE A GUI.  MineOS draws a desktop that is
    * overwhelmingly space characters on coloured backgrounds, so screenText --
    * which strips trailing whitespace per row -- renders a fully painted
    * desktop as a blank page, and "the OS produced no output" and "the OS
    * produced a GUI" become the same reading.  GenericTextBuffer carries a
    * packed colour per cell alongside the character, so count both: a booted
    * text OS shows glyphs, a booted GUI shows colours, and a machine that did
    * nothing shows neither. */
  def screenSignature(screen: Screen): String = {
    val d = screen.data
    var glyphs = 0
    val colours = new java.util.HashSet[Short]()
    for (row <- 0 until d.height; col <- 0 until d.width) {
      val ch = d.get(col, row).toChar
      if (ch != ' ' && ch.toInt != 0) glyphs += 1
      if (row < d.color.length && col < d.color(row).length) colours.add(d.color(row)(col))
    }
    d.width + "x" + d.height + ", " + glyphs + " non-blank glyphs, " +
      colours.size + " distinct cell colours" +
      (if (glyphs == 0 && colours.size <= 1) "   <- NOTHING WAS DRAWN" else "")
  }

  /** The screen, the way OcljSmoke.scala reads it: Screen exposes `data`, a
    * character grid, not a text buffer. */
  def screenText(screen: Screen): String = {
    val d = screen.data
    val sb = new StringBuilder
    for (row <- 0 until d.height) {
      val line = new StringBuilder
      for (col <- 0 until d.width) line.append(d.get(col, row).toChar)
      sb.append(line.toString.replaceAll("\\s+$", "")).append("\n")
    }
    sb.toString
  }

  def luaOf(arch: AnyRef): LuaState = {
    val f = classOf[NativeLuaArchitecture].getDeclaredField("lua")
    f.setAccessible(true)
    f.get(arch).asInstanceOf[LuaState]
  }

  def kernelMemoryOf(arch: AnyRef): Int = {
    val f = classOf[NativeLuaArchitecture].getDeclaredField("kernelMemory")
    f.setAccessible(true)
    f.getInt(arch)
  }

  /** Evaluate in the live state under the executor's own monitor.
    *
    * NOT OPTIONAL, AND THE REASON IS RECORDED.  Reading the raw LuaState while
    * ocelot-brain's executor thread is using it wedged roughly one run in four
    * across this project until it was found; `quiesced`-style checks do not
    * prevent it, because `Machine.switchTo(Yielded)` arms a thread-pool resume
    * BEFORE the state leaves Running.  `Machine.run()` takes this monitor, so
    * taking it here is what makes the read safe.  Individual reads only --
    * holding it across a tick loop deadlocks the machine being observed. */
  def evalLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                 lua: LuaState, code: String): String =
    machine.synchronized {
      try {
        lua.load(new java.io.ByteArrayInputStream(code.getBytes("UTF-8")), "=census", "t")
        lua.call(0, 1)
        val s = if (lua.isNil(-1)) "<nil>" else lua.toString(-1)
        lua.pop(1)
        s
      } catch { case t: Throwable => "<err:" + t.getClass.getSimpleName + ">" }
    }

  def gcStats(machine: totoro.ocelot.brain.entity.machine.Machine, lua: LuaState): String =
    evalLocked(machine, lua,
      "if _OCLJ_GCSTATS == nil then return 'absent (stock native)' end " +
      "local a,c,b,r,on,tot,thr,mul,st,tf = _OCLJ_GCSTATS() " +
      "return string.format('arms=%d collects=%d bailouts=%d refusals=%d armed=%s trace_flushes=%d', " +
      "a, c, b, r, tostring(on), tf or -1)")

  def main(args: Array[String]): Unit = {
    // args(0) is the generated ocelot-brain config, supplied by smoke-test.sh
    // exactly as it is to the smoke harness -- that config is what carries
    // ramScaleFor64Bit and forceNativeLibPathFirst, so dropping it would
    // silently run this census on ocelot-brain's OWN PUC native at OC's stock
    // RAM scale, i.e. measure the wrong VM at the wrong cap.
    if (args.length < 4) {
      System.err.println("usage: CensusOs <conf> <kernel-root> <name> <eeprom.lua> [ticks]")
      System.exit(2)
    }
    val conf = args(0)
    val root = Paths.get(args(1)).toAbsolutePath
    val name = args(2)
    val eepromArg = args(3)
    val ticks = if (args.length > 4) args(4).toInt else 2000

    // TWO WAYS A CENSUS SYSTEM BOOTS, and the distinction is not cosmetic.
    //   own bootloader   AxisOS ships eeprom/boot.lua and expects to be the
    //                    BIOS: it scans components itself, binds the gpu, and
    //                    loads /kernel.lua with its own environment.
    //   the stock BIOS   QuickOS is an OpenOS derivative with /init.lua at the
    //                    root and no bootloader of its own, so it needs OC's
    //                    Lua BIOS to find and run it.
    // Booting the second kind through the first (or the reverse) does not fail
    // cleanly -- it produces a machine that runs, uses memory and renders
    // nothing, which is a shape this project has already wasted time on.
    val useStockBios = eepromArg == "bios" || eepromArg == "-"
    require(Files.isDirectory(root), "kernel root is not a directory: " + root)
    if (useStockBios) {
      require(Files.isRegularFile(root.resolve("init.lua")),
        "stock-BIOS boot was requested but there is no init.lua at " + root +
          " -- the Lua BIOS looks for exactly that")
    } else {
      require(Files.isRegularFile(Paths.get(eepromArg)),
        "no eeprom at: " + eepromArg + "  (pass 'bios' to boot via OC's Lua BIOS instead)")
    }

    p("=============== " + name + " ===============")
    p("    kernel root = " + root)
    p("    boot        = " + (if (eepromArg == "bios" || eepromArg == "-") "OC Lua BIOS -> /init.lua" else eepromArg))
    p("    entries     = " + Files.list(root).sorted().toArray.map(_.asInstanceOf[Path].getFileName).mkString(", "))
    p("    native      = " + System.getProperty("ocljit.native", "luajit"))
    p("    ticks       = " + ticks)

    if (conf.nonEmpty) {
      val cp = Paths.get(conf)
      if (!Files.isRegularFile(cp)) { System.err.println("config not found: " + conf); System.exit(2) }
      Ocelot.configPath = Some(cp)
    }
    Ocelot.initialize()
    val ws = new Workspace(Files.createTempDirectory("ocljit-census"))

    val computer = ws.add(new Case(Tier.Three))
    // PIN THE ARCHITECTURE.  Without this the CPU takes the FIRST REGISTERED,
    // which is 5.3 -- and our native is the 5.2 one (libjnlua52), so the
    // machine quietly loads ocelot-brain's bundled 5.3 native instead of ours.
    // The first run of this census did exactly that: NativeLua53Architecture,
    // no _OCLJ_NATIVE marker, no watchdog, and the patched kernel panicking on
    // its first resume because _OCLJ_WATCHDOG was absent -- which is the kernel
    // working correctly, on the wrong VM.
    val cpu = new CPU(Tier.Three)
    // 5.2 is the product; 5.3 is available ONLY as a baseline arm.  Our native
    // is the 5.2 one, so a 5.3 run measures ocelot-brain's bundled PUC and is
    // useful for exactly one thing: telling "this OS cannot run on our VM"
    // apart from "this OS cannot run on a 5.2-class VM at all".  The fingerprint
    // above reports which one actually ran, so a 5.3 arm cannot be mistaken for
    // a result about OC-LuaJIT.
    val archProp = System.getProperty("ocljit.censusarch", "52")
    if (archProp == "53") {
      cpu.setArchitecture(classOf[NativeLua53Architecture])
      p("!! BASELINE ARM: pinned to NativeLua53Architecture, which our native does")
      p("!! NOT back.  This run measures ocelot-brain's PUC 5.3, not OC-LuaJIT.")
    } else if (archProp == "luajit") {
      // THE ADDITIVE ARM, and the only one that runs the shipped shape.  Here
      // the machine runs on OUR LuaState class, backed by libjnluajit52, while
      // OpenComputers' real PUC 5.2 native is loaded in the same JVM behind
      // "Lua 5.2".  Every other arm has at most one VM in the process.
      OCLuaJITStateFactory.register()
      cpu.setArchitecture(classOf[OCLuaJITArchitecture])
      p("ADDITIVE ARM: pinned to ocljit.arch.OCLuaJITArchitecture (LuaStateLuaJIT,")
      p("libjnluajit52).  OpenComputers' own PUC 5.2 native is loaded alongside it.")
    } else cpu.setArchitecture(classOf[NativeLua52Architecture])
    computer.inventory(0) = cpu
    computer.inventory(1) = new GraphicsCard(Tier.Three)
    // RAM.  One ExtendedTier.ThreeHalf stick is 1024 KB advertised.  MineOS's
    // own installer declares a floor of 2048 KB (mineos-census.md), and the
    // deciding experiment that document names is to run AT that floor rather
    // than above it -- so the stick count is a knob, not a constant.
    val sticks = Integer.getInteger("ocljit.censusram", 1).intValue()
    for (i <- 0 until sticks) computer.inventory(2 + i) = new Memory(ExtendedTier.ThreeHalf)
    p("    ram         = " + sticks + " x ExtendedTier.ThreeHalf = " + (sticks * 1024) + " KB advertised")

    // The OS tree in place.  Mounted, not copied: a census result should be
    // about the system as it ships, and a copy is one more thing to get wrong.
    val hdd = new HDDManaged(Tier.One)
    hdd.customRealPath = Some(root)
    computer.inventory(2 + sticks) = hdd

    // Its OWN bootloader, not the Lua BIOS.  A census OS that boots through
    // OpenOS's BIOS is not the system under test.
    computer.inventory(3 + sticks) =
      if (useStockBios) Loot.LuaBiosEEPROM.create()
      else {
        val e = new EEPROM()
        e.codePath = Some(Paths.get(eepromArg).toAbsolutePath)
        e.label = name + " boot"
        // THE BOOT FILESYSTEM ADDRESS LIVES IN THE EEPROM'S DATA, and an OS
        // that expects it there gets nothing useful without it.  MineOS's
        // OS.lua opens with
        //     component.proxy(component.invoke(component.list("eeprom")(),
        //                                      "getData"))
        // so an empty data field means component.proxy(nil) at line 4 of the
        // operating system.  AxisOS does not need this -- its bootloader scans
        // for a filesystem containing /kernel.lua -- which is why the first two
        // census systems never exposed the gap.
        e.volatileData = hdd.node.address.getBytes("UTF-8")
        e
      }
    p("    boot fs     = " + hdd.node.address)

    // A DATA CARD.  Without one, AxisOS's bootloader takes its `ndc;skip`
    // branch and never runs the sha256 path (eeprom/boot.lua scans for a
    // component of type "data"), so the census would silently skip the
    // machine-binding and kernel-hash verification that a real install does --
    // and hashing is precisely the allocation-heavy work the 2026-09-02 panic
    // happened in.  Tier 3 because that is the one with the full crypto set.
    computer.inventory(4 + sticks) = new DataCard.Tier3()

    val screen = ws.add(new Screen(Tier.Three))
    computer.connect(screen)

    computer.machine.start()

    // FINGERPRINT BEFORE MEASURING ANYTHING.
    //
    // The first run of this census reported "GC PRESSURE = absent (stock
    // native)" on a run launched with OCLJ_NATIVE=luajit, and it took three
    // rounds of guessing to work out what that meant.  It means what the smoke
    // harness's own guard() would have said in one line: ocelot-brain
    // substitutes its bundled PUC native (or LuaJ) whenever ours fails to load,
    // silently, and every number after that point describes the wrong VM.
    // A census that cannot say which VM it measured is not a census.
    var settle = 0
    while (settle < 40 && computer.machine.architecture == null) {
      ws.update(); Thread.sleep(5); settle += 1
    }
    p("LuaStateFactory.isAvailable = " + LuaStateFactory.isAvailable +
      "   includeLuaJ = " + LuaStateFactory.includeLuaJ)
    val arch0 = computer.machine.architecture
    p("architecture   = " + (if (arch0 == null) "<null>" else arch0.getClass.getName))
    // ASSERT THE PIN TOOK, whichever arm this is.  The old form of this check
    // only noticed a non-5.2 architecture in the 5.2 arm, so it could not have
    // caught a luajit arm that silently fell back -- and falling back is the
    // exact failure the first run of this census suffered.
    val expectedArch: Class[_] = archProp match {
      case "53"     => classOf[NativeLua53Architecture]
      case "luajit" => classOf[OCLuaJITArchitecture]
      case _        => classOf[NativeLua52Architecture]
    }
    if (arch0 != null && !expectedArch.isInstance(arch0)) {
      p("!! architecture is " + arch0.getClass.getName + ", NOT the pinned " +
        expectedArch.getName + " -- this run is measuring a DIFFERENT VM.")
      p("!! Nothing below describes OC-LuaJIT.")
    }

    // COEXISTENCE, RUN RATHER THAN ARGUED.  That our additive library and
    // OpenComputers' own 5.2 native cannot collide has rested on a symbol count
    // in build-native.sh.  Here both are live in one JVM and both are asked,
    // directly, which VM they are.
    if (archProp == "luajit") {
      LuaStateFactory.Lua52.createState() match {
        case Some(puc) =>
          try {
            puc.load(new java.io.ByteArrayInputStream(
              "return tostring(rawget(_G, '_OCLJ_NATIVE') or '<stock PUC>')".getBytes("UTF-8")),
              "=coexist", "t")
            puc.call(0, 1)
            val m = if (puc.isNil(-1)) "<nil>" else puc.toString(-1)
            puc.pop(1)
            p("coexistence    = OpenComputers' own LuaState reports " + m +
              "   (expected <stock PUC>)")
            if (m != "<stock PUC>") {
              p("!! OpenComputers' 5.2 state carries OUR marker: the two libraries are")
              p("!! NOT disjoint, and this is precisely the collision the additive")
              p("!! build exists to prevent.")
            }
          } finally puc.close()
        case None =>
          p("coexistence    = OpenComputers' 5.2 native did not load, so this run")
          p("                 proves nothing about coexistence -- only one VM was present.")
      }
    }
    if (arch0 != null && arch0.isInstanceOf[NativeLuaArchitecture]) {
      val l0 = try luaOf(arch0) catch { case _: Throwable => null }
      if (l0 != null) {
        p("native marker  = " + evalLocked(computer.machine, l0,
          "return tostring(rawget(_G, '_OCLJ_NATIVE') or '<stock PUC>')"))
        p("watchdog       = " + evalLocked(computer.machine, l0,
          "return tostring(rawget(_G, '_OCLJ_WATCHDOG') ~= nil)") +
          "   kernel = " + evalLocked(computer.machine, l0,
          "return tostring(rawget(_G, '_OCLJ_KERNEL') or '<stock>')"))
      }
    }

    // PEAK USED, sampled per tick.  `freeMemory` is what the sandbox is told,
    // i.e. real free divided by ramScaleFor64Bit; `used` below is in the same
    // scaled units, so it is directly comparable with what a player sees and
    // with references.txt's guard.  Section 11 wants the peak of it.
    var t = 0
    var peakUsed = 0
    var minFree = Int.MaxValue
    var kernelMem = -1
    var totalMem = -1
    var lastErr: String = null

    while (t < ticks && computer.machine.isRunning) {
      ws.update()
      Thread.sleep(5)
      t += 1
      if (t % 10 == 0) {
        val arch = computer.machine.architecture
        if (arch != null) {
          // The RAW state's counters, as OcljSmoke's b2 milestone reads them.
          // These are REAL bytes -- the cap is kernelMemory + memoryBytes *
          // ramScaleFor64Bit -- NOT the sandbox-visible figure, which
          // NativeLuaArchitecture divides by ramScale on the way out.  Section
          // 11's calibration wants the real ones, and the unit trap has
          // already produced one wrong result in this project (the RAM guard).
          try {
            val lua = luaOf(arch)
            if (lua != null) computer.machine.synchronized {
              val total = lua.getTotalMemory
              val free = lua.getFreeMemory
              if (total > 0) {
                val used = total - free
                if (used > peakUsed) peakUsed = used
                if (free < minFree) minFree = free
                totalMem = total
                kernelMem = kernelMemoryOf(arch)
              }
            }
          } catch { case _: Throwable => () }
        }
      }
    }

    lastErr = computer.machine.lastError

    // THE KERNEL MARKER, RE-READ AT THE END.  The early fingerprint reported
    // `kernel = <stock>` on a run launched with OCLJ_KERNEL=watchdog, and that
    // is an artifact of reading too soon rather than a kernel that failed to
    // load: initialize() only LOADS machine.lua and calls lua.newThread(); the
    // chunk does not execute -- and so cannot set _OCLJ_KERNEL -- until the
    // first runThreaded resume.  Reading it again here is the difference
    // between "the patched kernel is not in play" and "it had not run yet".
    val archEnd = computer.machine.architecture
    if (archEnd != null && archEnd.isInstanceOf[NativeLuaArchitecture]) {
      val lEnd = try luaOf(archEnd) catch { case _: Throwable => null }
      if (lEnd != null)
        p("kernel (final) = " + evalLocked(computer.machine, lEnd,
          "return tostring(rawget(_G, '_OCLJ_KERNEL') or '<stock>')"))
    }

    p("")
    p("ticks run      = " + t + " of " + ticks + "   (running=" + computer.machine.isRunning + ")")
    p("totalMemory    = " + totalMem + " B   kernelMemory = " + kernelMem + " B")
    p("PEAK USED      = " + peakUsed + " B REAL   (min free " +
      (if (minFree == Int.MaxValue) -1 else minFree) + " B)   <- section 11 calibration input")
    p("lastError      = " + (if (lastErr == null) "<none>" else lastErr))

    val arch = computer.machine.architecture
    if (arch != null) {
      val lua = try luaOf(arch) catch { case _: Throwable => null }
      if (lua != null) p("GC PRESSURE    = " + gcStats(computer.machine, lua))
      else p("GC PRESSURE    = <no LuaState: stopped or not a native architecture>")
    } else p("GC PRESSURE    = <no architecture>")

    p("")
    p("SCREEN         = " + screenSignature(screen))
    p("---------------- SCREEN [" + name + "] ----------------")
    println(screenText(screen))
    p("--------------------------------------------------")

    // A panic is printed BY THE OS onto the screen; it is not a machine error,
    // so isRunning and lastError can both look healthy while the system is
    // dead.  That is exactly how the axis-os OOM went unrecorded, so scan for
    // it explicitly and make it the exit status.
    val text = screenText(screen)
    val panicked = text.contains("PANIC") || text.contains("not enough memory")
    // Report the signature alongside, so "no panic" is not read as "booted"
    // when the machine may have drawn nothing at all.
    p("VERDICT: " + (if (panicked) "PANIC OR OOM ON SCREEN" else "no panic text on screen") +
      "  (running=" + computer.machine.isRunning + ", lastError=" +
      (if (lastErr == null) "none" else lastErr) + ")")

    Ocelot.shutdown()
    System.exit(if (panicked || lastErr != null) 1 else 0)
  }
}
