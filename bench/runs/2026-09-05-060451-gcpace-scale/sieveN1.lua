-- bench/oc/sieve.lua -- the sandbox-runnable form of bench/sieve.lua.
--
-- The kernel is BYTE-FOR-BYTE bench/sieve.lua: the same fresh `flags = {}` per
-- repetition, the same fill, the same `while i * i <= N` trial division, the
-- same final count, in the same order.  Exactly two things differ, and both
-- are forced rather than chosen:
--
--   1. N is 8192 here against 100000 there, with REPS raised from 400 to 4500
--      to keep the run long enough to time.  N is set by the RAM cap and
--      nothing else -- see MEMORY below.
--   2. The two print()s became a `return`, as for every file in this
--      directory: inside the sandbox print() goes to a scrolling terminal the
--      Java harness cannot reliably parse.
--
-- RESIZING INVALIDATES THE PUBLISHED CHECK.  bench/results-2026-09-01.md
-- reports a value for N = 100000, REPS = 400 only.  The new reference is
--     4626000
-- and it was measured, not derived: 4626000 = 1028 x 4500, where 1028 is
-- pi(8192).  It was byte-identical on lua5.3, on lua5.4, on our LuaJIT
-- compiled, and on our LuaJIT with -joff, 3 runs each.  Because it is a plain
-- product of the prime count and REPS it is a weak sabotage control -- a plant
-- that truncated the sieve would still return a round number -- so read it
-- together with the time, not instead of it.
--
-- MEMORY, measured, not estimated.  THIS FILE, under `luajit -joff`, loaded
-- the way the harness loads it, with a count hook sampling
-- collectgarbage("count") every 2000 instructions:
--     base 48.5 KB, peak 240.5 KB, delta 192.0 KB
-- and identical to the tenth of a KB on all 3 runs.  Against the 450 KB budget
-- that is 1.9x of margin.  (The base is 48.5 rather than an empty VM's ~41
-- because the measuring harness holds this file's own source string; the
-- delta, 192.0 KB, is the workload, and it has come out at 192.0-192.9 KB on
-- every revision of this file, header edits included.)
--
-- Two further properties, measured on the bare kernel without this comment
-- header -- where the same method reports base 40.6, peak 233.5, delta 192.9,
-- i.e. the same workload:
--   * hook-rate independent.  Sampling every 200 instructions instead of every
--     2000 returned 233.5 KB -- the same figure to the tenth of a KB.
--   * RETRACTED 2026-09-04 -- THIS PARAGRAPH MEASURED THE INSTRUMENT.  The
--     "233.5 KB, REPS-independent" figure below was sampled from a count hook
--     every 10000 instructions, and a hook callback is Lua work, which is GC
--     safepoints: the hooked run hands the collector hundreds of chances per
--     repetition that this loop never gives it, so the collector keeps up and
--     the heap stays flat.  Sampled instead ONCE PER REPETITION from inside
--     this file's own loop (bench/oc/checks/peak-inband.lua), the same file at
--     the same parameters peaks at 1154.5 KB -- and it is flat at 1143.6 KB
--     across REPS 100, 500, 1500 and 4500, so the flatness was real and the
--     LEVEL was not.  The steady state genuinely is small: live-after-collect
--     is 52-65 KB at every REPS in every mode.  What the RAM guard needs is
--     the high-water mark, and that is 3.7x what was published here.
--     references.txt now carries 1155.
--
--     The consequence was not academic.  At 312 KB the guard asked for 440 KB
--     free and let this benchmark start in a machine with ~890 KB -- and it
--     killed that machine 6 runs out of 6.  See
--     bench/results-in-machine-phase1-2026-09-04.md.
--
--   * The original claim, kept so the retraction can be checked against it:
--     REPS-independent, measured at REPS = 1500, 6000 and 12000 the peak was
--     233.5 KB every time -- each
--     repetition drops its `flags` before the next allocates, so the workload
--     reaches a steady state after the first rep and stays there.  REPS can
--     therefore be retuned for runtime without touching the memory row.
--
-- N cannot be retuned so freely: N = 16384 peaks at 425.5 KB, which is inside
-- the 450 KB cap by only 1.06x and is not a margin worth taking, because
-- LuaJIT has no emergency GC -- the first refused allocation throws, and an
-- oversized benchmark does not fail its own row, it kills the machine and
-- loses the whole run.
--
-- READ THIS BEFORE QUOTING A SPEEDUP.  Do NOT compare this row to the
-- published sieve figure of 4.6x.  It is not measuring the same regime, and
-- the difference is a factor of two.  Holding total work fixed at
-- N x REPS = 36.9M and sweeping N on this box, min of 3, lua5.3 over LuaJIT:
--       N =   2048  8.2x        N =  16384  4.5x
--       N =   4096  8.3x        N =  32768  3.6x
--       N =   8192  9.4x        N =  65536  5.2x
--                               N = 100000  5.2x   <- the published size
-- There is a cliff between 8192 and 16384: LuaJIT's own time at constant work
-- jumps from 0.126 s to 0.279 s across it.  `flags` lands in LuaJIT's array
-- part at 8 bytes per slot, so N = 8192 is a 64 KB hot array that stays in L1/
-- L2, and N >= 16384 does not.  Above the cliff the compiled inner loop is
-- memory-latency-bound and the interpreter's overhead is partly hidden, which
-- is why the published N = 100000 run reports 4.6x.  Below it the JIT is not
-- waiting on memory and reports 9.4x.  The N = 100000 row above is the
-- control: run through this harness it gives 5.2x, close to the published
-- 4.6x, which is the evidence that the sweep reproduces the original regime
-- and that the 9.4x at N = 8192 is a real effect of size and not of method.
--
-- Both numbers are honest; they answer different questions.  The reason this
-- file takes the small one deliberately, and not merely because the cap forced
-- it, is that the cache-resident regime is the only one an OpenComputers
-- program can actually be in.  A machine here has ~865 KB free after boot, so
-- a 128 KB hot array is not a thing a player's program will hold, let alone
-- the 800 KB the published run uses.  The 4.6x describes a workload this
-- platform cannot host.  About 9x is the figure for arrays of the size OC code
-- really uses -- but it must be reported as a rescaled row, never quoted
-- against the benchmarks-game lineage.
--
-- Why this one is in the suite: it is the flat integer-array pole.  4500 reps
-- of fill + sieve + count is well over 10^8 indexed table operations, so it is
-- in no danger of being a microbenchmark; what it measures is array-part store
-- and load in a counted loop, which is the single most common hot shape in the
-- OC programs this project is for.  It needs no bit operations, so it does not
-- depend on which branch compat.lua picks and needs no compat.lua at all, and
-- it has no require() and no upvalues from outside, so it loads with a plain
-- load(src) off the filesystem proxy.
--
-- TIMES for THIS file on this box, loaded the way the harness loads it, min of
-- 5 for the LuaJIT rows and min of 3 for PUC:
--   lua5.3 1.040 s | lua5.4 0.817 s | luajit -joff 0.797 s | luajit 0.119 s
-- -- so 8.7x over lua5.3 and 6.7x over this same binary's own interpreter.
-- All four returned check 4626000.  Quote one significant figure and no more:
-- across three separate sessions on an otherwise-busy desktop the lua5.3 row
-- ranged 1.040-1.186 s and the JIT row 0.119-0.126 s, so the honest statement
-- is "about 9x", spread 8.7-9.4x.  In-machine numbers supersede these; these
-- exist to size the row and to catch a gross regression, not to be published.
-- Run through bench/oc/checks/contract.lua -- which loads it exactly as
-- autorun.lua does, with io/print/collectgarbage/require/os.time poisoned --
-- it passes at 1.104 s on lua5.3, against that checker's 2.5 s budget.  Using
-- the checker's measured conversion (in-machine cell A ~= standalone lua5.3 x
-- 1.03) that projects to ~1.14 s in a real machine, against the 5 s
-- per-resume deadline it must fit in, since it does not yield and so runs as a
-- single resume.  That is 4x of headroom -- the most of any row in the suite
-- except trampoline.
--
-- Run standalone with bench/oc/run-standalone.sh to regenerate references.

local N, REPS = 8192, 4500

local total = 0
local clock = os.clock
local t0 = clock()
for r = 1, REPS do
  local flags = {}
  for i = 2, N do flags[i] = true end
  local i = 2
  while i * i <= N do
    if flags[i] then
      for j = i * i, N, i do flags[j] = false end
    end
    i = i + 1
  end
  local count = 0
  for k = 2, N do
    if flags[k] then count = count + 1 end
  end
  total = total + count
end
local t = clock() - t0

return string.format("%d", total), t
