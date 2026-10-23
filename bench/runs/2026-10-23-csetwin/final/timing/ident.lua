-- ident.lua [N] [time]: identity bit operations on doubles at and past 2^53.
-- The result of x | 0 (x & -1, x ~ 0, x << 0, x >> 0, ~~x) is the operand's
-- own int64, CONV i64.num x, which is always a double's value: the result
-- guard after it can never fail on the shipped build, and the range guard
-- (rg2) fails for every |x| >= 2^53.  Prints one line per loop: its name,
-- the sum, and with "time" the ns per iteration (os.clock, best of 3).
local N = tonumber(arg and arg[1]) or 2000
local TIME = arg and arg[2] == "time"
local A = {}
for i = 1, 1024 do
  local k = i % 4
  A[i] = (k == 0 and 2^53) or (k == 1 and 2^62 + 2^20) or (k == 2 and -2^60) or (2^53 + 2)
end
local SMALL = {}
for i = 1, 1024 do SMALL[i] = i * 3 end
local LOOPS = {
  { "or0", function(T, n) local s = 0; for i = 1, n do s = s + ((T[(i & 1023) + 1] | 0) % 7) end; return s end },
  { "andm1", function(T, n) local s = 0; for i = 1, n do s = s + ((T[(i & 1023) + 1] & -1) % 7) end; return s end },
  { "xor0", function(T, n) local s = 0; for i = 1, n do s = s + ((T[(i & 1023) + 1] ~ 0) % 7) end; return s end },
  { "shl0", function(T, n) local s = 0; for i = 1, n do s = s + ((T[(i & 1023) + 1] << 0) % 7) end; return s end },
  { "shr0", function(T, n) local s = 0; for i = 1, n do s = s + ((T[(i & 1023) + 1] >> 0) % 7) end; return s end },
}
for _, L in ipairs(LOOPS) do
  for _, which in ipairs({ "big", "small" }) do
    local T = which == "big" and A or SMALL
    local r = L[2](T, N)
    local line = string.format("%s-%s\t%.17g", L[1], which, r)
    if TIME then
      local best = math.huge
      for _ = 1, 3 do
        local t0 = os.clock()
        L[2](T, N)
        local t = os.clock() - t0
        if t < best then best = t end
      end
      line = line .. string.format("\t%.2f ns/it", best / N * 1e9)
    end
    print(line)
  end
end
