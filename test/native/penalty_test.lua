-- penalty_test.lua -- driven by penalty_test.c (the checks are listed there).
--
--   penalty_test penalty_test.lua <N re-loads> <path to bench/oc/mandelbrot.lua>
--
-- Quiet while it runs: rows are kept as numbers and printed at the end, so
-- the heap's size class the prototype lives in sees as little churn as
-- possible and a dead prototype's address can recur -- which is the case the
-- cure exists for, and the case an unpatched library must be SEEN to fail.
-- Returns the failure count (the host turns it into the exit status).
local jutil = require("jit.util")
local bit = require("bit")
local P = penalty

local N = tonumber(arg[1]) or 40
local path = assert(arg[2], "need the path to bench/oc/mandelbrot.lua")
local f = assert(io.open(path, "rb"))
local src = f:read("*a")
f:close()
local EXPECT = "37904620"   -- bench/oc/mandelbrot.lua's published CHECK

local checks, failures = 0, 0
local function ok(cond, what, detail)
  checks = checks + 1
  if not cond then failures = failures + 1 end
  print(string.format("  %s  %-62s %s", cond and "PASS" or "FAIL", what, detail or ""))
end

-- Loop-head opcodes, by number from the library's own lj_bc.h (penalty_test.c).
local NAMES, BLACK = {}, {}
for _, k in ipairs { "LOOP", "ILOOP", "JLOOP", "FORL", "IFORL", "JFORL", "ITERL", "IITERL", "JITERL" } do
  NAMES[P["BC_" .. k]] = k
end
BLACK[P.BC_ILOOP], BLACK[P.BC_IFORL], BLACK[P.BC_IITERL] = true, true, true

-- every loop head in fn's OWN bytecode, as {pc, op} pairs
local function heads(fn)
  local n = jutil.funcinfo(fn).bytecodes
  local out = {}
  for pc = 0, n - 1 do
    local ins = jutil.funcbc(fn, pc)
    if ins then
      local op = bit.band(ins, 0xff)
      if NAMES[op] then out[#out + 1] = { pc, op } end
    end
  end
  return out
end
local function headstr(hs)
  local t = {}
  for _, h in ipairs(hs) do t[#t + 1] = h[1] .. "=" .. NAMES[h[2]] end
  return table.concat(t, " ")
end
local function blacklisted(hs)
  for _, h in ipairs(hs) do if BLACK[h[2]] then return true end end
  return false
end

-- ---------------------------------------------------------------- re-loads
local rows, visit = {}, {}
local prev_base, prev_size
for run = 1, N do
  -- The adapter's post-save collect, twice: one cycle is not a full sweep on
  -- LuaJIT (see the project memory), and the prototype must actually DIE
  -- here for its block to be reusable.
  collectgarbage("collect"); collectgarbage("collect")
  -- P4: the previous prototype is dead and collected.  Does anything in the
  -- cache still point into its bytecode?
  local dead = -1
  if prev_base then dead = P.slots_in(prev_base, prev_size) end
  local fn = assert(load(src, "=mandelbrot"))
  local base, size = P.bcbase(fn)
  visit[base] = (visit[base] or 0) + 1
  local inherited, inhmax = P.slots_in(base, size)   -- before the fresh prototype has run at all
  local t0 = P.clock()
  local okr, check, secs = pcall(fn)
  local ms = P.clock() - t0
  local hs = heads(fn)
  local after, aftmax = P.slots_in(base, size)
  rows[run] = { ms = ms, base = base, visit = visit[base], dead = dead,
                inherited = inherited, inhmax = inhmax, after = after, aftmax = aftmax,
                heads = hs, black = blacklisted(hs), ok = okr and check == EXPECT,
                check = tostring(check), live = P.live_traces() }
  prev_base, prev_size = base, size
  fn = nil
end

print(string.format("re-loads of %s, N=%d, full collect between each:", path, N))
local first = rows[1].ms
local nbad, nblack, maxratio, maxdead, firstblack = 0, 0, 0, 0, nil
for run = 1, N do
  local r = rows[run]
  local ratio = r.ms / first
  if not r.ok then nbad = nbad + 1 end
  if r.black then nblack = nblack + 1; firstblack = firstblack or run end
  if ratio > maxratio then maxratio = ratio end
  if r.dead > maxdead then maxdead = r.dead end
  print(string.format("  run %2d: %s %7.1f ms (%4.2fx run 1)  bc=%x visit %d  dead-proto slots=%d  inherited=%d (max val %d) after=%d (max val %d)  live=%d  heads: %s%s",
    run, r.ok and "ok " or "BAD", r.ms, ratio, r.base % 4294967296, r.visit, r.dead,
    r.inherited, r.inhmax, r.after, r.aftmax, r.live, headstr(r.heads),
    r.black and "   <- BLACKLISTED" or ""))
end

print("")
ok(nbad == 0, "P1 every re-load computed the published checksum",
  string.format("%d/%d ok (expect %s)", N - nbad, N, EXPECT))
ok(nblack == 0, "P2 no re-load reads a blacklisted loop head (ILOOP/IFORL/IITERL)",
  nblack == 0 and string.format("0/%d", N)
    or string.format("%d/%d re-loads blacklisted, first at run %d (visit %d of bc=%x)",
         nblack, N, firstblack, rows[firstblack].visit, rows[firstblack].base % 4294967296))
ok(maxratio <= 3.0, "P3 no re-load slower than 3x the first",
  string.format("run 1 %.1f ms, slowest %.2fx", first, maxratio))
ok(maxdead == 0, "P4 no penalty slot outlives its prototype (the mechanism)",
  string.format("max slots still pointing into a dead prototype's bytecode = %d", maxdead))

-- ------------------------------------------------------ positive controls
-- The cure must not disable blacklisting.  A loop whose recording always
-- aborts must still be rewritten within ONE live prototype: PENALTY_MIN
-- doubles past PENALTY_MAX after 11 aborts, ~74k iterations at the default
-- hotcount, so 400k is ample.  The body creates a closure: BC_FNEW is an
-- unconditional "NYI: bytecode" abort in lj_record.c (a plain C call is NOT
-- -- since 2.1 the recorder stitches a new trace across it, and the first
-- draft of this control compiled to JLOOP in 9.6 ms).
local function control(name, chunk, want, wantname)
  local fn = assert(load(chunk, "=" .. name))
  local base, size = P.bcbase(fn)
  local t0 = P.clock()
  local n = fn()
  local ms = P.clock() - t0
  local hs = heads(fn)
  local got = hs[1] and NAMES[hs[1][2]] or "no loop head"
  local slots, maxval = P.slots_in(base, size)
  ok(hs[1] ~= nil and hs[1][2] == want,
    "P" .. name .. " blacklisting still works within a live prototype (-> " .. wantname .. ")",
    string.format("head reads %s after %d iterations in %.1f ms; penalty slots in proto=%d max val %d",
      got, n, ms, slots, maxval))
  fn = nil
end
control("5 while", "local i, f = 0, nil while i < 400000 do i = i + 1 f = function() return i end end return i",
  P.BC_ILOOP, "ILOOP")
control("6 for", "local n, f = 0, nil for i = 1, 400000 do n = n + 1 f = function() return i end end return n",
  P.BC_IFORL, "IFORL")

print("")
print(string.format("checks=%d failures=%d", checks, failures))
return failures
