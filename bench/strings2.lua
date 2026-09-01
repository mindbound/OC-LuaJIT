-- strings2.lua: the SAME workload as strings.lua (byte-identical CHECK),
-- rewritten in LuaJIT-friendly style: 8-wide multi-assignment reads from
-- string.byte and fixed-arity string.char, no table-constructor-from-
-- multi-return and no unpack — the two patterns that cause the side-trace
-- explosion measured in strings.lua.

local byte, char, concat = string.byte, string.char, table.concat

-- setup: identical 128 KB deterministic base string (see strings.lua)
local BASE, PASSES = 262144, 48
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

print(string.format("CHECK %d-%d", totlen, acc))
print(string.format("TIME %.3f", t))
