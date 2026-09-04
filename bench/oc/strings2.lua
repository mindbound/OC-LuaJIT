-- bench/oc/strings2.lua -- the sandbox-runnable form of bench/strings2.lua.
--
-- The kernel is BYTE-FOR-BYTE bench/strings2.lua: the same 64-byte chunking,
-- the same 8-wide multi-assignment `string.byte` reads, the same fixed-arity
-- `string.char`, the same rolling checksum in the same order.  Exactly two
-- things differ, and both are forced by the sandbox rather than chosen:
--
--   1. BASE is 4096 here against 262144 there, and PASSES is 3072 against 48.
--      TOTAL WORK IS UNCHANGED -- 4096 x 3072 = 262144 x 48 = 12,582,912 bytes
--      transformed and checksummed either way.  Only the WORKING SET shrank,
--      from a 256 KB string to a 4 KB one, and that is a memory decision:
--      see MEMORY below.
--   2. The two print()s became a `return`, as for every file in this
--      directory: inside the sandbox print() goes to a scrolling terminal the
--      Java harness cannot reliably parse.
--
-- ============================================================= --
-- ITS TWIN IS NOT HERE, AND THAT IS THE HEADLINE                 --
-- ============================================================= --
--
-- This benchmark's whole point in results-2026-09-01.md was that it is the
-- IDIOMATIC HALF OF A PAIR.  bench/strings.lua computes the identical value by
-- the naive route -- `{ string.byte(s, i, i+63) }` into a table constructor and
-- `string.char(unpack(t, 1, 64))` back out -- and scored 0.25x, the only cell
-- in the whole study where the compiler LOSES.  strings2 is that same
-- computation written the way the tracer likes, and scored 3.70x.  Two codings
-- agreeing on one checksum is very hard to fake, which is what made the pair
-- the suite's independent oracle.
--
-- **bench/oc/strings.lua deliberately does not exist, and must not be
-- created -- nor may `strings` be added to bench/oc/references.txt, which is
-- the allowlist OcljSmoke actually builds the suite from (OcljSmoke.scala:850,
-- 867: every .lua in this directory is PLANTED on the disk, but only names
-- listed in references.txt are RUN).**  It cannot be run inside an
-- OpenComputers machine at ANY size.  The reason is not its data -- its data
-- is tiny -- it is that the pathology has a MEMORY dimension that the
-- standalone study never looked for and that the `luajit -joff` budget rule
-- structurally cannot see.
--
-- CORRECTED.  An earlier draft of this header claimed the naive twin leaves
-- ~1456 KB LIVE after a full collect, reclaimable only by jit.flush(), and
-- attributed that to 212 GCtrace objects held permanently on the heap.  That
-- does not reproduce.  Re-measured at exactly the parameters above, with FIVE
-- collect cycles rather than one (LuaJIT's collector is incremental, and one
-- cycle is not a full sweep) and with the trace count taken from `-jv`, which
-- needs LUA_PATH pointed at build/native/luajit/src or it silently does
-- nothing at all:
--
--   | naive strings, BASE=4096 PASSES=3072 | JIT on    | -joff   |
--   |--------------------------------------|-----------|---------|
--   | wall time                            | 2.739 s   | 0.430 s |
--   | ALLOCATED AT RETURN                  | 3064.3 KB |  90.2 KB|
--   | live after a full collect            |   70.7 KB |  48.1 KB|
--   | reclaimed by jit.flush()             |    0.0 KB |    --   |
--   | traces recorded (-jv)                |       210 |       0 |
--
-- Both columns return the same CHECK, so this is one computation measured two
-- ways.  Three things follow, and the middle one reverses the earlier draft:
--
--   1. THE PATHOLOGY IS REAL AND WORSE THAN PUBLISHED.  6.4x slower with the
--      compiler on than with it off, against the standalone study's 4x
--      (0.25x).  210 traces for a loop that should need one.
--   2. THE TRACES ARE NOT A LEAK.  They are ordinary GC objects; a full
--      collect takes them and jit.flush() then reclaims nothing.  Live heap is
--      ~70 KB, flat in the workload.  The earlier "1393 KB that only
--      jit.flush() reclaims" was garbage that had not been swept yet, read as
--      though it were live.
--   3. WHAT ACTUALLY KILLS IT IS ALLOCATION CHURN, not live state.  At the
--      moment the benchmark returns, 3064 KB is allocated with the JIT on
--      against 90 KB without -- 34x.  OC's cap is on allocated bytes, and
--      lj52_alloc refuses rather than collecting: there is no emergency GC on
--      this path.  A machine with 865-1024 KB free is very unlikely to survive
--      a workload that transiently holds 3 MB.
--
-- So the conclusion the earlier draft reached is kept and the reasoning behind
-- it is replaced.  The distinction matters for the mitigation: if the cost
-- were permanently-live compiler state, no amount of GC would help and only
-- jit.off() would; because it is churn, a machine with more headroom, or an
-- allocator that collected before refusing, might well run this fine.  That is
-- a fixable thing rather than a wall, and it should be written up as one.
--
-- WHY THE CHURN IS CHARGED TO THE MACHINE.  Trace objects and everything
-- hanging off them go through `lj_mem_*` -> `g->allocf`, which on this build
-- IS `lj52_alloc`.  So unlike machine code -- VirtualAlloc'd, invisible to the
-- cap, ~192 KB per machine unaccounted (native/lj52shim.c `_OCLJ_JITSTATS`,
-- Phase 0) -- every one of those bytes IS charged.  Being collectable does not
-- help if the allocator refuses before the collector runs, and on this path it
-- does: lj52_alloc returns NULL rather than forcing a GC.
--
-- IT CANNOT BE RESCALED AWAY, and that was checked rather than assumed.  The
-- footprint SATURATES almost immediately and is then flat in the workload --
-- a property of the code's SHAPE, not of how much data goes through it.
-- BASE 4096, JIT on, re-measured with the corrected method:
--
--   PASSES              8      64     256    3072
--   allocated at return  1088    3158    2470    3064   KB
--   live after collect     65      71      71      71   KB
--
-- (The earlier draft's row here read "live KB 754 / 1450 / 1456" and was the
-- same one-collect misreading; the trace counts it reported, 211-212, are
-- corroborated -- `-jv` prints 210 at PASSES=256.)
--
-- Even 8 passes -- 32 KB of work, not a benchmark -- already allocates 1088 KB
-- at return, more than the machine has free.  The non-monotonicity across the
-- row is GC timing, not a trend: what the row shows is that the figure is
-- ~1-3 MB everywhere and never approaches the budget.
--
-- NARROWING THE CHUNK DOES NOT SAVE IT EITHER; it just moves the cost from RAM
-- to the clock, and OC bills both.  Both halves of the pair were rewritten
-- around a chunk of W bytes instead of 64 and re-measured -- at BASE 4096 and
-- PASSES **768**, a QUARTER of the shipped work, which is why the W=64 row
-- reads 0.82 s where the shipped table below reads 3.365 s.  The two codings
-- still agreed on a checksum at every W, so the rows are like-for-like:
--
--   W    naive traces   naive KB(*)   naive s   idiomatic KB(*)   idiom s
--    8       293            398          7.99            66            0.049
--   16       283            602          3.04            75            0.053
--   32       290           1075          1.60            70            0.045
--   64       211           1450          0.82            74            0.046
--
-- (*) THESE TWO COLUMNS WERE TAKEN WITH THE BROKEN METHOD and have NOT been
-- re-measured; treat them as indicative only.  The time and trace columns are
-- unaffected.  The argument survives on the times alone: W=8 is the only row
-- whose memory could plausibly fit, and even at a quarter of the shipped work
-- it takes 7.99 s STANDALONE -- past OC's 5 s per-resume deadline before any
-- in-machine scaling, and ~32 s at the shipped size.  There is no W that fits
-- both walls.
--
-- SO THE TWIN IS QUARANTINED, NOT DELETED.  bench/oc/strings.lua DOES exist,
-- and its line in references.txt carries a leading "!": planted on the disk
-- and referenced, but kept out of the default suite and runnable only with
-- OCLJ_BENCH_ONLY=strings.  The reason to keep it is that every sentence above
-- is an INFERENCE from standalone measurements about what an OpenComputers
-- machine will do, and this project's standard is that a question which can be
-- measured should be.  The reason to quarantine it is that the persist and
-- restore milestones run AFTER the suite, so a run that loses the machine
-- would lose them too -- it deserves its own run, where losing the machine IS
-- the result.
--
-- WHAT IS AT STAKE.  "Naive byte-shuffling regresses 4x under the JIT" was
-- already the study's most uncomfortable finding, and in-machine it looks
-- worse: 6.4x slower here, with 34x the allocation churn.  If the machine
-- dies, the release-note sentence is "on a 1 MB machine that program does not
-- run slowly, it runs out of memory", and it belongs next to the 17.5x.  If it
-- survives, the sentence is about the churn being absorbed, and the suite gets
-- its 0.25x cell and its in-machine oracle back.  Either answer is worth one
-- run, and neither is worth asserting from here.
--
-- Until then the oracle is the standalone cross-check recorded under CHECK
-- below: the same two codings agreeing on one value across four VMs, on a box
-- with enough RAM to hold the compiler's tantrum.
--
-- ONE STEP IS AN INFERENCE, flagged as such.  3064 KB is real bytes, which is
-- what collectgarbage("count") and lj52_alloc both count.  OC divides by
-- `ramScaleFor64Bit` (pinned to 3.0 here) before the sandbox sees it --
-- inferred from memory-accounting.md's `setTotalMemory(kernelMemory +
-- ceil(memoryBytes * ramScale))` together with Phase 0 reading "1024/865" on a
-- 1024 KB machine, NOT from reading OC's source, which is not in this repo.
-- So the sandbox-visible churn is ~1021 KB against 865-1024 KB free: over, but
-- close enough that the divisor decides it, which is the second reason to
-- measure rather than assert.
--
-- ============================================================= --
--
-- CHECK.  Rescaling invalidates the published reference exactly as it did for
-- trampoline, so this file cannot inherit `12582912-1973928960`.  The new
-- reference is
--     12582912-3852468224
-- and it was MEASURED, not derived.  Eight runs agreed on it: both codings
-- (this file and its naive twin at these same parameters) x four VMs (our
-- LuaJIT compiled, our LuaJIT -joff, lua5.3, lua5.4), each loaded the way the
-- harness loads it -- source read off disk, `load(src)`, no arguments.
--
-- NOTE THE TRAP IN THAT STRING.  Its first field is `12582912`, byte-identical
-- to the published reference's first field, because that field is `totlen` and
-- totlen is exactly BASE x PASSES -- which the rescale deliberately preserved.
-- Only the accumulator moved.  A reader diffing the two must compare the WHOLE
-- string; half of it matching means only that the same number of bytes went
-- through.
--
-- THE PATHOLOGY SURVIVED THE RESCALE.  This was the condition for publishing
-- the pair at all.  Checked at the shipped parameters, min of 5 runs, all
-- eight cells in ONE interleaved batch so the two codings are like-for-like,
-- seconds:
--
--   VM                 naive     THIS FILE
--   luajit (JIT on)    3.365     0.198
--   luajit -joff       0.467     0.445
--   lua5.3             0.758     0.691
--   lua5.4             0.513     0.598
--
-- Naive under the JIT is **0.23x of lua5.3** (published at full size: 0.25x)
-- and **7.2x SLOWER than the same binary's own interpreter**.  This file is
-- **3.49x of lua5.3** (published: 3.70x) and 2.25x faster than its own
-- interpreter.  Both halves moved toward 1.0 by ~6% when the working set went
-- from 256 KB to 4 KB, and neither changed sign.  The finding is intact; it is
-- simply that only one half of it can be demonstrated inside a machine.
--
-- (lua5.4 being FASTER on the naive coding than on this one is not a rescale
-- artefact -- results-2026-09-01.md reports the same inversion at full size,
-- 0.595 against 0.613.  It is the one VM with no opinion about either shape.)
--
-- MEMORY, measured on THIS file at this path, not estimated.  Under
-- `luajit -joff`, sampling collectgarbage("count") on a count hook, at three
-- hook intervals to show the sampler is not missing the peak:
-- **264.5 / 262.5 / 265.7 KB total** at 200000 / 20000 / 2000 instructions
-- (204.9 / 202.8 / 206.1 KB above the loader's own 59.6 KB baseline).  It has
-- converged: a 100x finer sampler finds 0.5% more.
--
-- **references.txt should carry 280**, not 265.  The peak includes this file's
-- own source -- the harness reads it into a string and caches it (srcCache) --
-- so every edit to the header above moves the measured peak by a KB or two,
-- and a manifest number that a comment can invalidate is a trap.  280 KB
-- absorbs that.  It costs nothing: the RAM guard skips a row unless
-- `free >= peak*2 + 64`, so 280 asks for 624 KB of the 865-1024 KB available,
-- and the 450 KB budget still has 1.6x of headroom.
--
-- That the source counts at all is worth saying once: the header is ~12 KB of
-- the ~14 KB file.  The same kernel with the header stripped measured a
-- 44.0 KB baseline and a 241.9 KB peak.  Comments are not free in a 1 MB
-- machine; ~265 KB is the honest figure because ~265 KB is what gets planted.
--
-- Do NOT re-measure this with the JIT on under a count hook: a sampling loop
-- under a count hook forces the trace abort/recompile cycle this project
-- already fixed once, and measures the hook.  The JIT-on figure below was
-- taken with NO hook at all, reading the counter once on return.
--
-- Cross-VM, because cell A is a PUC VM and PUC pacing is not LuaJIT pacing --
-- same method, hook 20000: lua5.3 **361.8 KB**, lua5.4 186.5 KB.  lua5.3 is the
-- worst cell for this row and is still inside the budget.  (PUC has an
-- emergency GC and would collect rather than throw; LuaJIT does not, which is
-- why the LuaJIT number is the one the budget is set from.)
--
-- With the JIT ON, no hook: 320.7 KB on return, 87.8 KB after a full collect,
-- **12 traces**.  Hold that next to the twin's 210 traces and 3064 KB
-- allocated at return -- same workload, same checksum, same VM, and an ~18x
-- difference in how much compiler the two codings provoke and a ~10x
-- difference in what they ask the allocator for.
--
-- TIMING.  The slowest cell is lua5.3 at 0.691 s; scaled by the 1.34x
-- in-machine cost Phase 0 measured for mandelbrot (1.355 s standalone ->
-- 1.820 s in cell A) that projects to ~0.93 s against the 5 s per-resume
-- deadline, 5.4x of margin.  PASSES was chosen for that: at the original
-- 48 passes of a 4 KB string this row would run in ~11 ms and measure noise.
-- Run-to-run spread between batches on this box is ~20% even at min-of-5, so
-- quote these to two figures, not three.
--
-- Uses only os.clock / string.* / table.* -- no io, no os.time, no print, no
-- collectgarbage, no `arg`, no require, and no bit operations, so it does not
-- depend on which branch compat.lua picks and needs no compat.lua at all.
-- `table.unpack or unpack` is the same expression bench/oc/compat.lua uses for
-- M.unpack, so taking it inline here rather than through the module changes
-- nothing about what runs -- it only removes a dependency this file would
-- otherwise carry for one name.  It appears in setup only, outside the clock.
--
-- Run standalone with bench/oc/run-standalone.sh to regenerate references.

local byte, char, concat = string.byte, string.char, table.concat

-- setup: identical construction to bench/strings2.lua, 4 KB instead of 256 KB
local BASE, PASSES = 4096, 3072
local seed = 7
local buf, parts, n = {}, {}, 0
local up = table.unpack or unpack
for i = 1, BASE do
  seed = (seed * 16807 + 3) % 2147483647
  n = n + 1
  buf[n] = seed % 256
  if n == 64 then
    parts[#parts + 1] = char(up(buf, 1, 64))
    n = 0
  end
end
local data = concat(parts)

local clock = os.clock
local t0 = clock()
local acc, totlen = 0, 0
local s = data
for p = 1, PASSES do
  local len = #s
  local pk = p * 13
  local out, m = {}, 0
  for i = 1, len, 64 do
    for j = 0, 56, 8 do
      local q = i + j
      local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, q, q + 7)
      b1 = (b1 * 7 + pk + j + 1) % 256
      b2 = (b2 * 7 + pk + j + 2) % 256
      b3 = (b3 * 7 + pk + j + 3) % 256
      b4 = (b4 * 7 + pk + j + 4) % 256
      b5 = (b5 * 7 + pk + j + 5) % 256
      b6 = (b6 * 7 + pk + j + 6) % 256
      b7 = (b7 * 7 + pk + j + 7) % 256
      b8 = (b8 * 7 + pk + j + 8) % 256
      m = m + 1
      out[m] = char(b1, b2, b3, b4, b5, b6, b7, b8)
    end
  end
  s = concat(out)
  local c = 0
  for i = 1, len, 8 do
    local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, i, i + 7)
    c = (c * 33 + b1) % 4294967296
    c = (c * 33 + b2) % 4294967296
    c = (c * 33 + b3) % 4294967296
    c = (c * 33 + b4) % 4294967296
    c = (c * 33 + b5) % 4294967296
    c = (c * 33 + b6) % 4294967296
    c = (c * 33 + b7) % 4294967296
    c = (c * 33 + b8) % 4294967296
  end
  acc = (acc + c) % 4294967296
  totlen = totlen + len
end
local t = clock() - t0

-- "%.0f", NOT "%d", and this is a portability fix rather than a style choice.
-- acc reaches 3852468224, which is above 2^31.  Cell A of the in-machine
-- matrix is PUC Lua 5.2 -- the one interpreter references.txt never verified
-- against -- and there string.format("%d", acc) raises
--     strings2:318: bad argument #3
-- every single time: the in-machine encore ran this file twelve times in a PUC
-- machine and failed twelve times on this line, which is why the whole strings
-- pair looked like a memory failure in that cell when it was a formatting one.
-- "%.0f" prints the same digits on every VM here (verified: LuaJIT, PUC 5.3
-- and PUC 5.4 all render 12582912-3852468224 identically either way), so the
-- reference value is unchanged.
return string.format("%.0f-%.0f", totlen, acc), t
