-- bench/oc/trampoline.lua -- the sandbox-runnable form of bench/trampoline.lua.
--
-- The kernel is BYTE-FOR-BYTE bench/trampoline.lua: the same three functions,
-- the same two layers of vararg forwarding, the same pcall, the same
-- arithmetic in the same order.  Exactly two things differ:
--
--   1. ITER is 1,000,000 here against 20,000,000 there -- a twentieth.  Why it
--      is a twentieth and not a half is the whole of the note below, and it is
--      the most important thing in this file.
--
--   2. The two print()s became a `return`, as for every file in this
--      directory: inside the sandbox print() goes to a scrolling terminal the
--      Java harness cannot reliably parse.
--
-- ================================================================
-- THE SIZE IS NOT SET BY THE CLOCK.  IT IS SET BY OC'S OWN pcall.
-- ================================================================
--
-- Standalone this file is cheap.  Loaded the way the harness loads it -- read
-- the source, load(src), call it, take the two returns -- and run seven times
-- on each VM in each of four sweeps (min of each; this machine, 2026-09-03):
--
--     lua5.3  0.104-0.122 s    lua5.4  0.098-0.113 s
--     LuaJIT -joff  0.053-0.067 s    LuaJIT  0.008-0.010 s
--
-- with CHECK 247388 in every one of those 112 runs.  The spread between
-- sweeps is concurrent load on this box, not the benchmark; the instrument
-- control further down puts a number on how slow the box was reading.
-- Note the last cell: 0.008 s is EIGHT ticks of a Windows os.clock, so the
-- standalone compiled column is at its resolution floor and the standalone
-- ratio (~12x) is worth about two digits.  That is a
-- property of the standalone harness and not of the benchmark -- in the
-- sandbox os.clock is machine.cpuTime at nanosecond resolution, and the
-- in-machine cells are two to three orders of magnitude longer than this (see
-- below), so the numbers that will be published are not resolution-limited.
--
-- The naive scaling -- "the published
-- 20,000,000 row costs lua5.3 2.390 s, keep the slowest cell under ~1.5 s, so
-- halve it" -- lands on 10,000,000 and is WRONG, because standalone `pcall`
-- and sandbox `pcall` are not the same function.
--
-- machine.lua does not hand the sandbox the C builtin.  It hands it this
-- (ocelot-brain's machine.lua, lines 763-769; our kernel patch does not touch
-- it -- native/kernel/patch-machine-lua.lua changes four sites, the watchdog
-- capture and three hook-arming sites, and this is none of them, so the
-- wrapper is in every cell A, B and C alike):
--
--     pcall = function(...)
--       -- prevent infinite pcall() loops by checking deadline before pcall()
--       local status, err = pcall(checkDeadline)
--       if not status then return false, err end
--       return pcallTimeoutCheck(pcall(...))
--     end,
--
-- So every one of this benchmark's iterations, in every cell, costs a Lua
-- closure call, TWO real pcalls, a pcallTimeoutCheck vararg forward (lines
-- 55-61), and -- as the first statement of checkDeadline, line 46 -- a
-- `computer.realTime()` call, which is a host function reached through JNLua,
-- not a Lua one.
--
-- MEASURED, not assumed.  A standalone replica of exactly that wrapper (the
-- same closure, the same two pcalls, the same pcallTimeoutCheck, with
-- os.clock standing in for computer.realTime), 1,000,000 iterations, min of 5,
-- both columns taken in one sweep so the ratio is internally consistent:
--
--     VM                 plain pcall   sandbox-shaped pcall   ratio
--     lua5.3               0.136 s          0.234 s           1.72x
--     lua5.4               0.120 s          0.236 s           1.97x
--     LuaJIT, -joff        0.064 s          0.139 s           2.17x
--     LuaJIT, JIT on       0.009 s          0.079 s           8.78x
--
-- Read the last row.  The JIT-on penalty is 8.78x where the interpreters pay
-- under 2.2x, and a third control says why: replacing os.clock with a trivial
-- Lua function (everything else identical) puts LuaJIT back at 0.009 s -- the
-- plain-pcall time exactly -- while leaving lua5.3 at 0.248 s.  The whole of
-- LuaJIT's loss is the ONE host call per pcall that it cannot record.  The
-- interpreters do not care what kind of function it is; the compiler cares
-- enormously.
--
-- Two consequences, and the second one sizes the file:
--
--   * this benchmark's in-machine number will NOT be its standalone 16.48x
--     (~12x as sized here).  On the replica the compiled advantage falls from
--     15.1x to 3.0x, and in-machine `computer.realTime` is a JNLua upcall into
--     the JVM rather than a libc clock() -- strictly more expensive per call,
--     so 3.0x is a CEILING and not a prediction.
--     That is the interesting result, not a defect: this file is the suite's
--     bridge between the compute pole (17.5x) and the component pole (1.00x),
--     and the mechanism it isolates -- a host call the recorder cannot inline,
--     one per sandbox pcall -- is the same mechanism, minus the tick.
--
--   * the cost per iteration in a real machine is therefore bounded below by
--     one JNLua upcall, and that number is NOT measured here.  So ITER is set
--     to leave the unknown a wide budget rather than to fill a time.  The
--     model projects cell A (PUC 5.2, +34% for the sandbox, the factor Phase 0
--     measured on mandelbrot: 1.355 s standalone -> 1.820 s in cell A) at
--     0.31 s for 1,000,000 iterations.  Against OC's 5 s per-resume deadline
--     that is 16x of headroom, i.e. the run survives even if a JNLua upcall
--     turns out to cost 4.7 us -- several times the plausible figure.  At
--     10,000,000 that budget would be 0.47 us and the row would very likely
--     come back DEADLINE instead of a number.
--
-- RESIZING INVALIDATES THE PUBLISHED CHECK.  bench/results-2026-09-01.md
-- reports 768719 and that value is for 20,000,000 iterations only; unlike
-- mandelbrot, this file cannot inherit its reference.  The new reference is
--     247388
-- measured, not derived: byte-identical on lua5.3, on lua5.4, on our LuaJIT
-- compiled and on our LuaJIT with -joff, in all 112 runs above, and identical
-- again under the sandbox-pcall replica -- the wrapper changes the cost and
-- not the answer.
--
-- The 20,000,000 reference was re-measured on this machine first, as a control
-- on the instrument: it came back 768719, the published value, at lua5.3
-- 2.764 / lua5.4 2.472 / LuaJIT 0.184 / -joff 1.178 s against the published
-- 2.390 / 2.306 / 0.145 / 1.034.  So this box reads 1.16-1.27x slow -- it was
-- under concurrent load -- and every second quoted in this header is therefore
-- a slow-side reading, which is the safe side for a sizing decision.
--
-- THE CHECKSUM IS ALSO THIS FILE'S DEADLINE CONTROL, which matters more here
-- than anywhere else in the suite.  When the deadline passes, sandbox pcall
-- returns `false, err` BEFORE calling f -- so `guarded` takes its `if not ok`
-- branch and returns n, and the loop keeps running with a corrupted
-- accumulator instead of stopping.  A run that then squeezed past the finish
-- line inside checkDeadline's 0.5 s grace would return normally with a wrong
-- answer.  It cannot pass: acc is a full recurrence over every iteration
--     acc <- (acc + acc%64 + i%97 - i%31 + 3) % 1048576
-- so any such run returns a different string.  The usual outcome is the
-- harness's DEADLINE row (checkDeadline's count=1 re-arm forces the error out
-- through code that is not inside a pcall); the checksum is what closes the
-- narrow case where it is not.
--
-- WHY FIXED WORK AND NOT ITERATIONS/SECOND.  ITER is a constant and is the
-- same in every cell, so the seconds returned are directly comparable and
-- iterations/second is exactly 1000000/t -- a row quoting either quotes the
-- same measurement.  A time-boxed loop reporting the rate it reached would
-- instead make acc depend on how fast the machine ran, and the checksum is the
-- only control this file has.  Fixed work keeps it.
--
-- Also true of this file, and cheaply so:
--   * it allocates nothing.  Peak is ~57 KB under `luajit -joff` (56.7-57.1
--     over the sweeps taken while this header was still growing), against the
--     450 KB budget -- and the loop's own contribution to that is 3.5 KB and
--     does not move: the rest is the VM's start-up heap plus this file's own
--     ~9 KB of source, which stays live because the harness holds the string
--     it loaded from.  Sampled from a count hook at intervals of
--     500, 2000 and 20000 instructions, all three agreeing to 0.1 KB, so the
--     figure is not an artefact of the sampling rate.  Measured with the JIT
--     OFF on purpose: a sampling loop under a count hook with the JIT on is
--     the exact pathology this project just fixed.  LuaJIT has no emergency
--     GC, so an oversized benchmark loses the whole cell rather than just its
--     own row, and this one cannot;
--   * no bit operations, so it does not depend on which branch compat.lua
--     picks, and no require() and no upvalues from outside, so it loads with a
--     plain load(src) off the filesystem proxy.
--
-- Run standalone with bench/oc/run-standalone.sh to regenerate references.

local ITER = 1000000

local function work(a, b, c)
  return a + b - c
end

local function guarded(f, ...)
  local n = select('#', ...)
  local ok, r = pcall(f, ...)
  if not ok then return n end
  return r + n
end

local function spcall_like(f, ...)
  return guarded(f, ...)
end

local acc = 0
local clock = os.clock
local t0 = clock()
for i = 1, ITER do
  acc = (acc + spcall_like(work, acc % 64, i % 97, i % 31)) % 1048576
end
local t = clock() - t0

return string.format("%d", acc), t
