-- Does every file in bench/oc/ satisfy the SANDBOX contract?
--
-- The reference script checks that the CHECK values agree between VMs.  This
-- checks something different and equally load-bearing: that each benchmark
-- still works when loaded the way autorun.lua actually loads it, which is not
-- how anyone runs it while developing it.  In the machine there is
--   * no require() that can see the disk -- compat arrives via _G.__OCLJ_COMPAT
--   * no arguments -- the chunk is called with none
--   * no io, no os.time, no print, no collectgarbage
-- and the driver expects exactly two return values, (string, number).
--
-- A benchmark that fails any of these does not fail its own row; it produces
-- an ERROR row, or worse a row whose number means something other than what
-- the column header says.

-- IT ALSO ENFORCES THE SIZING RULE, which is about OC's per-resume DEADLINE
-- and not about memory.  A benchmark gets 5 s of machine time before
-- machine.lua kills the resume with "too long without yielding"; the suite
-- driver turns that into a DEADLINE row rather than a dead machine, but a
-- DEADLINE row means that cell has no number and the A-vs-C ratio is lost.
--
-- The conversion factor is measured, not assumed.  Phase 0 ran mandelbrot in a
-- real machine on PUC 5.2 at 1.820 s, and the same file standalone on lua5.3
-- takes 1.773 s -- so
--     in-machine cell A  ~=  standalone lua5.3 x 1.03
-- (the OC sandbox and its standing deadline hook cost almost nothing on a
-- compute loop; what they cost is the JIT, which is the whole project).
-- Requiring <= 2.5 s on lua5.3 therefore leaves about 2x of headroom.
--
-- BUT THE TIMES PRINTED HERE ARE NOT MEASUREMENTS, and must not be used as
-- one.  This script runs every benchmark back to back IN ONE PROCESS, so each
-- row inherits the heap and the GC state the previous row left behind; run
-- against the same files that bench/oc/run-standalone.sh measures at 1.819 s
-- (min of 15, one fresh process per run) this script reported 2.82 s and
-- 3.58 s on two consecutive passes.  It flags a row for a LOOK, and the
-- authoritative number comes from run-standalone.sh.  Over-budget is therefore
-- a WARNING here and does not fail the check -- the first draft of this file
-- failed two correctly-sized benchmarks on its own measurement noise.
--
-- Benchmarks that use compat's bit operations get a further handicap in cell
-- A: PUC 5.2 cannot parse bitwise operators, so it takes the bit32 branch, one
-- C call per operation.  Measured at 1.5x on an interpreter (see
-- compat-branches.lua for the correctness half of that story), and that is a
-- LOWER bound, since PUC's call overhead is higher than LuaJIT's.
local BUDGET = 2.5

local R = arg[1] or "."
local names = {}
for i = 2, #arg do names[#names + 1] = arg[i] end

local function slurp(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

-- compat, loaded the way the driver loads it, and published the same way
local csrc = assert(slurp(R .. "/bench/oc/compat.lua"), "no bench/oc/compat.lua")
_G.__OCLJ_COMPAT = assert(load(csrc, "=compat"))()
print("compat path = " .. tostring(_G.__OCLJ_COMPAT.path))

-- The sandbox denials.  Each benchmark is loaded with these shadowed to a
-- poisoned value, so a benchmark that reaches for one fails HERE, on a
-- developer machine with a stack traceback, instead of inside the emulator
-- where all that comes back is a row saying ERROR.
local DENIED = {"io", "print", "collectgarbage", "require", "dofile", "loadfile", "arg"}

local bad, warned = 0, 0
for _, name in ipairs(names) do
  local src = slurp(R .. "/bench/oc/" .. name .. ".lua")
  if not src then
    print(string.format("%-12s MISSING", name)); bad = bad + 1
  else
    local saved = {}
    for _, k in ipairs(DENIED) do saved[k] = _G[k] end
    -- os stays, but only os.clock: the sandbox's os.time and os.date are not
    -- the ones a benchmark would expect, and os.clock is machine.cpuTime.
    local realos = _G.os
    _G.os = setmetatable({clock = realos.clock}, {__index = function(_, k)
      error("benchmark reached for os." .. k .. ", which the OC sandbox does not provide as expected", 2)
    end})
    for _, k in ipairs(DENIED) do
      _G[k] = setmetatable({}, {__index = function() error("benchmark reached for the denied global '" .. k .. "'", 2) end,
                                __call = function() error("benchmark called the denied global '" .. k .. "'", 2) end})
    end
    local fn, lerr = load(src, "=" .. name)
    local ok, a, b
    if fn then ok, a, b = pcall(fn) else ok, a = false, lerr end
    _G.os = realos
    for _, k in ipairs(DENIED) do _G[k] = saved[k] end

    if not ok then
      print(string.format("%-12s FAIL   %s", name, tostring(a))); bad = bad + 1
    elseif type(a) ~= "string" then
      print(string.format("%-12s FAIL   first return is %s, must be a string (the driver compares it textually)",
        name, type(a))); bad = bad + 1
    elseif type(b) ~= "number" then
      print(string.format("%-12s FAIL   second return is %s, must be the elapsed seconds",
        name, type(b))); bad = bad + 1
    else
      -- The budget applies to the SLOWEST cell, so it is only meaningful on a
      -- PUC VM.  On LuaJIT the same number would pass trivially and say
      -- nothing, so the warning is suppressed rather than made misleading.
      local slow = _VERSION and not jit
      local warn = ""
      if slow and b > BUDGET then
        warn = string.format("   <- WARN %.2f s here exceeds the %.1f s budget; confirm with run-standalone.sh before resizing",
          b, BUDGET)
        warned = warned + 1
      end
      print(string.format("%-12s ok     CHECK=%s  %.4f s%s", name, a, b, warn))
    end
  end
end
print((bad == 0 and "CONTRACT: all pass" or ("CONTRACT: " .. bad .. " FAILED"))
  .. (warned > 0 and ("  (" .. warned .. " over the time budget -- confirm with run-standalone.sh)") or ""))
os.exit(bad == 0 and 0 or 1)
