-- bench/oc/matmul.lua -- the sandbox-runnable form of bench/matmul.lua.
--
-- The KERNEL is bench/matmul.lua's, statement for statement.  Verified, not
-- assumed: the 39 lines from `local N, REPS` to `local t = clock() - t0` diff
-- clean against the original once the sizing line is normalised, and the trace
-- loop after them is identical too.  Exactly two things changed:
--
--   1. The two print()s became a `return`, as the harness contract requires,
--      because inside an OpenComputers sandbox print() goes to a scrolling
--      terminal the Java harness cannot reliably parse.
--   2. N and REPS were rescaled, 250/8 -> 32/3000, because the published shape
--      does not fit inside a Minecraft computer.
--
-- (2) means this row's CHECK is a NEW reference, NOT the published 29357.3086
-- from bench/results-2026-09-01.md.  The new reference is
--
--     481.0000
--
-- and, unlike nqueens', it depends on N ALONE: every rep recomputes the same c
-- from the same a and bT, so the trace is the same whether REPS is 400, 2400,
-- 3000 or 3840 (checked at all four).  REPS may therefore be retuned for time
-- without invalidating the checksum; N may not.  Every input is an exact
-- binary fraction -- multiples of 1/16 plus 1/2 in a, of 1/32 plus 1/4 in bT --
-- so every product is a multiple of 1/512 and every partial sum is exact in a
-- double.  481.0000 came back byte-identical from luajit, luajit -joff, lua5.3
-- and lua5.4 on all 60 timed runs recorded below.
--
-- WHY THE PUBLISHED SHAPE DOES NOT FIT, measured rather than argued.  Three
-- 250x250 tables of doubles, built exactly as bench/matmul.lua builds them and
-- then fully collected and weighed under `luajit -joff`: 1558.9 KB live --
-- larger than the machine's whole 1024 KB, never mind the 450 KB budget.  Run
-- as written, bench/matmul.lua peaks at 4267.9 KB, 9.5x the budget.  LuaJIT
-- has no emergency GC, so that would not merely fail this row: the first
-- refused allocation throws and the whole run is lost.
--
-- WHY N=32, AND NOT THE 48 OR 56 THE ARITHMETIC SUGGESTS.  Peak here is not
-- the live matrices.  It is GC headroom over the per-rep churn -- `c = {}`
-- drops N row tables every rep, and LuaJIT's incremental GC at the default
-- pause of 200% runs several times the live set ahead of it.  So peak tracks
-- ROW SIZE, and row size has a cliff.  A row holds keys 1..N; LuaJIT's array
-- part is indexed 0..asize-1 with asize a power of two, so N=32 fits in 32
-- slots and N=33 needs 64 -- one extra column doubles every row in all three
-- matrices.  Measured under `luajit -joff`, live set built then fully
-- collected, peak sampled on a count hook:
--
--     N    REPS    live set      peak
--     64    480    111.2 KB    433.8 KB
--     56    760     97.5 KB    394.6 KB
--     48   1200     83.8 KB    357.3 KB
--     44   1477     77.0 KB    335.5 KB
--     40   1966     70.1 KB    311.1 KB
--     36   2697     63.3 KB    291.2 KB
--     34    400     59.9 KB    281.8 KB
--     33    400     58.2 KB    243.6 KB   <- last N with 64-slot rows
--     32    400     31.7 KB    196.9 KB   <- first N with 32-slot rows
--
-- The N=64 candidate this file replaces measured 433.8 KB -- inside the 450 KB
-- budget by 4%, which is no margin at all against a denominator that itself
-- moved 865-1024 KB between Phase-0 runs.  N=48 is still 357 KB, N=36 clears
-- 300 KB by only 3%.  N=32 is the largest N on the cheap side of the cliff and
-- the first one that is actually safe.  Going below it buys nothing: N=31
-- measures 30.8 KB live against N=32's 31.7 KB.
--
-- MEMORY OF THIS FILE, measured, not estimated.  Loaded the way the harness
-- loads it and run under `luajit -joff` with a count hook sampling
-- collectgarbage("count"): base 54.2 - 54.8 KB, **peak ~210 KB** -- eleven
-- runs spanned 201.6 to 212.2 KB, so 147 to 158 KB above that base, the spread
-- being GC scatter rather than measurement error.  Against the 450 KB budget
-- that is 47% at the worst sample, with better than half the budget to spare.
-- (About 11 KB of the base is this comment header: the loader holds the source
-- string for as long as the chunk lives.  The body without the header measures
-- base 42.9 KB, peak 195.0 - 197.6 KB.)  Four sampling rates -- every 200,
-- 2000, 20000 and 200000 instructions -- all land inside that same band with
-- no ordering by rate, so the peak is a flat plateau, no spike is hiding
-- between samples, and run-to-run GC scatter is the larger term either way.
-- The peak is independent of REPS too: the body measures 196.9 / 197.2 /
-- 197.2 KB at REPS 400 / 2400 / 3840, because the churn reaches steady state
-- within the first few reps.
--
-- Cross-checked against an allocation-free control -- the same float work with
-- c and all its rows preallocated, so the timed loop allocates nothing.  That
-- peaks at 32.2 KB above base, matching the 31.7 KB live set.  So the whole of
-- the remaining ~122 KB is GC headroom over the churn, which is what makes the
-- row-size cliff, and not N^2, the thing that sets this row's footprint.
--
-- Do NOT re-measure the peak with the JIT on.  A sampling loop under a count
-- hook is the exact pathology this project already fixed; the number it
-- returns measures the hook, not the benchmark.
--
-- TIME, measured on this box.  Min of 15 runs per VM, ONE FRESH PROCESS PER
-- RUN (bench/run.sh's methodology), the four VMs round-robined so a busy
-- window could not land on one of them only, and the number of other
-- lua/luajit processes alive recorded next to every sample -- sibling agents
-- were benchmarking on this same box, and contended samples move the numbers
-- by up to 55%.  All 60 runs returned 481.0000; for each VM the winning sample
-- was an uncontended one.
--
--     lua5.3          1.424 s     1.00x   (baseline: what a player runs today)
--     lua5.4          0.935 s     1.52x
--     luajit -joff    0.724 s     1.97x
--     luajit          0.124 s    11.48x
--
-- against the published N=250 figures of 1.49x, 2.22x and 17.03x.  The two
-- interpreter rows reproduce; the compiled row gives up about a third of its
-- 17x, and is still an order of magnitude, which is what this row is in the
-- suite to show.  1.424 s on lua5.3 also puts it beside mandelbrot's 1.355 s
-- rather than out at nqueens' 1.819 s, so it should sit comfortably inside
-- OC's per-resume deadline.
--
-- WHAT THE RESCALE COSTS, stated plainly.  Shrinking N and multiplying REPS
-- holds the float work roughly constant but multiplies the allocation: the
-- published shape drops 2000 row tables across 125.0M multiply-adds, one table
-- per 62500 operations; this one drops 96000 across 98.3M, one per 1024.  So
-- this is a dense-float kernel with a real GC component attached, and it is
-- NOT row-for-row comparable to the matmul row in results-2026-09-01.md.
-- Measured, that component is small.  Against the allocation-free control
-- above, alternated with this file's sizing over 9 uncontended rounds, JIT on:
-- 0.121 s with the churn against 0.102 s without.  So the churn is ~16% of the
-- compiled time, and the rest of the gap from 17.03x down to 11.48x is NOT the
-- garbage.  What it is instead has not been measured here, and is left open
-- rather than guessed at; the obvious suspect is the shorter inner loop, but
-- this file makes no claim it has not checked.
--
-- Uses only os.clock and string.format: no io, no os.time, no print, no
-- collectgarbage, no require, no `arg`, no debug.  No bit operations either,
-- so it needs no compat.lua and does not depend on which branch compat.lua
-- picks.  Checked, not assumed: bench/oc/checks/contract.lua loads this file
-- with all of those globals poisoned and reports `matmul ok CHECK=481.0000`.
--
-- To regenerate the standalone references, load this file the way the harness
-- does -- load(src) with no arguments, take the two return values -- under
-- build/native/luajit/src/luajit.exe (with and without -joff),
-- bench/vendor/lua-5.3.6/src/lua.exe and bench/vendor/lua-5.4.8/src/lua.exe,
-- one fresh process per run, and take the minimum.

local N, REPS = 32, 3000

local a, bT = {}, {}
for i = 1, N do
  local ai = {}
  a[i] = ai
  for j = 1, N do
    ai[j] = ((i + j) % 16) * 0.0625 + 0.5
  end
end
-- b stored transposed (setup, untimed) so the kernel walks rows linearly
for j = 1, N do
  local bj = {}
  bT[j] = bj
  for k = 1, N do
    bj[k] = ((k * 3 + j * 7) % 16) * 0.03125 + 0.25
  end
end

local c = {}
local clock = os.clock
local t0 = clock()
for rep = 1, REPS do
  c = {}
  for i = 1, N do
    local ai = a[i]
    local ci = {}
    c[i] = ci
    for j = 1, N do
      local bj = bT[j]
      local s = 0.0
      for k = 1, N do
        s = s + ai[k] * bj[k]
      end
      ci[j] = s
    end
  end
end
local t = clock() - t0

local trace = 0.0
for i = 1, N do trace = trace + c[i][i] end

return string.format("%.4f", trace), t
