-- bench_numconv.lua [N] -- FIX-NUMCONV's own bench (numconv/proto,
-- 2026-10-21): realistic uses of an identity result, x | 0 on a double,
-- the 5.3 idiom that turns a float with an integral value into an integer
-- (and raises for any other).  x | 0 folds to the operand's own conversion,
-- CONV i64.num x, whose result guard FIX-NUMCONV removes; the operand's
-- guard (x integral and in range) stays.  Every value here is an integral
-- double, so nothing raises.  Rows, each the best of 3 (os.clock), ns per
-- iteration, and its result:
--   ref    the arith loop without | 0 (no bit operator: must not change)
--   arith  n = T[j] | 0 summed: an identity result in arithmetic
--   key    k = F[j] | 0 used as a table key, F holding float indexes
--   bits   n = T[j] | 0 feeding two more bit operators, (n & 0xff) and
--          ((n >> 8) & 0xff)
--   floor  math.floor(T[j] * 0.5) | 0: a float computation made an integer
-- N defaults to 2e7 (os.clock's 1 ms step is 0.05 ns at 2e7; guide 11.12).
local N = tonumber(arg and arg[1]) or 2e7
local SRC = {
  ref = [[
    local T, F, U, n = ...
    local s = 0
    for i = 1, n do
      s = s + T[(i & 1023) + 1]
    end
    return s ]],
  arith = [[
    local T, F, U, n = ...
    local s = 0
    for i = 1, n do
      local v = T[(i & 1023) + 1] | 0
      s = s + v
    end
    return s ]],
  key = [[
    local T, F, U, n = ...
    local s = 0
    for i = 1, n do
      local k = F[(i & 1023) + 1] | 0
      s = s + U[k]
    end
    return s ]],
  bits = [[
    local T, F, U, n = ...
    local s = 0
    for i = 1, n do
      local v = T[(i & 1023) + 1] | 0
      s = s + (v & 0xff) + ((v >> 8) & 0xff)
    end
    return s ]],
  floor = [[
    local T, F, U, n = ...
    local s = 0
    for i = 1, n do
      s = s + (math.floor(T[(i & 1023) + 1] * 0.5) | 0)
    end
    return s ]],
}
local ORDER = { "ref", "arith", "key", "bits", "floor" }
-- T: integral doubles, small and large (file sizes, millisecond times);
-- F: table indexes 1..1024 computed in floating point; U: values to look up.
local T, F, U = {}, {}, {}
for k = 1, 1024 do
  T[k] = (k % 3 == 0) and (1.7e12 + k * 1000) or (k * 7919)
  F[k] = math.floor(k * 0.61803398875 * 1024) % 1024 + 1
  U[k] = k * 3
end
local function t(f, n)
  local best, r = math.huge, nil
  for _ = 1, 3 do
    local t0 = os.clock(); r = f(T, F, U, n); local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best / n * 1e9, r
end
local out = {}
for _, name in ipairs(ORDER) do
  local f = assert(load(SRC[name], "=" .. name))
  local ns, r = t(f, N)
  out[#out + 1] = string.format("%s %.2f (r=%.17g)", name, ns, r)
end
print(table.concat(out, " | "))
