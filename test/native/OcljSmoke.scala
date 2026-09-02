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
import java.nio.file.{Files, Path, Paths}

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

  /** Evaluate a text chunk in the live state and return its single result. */
  def evalStr(lua: LuaState, code: String): String = {
    val base = lua.getTop
    try {
      lua.load(new ByteArrayInputStream(code.getBytes(StandardCharsets.UTF_8)), "=smoke", "t")
      lua.call(0, 1)
      val r = if (lua.isNil(-1)) "<nil>" else lua.toString(-1)
      lua.setTop(base)
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
    if (!nativeMark.startsWith("luajit/"))
      die("the live state carries no _OCLJ_NATIVE marker: this is the STOCK PUC-Lua 5.2 " +
        "native, not the LuaJIT one. forceNativeLibPathFirst did not take effect.")
    if (hasJit == "NO-JIT-TABLE")
      die("no jit table in the live state: the shim did not open luaopen_jit.")
    if (erisShape == "NO-ERIS")
      die("no eris library in the live state: eris_lj.o did not link in, or luaopen_eris was not called.")
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
    """local component = require("component")
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
      |event.timer(0.05, function()
      |  n = n + 1
      |  component.gpu.set(1, 15, "OCLJNONCE=" .. nonce .. " OCLJCTR=" .. n .. "        ")
      |  -- repainted every tick for the same reason as the counter: boot output
      |  -- would otherwise scroll a one-shot line off the screen.
      |  component.gpu.set(1, 16, gate .. "        ")
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
    val hdd = new HDDManaged(Tier.One)
    hdd.customRealPath = Some(diskDir)
    computer.inventory(3) = hdd
    p("hdd real path = " + diskDir + " (autorun.lua planted, " + AutorunLua.length + " bytes)")

    computer.inventory(4) = Loot.LuaBiosEEPROM.create()
    computer.inventory(5) = Loot.OpenOsFloppy.create()
    val screen = ws.add(new Screen(Tier.One))
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
    var q = 0
    while (computer.machine.isExecuting && q < 600) { Thread.sleep(10); q += 1 }
    p("quiesced after " + q + " spins (isExecuting=" + computer.machine.isExecuting + ")")
    val fp = guard(computer.machine)

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

    // --- (f1) persist through OC's own PersistenceAPI ------------------
    p("--- persisting the workspace (eris.persist through OC's PersistenceAPI) ---")
    val nbt = new NBTTagCompound()
    var persistOk = true
    var persistErr = ""
    val tPersist = System.currentTimeMillis()
    try ws.save(nbt) catch { case t: Throwable => persistOk = false; persistErr = t.toString }
    val persistMs = System.currentTimeMillis() - tPersist
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

      milestone("f2-restore-same-vm", sameVm,
        s"boot nonce before=$nonceA after=$nonceB (identical=$sameVm) " +
          (if (!sameVm && nonceB != "<missing>") "-- a DIFFERENT nonce means the machine REBOOTED, not resumed" else ""))
      milestone("f3-restore-counter-continues", advanced && computer2.machine.isRunning,
        s"counter at persist=$ctrBeforeRestore, after restore=$ctrB (advanced=$advanced); " +
          s"running=${computer2.machine.isRunning}")
      milestone("f4-restore-no-error", computer2.machine.lastError == null,
        "restored lastError=" + computer2.machine.lastError)
    }

    // --- (g) the bytecode gate ----------------------------------------
    p("--- allowBytecode gate (on a private LuaState) ---")
    computer.machine.stop()
    bytecodeGate()

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
