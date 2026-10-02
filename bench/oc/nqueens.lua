-- bench/oc/nqueens.lua -- the sandbox-runnable form of bench/nqueens.lua.
--
-- BYTE-FOR-BYTE the same computation as bench/nqueens.lua: same N = 12, same
-- REPS = 6, same backtracking visiting the same squares in the same order.
-- (Verified, not assumed: the region from `local N, REPS` to `local t = clock`
-- diffs clean against the original.)  The ONLY difference is the last two
-- lines -- the standalone file prints CHECK and TIME, this one returns them,
-- because inside an OpenComputers sandbox print() goes to a scrolling terminal
-- the Java harness cannot reliably parse.  So its CHECK is the PUBLISHED
-- reference from bench/results-2026-09-01.md and needs no new baseline: 85200.
--
-- N = 12 IS KEPT.  The survey's rescaled copy dropped to N = 11 to save
-- memory; measured, that trade buys nothing, because this benchmark is not
-- near the cap in the first place (see MEMORY).  Keeping N = 12 keeps the
-- published checksum, so this row needs no new reference value.  Note 85200 =
-- 6 reps x 14200 solutions for the 12-queens board -- the count depends on
-- REPS as well as N, so neither may be retuned without invalidating it.
--
-- WHY THIS ONE IS IN THE SUITE: it is the ANTI-pole to mandelbrot.  Recursion
-- and backtracking is the least JIT-friendly compute shape in the set, and
-- keeping it is what stops the suite reporting a geomean the mod's users would
-- not recognise.  It also needs no compat.lua (no bit operations), no
-- require(), and no upvalues from outside, so it loads with a plain load(src)
-- off the filesystem proxy; and it is integer-and-boolean work throughout, so
-- the count is identical on PUC 5.2, on 5.3/5.4, and on our LuaJIT both ways.
--
-- TIME, measured on this box.  Min of 15 runs per VM, ONE FRESH PROCESS PER
-- RUN (bench/run.sh's methodology), the four VMs round-robined so a busy
-- window could not land on one of them only, and the number of other
-- lua/luajit processes recorded next to every sample so contended ones could
-- be excluded rather than averaged in.  All 60 runs returned 85200; for each
-- VM the winning sample was an uncontended one.
--
--     lua5.3          1.819 s     (baseline: what a player runs today)
--     lua5.4          1.632 s
--     luajit -joff    1.026 s     1.77x
--     luajit          1.501 s     1.21x
--
-- THE COMPILER IS NEGATIVE HERE: JIT on is 1.46x SLOWER than the same
-- binary's own interpreter.  That is not an artefact of this box -- the
-- published standalone table shows the same inversion at 1.655 s against
-- 0.993 s (1.67x), and the whole table agrees with these numbers to within
-- about 7%.
--
-- WHAT CAUSES THE INVERSION -- FOUND 2026-10-02, after this file had been
-- wrong about it once.  The first claim was that recursive solve() "trips a
-- trace abort and re-entry on every level".  Measured with a
-- jit.attach("trace") counter, that is false: the recorder starts 118 traces,
-- completes 118, and aborts ZERO.  The probe is not blind -- a coroutine-switch
-- positive control run through the same counter reports 13 starts, 2
-- completions and 11 aborts.  So the compiler records this workload cleanly
-- and the compiled code still loses; the row was then reported as measured,
-- with the mechanism left open rather than guessed at.
--   The mechanism (bench/results-ladder-2026-09-29.md, "nqueens: the same
-- mechanism"; docs/roadmap.md, the row on re-calling one loaded chunk):
-- `local function solve` is defined INSIDE the rep loop below, so every rep
-- makes a new closure over new tables while the traces compiled for the
-- earlier reps' closures stay attached.
-- Per-rep times, 3 fresh processes per cell, CHECK 85200 in every run: rep 1
-- 0.057-0.060 s, rep 2 0.087-0.089, reps 3-6 0.226-0.237, our build and
-- upstream LuaJIT alike; with -joff every rep 0.143-0.146.  Rep 1 compiled is
-- 2.4x faster than interpreted; from rep 3 the reps run 1.6x SLOWER than
-- interpreted, on the traces the earlier reps left behind.  A jit.flush()
-- before each rep brings reps 3-6 to 0.076-0.082 (total 0.43 s against
-- 1.06-1.09 s), and one solve hoisted out of the loop runs every rep at
-- 0.056-0.066 (total 0.35 s, 2.5x faster than the interpreter's 0.87 s).
-- What the flush leaves, ~1.3x over rep 1 from the third closure on, sits at
-- LuaJIT's closure-count threshold (PROTO_CLC_POLY); what the flush removes
-- is ~3x on top of it (reps 3-6 0.226-0.237 against 0.076-0.082 flushed;
-- ~3.9x is the whole climb over rep 1).  The loop below is left as published
-- (it must stay the same computation as bench/nqueens.lua); the inversion
-- belongs to this shape, on upstream LuaJIT as on ours.  Still open: why this
-- file reads faster inside a machine than standalone (six runs launched
-- pinned on 2026-10-02: mins 0.43-0.56 s, maxes 1.09-1.14 s; 0.68 s unpinned
-- on 09-29); candidate, untested: LuaJIT's own self-flush (1000 traces or
-- 2 MB of mcode) landing mid-run in a machine that already holds the boot's
-- traces.
--
-- MEMORY, measured, not estimated, and comfortably inside the 450 KB budget.
-- Under `luajit -joff` with a count hook sampling collectgarbage("count"):
-- base 48.0 KB, peak 58.9 KB, so the benchmark's own footprint is 10.9 KB.
-- Identical at hook intervals 1000, 10000 and 100000, so nothing is hiding
-- between samples.  (Quote the 10.9 KB delta, not the 58.9 KB: the base is
-- whatever the measuring harness already had on the heap, and it moves when
-- this comment block changes length.)  Cross-checked against a bound no sampling interval can
-- hide anything from -- collectgarbage("stop") held for the whole run, making
-- the delta the total bytes EVER allocated: 7.9 KB.  (lua5.3 on the same
-- bound: 12.4 KB.)  Three small tables and one closure per rep, and nothing
-- else.  Against a 450 KB cap this row is free.
--
-- DO NOT RE-MEASURE THE PEAK WITH THE JIT ON.  With the compiler enabled the
-- same GC-stopped bound is 106.9 KB, because the traces are themselves on the
-- heap -- that ~100 KB is the compiler's footprint, not the workload's, and it
-- is why the cap is measured with -joff.  Worse, the count-hook probe with the
-- JIT on reports peak 221.9 KB and 16.0-18.7 s against an honest 1.501 s: an
-- 11x time inflation, stable across all three hook intervals.  That is the
-- sampling-hook-versus-JIT pathology this project already fixed once.  It
-- measures the hook, not the benchmark.
--
-- ONE THING TO WATCH IN-MACHINE, and it is not yet measured: this is the
-- longest row in the suite so far.  Standalone on lua5.3 it is 1.819 s against
-- mandelbrot's 1.355 s, and mandelbrot's in-machine cell A came out at
-- 1.820 s.  nqueens does not yield, so the whole run is a single resume.  It
-- deserves a deliberate look against OC's per-resume deadline the first time
-- it is run in-machine; if that deadline is ever tightened below the stock 5 s,
-- this is the row that hits it first.
--
-- To regenerate the standalone references, load this file the way the harness
-- does -- load(src) with no arguments, take the two return values -- under
-- build/native/luajit/src/luajit.exe (with and without -joff) and
-- bench/vendor/lua-5.3.6/src/lua.exe, one fresh process per run, and take the
-- minimum.

local N, REPS = 12, 6

local total = 0
local clock = os.clock
local t0 = clock()
for rep = 1, REPS do
  local cols, d1, d2 = {}, {}, {}
  local count = 0
  local function solve(row)
    if row > N then
      count = count + 1
      return
    end
    for col = 1, N do
      local x, y = row - col + N, row + col
      if not (cols[col] or d1[x] or d2[y]) then
        cols[col], d1[x], d2[y] = true, true, true
        solve(row + 1)
        cols[col], d1[x], d2[y] = nil, nil, nil
      end
    end
  end
  solve(1)
  total = total + count
end
local t = clock() - t0

return string.format("%d", total), t
