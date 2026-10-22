-- The T10 reference values, recomputed: CRC32 of DATA and of "123456789",
-- xorshift32 after 1 and 1000 steps from 2463534242, rotr(0xDEADBEEF, 7),
-- the x|0 and pack sums.  Run on PUC 5.3.6 and on our luajit.exe.
local byte, char = string.byte, string.char
local parts = {}
for i = 1, 4096 do parts[i] = char((i * 7 + 3) % 256) end
local DATA = table.concat(parts)
local CRCT = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRCT[i] = c
end
local function crc(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do c = (c >> 8) ~ CRCT[(c ~ byte(s, i)) & 0xFF] end
  return c ~ 0xFFFFFFFF
end
print("crc 123456789", string.format("%d", crc("123456789")))
print("crc DATA", string.format("%d", crc(DATA)))
local x = tonumber("2463534242")
for s = 1, 1000 do
  x = x ~ ((x << 13) & 0xFFFFFFFF)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & 0xFFFFFFFF)
  if s == 1 then print("xs step1", string.format("%d", x)) end
end
print("xs step1000", string.format("%d", x))
local d = tonumber("3735928559")
print("rotr7", string.format("%d", (d >> 7) | ((d << 25) & 0xFFFFFFFF)))
local FL = {}
for i = 1, 1024 do FL[i] = (i - 500) * 3.0 end
local s = 0
for i = 1, 1024 do s = s + (FL[i] | 0) end
local orr = 0
for i = 1, 1024 do orr = orr + FL[i] end
print("or0", s, orr, s == orr, "min", FL[1], "max", FL[1024])
