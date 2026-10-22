-- upfix.lua: two value-level behaviours of the shipped build that upstream
-- commits past our pin change [S: their diffs].  849bbbe (vm_x64.dasc):
-- math.floor/ceil's fast path did not check that an argument was passed
-- (.ffunc, now .ffunc_1).  2a8e017 (lib_base.c): tonumber with a base used
-- strtoul, 32 bits on Windows (LLP64), now strtoull.  Prints one line per
-- probe.  Value-level only; no backslashes.
local function zf() return math.floor() end
local function zc() return math.ceil() end
local out = {}
for i = 1, 4 do
  local x = 12.5 + i  -- leave a number in nearby stack slots
  local a, b = pcall(zf)
  out[#out + 1] = tostring(a) .. ":" .. tostring(b)
end
print("floor-noarg: " .. table.concat(out, " | "))
out = {}
for i = 1, 4 do
  local x = 7.25 + i
  local a, b = pcall(zc)
  out[#out + 1] = tostring(a) .. ":" .. tostring(b)
end
print("ceil-noarg: " .. table.concat(out, " | "))
print("pcall-floor: " .. tostring(select(2, pcall(math.floor))))
print("tonumber-base: " .. string.format("%.17g %.17g %.17g %.17g",
  tonumber("100000000", 16), tonumber("ffffffffff", 16),
  tonumber("-100000000", 16), tonumber("4294967295", 10)))
