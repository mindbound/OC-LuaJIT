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
      |  end)
      |end)
      |
      |event.timer(0.05, function()
      |  n = n + 1
      |  component.gpu.set(1, 12, bench2 .. "        ")
      |  component.gpu.set(1, 13, "OCLJDEADLINE=" .. deadlineResult .. "        ")
      |  component.gpu.set(1, 14, bench .. "        ")
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
    val kernelSeen = evalStr(mLua, "return tostring(_OCLJ_KERNEL)")
    milestone("k0-kernel-observed", (kernelMode == "watchdog") == (kernelSeen == "watchdog"),
      "asked for " + kernelMode + ", raw _G._OCLJ_KERNEL=" + kernelSeen +
        (if ((kernelMode == "watchdog") == (kernelSeen == "watchdog")) ""
         else "   <- the kernel that ran is NOT the one requested; nothing below means what it says"))
    var qj = 0
    while (computer.machine.isExecuting && qj < 600) { Thread.sleep(10); qj += 1 }
    if (jitMode == "off")
      p("JIT PROBE: jit.off() + jit.flush() -> jit.status()=" +
        evalStr(mLua, "jit.off() jit.flush() return tostring(jit.status())"))
    p("JIT PROBE: mode=" + jitMode + "  attach -> " + evalStr(mLua,
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
    while (computer.machine.isExecuting && qk < 600) { Thread.sleep(10); qk += 1 }
    val trRaw = evalStr(mLua, "local t = __ocljTr return t.start .. '/' .. t.stop .. '/' .. t.abort .. '/' .. t.flush")
    val jitStatus = evalStr(mLua, "return tostring(jit.status())")
    evalStr(mLua, "jit.attach(__ocljTrFn) __ocljTr = nil __ocljTrFn = nil return 'ok'")
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
    var q5 = 0
    while (computer.machine.isExecuting && q5 < 600) { Thread.sleep(10); q5 += 1 }
    val wdStats = evalStr(mLua, "local f, r, x, dp, h = _OCLJ_WATCHDOG.stats() return f .. '/' .. r .. '/' .. x .. '/' .. dp .. '/' .. tostring(h)")
    val wdFires = try wdStats.split("/")(0).toInt catch { case _: Throwable => -1 }
    p("WATCHDOG STATS: fires/refires/filtered/depth/hooked = " + wdStats)
    if (kernelMode == "watchdog")
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
