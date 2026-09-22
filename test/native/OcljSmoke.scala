package ocljit.smoke

import li.cil.repack.com.naef.jnlua.LuaState
import totoro.ocelot.brain.Ocelot
import totoro.ocelot.brain.entity.machine.luac.{LuaStateFactory, NativeLua52Architecture, NativeLuaArchitecture}
import ocljit.arch.OCLuaJITArchitecture
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
 * the architecture ocljit.native implies -- NativeLua52Architecture for the
 * dropin and stock arms, OCLuaJITArchitecture for the additive one -- and it
 * prints a fingerprint read out of the running
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

  /** mcode bytes / cap / traces-used / jit-on / traces-live, read off the raw
    * state.  The RAM cap cannot see machine code (it is VirtualAlloc'd, never
    * through g->allocf), so this is the only number that says what a machine
    * actually costs.  It is also the trace-flush signature: lj_trace_flushall
    * zeroes szallmcarea, so a drop to 0 across a persist proves the serializer
    * threw away every compiled trace in the VM.  traces-used is J->freetrace-1
    * and FREEZES when every recording aborts (it sat at 468 through the
    * 2026-09-22 penalty-cache regression); traces-live counts the traces that
    * exist right now and is the one that says whether compiled code is present. */
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

  // ------------------------------------------------------------------ //
  // (jn-1) the jnlua resume-error patch, exercised through jnlua itself
  // ------------------------------------------------------------------ //

  /**
   * THE ONE LINE WE PATCH IN jnlua.c HAS TO BE SHOWN TO WORK.  Until this
   * milestone its only observation was the old-11-site-kernel mirror probe,
   * where the escaping object was OC's tooLongWithoutYielding sentinel TABLE
   * with the count=1 hook still armed: throw_protected's luaL_tolstring ran
   * the sentinel's __tostring under that hook, the hook raised, and jnlua's
   * throw() fell back to java.lang.Error -- the machine showed
   * Error.InternalError and the patched line was never seen doing its job.
   * Under the shipped 12-site kernel that path is unreachable (no hook
   * reaches the kernel thread, the sentinel never escapes pcall(main)).
   *
   * This drives LuaState.resume -- jnlua's lua_1resume, the JNI method the
   * patch lives in -- on the harness's RAW main state, under the machine's
   * monitor (evalStrLocked's reasoning), on a fresh coroutine that dies with
   * (a) a plain string and (b) a table whose __tostring returns a string.
   * PATCHED (native/jnlua/patch-resume-error.sh): lua_1resume xmoves T's
   * error object onto L before throw(), so the LuaRuntimeException message
   * is that object rendered and contains the expected text.  UNPATCHED (any
   * native built before 2026-09-22): throw() renders the top of L, which is
   * the coroutine object itself, and the message is "thread: 0x...".  PASS
   * iff both (a) and (b) carry their text; no hook is armed for either.
   *
   * (c) is RECORDED, NOT ASSERTED: a table whose __tostring itself raises.
   * throw_protected runs under lua_pcall (jnlua.c throw(), :2353); when the
   * metamethod raises inside it the pcall fails and throw() falls back to
   * ThrowNew(error_class, lua_tostring(L, -1) or "error throwing Lua
   * exception") -- a java.lang.Error carrying the raise's message when it is
   * a string, and jnlua's literal fallback text when it is not.  That is
   * jnlua's own shape for ANY error object whose __tostring raises, patched
   * or not, and it is what a machine shows as Error.InternalError.  Two
   * variants are recorded so both halves of that sentence are quoted from
   * the native rather than read off the source: a __tostring raising a
   * string, and one raising a table.
   */
  def jnluaResumeErrorProbe(machine: totoro.ocelot.brain.entity.machine.Machine,
                            lua: LuaState): Unit = {
    val id = "jn-1-resume-error-carries-message"
    p("--- (jn-1) LuaState.resume on a coroutine that dies: does the LuaRuntimeException carry the error object? ---")
    // One coroutine per case: load the body (a function), wrap it in a new
    // thread, resume it THROUGH JNLUA, and report what Java caught.  The
    // stack is restored to its base whether or not the resume threw; the base
    // is expected to be 1 (the kernel thread), as every raw-state read is.
    def one(label: String, body: String): String = machine.synchronized {
      var base = -1
      try {
        base = lua.getTop
        if (base != 1)
          p("!! jn-1 " + label + ": raw-state probe on a dirty stack: getTop=" + base +
            " (expected 1) -- something else is using this state")
        lua.load(new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8)), "=jn1-" + label, "t")
        lua.newThread()
        val n = lua.resume(lua.getTop, 0)
        "<no exception: resume returned " + n + " value(s); thread status=" + lua.status(base + 1) + ">"
      } catch {
        case t: Throwable => t.getClass.getName + ": " + t.getMessage
      } finally {
        if (base >= 0) try lua.setTop(base) catch { case _: Throwable => }
      }
    }
    // What hook, if any, would a __tostring run under.  Diagnostic: the claim
    // "no hook armed" is read from the state, not assumed.  LuaJIT keeps the
    // hook in global_State, so the main state's answer covers the new threads.
    val hook = machine.synchronized { evalStr(lua,
      "if debug == nil then return 'debug-absent' end " +
      "local h, m, c = debug.gethook() return tostring(h ~= nil) .. '/' .. tostring(m) .. '/' .. tostring(c)") }
    val a  = one("a",  "error('jn1-string-error', 0)")
    val b  = one("b",  "error(setmetatable({}, { __tostring = function() return 'jn1-tostring-error' end }))")
    val c1 = one("c1", "error(setmetatable({}, { __tostring = function() error('jn1-tostring-raises', 0) end }))")
    val c2 = one("c2", "error(setmetatable({}, { __tostring = function() error({}) end }))")
    val topAfter = machine.synchronized { try lua.getTop catch { case _: Throwable => -1 } }
    val okA = a.contains("jn1-string-error")
    val okB = b.contains("jn1-tostring-error")
    val threadShape = a.contains("thread: 0x") || b.contains("thread: 0x")
    p("JNLUA RESUME: hook(set/mask/count)=" + hook + "  stack top after the four resumes=" + topAfter)
    p("JNLUA RESUME (a) error('jn1-string-error')                      -> " + a)
    p("JNLUA RESUME (b) error(table with __tostring -> 'jn1-tostring-error') -> " + b)
    p("JNLUA RESUME (c) RECORDED, not asserted: __tostring raises a string -> " + c1)
    p("JNLUA RESUME (c) RECORDED, not asserted: __tostring raises a table  -> " + c2)
    milestone(id, okA && okB,
      "(a) " + a + ";  (b) " + b +
        (if (okA && okB) "   (jnlua reports the coroutine's error object; hook=" + hook + ")"
         else if (threadShape) "   <- jnlua rendered the COROUTINE OBJECT, not its error: the resume-error patch " +
                                "(native/jnlua/patch-resume-error.sh) is not in this native"
         else "   <- neither message carries its text; hook=" + hook))
  }

  // ------------------------------------------------------------------ //
  // (mem-1) what the compiled traces cost the RAM cap, per tier
  // ------------------------------------------------------------------ //

  /**
   * One resident-memory read: what the sandbox sees, what the allocator
   * really charged, and how many traces are alive to be charged for.
   *
   * WHY IT EXISTS.  Trace metadata -- the GCtrace, its IR, its snapshots --
   * is allocated through g->allocf, so it is charged against the machine's
   * RAM cap (machine code is not: VirtualAlloc'd, see jitStats).  Up to
   * 2026-09-22 the serializer flushed every trace on every save, which gave
   * that charge back each time a world saved; since then a save leaves the
   * traces resident, and only LuaJIT's own self-flush takes them back: a
   * full trace table (maxtrace, default 1000 -- lj_trace.c trace_findfree
   * returns 0 and lj_trace_start calls lj_trace_flushall) or a full mcode
   * reservation (maxmcode, default 2048 KB -- lj_mcode.c lj_mcode_limiterr
   * raises LJ_TRERR_MCODEAL and trace_abort flushes).  On a 256 KB tier that
   * residency is a real fraction of the machine.  This is the instrument
   * that measures it; nothing here asserts a threshold, because the player
   * picks both the tier and the workload.
   *
   * THREE READINGS PER POINT, in three units, and the units are the point:
   *   sandbox   computer.totalMemory()/freeMemory() as the autorun paints
   *             them on row 20 (OCLJENV=total/free, KB) every 50 ms -- the
   *             number a program inside the machine acts on.  Sampled over
   *             ~1 s of ticks and reported as min..max free, because the
   *             incremental collector makes one reading a random point
   *             between the live set and the pause threshold.  It is real
   *             bytes / ramScale with kernelMemory taken out
   *             (NativeLuaArchitecture:158-166), so it hides the scale factor
   *             the player never sees either.
   *   raw       lua.getTotalMemory / getFreeMemory off the LuaState, real
   *             bytes, under the machine's monitor (b2 reads the same pair).
   *   traces    _OCLJ_JITSTATS: traces_live is what is actually resident;
   *             `traces` is J->freetrace-1 and only grows.  -1 for
   *             traces_live is a shim older than 2026-09-22 (four values):
   *             reported as n/a, not counted as a failed read, because the
   *             pre-bump native is one of the two arms this compares.
   *
   * THEN ONE PERTURBING READ, labelled as such and LAST: collectgarbage
   * ("collect") on the raw state, then the raw free and the trace count
   * again.  Without it the "resident" figure is unreadable -- garbage that
   * the collector has not reached yet is indistinguishable from trace
   * metadata in every number above.  It is a full GC on a quiescent machine
   * under the executor's monitor, the same thing machine.lua does at boot
   * and the emergency collector does under pressure; nothing above it is
   * measured after it.  A trace whose start prototype is otherwise dead is
   * garbage to this GC too (lj_gc.c gc_traverse_proto marks pt->trace, and
   * nothing else does), so traces_live may DROP across it: that drop is the
   * part of the residency a GC can reclaim without a flush, and it is
   * printed rather than folded in.
   *
   * Returns true iff every non-perturbing read produced a number.  One that
   * did not is announced on its own line so the milestone can SKIP instead
   * of passing on a number nobody saw.
   */
  def residentTracesRead(ws: Workspace, machine: totoro.ocelot.brain.entity.machine.Machine,
                         screen: Screen, lua: LuaState, tierName: String, point: String,
                         ticks: Int = 40): Boolean = {
    // sandbox: `ticks` ticks (~25 ms each) of the autorun's own row, min..max free
    var envTot = -1L; var envMin = Long.MaxValue; var envMax = -1L; var envReads = 0
    var t = 0
    while (t < ticks && machine.isRunning) {
      ws.update(); Thread.sleep(25); t += 1
      if (t % 4 == 0) {
        val e = parse(nonEmptyScreen(screen), "OCLJENV").split("/")
        if (e.length == 2) {
          try {
            val tot = e(0).toLong; val fr = e(1).toLong
            envTot = tot; envReads += 1
            if (fr < envMin) envMin = fr
            if (fr > envMax) envMax = fr
          } catch { case _: Throwable => }
        }
      }
    }
    val benchRow = parse(nonEmptyScreen(screen), "OCLJB01")
    val sandboxOk = envReads > 0 && envTot > 0
    // raw bytes and the trace count, under the executor's monitor.  quiesced()
    // is the DIAGNOSTIC it is at the k5 read, not the gate: it reports whether
    // the machine looked idle, and with the encore timer running it says
    // "no" one read in three (a resume can be scheduled between its last
    // poll and its answer -- the evalStrLocked reasoning).  The monitor is
    // what makes the read safe; Machine.run holds it for the whole resume.
    val q = quiesced(machine, "the mem-1 " + point + " read (diagnostic; the read proceeds under the monitor)")
    var rawTot = -1L; var rawFree = -1L
    machine.synchronized {
      rawTot = try lua.getTotalMemory.toLong catch { case _: Throwable => -1L }
      rawFree = try lua.getFreeMemory.toLong catch { case _: Throwable => -1L }
    }
    val s = jitStatsLocked(machine, lua)
    val mc = s._1; val tr = s._3; val lv = s._5
    val rawOk = rawTot > 0 && rawFree >= 0 && mc >= 0
    def kb(b: Long) = if (b < 0) "n/a" else (b / 1024).toString
    p("MEM-1 " + point + ": tier=" + tierName +
      "  sandbox total/free KB=" + (if (sandboxOk) s"$envTot/$envMin..$envMax" else "<no OCLJENV row in " + t + " ticks>") +
      " (" + envReads + " samples; phase0=" + (if (benchRow == "<missing>") "<missing>" else benchRow.split("/").take(2).mkString("/")) + ")" +
      "  raw total/free KB=" + (if (rawOk) kb(rawTot) + "/" + kb(rawFree) + " (used " + kb(rawTot - rawFree) + ")" else "<not read>") +
      "  traces_live=" + (if (!rawOk) "<not read>" else if (lv < 0) "n/a(4-value JITSTATS)" else lv.toString) +
      " traces=" + (if (rawOk) tr.toString else "<not read>") + " mcode=" + kb(mc) + " KB" +
      (if (!sandboxOk) "   <- the sandbox row did not parse" else "") +
      (if (!rawOk) "   <- the raw read produced no number" else "") +
      "  quiesced=" + q + " running=" + machine.isRunning)
    // the perturbing read, last
    if (rawOk) {
      val gcCount = evalStrLocked(machine, lua,
        "collectgarbage('collect') return string.format('%d', math.floor(collectgarbage('count') * 1024))")
      var gcFree = -1L
      machine.synchronized { gcFree = try lua.getFreeMemory.toLong catch { case _: Throwable => -1L } }
      val s2 = jitStatsLocked(machine, lua)
      p("MEM-1 " + point + " after a full GC (PERTURBING, on the raw state): raw free KB=" + kb(gcFree) +
        " (used " + kb(rawTot - gcFree) + "; collectgarbage('count')=" + gcCount + " B)" +
        "  traces_live=" + (if (s2._5 < 0) "n/a" else s2._5.toString) + " traces=" + s2._3 + " mcode=" + kb(s2._1) + " KB" +
        "   <- garbage reclaimed " + kb(gcFree - rawFree) + " KB; traces_live " + lv + " -> " + s2._5)
    }
    sandboxOk && rawOk
  }

  /** jitStats under the executor's monitor -- same reasoning as evalStrLocked. */
  def jitStatsLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                     lua: LuaState): (Long, Long, Int, Boolean, Int) =
    machine.synchronized { jitStats(lua) }

  /** _OCLJ_GCSTATS -> arms, collects, bailouts, refusals, armed, state.
    *
    * THE EMERGENCY COLLECTOR'S ACCEPTANCE TEST IS UNREADABLE WITHOUT THIS.
    * A `sieve` that passes with arms == 0 proves nothing about the collector:
    * it would mean the run never approached the watermark and the trip-wire was
    * never exercised.  That is the same class of false green as the peak column
    * measured by its own instrument (references.txt), and it is why the
    * milestones below assert arms >= 1 as well as the benchmark row.
    *
    * bailouts is the sharpest of the four.  Nonzero means the currentwhite
    * latch is not seeing flips it should, so the disarm predicate -- the whole
    * safety argument for handing the collector an unbounded budget -- is
    * wrong.  It is a bug signal, never a tuning signal. */
  def gcStatsLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                    lua: LuaState): (Long, Long, Long, Long, Boolean, Int) =
    machine.synchronized { gcStats(lua) }

  def gcStats(lua: LuaState): (Long, Long, Long, Long, Boolean, Int) = {
    val s = evalStr(lua,
      "if _OCLJ_GCSTATS == nil then return 'absent' end " +
      "local a, c, b, r, on, tot, thr, mul, st = _OCLJ_GCSTATS() " +
      "return string.format('%d/%d/%d/%d/%s/%d', a, c, b, r, tostring(on), st)")
    try {
      val q = s.split("/")
      (q(0).toDouble.toLong, q(1).toDouble.toLong, q(2).toDouble.toLong,
       q(3).toDouble.toLong, q(4) == "true", q(5).toInt)
    } catch { case _: Throwable => (-1L, -1L, -1L, -1L, false, -1) }
  }

  def jitStats(lua: LuaState): (Long, Long, Int, Boolean, Int) = {
    // `lv or -1`: a native older than 2026-09-22 returns four values, and the
    // first four must stay readable against it rather than all five failing.
    val s = evalStr(lua, "local m, c, t, on, lv = _OCLJ_JITSTATS() " +
      "return string.format('%d/%d/%d/%s/%d', m, c, t, tostring(on), lv or -1)")
    try {
      val p = s.split("/")
      (p(0).toDouble.toLong, p(1).toDouble.toLong, p(2).toInt, p(3) == "true", p(4).toInt)
    } catch { case _: Throwable => (-1L, -1L, -1, false, -1) }
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

  // ------------------------------------------------------------------ //
  // The sync-call save (stk-*): reads that need the TWO-value stack shape
  // ------------------------------------------------------------------ //

  /**
   * A raw-state read for the sync-call shape.  While the machine is in
   * SynchronizedCall the main stack holds the kernel thread at 1 and the
   * pending invoke closure at 2 (NativeLuaArchitecture.runSynchronized asserts
   * exactly that), and the chunk gets both as its arguments.  Under the
   * machine's monitor for the same reason as evalStrLocked, and it REFUSES
   * rather than guesses when the stack is not in that shape: a read on the
   * wrong shape is the class of fault the locked readers exist to prevent.
   */
  def evalSyncLocked(machine: totoro.ocelot.brain.entity.machine.Machine,
                     lua: LuaState, code: String): String =
    machine.synchronized {
      var base = -1
      try {
        base = lua.getTop
        if (base != 2 || !lua.isThread(1)) "<shape: top=" + base + ">"
        else {
          lua.load(new ByteArrayInputStream(code.getBytes(StandardCharsets.UTF_8)), "=stkprobe", "t")
          lua.pushValue(1)
          lua.pushValue(2)
          lua.call(2, 1)
          val r = if (lua.isNil(-1)) "<nil>" else lua.toString(-1)
          lua.setTop(base)
          r
        }
      } catch {
        case t: Throwable =>
          if (base >= 0) try lua.setTop(base) catch { case _: Throwable => }
          "<error: " + t.getMessage + ">"
      }
    }

  /**
   * Machine.state's top, by reflection.  The field is private[machine]: public
   * in bytecode (javap: `public Stack<Enumeration$Value> state()`), invisible
   * to scalac from this package -- the same reach luaOf makes for `lua`.  Read
   * under the stack's own monitor, the one Machine.update/run/save take
   * (state.synchronized).
   */
  def stateTop(machine: totoro.ocelot.brain.entity.machine.Machine): String = {
    val st = classOf[totoro.ocelot.brain.entity.machine.Machine].getMethod("state").invoke(machine)
      .asInstanceOf[scala.collection.mutable.Stack[AnyRef]]
    st.synchronized { if (st.isEmpty) "<empty>" else st.top.toString }
  }

  /** id -> name for every state on the live stack.  MachineAPI.State is
    * private[machine] too, so the saved IntArray is translated through the
    * values the live stack holds at the same moment (the save copies them). */
  def stateNames(machine: totoro.ocelot.brain.entity.machine.Machine): Map[Int, String] = {
    val st = classOf[totoro.ocelot.brain.entity.machine.Machine].getMethod("state").invoke(machine)
      .asInstanceOf[scala.collection.mutable.Stack[AnyRef]]
    st.synchronized { st.toSeq.map(v => v.asInstanceOf[Enumeration#Value].id -> v.toString).toMap }
  }

  /** What the closure at stack index 2 is about to call, from its `args`
    * upvalue (machine.lua:1097): "open(manifest.lua)". */
  val PendingProbeLua: String =
    """local co, fn = ...
      |if type(fn) ~= "function" then return "not-a-function:" .. type(fn) end
      |for i = 1, 60 do
      |  local n, v = debug.getupvalue(fn, i)
      |  if n == nil then break end
      |  if n == "args" and type(v) == "table" then return tostring(v[2]) .. "(" .. tostring(v[3]) .. ")" end
      |end
      |return "no-args-upvalue"
      |""".stripMargin

  /**
   * The registries.  The kernel's is the chunk-local `wrappedUserdata`
   * (machine.lua:1091), found by walking the kernel thread's frames -- the
   * chunk frame stays live for the machine's life (:1571).  The closure's is
   * reached the way the closure itself reaches it: its `unwrapUserdata`
   * upvalue, then that function's `wrappedUserdata` upvalue.  `same` says
   * whether the two are one table; `values` counts DISTINCT host userdata
   * across both, i.e. how many host Values exist for the proxies.  Two full
   * collects first: a weak-keyed registry counts uncollected garbage
   * otherwise, and one cycle is not a full sweep on LuaJIT.
   */
  val RegistryProbeLua: String =
    """local co, fn = ...
      |local function frame_local(th, name)
      |  for level = 0, 100 do
      |    if not debug.getinfo(th, level, "S") then return nil end
      |    local i = 1
      |    while true do
      |      local n, v = debug.getlocal(th, level, i)
      |      if n == nil then break end
      |      if n == name then return v end
      |      i = i + 1
      |    end
      |  end
      |end
      |local function upvalue(f, name)
      |  if type(f) ~= "function" then return nil end
      |  for i = 1, 60 do
      |    local n, v = debug.getupvalue(f, i)
      |    if n == nil then return nil end
      |    if n == name then return v end
      |  end
      |end
      |local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
      |collectgarbage("collect") collectgarbage("collect")
      |local kreg = frame_local(co, "wrappedUserdata")
      |if type(kreg) ~= "table" then return "kreg=noreg creg=nil same=false values=-1 pending=nil" end
      |local uw = upvalue(fn, "unwrapUserdata")
      |local creg = upvalue(uw, "wrappedUserdata")
      |local args = upvalue(fn, "args")
      |local seen, nvals = {}, 0
      |for _, v in pairs(kreg) do if not seen[v] then seen[v] = true nvals = nvals + 1 end end
      |if type(creg) == "table" then
      |  for _, v in pairs(creg) do if not seen[v] then seen[v] = true nvals = nvals + 1 end end
      |end
      |return string.format("kreg=%d creg=%s same=%s values=%d pending=%s", count(kreg),
      |  type(creg) == "table" and tostring(count(creg)) or "nil", tostring(rawequal(kreg, creg)), nvals,
      |  type(args) == "table" and (tostring(args[2]) .. "(" .. tostring(args[3]) .. ")") or "nil")
      |""".stripMargin

  def stkField(row: String, i: Int): Int = {
    val f = row.split("/")
    if (f.length > i) try f(i).trim.toInt catch { case _: Throwable => -1 } else -1
  }

  /**
   * How many userdata recipes a blob carries.  machine.lua's proxy recipe
   * (:1156-1164) closes over what userdata.save returned: the class name and
   * the Value's NBT, written UNCOMPRESSED (UserdataAPI.scala:23,
   * CompressedStreamTools.write -> writeTag).  Each recipe calls userdata.load
   * exactly once when the reader fills it, so recipes across every blob a save
   * wrote = host Values the restore mints.  That is what the restored
   * registries cannot show: on LuaJIT a table has no __gc, so a second
   * universe's copies vanish at the load's own full collect and leave nothing
   * to count.
   *
   * THE NEEDLE IS THE NBT, NOT THE CLASS NAME.  eris-lj keys every collectable
   * object in its reference table, strings included (eris_lj.c:1538,
   * persist_keyed: "refkey == obj for every M1 type"), so the one interned
   * class-name string is written once per blob and referenced after -- the
   * first version of this counted it and read 1 for 7 proxies.  A
   * HandleValue's NBT differs per handle id, so it is a distinct string per
   * proxy, written by value once per blob each; its `handle` int tag is
   * encoded as TAG_Int(3), name length 0x0006, "handle" -- control bytes no
   * Lua source or screen text contains.
   */
  val RecipeNeedle: String = new String(Array[Byte](3, 0, 6), StandardCharsets.ISO_8859_1) + "handle"

  def countOccurrences(blob: Array[Byte], needle: String): Int = {
    if (blob == null) return 0
    val hay = new String(blob, StandardCharsets.ISO_8859_1)
    var n = 0
    var i = hay.indexOf(needle)
    while (i >= 0) { n += 1; i = hay.indexOf(needle, i + needle.length) }
    n
  }

  /** The compound that holds `key`, found the way findBlob finds the blob. */
  def findCompoundWith(nbt: NBTTagCompound, key: String): NBTTagCompound = {
    if (nbt.hasKey(key)) return nbt
    val it = new java.util.ArrayList[String](nbt.getKeySet).iterator
    while (it.hasNext) {
      nbt.getTag(it.next()) match {
        case c: NBTTagCompound =>
          val r = findCompoundWith(c, key)
          if (r != null) return r
        case l: totoro.ocelot.brain.nbt.NBTTagList =>
          var i = 0
          while (i < l.tagCount) {
            l.getCompoundTagAt(i) match {
              case c: NBTTagCompound =>
                val r = findCompoundWith(c, key)
                if (r != null) return r
              case _ =>
            }
            i += 1
          }
        case _ =>
      }
    }
    null
  }

  /**
   * THE SYNC-CALL SAVE (stk-*).
   *
   * f1/f7 save at a moment the harness chooses, and that moment is never
   * inside a SynchronizedCall, so they never exercise OC's SECOND root: while
   * the state stack holds SynchronizedCall / SynchronizedReturn,
   * NativeLuaArchitecture.save persists stack index 2 -- the closure
   * machine.lua's invoke yielded (:1097-1104) -- in a SEPARATE eris.persist
   * call with its own reference space, as "_stack".  That closure holds four
   * OPEN upvalues into the kernel coroutine's stack (args, target,
   * unwrapUserdata, wrapUserdata).  Persisted on its own under our serializer,
   * an open upvalue whose owner is not in the reference table is chased to its
   * thread (eris_lj.c:543) and the WHOLE kernel is written into "_stack": a
   * second kernel universe, a second registry, a second host Value per proxy,
   * and a sync result the real kernel's registry has never seen.
   * serializer/tests/stack-universe.lua measures it on a kernel mirror (U1);
   * this is the same measurement on the real machine, and it is the gate for
   * the Architecture's fix (persist {thread, closure} as ONE root).
   *
   * How the save lands mid-call: the sandbox half (see OCLJSTK in AutorunLua)
   * bursts fs.open past its per-tick limit, and Machine.update() is what
   * performs a pending sync call -- so a machine observed in SynchronizedCall
   * between two update() calls STAYS there until the next one.  The harness
   * polls for that state, confirms the pending closure is an fs.open (its
   * result is a HandleValue, a host Value), and saves before updating again.
   *
   * Four milestones, each with its anti-vacuity gate:
   *   stk-1  the persisted state stack SAYS SynchronizedCall, and the pending
   *          closure was an fs.open.  Gate for all of the below; also OC's
   *          failure protocol removes the "state" tag when a persist throws,
   *          so a failed persist cannot pass.
   *   stk-2  "_stack" is small against "_kernel" (absent counts as 0).  Gate:
   *          stk-1 and a real kernel blob; a save that dropped the closure
   *          altogether fails stk-3/4, so "absent" cannot pass on its own.
   *   stk-3  the userdata recipes across every blob the save wrote (one
   *          userdata.load each on restore; see countOccurrences) equal the
   *          proxies persisted, and, read after the restore BEFORE the first
   *          update() (the closure is still at index 2), the closure's
   *          registry IS the kernel's.  Gate: at least two proxies persisted
   *          (udh and stkHeld), and the restored closure still names fs.open.
   *          The registries alone cannot carry the count: LuaJIT never
   *          finalises a table, so a second universe's copies are gone at the
   *          load's own full collect (measured: closure's registry = 0
   *          entries, same table = false), which is why the blobs are counted.
   *   stk-4  the restored machine runs the closure; the burst that spanned
   *          the save reads and closes the handle it returned; no failure is
   *          added.  Gate: the OCLJSTK sequence number advanced past the
   *          pre-save row (the restore paints the old screen back, so a dead
   *          machine shows exactly the old number).
   * THE EXPECTATION IS KEYED ON THE ARM, because only one arm can pass the
   * bundle shape at all.  The Architecture override lives in
   * OCLuaJITArchitecture, and that class drives the machine ONLY in the
   * additive arm; the dropin arm (OCLJ_NATIVE=luajit, the default) runs
   * OpenComputers' own NativeLua52Architecture over our native, so its save is
   * OC's two-call save, forever -- there is nothing there to fix.  A bundle
   * assertion in that arm would fail on every run for the rest of the
   * project's life, and a gate that always fails is read once and ignored.
   * So each arm asserts what IT must show, two-sided, so a baseline that
   * silently ran on the fix, or a fix that silently did nothing, both fail:
   *   additive  "bundle": no second blob, one recipe per proxy, one registry,
   *             no failure added -- the shipped shape.
   *   luajit    "dropin": OC's two-call save over OUR serializer -- the
   *             second blob carries the kernel, two recipes per proxy, a
   *             second registry, the silent mode.  stack-universe.lua U1 on a
   *             real machine, kept as the documented-defect control.
   *   stock     "stock": OC's own Eris.  The second blob is small (upvalues
   *             by value), and it carries NO recipes, because stock
   *             machine.lua:1061-1066 persists the registry as an EMPTY table
   *             by design -- so no second Value per proxy, but a second
   *             (empty) registry and the same silent mode.  Measured, not
   *             taken from the U4 mirror, whose closure holds a proxy in args.
   */
  def syncCallSave(ws: Workspace, computer: Case, screen: Screen, expect: String): Unit = {
    val m = computer.machine
    val bundle = expect == "bundle"
    p("--- (stk) saving WHILE the machine is in SynchronizedCall (expecting " +
      (expect match {
        case "bundle" => "ONE reference space: the roots bundled"
        case "dropin" => "OC's two-call save over our serializer: the second universe, U1's shape"
        case _ => "stock Eris's two-call save: by-value upvalues, an empty second registry, the silent mode"
      }) + ") ---")
    val arch = m.architecture
    val lua = if (arch == null) null else luaOf(arch)
    if (lua == null || !m.isRunning) {
      milestone("stk-1-save-landed-in-synccall", ok = false,
        "no running machine to save: running=" + m.isRunning + " lastError=" + m.lastError)
      return
    }
    // The signal starts the burst chain (sandbox half).
    val queued = m.signal("ocljstk")
    // Poll for the shape.  ws.update() PERFORMS a pending sync call
    // (Machine.update, case SynchronizedCall), so the check comes after the
    // sleep and the save comes before the next update.
    var caught = false
    var polls = 0
    var seenSync = 0
    var pending = "-"
    val tPoll = System.currentTimeMillis()
    while (!caught && polls < 3000 && m.isRunning) {
      ws.update(); Thread.sleep(10); polls += 1
      if (stateTop(m) == "SynchronizedCall") {
        seenSync += 1
        pending = evalSyncLocked(m, lua, PendingProbeLua)
        if (pending.startsWith("open(")) caught = true
      }
    }
    p("stk: signal queued=" + queued + "; " + polls + " polls in " + (System.currentTimeMillis() - tPoll) +
      " ms, SynchronizedCall seen " + seenSync + " times, last pending call = " + pending +
      (if (caught) "   <- caught on an fs.open" else "   <- NOT caught"))
    if (!caught) {
      milestone("stk-1-save-landed-in-synccall", ok = false,
        "never observed the machine in SynchronizedCall on an fs.open after " + polls + " polls (" +
          seenSync + " sync-call sightings, last=" + pending + "); running=" + m.isRunning +
          " lastError=" + m.lastError + " OCLJSTK=" + parse(nonEmptyScreen(screen), "OCLJSTK"))
      return
    }
    // Pre-save reads, on the caught shape, executor idle, under the monitor.
    val regBefore = evalSyncLocked(m, lua, RegistryProbeLua)
    val scrBefore = nonEmptyScreen(screen)
    val stkBefore = parse(scrBefore, "OCLJSTK")
    val udBefore = parse(scrBefore, "OCLJUD")
    p("stk: before the save: registries " + regBefore + "; OCLJSTK=" + stkBefore + "; OCLJUD=" + udBefore)

    val nbt = new NBTTagCompound()
    var saveOk = true
    var saveErr = ""
    val tSave = System.currentTimeMillis()
    try ws.save(nbt) catch { case t: Throwable => saveOk = false; saveErr = " " + t.toString }
    val saveMs = System.currentTimeMillis() - tSave
    val addr = m.node.address
    val mnbt = findCompoundWith(nbt, addr + "_kernel")
    val names = stateNames(m)
    val savedStates: Seq[String] =
      if (mnbt == null || !mnbt.hasKey("state")) Seq.empty
      else mnbt.getIntArray("state").toSeq.map(i => names.getOrElse(i, "#" + i))
    val kBlob = findBlob(nbt, addr + "_kernel")
    val sBlob = findBlob(nbt, addr + "_stack")
    val k = if (kBlob == null) 0 else kBlob.length
    val s = if (sBlob == null) 0 else sBlob.length
    val recK = countOccurrences(kBlob, RecipeNeedle)
    val recS = countOccurrences(sBlob, RecipeNeedle)
    val recipes = recK + recS
    val landed = savedStates.contains("SynchronizedCall")
    p("stk: blobs: _kernel=" + k + " B carrying " + recK + " userdata recipes (HandleValue NBT payloads), _stack=" +
      (if (sBlob == null) "absent" else s + " B carrying " + recS + " userdata recipes") +
      "; class-name string occurrences " + countOccurrences(kBlob, "HandleValue") + "/" +
      countOccurrences(sBlob, "HandleValue") + " (interned: once per blob, not a count)")
    milestone("stk-1-save-landed-in-synccall", saveOk && landed && k > 10000,
      "save ok=" + saveOk + saveErr + " in " + saveMs + " ms; persisted state stack = " +
        (if (savedStates.isEmpty) "<no state tag: the persist failed>" else savedStates.mkString("/")) +
        "; pending call = " + pending + "; _kernel=" + k + " B")
    val ratio = if (k > 0) s.toDouble / k else -1.0
    val detail2 = "_kernel=" + k + " B, _stack=" + (if (sBlob == null) "absent" else s + " B") +
      f", ratio $ratio%.2f"
    expect match {
      case "bundle" =>
        milestone("stk-2-one-reference-space", landed && k > 10000 && s < k / 4,
          detail2 + (if (s >= k / 4) "   <- the index-2 root pulled the whole kernel into a SECOND blob: two reference spaces, two universes"
                     else if (sBlob == null) "   (no second root: the closure rode in the kernel's reference space)"
                     else "   (a small second root was written: not the bundle, but not the second universe either)"))
      case "dropin" =>
        milestone("stk-2-dropin-control-second-blob-carries-kernel", landed && k > 10000 && s > k / 2,
          detail2 + (if (s > k / 2) "   (OC's own save, our serializer: the index-2 root chased its open upvalues and wrote the kernel again -- the documented defect)"
                     else "   <- the second blob no longer carries the kernel: the two-call shape stopped producing the second universe"))
      case _ =>
        milestone("stk-2-stock-control-small-second-blob", landed && k > 10000 && sBlob != null && s < k / 4,
          detail2 + (if (sBlob != null && s < k / 4) "   (stock Eris: the closure's upvalues by value, no thread chase)"
                     else "   <- not stock Eris's shape"))
    }

    p("--- (stk) restoring the sync-call save into a fresh workspace ---")
    var ws3: Workspace = null
    var c3: Case = null
    var sc3: Screen = null
    var rerr = ""
    try {
      ws3 = new Workspace(Files.createTempDirectory("ocljit-smoke-stk"))
      ws3.load(nbt)
      val it = ws3.getEntitiesIter
      while (it.hasNext) it.next() match {
        case c: Case => c3 = c
        case sc: Screen => sc3 = sc
        case _ =>
      }
    } catch { case t: Throwable => rerr = t.toString; t.printStackTrace() }
    val m3 = if (c3 == null) null else c3.machine
    val id3 = expect match {
      case "bundle" => "stk-3-one-value-per-proxy"
      case "dropin" => "stk-3-dropin-control-two-universes"
      case _ => "stk-3-stock-control-empty-second-registry"
    }
    val id4 = expect match {
      case "bundle" => "stk-4-sync-result-recognised"
      case "dropin" => "stk-4-dropin-control-silent-mode"
      case _ => "stk-4-stock-control-silent-mode"
    }
    if (m3 == null || !m3.isRunning) {
      val why = "the restored machine is " +
        (if (m3 == null) "missing: " + rerr else "not running: lastError=" + m3.lastError)
      milestone(id3, ok = false, why)
      milestone(id4, ok = false, why)
      return
    }
    // BEFORE the first update(): the restored closure is still at index 2.
    val a3 = m3.architecture
    val lua3 = if (a3 == null) null else luaOf(a3)
    val regAfter = if (lua3 == null) "<no LuaState>" else evalSyncLocked(m3, lua3, RegistryProbeLua)
    p("stk: restored: running=" + m3.isRunning + " state=" + stateTop(m3) + " lastError=" + m3.lastError +
      "; registries " + regAfter)
    def num(row: String, key: String): Int = try parse(row, key).toInt catch { case _: Throwable => -1 }
    val kb = num(regBefore, "kreg")
    val ka = num(regAfter, "kreg")
    val same = parse(regAfter, "same") == "true"
    val values = num(regAfter, "values")
    val pend3 = parse(regAfter, "pending")
    val creg = parse(regAfter, "creg")
    val detail3 = "proxies persisted (kernel registry after a full GC) = " + kb +
      "; userdata recipes across the blobs written (= host Values the restore mints) = " + recipes +
      " (" + recK + " in _kernel, " + recS + " in _stack); after the restore: kernel registry = " + ka +
      ", closure's registry = " + creg + " entries, same table = " + same +
      ", distinct host userdata across both = " + values + "; pending = " + pend3
    // recK == kb is the count's own calibration: the kernel blob must carry
    // exactly one payload per proxy the registry held, under EITHER shape.
    // If it does not, the needle is not counting recipes and nothing built on
    // it is believed.
    val countOk = recK == kb
    val gate3 = kb >= 2 && countOk && pend3.startsWith("open(")
    val gateWhy =
      if (kb < 2) "   <- fewer than two proxies persisted: nothing to count (vacuous)"
      else if (!countOk) "   <- _kernel carries " + recK + " payloads for " + kb + " proxies: the recipe count is not measuring recipes"
      else if (!pend3.startsWith("open(")) "   <- the restored closure is not the fs.open that was pending"
      else ""
    expect match {
      case "bundle" =>
        milestone(id3, gate3 && recipes == kb && ka == kb && same,
          detail3 + (if (!gate3) gateWhy
                     else if (recipes != kb) "   <- " + recipes + " recipes for " + kb + " proxies: every proxy restores TWICE, once per blob (a second kernel universe)"
                     else if (!same) "   <- the restored closure's registry is not the kernel's: a second universe"
                     else if (ka != kb) "   <- the kernel registry did not come back with the proxies it had"
                     else ""))
      case "dropin" =>
        milestone(id3, gate3 && recipes == 2 * kb && !same,
          detail3 + (if (!gate3) gateWhy
                     else if (recipes == 2 * kb && !same) "   (OC's save over our serializer: every proxy restores twice and the closure holds a second registry -- U1 on a real machine)"
                     else "   <- not the documented two-universe shape any more"))
      case _ =>
        milestone(id3, gate3 && recipes == kb && !same,
          detail3 + (if (!gate3) gateWhy
                     else if (recipes == kb && !same) "   (stock Eris: the copied registry is EMPTY by machine.lua's own design, :1061-1066, so no second Value -- but a second registry)"
                     else "   <- not stock Eris's shape"))
    }

    val seqBefore = stkField(stkBefore, 1)
    val failsBefore = stkField(stkBefore, 2)
    var stkAfter = "<missing>"
    var seqAfter = -1
    var t = 0
    while (t < 800 && m3.isRunning && seqAfter < seqBefore + 3) {
      ws3.update(); Thread.sleep(25); t += 1
      if (t % 4 == 0) { stkAfter = parse(nonEmptyScreen(sc3), "OCLJSTK"); seqAfter = stkField(stkAfter, 1) }
    }
    val failsAfter = stkField(stkAfter, 2)
    val fresh = seqBefore >= 0 && seqAfter >= seqBefore + 2
    val txt3 = nonEmptyScreen(sc3)
    p("stk: restored machine after " + t + " ticks: running=" + m3.isRunning + " lastError=" + m3.lastError +
      " OCLJSTK=" + stkAfter + " OCLJUD=" + parse(txt3, "OCLJUD") + " (was " + udBefore + ")")
    val detail4 = "OCLJSTK before=" + stkBefore + " after=" + stkAfter + " (bursts completed after the restore: " +
      (if (fresh) (seqAfter - seqBefore).toString else "NONE") + "; read/close failures " + failsBefore +
      " -> " + failsAfter + ")"
    if (bundle)
      milestone(id4, fresh && failsBefore >= 0 && failsAfter == failsBefore,
        detail4 + (if (!fresh) "   <- STALE or dead: no burst completed after the restore, so this row is not a post-restore measurement"
                   else if (failsAfter != failsBefore) "   <- the handle the restored sync call returned is NOT in this kernel's registry: the silent mode"
                   else ""))
    else
      milestone(id4, fresh && failsAfter > failsBefore && stkAfter.contains("bad_file_descriptor"),
        detail4 + (if (!fresh) "   <- STALE or dead: no burst completed after the restore, so this row is not a post-restore measurement"
                   else if (failsAfter > failsBefore && stkAfter.contains("bad_file_descriptor"))
                     "   (the result proxy lives in the second registry, so the kernel hands the host a plain table: the silent mode, as documented)"
                   else "   <- the silent mode did not show: the two-call shape no longer loses the sync result"))
    try m3.stop() catch { case _: Throwable => }
  }

  /**
   * THE FOR-IN SAVE (fi-*).
   *
   * f1/f7 and stk save while the sandbox is idle or inside a sync call; none
   * of them saves while a program is suspended INSIDE a for-in loop over the
   * kernel's own component iterators, which is the shape every OS's boot path
   * produces (`for addr in component.list() do ... end` with an indirect
   * call, i.e. a yield, in the body).  The census measured those two
   * iterators -- component.list's __call-over-next and componentProxy's
   * two-phase __pairs -- restoring the wrong key multiset on nearly every
   * hash-layout rotation, silently (os-shape-census.md #1, #3).  The
   * serializer's replay iterator cannot reach them: the cursor is a plain key
   * in a closure upvalue and round-trips perfectly; only its POSITION in the
   * rebuilt table changes.  The fix is the kernel's (patch-machine-lua.lua
   * sites 10 and 11: snapshot the keys, walk by an integer), and this is the
   * in-machine gate for it, over the real component set.
   *
   * How the save lands mid-loop: the sandbox half (see OCLJFI in AutorunLua)
   * walks both loops one key per timer step and PARKS each strictly inside
   * its loop, with nothing pending, until a second signal.  The harness polls
   * the row for "held", saves, restores the blob into a fresh workspace (a
   * fresh LuaJIT state, the blob's own interning order), then sends the
   * second signal to BOTH machines -- the restored one and the one that was
   * never saved -- and compares the completed sequences.
   *
   * Three milestones, each with its anti-vacuity gate:
   *   fi-1  the pre-save row says held, with both positions STRICTLY inside
   *         their ranges (1 <= pos < n, n >= 3), the screen rows carry
   *         exactly pos recorded tokens each, and the save produced a real
   *         kernel blob.  The loops are parked, so the position read is the
   *         position saved, not a sample of a moving loop.
   *   fi-2  component.list walk: the restored machine's completed sequence
   *         equals the never-saved machine's, element for element.  Gates:
   *         both machines report "done" with the sequence number advanced
   *         past the saved row (a dead restored machine shows the painted-
   *         back held/0 row), and the never-saved walk is a proper walk (n
   *         distinct keys), so the comparison has a real reference.
   *   fi-3  the same for `for k, v in pairs(component.proxy(gpu))`, i.e.
   *         componentProxy.__pairs, live under LUA52COMPAT.
   * THE EXPECTATION IS KEYED ON THE KERNEL.  The watchdog kernel is ours and
   * must be exact once sites 10/11 ship (and FAILS here before they do --
   * that failure was observed, on the 9-site kernel, before this gate was
   * trusted).  The stock kernel is OpenComputers' own, whose iterators have
   * the defect by construction and whose outcome per run is a coin the hash
   * layout tosses; there the two walks are asserted for liveness only and
   * their exactness is REPORTED, because a gate that fails on every stock run
   * for the rest of the project's life is read once and ignored.
   */
  def forInSave(ws: Workspace, computer: Case, screen: Screen, kernelMode: String): Unit = {
    val m = computer.machine
    val expectExact = kernelMode == "watchdog"
    p("--- (fi) saving WHILE two for-in loops over the kernel's own component iterators are suspended mid-walk (kernel=" +
      kernelMode + ", expecting " +
      (if (expectExact) "EXACT sequences after the restore: sites 10/11"
       else "OpenComputers' own iterators: exactness reported, liveness asserted") + ") ---")
    val idL = if (expectExact) "fi-2-component-list-walk-exact" else "fi-2-stock-control-component-list-walk"
    val idP = if (expectExact) "fi-3-proxy-pairs-walk-exact" else "fi-3-stock-control-proxy-pairs-walk"
    def field(row: String, i: Int): String = { val f = row.split("/"); if (f.length > i) f(i) else "<missing>" }
    def num(row: String, i: Int): Int = try field(row, i).toInt catch { case _: Throwable => -1 }
    def toks(s: String): Seq[String] = if (s == "<missing>" || s.isEmpty) Seq.empty else s.split(",").toSeq
    def listOf(txt: String): Seq[String] = toks(parse(txt, "OCLJFIL"))
    def pairsOf(txt: String): Seq[String] = {
      val sb = new StringBuilder
      var i = 1
      var chunk = parse(txt, "OCLJFIP" + i)
      while (chunk != "<missing>") { sb.append(chunk); i += 1; chunk = parse(txt, "OCLJFIP" + i) }
      toks(sb.toString)
    }
    def diff(ref: Seq[String], got: Seq[String]): String = {
      val cr = ref.groupBy(identity).map { case (k, v) => k -> v.size }
      val cg = got.groupBy(identity).map { case (k, v) => k -> v.size }
      val missing = ref.distinct.filter(k => cg.getOrElse(k, 0) < cr(k))
      val extra = got.distinct.filter(k => cg(k) > cr.getOrElse(k, 0))
      "missing=[" + missing.mkString(" ") + "] duplicated/alien=[" + extra.mkString(" ") + "]"
    }
    if (!m.isRunning) {
      val why = "no running machine to save: running=" + m.isRunning + " lastError=" + m.lastError
      milestone("fi-1-save-landed-mid-loop", ok = false, why)
      milestone(idL, ok = false, why)
      milestone(idP, ok = false, why)
      return
    }
    val queued = m.signal("ocljfi")
    var row0 = "<missing>"
    var polls = 0
    val tPoll = System.currentTimeMillis()
    while (!row0.startsWith("held/") && !row0.startsWith("ERR/") && polls < 1200 && m.isRunning) {
      ws.update(); Thread.sleep(25); polls += 1
      if (polls % 2 == 0) row0 = parse(nonEmptyScreen(screen), "OCLJFI")
    }
    // The loops are parked, so nothing below changes any more -- but the
    // status row is painted before the sequence rows, and a gpu.set over the
    // tick budget yields between them.  A few more ticks let the paint land.
    var settle = 0
    while (settle < 8 && m.isRunning) { ws.update(); Thread.sleep(25); settle += 1 }
    val scr0 = nonEmptyScreen(screen)
    row0 = parse(scr0, "OCLJFI")
    val held = field(row0, 0) == "held"
    val seq0 = num(row0, 1)
    val posL = num(row0, 2); val nL = num(row0, 3)
    val posP = num(row0, 4); val nP = num(row0, 5)
    val preL = listOf(scr0); val preP = pairsOf(scr0)
    p("fi: signal queued=" + queued + "; " + polls + " polls in " + (System.currentTimeMillis() - tPoll) +
      " ms; row at save = " + row0 + "  (state/seq/posL/nL/posP/nP/gpu/err)")
    p("fi: recorded before the save: list " + preL.mkString(",") + "  pairs " + preP.mkString(","))
    val inside = held && nL >= 3 && nP >= 3 && posL >= 1 && posL < nL && posP >= 1 && posP < nP
    val rowsOk = preL.size == posL && preP.size == posP
    if (!held) {
      val why = "the loops never parked: row=" + row0 + " after " + polls + " polls; running=" + m.isRunning +
        " lastError=" + m.lastError
      milestone("fi-1-save-landed-mid-loop", ok = false, why)
      milestone(idL, ok = false, why)
      milestone(idP, ok = false, why)
      return
    }

    val nbt = new NBTTagCompound()
    var saveOk = true
    var saveErr = ""
    val tSave = System.currentTimeMillis()
    try ws.save(nbt) catch { case t: Throwable => saveOk = false; saveErr = " " + t.toString }
    val saveMs = System.currentTimeMillis() - tSave
    val kBlob = findBlob(nbt, m.node.address + "_kernel")
    val k = if (kBlob == null) 0 else kBlob.length
    milestone("fi-1-save-landed-mid-loop", saveOk && inside && rowsOk && k > 10000,
      "save ok=" + saveOk + saveErr + " in " + saveMs + " ms; both loops parked: list at " + posL + "/" + nL +
        ", pairs at " + posP + "/" + nP + " (strictly inside=" + inside + "); screen rows carry " + preL.size +
        "/" + preP.size + " recorded tokens (=" + rowsOk + "); _kernel=" + k + " B" +
        (if (!inside) "   <- a position at an end of its range proves nothing about a suspended loop"
         else if (!rowsOk) "   <- the rows do not carry the recorded prefix: a harness fault, not the defect"
         else ""))
    if (!(saveOk && inside && rowsOk && k > 10000)) {
      milestone(idL, ok = false, "fi-1 did not hold; nothing below is a mid-loop measurement")
      milestone(idP, ok = false, "fi-1 did not hold; nothing below is a mid-loop measurement")
      return
    }

    p("--- (fi) restoring the mid-loop save into a fresh workspace, then completing both walks on BOTH machines ---")
    var ws4: Workspace = null
    var c4: Case = null
    var sc4: Screen = null
    var rerr = ""
    try {
      ws4 = new Workspace(Files.createTempDirectory("ocljit-smoke-fi"))
      ws4.load(nbt)
      val it = ws4.getEntitiesIter
      while (it.hasNext) it.next() match {
        case c: Case => c4 = c
        case sc: Screen => sc4 = sc
        case _ =>
      }
    } catch { case t: Throwable => rerr = t.toString; t.printStackTrace() }
    val m4 = if (c4 == null) null else c4.machine
    if (m4 == null || sc4 == null || !m4.isRunning) {
      val why = "the restored machine is " +
        (if (m4 == null) "missing: " + rerr else if (sc4 == null) "without a screen" else "not running: lastError=" + m4.lastError)
      milestone(idL, ok = false, why)
      milestone(idP, ok = false, why)
      return
    }
    // The second signal to both: the never-saved machine's completion is the
    // reference, the restored machine's is the measurement.
    val goA = m.signal("ocljfigo")
    val goB = m4.signal("ocljfigo")
    var rowA = row0
    var rowB = "<missing>"
    def fin(row: String): Boolean = field(row, 0) == "done" && num(row, 1) == seq0 + 1
    var t = 0
    while (t < 1600 && !(fin(rowA) && fin(rowB)) && (m.isRunning || m4.isRunning)) {
      ws.update(); ws4.update(); Thread.sleep(25); t += 1
      if (t % 4 == 0) {
        rowA = parse(nonEmptyScreen(screen), "OCLJFI")
        rowB = parse(nonEmptyScreen(sc4), "OCLJFI")
      }
    }
    // Same settling as before the save: "done" is painted before the rows
    // that carry the sequences.
    settle = 0
    while (settle < 8) { ws.update(); ws4.update(); Thread.sleep(25); settle += 1 }
    val txtA = nonEmptyScreen(screen)
    val txtB = nonEmptyScreen(sc4)
    rowA = parse(txtA, "OCLJFI"); rowB = parse(txtB, "OCLJFI")
    val aL = listOf(txtA); val bL = listOf(txtB)
    val aP = pairsOf(txtA); val bP = pairsOf(txtB)
    val liveA = fin(rowA)
    val liveB = fin(rowB)
    p("fi: go queued A=" + goA + " B=" + goB + "; after " + t + " ticks: never-saved row=" + rowA +
      " (running=" + m.isRunning + ")  restored row=" + rowB + " (running=" + m4.isRunning +
      " lastError=" + m4.lastError + ")")
    p("fi: list  never-saved (" + aL.size + "): " + aL.mkString(","))
    p("fi: list  restored    (" + bL.size + "): " + bL.mkString(","))
    p("fi: pairs never-saved (" + aP.size + "): " + aP.mkString(","))
    p("fi: pairs restored    (" + bP.size + "): " + bP.mkString(","))
    val refL = aL.size == nL && aL.distinct.size == nL
    val refP = aP.size == nP && aP.distinct.size == nP
    val exactL = aL == bL
    val exactP = aP == bP
    def gateWhy(ref: Boolean, which: String): String =
      if (!liveB) "   <- STALE or dead: the restored machine never reported done/" + (seq0 + 1) + ", so its rows are the painted-back pre-save screen"
      else if (!liveA) "   <- the never-saved machine never completed, so there is no reference walk"
      else if (!ref) "   <- the never-saved " + which + " walk is not a proper walk of n distinct keys; the reference is broken"
      else ""
    val detailL = "saved at " + posL + "/" + nL + "; never-saved walk " + aL.size + " keys, restored walk " +
      bL.size + " keys, element-wise equal=" + exactL + "; " + diff(aL, bL)
    val detailP = "saved at " + posP + "/" + nP + " over the gpu proxy " + field(row0, 6) +
      "; never-saved walk " + aP.size + " keys, restored walk " + bP.size + " keys, element-wise equal=" + exactP +
      "; " + diff(aP, bP)
    if (expectExact) {
      milestone(idL, liveA && liveB && refL && exactL,
        detailL + gateWhy(refL, "list") +
          (if (liveA && liveB && refL && !exactL)
             "   <- the restored loop resumed next() from its saved key in a DIFFERENT hash layout: the wrong components, silently (census #1)"
           else ""))
      milestone(idP, liveA && liveB && refP && exactP,
        detailP + gateWhy(refP, "pairs") +
          (if (liveA && liveB && refP && !exactP)
             "   <- componentProxy.__pairs resumed next() from its saved key in a DIFFERENT hash layout: the wrong keys, silently (census #3)"
           else ""))
    } else {
      milestone(idL, liveA && liveB && refL,
        detailL + gateWhy(refL, "list") +
          (if (liveA && liveB && refL) "   (OpenComputers' own iterator: exactness REPORTED, not asserted)" else ""))
      milestone(idP, liveA && liveB && refP,
        detailP + gateWhy(refP, "pairs") +
          (if (liveA && liveB && refP) "   (OpenComputers' own iterator: exactness REPORTED, not asserted)" else ""))
    }
    try m4.stop() catch { case _: Throwable => }
  }

  /**
   * THE OS-WRAPPER DIAGNOSTIC SAVE (dg-1).
   *
   * fi-2/fi-3 prove the kernel's two iterators survive a mid-walk save once
   * sites 10/11 snapshot them.  What is LEFT is census #9: a `next`-wrapper
   * the OS author wrote -- OpenOS's boot/04_component.lua:16-31 puts one on
   * its `component` library table -- which the serializer cannot tell from a
   * legitimate custom iterator and cannot rewrite.  The answer designed for
   * it (docs/forin-iterator-gap.md, "The #9 diagnostic") is a save-time NAME:
   * under eris.settings("forin", "warn") the persist queues, for each live
   * for-in loop whose iterator is a Lua closure that reaches `next`, one
   * message giving the loop's line and the iterator's; the Architecture sets
   * the mode from -Docluajit.forin and drains eris.diagnostics() to the log
   * after every save that returned.  This is the in-machine gate for that
   * whole path, over the real OpenOS wrapper.
   *
   * How the save lands mid-loop: the sandbox half (OCLJDG in AutorunLua)
   * walks `for k in pairs(component)` one key per timer step and parks it
   * strictly inside until a second signal, exactly as fi does.
   *
   * WHO DRAINS.  In the additive arm OCLuaJITArchitecture drives the machine
   * and its save() drains into `forinDiagnostics`; the milestone reads what
   * THIS save appended.  In the dropin arm OpenComputers' own
   * NativeLua52Architecture drives the machine over our native and reads no
   * property, so the harness plays the adapter's part on the same state with
   * the adapter's own two calls (forinApply before, forinDrain after), under
   * the machine's monitor like every raw-state read here.  Either way the
   * SERIALIZER is what is being asked, and it is the same one.
   *
   * KEYED ON THE MODE the JVM was started with (-Docluajit.forin, through
   * JAVA_TOOL_OPTIONS), because one run cannot show both directions:
   *   warn     STRICT: the save landed with the loop parked strictly inside
   *            (1 <= pos < n, n >= 3) and produced a real kernel blob, and at
   *            least one diagnostic drained by this save names
   *            04_component.lua.  It FAILS on a native whose serializer
   *            predates the setting (the setting is refused, nothing is
   *            drained) and when the loop did not park (nothing to name).
   *   ignore   the property absent, or =ignore: the NEGATIVE.  The same save,
   *            nothing drained (the adapter does not look), AND a direct
   *            eris.diagnostics() after the save comes back empty -- the
   *            serializer's own word that ignore did not look.  It reports
   *            "mode=ignore: 0 diagnostics, as configured" and PASSES; on a
   *            serializer without eris.diagnostics it fails, by name.
   *   refuse   the persist must have RAISED the message instead: no kernel
   *            blob, and (additive arm) the adapter's recorded save error
   *            names 04_component.lua.
   * Afterwards the parked loop is released with the second signal and the
   * completion is reported, so the saves that follow (stk) meet no parked
   * wrapper -- under refuse they would fail on it.
   */
  def forinDiagnosticSave(ws: Workspace, computer: Case, screen: Screen): Unit = {
    val m = computer.machine
    val mode = OCLuaJITArchitecture.ForinMode
    val id = "dg-1-forin-diagnostic-names-the-os-wrapper"
    p("--- (dg) saving WHILE an OpenOS-authored next-wrapper loop is parked mid-walk: for k in pairs(component), " +
      "boot/04_component.lua's __pairs (-D" + OCLuaJITArchitecture.ForinProperty + "=" + mode + ") ---")
    def field(row: String, i: Int): String = { val f = row.split("/"); if (f.length > i) f(i) else "<missing>" }
    def num(row: String, i: Int): Int = try field(row, i).toInt catch { case _: Throwable => -1 }
    if (!m.isRunning) {
      milestone(id, ok = false, "no running machine to save: running=" + m.isRunning + " lastError=" + m.lastError)
      return
    }
    val arch = m.architecture
    val adapter: OCLuaJITArchitecture = arch match { case a: OCLuaJITArchitecture => a; case _ => null }
    val lua = if (arch == null) null else luaOf(arch)
    val driver = if (adapter != null) "adapter" else "harness"
    // The dropin arm: nothing in OC's architecture reads the property, so the
    // harness sets the mode itself, with the adapter's own call.
    var applyErr = ""
    if (adapter == null && lua != null) {
      try m.synchronized { OCLuaJITArchitecture.forinApply(lua, mode) }
      catch { case e: Exception => applyErr = e.toString }
      p("dg: dropin arm -- the harness set eris.settings(\"forin\", \"" + mode + "\") itself" +
        (if (applyErr.isEmpty) "" else ": REFUSED " + applyErr))
    }
    val queued = m.signal("ocljdg")
    var row0 = "<missing>"
    var polls = 0
    val tPoll = System.currentTimeMillis()
    while (!row0.startsWith("held/") && !row0.startsWith("ERR/") && polls < 1200 && m.isRunning) {
      ws.update(); Thread.sleep(25); polls += 1
      if (polls % 2 == 0) row0 = parse(nonEmptyScreen(screen), "OCLJDG")
    }
    // Parked, so nothing below changes any more; a few more ticks let the
    // paint land (the row is painted from the heartbeat, not the driver).
    var settle = 0
    while (settle < 8 && m.isRunning) { ws.update(); Thread.sleep(25); settle += 1 }
    row0 = parse(nonEmptyScreen(screen), "OCLJDG")
    val held = field(row0, 0) == "held"
    val seq0 = num(row0, 1)
    val pos = num(row0, 2)
    val n = num(row0, 3)
    p("dg: signal queued=" + queued + "; " + polls + " polls in " + (System.currentTimeMillis() - tPoll) +
      " ms; row at save = " + row0 + "  (state/seq/pos/n/err)")
    val inside = held && n >= 3 && pos >= 1 && pos < n
    if (!held) {
      milestone(id, ok = false, "the loop never parked: row=" + row0 + " after " + polls + " polls; running=" +
        m.isRunning + " lastError=" + m.lastError)
      return
    }
    val before = if (adapter != null) adapter.forinDiagnostics.size else 0
    val nbt = new NBTTagCompound()
    var saveOk = true
    var saveErr = ""
    val tSave = System.currentTimeMillis()
    try ws.save(nbt) catch { case t: Throwable => saveOk = false; saveErr = " " + t.toString }
    val saveMs = System.currentTimeMillis() - tSave
    val kBlob = findBlob(nbt, m.node.address + "_kernel")
    val k = if (kBlob == null) 0 else kBlob.length
    // What THIS save produced.
    var drainErr = ""
    val drained: List[String] =
      if (adapter != null) adapter.forinDiagnostics.drop(before).toList
      else if (lua != null) {
        try m.synchronized { OCLuaJITArchitecture.forinDrain(lua) }
        catch { case e: Exception => drainErr = e.toString; Nil }
      } else Nil
    // A direct read AFTER the drain, in every mode: what is left in the
    // serializer's list.  After the adapter drained it must be nothing; under
    // ignore it must be nothing because ignore does not look; and on a
    // serializer that lacks the function it is an ERROR, not "nothing".
    var residualErr = ""
    val residual: List[String] =
      if (lua == null) Nil
      else {
        try m.synchronized { OCLuaJITArchitecture.forinDrain(lua) }
        catch { case e: Exception => residualErr = e.toString; Nil }
      }
    for (d <- drained) p("dg: diagnostic (drained by the " + driver + "): " + d)
    for (d <- residual) p("dg: residual after the drain: " + d)
    val named = drained.filter(_.contains("04_component.lua"))
    val lastErr = if (adapter != null) adapter.lastSaveError else ""
    // Release the parked loop, so the saves that follow meet no parked wrapper.
    val go = m.signal("ocljdggo")
    var rowA = row0
    var t = 0
    while (t < 400 && !(field(rowA, 0) == "done" && num(rowA, 1) == seq0 + 1) && m.isRunning) {
      ws.update(); Thread.sleep(25); t += 1
      if (t % 4 == 0) rowA = parse(nonEmptyScreen(screen), "OCLJDG")
    }
    val released = field(rowA, 0) == "done" && num(rowA, 1) == seq0 + 1
    p("dg: go queued=" + go + "; after " + t + " ticks the row is " + rowA + " (released=" + released +
      ", running=" + m.isRunning + " lastError=" + m.lastError + ")")
    val common = "save ok=" + saveOk + saveErr + " in " + saveMs + " ms; loop parked at " + pos + "/" + n +
      " (strictly inside=" + inside + "); _kernel=" + k + " B; drained by the " + driver + ": " + drained.size +
      " diagnostic(s), " + named.size + " naming 04_component.lua" +
      (if (drainErr.isEmpty) "" else " (drain REFUSED: " + drainErr + ")") +
      "; residual after the drain: " + residual.size +
      (if (residualErr.isEmpty) "" else " (direct read REFUSED: " + residualErr + ")") +
      (if (applyErr.isEmpty) "" else "; eris.settings(\"forin\") REFUSED: " + applyErr) +
      "; released=" + released
    mode match {
      case "warn" =>
        val ok = saveOk && inside && k > 10000 && named.nonEmpty
        milestone(id, ok, "mode=warn: " + common +
          (if (ok) ""
           else if (!inside) "   <- a position at an end of its range proves nothing about a suspended loop"
           else if (!saveOk || k <= 10000) "   <- no kernel blob: the persist did not return, so there was nothing to drain"
           else if (drained.isEmpty) "   <- the persist named NOTHING with the wrapper parked mid-walk: the setting was refused (a serializer older than it), or the scan missed the shape"
           else "   <- something was named, but not the OpenOS wrapper"))
      case "ignore" =>
        val ok = saveOk && inside && k > 10000 && drained.isEmpty && residual.isEmpty && residualErr.isEmpty
        milestone(id, ok, "mode=ignore: " + drained.size + " diagnostics, as configured; " + common +
          (if (ok) "   (the NEGATIVE: the " + driver + " did not look, and eris.diagnostics() read directly after the save is empty)"
           else if (residualErr.nonEmpty) "   <- eris.diagnostics() is not there: this serializer predates the diagnostic"
           else if (drained.nonEmpty || residual.nonEmpty) "   <- ignore LOOKED: the persist queued a diagnostic under the default mode"
           else if (!inside) "   <- a position at an end of its range proves nothing about a suspended loop"
           else "   <- no kernel blob: the save did not return"))
      case _ =>
        val namedErr = lastErr.contains("04_component.lua")
        val ok = inside && kBlob == null && (adapter == null || namedErr)
        milestone(id, ok, "mode=refuse: " + common + "; the save's recorded error: " +
          (if (lastErr.isEmpty) "<none recorded>" else lastErr) +
          (if (ok) (if (adapter == null) "   (dropin arm: OC's own save hides the text; the blob's absence is what is asserted)" else "")
           else if (kBlob != null) "   <- refuse did NOT refuse: a kernel blob was written with the wrapper parked mid-walk"
           else if (!inside) "   <- a position at an end of its range proves nothing about a suspended loop"
           else "   <- the persist failed, but not with the wrapper's name"))
    }
  }

  /** Which native this run is driven by: luajit (dropin) | additive | stock. */
  val nativeMode: String = System.getProperty("ocljit.native", "luajit")

  /**
    * OCLJ_PROBE: "" (the default run) | "grace".  Read from the environment
    * like OCLJ_BENCH_ONLY, so smoke-test.sh needs no plumbing.  "grace" boots
    * OpenOS exactly as the default run does, then runs ONLY the grace-expiry
    * probe (graceExpiryProbe below) in place of the suite and the persist
    * milestones, and reports one milestone, k6.
    */
  val probeMode: String = Option(System.getenv("OCLJ_PROBE")).map(_.trim).getOrElse("")

  /**
    * Which architecture must drive the machine, DERIVED from nativeMode rather
    * than chosen separately.
    *
    * They cannot move independently. In the additive arm the forced library
    * directory holds only libjnluajit52-*, so OpenComputers' own 5.2 factory
    * MISSES and falls back to its bundled PUC native -- pinning
    * NativeLua52Architecture there would quietly run the whole suite on PUC Lua
    * while every line of output claimed to describe OC-LuaJIT. That is the
    * failure this harness exists to make impossible, so the two come from one
    * switch and the guard below asserts the result.
    */
  val expectedArch: Class[_ <: totoro.ocelot.brain.entity.machine.Architecture] =
    if (nativeMode == "additive") classOf[OCLuaJITArchitecture]
    else classOf[NativeLua52Architecture]

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
    if (!expectedArch.isInstance(arch))
      die("architecture is " + arch.getClass.getName + ", not the pinned " + expectedArch.getName +
        " -- this run is measuring a different VM than it claims to.")
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

    val fp = s"native=$nativeMark | class=${lua.getClass.getSimpleName} | _VERSION=$version | " +
      s"jit=$hasJit ($jitStatus) | eris=[$erisShape] | eris.version=$erisVer"
    p("GUARD OK. arch=" + arch.getClass.getName)
    p("GUARD VM FINGERPRINT: " + fp)
    // The guard is TWO-SIDED, and the stock side is asserted with equal force.
    // Cell A of the benchmark is "what a player runs today" -- ocelot-brain's
    // bundled PUC-Lua 5.2 native, loaded simply by not pointing
    // forceNativeLibPathFirst at ours.  A silently mis-resolved DLL in EITHER
    // direction would produce a plausible-looking number for the wrong VM,
    // which is the one way this benchmark could lie outright.  So each mode
    // refuses the other's fingerprint.
    // WHICH LuaState CLASS, not just which VM. The dropin and the additive
    // build are the same LuaJIT behind different JNI symbol families, so the
    // marker below cannot tell them apart -- only the Java class can, and it is
    // the thing the additive arm exists to exercise. PersistenceAPI drives
    // lua_dump/lua_pushbytearray/lua_tobytearray/lua_next/lua_rawset, all of
    // which LuaStateLuaJIT redeclares into OUR family, so a persistence result
    // from the wrong class would be a result about OpenComputers' bindings.
    val stateClass = lua.getClass.getName

    nativeMode match {
      case "additive" =>
        if (!nativeMark.startsWith("luajit/"))
          die("ocljit.native=additive but the live state carries no _OCLJ_NATIVE marker: " +
            "this is not our VM. Check that forceNativeLibPathFirst names a directory " +
            "holding libjnluajit52-<platform>.")
        if (!stateClass.endsWith("LuaStateLuaJIT"))
          die("ocljit.native=additive but the live LuaState is " + stateClass +
            ", not LuaStateLuaJIT: the machine is running on OpenComputers' own binding, " +
            "so nothing here describes the additive shape we ship.")
        if (hasJit == "NO-JIT-TABLE")
          die("no jit table in the live state: the shim did not open luaopen_jit.")
        if (erisShape == "NO-ERIS")
          die("no eris library in the live state: eris_lj.o did not link in, or luaopen_eris was not called.")
      case "luajit" =>
        if (stateClass.endsWith("LuaStateLuaJIT"))
          die("ocljit.native=luajit (dropin) but the live LuaState is " + stateClass +
            ": that is the ADDITIVE class. The two arms would not be measuring the same thing.")
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
        die("ocljit.native must be luajit, additive or stock, not '" + other + "'")
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
      |-- THE USERDATA PROBE.  fs.open returns a Value (HandleValue), which
      |-- machine.lua wraps into a proxy table whose metatable is userdataWrapper
      |-- -- the one carrying the [persistKey] closure.  Held as an upvalue of
      |-- the heartbeat timer below, so it is REACHABLE from the persisted root
      |-- and eris must serialise it through that closure.
      |local udh = fsproxy.open("manifest.lua", "r")
      |local udSeq = 0
      |local udRow = "OCLJUD=noopen/0"
      |-- THE SEQUENCE NUMBER IS WHAT MAKES f7 NON-VACUOUS.  A machine that dies
      |-- during unpersist leaves the PRE-SAVE screen painted, so a check that
      |-- only reads the row's shape passes on a corpse.  Only a live probe can
      |-- advance this, exactly as encoreSeq does for the encore.
      |local function udProbe()
      |  udSeq = udSeq + 1
      |  if not udh then udRow = "OCLJUD=noopen/" .. udSeq return end
      |  local okt, mt = pcall(getmetatable, udh)
      |  local okr, chunk = pcall(function()
      |    fsproxy.seek(udh, "set", 0)
      |    return fsproxy.read(udh, 8)
      |  end)
      |  udRow = string.format("OCLJUD=%s/%s/%s/%s/%d", type(udh),
      |    tostring(okt and mt):gsub("[ /]", "_"), tostring(okr),
      |    tostring(okr and chunk and #chunk or chunk):gsub("[ /]", "_"), udSeq)
      |end
      |udProbe()
      |
      |-- THE SYNC-CALL SAVE PROBE, sandbox half (the stk-* milestones on the
      |-- Java side).  That save has to land while the machine is in
      |-- SynchronizedCall, and the call pending at that moment has to be one
      |-- whose RESULT is a host Value.  fs.open is direct with limit = 4 per
      |-- tick (ocelot-brain FileSystem.scala:150) against a Tier-3 budget of
      |-- 1.5, so a burst of eight opens in one callback pushes at least two of
      |-- them past the budget and down machine.lua's synchronized path
      |-- (invoke :1080-1106): the LimitReachedException comes back as zero
      |-- results, invoke yields a closure, and that closure is what OC files
      |-- at stack index 2 and persists as "_stack".
      |--
      |-- Every handle is then read and closed at once, and THAT is the
      |-- measurement.  A handle whose proxy was made by a closure restored into
      |-- a second kernel universe is registered in that universe's registry,
      |-- not this kernel's; unwrapUserdata (:1080, the direct path) finds no
      |-- entry, hands the host a plain table, and FileSystem.checkHandle
      |-- (:232) answers nil, "bad file descriptor".  Failures are COUNTED with
      |-- the last message, and the sequence number advances once per burst so
      |-- the Java side can tell a burst that ran AFTER the restore from the
      |-- row the restore painted back (the same gate f7 and the encore use).
      |--
      |-- Started by a SIGNAL from the harness, not by a timer: nothing of this
      |-- is pending while the deadline probe runs (see the k4 note below), and
      |-- the chain re-arms itself from the callback that finished, as
      |-- everything here does.
      |local stkSeq, stkFails, stkLast, stkHeld = 0, 0, "none", nil
      |local stkRow = "OCLJSTK=idle/0/0/none"
      |local function stkFail(what)
      |  stkFails = stkFails + 1
      |  stkLast = tostring(what):gsub("[ /]", "_"):sub(1, 40)
      |end
      |local function stkBurst()
      |  local hs = {}
      |  for i = 1, 8 do
      |    local h, e = fsproxy.open("manifest.lua", "r")
      |    if h then hs[#hs + 1] = h else stkFail("open:" .. tostring(e)) end
      |  end
      |  for i = 1, #hs do
      |    local r, e = fsproxy.read(hs[i], 8)
      |    if type(r) ~= "string" then stkFail("read:" .. tostring(e)) end
      |    local _, ce = fsproxy.close(hs[i])
      |    if ce ~= nil then stkFail("close:" .. tostring(ce)) end
      |  end
      |  stkSeq = stkSeq + 1
      |  stkRow = string.format("OCLJSTK=run/%d/%d/%s", stkSeq, stkFails, stkLast)
      |  event.timer(0, stkBurst)
      |end
      |event.listen("ocljstk", function()
      |  -- One handle of ours HELD for the life of the machine, so the registry
      |  -- the save carries holds a proxy this probe owns, next to udh above:
      |  -- the "proxies persisted" side of stk-3 is at least two.
      |  stkHeld = fsproxy.open("manifest.lua", "r")
      |  stkRow = "OCLJSTK=run/0/0/none"
      |  event.timer(0, stkBurst)
      |  return false   -- one-shot: OpenOS drops a listener that returns false
      |end)
      |
      |-- THE FOR-IN PROBE, sandbox half (the fi-* milestones on the Java side).
      |-- The two iterators OpenComputers' own kernel hands every program --
      |-- component.list()'s __call table (libcomponent.list) and
      |-- componentProxy.__pairs -- keep their traversal cursor in a closure
      |-- upvalue as a plain KEY.  A loop suspended across a save therefore
      |-- resumes `next` from that key inside the RESTORED table's hash layout,
      |-- a different one, and visits the wrong keys with no error anywhere
      |-- (docs/research/os-shape-census.md #1 and #3; docs/forin-iterator-gap.md).
      |-- The serializer cannot see it: the key round-trips perfectly.  The fix
      |-- is the kernel's (sites 10 and 11 of patch-machine-lua.lua: snapshot
      |-- the keys, walk by an integer), and this probe is what proves it on a
      |-- real machine over the real component set.
      |--
      |-- Two coroutines, one per loop, advanced one key per step from a timer:
      |--     for addr in component.list() do record(addr) yield end
      |--     for k in pairs(component.proxy(gpu)) do record(k) yield end
      |-- Each is PARKED strictly inside its loop once it has walked half its
      |-- keys, and stays parked -- no timer pending -- until a second signal.
      |-- So the position at save time is a fact read off the screen, not a
      |-- race against the wall clock, and the same second signal sent to the
      |-- machine that was never saved yields the reference sequence the
      |-- restored machine is held to.  The sequence number advances only when
      |-- both loops COMPLETE, so a restored machine that died shows the
      |-- painted-back "held/0" row and never "done/1".
      |--
      |-- Tokens instead of names where names would not fit on the screen: an
      |-- address is its first 8 hex digits; a proxy key is the key itself.
      |local fiState, fiSeq, fiErr = "idle", 0, "none"
      |local fiL, fiP = {}, {}                   -- the recorded sequences
      |local fiPosL, fiNL, fiPosP, fiNP = 0, 0, 0, 0
      |local fiHoldL, fiHoldP = 0, 0             -- 0: park at half; -1: run free
      |local fiCoL, fiCoP = nil, nil
      |local fiAddr = "-"
      |local fiDirty = false
      |local function fiListLoop()
      |  local list = component.list()
      |  local n = 0
      |  for _ in next, list do n = n + 1 end    -- raw count of the API's own table
      |  fiNL = n
      |  if fiHoldL == 0 then fiHoldL = math.max(1, math.floor(n / 2)) end
      |  for addr in list do                     -- the canonical OC idiom
      |    fiL[#fiL + 1] = addr:sub(1, 8)
      |    fiPosL = fiPosL + 1
      |    coroutine.yield()
      |  end
      |end
      |local function fiPairsLoop()
      |  local proxy = component.proxy(fiAddr)
      |  local n = 0
      |  for k in next, proxy do if k ~= "fields" then n = n + 1 end end
      |  for _ in next, proxy.fields do n = n + 1 end
      |  fiNP = n
      |  if fiHoldP == 0 then fiHoldP = math.max(1, math.floor(n / 2)) end
      |  for k in pairs(proxy) do                -- componentProxy.__pairs
      |    fiP[#fiP + 1] = tostring(k)
      |    fiPosP = fiPosP + 1
      |    coroutine.yield()
      |  end
      |end
      |local function fiStep(co, which)
      |  local ok, err = coroutine.resume(co)
      |  if not ok then fiErr = which .. ":" .. tostring(err):gsub("[ /]", "_"):sub(1, 40) end
      |  return coroutine.status(co) == "dead"
      |end
      |local function fiDrive()
      |  local doneL = coroutine.status(fiCoL) == "dead"
      |  local doneP = coroutine.status(fiCoP) == "dead"
      |  local parkedL = fiHoldL > 0 and fiPosL >= fiHoldL
      |  local parkedP = fiHoldP > 0 and fiPosP >= fiHoldP
      |  if not doneL and not parkedL then doneL = fiStep(fiCoL, "list") end
      |  if not doneP and not parkedP then doneP = fiStep(fiCoP, "pairs") end
      |  parkedL = fiHoldL > 0 and fiPosL >= fiHoldL
      |  parkedP = fiHoldP > 0 and fiPosP >= fiHoldP
      |  fiDirty = true
      |  if fiErr ~= "none" then fiState = "ERR" return end
      |  if doneL and doneP then fiSeq = fiSeq + 1 fiState = "done" return end
      |  if (doneL or parkedL) and (doneP or parkedP) then fiState = "held" return end
      |  event.timer(0.1, fiDrive)
      |end
      |event.listen("ocljfi", function()
      |  fiL, fiP = {}, {}
      |  fiPosL, fiNL, fiPosP, fiNP = 0, 0, 0, 0
      |  fiHoldL, fiHoldP = 0, 0
      |  fiErr, fiState = "none", "run"
      |  fiAddr = component.list("gpu")() or "-"   -- the () idiom, kernel :1532's own
      |  fiCoL = coroutine.create(fiListLoop)
      |  fiCoP = coroutine.create(fiPairsLoop)
      |  fiDirty = true
      |  event.timer(0, fiDrive)
      |  return false
      |end)
      |event.listen("ocljfigo", function()
      |  fiHoldL, fiHoldP = -1, -1
      |  -- Parked means nothing is pending, so the driver has to be re-armed;
      |  -- while still stepping towards the park it already is.
      |  if fiState == "held" then fiState = "go" fiDirty = true event.timer(0, fiDrive) end
      |  return false
      |end)
      |local function fiPaint()
      |  local function row(r, s)
      |    component.gpu.set(1, r, s .. string.rep(" ", math.max(0, 150 - #s)))
      |  end
      |  row(43, string.format("OCLJFI=%s/%d/%d/%d/%d/%d/%s/%s", fiState, fiSeq,
      |    fiPosL, fiNL, fiPosP, fiNP, fiAddr:sub(1, 8), fiErr))
      |  row(44, "OCLJFIL=" .. table.concat(fiL, ","))
      |  local s = table.concat(fiP, ",")
      |  local r = 45
      |  for i = 1, math.max(1, #s), 140 do
      |    if r > 49 then fiErr = "pairs-rows-overflow" break end
      |    row(r, "OCLJFIP" .. (r - 44) .. "=" .. s:sub(i, i + 139))
      |    r = r + 1
      |  end
      |end
      |
      |-- THE OS-WRAPPER DIAGNOSTIC PROBE, sandbox half (dg-1 on the Java side).
      |-- What fi cannot cover: an iterator the OS AUTHOR wrote.  OpenOS's
      |-- boot/04_component.lua:16-31 installs a __pairs on the `component`
      |-- library table -- a Lua closure over `next` with a parent-phase flag,
      |-- own keys first and then the primaries -- so `for k in pairs(component)`
      |-- is exactly the residual shape of docs/forin-iterator-gap.md (census
      |-- #9): not replayable, not soundly rewritable, and under
      |-- -Docluajit.forin=warn NAMED by the persist, both lines.  One
      |-- coroutine, one key per timer step, parked strictly inside the loop at
      |-- half its keys until a second signal -- the fi pattern, so the position
      |-- at save time is a fact read off the screen and not a race.  A yield
      |-- inside the body is what os.sleep would be too: the frame is suspended
      |-- inside the loop either way, and that is the condition the scan tests.
      |local dgState, dgSeq, dgPos, dgN, dgErr = "idle", 0, 0, 0, "none"
      |local dgHold = 0                            -- 0: park at half; -1: run free
      |local dgCo = nil
      |local dgDirty = false
      |local function dgLoop()
      |  local n = 0
      |  for _ in pairs(component) do n = n + 1 end -- the same wrapper, walked through for the count
      |  dgN = n
      |  if dgHold == 0 then dgHold = math.max(1, math.floor(n / 2)) end
      |  for k in pairs(component) do               -- OpenOS's own __pairs: boot/04_component.lua:16
      |    dgPos = dgPos + 1
      |    coroutine.yield()                        -- the loop line the diagnostic names
      |  end
      |end
      |local function dgDrive()
      |  local done = coroutine.status(dgCo) == "dead"
      |  local parked = dgHold > 0 and dgPos >= dgHold
      |  if not done and not parked then
      |    local ok, err = coroutine.resume(dgCo)
      |    if not ok then dgErr = tostring(err):gsub("[ /]", "_"):sub(1, 40) end
      |    done = coroutine.status(dgCo) == "dead"
      |  end
      |  parked = dgHold > 0 and dgPos >= dgHold
      |  dgDirty = true
      |  if dgErr ~= "none" then dgState = "ERR" return end
      |  if done then dgSeq = dgSeq + 1 dgState = "done" return end
      |  if parked then dgState = "held" return end
      |  event.timer(0.1, dgDrive)
      |end
      |event.listen("ocljdg", function()
      |  dgPos, dgN, dgHold = 0, 0, 0
      |  dgErr, dgState = "none", "run"
      |  dgCo = coroutine.create(dgLoop)
      |  dgDirty = true
      |  event.timer(0, dgDrive)
      |end)
      |event.listen("ocljdggo", function()
      |  dgHold = -1
      |  -- Parked means nothing is pending, so the driver has to be re-armed.
      |  if dgState == "held" then dgState = "go" dgDirty = true event.timer(0, dgDrive) end
      |end)
      |local function dgPaint()
      |  local s = string.format("OCLJDG=%s/%d/%d/%d/%s", dgState, dgSeq, dgPos, dgN, dgErr)
      |  component.gpu.set(1, 42, s .. string.rep(" ", math.max(0, 150 - #s)))
      |end
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
      |  if n % 10 == 0 then udProbe() end
      |  component.gpu.set(1, 17, udRow .. "        ")
      |  component.gpu.set(1, 18, stkRow .. "        ")
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
      |  if fiDirty or n % 20 == 0 then
      |    fiDirty = false
      |    fiPaint()
      |  end
      |  if dgDirty or n % 20 == 0 then
      |    dgDirty = false
      |    dgPaint()
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
  // OCLJ_PROBE=grace -- the grace-expiry probe (milestone k6).
  //
  // WHAT IT ASKS.  OC's checkDeadline grants a program that catches the first
  // "too long without yielding" a 0.5 s grace (deadline = deadline + 0.5) and
  // re-arms itself as a count=1 hook for the rest of the resume.  A program
  // that keeps running past that grace WITHOUT yielding must then bring the
  // machine down -- the question is HOW.  On stock OpenComputers the sentinel
  // unwinds the sandbox, main() turns it into a string, pcall(main) returns
  // it, and the machine stops with lastError "too long without yielding".
  // The 2026-09-19 load matrix (scratchpad/wd-load) saw our kernel die 9/9
  // with "kernel panic: this is a bug ..." instead, and the source-level
  // route runs through that re-arm: debug.sethook(co, f, "", 1) is per-thread
  // on PUC Lua and GLOBAL on LuaJIT, so it hooks the kernel thread too, and
  // checkDeadline then raises on the way to disarm(), inside pcall(main), and
  // once more in pcallTimeoutCheck, outside it.  Load only made that route
  // likely; this probe makes it certain, with no load at all:
  //
  //     pcall(function() while true do end end)   -- catch the first sentinel
  //     local t = computer.uptime()
  //     while computer.uptime() - t < 1 do end     -- past the grace, no yield
  //
  // k6 PASSES iff the machine stopped AND lastError says "too long without
  // yielding" AND not "kernel panic".  Expected to FAIL on the current kernel
  // and PASS on OCLJ_NATIVE=stock: it is the fail-first check for patcher
  // site 12 (drop the re-arm), and must be seen failing before that fix is
  // believed.
  // ------------------------------------------------------------------ //

  val GraceAutorunLua: String =
    """-- OCLJ_PROBE=grace: heartbeat plus the grace-expiry program.  Nothing
      |-- else from the default autorun -- no suite, no probes, no timer that
      |-- could be pending when the deadline fires.
      |local component = require("component")
      |local event = require("event")
      |local computer = require("computer")
      |local nonce = string.format("%.4f-%d", computer.uptime(), math.random(100000, 999999))
      |local n = 0
      |local stage = "armed"
      |local function paint()
      |  component.gpu.set(1, 15, "OCLJNONCE=" .. nonce .. " OCLJCTR=" .. n .. "        ")
      |  component.gpu.set(1, 16, "OCLJGRACE=" .. stage .. "        ")
      |end
      |-- Started by a SIGNAL from the harness once (d) has passed, like the stk
      |-- and fi probes, so the harness knows when it began and nothing races
      |-- the boot.  Dispatched from OpenOS's event loop like any handler.
      |event.listen("ocljgrace", function()
      |  -- The row is painted BEFORE the overrun: nothing between the first
      |  -- catch and the end of the spin may yield, and gpu.set can.
      |  stage = string.format("spinning/%.2f", computer.uptime())
      |  pcall(paint)
      |  local okd, err = pcall(function() while true do end end)
      |  -- Caught the first "too long without yielding".  checkDeadline has
      |  -- moved the deadline 0.5 s out and re-armed at count=1; keep running
      |  -- past that WITHOUT yielding: no os.sleep, no print, no component
      |  -- call.  computer.uptime is the host function itself (machine.lua's
      |  -- libcomputer.uptime = computer.uptime), a direct call.
      |  local t = computer.uptime()
      |  while computer.uptime() - t < 1 do end
      |  -- Only reached if the machine SURVIVED the expiry, which neither
      |  -- kernel should allow.
      |  stage = string.format("survived/%s/%s/%.2f", tostring(okd),
      |    (tostring(err):gsub("[ /]", "_")), computer.uptime())
      |  pcall(paint)
      |  return false
      |end)
      |event.timer(0.05, function()
      |  n = n + 1
      |  pcall(paint)
      |end, math.huge)
      |""".stripMargin

  /** ocelot-brain's WARN-and-above log lines, captured in-process (grace mode). */
  val kernelLog = new java.util.concurrent.CopyOnWriteArrayList[String]()

  /**
    * Hook a capturing appender onto log4j's root logger.  "Kernel crashed.
    * This is a bug!" is Ocelot.log.warn in NativeLuaArchitecture.runThreaded
    * (:288), and under ocelot-brain's default log4j configuration the root
    * level is ERROR, so that line is DROPPED unless the JVM runs with
    * -Dlog4j2.level=WARN (the wd-load rig delivered it through
    * JAVA_TOOL_OPTIONS).  Lowering the root level here makes the probe
    * self-sufficient: the line lands on the console (smoke.log) AND in
    * kernelLog, so k6's message can quote it.  Grace mode only; the default
    * run never calls this.
    */
  def installKernelLogCapture(): String = {
    try {
      import org.apache.logging.log4j.Level
      import org.apache.logging.log4j.core.{LogEvent, LoggerContext}
      import org.apache.logging.log4j.core.appender.AbstractAppender
      import org.apache.logging.log4j.core.config.Property
      val app = new AbstractAppender("ocljit-kernel-log", null, null, true, Property.EMPTY_ARRAY) {
        override def append(e: LogEvent): Unit =
          kernelLog.add(e.getLevel.toString + " [" + e.getThreadName + "] " + e.getMessage.getFormattedMessage)
      }
      app.start()
      val ctx = LoggerContext.getContext(false)
      val cfg = ctx.getConfiguration
      val root = cfg.getRootLogger
      val was = root.getLevel
      if (was.isMoreSpecificThan(Level.WARN)) root.setLevel(Level.WARN)
      cfg.addAppender(app)
      root.addAppender(app, Level.WARN, null)
      ctx.updateLoggers()
      "ok (root level " + was + " -> " + root.getLevel + ")"
    } catch { case e: Throwable => "UNAVAILABLE: " + e }
  }

  /**
    * The probe itself: signal the program, watch the machine until it stops
    * (or survives, or 40 s pass), then say exactly how it ended.  Reads only
    * the screen and Machine's own accessors -- never the Lua state, which a
    * machine mid-overrun is using.
    */
  def graceExpiryProbe(ws: Workspace, computer: Case, screen: Screen,
                       kernelMode: String, nativeMode: String): Unit = {
    val m = computer.machine
    p("--- grace-expiry probe: kernel=" + kernelMode + " native=" + nativeMode + " ---")
    val tSig = System.currentTimeMillis()
    val upSig = m.upTime()
    val queued = m.signal("ocljgrace")
    p(f"grace: signal ocljgrace queued=$queued at uptime $upSig%.2f")
    // Bounded at 40 s of 25 ms ticks.  The program itself is 5 s (timeout)
    // + 0.5 s (grace) + whatever the count=1 hook costs the spin, so 40 s is
    // a ceiling, not an estimate; the loop leaves the moment the machine
    // stops, or the row says the program outlived the expiry.
    var row = parse(nonEmptyScreen(screen), "OCLJGRACE")
    var lastRow = row
    var tSpin = -1L
    var upSpin = -1.0
    var k = 0
    while (k < 1600 && m.isRunning && !row.startsWith("survived")) {
      ws.update(); Thread.sleep(25); k += 1
      if (k % 4 == 0) {
        row = parse(nonEmptyScreen(screen), "OCLJGRACE")
        if (row != lastRow) {
          p("grace: OCLJGRACE=" + row + " after " + (System.currentTimeMillis() - tSig) + " ms")
          lastRow = row
        }
        if (tSpin < 0 && row.startsWith("spinning")) { tSpin = System.currentTimeMillis(); upSpin = m.upTime() }
      }
    }
    val tStop = System.currentTimeMillis()
    // A few more ticks so a death settles: OC paints its "Unrecoverable
    // Error" onto the screen when the machine stops, and the log line is
    // written by the executor thread that is still unwinding.
    var k2 = 0
    while (k2 < 20) { ws.update(); Thread.sleep(25); k2 += 1 }
    val running = m.isRunning
    val lastErr = m.lastError
    val err = if (lastErr == null) "<null>" else lastErr
    row = parse(nonEmptyScreen(screen), "OCLJGRACE")
    val captured = kernelLog.toArray(new Array[String](0)).toList
    val crashed = captured.filter(_.contains("Kernel crashed"))
    p("GRACE-TIMELINE: kernel=" + kernelMode + " native=" + nativeMode +
      " queued=" + queued + " ticks=" + k +
      " spin_seen_ms=" + (if (tSpin < 0) -1L else tSpin - tSig) + f" spin_up=$upSpin%.2f" +
      " spin_to_stop_ms=" + (if (tSpin < 0) -1L else tStop - tSpin) +
      " running=" + running + " lastError=" + err + " row=" + row +
      " log_lines=" + captured.size + " kernel_crashed_lines=" + crashed.size)
    captured.foreach { s => s.linesIterator.foreach(l => p("  ocelot-brain log: " + l)) }
    p("SCREEN AT END OF GRACE PROBE (running=" + running + "):")
    println(nonEmptyScreen(screen))
    // The clean message alone would also accept the vacuous path where the
    // FIRST raise escaped the program's pcall and the machine died at the
    // deadline D instead of at D + grace: that is a clean crash too, and it
    // proves nothing about the grace.  So the death must come no earlier
    // than the timeout itself (ocljit.conf timeout: 5.0), measured from the
    // spin row.  OCLJ_GRACE_MIN_MS overrides the bound, which is how the
    // clause is shown in its failing direction (99999 -> FAIL).
    val graceMinMs = Option(System.getenv("OCLJ_GRACE_MIN_MS")).map(_.trim).filter(_.nonEmpty).map(_.toLong).getOrElse(5000L)
    val outlived = tSpin >= 0 && (tStop - tSpin) >= graceMinMs
    val clean = !running && err.contains("too long without yielding") && !err.contains("kernel panic") && outlived
    val warnQuote = crashed.headOption.map(_.linesIterator.map(_.trim).filter(_.nonEmpty).take(2).toList.mkString(" | "))
    milestone("k6-grace-expiry-crashes-cleanly", clean,
      "kernel=" + kernelMode + " native=" + nativeMode +
        ":  pcall(while true do end) caught, then 1 s more without yielding -> running=" + running +
        "  lastError='" + err + "'" +
        "  OCLJGRACE=" + row +
        "  spinning->stop=" + (if (tSpin < 0) "?" else (tStop - tSpin) + " ms") +
        "  outlived the first deadline (>= " + graceMinMs + " ms)=" + outlived +
        (warnQuote match {
          case Some(w) => "  ocelot-brain WARN: '" + w + "'"
          case None => "  (no 'Kernel crashed' WARN captured)"
        }) +
        (if (clean) "   (a clean machine crash, as stock OpenComputers gives)"
         else if (running) "   <- the machine SURVIVED running past the grace: the expiry was never enforced"
         else if (err.contains("kernel panic")) "   <- KERNEL PANIC, not a clean crash: the sentinel escaped pcall(main) (the count=1 re-arm hooked the kernel thread)"
         else if (!outlived) "   <- clean message but the machine died BEFORE the timeout had elapsed: the first raise escaped the program's pcall, so the grace was never exercised"
         else "   <- stopped with an unexpected error"))
  }

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
    if (probeMode.nonEmpty && probeMode != "grace")
      die("OCLJ_PROBE must be unset or 'grace', not '" + probeMode + "'")
    if (probeMode == "grace") {
      p("!! OCLJ_PROBE=grace: boot as usual, then ONLY the grace-expiry probe (k6);")
      p("!! no suite, no persist.  ocelot-brain log capture: " + installKernelLogCapture())
    }
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
    // THE RAM TIER IS A KNOB (OCLJ_RAM_TIER -> -Docljit.ramtier), default
    // the 3.5 the harness has always used.  Every memory figure this run
    // prints is a fraction of it, and the one question the mem-1 lines exist
    // to answer -- what resident trace metadata costs a machine that cannot
    // afford it -- has no answer at 1024 KB.  Refused rather than defaulted
    // on a misspelling: a run that quietly measured the wrong tier would be
    // filed under the tier it was asked for.
    val ramTierName = System.getProperty("ocljit.ramtier", "threehalf")
    val ramTier: ExtendedTier.ExtendedTier = ramTierName match {
      case "one"       => ExtendedTier.One
      case "onehalf"   => ExtendedTier.OneHalf
      case "two"       => ExtendedTier.Two
      case "twohalf"   => ExtendedTier.TwoHalf
      case "three"     => ExtendedTier.Three
      case "threehalf" => ExtendedTier.ThreeHalf
      case other => die("ocljit.ramtier must be one|onehalf|two|twohalf|three|threehalf, not '" + other + "'")
    }
    computer.inventory(2) = new Memory(ramTier)
    val ramTierKB = totoro.ocelot.brain.Settings.get.ramSizes(ramTier.id)
    p("RAM tier = " + ramTierName + " (" + ramTierKB + " KB as the sandbox sees it; x ramScale " +
      totoro.ocelot.brain.Settings.get.ramScaleFor64Bit + " real bytes, plus kernelMemory)")

    // The hard disk is bound to a real directory we pre-populate, so OpenOS
    // finds autorun.lua when it mounts it.
    val diskDir: Path = Files.createTempDirectory("ocljit-smoke-hdd")
    // OCLJ_PROBE=grace plants the probe's own autorun instead: heartbeat plus
    // the grace-expiry program, nothing else.  The suite files planted below
    // are still written (the planting code is shared) but nothing reads them.
    val autorunSrc = if (probeMode == "grace") GraceAutorunLua else AutorunLua
    Files.write(diskDir.resolve("autorun.lua"), autorunSrc.getBytes(StandardCharsets.UTF_8))
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
    // `nativeMode` is an object-level val now (it moved up with the
    // architecture switch, which planting needs too), so this could read it
    // directly.  Left as the property for one reason: this line runs during
    // PLANTING and the value it wants is "is this the stock baseline", which is
    // exactly what it spells out.
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
    p("hdd real path = " + diskDir + " (autorun.lua planted, " + autorunSrc.length + " bytes" +
      (if (probeMode == "grace") ", the OCLJ_PROBE=grace variant" else "") + ")")

    computer.inventory(4) = Loot.LuaBiosEEPROM.create()
    computer.inventory(5) = Loot.OpenOsFloppy.create()
    // Tier.Three (160x50), not Tier.One (50x16).  Results come back by reading
    // fixed screen rows, and a 64-hex sha256 digest does not fit on a 50-column
    // row -- nor do nine benchmark rows plus the existing nonce/gate/deadline
    // block fit in 16.  The GPU is already Tier.Three.
    val screen = ws.add(new Screen(Tier.Three))
    computer.connect(screen)

    // REGISTER FIRST, AND IT IS NOT OPTIONAL. MutableProcessor.setArchitecture
    // checks the class against MachineAPI's registry and throws
    // "Unsupported processor type." for anything absent (MutableProcessor.scala:26-29).
    // ocelot-brain registers its own three during Ocelot.initialize; ours is a
    // fourth that nothing else knows about.
    if (nativeMode == "additive") ocljit.arch.OCLuaJITStateFactory.register()
    cpu.setArchitecture(expectedArch)
    p("architecture pinned to " + expectedArch.getName + "   (ocljit.native=" + nativeMode + ")")

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
    // The run's last lines, shared by the default path (the end of main) and
    // the OCLJ_PROBE=grace path, which leaves right after (d).
    def finish(): Nothing = {
      p("FINGERPRINT: " + fp)
      p(s"CHECKS: $checks   FAILURES: $failures   WALL: ${secs}s")
      p("VERDICT: " + (if (failures == 0) "PASS" else "FAIL"))
      p("=" * 72)
      try Ocelot.shutdown() catch { case _: Throwable => }
      System.exit(if (failures > 0) 1 else 0)
      throw new RuntimeException()
    }

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
    // --- GC PACING, for the rate-contest experiment --------------------
    //
    // WHY THIS KNOB AND NOT THE OTHER ONES.  memory-accounting.md section 8
    // shows the collector losing a RATE contest: lj_gc_step gets a fixed
    // budget lim = (GCSTEPSIZE/100)*stepmul (lj_gc.c:734) = 2000 at the
    // defaults, while lj_gc.c:737-738 charges it everything allocated since
    // the last step and :752 repays only GCSTEPSIZE = 1024 bytes.  Work per
    // byte allocated is therefore ~stepmul/100, and STEPMUL IS THE ONLY KNOB
    // THAT CHANGES IT -- GCSTEPSIZE cancels out of that ratio (it sets
    // granularity, not rate), and gc.pause is read only at lj_gc.c:742/:801,
    // both of which set the START threshold of the NEXT cycle.  Under
    // sustained churn the collector never reaches GCSpause, so pause is inert
    // in exactly the regime being tested.  It is settable here anyway, so a
    // run can DEMONSTRATE that rather than assert it.
    //
    // THE OLD VALUE IS THE CONTROL AND IT MATTERS.  collectgarbage('setstepmul')
    // returns the previous setting (lj_api.c:1272-1280).  It must read 200 --
    // LUAI_GCMUL at luaconf.h:94, seeded at lj_state.c:309.  Without that
    // readback a null result is unattributable: "pacing did not help" and "the
    // knob never took" look identical in the row.
    //
    // NOT stepmul = 0: lj_gc.c:735-736 turns that into LJ_MAX_MEM, i.e. a
    // whole stop-the-world cycle inside one bytecode.  The property is ignored
    // unless positive.
    //
    // This runs on the RAW state, pre-boot, where collectgarbage is still
    // reachable (machine.lua:1526 uses it).  It is NOT reachable from the
    // sandbox -- machine.lua:737 omits it from the global table -- which is
    // why a SHIPPED version of this would have to live in lj52_setallocf or
    // the patched kernel, never in user code.
    val gcStepMul = Integer.getInteger("ocljit.gcstepmul", 0).intValue()
    val gcPause = Integer.getInteger("ocljit.gcpause", 0).intValue()
    if (gcStepMul > 0) {
      val was = evalStrLocked(computer.machine, mLua,
        "local ok, old = pcall(collectgarbage, 'setstepmul', " + gcStepMul + ") " +
        "return ok and tostring(old) or ('ERR:' .. tostring(old))")
      p("GC PACE: setstepmul=" + gcStepMul + "  (was " + was + ")")
      milestone("gc-pace-stepmul-took", was == "200",
        "collectgarbage('setstepmul', " + gcStepMul + ") returned the previous value " + was +
          (if (was == "200") "" else "   <- expected 200 (LUAI_GCMUL); the knob did NOT take, so this run measures nothing"))
    }
    if (gcPause > 0) {
      val was = evalStrLocked(computer.machine, mLua,
        "local ok, old = pcall(collectgarbage, 'setpause', " + gcPause + ") " +
        "return ok and tostring(old) or ('ERR:' .. tostring(old))")
      p("GC PACE: setpause=" + gcPause + "  (was " + was + ")")
      milestone("gc-pace-pause-took", was == "200",
        "collectgarbage('setpause', " + gcPause + ") returned the previous value " + was +
          (if (was == "200") "" else "   <- expected 200 (LUAI_GCPAUSE); the knob did NOT take"))
    }
    p("GC PACE: stepmul=" + (if (gcStepMul > 0) gcStepMul.toString else "default(200)") +
      "  pause=" + (if (gcPause > 0) gcPause.toString else "default(200)"))

    val tBootStart = System.currentTimeMillis()

    // --- (c) OpenOS boots to a shell ----------------------------------
    // THE TIMEOUT IS SIZED FOR THE SLOWEST LEGITIMATE ARM, because it only
    // binds when something is wrong: the loop leaves the moment the screen
    // shows what it waits for, so a generous cap costs the fast arms nothing.
    //
    // It was a flat 600 ticks (15 s). Ample with the watchdog kernel, and NOT
    // ample under OpenComputers' standing count hook, which stops traces being
    // entered and makes boot roughly a hundred times slower. Measured in BOTH
    // stock-kernel arms on 2026-09-16: the shell appeared, the autorun's first
    // line had not, the loop left on the timeout, and (d) then failed with
    // counter -1 -- so the suite reported SMOKE FAIL for a documented control
    // arm, for a timing reason, with nothing actually wrong.
    val bootCapTicks = if (kernelMode == "watchdog") 600 else 3000
    var i = 0
    var booted = false
    while (i < bootCapTicks && computer.machine.isRunning && !booted) {
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
    // REPORT WHICH WAY THE LOOP LEFT. It waits for the prompt AND the autorun's
    // first line, but this milestone asserts only the prompt -- so a run that
    // timed out with the shell up passed HERE and failed later, describing a
    // symptom instead of its cause.
    milestone("c-openos-shell", txtA.contains("/home #"),
      "OpenOS shell prompt on screen (" + txtA.split("\n").length + " non-empty lines)" +
        (if (booted) "" else "   <- loop hit its " + bootCapTicks +
          "-tick cap without the autorun line; expect (d) to fail"))

    // --- (d) the autorun closure is alive and counting ----------------
    val nonceA = parse(txtA, "OCLJNONCE")
    val ctrA1 = try parse(txtA, "OCLJCTR").toInt catch { case _: Throwable => -1 }
    // UNTIL IT ADVANCES, not for a fixed 60 ticks. 60 ticks is 1.5 s: several
    // counter ticks with the watchdog kernel, and possibly none at all under
    // the standing hook. Same rule as the boot cap -- wait on the condition,
    // and let the timeout be the generous part.
    val dCapTicks = if (kernelMode == "watchdog") 300 else 2000
    var j = 0
    var ctrA2 = -1
    while (j < dCapTicks && computer.machine.isRunning && !(ctrA1 > 0 && ctrA2 > ctrA1)) {
      ws.update(); Thread.sleep(25); j += 1
      if (j % 10 == 0)
        ctrA2 = try parse(nonEmptyScreen(screen), "OCLJCTR").toInt catch { case _: Throwable => -1 }
    }
    val txtA2 = nonEmptyScreen(screen)
    ctrA2 = try parse(txtA2, "OCLJCTR").toInt catch { case _: Throwable => -1 }
    milestone("d-autorun-counter-live", nonceA != "<missing>" && ctrA1 > 0 && ctrA2 > ctrA1,
      s"nonce=$nonceA counter $ctrA1 -> $ctrA2 in $j of $dCapTicks ticks" +
        (if (ctrA1 > 0 && ctrA2 > ctrA1) "" else "   <- did not advance within the cap"))
    if (nonceA == "<missing>")
      die("autorun.lua never ran: no OCLJNONCE on screen. OpenOS did not mount the hard disk, " +
        "or /etc/filesystem.cfg disabled autorun.")

    // --- (k6) OCLJ_PROBE=grace: the grace-expiry probe, and nothing after it --
    if (probeMode == "grace") {
      graceExpiryProbe(ws, computer, screen, kernelMode, nativeMode)
      finish()
    }

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

    // --- (mem-1) resident traces at the shell, after boot -----------------
    // Here and not right after (d): the trace counter is detached now, so the
    // ticks this read spends cannot move the k2 number.  Only 12 of them: the
    // deadline probe's spin starts 4 s of uptime after the autorun ran and k1
    // begins about 2 s after it (WDTIMELINE-K1: nonce_up vs up_k1_start), so
    // a longer window would tick the machine INTO the spin and this read
    // would then wait out the timeout instead of measuring a shell.  Phase 0
    // (2 s after the autorun) may still fire inside the window; the OCLJB01
    // status on the line says whether it did.
    // Our natives only, like jn-1: the stock PUC 5.2 has no traces to be
    // resident, and its _OCLJ_JITSTATS-less read would SKIP every stock run.
    val memAfterBoot = nativeMode != "stock" &&
      residentTracesRead(ws, computer.machine, screen, mLua, ramTierName, "after-boot", ticks = 12)

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
    // WDTIMELINE (roadmap row 109): per-run discrimination of fires=0.  The
    // probe is due at the autorun's uptime + 6 s, and the nonce IS that uptime
    // (autorun: string.format("%.4f-%d", computer.uptime(), ...)).  While the
    // probe spins nothing else on the machine runs, so OCLJCTR FREEZES with
    // OCLJDEADLINE still "pending"; while the probe has not yet run, OCLJCTR
    // keeps advancing under the same "pending".  The row alone cannot tell
    // those apart; the counter can.  Diagnostic only: k1's condition, cap and
    // sampling cadence are unchanged.
    //   Measured 2026-09-19 (wd-load/instrument/ff-1-watchdog): the freeze is
    // NOT the spin alone.  The autorun's 4 s walk timer (OCLJW01: 132 indirect
    // fs.list calls, one host tick each, 6.05 s of uptime) runs from nonce+4
    // and the probe dispatches in the same resume when it ends, with no
    // heartbeat between, so freeze_up lands on nonce+4 and freeze_ms is walk
    // plus spin.  Under load the walk's wall time inflates and the spin's does
    // not, so freeze_ms cannot be read as watchdog lateness.  exec_run_ms is
    // the spin itself: the longest run of consecutive samples with
    // isExecuting=true, which the walk (a yield per fs.list) cannot produce.
    // OpenOS timers catch up (event.lua: timeout += interval), so after the
    // spin the heartbeat bursts at about one per tick and hb_per_s is an
    // average over both regimes.
    val tK1 = System.currentTimeMillis()
    val upK1 = computer.machine.upTime()
    val nonceUp = try nonceA.split("-")(0).toDouble catch { case _: Throwable => -1.0 }
    val dueUp = if (nonceUp >= 0) nonceUp + 6.0 else -1.0
    var ctrK1 = try parse(nonEmptyScreen(screen), "OCLJCTR").toInt catch { case _: Throwable => -1 }
    val ctrK1Start = ctrK1
    var tCtrMoved = tK1
    var upCtrMoved = upK1
    var frzMs = 0L
    var frzStartMs = -1L
    var frzUp = -1.0
    var execSamples = 0
    var execTrue = 0
    var exRunStart = -1L
    var exRunStartUp = -1.0
    var exRunMs = 0L
    var exRunStartMs = -1L
    var exRunUp = -1.0
    var rowSeenMs = if (txtA.contains("OCLJDEADLINE=")) tBootShell - t0 else -1L
    var kd = 0
    var dlRes = parse(nonEmptyScreen(screen), "OCLJDEADLINE")
    while (kd < 600 && computer.machine.isRunning && (dlRes == "pending" || dlRes == "<missing>")) {
      ws.update(); Thread.sleep(25); kd += 1
      if (kd % 10 == 0) {
        val t = nonEmptyScreen(screen)
        dlRes = parse(t, "OCLJDEADLINE")
        val now = System.currentTimeMillis()
        if (rowSeenMs < 0 && dlRes != "<missing>") rowSeenMs = now - t0
        execSamples += 1
        if (computer.machine.isExecuting) {
          execTrue += 1
          if (exRunStart < 0) { exRunStart = now; exRunStartUp = computer.machine.upTime() }
          if (now - exRunStart >= exRunMs) { exRunMs = now - exRunStart; exRunStartMs = exRunStart - t0; exRunUp = exRunStartUp }
        } else exRunStart = -1L
        val c = try parse(t, "OCLJCTR").toInt catch { case _: Throwable => -1 }
        if (c != ctrK1) { ctrK1 = c; tCtrMoved = now; upCtrMoved = computer.machine.upTime() }
        else if (now - tCtrMoved > frzMs) { frzMs = now - tCtrMoved; frzStartMs = tCtrMoved - t0; frzUp = upCtrMoved }
      }
    }
    val tK1End = System.currentTimeMillis()
    val frzOpen = frzMs > 0 && (tK1End - tCtrMoved) >= frzMs
    // "Open" = the longest exec run reached the last sample AND the loop left
    // without a result.  The second clause is load-bearing: in a nominal run
    // the sample that sees the row resolve can also catch the machine inside
    // the heartbeat's catch-up burst (wd-load/instrument/ff-3-watchdog-final:
    // exec_run_open=true with exec_at_exit=false), which is not the spin
    // still going.  The probe60 fixture run (ff-4-probe60) reads false.
    val exRunOpen = exRunStart >= 0 && (exRunStart - t0) == exRunStartMs &&
      (dlRes == "pending" || dlRes == "<missing>")
    val walkK1 = parse(nonEmptyScreen(screen), "OCLJW01")
    p("WDTIMELINE-K1: kernel=" + kernelMode + " jit=" + jitMode + " native=" + nativeMode +
      " k1_start_ms=" + (tK1 - t0) + " k1_ms=" + (tK1End - tK1) + " k1_ticks=" + kd + " k1=" + dlRes +
      " k1_resolved_ms=" + (if (dlRes == "pending" || dlRes == "<missing>") -1L else tK1End - t0) +
      " row_seen_ms=" + rowSeenMs +
      f" nonce_up=$nonceUp%.2f due_up=$dueUp%.2f up_k1_start=$upK1%.2f up_k1_end=${computer.machine.upTime()}%.2f" +
      " ctr=" + ctrK1Start + "->" + ctrK1 +
      f" hb_per_s=${if (tK1End > tK1 && ctrK1 >= 0 && ctrK1Start >= 0) (ctrK1 - ctrK1Start) * 1000.0 / (tK1End - tK1) else -1.0}%.2f" +
      f" freeze_ms=$frzMs freeze_start_ms=$frzStartMs freeze_up=$frzUp%.2f freeze_open=$frzOpen" +
      f" exec_run_ms=$exRunMs exec_run_start_ms=$exRunStartMs exec_run_up=$exRunUp%.2f exec_run_open=$exRunOpen" +
      " exec_pct=" + (if (execSamples > 0) execTrue * 100 / execSamples else -1) +
      " exec_at_exit=" + computer.machine.isExecuting + " walk=" + walkK1 +
      " running=" + computer.machine.isRunning +
      " lastError=" + computer.machine.lastError)
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
    var wdQuiet = false
    val tQ0 = System.currentTimeMillis()
    var tQ1 = tQ0
    val wdStats = {
      // quiesced() is kept as a DIAGNOSTIC only.  It reports whether the
      // machine looked idle; it does not make the read safe, and believing it
      // did cost about one run in four.  evalStrLocked is what makes it safe.
      wdQuiet = quiesced(computer.machine, "the watchdog stats read-out")
      tQ1 = System.currentTimeMillis()
      evalStrLocked(computer.machine, mLua,
        "local f, r, x, dp, h = _OCLJ_WATCHDOG.stats() return f .. '/' .. r .. '/' .. x .. '/' .. dp .. '/' .. tostring(h)")
    }
    val tQ2 = System.currentTimeMillis()
    val wdFires = try wdStats.split("/")(0).toInt catch { case _: Throwable => -1 }
    p("WATCHDOG STATS: fires/refires/filtered/depth/hooked = " + wdStats)
    // The second half of the timeline: what the shim says, and how long the
    // locked read waited.  evalStrLocked takes the machine's monitor, which
    // Machine.run holds for the whole resume (ocelot-brain Machine.scala:907),
    // so a probe still spinning here either ends first (a late fire, and then
    // fires>=1 on this line) or holds this line off the log until OCLJ_TIMEOUT.
    // A PRINTED fires=0 is therefore never "the loop was still running".
    p("WDTIMELINE: kernel=" + kernelMode + " jit=" + jitMode + " native=" + nativeMode +
      " k1=" + dlRes + " k1_ticks=" + kd + " k1_ms=" + (tK1End - tK1) +
      " freeze_ms=" + frzMs + " freeze_open=" + frzOpen + " exec_run_ms=" + exRunMs +
      " ctr=" + ctrK1Start + "->" + ctrK1 +
      " quiesced=" + wdQuiet + " quiesce_ms=" + (tQ1 - tQ0) + " read_ms=" + (tQ2 - tQ1) +
      " exec_at_read=" + computer.machine.isExecuting +
      " stats(fires/refires/filtered/depth/hooked)=" + wdStats +
      " k2_stops=" + stops + " running=" + computer.machine.isRunning +
      " lastError=" + computer.machine.lastError + " wall_s=" + secs)
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

    // --- (jn-1) the jnlua resume-error line, through jnlua ----------------
    // Same quiescent moment as the k5 read, same monitor.  Our natives only:
    // the stock PUC 5.2 native is OC's own jnlua build, unpatched, and would
    // report the thread -- a known shape, not a control worth a milestone.
    if (nativeMode != "stock") jnluaResumeErrorProbe(computer.machine, mLua)

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
    else {
      // OUR VM UNDER THE STANDING HOOK CANNOT FINISH THIS, AND THAT IS THE
      // POINT OF THE ARM.  hook-vs-jit.md exists to show what OpenComputers'
      // standing count hook costs a JIT: measured, a sandbox loop goes from
      // 0.0047 s to 0.47 s.  At that factor the mandelbrot reference does not
      // fit inside OC's deadline, so the cell reports
      // too_long_without_yielding -- and until now that failed the milestone
      // and so failed the whole run, for a documented control configuration
      // behaving exactly as documented.
      //
      // The deadline is ACCEPTED here, not the checksum WAIVED.  What p0
      // defends against is a FAST WRONG ANSWER, and that defence is intact:
      // any checksum that is neither the published reference nor the deadline
      // still fails.  The same shape as k5-baseline-has-no-watchdog and
      // m1-baseline-has-no-mcode, which assert the absence that defines a
      // baseline rather than pretending the baseline behaves like the product.
      val stockKernelOnOurs = nativeMode != "stock" && kernelMode == "stock"
      val deadlineBit = bCheck == "too_long_without_yielding"
      val ok = checkOk || (stockKernelOnOurs && deadlineBit)
      milestone("p0-compute-checksum", ok,
        "mandelbrot CHECK=" + bCheck + " (published reference 37904620), " + bSecs + " s" +
          (if (checkOk) ""
           else if (ok) "   <- the standing hook ran it past the deadline, which is what this arm is FOR"
           else "   <- wrong or missing: this cell's time means nothing"))
    }

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
    val (mc0, mcCap, tr0, jitOn, lv0) =
      if (quiesced(computer.machine, "the mcode read-out")) jitStatsLocked(computer.machine, mLua)
      else (-1L, -1L, -1, false, -1)
    p("JIT MEMORY: mcode=" + mc0 + " B of a " + mcCap + " B cap, traces=" + tr0 +
      ", traces_live=" + lv0 + ", jit=" + jitOn + "  (the RAM cap cannot see any of this)")

    // --- the emergency collector, and whether it was even exercised ------
    val (gcArms, gcCollects, gcBailouts, gcRefusals, gcArmed, gcState) =
      if (quiesced(computer.machine, "the GC pressure read-out"))
        gcStatsLocked(computer.machine, mLua)
      else (-1L, -1L, -1L, -1L, false, -1)
    if (gcArms >= 0) {
      p("GC PRESSURE: arms=" + gcArms + " collects=" + gcCollects +
        " bailouts=" + gcBailouts + " refusals=" + gcRefusals +
        " armed=" + gcArmed + " gcstate=" + gcState)
      // Every arm must be PROVEN to have completed a cycle.  The disarm
      // predicate is "currentwhite flipped AND state back at GCSpause"; a
      // shortfall means arms are resolving through the safety valve instead,
      // which is exactly the case the latch exists to prevent.
      milestone("gc-emergency-collects-resolve", gcCollects == gcArms && gcBailouts == 0,
        "arms=" + gcArms + " collects=" + gcCollects + " bailouts=" + gcBailouts +
          (if (gcCollects == gcArms && gcBailouts == 0) ""
           else "   <- an arm did not complete a cycle; the currentwhite latch is not " +
                "seeing flips it should and the disarm argument needs re-deriving"))
      milestone("gc-emergency-not-stuck-armed", !gcArmed,
        "armed=" + gcArmed + " at rest" +
          (if (!gcArmed) "" else "   <- the window is still open: stepmul is 0 and EVERY " +
                                 "lj_gc_step from any site is unbounded"))
    } else {
      p("GC PRESSURE: _OCLJ_GCSTATS absent (stock native, or an older DLL)")
    }
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
    val (mc1, _, tr1, _, lv1) = jitStatsLocked(computer.machine, mLua)
    val flushed = mc0 > 0 && mc1 == 0
    p("JIT MEMORY after persist: mcode=" + mc1 + " B, traces=" + tr1 + ", traces_live=" + lv1 +
      (if (flushed) "   <- FLUSHED: the save discarded every compiled trace"
       else if (mc0 > 0) "   (traces survived the save)" else ""))
    // OURS, not "luajit": the additive arm is the same VM behind a different
    // JNI symbol family, so it has mcode and traces exactly as the dropin does.
    // Gating on the literal "luajit" silently SKIPPED this milestone for the
    // one shape we actually ship -- and a skipped milestone reads as a pass.
    if (nativeMode != "stock" && kernelMode == "watchdog" && jitMode == "on")
      // Not an assertion about WHICH way it goes -- both are legitimate.  Up
      // to 2026-09-22 the serializer flushed every trace whenever the thread
      // was parked in a generic-for loop (an idle OpenOS always is); since
      // then it reads a compiled loop head through GCtrace.startins and
      // flushes nothing, so a save leaves the machine WARM.  What is asserted
      // is that we can TELL, so the answer is recorded rather than assumed.
      milestone("m2-persist-flush-observed", mc0 > 0 && mc1 >= 0,
        "mcode " + mc0 + " -> " + mc1 + " B, traces " + tr0 + " -> " + tr1 +
          (if (flushed) "  (a world save leaves the machine COLD; it must recompile -- a pre-2026-09-22 serializer)"
           else "  (traces survived the save: the machine stays warm)"))

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
      var lvBack = 0
      while (mr < 120 && computer.machine.isRunning && mcBack == 0L) {
        ws.update(); Thread.sleep(25); mr += 1
        if (mr % 10 == 0) {
          var qq = 0
          while (computer.machine.isExecuting && qq < 200) { Thread.sleep(5); qq += 1 }
          // LOCKED.  This was the one raw-state read left outside the
          // machine's monitor, and the isExecuting spin above is not an
          // interlock (see evalStrLocked).  It read -1/-1 on one run in three
          // and the ORIGINAL machine -- the one the stk phase below still
          // needs -- died of Error.InternalError before that phase began.
          val s = jitStatsLocked(computer.machine, mLua); mcBack = s._1; trBack = s._3; lvBack = s._5
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
        mcBack + " B / " + trBack + " traces (" + lvBack + " live) after " + mr + " ticks (~" + (mr * 25) +
        " ms).  An idle machine has nothing to recompile; recovery under load is" +
        " measured by the benchmark harness, not by this line.")
    }

    // --- (mem-1) resident traces after the first save ---------------------
    // After m3's recovery watch, so that watch sees the machine the save left
    // and not one this read has ticked and collected.
    val memAfterSave = nativeMode != "stock" &&
      residentTracesRead(ws, computer.machine, screen, mLua, ramTierName, "after-first-save")

    val kernelKey = computer.machine.node.address + "_kernel"
    val blob = try findBlob(nbt, kernelKey) catch { case _: Throwable => null }
    milestone("f1-persist-blob", persistOk && blob != null && blob.length > 0,
      s"persist ok=$persistOk err=$persistErr key=$kernelKey blobBytes=" +
        (if (blob == null) -1 else blob.length) + s" in ${persistMs}ms")

    // (f1b) ANTI-VACUITY: did the blob actually carry a wrapped userdata?
    // userdata.save pushes persistable.getClass.getName, and machine.lua closes
    // over it as the [persistKey] closure's upvalue, so a blob that serialised
    // one necessarily contains that class name as a literal string.  Without
    // this, f7 below would pass vacuously on a run where no proxy was reachable.
    val blobText = if (blob == null) "" else new String(blob, StandardCharsets.ISO_8859_1)
    val udInBlob = blobText.contains("HandleValue")
    milestone("f1b-blob-carries-userdata", udInBlob,
      "persisted blob " + (if (udInBlob) "CONTAINS" else "does NOT contain") +
        " the userdata class name HandleValue; blobBytes=" +
        (if (blob == null) -1 else blob.length))

    val udBefore = parse(nonEmptyScreen(screen), "OCLJUD")
    val ctrBeforeRestore = try parse(nonEmptyScreen(screen), "OCLJCTR").toInt catch { case _: Throwable => -1 }

    // --- (m4) persist-and-continue under load: what an autosave costs ---
    // m2 shows that one save flushes every trace; m3 (below) measures the
    // cold run in a FRESH VM after a restore.  Neither is the steady state of
    // a busy computer on a server: Minecraft autosaves every 900 ticks (45 s)
    // and OpenComputers persists a machine on every chunk save, so the machine
    // that matters is one that is mid-workload, gets flushed, and KEEPS
    // RUNNING in the same VM -- again and again.  So: K in-place saves on the
    // running machine, and for each the first encore run after the flush
    // (cold) and the one after that (re-warmed).
    //
    // Placed AFTER the f3/f7 baselines above are read, because the restore
    // below resumes from the `nbt` taken at f1 and those baselines must not
    // include the minute this block keeps the original machine running.  The
    // extra saves go into fresh compounds; `nbt` is untouched.
    //
    // Every save is taken RIGHT AFTER a fresh encore sample, so it lands in
    // the idle 5 s window rather than blocking behind a running encore (a
    // save that waited for the encore would make that encore's warm number
    // read as "cold").  The ratios are REPORTED, never asserted -- the player
    // picks both the workload and the limit.  The PASS condition is only that
    // the instrument worked: every save succeeded, the flush was observed
    // after each one (mcode == 0, the signature _OCLJ_JITSTATS documents) on
    // the JIT-on arm, and both samples arrived every time.  On the JIT-off arm
    // there is nothing to flush, so the same lines are the control: a delta
    // that shows up there too is not the flush.
    if (nativeMode != "stock" && kernelMode == "watchdog") {
      if (suiteNames.isEmpty || encSeqBefore <= 0) {
        p("m4-persist-and-continue-under-load: SKIP -- no encore workload is running" +
          " (suite=" + (if (suiteNames.isEmpty) "<none>" else suiteNames.mkString(",")) +
          ", encore samples seen=" + encSeqBefore + "), nothing to measure a flush against")
      } else {
        val K = 5
        p("--- (m4) " + K + " in-place saves on the RUNNING machine; encore " + encName +
          " sampled cold and re-warmed after each (warm best = " + encWarm + " s) ---")
        var seqSeen = encSeqBefore
        // Poll for the next encore sample newer than `seqSeen`; returns (secs, seq)
        // or (-1, -1) after the budget.  100 ms cadence against a 5 s period.
        def nextSample(budgetPolls: Int): (Double, Int) = {
          var polls = 0
          var out = (-1.0, -1)
          while (out._2 < 0 && polls < budgetPolls && computer.machine.isRunning) {
            ws.update(); Thread.sleep(25); polls += 1
            if (polls % 4 == 0) {
              val f = parse(nonEmptyScreen(screen), "OCLJENCORE").split("/")
              if (f.length >= 5 && f(1) == "ok") {
                val sq = try f(4).toInt catch { case _: Throwable => -1 }
                val sc = try f(3).toDouble catch { case _: Throwable => -1.0 }
                if (sq > seqSeen) { seqSeen = sq; out = (sc, sq) }
              }
            }
          }
          out
        }
        val persistMsArr = new Array[Long](K)
        val mcBeforeSave = Array.fill(K)(-1L)
        val mcAfterSave = Array.fill(K)(-1L); val trAfterSave = Array.fill(K)(-1)
        val mcAfterWarm = Array.fill(K)(-1L); val trAfterWarm = Array.fill(K)(-1)
        val cold = Array.fill(K)(-1.0); val rewarm = Array.fill(K)(-1.0)
        val seqGap = Array.fill(K)(0)
        var savesOk = 0
        var samples = 0
        // line up on a fresh sample so save 1 lands in the idle window
        nextSample(400)
        for (i <- 0 until K) {
          val nbtK = new NBTTagCompound()
          val (mcPre, _, trPre, _, lvPre) = jitStatsLocked(computer.machine, mLua)
          mcBeforeSave(i) = mcPre
          val t0 = System.currentTimeMillis()
          val ok = try { ws.save(nbtK); true } catch {
            case t: Throwable => p("m4 save " + (i + 1) + " threw " + t); false
          }
          persistMsArr(i) = System.currentTimeMillis() - t0
          if (ok) savesOk += 1
          val (mc1, _, tr1, _, lv1) = jitStatsLocked(computer.machine, mLua)
          mcAfterSave(i) = mc1; trAfterSave(i) = tr1
          val seqAtSave = seqSeen
          val c = nextSample(600)              // 15 s budget for a 5 s period
          if (c._2 > 0) { cold(i) = c._1; samples += 1; seqGap(i) += c._2 - seqAtSave - 1 }
          val w = nextSample(600)
          if (w._2 > 0) { rewarm(i) = w._1; samples += 1; seqGap(i) += w._2 - c._2 - 1 }
          val (mc2, _, tr2, _, lv2) = jitStatsLocked(computer.machine, mLua)
          mcAfterWarm(i) = mc2; trAfterWarm(i) = tr2
          // traces_live alongside traces: the latter is J->freetrace-1 and sat
          // frozen at 468 through the penalty-cache regression, so it cannot
          // tell "nothing recorded" from "everything aborted"; the live count can.
          p("m4 save " + (i + 1) + ": before mcode=" + mcPre + " B traces=" + trPre + " traces_live=" + lvPre +
            "; persist " + persistMsArr(i) + " ms; right after: mcode=" + mc1 + " B traces=" + tr1 + " traces_live=" + lv1 +
            (if (mcPre > 0 && mc1 == 0) " (FLUSHED)" else if (mcPre > 0) " (traces survived)" else "") +
            "; cold=" + cold(i) + " s, re-warmed=" + rewarm(i) + " s" +
            "; after re-warm: mcode=" + mc2 + " B traces=" + tr2 + " traces_live=" + lv2 +
            (if (seqGap(i) != 0) "   <- " + seqGap(i) + " sample(s) skipped by the screen poll" else "") +
            (if (c._2 < 0 || w._2 < 0) "   <- a sample did not arrive within budget" else ""))
        }
        val colds = cold.filter(_ > 0); val warms = rewarm.filter(_ > 0)
        def mean(a: Array[Double]) = if (a.isEmpty) -1.0 else a.sum / a.length
        val coldMean = mean(colds); val coldMax = if (colds.isEmpty) -1.0 else colds.max
        val warmMean = mean(warms)
        val persistMean = persistMsArr.sum.toDouble / K
        def r(x: Double) = if (encWarm > 0 && x > 0) f"${x / encWarm}%.2fx" else "n/a"
        val flushEveryTime = (0 until K).forall(i => mcAfterSave(i) == 0L)
        val tracesBack = (0 until K).forall(i => trAfterWarm(i) > 0)
        // mcode == 0 after a save is only a flush SIGNATURE when there was
        // something to flush; on the jit=off arm it is 0 before and after.
        val hadTraces = (0 until K).exists(i => mcBeforeSave(i) > 0L)
        val flushWord =
          if (!hadTraces) "nothing to flush (mcode 0 before every save)"
          else if (flushEveryTime) "every save FLUSHED the traces (a pre-2026-09-22 serializer)"
          else "traces survived every save=" + (0 until K).forall(i => mcAfterSave(i) > 0L)
        p("m4 summary: warm best " + encWarm + " s; cold mean " + f"$coldMean%.4f" + " s (" + r(coldMean) +
          "), cold max " + f"$coldMax%.4f" + " s (" + r(coldMax) + "); re-warmed mean " + f"$warmMean%.4f" +
          " s (" + r(warmMean) + "); persist mean " + f"$persistMean%.1f" + " ms; " + flushWord +
          "; traces back after the re-warm run every time=" + tracesBack +
          "; cost per save on this encore ~" + f"${(coldMean - encWarm) * 1000}%.1f" + " ms beyond a warm run" +
          " (jit=" + jitMode + ")")
        // Since 2026-09-22 the persist reads a compiled loop head through
        // GCtrace.startins instead of flushing, so mcode == 0 after a save is
        // no longer expected -- the instrument condition is only that the
        // saves happened and the samples arrived.  Whether traces survived is
        // REPORTED (flushWord), and the ratios are what this milestone is for:
        // they are how the penalty-cache blacklisting was first seen.
        val instrumentOk = savesOk == K && samples == 2 * K
        milestone("m4-persist-and-continue-under-load", instrumentOk,
          "jit=" + jitMode + ": " + savesOk + "/" + K + " saves, " + samples + "/" + (2 * K) +
            " samples; " + flushWord +
            "; warm " + encWarm + " s -> cold mean " + f"$coldMean%.4f" + " s (" + r(coldMean) +
            "), re-warmed mean " + f"$warmMean%.4f" + " s (" + r(warmMean) + ")   (ratios REPORTED, not asserted)")
      }
    }

    // --- (mem-1) resident traces after the m4 saves, and the verdict ---
    val memAfterM4 = nativeMode != "stock" &&
      residentTracesRead(ws, computer.machine, screen, mLua, ramTierName, "after-m4-saves")
    val memReads = List(("after-boot", memAfterBoot), ("after-first-save", memAfterSave), ("after-m4-saves", memAfterM4))
    if (nativeMode == "stock") {
      // no line at all: the stock arm has nothing resident to measure
    } else if (memReads.forall(_._2)) {
      milestone("mem-1-resident-traces-at-tier", ok = true,
        "tier=" + ramTierName + " (" + ramTierKB + " KB): every read above produced a number at all three points" +
          " -- the figures are REPORTED on the MEM-1 lines, never asserted")
    } else {
      // NOT a pass and NOT counted: a read that produced no number leaves
      // nothing to report, and a PASS here would read as "the memory looked
      // fine at this tier" to anyone scanning the milestone list.
      val bad = memReads.filter(!_._2).map(_._1).mkString(",")
      p("!! mem-1-resident-traces-at-tier: a read produced NO NUMBER at " + bad + " -- see the MEM-1 lines above")
      p("MILESTONE mem-1-resident-traces-at-tier: SKIP -- tier=" + ramTierName + ": read failed at " + bad +
        " (not counted; nothing to report is not a pass)")
    }

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

      // THE RESTORED MACHINE ALSO NEEDS ITS OWN setstepmul, FOR THE SAME
      // REASON AND WITH THE SAME CONSEQUENCE.
      //
      // g->gc.stepmul is a global_State field (lj_obj.h), seeded from
      // LUAI_GCMUL at lj_state.c:309 and written by collectgarbage('setstepmul')
      // via lj_api.c:1272-1280.  eris rebuilds a DIFFERENT lua_State, so the
      // pre-persist injection is gone on the other side and the restored
      // machine runs at the default 200 however the sweep was configured.
      //
      // THIS WAS CAUGHT BY A CONFOUNDED COLUMN, NOT BY READING THE CODE.  The
      // first gc-pace sweep reported ENCORE_OOM on 8 of 8 runs whose benchmark
      // SURVIVED, which reads as "no amount of pacing saves the persistence
      // path" -- a much stronger claim than the data supported, because the
      // encore was running at stepmul 200 in every one of those rows.  It is
      // the f6 defect above, one field over.
      if (gcStepMul > 0 || gcPause > 0) {
        var ra2: AnyRef = null
        var rt2 = 0
        while (rt2 < 120 && (ra2 == null || luaOf(ra2) == null)) {
          ws2.update(); Thread.sleep(25); rt2 += 1
          ra2 = computer2.machine.architecture
        }
        val rLua2 = if (ra2 == null) null else luaOf(ra2)
        if (rLua2 == null || !quiesced(computer2.machine, "re-applying GC pacing after the restore"))
          milestone("gc-pace-restored", ok = false,
            "could not reach the restored machine's LuaState, so the pacing was NOT re-applied -- " +
              "the encore below ran at the default stepmul and says nothing about pacing")
        else {
          val sm = if (gcStepMul > 0)
            evalStr(rLua2, "local ok, old = pcall(collectgarbage, 'setstepmul', " + gcStepMul +
              ") return ok and tostring(old) or ('ERR:' .. tostring(old))") else "-"
          val pz = if (gcPause > 0)
            evalStr(rLua2, "local ok, old = pcall(collectgarbage, 'setpause', " + gcPause +
              ") return ok and tostring(old) or ('ERR:' .. tostring(old))") else "-"
          // The old value is the evidence for the claim in the comment above:
          // if the restored state had kept the injection it would read back the
          // swept value, not 200.
          p("GC PACE: re-applied after restore -- setstepmul was " + sm + ", setpause was " + pz)
          milestone("gc-pace-restored", sm != "ERR" && !sm.startsWith("ERR:"),
            "re-applied pacing to the state eris rebuilt (previous stepmul on the RESTORED state = " +
              sm + (if (sm == "200") "; note it reset to the LUAI_GCMUL default, which is why this is needed"
                    else "") + ")")
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

      // (f7) THE WRAPPED USERDATA CAME BACK AND STILL WORKS.  The proxy is a
      // table with __metatable = "userdata", so getmetatable must still read
      // "userdata", and a component call through it must still reach the
      // reconstructed HandleValue.
      val udAfter = parse(txtB, "OCLJUD")
      // The shape alone is not enough: a machine killed during unpersist leaves
      // the pre-save row on the screen, and this read PASSED on two dead
      // machines before the counter existed.  Demand a sample taken AFTER the
      // restore, the same gate the encore uses.
      def udSeqOf(row: String): Int = {
        val f = row.split("/")
        if (f.length >= 5) try f(4).trim.toInt catch { case _: Throwable => -1 } else -1
      }
      val udSeqBefore = udSeqOf(udBefore)
      val udSeqAfter = udSeqOf(udAfter)
      val udShapeOk = udAfter.startsWith("table/userdata/true/")
      val udFresh = udSeqAfter > udSeqBefore && udSeqAfter > 0
      milestone("f7-restored-userdata-proxy-live", udShapeOk && udFresh,
        "OCLJUD before=" + udBefore + " after=" + udAfter +
          (if (udShapeOk && udFresh) ""
           else if (!udShapeOk) "   <- the wrapped userdata did not survive the round trip"
           else "   <- STALE: seq " + udSeqAfter + " did not advance past " + udSeqBefore +
             ", so this row predates the restore and proves nothing"))

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

    // --- (fi) a save that lands MID-FOR-IN over the kernel's iterators ----
    // On the ORIGINAL machine too, before stk starts its endless fs.open
    // burst chain on it.  See forInSave for what is asserted and why.
    forInSave(ws, computer, screen, kernelMode)

    // --- (dg) a save that lands MID-FOR-IN over OpenOS's OWN next-wrapper --
    // The residual of the for-in gap (census #9): not fixable, but NAMED at
    // save time under -Docluajit.forin=warn.  Our serializer only -- stock
    // Eris has no such setting.  See forinDiagnosticSave for the arms.
    if (nativeMode != "stock") forinDiagnosticSave(ws, computer, screen)

    // --- (stk) a save that lands MID-SYNC-CALL ------------------------
    // On the ORIGINAL machine, which f1 left running; ws2's copy shares the
    // disk directory but is no longer ticked, so only this one answers the
    // signal.  See syncCallSave for what is asserted and why.
    syncCallSave(ws, computer, screen,
      expect = nativeMode match { case "additive" => "bundle"; case "stock" => "stock"; case _ => "dropin" })

    // --- (g) the bytecode gate ----------------------------------------
    p("--- allowBytecode gate (on a private LuaState) ---")
    computer.machine.stop()
    bytecodeGate()
    memoryProbes()

    finish()
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
