-- bench/oc/strings.lua -- the NAIVE half of the strings pair, QUARANTINED.
--
-- ============================================================= --
-- IT KILLS THE MACHINE WITH THE JIT ON, AND ONLY THEN.            --
-- ============================================================= --
--
-- Its line in bench/oc/references.txt begins with "!", which means OcljSmoke
-- plants it on the disk and knows its reference value but leaves it OUT of the
-- default suite.  It runs only when named:
--
--     OCLJ_BENCH_ONLY=strings test/native/smoke-test.sh
--
-- That is deliberate, and the reason is scheduling rather than cowardice: the
-- persist and restore milestones (f1-f5, m3) run AFTER the suite, so a run
-- that loses the machine here would also lose them.  On its own run, losing
-- the machine IS the result.
--
-- WHAT IT IS.  Byte-for-byte the computation in bench/strings.lua -- the naive
-- coding, `{ byte(s, i, i+63) }` into a table constructor and
-- `char(unpack(t, 1, 64))` back out -- at the SAME parameters as its idiomatic
-- twin bench/oc/strings2.lua (BASE 4096, PASSES 3072; the twin's header
-- explains why those and not the original 262144/48).  Both must return
--
--     12582912-3852468224
--
-- and that agreement is the point of keeping the pair: two different codings
-- of one computation arriving at one value is very hard to fake, and it is the
-- only oracle in the suite that does not rest on a single implementation.
--
-- WHY IT IS EXPECTED TO FAIL, measured standalone at these exact parameters:
--
--                                    JIT on     -joff
--     wall time                      2.739 s    0.430 s     6.4x SLOWER
--     ALLOCATED AT RETURN            3064.3 KB   90.2 KB    34x
--     live after a full collect        70.7 KB   48.1 KB
--     reclaimed by jit.flush()          0.0 KB      --
--     traces recorded (-jv)               210          0
--
-- The machine has 865-1024 KB free after boot.  Allocation is charged through
-- g->allocf -> lj52_alloc, and lj52_alloc REFUSES rather than collecting --
-- there is no emergency GC on that path -- so 3 MB of transient churn in a
-- 1 MB machine is expected to throw.  It is CHURN, not a leak: the traces are
-- ordinary GC objects and a full collect takes them.  Whether OC's own GC
-- pressure gets there first is exactly what this run is for.
--
-- Read bench/oc/strings2.lua's header before interpreting any of this; it
-- carries the full argument, including a retraction of an earlier draft that
-- reported the churn as permanently-live compiler state.
--
-- MEASURED 2026-09-04, AND THE PREDICTION ABOVE IS HALF WRONG.  One run per
-- cell, one benchmark per freshly booted machine:
--
--   B  ours, JIT OFF   ok, 12582912-3852468224, 1.1043 s, 936 KB FREE AFTER
--                      plus three more correct encore samples in the same
--                      machine.  It fits comfortably.  The -joff half of the
--                      standalone prediction is CONFIRMED in a real machine.
--   C  ours, JIT ON    DIES: "not enough memory", inside strings rep 1.
--
-- The C result took three runs and a harness fix to establish, and the two
-- intermediate readings were both wrong, so the sequence is worth keeping.
-- Run 1 wedged: 463 s of wall clock, no row, the machine still reporting
-- isRunning, and 903 KB free at the last paint -- which read as "the
-- benchmark never started", because the scoreboard was only repainted by a
-- 0.05 s timer that stops when the machine does, and startSuite() calls
-- unit() synchronously so no tick falls between "suite started" and "inside
-- the benchmark".  Those two states were literally indistinguishable on
-- screen.  Painting the row synchronously before each pcall separated them:
--
--     OCLJPDONE=pending OCLJPNOW=strings#1 OCLJPCOMPAT=operators
--     OCLJP01=strings/pending/-/-1.0000/-1.0000/0/0
--     !! MACHINE STOPPED during the Phase 1 suite:
--        running=false lastError=not enough memory     (16.5 s, not 463 s)
--
-- So: the suite had started, compat had loaded, 909 KB was free on entry, and
-- the machine died of memory INSIDE strings on its first repetition.
--   A  PUC 5.2         no row; machine gone before Phase 0, cause not logged.
--                      Cell A could not have produced the checksum anyway --
--                      see the "%.0f" note at the bottom of this file.
--
-- THE SENTENCE THIS FILE PREDICTED IS THEREFORE SUPPORTED, but only for the
-- compiled cell and only with the attribution above: on a 1 MB OpenComputers
-- machine, with the JIT on, this program does not run slowly -- it runs out of
-- memory; with the JIT off the identical file finishes in 0.55 s with 990 KB
-- free.  Same native, same kernel, same machine, same source: the compiler's
-- allocation churn is the whole difference between running and not running.
--
-- Note that the failure does NOT come back as an ERROR row the way cell B's
-- sieve does (sieve/ERROR/not_enough_memory/...).  The driver pcalls each
-- benchmark, but this allocation failure kills the machine rather than
-- unwinding into the pcall, so the evidence is the frozen row plus the
-- harness's lastError, not a status field.
--
-- ONE UNEXPLAINED FINDING WORTH KEEPING: the only two machines in the matrix
-- that ran strings could not be resumed from their own save (restored
-- lastError = "not enough memory"), while strings2 restored cleanly from a
-- LARGER blob in both cells.  That is awkward for the churn story, since cell
-- C never ran the benchmark at all, and it is unresolved.
--
-- CONTRACT.  Same as every file in this directory: no require() that can see
-- the disk (compat arrives as _G.__OCLJ_COMPAT, with a require() fallback so
-- the file also runs standalone), no io, no print, no collectgarbage, and the
-- last statement returns (CHECK string, seconds).

local C = _G.__OCLJ_COMPAT
if not C and type(require) == "function" then C = require("compat") end
if type(C) ~= "table" then
  error("strings: no compat -- the harness must set _G.__OCLJ_COMPAT", 0)
end
local up = C.unpack
local byte, char, concat = string.byte, string.char, table.concat

-- setup: deterministic base string.  BASE/PASSES differ from bench/strings.lua
-- and match bench/oc/strings2.lua exactly, so the two remain comparable; total
-- work is unchanged at 4096 x 3072 = 262144 x 48 bytes.
local BASE, PASSES = 4096, 3072
local seed = 7
local buf, parts, n = {}, {}, 0
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
  -- transform: read bytes in chunks, remap, rebuild via char + concat.
  -- THIS is the pathological shape: a table constructor fed by a multi-return
  -- string.byte, and a wide unpack back into string.char.  The recorder cannot
  -- keep the 64 stack slots stable across the loop, so it specialises, exits,
  -- and re-records -- 210 traces for one loop.
  local out, m = {}, 0
  for i = 1, len, 64 do
    local t = { byte(s, i, i + 63) }
    for k = 1, 64 do
      t[k] = (t[k] * 7 + p * 13 + k) % 256
    end
    m = m + 1
    out[m] = char(up(t, 1, 64))
  end
  s = concat(out)
  -- rolling checksum over the rebuilt string
  local c = 0
  for i = 1, len, 64 do
    local t = { byte(s, i, i + 63) }
    for k = 1, 64 do
      c = (c * 33 + t[k]) % 4294967296
    end
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
