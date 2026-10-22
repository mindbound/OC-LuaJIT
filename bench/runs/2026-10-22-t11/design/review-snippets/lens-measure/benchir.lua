-- T10's x | 0 and crc32 loops (ingame-bitops.lua :275-283, :308-315), run a
-- few times only, for -jdump=i: is the table-index fold's CONV int.i64 in the
-- crc loop, and is x | 0 left with a result guard?
local byte, char = string.byte, string.char
local CRCT = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRCT[i] = c
end
local parts = {}
for i = 1, 4096 do parts[i] = char((i * 7 + 3) % 256) end
local DATA = table.concat(parts)
local FL = {}
for i = 1, 1024 do FL[i] = (i - 500) * 3.0 end
local which = arg[1]
if which == "crc" then
  local T, s, len, c = CRCT, DATA, #DATA
  for _ = 1, 2 do
    c = 0xFFFFFFFF
    for i = 1, len do c = (c >> 8) ~ T[(c ~ byte(s, i)) & 0xFF] end
    c = c ~ 0xFFFFFFFF
  end
  print(c)
else
  local F, s = FL
  for _ = 1, 2 do
    s = 0
    for i = 1, 1024 do s = s + (F[i] | 0) end
  end
  print(s)
end
