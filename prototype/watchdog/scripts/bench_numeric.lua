-- (f) Honest benchmark: bit-ops heavy integer mixing loop (SHA-ish).
-- Exercises the 'bit' library (band/bor/bxor/rshift/lshift/rol) in a tight
-- loop -- the workload most sensitive to the CHECKHOOK per-loop guard,
-- because it is a pure compiled inner loop with many bit ops per iteration.
-- Runs to completion; compare wall-clock across:
--   JIT on (stock) vs --jitoff vs JIT on (CHECKHOOK build).
--
-- Expected: --expect complete
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local rshift, lshift, rol = bit.rshift, bit.lshift, bit.rol

local N = tonumber(arg and arg[1]) or 20000000
local h0 = 0x6a09e667
local h1 = 0xbb67ae85
local a = 0x12345678
for i = 1, N do
  -- a cheap ARX-style mixing round, all in 'bit'
  a = bxor(a, rol(a, 13))
  a = band(a + i, 0xffffffff)
  a = bxor(a, rshift(a, 7))
  h0 = band(h0 + bxor(a, lshift(a, 5)), 0xffffffff)
  h1 = bxor(h1, bor(h0, a))
end
print("numeric checksum: " .. band(bxor(h0, h1), 0xffffffff))
