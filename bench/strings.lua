-- strings.lua: pure-Lua string building/processing. Byte-wise transform with
-- string.byte/string.char in 64-byte chunks + table.concat, then a rolling
-- checksum. No gsub/find (those are C in every VM).
-- CHECK = totalbytes-accumulator.

local C = require("compat")
local up = C.unpack
local byte, char, concat = string.byte, string.char, table.concat

-- setup: 128 KB deterministic base string
local BASE, PASSES = 262144, 48
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
  -- transform: read bytes in chunks, remap, rebuild via char + concat
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

print(string.format("CHECK %d-%d", totlen, acc))
print(string.format("TIME %.3f", t))
