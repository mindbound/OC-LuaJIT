-- bench_bit.lua: bitop loop vs an arithmetic loop of the same shape, same run.
-- Prints ns/iteration for each and the ratio bit/ref. Unpinned; indicative only.
local N = tonumber(arg and arg[1]) or 2e7
local bit_loop = assert(load([[
  local n = ...
  local x = 0
  for i = 1, n do x = (x ~ (i << 3)) & 0xffffff end
  return x
]]))
local ref_loop = assert(load([[
  local n = ...
  local x = 0
  for i = 1, n do x = (x + (i * 8)) % 16777216 end
  return x
]]))
-- a CRC32-shaped inner loop (table-free), the typical consumer pattern
local crc_loop = assert(load([[
  local n = ...
  local c = 0xffffffff
  for i = 1, n do
    local b = (c ~ i) & 0xff
    for _ = 1, 8 do
      if b & 1 == 1 then b = (b >> 1) ~ 0xedb88320 else b = b >> 1 end
    end
    c = (c >> 8) ~ b
  end
  return c ~ 0xffffffff
]]))
local function t(f, n)
  local best = math.huge
  local r
  for _ = 1, 3 do
    local t0 = os.clock()
    r = f(n)
    local dt = os.clock() - t0
    if dt < best then best = dt end
  end
  return best / n * 1e9, r
end
local tb, rb = t(bit_loop, N)
local tr, rr = t(ref_loop, N)
local tc, rc = t(crc_loop, N / 10)
print(string.format("bit %.2f ns/it (r=%.17g)  ref %.2f ns/it (r=%.17g)  ratio %.2f  crc %.2f ns/byte (r=%.17g)",
  tb, rb, tr, rr, tb / tr, tc, rc))
