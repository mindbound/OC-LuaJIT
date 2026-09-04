-- bench/oc/binarytrees.lua -- the sandbox-runnable form of bench/binarytrees.lua.
--
-- The kernel -- make(), nodes(), the stretch tree, the long-lived tree, the
-- `for d = MINDEPTH, MAXDEPTH, 2` loop and its doubling iteration count -- is
-- BYTE-FOR-BYTE bench/binarytrees.lua.  Three things differ:
--
--   1. MAXDEPTH is 7 here against 16 there.  Set by the RAM cap; see MEMORY.
--   2. The whole benchmark body is wrapped in `for _ = 1, REPS` with
--      REPS = 800, because shrinking MAXDEPTH by 9 removes ~99.8% of the work
--      and something has to put it back.  This is a larger structural change
--      than any other file in this directory makes, and it is called out here
--      rather than buried: the original runs the body once, this runs it 800
--      times.  Consequently `longlived` is re-created and dropped each rep
--      instead of surviving the whole run.
--   3. The two print()s became a `return`, as for every file in this
--      directory: inside the sandbox print() goes to a scrolling terminal the
--      Java harness cannot reliably parse.
--
-- RESIZING INVALIDATES THE PUBLISHED CHECK.  The new reference is
--     7038400
-- measured, not derived, and byte-identical on lua5.3, lua5.4, our LuaJIT
-- compiled and our LuaJIT with -joff, 3 runs each.  It is 800 x 8798, where
-- 8798 is the per-rep node count: 511 (stretch, depth 8) + 255 (longlived,
-- depth 7) + 128 x 31 (d = 4) + 32 x 127 (d = 6).  Like sieve's it is a plain
-- product and so a weak sabotage control; read it with the time, not instead
-- of it.  It does confirm the tree shapes are intact, which is what it is for.
--
-- MEMORY, measured, not estimated.  THIS FILE, under `luajit -joff`, loaded
-- the way the harness loads it, with a count hook sampling
-- collectgarbage("count") every 2000 instructions:
--     base 53.1 KB, peak 239.5 KB, delta 186.4 KB
-- and identical to the tenth of a KB on all 3 runs -- which is worth stating
-- for this file in particular, since its peak is set by GC pacing and pacing
-- was the thing most likely to wander between runs.  Between runs it did not.
-- (The base is 52.3 rather than an empty VM's ~41 because the measuring
-- harness holds this file's own source string; the delta, 186.4 KB, is the
-- workload.)
--
-- It does wander between *builds*, and by more than the depth ladder's steps
-- would suggest, so treat the last digit as decoration.  Editing this comment
-- header alone -- which changes nothing but the size of the source string the
-- VM holds -- walked the measured delta over 182.5, 185.0, 187.1 and 189.0 KB
-- across four revisions, a 3.5% band, on a kernel that never changed.  Do not
-- chase the last digit; the claim this file stands behind is "delta 186 KB,
-- +/- 4", i.e. peak ~240 KB against a 450 KB cap.  That is LuaJIT
-- pacing its GC against total heap: a
-- slightly larger base moves every collection slightly, and the peak follows.
-- It is the reason this row is sized with 1.9x of margin instead of depth 8's
-- 1.3x, because in a real machine the base is not an empty VM plus a source
-- string, it is a booted OpenComputers OS, and this 2.5% is the direction that
-- effect points in.
--
-- The depth ladder below was measured the same way on bare kernels without
-- this comment header, where depth 7 reports 220.7 KB -- the same workload:
--     depth 5  130.0 KB      depth 7  220.7 KB      depth 9   595.3 KB
--     depth 6  160.7 KB      depth 8  354.5 KB      depth 10 1126.7 KB
-- Hook-rate independent there too: sampling every 200 instructions instead of
-- every 2000 returned 221.6 KB for depth 7, a 0.4% difference.
--
-- Depth 7 is the largest that fits under the 300 KB working target, and the
-- gap to depth 8 is the reason to stop there rather than to spend the rest of
-- the 450 KB cap: 354.5 KB would leave only 1.27x of margin on the one
-- benchmark in the suite whose peak is set by GC *pacing* rather than by a
-- fixed live set, and pacing is the least portable quantity here -- in-machine
-- the heap already holds the booted OS, and LuaJIT sizes its GC steps against
-- total heap.  Depth 7 leaves 1.9x.  LuaJIT has no emergency GC: the first
-- refused allocation throws, and an oversized benchmark does not fail its own
-- row, it kills the machine and loses the whole run.
--
-- Do NOT re-measure the peak with the JIT on under a count hook.  That is the
-- sampling-hook-versus-JIT pathology this project already fixed once; it
-- measures the hook, not the benchmark.  Note also that the GC-stopped
-- total-allocation bound used to cross-check nqueens is useless here -- this
-- file allocates ~7.0M tables, so with the collector stopped the total is the
-- churn, not the peak.  The count hook is the measurement, and its
-- hook-rate independence above is what stands in for the cross-check.
--
-- WHAT SHRINKING COSTS, stated plainly.  Two properties are gone and one is
-- intact.
--   * Gone: GC *tracing* of a large live set.  The long-lived tree is 255
--     nodes (~20 KB), so marking is free.  Nothing in a 450 KB budget can
--     restore this, and nothing should try -- an OC machine has ~865 KB free
--     after boot, so a large live heap is not a state a player's program can
--     reach.  The suite cannot measure it because the platform cannot host it.
--   * Gone: the sweep across allocation sizes.  `for d = 4, 7, 2` visits only
--     d = 4 and d = 6, where the original visits 4, 6, 8, 10, 12, 14, 16.
--     Trees of depth 4, 6, 7 and 8 are still all built, so a mix remains, but
--     it is a narrow one.
--   * Intact, and it is the property this row exists for: allocation and
--     sweep throughput.  ~7.0M table allocations in 0.36 s under -joff.
--
-- That last point is why this is a port and not a drop.  The reason the suite
-- wants an allocator row at all is the per-allocation JNI accounting this
-- project just added to the RAM cap, and that cost is paid *per allocation* --
-- so a high allocation rate against a small live set is a sharper probe of it
-- than a deep tree would be, not a blunter one.
--
-- The speedup is also size-robust, which is the evidence that the rescaled row
-- still measures what the published one did.  Measured here, min of 3,
-- lua5.3 over LuaJIT: depth 5 3.8x, depth 6 4.4x, depth 7 3.2x, depth 8 3.7x
-- -- against the published 3.1x at depth 16.  Depth 7 lands on the published
-- figure (this file as shipped measures 3.7x; the whole ladder sits in
-- 3.2-4.4x, a band narrower than the 2x that separates sieve's two regimes).  (Contrast sieve in this directory, which does NOT survive rescaling
-- intact and carries a warning saying so.)
--
-- TIMES for THIS file on this box, loaded the way the harness loads it, min of
-- 5 for the LuaJIT rows and min of 3 for PUC:
--   lua5.3 1.048 s | lua5.4 0.816 s | luajit -joff 0.364 s | luajit 0.284 s
-- -- so 3.7x over lua5.3.  All four returned check 7038400.  One significant
-- figure only: across three sessions the lua5.3 row ranged 1.007-1.194 s, so
-- the honest statement is "about 3.5x", spread 3.2-3.7x.
-- Note the last two: the JIT is worth only 1.28x over this binary's own
-- interpreter, against 6.7x on sieve and 17.5x in-machine on mandelbrot.  That
-- is the expected and wanted shape -- the time is going into the allocator and
-- the collector, which the compiler does not speed up -- and it is what makes
-- this the row that would show a regression if the new RAM accounting has a
-- per-allocation cost.  A suite without it could not see that at all.
--
-- Why this one is otherwise in the suite: no bit operations, so it does not
-- depend on which branch compat.lua picks and needs no compat.lua at all; no
-- require() and no upvalues from outside, so it loads with a plain load(src)
-- off the filesystem proxy; integer-valued counting only, so the check is
-- identical on PUC 5.2, on 5.3/5.4 and on our LuaJIT both ways.
--
-- Run through bench/oc/checks/contract.lua -- which loads it exactly as
-- autorun.lua does, with io/print/collectgarbage/require/os.time poisoned --
-- it passes at 1.05-1.09 s on lua5.3, against the checker's 2.5 s budget.  Using
-- the checker's measured conversion (in-machine cell A ~= standalone lua5.3 x
-- 1.03) that projects to ~1.08 s in a real machine, against the 5 s
-- per-resume deadline it must fit in, since it does not yield and so runs as a
-- single resume.
--
-- Run standalone with bench/oc/run-standalone.sh to regenerate references.

local MINDEPTH, MAXDEPTH, REPS = 4, 7, 800

local function make(d)
  if d > 0 then
    return { make(d - 1), make(d - 1) }
  end
  return {}
end

local function nodes(t)
  local l = t[1]
  if l then
    return 1 + nodes(l) + nodes(t[2])
  end
  return 1
end

local total = 0
local clock = os.clock
local t0 = clock()

for _ = 1, REPS do
  total = total + nodes(make(MAXDEPTH + 1))    -- stretch tree
  local longlived = make(MAXDEPTH)             -- survives this repetition

  for d = MINDEPTH, MAXDEPTH, 2 do
    local iters = 1
    for _ = 1, MAXDEPTH - d + MINDEPTH do iters = iters * 2 end
    local sum = 0
    for i = 1, iters do
      sum = sum + nodes(make(d))
    end
    total = total + sum
  end

  total = total + nodes(longlived)
end
local t = clock() - t0

return string.format("%d", total), t
