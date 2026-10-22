-- Which of T10's Part 1 shapes get compiled standalone: mirrors the setup
-- loops and the CRC32 checks of ingame-bitops.lua :145-183 in order, then a
-- few one-shot checks (:184-202), and reports each trace start/stop with the
-- label of the step that was running.
local N = tonumber
local byte, char = string.byte, string.char
local label = "setup"
local ev = {}
jit.attach(function(what, tr, func, pc)
  local info = func and debug.getinfo(func, "S")
  ev[#ev + 1] = string.format("%-6s %-3s line %-4s during %s", what, tostring(tr),
    info and tostring(info.linedefined) or "?", label)
end, "trace")
local K = { one = N("1"), m1 = N("-1"), eight = N("8"), dead = N("3735928559"), zero = N("0") }
local CRCT = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRCT[i] = c
end
local function crc_table(s)
  local c, T = 0xFFFFFFFF, CRCT
  for i = 1, #s do c = (c >> 8) ~ T[(c ~ byte(s, i)) & 0xFF] end
  return c ~ 0xFFFFFFFF
end
local function crc_bit(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = c ~ byte(s, i)
    for _ = 1, 8 do
      if (c & 1) ~= 0 then c = (c >> 1) ~ 0xEDB88320 else c = c >> 1 end
    end
  end
  return c ~ 0xFFFFFFFF
end
local parts = {}
for i = 1, 4096 do parts[i] = char((i * 7 + 3) % 256) end
local DATA = table.concat(parts)
local checks = {
  { "crc32 table '123456789'", function() return crc_table("123456789") end },
  { "crc32 bitwise '123456789'", function() return crc_bit("123456789") end },
  { "crc32 table, 4 KB", function() return crc_table(DATA) end },
  { "crc32 bitwise, 4 KB", function() return crc_bit(DATA) end },
  { "1 << 64", function() return K.one << 64 end },
  { "-1 >> 64", function() return K.m1 >> 64 end },
  { "8 << -2", function() return K.eight << -2 end },
  { "dead & ffff", function() return K.dead & 0xFFFF end },
  { "~0", function() return ~K.zero end },
}
for _, c in ipairs(checks) do
  label = c[1]
  local ok, v = pcall(c[2])
  print(c[1], ok, string.format("%.17g", v))
end
label = "end"
jit.attach(function() end)
for _, s in ipairs(ev) do print(s) end
