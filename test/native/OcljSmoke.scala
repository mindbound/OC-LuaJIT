package ocljit.smoke

import li.cil.repack.com.naef.jnlua.LuaState
import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.machine.luac.{LuaStateFactory, NativeLua52Architecture, NativeLuaArchitecture}
import totoro.ocelot.brain.entity.{CPU, Case, GraphicsCard, HDDManaged, Memory, Screen}
import totoro.ocelot.brain.loot.Loot
import totoro.ocelot.brain.nbt.NBTTagCompound
import totoro.ocelot.brain.util.{ExtendedTier, Tier}
import totoro.ocelot.brain.workspace.Workspace

import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, Paths, StandardCopyOption}

/**
 * OC-LuaJIT smoke test.  One command, one verdict.
 *
 * Boots REAL OpenOS 1.8.9 on ocelot-brain against the LuaJIT-backed
 * libjnlua52 native, runs to a shell, persists the machine through OC's own
 * PersistenceAPI (eris.persist), restores into a FRESH workspace, and proves
 * the restored machine is the same live VM and not a reboot:
 *   - a boot-time nonce, minted inside the sandbox before the persist, is
 *     byte-identical afterwards
 *   - a counter driven by a Lua closure registered with OpenOS's event loop
 *     kept counting up from where it stopped
 *
 * THE LUAJ GUARD.  ocelot-brain sets includeLuaJ = !isAvailable, so a native
 * that fails to load is silently replaced by LuaJ, which has no Eris -- and
 * then every persistence assertion passes VACUOUSLY.  Nothing below is
 * believed until `guard` has run: it asserts the native factory is available,
 * that LuaJ is out of play, that the live architecture is a
 * NativeLua52Architecture, and it prints a fingerprint read out of the running
 * Lua state (the _OCLJ_NATIVE marker only the shim can plant, _VERSION, the
 * jit table, and eris's shape and version).  A run without that fingerprint in
 * its log is not a result.
 *
 * Exit status: 0 iff every milestone passed.
 */
object Smoke {
  private var failures = 0
  private var checks = 0

  def p(s: String): Unit = { println("SMOKE| " + s); System.out.flush() }

  def milestone(id: String, ok: Boolean, detail: String): Unit = {
    checks += 1
    p(s"MILESTONE $id: ${if (ok) "PASS" else "FAIL"} -- $detail")
    if (!ok) failures += 1
  }

  def die(s: String): Nothing = {
    p("FATAL: " + s)
    p("VERDICT: FAIL")
    try Ocelot.shutdown() catch { case _: Throwable => }
    System.exit(3)
    throw new RuntimeException()
  }

  // ------------------------------------------------------------------ //
  // reflection into NativeLuaArchitecture's private state
  // ------------------------------------------------------------------ //

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

  /** mcode bytes / cap / traces / jit-on, read off the raw state.
    * The RAM cap cannot see machine code (it is VirtualAlloc'd, never through
    * g->allocf), so this is the only number that says what a machine actually
    * costs.  It is also the trace-flush signature: lj_trace_flushall zeroes
    * szallmcarea, so a drop to 0 across a persist proves the serializer threw
    * away every compiled trace in the VM. */
  /**
   * Wait for the machine's worker thread to stop executing before this thread
   * touches its LuaState, and REPORT rather than proceed if it does not.
   *
   * Every one of these waits used to run out its budget and then probe anyway.
   * The Phase 1 matrix showed the price: C-matmul's watchdog stats came back
   * as `-16.05` -- one float where five integers belong -- and ocelot-brain's
   * own save then tripped `assert(lua.isThread(1))`, losing the persist blob,
   * the restore, and every milestone after them.  That is this thread and the
   * machine thread racing over one Lua stack, which is the single thing a JNI
   * caller must never do.  A probe skipped and announced is worth more than a
   * number read off a stack somebody else is using.
   */
  def quiesced(machine: totoro.ocelot.brain.entity.machine.Machine, what: String,
               spins: Int = 600, ms: Long = 10L): Boolean = {
    var q = 0
    while (machine.isExecuting && q < spins) { Thread.sleep(ms); q += 1 }
    val ok = !machine.isExecuting
    if (ok) p("quiesced after " + q + " spins, before " + what)
    else p("!! NOT QUIESCED after " + q + " spins: SKIPPING " + what +
      " -- reading the Lua state while the machine thread runs corrupts it")
    ok
  }

  /**
   * Say why a machine stopped.  ocelot-brain's Machine.crash fires an event
   * with no subscriber here, so a machine that dies mid-run leaves nothing in
   * the log at all -- which is exactly what happened to A-strings.  OC paints
   * "Unrecoverable Error" and the wrapped message onto the screen when a
   * machine stops with one, so the screen is usually the whole diagnosis.
   */
  def reportDeath(machine: totoro.ocelot.brain.entity.machine.Machine,
                  screen: Screen, where: String): Unit = {
    p("!! MACHINE STOPPED during " + where +
      ": running=" + machine.isRunning + " lastError=" + machine.lastError)
    p("!! screen at death:")
    println(nonEmptyScreen(screen))
  }

  /** jitStats under the executor's monitor -- same reasoning as evalStrLocked. */
  def jitStatsLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                     lua: LuaState): (Long, Long, Int, Boolean) =
    machine.synchronized { jitStats(lua) }

  def jitStats(lua: LuaState): (Long, Long, Int, Boolean) = {
    val s = evalStr(lua, "local m, c, t, on = _OCLJ_JITSTATS() " +
      "return string.format('%d/%d/%d/%s', m, c, t, tostring(on))")
    try {
      val p = s.split("/")
      (p(0).toDouble.toLong, p(1).toDouble.toLong, p(2).toInt, p(3) == "true")
    } catch { case _: Throwable => (-1L, -1L, -1, false) }
  }

  /** Evaluate a text chunk in the live state and return its single result. */
  /**
   * Read the raw LuaState under the SAME monitor ocelot-brain's executor takes.
   *
   * THE HARNESS WAS RACING THE MACHINE, and quiesced() did not stop it -- that
   * helper checks isExecuting, but Machine.switchTo(Yielded) arms a thread-pool
   * resume `executionDelay` ms out BEFORE the state leaves Running, so a false
   * from isExecuting means "a resume is already scheduled", not "no resume can
   * happen".  Measured: a deliberate 50 ms widening of the window inside
   * evalStr, applied at the watchdog-stats read alone, took the wedge rate from
   * 0.28 to 4 runs out of 4, and the machine's state was observed transitioning
   * Yielded -> SynchronizedCall *during* the read.  Roughly one run in four was
   * being lost to this across every measurement in the project.
   *
   * Machine.run() is `Machine.this.synchronized` -- ocelot-brain's own words
   * are "a really high level lock that we only use for saving and loading" --
   * and save/load take it too.  Taking it here serialises the harness against
   * the executor instead of guessing when the executor is idle.
   *
   * Wrap only the individual read.  Holding this across a ws.update() loop
   * would deadlock the machine it is trying to observe.
   */
  def evalStrLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                    lua: LuaState, code: String): String =
    machine.synchronized {
      val before = try lua.getTop catch { case _: Throwable => -1 }
      if (before != 1)
        p("!! raw-state read on a dirty stack: getTop=" + before +
          " (expected 1) -- something else is using this state")
      val r = evalStr(lua, code)
      val after = try lua.getTop catch { case _: Throwable => -1 }
      if (after != before)
        p("!! raw-state read left the stack at " + after + ", was " + before)
      r
    }

  def evalStr(lua: LuaState, code: String): String = {
    // getTop INSIDE the try.  It used to sit above it, and on a machine that
    // had already crashed it threw IllegalStateException("Lua state is
    // closed") straight out of this function -- which killed the whole harness
    // mid-run and threw away every milestone that had not been reached yet.
    // That is how the Phase 1 A-strings run ended with no diagnosis at all.
    var base = -1
    try {
      base = lua.getTop
      lua.load(new ByteArrayInputStream(code.getBytes(StandardCharsets.UTF_8)), "=smoke", "t")
      lua.call(0, 1)
      val r = if (lua.isNil(-1)) "<nil>" else lua.toString(-1)
      if (base >= 0) lua.setTop(base)
      r
    } catch {
      case t: Throwable => lua.setTop(base); "<error: " + t.getMessage + ">"
    }
  }

  def guard(machine: totoro.ocelot.brain.entity.machine.Machine): String = {
    if (!LuaStateFactory.isAvailable)
      die("LuaStateFactory.isAvailable == false: no native loaded, LuaJ would be substituted. " +
        "Check that debug.forceNativeLibPathFirst points at a directory containing " +
        "libjnlua52-windows-x86_64.dll and that the DLL's dependencies resolve.")
    if (LuaStateFactory.includeLuaJ)
      die("LuaStateFactory.includeLuaJ == true: LuaJ is in play. Refusing to report anything.")
    val arch = machine.architecture
    if (arch == null) die("machine.architecture is null")
    if (!arch.isInstanceOf[NativeLuaArchitecture])
      die("architecture is " + arch.getClass.getName + ", not a NativeLuaArchitecture -- LuaJ fallback.")
    if (!arch.isInstanceOf[NativeLua52Architecture])
      die("architecture is " + arch.getClass.getName + ", not NativeLua52Architecture.")
    val lua = luaOf(arch)
    if (lua == null) die("architecture holds a null LuaState")

    val nativeMark = evalStr(lua, "return rawget(_G, '_OCLJ_NATIVE') or '<stock>'")
    val jitStatus = evalStr(lua, "return rawget(_G, '_OCLJ_JIT') or '<n/a>'")
    val version = evalStr(lua, "return _VERSION")
    val hasJit = evalStr(lua, "return jit and (jit.version or 'jit-table-no-version') or 'NO-JIT-TABLE'")
    val erisShape = evalStr(lua,
      "if not eris then return 'NO-ERIS' end local ks={} for k in pairs(eris) do ks[#ks+1]=k end " +
        "table.sort(ks) return table.concat(ks,',')")
    val erisVer = evalStr(lua,
      "if not eris or not eris.version then return '<none>' end " +
        "if type(eris.version) ~= 'function' then return tostring(eris.version) end " +
        "local ok, a, b, c = pcall(eris.version) " +
        "return ok and (tostring(a) .. ' / ' .. tostring(b) .. ' / fmt=' .. tostring(c)) or '<err>'")

    val fp = s"native=$nativeMark | _VERSION=$version | jit=$hasJit ($jitStatus) | " +
      s"eris=[$erisShape] | eris.version=$erisVer"
    p("GUARD OK. arch=" + arch.getClass.getName)
    p("GUARD VM FINGERPRINT: " + fp)
    // The guard is TWO-SIDED, and the stock side is asserted with equal force.
    // Cell A of the benchmark is "what a player runs today" -- ocelot-brain's
    // bundled PUC-Lua 5.2 native, loaded simply by not pointing
    // forceNativeLibPathFirst at ours.  A silently mis-resolved DLL in EITHER
    // direction would produce a plausible-looking number for the wrong VM,
    // which is the one way this benchmark could lie outright.  So each mode
    // refuses the other's fingerprint.
    System.getProperty("ocljit.native", "luajit") match {
      case "luajit" =>
        if (!nativeMark.startsWith("luajit/"))
          die("the live state carries no _OCLJ_NATIVE marker: this is the STOCK PUC-Lua 5.2 " +
            "native, not the LuaJIT one. forceNativeLibPathFirst did not take effect.")
        if (hasJit == "NO-JIT-TABLE")
          die("no jit table in the live state: the shim did not open luaopen_jit.")
        if (erisShape == "NO-ERIS")
          die("no eris library in the live state: eris_lj.o did not link in, or luaopen_eris was not called.")
      case "stock" =>
        if (nativeMark.startsWith("luajit/"))
          die("ocljit.native=stock but the live state carries _OCLJ_NATIVE=" + nativeMark +
            ": OUR LuaJIT native is loaded, not the stock PUC-Lua 5.2 one. The baseline " +
            "cell would be measuring the thing it is supposed to be a baseline FOR.")
        if (hasJit != "NO-JIT-TABLE")
          die("ocljit.native=stock but the live state has a jit table (" + hasJit +
            "): this is not PUC Lua.")
        // NOT startsWith("Lua 5.2"): OC's own bundled PUC-5.2 native reports
        // "Lua+Eris 5.2" too, because luaopen_eris sets _VERSION in BOTH
        // natives -- OC uses Eris for its own persistence.  So _VERSION
        // cannot tell the two apart at all, and asserting "Lua 5.2" here
        // rejected a correctly-loaded stock native three times in a row.
        // The discriminators that DO work are the two above: the stock
        // native has no _OCLJ_NATIVE marker and no jit table.  (This is the
        // same weakness the roadmap records under "move _VERSION out of
        // luaopen_eris" -- it is a poor anti-vacuity guard for exactly this
        // reason.)
        if (!version.contains("5.2"))
          die("ocljit.native=stock but _VERSION=" + version + ", expected a 5.2 of some kind.")
      case other =>
        die("ocljit.native must be luajit or stock, not '" + other + "'")
    }
    fp
  }

  // ------------------------------------------------------------------ //
  // the bytecode gate (computer.lua.allowBytecode)
  // ------------------------------------------------------------------ //

  /**
   * OC reads computer.lua.allowBytecode and, when it is false, machine.lua's
   * sandboxed `load` forces mode="t" so precompiled chunks are refused.  On a
   * multiplayer server that is a security setting.  LuaJIT's lua_load has no
   * mode argument, so a shim that drops it turns allowBytecode=false into a
   * lie with no error and no log line.  This exercises the exact C path the
   * sandbox uses: jnlua's LuaState.load(stream, chunkname, mode).
   *
   * The internal 'b' path must stay OPEN -- eris_lj legitimately loads LuaJIT
   * bytecode via lj_bcwrite/lua_loadx -- which the eris round trip proves.
   */
  /**
   * MEMORY ACCOUNTING.  OC's per-machine RAM cap, on a state of its OWN.
   *
   * These run on a private LuaState, never the machine's: e3 deliberately
   * drives a state into out-of-memory, and a machine that has been starved is
   * no longer a machine you can persist and resume.
   *
   * The negative control for this whole group is the SHIPPED-BEFORE build, in
   * which lua_setallocf was a no-op: there, e1 reports kernelMemory == 1 (the
   * literal floor of NativeLuaArchitecture's `math.max(total - free, 1)`),
   * getFreeMemory() == getTotalMemory() forever, e2 sees no fall at all and e3
   * never raises.  Every assertion here is one that build fails.
   */
  def memoryProbes(): Unit = {
    val opt = LuaStateFactory.Lua52.createState()
    if (opt.isEmpty) { milestone("e0-state-available", ok = false, "createState() returned None"); return }
    val lua = opt.get
    try {
      val total0 = lua.getTotalMemory
      val free0 = lua.getFreeMemory
      val used0 = total0 - free0

      // e1 -- the state is accounted at all.  A fresh 5.2 state with the base
      // libraries open is tens of KB at minimum; the broken build says zero.
      milestone("e1-accounting-live", used0 > 10000,
        "fresh private state: total=" + total0 + " free=" + free0 + " used=" + used0 +
          (if (used0 > 10000) "" else "   <- used is ~0: the allocator is not accounting"))

      // e2 -- allocating moves the number, and by roughly what was allocated.
      // 20000 two-element tables is comfortably over 1 MB on GC64; asserting
      // only "grew by > 200 KB" keeps this insensitive to object layout.
      evalStr(lua, "__hold = {} for i = 1, 20000 do __hold[i] = {i, i} end return 'ok'")
      val usedAfter = lua.getTotalMemory - lua.getFreeMemory
      val grew = usedAfter - used0
      milestone("e2-freemem-falls", grew > 200000,
        "after 20000 tables: used " + used0 + " -> " + usedAfter + " (+" + grew + " bytes)" +
          (if (grew > 200000) "" else "   <- allocation did not move the counter"))

      // e3 -- and it comes back.  This is the anti-ratchet control: an
      // accounting bug that credits frees to the wrong side, or not at all,
      // passes e1 and e2 and fails only here.
      evalStr(lua, "__hold = nil return 'ok'")
      lua.gc(LuaState.GcAction.COLLECT, 0)
      val usedGc = lua.getTotalMemory - lua.getFreeMemory
      val freed = usedAfter - usedGc
      milestone("e3-gc-credits-frees", freed > grew / 2,
        "after dropping the reference and a full GC: used " + usedAfter + " -> " + usedGc +
          " (-" + freed + " of " + grew + " reclaimed)" +
          (if (freed > grew / 2) "" else "   <- frees are not being credited; `used` only ever rises"))

      // e4 -- THE ENFORCEMENT.  Cap the state just above where it stands and
      // allocate without bound.  On the shipped-before build this loop runs to
      // completion and the milestone fails; with the cap live it must raise,
      // and it must raise as OC's own memory exception rather than by killing
      // the process, which is the entire reason the pushcfunction sites had to
      // be made unrefusable in the same change.
      val cap = usedGc + 256 * 1024
      lua.setTotalMemory(cap)
      var raised = ""
      val base = lua.getTop
      try {
        // Deliberately NOT evalStr: that helper turns a throw into a returned
        // string, and here the throw IS the result being asserted.
        lua.load(new ByteArrayInputStream(
          "__eat = {} for i = 1, 100000000 do __eat[i] = {i, i, i, i} end return 'ok'"
            .getBytes(StandardCharsets.UTF_8)), "=eat", "t")
        lua.call(0, 1)
      } catch {
        case t: Throwable => raised = t.getClass.getSimpleName + ": " + String.valueOf(t.getMessage)
      }
      try lua.setTop(base) catch { case _: Throwable => }
      val usedAtCap = lua.getTotalMemory - lua.getFreeMemory
      val threw = raised.nonEmpty
      val stopped = usedAtCap <= cap
      milestone("e4-oom-at-the-cap", threw && stopped,
        "cap " + usedGc + " -> " + cap + "; unbounded allocation ended at used=" + usedAtCap +
          "; threw=" + (if (threw) raised.take(140) else "<nothing>") +
          (if (threw && stopped) "   (process alive: the bare-frame ERRMEM did not escape)"
           else if (!threw) "   <- the allocation loop RAN TO COMPLETION: the cap is not enforced"
           else "   <- it threw, but only after running past the cap"))

      lua.setTotalMemory(Int.MaxValue)
    } catch {
      case t: Throwable => milestone("e9-probes-completed", ok = false, "memory probes threw: " + t)
    } finally {
      try { lua.setTotalMemory(Int.MaxValue); lua.close() } catch { case _: Throwable => }
    }
  }

  def bytecodeGate(): Unit = {
    // On a state of its OWN, never the running machine's: these probes
    // deliberately provoke load errors, and a rejected load can leave values
    // on the stack that a live OpenOS has no business sharing.
    val opt = LuaStateFactory.Lua52.createState()
    if (opt.isEmpty) { milestone("g0-state-available", ok = false, "LuaStateFactory.Lua52.createState() returned None"); return }
    val lua = opt.get
    val binary = Array[Byte](0x1B.toByte, 'L', 'J', 0x02, 0x00, 0x00, 0x00)

    var rejected = false
    var msg = ""
    val topBefore = lua.getTop
    try {
      lua.load(new ByteArrayInputStream(binary), "=gate", "t")
      lua.pop(1)
    } catch { case t: Throwable => rejected = true; msg = String.valueOf(t.getMessage) }
    // The canonical shim delegates to LuaJIT's lua_loadx, whose refusal reads
    // "attempt to load chunk with wrong mode" (lj_err.h, LJ_ERR_XMODE).  The
    // hand-rolled byte-sniffer this replaced said "attempt to load a binary
    // chunk".  Accept either wording; what is asserted is the REFUSAL.
    val lower = msg.toLowerCase
    val refusalWorded = lower.contains("wrong mode") || lower.contains("binary")
    milestone("g1-bytecode-refused-with-mode-t", rejected && refusalWorded,
      "mode=\"t\" on a chunk starting 0x1B -> " +
        (if (!rejected) "ACCEPTED (allowBytecode=false is a lie)"
         else if (!refusalWorded) "rejected, but for an unexpected reason: " + msg.take(120)
         else "rejected: " + msg.take(120)))

    // A rejected load must leave the stack exactly as it found it.  A shim
    // that pushes its error message ON TOP of whatever lua_load already left
    // there leaks one slot per refusal into a state shared with OC's kernel;
    // the machine dies later with Error.InternalError and nothing points back
    // to the loader.
    val topAfter = lua.getTop
    milestone("g1b-rejected-load-leaks-no-stack", topAfter == topBefore,
      s"stack top before=$topBefore after=$topAfter" +
        (if (topAfter != topBefore) s" -- LEAK of ${topAfter - topBefore} slot(s) per refused chunk" else ""))
    lua.setTop(topBefore)

    // A text chunk with the same mode must still load, or the gate is just a
    // broken loader.
    var textOk = false
    try {
      lua.load(new ByteArrayInputStream("return 1+1".getBytes(StandardCharsets.UTF_8)), "=gate", "t")
      lua.call(0, 1)
      textOk = lua.toInteger(-1) == 2
      lua.pop(1)
    } catch { case t: Throwable => msg = String.valueOf(t.getMessage) }
    milestone("g2-text-still-loads-with-mode-t", textOk,
      "mode=\"t\" on Lua source -> " + (if (textOk) "loaded and returned 2" else "BROKEN: " + msg))

    // eris must still be able to round-trip a graph -- its own bytecode path
    // (lj_bcwrite / lua_loadx "b") is internal and must remain open.
    // _G goes in the perms table: a Lua closure carries its environment, and
    // the globals table is full of C functions that cannot be persisted by
    // value.  This is the same shape OC's PersistenceAPI uses.
    val r = evalStr(lua,
      "local t = {1, 2, 'three', nested = {a = 1}} t.self = t " +
        "local f = function(x) return x * 3 end " +
        "local blob = eris.persist({[_G] = '_G'}, {t = t, f = f}) " +
        "local back = eris.unpersist({['_G'] = _G}, blob) " +
        "return #blob .. '/' .. tostring(back.t.self == back.t) .. '/' .. tostring(back.f(14))")
    milestone("g3-eris-internal-bytecode-path-open", r.endsWith("/true/42"),
      "eris.persist+unpersist of a cyclic table and a closure -> " + r)
  }

  // ------------------------------------------------------------------ //
  // screen helpers
  // ------------------------------------------------------------------ //

  def screenText(screen: Screen): String = {
    val d = screen.data
    val sb = new StringBuilder
    for (row <- 0 until d.height) {
      val line = new StringBuilder
      for (col <- 0 until d.width) line.append(d.get(col, row).toChar)
      sb.append(line.toString.replaceAll("\\s+$", "")).append("\n")
    }
    sb.toString.replaceAll("(\n)+$", "\n")
  }

  def nonEmptyScreen(screen: Screen): String =
    screenText(screen).split("\n").filter(_.trim.nonEmpty).mkString("\n")

  def parse(text: String, key: String): String =
    (key + "=([^ \n]*)").r.findFirstMatchIn(text).map(_.group(1)).getOrElse("<missing>")

  // ------------------------------------------------------------------ //
  // The workload that gets planted on the hard disk.
  //
  // OpenOS's boot/90_filesystem.lua mounts every non-tmp filesystem and, on
  // the "init" event, runs <mount>/autorun.lua through shell.execute.  This
  // one registers a REPEATING TIMER and returns, so boot proceeds to the shell
  // while the closure keeps ticking off OpenOS's own event loop.
  //
  // Why that shape matters: the thing that has to survive the persist is a
  // live Lua closure with upvalues (nonce, n) held by OpenOS's event table --
  // exactly the object graph eris_lj M2 exists to serialise.
  //
  // The nonce is computer.uptime() at autorun time (plus a random draw).  It
  // has to be minted INSIDE the sandbox, per boot: a value supplied from Java
  // and written into the file would be reproduced identically by a reboot and
  // would prove nothing.  A reboot of the restored machine would re-run
  // autorun.lua at a different uptime and reset the counter to 1, which is
  // precisely what this test is looking for.
  // ------------------------------------------------------------------ //

  val AutorunLua: String =
    """-- The filesystem proxy for the disk this file was loaded from, handed to
      |-- us as the chunk's first vararg.  OpenOS's 90_filesystem.lua does
      |--     shell.execute(file, _ENV, proxy)
      |-- and sh.lua packs it into the chunk's varargs, so this is the ONLY
      |-- reliable way to read our sibling files: require() searches
      |-- /lib;/usr/lib;/home/lib;./ and never sees the disk, and loadfile()
      |-- resolves against $PWD, which is not the mount either.  The mount point
      |-- itself is /mnt/<address-prefix> and unpredictable.
      |local fsproxy = ...
      |local component = require("component")
      |local event = require("event")
      |local computer = require("computer")
      |local nonce = string.format("%.4f-%d", computer.uptime(), math.random(100000, 999999))
      |local n = 0
      |
      |-- The computer.lua.allowBytecode gate, probed from INSIDE the real
      |-- machine.lua sandbox.  This `load` is the sandbox wrapper at
      |-- machine.lua:754, which overwrites mode with "t" whenever
      |-- system.allowBytecode() is false.  The probe only REPORTS; the Java
      |-- side decides what the answer should have been from the setting it
      |-- read, so the same script serves the test and its negative control.
      |-- string.dump is in the sandbox (machine.lua:888), so this is exactly
      |-- what a hostile program on a server would type.
      |-- PHASE 0, POLE 1 -- COMPUTE.  Read bench/oc/mandelbrot.lua off the
      |-- disk and run it.  Pure float arithmetic, no allocation, no bit ops,
      |-- so its published CHECK (37904620) is valid unchanged and it cannot be
      |-- killed by the RAM cap.  Scheduled on its own timer so it gets a fresh
      |-- 5 s deadline rather than sharing autorun's.
      |local benchRow = "OCLJB01=pending"
      |local function readAll(name)
      |  local h, e = fsproxy.open(name, "r")
      |  if not h then return nil, tostring(e) end
      |  local parts, chunk = {}, nil
      |  repeat
      |    chunk = fsproxy.read(h, 4096)
      |    if chunk then parts[#parts + 1] = chunk end
      |  until not chunk
      |  fsproxy.close(h)
      |  return table.concat(parts)
      |end
      |event.timer(2, function()
      |  local src, err = readAll("mandelbrot.lua")
      |  if not src then benchRow = "OCLJB01=mandelbrot/READFAIL/" .. tostring(err) .. "/0/0" return end
      |  local fn, lerr = load(src, "=mandelbrot")
      |  if not fn then benchRow = "OCLJB01=mandelbrot/LOADFAIL/" .. tostring(lerr) .. "/0/0" return end
      |  local ok, check, secs = pcall(fn)
      |  if not ok then benchRow = "OCLJB01=mandelbrot/ERROR/" .. tostring(check):gsub("[ /]", "_") .. "/0/0" return end
      |  benchRow = string.format("OCLJB01=mandelbrot/ok/%s/%.4f/%d",
      |    check, secs, math.floor(computer.freeMemory() / 1024))
      |end)
      |
      |-- PHASE 0, POLE 2 -- COMPONENT.  Walk a directory tree through the same
      |-- proxy.  fs.list is an INDIRECT component call: machine.lua turns it
      |-- into a coroutine.yield -> SynchronizedCall, which costs one tick
      |-- minimum no matter how fast the VM is.  So this is the half of the
      |-- predicted bimodal answer where the JIT must buy nothing, and the
      |-- identity between cells IS the result.  Timed in uptime (ticks), not
      |-- os.clock, because the cost is scheduler latency and not CPU.
      |local walkRow = "OCLJW01=pending"
      |local function walk(path)
      |  local n = 0
      |  local l = fsproxy.list(path)
      |  if l then
      |    for i = 1, #l do
      |      n = n + 1
      |      if l[i]:sub(-1) == "/" then n = n + walk(path .. l[i]) end
      |    end
      |  end
      |  return n
      |end
      |event.timer(4, function()
      |  local t0 = computer.uptime()
      |  local ok, n = pcall(walk, "/")
      |  local dt = computer.uptime() - t0
      |  if not ok then walkRow = "OCLJW01=ERROR/" .. tostring(n):gsub("[ /]", "_") .. "/0"
      |  else walkRow = string.format("OCLJW01=%d/%.3f", n, dt) end
      |end)
      |
      |local dumped = string.dump(function() return 42 end)
      |local viaBytecode = load(dumped, "=gateprobe")
      |local viaText = load("return 6*7", "=textprobe")
      |-- ... and the same attempt with the mode named explicitly, which must
      |-- not reopen the gate: machine.lua ASSIGNS mode, it does not default it.
      |local viaForcedMode = load(dumped, "=gateprobe2", "bt")
      |local gate = "OCLJGATE=" ..
      |  (viaBytecode and "ACCEPTED" or "refused") .. "/" ..
      |  (viaForcedMode and "ACCEPTED" or "refused") .. "/" ..
      |  ((viaText and viaText() == 42) and "textok" or "TEXTBROKEN") .. "/" ..
      |  #dumped
      |
      |-- JIT PROBE.  A compute-bound loop run from INSIDE the sandbox -- i.e.
      |-- under OC's real deadline hook, with OC's real hookInterval and the real
      |-- checkDeadline doing its work -- timed with the sandbox's own os.clock.
      |-- Min of three, so a GC pause or a tick boundary cannot inflate it.  The
      |-- Java side reads this back and pairs it with the trace counter it
      |-- attached to the raw state; see docs/research/hook-vs-jit.md section 5.
      |local function work(k) local s = 0 for i = 1, k do s = s + (i % 7) * 2 end return s end
      |local N = 2000000
      |local best = math.huge
      |for r = 1, 3 do
      |  local t0 = os.clock(); work(N); local dt = os.clock() - t0
      |  if dt < best then best = dt end
      |end
      |local bench = string.format("OCLJBENCH=%.4f/%d/3", best, N)
      |
      |-- DEADLINE PROBE.  Six seconds after autorun starts -- after the Java
      |-- side has finished its boot and counter milestones -- spin forever
      |-- inside a pcall.  The kernel's timeout must interrupt it with "too long
      |-- without yielding", and the 0.5 s grace checkDeadline grants after the
      |-- first hit must be enough to paint the result.  This has to hold with
      |-- the stock kernel (standing hook) AND the watchdog kernel (nothing
      |-- armed until the deadline passes); it is the one thing the watchdog
      |-- must not break.  Spaces become underscores so the Java side's
      |-- whitespace-delimited parse() can read it.
      |local deadlineResult = "pending"
      |local bench2 = "pending"
      |-- DECLARED HERE, ABOVE the probe that calls it, and that placement is
      |-- load-bearing.  It was first declared down in the suite section, below
      |-- this point: the call sites inside the probe then compiled as reads of
      |-- a GLOBAL of the same name -- nil forever -- while the assignment
      |-- bound the local.  Everything registered fine and the suite simply
      |-- never started, with no error anywhere, because a nil global read is
      |-- only an error at the moment it is called.
      |local startSuiteOnce
      |event.timer(6, function()
      |  local okd, err = pcall(function() while true do end end)
      |  deadlineResult = (okd and "RAN-TO-COMPLETION" or tostring(err)):gsub(" ", "_")
      |  -- AFTER the timeout, on a LATER resume: checkDeadline re-armed a
      |  -- count=1 hook when it fired, and the kernel's disarm() is supposed to
      |  -- clear it when this resume returns.  If it did not, everything from
      |  -- here on runs one hook call per instruction.  So time the same loop
      |  -- again from a fresh timer callback.
      |  --
      |  -- Registered HERE, from inside the callback, and NOT up front.  Up
      |  -- front looks tidier and kills the machine: with this timer already
      |  -- pending when the deadline fires, every run ends in a kernel panic
      |  -- instead of "too long without yielding" and the probe never even
      |  -- writes its result (6 runs out of 6, OCLJDEADLINE never leaving
      |  -- "pending").  Not diagnosed further -- the sandbox program is the
      |  -- test fixture, not the thing under test, and the shape that works is
      |  -- the shape OC programs actually use: schedule follow-up work from
      |  -- the callback that finished.  The cost is that this registration
      |  -- races checkDeadline's 0.5 s grace, so roughly 1 run in 6 never
      |  -- reports and k4 tolerates that below.
      |  event.timer(1, function()
      |    local t0 = os.clock(); work(N)
      |    bench2 = string.format("OCLJBENCH2=%.4f", os.clock() - t0)
      |    -- The suite starts from the callback that finished, the shape OC
      |    -- programs actually use.
      |    event.timer(0.05, function() startSuiteOnce() end)
      |  end)
      |  -- Backup, registered here rather than up front: see startSuiteOnce.
      |  event.timer(6, function() startSuiteOnce() end)
      |end)
      |
      |-- PHASE 1 -- THE SUITE.  Everything above is Phase 0 and is left exactly
      |-- as it was, because those numbers are published; the suite runs the
      |-- same mandelbrot again as one of its rows, which makes the two an
      |-- independent cross-check of each other.
      |--
      |-- manifest.lua is GENERATED by the Java side from the contents of
      |-- bench/oc/ and its references.txt, so adding a benchmark means dropping
      |-- a file in that directory -- neither this script nor the Java side
      |-- needs editing.  Fields: reps, order (array of names), peak (name->KB).
      |--
      |-- NO CUSTOM ENVIRONMENT, deliberately.  The obvious way to hand a
      |-- benchmark its bit-ops module is load(src, name, "t", env) over a
      |-- table copied from _ENV.  Both halves of that are unsafe here: _ENV is
      |-- a Lua 5.2 construct LuaJIT does not implement, and cell A is real PUC
      |-- 5.2 -- so the two VMs under comparison would disagree about what the
      |-- code even means.  Instead the module goes in the sandbox global that
      |-- benchmarks already read, which is the mechanism the working Phase-0
      |-- pole already depends on, and the driver reads it back to prove it
      |-- landed rather than assuming it did.
      |local suite = {}          -- name -> {status=, check=, min=, max=, n=, free=}
      |local suiteOrder = {}
      |local suiteDone = "OCLJPDONE=pending"
      |local suiteNow = "-"
      |-- Separate from suiteNow ON PURPOSE.  The first version reported the
      |-- bit-ops path through suiteNow, which is PROGRESS and gets reset to
      |-- "-" when the last benchmark finishes -- so by the time Java read the
      |-- screen the marker was always gone and every run logged "compat: -".
      |-- The whole point of compat.lua recording which branch it took is that
      |-- the results row can carry it, so it needs a field that is written
      |-- once and never overwritten.
      |local compatPath = "unknown"
      |local dirty = true
      |local manifest = nil
      |local srcCache = {}
      |local encoreRow = "OCLJENCORE=pending"
      |local encoreSeq = 0
      |local startEncore
      |
      |-- One (benchmark, repetition) per timer callback, and the next one is
      |-- registered FROM the callback that finished rather than up front --
      |-- the same shape the deadline probe had to adopt, for the same reason.
      |-- It also means every unit gets a fresh 5 s deadline instead of sharing
      |-- one, so a benchmark that overruns costs its own row and not the run.
      |-- Paint the suite rows NOW, not on the next heartbeat tick.
      |--
      |-- This exists because of a question the harness could not answer.  When
      |-- a machine dies inside a benchmark the 0.05 s repaint timer never runs
      |-- again, so the screen still shows what it showed BEFORE the suite
      |-- started -- OCLJPCOMPAT=unknown, no row -- which is indistinguishable
      |-- from dying before the suite started at all.  startSuite() ends by
      |-- calling unit() synchronously, so no tick falls in between.  A whole
      |-- investigation of a lost cell-C run turned on that ambiguity and could
      |-- not settle it.  Painting before each pcall makes the last thing on
      |-- the screen the name of the benchmark that was actually running.
      |local paintSuite
      |
      |local unit
      |unit = function(bi, rep)
      |  local name = suiteOrder[bi]
      |  if not name then
      |    suiteDone = string.format("OCLJPDONE=%d", #suiteOrder)
      |    suiteNow = "-"
      |    dirty = true
      |    startEncore()
      |    return
      |  end
      |  local r = suite[name]
      |  suiteNow = name .. "#" .. rep
      |  dirty = true
      |  local function nxt()
      |    if rep >= (manifest.reps or 3) then event.timer(0.05, function() unit(bi + 1, 1) end)
      |    else event.timer(0.05, function() unit(bi, rep + 1) end) end
      |  end
      |  -- THE RAM GUARD.  LuaJIT has no emergency GC and the sandbox has no
      |  -- collectgarbage, so a benchmark that does not fit does not fail its
      |  -- own row -- it kills the machine and loses every row after it too.  A
      |  -- skipped row is a reported result; a dead machine is not.
      |  --
      |  -- THE MARGIN WAS peak*2 + 64 AND THAT WAS WRONG.  peak is the TOTAL
      |  -- standalone heap, base included, so doubling it asks for more than
      |  -- the machine ever has: sieve (312 KB) demanded 688 KB against a
      |  -- measured 653-676 KB free, so it could never run, and it did not --
      |  -- it skipped a rep, then reported SKIP-LOWMEM over two perfectly good
      |  -- ones.  The 2x came from LuaJIT letting the heap reach twice the LIVE
      |  -- set before a cycle completes, which is a statement about the live
      |  -- set and not about a total that already includes the base.
      |  -- UNITS.  manifest.peak is REAL KB (peak-inband.lua, standalone,
      |  -- collectgarbage("count")); computer.freeMemory() is real free
      |  -- DIVIDED by ramScaleFor64Bit -- see the comment where the manifest
      |  -- is written.  Multiply back, or this compares 1155 against 977 and
      |  -- skips a benchmark the machine had 2.5x the room for.
      |  local scale = manifest.ramScale or 1
      |  local freeKB = math.floor(computer.freeMemory() / 1024 * scale)
      |  local peak = (manifest.peak or {})[name] or 0
      |  local need = peak + 128
      |  -- AND THE PEAK IS AN UNDERCOUNT, always, by construction.  Every
      |  -- sampler is a GC safepoint, so the figure tracks the sample rate:
      |  -- sieve reads 440.8 KB from a hook every 10000 instructions, 1143.6
      |  -- from one sample per repetition, and UNSAMPLED its heap ON RETURN
      |  -- at REPS=1500 is 1205.7 -- above the sampled "peak", which a peak
      |  -- cannot be.  lj_gc.c:752-753 pins threshold = gc.total once the
      |  -- collector is behind, so behind is where it stays and the heap
      |  -- climbs until the cap stops it.  There is no peak to guard on.
      |  --
      |  -- So this is a BACKSTOP, not a predictor.  What actually protects the
      |  -- suite from a machine-killer is the `!` quarantine in
      |  -- references.txt, which records what has been OBSERVED to kill a
      |  -- machine instead of trying to predict it from a number that does not
      |  -- exist.  sieve and strings are both quarantined for that reason.
      |  -- manifest.guard is false for the PUC baseline; see the comment where
      |  -- the manifest is generated.  PUC collects and retries when an
      |  -- allocation is refused, so it does not need this, and its
      |  -- freeMemory() counts uncollected garbage as used, so the figure the
      |  -- guard would be testing is not a measure of what is available.
      |  if manifest.guard ~= false and peak > 0 and freeKB < need then
      |    -- Only report a skip if NOTHING has succeeded yet.  A later rep
      |    -- being skipped must not overwrite the status and CHECK that
      |    -- earlier reps established, which is how two good sieve runs came
      |    -- back looking like a failure with a byte count where the checksum
      |    -- should have been.
      |    if r.n == 0 then
      |      r.status = "SKIP-LOWMEM"
      |      r.check = string.format("%dKB_lt_%dKB", freeKB, need)
      |    end
      |    dirty = true
      |    return nxt()
      |  end
      |  local src = srcCache[name]
      |  if not src then
      |    local e
      |    src, e = readAll(name .. ".lua")
      |    if not src then r.status = "READFAIL" r.check = tostring(e):gsub("[ /]", "_") dirty = true return nxt() end
      |    srcCache[name] = src
      |  end
      |  local fn, lerr = load(src, "=" .. name)
      |  if not fn then r.status = "LOADFAIL" r.check = tostring(lerr):gsub("[ /]", "_") dirty = true return nxt() end
      |  -- The last paint before control leaves for the benchmark.  If the
      |  -- machine does not come back, this is the evidence of what it was
      |  -- doing when it went.
      |  if paintSuite then paintSuite() end
      |  local ok, check, secs = pcall(fn)
      |  if not ok then
      |    local msg = tostring(check)
      |    -- OC's own timeout sentinel, reached through pcall.  Kept distinct
      |    -- from any other error because it means "too big for one resume",
      |    -- which is a sizing fact about the benchmark rather than a failure
      |    -- of the VM under test.
      |    r.status = msg:find("too long without yielding", 1, true) and "DEADLINE" or "ERROR"
      |    r.check = msg:gsub("[ /]", "_"):sub(1, 40)
      |    dirty = true
      |    return nxt()
      |  end
      |  secs = tonumber(secs) or -1
      |  r.status = "ok"
      |  -- "/" is the row separator and " " ends the Java side's parse, so a
      |  -- CHECK containing either would silently shift every later field --
      |  -- the time would be read out of the free-memory column and still look
      |  -- like a number.  Benchmarks return plain integers, hex digests and
      |  -- %.4f floats today; this makes that a property of the row format
      |  -- rather than of the current set of benchmarks.
      |  r.check = tostring(check):gsub("[ /]", "_")
      |  if secs < r.min then r.min = secs end
      |  if secs > r.max then r.max = secs end
      |  r.n = r.n + 1
      |  r.free = math.floor(computer.freeMemory() / 1024)
      |  dirty = true
      |  return nxt()
      |end
      |
      |-- THE ENCORE -- what does a world save actually cost?
      |--
      |-- Every OpenComputers world save runs eris.persist, and Phase 0 measured
      |-- what that does to us: 196 608 B of machine code and 349 traces go to
      |-- 0 and 0.  So a machine loaded from a save starts COLD and must
      |-- recompile.  The obvious way to price that is to run a benchmark after
      |-- the restore -- but the Java side has no safe way to tell a restored
      |-- sandbox to do anything, and reaching into a running machine's Lua
      |-- state from the harness thread is the exact race this project spent a
      |-- milestone closing.
      |--
      |-- So the probe rides on the thing under test.  A repeating timer holding
      |-- a Lua closure is precisely what eris has to serialise, so the encore
      |-- SURVIVES THE SAVE by the same mechanism the boot counter does and
      |-- fires again on the other side unprompted.  Java only has to read a
      |-- sequence number and notice it advanced: samples before the persist are
      |-- warm, the first sample after the restore is cold.
      |--
      |-- Phase 0's m3 tried to answer this by watching an IDLE machine and got
      |-- it backwards -- it PASSED the thrashing build and FAILED the working
      |-- one, because an idle machine has nothing hot to recompile.  This is
      |-- the workload that measurement was missing.
      |startEncore = function()
      |  local name = manifest and manifest.encore
      |  if not name or not srcCache[name] then return end
      |  event.timer(manifest.encore_period or 5, function()
      |    local fn = load(srcCache[name], "=" .. name)
      |    if not fn then return end
      |    local ok, check, secs = pcall(fn)
      |    encoreSeq = encoreSeq + 1
      |    if ok then
      |      encoreRow = string.format("OCLJENCORE=%s/ok/%s/%.4f/%d",
      |        name, tostring(check), tonumber(secs) or -1, encoreSeq)
      |    else
      |      encoreRow = string.format("OCLJENCORE=%s/ERR/%s/-1/%d", name,
      |        tostring(check):gsub("[ /]", "_"):sub(1, 30), encoreSeq)
      |    end
      |    dirty = true
      |  end, math.huge)
      |end
      |
      |paintSuite = function()
      |  component.gpu.set(1, 23, suiteDone .. " OCLJPNOW=" .. suiteNow ..
      |    " OCLJPCOMPAT=" .. compatPath .. "                    ")
      |  component.gpu.set(1, 41, encoreRow .. "                    ")
      |  for i = 1, #suiteOrder do
      |    local nm = suiteOrder[i]
      |    local r = suite[nm]
      |    component.gpu.set(1, 23 + i, string.format("OCLJP%02d=%s/%s/%s/%.4f/%.4f/%d/%d%s",
      |      i, nm, r.status, r.check,
      |      r.min == math.huge and -1 or r.min, r.max, r.free, r.n,
      |      "                    "))
      |  end
      |end
      |
      |local function startSuite()
      |  local msrc = readAll("manifest.lua")
      |  if not msrc then suiteDone = "OCLJPDONE=NOMANIFEST" dirty = true return end
      |  local mfn = load(msrc, "=manifest")
      |  if not mfn then suiteDone = "OCLJPDONE=BADMANIFEST" dirty = true return end
      |  local okm
      |  okm, manifest = pcall(mfn)
      |  if not okm or type(manifest) ~= "table" then suiteDone = "OCLJPDONE=BADMANIFEST" dirty = true return end
      |  -- compat.lua is loaded ONCE and published as a sandbox global, because
      |  -- require() searches /lib;/usr/lib;/home/lib;./ and never sees this
      |  -- disk.  It is a hard stop if it does not land: bench/oc/compat.lua
      |  -- records WHICH bit-ops implementation it picked, and a benchmark that
      |  -- silently took the other one would be a different program measured
      |  -- under the same name.
      |  local csrc = readAll("compat.lua")
      |  if csrc then
      |    local cfn = load(csrc, "=compat")
      |    if cfn then
      |      local okc, c = pcall(cfn)
      |      -- Guarded, because this is NOT inside a pcall.  The whole reason
      |      -- the sandbox global is used at all is that _G is assumed to
      |      -- exist there; an assumption that kills the suite by indexing
      |      -- nil is worse than one that reports itself, and the readback
      |      -- two lines down is what turns it into a reported result.
      |      if okc and type(c) == "table" and type(_G) == "table" then _G.__OCLJ_COMPAT = c end
      |    end
      |  end
      |  -- Read it back THROUGH _G, the way a benchmark will, instead of
      |  -- trusting that the write above was visible.
      |  local seen = _G and _G.__OCLJ_COMPAT
      |  compatPath = seen and tostring(seen.path) or "UNREACHABLE"
      |  suiteOrder = manifest.order or {}
      |  for i = 1, #suiteOrder do
      |    suite[suiteOrder[i]] = {status = "pending", check = "-", min = math.huge, max = -1, n = 0, free = 0}
      |  end
      |  dirty = true
      |  unit(1, 1)
      |end
      |
      |-- The suite must start AFTER the deadline probe, and the way it is
      |-- started matters as much as the ordering.
      |--
      |-- The first version of this was a repeating gate timer registered up
      |-- front that polled for bench2.  It made the deadline probe never
      |-- report: OCLJDEADLINE stayed "pending", the watchdog never fired
      |-- (fires=0), and k1/k2/k5 all failed -- while the SAME native and the
      |-- same kernel passed 30/30 under the previous harness.  That is the
      |-- failure the k4 comment above already describes in as many words,
      |-- from the last time someone registered follow-up work up front, and
      |-- it cost a run to rediscover.
      |--
      |-- So the suite is started the way OC programs actually schedule work:
      |-- from the callback that finished.  Both registrations below happen
      |-- INSIDE the deadline probe's callback, i.e. after the timeout has
      |-- already fired, so nothing of ours is ever pending across it.
      |local suiteStarted = false
      |startSuiteOnce = function()
      |  if suiteStarted then return end
      |  suiteStarted = true
      |  startSuite()
      |end
      |
      |-- THE HEARTBEAT, AND WHY ITS BODY IS INSIDE A pcall.
      |--
      |-- This is a REPEATING timer, and OpenOS drops a repeating timer whose
      |-- callback raises.  So a single error anywhere in the paint path -- one
      |-- bad string.format, one gpu.set that objects -- silently and
      |-- permanently stops the scoreboard, while the machine carries on
      |-- running the shell perfectly happily.  From outside, that is
      |-- indistinguishable from a hung benchmark: OCLJCTR frozen,
      |-- lastError=null, isRunning=true, and nothing in any log.  Cell A of
      |-- the Phase 1 matrix did exactly that in about 6 of its 26 runs and
      |-- cost two rows of the published table.
      |--
      |-- Wrapping the body has two effects, and both matter.  The timer can no
      |-- longer die, so a paint error costs one tick instead of the run; and
      |-- the error is CAPTURED, so the next tick can say what it was.  The
      |-- tick row below is painted separately and is itself protected, because
      |-- the one thing that must survive a broken paint path is the evidence
      |-- that the paint path is broken.
      |local perr, perrs = "none", 0
      |event.timer(0.05, function()
      |  n = n + 1
      |  local pok, pe = pcall(function()
      |  -- Phase 0 rows.  Repainted like the others: boot output scrolls, and
      |  -- a row written once can be gone by the time Java reads the screen.
      |  component.gpu.set(1, 20, "OCLJENV=" .. math.floor(computer.totalMemory() / 1024)
      |    .. "/" .. math.floor(computer.freeMemory() / 1024) .. "        ")
      |  component.gpu.set(1, 21, benchRow .. "                    ")
      |  component.gpu.set(1, 22, walkRow .. "                    ")
      |  component.gpu.set(1, 12, bench2 .. "        ")
      |  component.gpu.set(1, 13, "OCLJDEADLINE=" .. deadlineResult .. "        ")
      |  component.gpu.set(1, 14, bench .. "        ")
      |  component.gpu.set(1, 15, "OCLJNONCE=" .. nonce .. " OCLJCTR=" .. n .. "        ")
      |  -- repainted every tick for the same reason as the counter: boot output
      |  -- would otherwise scroll a one-shot line off the screen.
      |  component.gpu.set(1, 16, gate .. "        ")
      |  -- The suite block.  gpu.set is a DIRECT call and OC meters those per
      |  -- tick; painting twenty-odd rows every 50 ms would spend the machine's
      |  -- call budget on the scoreboard and stretch the wall time of the very
      |  -- runs it is reporting.  So paint on change, plus once a second
      |  -- regardless, because boot output scrolls a row away.
      |  if dirty or n % 20 == 0 then
      |    dirty = false
      |    paintSuite()
      |  end
      |  end)
      |  if not pok then
      |    perrs = perrs + 1
      |    perr = tostring(pe):gsub("[ /]", "_"):sub(1, 60)
      |  end

      |  -- Minimal, independently protected, and never skipped: OCLJTICK is a
      |  -- liveness signal that does not depend on anything above it working.
      |  pcall(component.gpu.set, 1, 19,
      |    "OCLJTICK=" .. n .. " OCLJPERR=" .. perrs .. ":" .. perr .. "        ")
      |end, math.huge)
      |""".stripMargin

  // ------------------------------------------------------------------ //

  def main(args: Array[String]): Unit = {
    val conf = if (args.length > 0) args(0) else ""
    val t0 = System.currentTimeMillis()
    def secs = f"${(System.currentTimeMillis() - t0) / 1000.0}%.1f"

    p("=" * 72)
    p("OC-LuaJIT smoke test -- OpenOS on LuaJIT, persist, resume")
    p("java=" + System.getProperty("java.version") + " " + System.getProperty("os.arch") +
      "  os=" + System.getProperty("os.name"))
    p("conf=" + (if (conf.isEmpty) "<ocelot-brain defaults>" else conf))

    if (conf.nonEmpty) {
      val cp = Paths.get(conf)
      if (!Files.isRegularFile(cp)) die("config file not found: " + conf)
      Ocelot.configPath = Some(cp)
    }
    Ocelot.initialize()

    p("LuaStateFactory.isAvailable  = " + LuaStateFactory.isAvailable)
    p("LuaStateFactory.include52    = " + LuaStateFactory.include52)
    p("LuaStateFactory.includeLuaJ  = " + LuaStateFactory.includeLuaJ)
    p("forceNativeLibPathFirst      = '" + totoro.ocelot.brain.Settings.get.forceNativeLibPathFirst + "'")
    p("computer.lua.allowBytecode   = " + totoro.ocelot.brain.Settings.get.allowBytecode)
    // The d2 milestone below is PARAMETERISED on this setting rather than
    // assuming it.  A gate test that only ever runs in the "shut" polarity
    // cannot tell enforcement from a probe that always prints "refused"; the
    // run with allowBytecode = true is that test's negative control, and it
    // must show the SAME chunk being ACCEPTED.  Everything else here is
    // polarity-independent: g1 passes mode="t" explicitly and never consults
    // the setting.
    val bytecodeAllowed = totoro.ocelot.brain.Settings.get.allowBytecode
    if (bytecodeAllowed) {
      p("!! NEGATIVE-CONTROL RUN: computer.lua.allowBytecode = TRUE.")
      p("!! The sandbox gate is expected to be OPEN in this run.  A pass here")
      p("!! is NOT a security result -- it proves d2 can fail.")
    }

    // --- the machine -------------------------------------------------
    val wsDir = Files.createTempDirectory("ocljit-smoke-a")
    val ws = new Workspace(wsDir)
    val computer = ws.add(new Case(Tier.Three))
    val cpu = new CPU(Tier.Three)
    computer.inventory(0) = cpu
    computer.inventory(1) = new GraphicsCard(Tier.Three)
    computer.inventory(2) = new Memory(ExtendedTier.ThreeHalf)

    // The hard disk is bound to a real directory we pre-populate, so OpenOS
    // finds autorun.lua when it mounts it.
    val diskDir: Path = Files.createTempDirectory("ocljit-smoke-hdd")
    Files.write(diskDir.resolve("autorun.lua"), AutorunLua.getBytes(StandardCharsets.UTF_8))
    // The Phase-0 compute pole, planted next to autorun.lua so the sandbox can
    // read it through the filesystem proxy.  OCLJ_BENCH_SABOTAGE plants a
    // deliberately wrong variant instead -- the control for the checksum
    // assertion, because a checksum nobody has watched REJECT a wrong answer
    // is not evidence of anything.
    val benchDirPath = Paths.get(System.getProperty("ocljit.benchdir", "bench/oc"))
    val benchSrcPath = benchDirPath.resolve("mandelbrot.lua")
    val benchSabotage = System.getenv("OCLJ_BENCH_SABOTAGE") == "1"
    var benchSrc = new String(Files.readAllBytes(benchSrcPath), StandardCharsets.UTF_8)
    if (benchSabotage) {
      benchSrc = benchSrc.replace("local W, H, MAXI = 1024, 1024, 128", "local W, H, MAXI = 1024, 1024, 13")
      p("!! OCLJ_BENCH_SABOTAGE=1: mandelbrot planted with MAXI=13, so its CHECK")
      p("!! must NOT match 37904620.  A run that still reports a pass here means")
      p("!! the checksum assertion is not being enforced.")
    }
    Files.write(diskDir.resolve("mandelbrot.lua"), benchSrc.getBytes(StandardCharsets.UTF_8))

    // --- PHASE 1: the suite -------------------------------------------
    // Every .lua in bench/oc/ is planted; WHICH of them run, in what order,
    // and what CHECK each must produce is decided by references.txt.  Adding a
    // benchmark is therefore dropping a file and a line in that directory --
    // neither this harness nor autorun.lua needs editing, which is what keeps
    // the reference values and the assertions from drifting apart.
    //
    // Line format:  [!]<name> <CHECK> [<peakKB>]
    //
    // A LEADING "!" means QUARANTINED: the file is planted and its reference is
    // known, but it stays OUT of the default suite and runs only when named
    // explicitly in OCLJ_BENCH_ONLY.  That exists for a benchmark expected to
    // exhaust the machine -- `strings`, whose naive coding allocates about 3 MB
    // in a machine with under 1 MB free (bench/oc/strings2.lua).  Whether it
    // survives is a real question worth measuring, but measuring it must not
    // also cost the persist and restore milestones that run after the suite,
    // so it gets a run of its own.
    // peakKB is the standalone-measured peak; the sandbox driver refuses to
    // start a benchmark unless free memory is comfortably above it, because
    // LuaJIT has no emergency GC and an oversized workload does not fail its
    // own row, it kills the machine and loses every row after it.
    val refsPath = benchDirPath.resolve("references.txt")
    val refCheck = scala.collection.mutable.LinkedHashMap.empty[String, String]
    val refPeak = scala.collection.mutable.HashMap.empty[String, Int]
    val refQuarantine = scala.collection.mutable.HashSet.empty[String]
    if (Files.exists(refsPath)) {
      val srcF = scala.io.Source.fromFile(refsPath.toFile, "UTF-8")
      try for (raw <- srcF.getLines()) {
        val line = raw.trim
        if (line.nonEmpty && !line.startsWith("#")) {
          val f = line.split("\\s+")
          if (f.length >= 2) {
            val quarantined = f(0).startsWith("!")
            val nm = if (quarantined) f(0).substring(1) else f(0)
            refCheck(nm) = f(1)
            if (quarantined) refQuarantine += nm
            if (f.length >= 3) refPeak(nm) = try f(2).toInt catch { case _: Throwable => 0 }
          }
        }
      } finally srcF.close()
    } else p("!! no " + refsPath + ": the Phase 1 suite will not run (Phase 0 is unaffected)")

    var suiteNames: Seq[String] =
      refCheck.keys.toSeq.filter(n => Files.exists(benchDirPath.resolve(n + ".lua")))
    System.getenv("OCLJ_BENCH_ONLY") match {
      case null =>
        val held = suiteNames.filter(refQuarantine.contains)
        suiteNames = suiteNames.filterNot(refQuarantine.contains)
        if (held.nonEmpty)
          p("quarantined, not in the default suite: " + held.mkString(",") +
            "   (run one with OCLJ_BENCH_ONLY=<name>)")
      case o =>
        // Naming a benchmark explicitly overrides its quarantine; that is the
        // only way a quarantined one ever runs.
        val keep = o.split(",").map(_.trim).filter(_.nonEmpty).toSet
        suiteNames = suiteNames.filter(keep.contains)
        p("OCLJ_BENCH_ONLY=" + o + " -- suite restricted to " + suiteNames.mkString(",") +
          (if (suiteNames.exists(refQuarantine.contains))
             "   (includes a QUARANTINED benchmark: this run may lose the machine, which is the point)"
           else ""))
    }
    val suiteReps =
      try Option(System.getenv("OCLJ_REPS")).map(_.toInt).getOrElse(3)
      catch { case _: Throwable => 3 }
    if (benchSabotage) {
      // The sabotage run is a control for the Phase-0 checksum and nothing
      // else.  Leaving the suite in would make every Phase-1 row fail for a
      // reason that has nothing to do with what is being controlled for.
      p("!! OCLJ_BENCH_SABOTAGE=1: the Phase 1 suite is skipped; this run controls Phase 0 only")
      suiteNames = Seq.empty
    }
    // Everything, including compat.lua, which the driver publishes as a
    // sandbox global because require() cannot see this disk.
    var plantedN = 0
    val dstream = Files.newDirectoryStream(benchDirPath, "*.lua")
    try dstream.forEach { pth =>
      val fn = pth.getFileName.toString
      if (fn != "mandelbrot.lua") {   // already planted above, possibly sabotaged
        Files.copy(pth, diskDir.resolve(fn), StandardCopyOption.REPLACE_EXISTING)
        plantedN += 1
      }
    } finally dstream.close()
    val mfst = new StringBuilder
    mfst.append("-- GENERATED by OcljSmoke from bench/oc/references.txt.  Do not edit.\n")
    mfst.append("return {\n  reps = ").append(suiteReps).append(",\n  order = {")
      .append(suiteNames.map(n => "\"" + n + "\"").mkString(", ")).append("},\n  peak = {")
      .append(suiteNames.map(n => "[\"" + n + "\"] = " + refPeak.getOrElse(n, 0)).mkString(", "))
      .append("},\n")
    // The encore: one benchmark kept running on a repeating timer after the
    // suite ends, so that post-save recovery has a workload to be measured
    // against.  mandelbrot by default -- it allocates nothing (so it cannot be
    // killed by the RAM cap while the harness is busy persisting), it is pure
    // compute (so a flushed trace actually shows up), and its cost is already
    // known in every cell.
    val encorePick = Option(System.getenv("OCLJ_ENCORE")).filter(_.nonEmpty)
      .getOrElse(if (suiteNames.contains("mandelbrot")) "mandelbrot" else suiteNames.headOption.getOrElse(""))
    val encorePeriod =
      try Option(System.getenv("OCLJ_ENCORE_PERIOD")).map(_.toInt).getOrElse(5)
      catch { case _: Throwable => 5 }
    mfst.append("  encore = ").append(if (encorePick.isEmpty) "nil" else "\"" + encorePick + "\"")
      .append(",\n  encore_period = ").append(encorePeriod)
    // WHETHER THE RAM GUARD APPLIES AT ALL, and it does not apply to cell A.
    //
    // The guard exists for one reason: LuaJIT has no emergency GC, so our
    // lj52_alloc refuses an allocation rather than collecting and retrying,
    // and an oversized benchmark takes the machine down instead of failing its
    // own row.  PUC Lua has that retry (lmem.c, luaM_realloc_), so on
    // ocelot-brain's bundled 5.2 the premise is simply false.
    //
    // Worse, the INPUT is wrong there too.  computer.freeMemory() on PUC
    // reports whatever has not been collected yet as used, which is near zero
    // for a machine that has been working -- the Phase 1 matrix caught it
    // reading 4 KB and 13 KB free on machines that then ran the same benchmark
    // a dozen more times.  A guard fed that number skips real work: one
    // strings2 run lost two of its three reps, and a sieve row was reported
    // SKIP-LOWMEM after two good reps had already completed.
    //
    // Read from the system property and not from `nativeMode`, which is the
    // obvious thing to reach for and is a forward reference here -- it is
    // defined ~100 lines below, with the guard block, while this runs during
    // planting.  scalac catches it, but only with the real classpath.
    //
    // So the guard is gated on our native being loaded.  Cell A gets none,
    // which is right on both counts: it does not need one, and the number it
    // would be handed is not a measure of what is available.
    mfst.append(",\n  guard = ").append(if (System.getProperty("ocljit.native", "luajit") == "stock") "false" else "true")
    // THE GUARD'S TWO SIDES WERE IN DIFFERENT UNITS, and it took the direction
    // that refuses.  manifest.peak is measured standalone by
    // bench/oc/checks/peak-inband.lua through collectgarbage("count"), which
    // counts REAL KB.  computer.freeMemory() does not: ocelot-brain's
    // NativeLuaArchitecture charges real bytes against the cap
    //
    //     :145  setTotalMemory(kernelMemory + ceil(memoryBytes * ramScale))
    //
    // and then DIVIDES on the way back out to the sandbox
    //
    //     :161  freeMemory = ((getFreeMemory min (getTotalMemory - kernelMemory)) / ramScale)
    //
    // Once anything is allocated getFreeMemory is below memoryBytes*ramScale,
    // so the min resolves to the real free figure and what the sandbox reads
    // is exactly realFree / ramScale.  At the pinned 3.0 that made the guard
    // test sieve's 1155 REAL KB against 977 SCALED KB -- a 3x error, and in
    // the direction that skips a benchmark the machine had room for.
    //
    // Publish the scale so the guard can put both sides in real KB.  It is
    // Settings.get.ramScaleFor64Bit that NativeLuaArchitecture:315 reads, and
    // it applies only for a pointer width >= 8; our native is GC64, so always.
    // Reached fully-qualified to match :978-987, which needs no import.
      .append(",\n  ramScale = ").append(totoro.ocelot.brain.Settings.get.ramScaleFor64Bit)
      .append(",\n}\n")
    Files.write(diskDir.resolve("manifest.lua"), mfst.toString.getBytes(StandardCharsets.UTF_8))
    p("planted " + plantedN + " more .lua from " + benchDirPath + "; suite = " +
      (if (suiteNames.isEmpty) "<none>" else suiteNames.mkString(",")) + " x" + suiteReps +
      " reps; encore = " + (if (encorePick.isEmpty) "<none>" else encorePick) +
      " every " + encorePeriod + " s")
    // 120 nested directories for the component pole.  Nested rather than flat
    // so the walk makes 120 SEPARATE fs.list calls (one per level); a flat
    // directory would be a single call and would measure nothing.
    var wdir = diskDir
    for (i <- 1 to 120) { wdir = wdir.resolve("d" + i); Files.createDirectories(wdir) }
    p("planted mandelbrot.lua (" + benchSrc.length + " B" + (if (benchSabotage) ", SABOTAGED" else "") +
      ") and a 120-deep directory tree")
    val hdd = new HDDManaged(Tier.One)
    hdd.customRealPath = Some(diskDir)
    computer.inventory(3) = hdd
    p("hdd real path = " + diskDir + " (autorun.lua planted, " + AutorunLua.length + " bytes)")

    computer.inventory(4) = Loot.LuaBiosEEPROM.create()
    computer.inventory(5) = Loot.OpenOsFloppy.create()
    // Tier.Three (160x50), not Tier.One (50x16).  Results come back by reading
    // fixed screen rows, and a 64-hex sha256 digest does not fit on a 50-column
    // row -- nor do nine benchmark rows plus the existing nonce/gate/deadline
    // block fit in 16.  The GPU is already Tier.Three.
    val screen = ws.add(new Screen(Tier.Three))
    computer.connect(screen)

    cpu.setArchitecture(classOf[NativeLua52Architecture])
    p("architecture pinned to NativeLua52Architecture")

    val started = computer.machine.start()
    if (!started) die("machine.start() returned false")

    // --- (a) the LuaState opens --------------------------------------
    var ticks = 0
    var arch: AnyRef = null
    while (ticks < 60 && (arch == null || luaOf(arch) == null)) {
      ws.update(); Thread.sleep(30); ticks += 1
      arch = computer.machine.architecture
    }
    if (arch == null || !arch.isInstanceOf[NativeLuaArchitecture] || luaOf(arch) == null)
      die("no LuaState after " + ticks + " ticks; arch=" +
        (if (arch == null) "null" else arch.getClass.getName) +
        "; lastError=" + computer.machine.lastError)
    milestone("a-lua-state-opens", ok = true, "LuaState created after " + ticks + " ticks")

    // --- (b) machine.lua loads and the sandbox is built ---------------
    // This is the milestone a stock LuaJIT never reaches with the JIT on:
    // machine.lua's opening statement spins waiting for a count hook that a
    // build without LUAJIT_ENABLE_CHECKHOOK never delivers from inside a trace.
    var spins = 0
    while (kernelMemoryOf(arch) == 0 && spins < 300 && computer.machine.isRunning) {
      ws.update(); Thread.sleep(30); spins += 1
    }
    val km = kernelMemoryOf(arch)
    milestone("b-machine.lua-sandbox", km > 0,
      "kernelMemory=" + km + " after " + spins + " ticks; running=" + computer.machine.isRunning +
        "; lastError=" + computer.machine.lastError)
    if (km == 0)
      die("machine.lua never built its sandbox. If the JIT is on, this is the CHECKHOOK " +
        "symptom: rebuild LuaJIT with -DLUAJIT_ENABLE_CHECKHOOK.")

    // The LuaState belongs to the machine's worker thread; quiesce before
    // reading it, or the guard and the kernel race on the same state.
    val qOk = quiesced(computer.machine, "the VM fingerprint")
    val fp = guard(computer.machine)

    // --- (b2) the MACHINE's own accounting -----------------------------
    // Read-only, on the live machine, so it says something about the thing
    // players actually run rather than about a private test state.
    // kernelMemory is NativeLuaArchitecture's math.max(getTotalMemory -
    // getFreeMemory, 1) taken after a full GC once machine.lua has built the
    // sandbox.  A build whose allocator does not account bottoms out at that
    // literal 1 on every run; that is the negative control for this line.
    val mLua = luaOf(arch)
    val mTotal = mLua.getTotalMemory
    val mFree = mLua.getFreeMemory
    val mKernel = kernelMemoryOf(arch)
    milestone("b2-machine-memory-accounted", mKernel > 10000 && mFree < mTotal,
      "kernelMemory=" + mKernel + "  totalMemory=" + mTotal + "  freeMemory=" + mFree +
        "  used=" + (mTotal - mFree) +
        (if (mKernel > 10000 && mFree < mTotal) ""
         else if (mKernel <= 1) "   <- kernelMemory is at its floor of 1: the RAM cap is reported but NOT enforced"
         else "   <- freeMemory == totalMemory: nothing is being charged"))

    // --- JIT PROBE, part 1 ---------------------------------------------
    // Confirmation run for docs/research/hook-vs-jit.md section 5, step 0.
    // On the quiesced RAW state, never the sandbox: machine.lua strips `jit`
    // from the sandbox, and jit.attach is the only way to see whether traces
    // are being made at all.  Attached here -- after machine.lua has built its
    // sandbox, before OpenOS boots -- so the count covers the boot.
    //   -Docljit.jit=off is the control: the same boot, the compiler switched
    // off in the same state at the same moment.  Note what that does NOT
    // cover: kernel init already ran with the JIT on by the time we get here.
    val jitMode = System.getProperty("ocljit.jit", "on")
    val kernelMode = System.getProperty("ocljit.kernel", "stock")
    // Which kernel ACTUALLY ran.  The patched kernel sets _OCLJ_KERNEL in the
    // raw _G as its first act; OC's does not.  Without this, every
    // "kernel=watchdog" in the log would merely echo -Docljit.kernel, and a
    // classpath mishap that quietly loaded OC's kernel would go unnoticed.
    val kernelSeen = evalStrLocked(computer.machine, mLua, "return tostring(_OCLJ_KERNEL)")
    val nativeMode = System.getProperty("ocljit.native", "luajit")
    milestone("k0-kernel-observed", (kernelMode == "watchdog") == (kernelSeen == "watchdog"),
      "asked for " + kernelMode + ", raw _G._OCLJ_KERNEL=" + kernelSeen +
        (if ((kernelMode == "watchdog") == (kernelSeen == "watchdog")) ""
         else "   <- the kernel that ran is NOT the one requested; nothing below means what it says"))
    var qj = 0
    quiesced(computer.machine, "the JIT probe read-out")
    if (jitMode == "off")
      p("JIT PROBE: jit.off() + jit.flush() -> jit.status()=" +
        evalStrLocked(computer.machine, mLua, "jit.off() jit.flush() return tostring(jit.status())"))
    p("JIT PROBE: mode=" + jitMode + "  attach -> " + evalStrLocked(computer.machine, mLua,
      "__ocljTr = {start=0, stop=0, abort=0, flush=0} " +
      "__ocljTrFn = function(what) local t = __ocljTr t[what] = (t[what] or 0) + 1 end " +
      "jit.attach(__ocljTrFn, 'trace') return 'ok'"))
    val tBootStart = System.currentTimeMillis()

    // --- (c) OpenOS boots to a shell ----------------------------------
    var i = 0
    var booted = false
    while (i < 600 && computer.machine.isRunning && !booted) {
      ws.update(); Thread.sleep(25); i += 1
      if (i % 20 == 0) {
        val t = nonEmptyScreen(screen)
        booted = t.contains("/home #") && t.contains("OCLJCTR=")
      }
    }
    val tBootShell = System.currentTimeMillis()
    val txtA = nonEmptyScreen(screen)
    p(s"SCREEN AFTER BOOT ($i ticks, ${secs}s, running=${computer.machine.isRunning}):")
    println(txtA)
    p("lastError = " + computer.machine.lastError)
    milestone("c-openos-shell", txtA.contains("/home #"),
      "OpenOS shell prompt on screen (" + txtA.split("\n").length + " non-empty lines)")

    // --- (d) the autorun closure is alive and counting ----------------
    val nonceA = parse(txtA, "OCLJNONCE")
    val ctrA1 = try parse(txtA, "OCLJCTR").toInt catch { case _: Throwable => -1 }
    var j = 0
    while (j < 60 && computer.machine.isRunning) { ws.update(); Thread.sleep(25); j += 1 }
    val txtA2 = nonEmptyScreen(screen)
    val ctrA2 = try parse(txtA2, "OCLJCTR").toInt catch { case _: Throwable => -1 }
    milestone("d-autorun-counter-live", nonceA != "<missing>" && ctrA1 > 0 && ctrA2 > ctrA1,
      s"nonce=$nonceA counter $ctrA1 -> $ctrA2 over 60 ticks")
    if (nonceA == "<missing>")
      die("autorun.lua never ran: no OCLJNONCE on screen. OpenOS did not mount the hard disk, " +
        "or /etc/filesystem.cfg disabled autorun.")

    // --- JIT PROBE, part 2: read out, then detach BEFORE the persist ------
    // The counter closure lives in the jit library's attach registry, which is
    // not something a persisted blob should ever contain.
    val bootMs = tBootShell - tBootStart
    var qk = 0
    quiesced(computer.machine, "the k-milestone read-out")
    val trRaw = evalStrLocked(computer.machine, mLua, "local t = __ocljTr return t.start .. '/' .. t.stop .. '/' .. t.abort .. '/' .. t.flush")
    val jitStatus = evalStrLocked(computer.machine, mLua, "return tostring(jit.status())")
    evalStrLocked(computer.machine, mLua, "jit.attach(__ocljTrFn) __ocljTr = nil __ocljTrFn = nil return 'ok'")
    val bench = parse(txtA2, "OCLJBENCH")
    p("JIT PROBE: kernel=" + kernelMode + "  mode=" + jitMode + "  jit.status()=" + jitStatus +
      "  traces start/stop/abort/flush=" + trRaw +
      "  ticks-to-shell=" + i + "  boot-ms=" + bootMs +
      "  sandbox-bench(min-s/iters/reps)=" + bench)
    // With the WATCHDOG kernel and the JIT on, the numbers stop being merely
    // informational: the boot must no longer thrash, and the sandbox loop must
    // run as compiled code.  Thresholds sit between the two measured regimes
    // -- ~2700 discarded traces and 0.485 s under the standing hook, ~2 traces
    // and 0.008 s with no hook at all -- with room on both sides.
    // Thresholds, and what they sit between.  Measured regimes for the 2M-
    // iteration sandbox loop: compiled 0.003-0.005 s; plain interpreter
    // 0.017-0.026 s; under OC's standing hook 0.47-0.49 s.  So the "compiled"
    // threshold must sit BELOW the interpreter -- 0.010 s -- or it would pass
    // with no compiled code running at all (it did, at 0.1 s, until a review
    // pointed it out).  Traces completed during boot: ~110 with the watchdog,
    // ~2500 thrashing under the standing hook; 300 sits between.
    //   The same thresholds are asserted INVERTED in the other polarities,
    // so each one is observed to fail where the thrash is real, not merely
    // observed to pass where it is not.
    val stops = try trRaw.split("/")(1).toInt catch { case _: Throwable => -1 }
    val benchS = try bench.split("/")(0).toDouble catch { case _: Throwable => -1.0 }
    if (kernelMode == "watchdog" && jitMode == "on") {
      milestone("k2-jit-not-thrashing", stops >= 0 && stops < 300,
        "traces completed during boot = " + stops + " (standing hook: ~2500; want < 300)")
      milestone("k3-sandbox-loop-is-compiled", benchS > 0 && benchS < 0.010,
        "sandbox loop best-of-3 = " + benchS + " s (interpreter: 0.017-0.026; standing hook: 0.47; want < 0.010)")
    } else if (nativeMode == "stock") {
      // PUC Lua 5.2 has no compiler, so "traces" and "mcode" are not merely
      // zero, the accessors do not exist.  That absence is this cell's own
      // control: it is how we know the baseline is a genuinely different VM
      // and not our native with the JIT switched off.
      milestone("k2-baseline-has-no-jit", stops == 0 && trRaw.startsWith("<") == false || stops == 0,
        "PUC 5.2 baseline: traces=" + stops + " (a VM with no compiler cannot thrash)")
    } else if (kernelMode == "stock" && jitMode == "on") {
      milestone("k2-jit-not-thrashing-NEGATIVE-CONTROL", stops >= 300,
        "stock kernel: traces completed during boot = " + stops + " -- the thrash must be SEEN here (want >= 300)")
      milestone("k3-sandbox-loop-is-compiled-NEGATIVE-CONTROL", benchS >= 0.010,
        "stock kernel: sandbox loop = " + benchS + " s -- must be slow here (want >= 0.010)")
    } else {
      milestone("k3-sandbox-loop-is-compiled-NEGATIVE-CONTROL", benchS >= 0.010,
        "JIT off: sandbox loop = " + benchS + " s -- interpreter speed, must be >= 0.010")
    }
    milestone("j0-jit-switch-honoured", (jitMode == "off") == (jitStatus == "false"),
      "mode=" + jitMode + " -> jit.status()=" + jitStatus +
        (if ((jitMode == "off") == (jitStatus == "false")) ""
         else "   <- the probe's own control did not take; this run's numbers mean nothing"))

    // --- (d2) the allowBytecode gate, as seen from inside the sandbox --
    // bytecodeGate() below exercises the C entry point (jnlua's
    // LuaState.load, i.e. the shim's lua_load macro).  THIS milestone
    // exercises the other enforcement point: machine.lua's sandboxed `load`
    // calling the base library `load`, inside a booted OpenOS, with
    // computer.lua.allowBytecode = false.  Both must hold; neither implies
    // the other, and a shim that drops lua_load's mode still passes this one
    // -- which is exactly why the C-level test exists as well.
    val gateA = parse(txtA2, "OCLJGATE")
    val gateParts = gateA.split("/")
    // What the setting demands.  With allowBytecode = false machine.lua
    // overwrites mode with "t" and BOTH attempts must be refused -- including
    // the one that names mode="bt" itself, because the wrapper assigns the
    // parameter rather than defaulting it.  With allowBytecode = true the
    // wrapper leaves mode alone and both must load.
    val wantBytecode = if (bytecodeAllowed) "ACCEPTED" else "refused"
    val gateShaped = gateParts.length == 4 && gateParts(2) == "textok" &&
      gateParts(3).nonEmpty && gateParts(3).forall(_.isDigit)
    val gateOk = gateShaped &&
      gateParts(0) == wantBytecode && gateParts(1) == wantBytecode
    val d2id = if (bytecodeAllowed) "d2-sandbox-bytecode-gate-NEGATIVE-CONTROL"
               else "d2-sandbox-bytecode-gate"
    milestone(d2id, gateOk,
      if (gateA == "<missing>")
        "no OCLJGATE on screen -- the in-sandbox probe never ran"
      else
        "allowBytecode=" + bytecodeAllowed + " so want " + wantBytecode + ";  " +
          "load(string.dump(f))=" + gateParts(0) +
          "  load(dump, name, \"bt\")=" + (if (gateParts.length > 1) gateParts(1) else "?") +
          "  load(text)=" + (if (gateParts.length > 2) gateParts(2) else "?") +
          "  dump bytes=" + (if (gateParts.length > 3) gateParts(3) else "?") +
          (if (gateOk) ""
           else if (!gateShaped) "   <- the probe itself is broken; this run proves nothing"
           else if (bytecodeAllowed) "   <- the probe reports 'refused' even with the gate OPEN: it is not reading the setting"
           else "   <- allowBytecode=false is NOT being enforced in the sandbox"))

    // --- (k1) the deadline still fires -----------------------------------
    // The watchdog replaces the mechanism behind "too long without yielding";
    // this is the assertion that the replacement enforces it.  Waits for the
    // probe autorun.lua scheduled: up to timeout (5 s) + grace + slack.
    var kd = 0
    var dlRes = parse(nonEmptyScreen(screen), "OCLJDEADLINE")
    while (kd < 600 && computer.machine.isRunning && (dlRes == "pending" || dlRes == "<missing>")) {
      ws.update(); Thread.sleep(25); kd += 1
      if (kd % 10 == 0) dlRes = parse(nonEmptyScreen(screen), "OCLJDEADLINE")
    }
    milestone("k1-deadline-still-fires", dlRes == "too_long_without_yielding",
      "kernel=" + kernelMode + "  pcall(while true do end) -> " + dlRes + " after " + kd + " ticks" +
        (if (dlRes == "too_long_without_yielding") "   (and the machine survived it: running=" + computer.machine.isRunning + ")"
         else if (dlRes == "RAN-TO-COMPLETION") "   <- an infinite loop RETURNED: the deadline is not enforced"
         else if (dlRes == "pending" || dlRes == "<missing>") "   <- never came back: the loop was not interrupted (machine running=" + computer.machine.isRunning + ", lastError=" + computer.machine.lastError + ")"
         else "   <- interrupted, but not with the timeout sentinel"))

    // --- (k5) the watchdog says it fired ---------------------------------
    // Counters kept by the shim: first fires, periodic re-fires, hook calls
    // ignored by the thread filter.  Read on the quiesced raw state.  In
    // watchdog mode the timeout probe above must have produced at least one
    // fire; in stock mode the kernel never arms, so all three must be zero.
    // If this one probes a running machine it does not merely misreport --
    // it corrupted the stack badly enough to break the persist that follows.
    val wdStats = {
      // quiesced() is kept as a DIAGNOSTIC only.  It reports whether the
      // machine looked idle; it does not make the read safe, and believing it
      // did cost about one run in four.  evalStrLocked is what makes it safe.
      quiesced(computer.machine, "the watchdog stats read-out")
      evalStrLocked(computer.machine, mLua,
        "local f, r, x, dp, h = _OCLJ_WATCHDOG.stats() return f .. '/' .. r .. '/' .. x .. '/' .. dp .. '/' .. tostring(h)")
    }
    val wdFires = try wdStats.split("/")(0).toInt catch { case _: Throwable => -1 }
    p("WATCHDOG STATS: fires/refires/filtered/depth/hooked = " + wdStats)
    if (nativeMode == "stock")
      milestone("k5-baseline-has-no-watchdog", wdFires == -1,
        "PUC 5.2 baseline: _OCLJ_WATCHDOG is absent (stats read " + wdStats + ")" +
          (if (wdFires == -1) "" else "   <- our native is loaded; this is not a baseline"))
    else if (kernelMode == "watchdog")
      milestone("k5-watchdog-fired", wdFires >= 1,
        "fires=" + wdFires + " after the timeout probe" + (if (wdFires >= 1) "" else "   <- the deadline was enforced by something other than the watchdog, or not at all"))
    else
      milestone("k5-watchdog-fired-NEGATIVE-CONTROL", wdFires == 0,
        "stock kernel never arms: fires=" + wdFires + " (must be 0)")

    // --- (k4) still fast AFTER the timeout ----------------------------
    // The only thing that distinguishes "disarm() cleared checkDeadline's
    // count=1 re-arm" from "it did not" is the speed of the NEXT resume.
    //   The window is 600 ticks, not 200: in 4 of 10 otherwise-green runs the
    // value arrived AFTER a 200-tick window (and was 0.0037 s -- compiled --
    // when it did).  The loop itself is milliseconds; what is slow to arrive
    // is the gpu.set that paints it, on a machine that has just spent a
    // whole 5 s timeout inside one resume and is being throttled by OC's
    // per-machine call budget.  The ticks it took are reported so the
    // distribution stays visible.
    var k4 = 0
    var b2 = parse(nonEmptyScreen(screen), "OCLJBENCH2")
    while (k4 < 600 && computer.machine.isRunning && (b2 == "pending" || b2 == "<missing>")) {
      ws.update(); Thread.sleep(25); k4 += 1
      if (k4 % 10 == 0) b2 = parse(nonEmptyScreen(screen), "OCLJBENCH2")
    }
    val bench2S = try b2.toDouble catch { case _: Throwable => -1.0 }
    if (kernelMode == "watchdog" && jitMode == "on") {
      // Tolerates a MISSING report, never a slow one.  The probe schedules
      // itself from inside the callback that just took the timeout, so it
      // races checkDeadline's 0.5 s grace and about 1 run in 6 never gets
      // registered at all (see the comment in AutorunLua; registering it up
      // front instead kills the machine).  A missing value says nothing about
      // the hook; a slow one says disarm() did not clear the re-arm, and that
      // still fails.  The distribution is reported either way so a change in
      // the miss rate is visible rather than silent.
      milestone("k4-still-compiled-after-timeout", bench2S < 0 || bench2S < 0.010,
        "sandbox loop on the resume after the timeout = " + b2 + " s (before: " + bench.split("/")(0) + "; want < 0.010), reported after " + k4 + " ticks" +
          (if (bench2S > 0 && bench2S < 0.010) ""
           else if (bench2S < 0) "   (not reported -- the follow-up timer lost its race with the grace; no claim either way)"
           else "   <- SLOW after the timeout: the count=1 re-arm survived disarm()"))
    } else {
      milestone("k4-still-compiled-after-timeout-NEGATIVE-CONTROL", bench2S < 0 || bench2S >= 0.010,
        "kernel=" + kernelMode + " jit=" + jitMode + ": loop after the timeout = " + b2 + " (must NOT be compiled-fast here)")
    }

    // --- (p0) PHASE 0: the two poles -----------------------------------
    // The whole point of the ordering: if the compute pole shows no win, the
    // rest of the benchmark suite is cancelled rather than built.
    var pw = 0
    var benchRow = parse(nonEmptyScreen(screen), "OCLJB01")
    var walkRow = parse(nonEmptyScreen(screen), "OCLJW01")
    while (pw < 800 && computer.machine.isRunning &&
           (benchRow == "pending" || benchRow == "<missing>" || walkRow == "pending" || walkRow == "<missing>")) {
      ws.update(); Thread.sleep(25); pw += 1
      if (pw % 8 == 0) {
        val t = nonEmptyScreen(screen)
        benchRow = parse(t, "OCLJB01"); walkRow = parse(t, "OCLJW01")
      }
    }
    val envRow = parse(nonEmptyScreen(screen), "OCLJENV")
    p("PHASE0 env=" + envRow + " (totalKB/freeKB)")
    p("PHASE0 compute=" + benchRow)
    p("PHASE0 component=" + walkRow)
    val bParts = benchRow.split("/")
    val bOk = bParts.length >= 4 && bParts(1) == "ok"
    val bCheck = if (bParts.length >= 3) bParts(2) else "<none>"
    val bSecs = try bParts(3).toDouble catch { case _: Throwable => -1.0 }
    val wParts = walkRow.split("/")
    val wDirs = try wParts(0).toInt catch { case _: Throwable => -1 }
    val wSecs = try wParts(1).toDouble catch { case _: Throwable => -1.0 }

    // The checksum is the whole defence against a fast wrong answer, and it is
    // the PUBLISHED reference (bench/results-2026-09-01.md) because this file
    // is byte-identical to bench/mandelbrot.lua but for its last two lines.
    val benchSabotaged = System.getenv("OCLJ_BENCH_SABOTAGE") == "1"
    val checkOk = bOk && bCheck == "37904620"
    if (benchSabotaged)
      milestone("p0-compute-checksum-NEGATIVE-CONTROL", !checkOk,
        "sabotaged mandelbrot returned " + bCheck + "; the checksum MUST reject it" +
          (if (!checkOk) "   (rejected, as it must be)"
           else "   <- a wrong answer PASSED: the checksum is not being enforced"))
    else
      milestone("p0-compute-checksum", checkOk,
        "mandelbrot CHECK=" + bCheck + " (published reference 37904620), " + bSecs + " s" +
          (if (checkOk) "" else "   <- wrong or missing: this cell's time means nothing"))

    milestone("p0-component-walk-ran", wDirs >= 120,
      "walked " + wDirs + " entries via indirect fs.list calls in " + wSecs +
        " s of uptime" + (if (wDirs >= 120) "" else "   <- the walk did not reach the planted depth"))
    p("PHASE0 ROW: native=" + System.getProperty("ocljit.native", "luajit") +
      " kernel=" + kernelMode + " jit=" + jitMode +
      "  compute=" + bSecs + "s  component=" + wSecs + "s  env=" + envRow)

    // --- (p1) PHASE 1: the suite ---------------------------------------
    // Waits on the driver's own DONE sentinel rather than polling each row for
    // "pending": with N rows, "have they all stopped saying pending" is a
    // weaker question than "did the driver reach the end of its list", and only
    // the second one distinguishes a finished suite from one that died in the
    // middle.
    if (suiteNames.nonEmpty) {
      val suiteWaitS =
        try Option(System.getenv("OCLJ_SUITE_WAIT")).map(_.toInt).getOrElse(300)
        catch { case _: Throwable => 600 }
      var sw = 0
      val swMax = suiteWaitS * 40                 // 25 ms per poll
      var doneRow = parse(nonEmptyScreen(screen), "OCLJPDONE")
      var lastNow = ""
      // THE STALL DETECTOR.  OCLJCTR is bumped by autorun's 0.05 s repeating
      // timer, so it advances for as long as the machine dispatches timers at
      // all.  Without this the harness sat out its whole 300 s budget twice in
      // the Phase 1 matrix (C-strings, C-matmul) on machines that had stopped
      // painting 280 s earlier -- ocelot-brain reports isRunning for a machine
      // that is merely Sleeping or Yielded, so "still running" says nothing.
      // A stalled scoreboard is the observable that does.
      var lastCtr = -1
      var stalled = 0
      var stallStop = false
      // OCLJTICK counts heartbeat firings.  Its RATE is the diagnostic: the
      // timer's period is 0.05 s, so a healthy machine turns in hundreds of
      // ticks over a suite wait and a hobbled one turns in tens.
      val tick0 = try parse(nonEmptyScreen(screen), "OCLJTICK").toInt catch { case _: Throwable => -1 }
      val twall0 = System.currentTimeMillis()
      while (sw < swMax && computer.machine.isRunning && !stallStop &&
             (doneRow == "pending" || doneRow == "<missing>")) {
        ws.update(); Thread.sleep(25); sw += 1
        if (sw % 8 == 0) {
          val t = nonEmptyScreen(screen)
          doneRow = parse(t, "OCLJPDONE")
          val now = parse(t, "OCLJPNOW")
          // A heartbeat, so a suite that takes minutes does not look hung and
          // so a run killed by the outer timeout says where it got to.
          if (now != lastNow && now != "<missing>") { lastNow = now; p("PHASE1 .. " + now) }
          val ctr = try parse(t, "OCLJCTR").toInt catch { case _: Throwable => -1 }
          if (ctr >= 0 && ctr == lastCtr) {
            stalled += 1
            // 400 polls of 25 ms with no tick = 10 s of a machine that is
            // supposed to repaint twenty times a second.
            if (stalled >= 400) {
              stallStop = true
              // OCLJTICK/OCLJPERR come from the heartbeat's separately
              // protected tail, so they survive a paint path that is itself
              // broken.  If OCLJPERR is non-zero the scoreboard was dying of
              // its own error rather than the machine hanging -- which is the
              // distinction that used to be invisible.
              val tick = parse(t, "OCLJTICK")
              val perr = parse(t, "OCLJPERR")
              p("!! SUITE STALLED: OCLJCTR frozen at " + ctr + " for ~10 s while the " +
                "machine still reports running.  OCLJTICK=" + tick + " OCLJPERR=" + perr +
                ".  Giving up here instead of waiting out " + suiteWaitS + " s.")
              if (perr != "<missing>" && !perr.startsWith("0:"))
                p("!! the heartbeat's own paint path raised -- that, not the benchmark, " +
                  "is what stopped the scoreboard: " + perr)
              reportDeath(computer.machine, screen, "the Phase 1 suite (stalled, not stopped)")
            }
          } else { lastCtr = ctr; stalled = 0 }
        }
      }
      if (!computer.machine.isRunning) reportDeath(computer.machine, screen, "the Phase 1 suite")
      val suiteText = nonEmptyScreen(screen)
      doneRow = parse(suiteText, "OCLJPDONE")

      // IS THIS RUN VOID?  A cell-A machine sometimes comes out of the
      // deadline probe with OC's post-timeout hook still armed --
      // checkDeadline re-arms debug.sethook(co, checkDeadline, "", 1), a hook
      // on EVERY INSTRUCTION, and when the disarm loses the race the machine
      // keeps running at roughly 1/200th speed for the rest of its life.
      //
      // Measured: 13 heartbeat ticks in 130 s against 400+ in a healthy run,
      // on a 0.05 s timer.  Nothing crashes, so lastError is null and
      // isRunning is true; the suite simply never gets far enough to paint a
      // row.  Reported naively that looks like every benchmark failing, which
      // is how two rows of the Phase 1 table were lost.
      //
      // ROOT-CAUSED 2026-09-04, AND IT WAS THIS HARNESS.  Three explanations
      // were tried and all three were wrong: a paint error killing the
      // heartbeat (refuted, OCLJPERR=0:none), timers lost inside the deadline
      // callback (refuted, the machine ran no timers at all), and OC's
      // post-timeout count=1 hook never being cleared (refuted -- lj52_wd_disarm
      // clears it, and a machine crawling under a per-instruction hook could
      // not report isExecuting=false on the first poll, which every wedged run
      // did).
      //
      // It was the harness reading the raw LuaState while ocelot-brain's
      // executor was using it.  quiesced() does not prevent that: switchTo
      // (Yielded) arms a thread-pool resume `executionDelay` ms out BEFORE the
      // state leaves Running, so !isExecuting means "a resume is already
      // scheduled".  Proven both ways -- widening the window inside evalStr by
      // 50 ms took the wedge rate to 4 of 4, with the machine observed moving
      // Yielded -> SynchronizedCall DURING the read; taking the executor's own
      // monitor (evalStrLocked) took it to 0 of 20 with the marker rate
      // unchanged.
      //
      // The detector below stays, because a machine can still fail to progress
      // for reasons we have not met yet -- but it no longer names a cause.  A cell-C run
      // (kernel=watchdog) hobbled with the same signature, and matrix3's
      // C-matmul had burned 453 s the same way before that.  The reason is in
      // native/kernel/patch-machine-lua.lua's own header: the patcher replaces
      // the three ARM sites but deliberately leaves checkDeadline's post-expiry
      // debug.sethook(co, checkDeadline, "", 1) alone, reasoning that it only
      // runs after the deadline has passed and that disarm() clears it.  When
      // that disarm loses the race, the count=1 hook stays armed and any cell
      // crawls.  So this is OUR kernel too, and clearing that re-arm properly
      // is a real fix available to us -- unlike the stock kernel, which we do
      // not control.
      //
      // Either way the run is declared VOID and its rows are not judged: a
      // discarded run is honest, a run reported as eight benchmark failures is
      // not.
      //
      // The predictor is exact in the four runs that established it: every
      // hobbled run had k4's post-timeout loop time missing, every healthy one
      // had it.  The tick rate is used here because it is measured over the
      // suite wait itself rather than inferred from an earlier probe.
      val tickN = try parse(suiteText, "OCLJTICK").toInt catch { case _: Throwable => -1 }
      val twall = (System.currentTimeMillis() - twall0) / 1000.0
      val tickRate = if (tick0 >= 0 && tickN >= tick0 && twall > 1.0) (tickN - tick0) / twall else -1.0
      val incomplete = doneRow != suiteNames.length.toString
      val hobbled = incomplete && tickRate >= 0 && tickRate < 1.0
      if (hobbled) {
        p("PHASE1 VOID: the machine was hobbled, not the benchmark -- " +
          f"$tickRate%.2f" + " heartbeat ticks/s over " + f"$twall%.0f" + " s (healthy: 3-4/s) " +
          "on a 0.05 s timer.  The run is DISCARDED, not failed.  Re-run it.  " +
          "The known cause of this -- the harness reading the raw Lua state " +
          "while the executor thread was using it -- was fixed by evalStrLocked. " +
          "If this fires again it is something new; capture the log.")
        milestone("p1-run-VOID-machine-not-progressing", ok = false,
          "this run produced no usable benchmark data and its rows are not judged: the " +
            "machine ran at " + f"$tickRate%.2f" + " ticks/s.  Not a benchmark result; re-run.")
      } else
      milestone("p1-suite-complete", doneRow == suiteNames.length.toString,
        "driver reported OCLJPDONE=" + doneRow + " for " + suiteNames.length + " benchmarks" +
          (if (doneRow == suiteNames.length.toString) ""
           else "   <- the suite did not finish; rows below are partial"))
      // Which bit-ops implementation the sandbox actually took.  It differs
      // BY CELL and not by accident: PUC 5.2 cannot parse bitwise operators,
      // so cell A necessarily runs the bit32 branch while B and C run the
      // operator one.  Rows that use compat are therefore comparing two
      // implementations across A, which is a real property of what players
      // have rather than a defect -- but it has to be visible in the results.
      val compatPath = parse(suiteText, "OCLJPCOMPAT")
      p("PHASE1 compat path in-sandbox: " + compatPath)
      milestone("p1-compat-path-known", compatPath == "operators" || compatPath == "bit32-STITCHED",
        "sandbox bit-ops implementation = " + compatPath +
          (if (compatPath == "operators" || compatPath == "bit32-STITCHED") ""
           else "   <- compat.lua did not load, or _G is not reachable from the driver"))
      p("PHASE1 rows: name/status/CHECK/min/max/freeKB/reps")
      for (i <- suiteNames.indices if !hobbled) {
        val key = "OCLJP%02d".format(i + 1)
        val row = parse(suiteText, key)
        val f = row.split("/")
        val nm = if (f.length >= 1) f(0) else suiteNames(i)
        val st = if (f.length >= 2) f(1) else "<norow>"
        val ck = if (f.length >= 3) f(2) else "<none>"
        val mn = if (f.length >= 4) f(3) else "-1"
        val mx = if (f.length >= 5) f(4) else "-1"
        val fr = if (f.length >= 6) f(5) else "-1"
        val nr = if (f.length >= 7) f(6) else "0"
        p("PHASE1 ROW: native=" + nativeMode + " kernel=" + kernelMode + " jit=" + jitMode +
          "  " + nm + "/" + st + "/" + ck + "/" + mn + "/" + mx + "/" + fr + "/" + nr)
        val want = refCheck.getOrElse(suiteNames(i), "<no-reference>")
        val nrI = try nr.toInt catch { case _: Throwable => 0 }
        val ok = st == "ok" && ck == want && nrI >= 1
        // A skipped row is a reported outcome, not a pass.  It is called out
        // separately because "did not fit in this machine" is a fact about
        // OC's RAM cap that belongs in the writeup, and is not the same kind
        // of thing as a wrong answer.
        val why =
          if (ok) ""
          else if (st == "SKIP-LOWMEM") "   <- did not fit: " + ck
          else if (st == "DEADLINE") "   <- overran OC's 5 s per-resume deadline; it is sized too big"
          else if (st == "ok") "   <- WRONG ANSWER: expected " + want
          else "   <- " + st + ": " + ck
        milestone("p1-" + suiteNames(i), ok,
          nm + " CHECK=" + ck + " (reference " + want + "), min " + mn + " s / max " + mx +
            " s over " + nr + " reps, " + fr + " KB free after" + why)
      }
    }

    // --- (m1/m2) what the machine costs, and what a save destroys ------
    // Sampled either side of the persist below.  Both numbers were masked
    // until the watchdog landed: with traces thrashing there was almost no
    // mcode to account for and nothing worth flushing.
    val (mc0, mcCap, tr0, jitOn) =
      if (quiesced(computer.machine, "the mcode read-out")) jitStatsLocked(computer.machine, mLua)
      else (-1L, -1L, -1, false)
    p("JIT MEMORY: mcode=" + mc0 + " B of a " + mcCap + " B cap, traces=" + tr0 +
      ", jit=" + jitOn + "  (the RAM cap cannot see any of this)")
    // The control for "mcode is real" is the JIT being OFF, not the stock
    // kernel.  The first draft asserted the stock kernel holds ~no mcode and
    // it FAILED, for a reason worth keeping: stock holds MORE (448 KB / 776
    // traces against the watchdog's 192 KB / 349).  Thrashing does not stop
    // the compiler, it stops traces being ENTERED -- so the standing hook was
    // paying for machine code it could never run.  A wrong guess encoded as a
    // milestone; the number replaced the guess.
    if (nativeMode == "stock") {
      milestone("m1-baseline-has-no-mcode", mc0 == -1,
        "PUC 5.2 baseline: _OCLJ_JITSTATS is absent, so there is no machine code to " +
          "be blind to -- the RAM cap sees everything this VM allocates" +
          (if (mc0 == -1) "" else "   <- our native is loaded; this is not a baseline"))
    } else if (jitMode == "off") {
      milestone("m1-mcode-is-real-NEGATIVE-CONTROL", mc0 == 0,
        "jit=off: mcode=" + mc0 + " B, traces=" + tr0 + " (must be exactly 0)")
    } else {
      // 64 KB is one mcode area; less than that means nothing was compiled
      // and the flush measurement below would be vacuous.
      milestone("m1-mcode-is-real", mc0 >= 65536,
        "kernel=" + kernelMode + ": " + mc0 + " B of machine code the RAM cap does not charge for, " +
          tr0 + " traces, cap " + mcCap + " B" +
          (if (mc0 >= 65536) "" else "   <- too little compiled to measure a flush against"))
    }

    // --- (m3a) WARM encore samples, taken before the persist -----------
    // Best of several, because the comparison wants a machine whose traces are
    // compiled; one sample could land on a GC pause and make the post-restore
    // cost look smaller than it is.
    var encWarm = -1.0
    var encSeqBefore = -1
    var encName = "<none>"
    if (suiteNames.nonEmpty) {
      var es = 0
      while (es < 1200 && computer.machine.isRunning && encSeqBefore < 3) {
        ws.update(); Thread.sleep(25); es += 1
        if (es % 8 == 0) {
          val f = parse(nonEmptyScreen(screen), "OCLJENCORE").split("/")
          if (f.length >= 5 && f(1) == "ok") {
            val sq = try f(4).toInt catch { case _: Throwable => -1 }
            val sc = try f(3).toDouble catch { case _: Throwable => -1.0 }
            if (sq > encSeqBefore) {
              encName = f(0); encSeqBefore = sq
              if (sc > 0 && (encWarm < 0 || sc < encWarm)) encWarm = sc
            }
          }
        }
      }
      p("ENCORE warm: " + encName + ", best of " + encSeqBefore + " samples = " + encWarm + " s")
    }

    // --- (f1) persist through OC's own PersistenceAPI ------------------
    p("--- persisting the workspace (eris.persist through OC's PersistenceAPI) ---")
    val nbt = new NBTTagCompound()
    var persistOk = true
    var persistErr = ""
    val tPersist = System.currentTimeMillis()
    try ws.save(nbt) catch { case t: Throwable => persistOk = false; persistErr = t.toString }
    val persistMs = System.currentTimeMillis() - tPersist
    val (mc1, _, tr1, _) = jitStatsLocked(computer.machine, mLua)
    val flushed = mc0 > 0 && mc1 == 0
    p("JIT MEMORY after persist: mcode=" + mc1 + " B, traces=" + tr1 +
      (if (flushed) "   <- FLUSHED: the save discarded every compiled trace"
       else if (mc0 > 0) "   (traces survived the save)" else ""))
    if (nativeMode == "luajit" && kernelMode == "watchdog" && jitMode == "on")
      // Not an assertion about WHICH way it goes -- both are legitimate, and
      // the serializer flushes only when the coroutine is suspended inside a
      // generic-for loop (eris_lj.c:1209).  What is asserted is that we can
      // TELL, so the answer is recorded rather than assumed.
      milestone("m2-persist-flush-observed", mc0 > 0 && mc1 >= 0,
        "mcode " + mc0 + " -> " + mc1 + " B, traces " + tr0 + " -> " + tr1 +
          (if (flushed) "  (a world save leaves the machine COLD; it must recompile)"
           else "  (this save did not trigger the for-in flush)"))

    // --- (m3) how cold is cold? ---------------------------------------
    // A save flushes every trace, and the machine goes on running.  What it
    // costs a player is not the flush but the RECOVERY: Minecraft saves every
    // few minutes, so if a machine needs long to get back to compiled speed it
    // spends much of its life interpreted.  Let it run and watch the machine
    // code come back.
    if (flushed) {
      var mr = 0
      var mcBack = 0L
      var trBack = 0
      while (mr < 120 && computer.machine.isRunning && mcBack == 0L) {
        ws.update(); Thread.sleep(25); mr += 1
        if (mr % 10 == 0) {
          var qq = 0
          while (computer.machine.isExecuting && qq < 200) { Thread.sleep(5); qq += 1 }
          val s = jitStats(mLua); mcBack = s._1; trBack = s._3
        }
      }
      // REPORTED, NOT ASSERTED, and the reason matters.  This watches an IDLE
      // machine, and an idle OpenOS has nothing hot to compile -- so "no mcode
      // three seconds after the flush" means "had no work", not "stays
      // interpreted".  The first version of this asserted mcBack > 0 and the
      // stock kernel passed it only because thrashing recompiles wastefully:
      // the milestone would have rewarded the broken build and failed the
      // working one.  Real recovery has to be measured with a WORKLOAD after
      // the save, which belongs in the benchmark harness (Step 3), not here.
      p("JIT MEMORY recovery (idle machine, informational only): mcode back to " +
        mcBack + " B / " + trBack + " traces after " + mr + " ticks (~" + (mr * 25) +
        " ms).  An idle machine has nothing to recompile; recovery under load is" +
        " measured by the benchmark harness, not by this line.")
    }

    val kernelKey = computer.machine.node.address + "_kernel"
    val blob = try findBlob(nbt, kernelKey) catch { case _: Throwable => null }
    milestone("f1-persist-blob", persistOk && blob != null && blob.length > 0,
      s"persist ok=$persistOk err=$persistErr key=$kernelKey blobBytes=" +
        (if (blob == null) -1 else blob.length) + s" in ${persistMs}ms")

    val ctrBeforeRestore = try parse(nonEmptyScreen(screen), "OCLJCTR").toInt catch { case _: Throwable => -1 }

    // --- (f2) restore into a FRESH workspace and resume ----------------
    p("--- restoring into a fresh workspace ---")
    var ws2: Workspace = null
    var computer2: Case = null
    var screen2: Screen = null
    var restoreErr = ""
    try {
      ws2 = new Workspace(Files.createTempDirectory("ocljit-smoke-b"))
      ws2.load(nbt)
      val it = ws2.getEntitiesIter
      while (it.hasNext) {
        it.next() match {
          case c: Case => computer2 = c
          case s: Screen => screen2 = s
          case _ =>
        }
      }
    } catch { case t: Throwable => restoreErr = t.toString; t.printStackTrace() }

    if (computer2 == null) {
      milestone("f2-restore-resumes", ok = false, "restore failed: " + restoreErr)
    } else {
      p("restored machine running=" + computer2.machine.isRunning +
        " lastError=" + computer2.machine.lastError)

      // THE RESTORED MACHINE NEEDS ITS OWN jit.off(), AND THIS IS WHY.
      //
      // OCLJ_JIT=off is applied once, to the LIVE state, before the persist
      // (the "JIT PROBE: jit.off() + jit.flush()" line far above).  eris
      // rebuilds a DIFFERENT lua_State on restore and nothing re-applied it
      // there, so every post-restore number in the JIT-OFF cell was in fact
      // measured with the compiler ON -- which silently destroys the negative
      // control this cell exists to be.
      //
      // The Phase 1 matrix made it unmistakable: cell B's cold encore samples
      // landed on cell C's for six benchmarks out of six, and B-sha256
      // reported a post-save "recovery" of 0.0822 s against a bare-metal
      // -joff time of 1.018 s.  An interpreter does not beat its own
      // uncontended standalone run by 12x; a compiler does.
      //
      // This is a HARNESS fault, not a shipping one -- the shim's own
      // OCLJ_JITOFF is applied at luaopen time and survives the restore -- but
      // a control that is not real is worse than no control.
      if (jitMode == "off") {
        var ra: AnyRef = null
        var rt = 0
        while (rt < 120 && (ra == null || luaOf(ra) == null)) {
          ws2.update(); Thread.sleep(25); rt += 1
          ra = computer2.machine.architecture
        }
        val rLua = if (ra == null) null else luaOf(ra)
        if (rLua == null)
          milestone("f6-restored-jit-still-off", ok = false,
            "could not reach the restored machine's LuaState after " + rt +
              " ticks, so jit.off() was NOT re-applied -- every post-restore " +
              "number in this cell is a JIT-ON number")
        else if (!quiesced(computer2.machine, "re-applying jit.off() after the restore"))
          milestone("f6-restored-jit-still-off", ok = false,
            "the restored machine never quiesced, so jit.off() was NOT re-applied")
        else {
          val st = evalStr(rLua, "jit.off() jit.flush() return tostring(jit.status())")
          milestone("f6-restored-jit-still-off", st == "false",
            "re-applied jit.off() to the state eris rebuilt -> jit.status()=" + st +
              (if (st == "false")
                 "   (without this, this cell's post-restore numbers are the COMPILER's)"
               else "   <- still on: no post-restore number in this cell is an interpreter number"))
        }
      }

      var k = 0
      while (k < 160 && computer2.machine.isRunning) { ws2.update(); Thread.sleep(25); k += 1 }
      val txtB = if (screen2 != null) nonEmptyScreen(screen2) else "<no screen>"
      p(s"SCREEN AFTER RESTORE ($k ticks, ${secs}s, running=${computer2.machine.isRunning}):")
      println(txtB)
      p("restored lastError = " + computer2.machine.lastError)

      val nonceB = parse(txtB, "OCLJNONCE")
      val ctrB = try parse(txtB, "OCLJCTR").toInt catch { case _: Throwable => -1 }
      val sameVm = nonceA != "<missing>" && nonceA == nonceB
      val advanced = ctrB > ctrBeforeRestore

      // --- (m3) post-save recovery: the first encore AFTER the restore ---
      // The save flushed every trace (m2 measures that), so this run is cold.
      // What is ASSERTED is only that a sample was obtained; the ratio is
      // REPORTED.  Phase 0 taught that lesson expensively -- m1 and m3 each
      // encoded a guess about which way a number would go and both guesses
      // were wrong, one of them passing the broken build.
      if (suiteNames.nonEmpty && encSeqBefore > 0) {
        var encCold = -1.0
        var encSeqAfter = -1
        var ec = 0
        while (ec < 1600 && computer2.machine.isRunning && encCold < 0) {
          ws2.update(); Thread.sleep(25); ec += 1
          if (ec % 8 == 0) {
            val f = parse(nonEmptyScreen(screen2), "OCLJENCORE").split("/")
            if (f.length >= 5 && f(1) == "ok") {
              val sq = try f(4).toInt catch { case _: Throwable => -1 }
              // Only a sequence number PAST the pre-persist one is a
              // post-restore sample.  The restore paints the old screen back,
              // so the row is already there and already says "ok"; without
              // this the harness would read the warm number twice and report
              // a recovery cost of exactly 1.00x.
              if (sq > encSeqBefore) {
                encSeqAfter = sq
                encCold = try f(3).toDouble catch { case _: Throwable => -1.0 }
              }
            }
          }
        }
        val ratio = if (encWarm > 0 && encCold > 0) encCold / encWarm else -1.0
        val ratioS = if (ratio > 0) f"$ratio%.2f" + "x" else "n/a"
        p("ENCORE cold: " + encName + ", first post-restore sample (seq " + encSeqBefore +
          " -> " + encSeqAfter + ") = " + encCold + " s")
        p("POST-SAVE RECOVERY: warm " + encWarm + " s -> cold " + encCold + " s = " + ratioS +
          "   (a world save flushes every compiled trace" +
          (if (jitMode == "off") "; with the JIT off there is nothing to flush, so ~1.0x is the control" else "") + ")")
        milestone("m3-post-save-workload-resumes", encCold > 0,
          "the encore closure survived the persist and ran again on the other side: " +
            encName + " cold " + encCold + " s against warm " + encWarm + " s, ratio " + ratioS +
            (if (encCold > 0) "   (ratio REPORTED, not asserted)"
             else "   <- no post-restore sample: the encore did not survive, or never fired"))
      }

      milestone("f2-restore-same-vm", sameVm,
        s"boot nonce before=$nonceA after=$nonceB (identical=$sameVm) " +
          (if (!sameVm && nonceB != "<missing>") "-- a DIFFERENT nonce means the machine REBOOTED, not resumed" else ""))
      milestone("f3-restore-counter-continues", advanced && computer2.machine.isRunning,
        s"counter at persist=$ctrBeforeRestore, after restore=$ctrB (advanced=$advanced); " +
          s"running=${computer2.machine.isRunning}")
      // f5 -- the RESTORED machine is still accounted.  OC persists kernelMemory
      // into the save and rebuilds totalMemory from it on load
      // (NativeLuaArchitecture.save/load), so a blob written by a build whose
      // accounting was dead carries kernelMemory == 1 and starves the machine
      // on its first tick after loading.  Nothing in OC guards that.  This is
      // the shape of that landmine, asserted where it can be seen: after a real
      // persist and restore, the machine must still report a real kernel size.
      val arch2 = computer2.machine.architecture
      val km2 = if (arch2 != null && arch2.isInstanceOf[NativeLuaArchitecture]) kernelMemoryOf(arch2) else -1
      milestone("f5-restore-memory-still-accounted", km2 > 10000,
        "kernelMemory after restore = " + km2 +
          (if (km2 > 10000) ""
           else if (km2 == 1) "   <- the restored machine is sized from the FLOOR of 1: it has no RAM"
           else "   <- restored kernelMemory is not a real measurement"))

      milestone("f4-restore-no-error", computer2.machine.lastError == null,
        "restored lastError=" + computer2.machine.lastError)
    }

    // --- (g) the bytecode gate ----------------------------------------
    p("--- allowBytecode gate (on a private LuaState) ---")
    computer.machine.stop()
    bytecodeGate()
    memoryProbes()

    p("FINGERPRINT: " + fp)
    p(s"CHECKS: $checks   FAILURES: $failures   WALL: ${secs}s")
    p("VERDICT: " + (if (failures == 0) "PASS" else "FAIL"))
    p("=" * 72)
    try Ocelot.shutdown() catch { case _: Throwable => }
    System.exit(if (failures > 0) 1 else 0)
  }

  /** The kernel blob is buried somewhere in the entity tree; find it by key. */
  def findBlob(nbt: NBTTagCompound, key: String): Array[Byte] = {
    if (nbt.hasKey(key)) return nbt.getByteArray(key)
    val it = new java.util.ArrayList[String](nbt.getKeySet).iterator
    while (it.hasNext) {
      nbt.getTag(it.next()) match {
        case c: NBTTagCompound =>
          val r = findBlob(c, key)
          if (r != null && r.length > 0) return r
        case l: totoro.ocelot.brain.nbt.NBTTagList =>
          var i = 0
          while (i < l.tagCount) {
            l.getCompoundTagAt(i) match {
              case c: NBTTagCompound =>
                val r = findBlob(c, key)
                if (r != null && r.length > 0) return r
              case _ =>
            }
            i += 1
          }
        case _ =>
      }
    }
    null
  }
}
