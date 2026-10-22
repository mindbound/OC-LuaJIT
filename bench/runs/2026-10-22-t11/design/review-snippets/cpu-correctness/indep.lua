-- Independent references with no bit operators: 32-bit xor and shifts by
-- arithmetic on non-negative integers below 2^32.
local function bxor(a, b)
  local r, p = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + p end
    a, b, p = (a - x) / 2, (b - y) / 2, p * 2
  end
  return r
end
local function shl32(a, n) return (a * 2 ^ n) % 4294967296 end
local function shr(a, n) return math.floor(a / 2 ^ n) end

-- CRC32 reflected, poly 0xEDB88320, bit by bit.
local POLY = 3988292384
local function crc(s)
  local c = 4294967295
  for i = 1, #s do
    c = bxor(c, s:byte(i))
    for _ = 1, 8 do
      if c % 2 == 1 then c = bxor(shr(c, 1), POLY) else c = shr(c, 1) end
    end
  end
  return bxor(c, 4294967295)
end
local parts = {}
for i = 1, 4096 do parts[i] = string.char((i * 7 + 3) % 256) end
local DATA = table.concat(parts)
print("crc '123456789'", string.format("%.0f", crc("123456789")))
print("crc DATA", string.format("%.0f", crc(DATA)))

local function xs(x)
  x = bxor(x, shl32(x, 13))
  x = bxor(x, shr(x, 17))
  x = bxor(x, shl32(x, 5))
  return x
end
local x = 2463534242
x = xs(x)
print("xorshift32 step 1", string.format("%.0f", x))
for _ = 2, 1000 do x = xs(x) end
print("xorshift32 step 1000", string.format("%.0f", x))
local d = 3735928559
print("rotr(0xDEADBEEF,7)", string.format("%.0f", shr(d, 7) + shl32(d, 25)))
