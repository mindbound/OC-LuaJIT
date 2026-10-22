-- Loads only the OPS chunk of ingame-bitops.lua (no benches run) and
-- evaluates the Part 1 checks and deviation cases, formatting the values
-- with copies of the file's own show/fmtint/msgof.
local path = arg[1]
local f = assert(io.open(path, "rb"))
local src = f:read("*a")
f:close()
local open = "local OPS = [==["
local a = assert(src:find(open, 1, true))
local b = assert(src:find("]==]", a, true))
local ops = src:sub(a + #open, b - 1)
if ops:sub(1, 1) == string.char(10) then ops = ops:sub(2) end

local function fmtint(v)
  if type(v) ~= "number" then return tostring(v) end
  local ok, s = pcall(string.format, "%d", v)
  if ok then return s end
  return string.format("%.17g", v)
end
local function show(v)
  if type(v) == "number" then
    if v == math.floor(v) and v >= -2^63 and v < 2^63 then
      local s = fmtint(v)
      if v >= 65536 and v < 2^32 then s = s .. string.format(" (0x%X)", v) end
      return s
    end
    return string.format("%.17g", v)
  elseif type(v) == "string" then
    if v:find("[^%w%p ]") then
      return "bytes " .. (v:gsub(".", function(c) return string.format("%02X ", c:byte()) end)):sub(1, -2)
    end
    return '"' .. v .. '"'
  end
  return tostring(v)
end
local function msgof(e) return (tostring(e):gsub("^[^:]*:%d+: ", "")) end
local mt = math.type or function() return "double" end

collectgarbage("collect")
local m0 = collectgarbage("count")
local fn = assert(load(ops, "=ingame-bitops ops"))
local OP = fn()
collectgarbage("collect")
local m1 = collectgarbage("count")
print(string.format("MEM chunk+data retained: %.1f KB (before %.1f, after %.1f)", m1 - m0, m0, m1))

for _, c in ipairs(OP.checks) do
  if c.skip then print("SKIP", c.name)
  else
    local ok, got = pcall(c.fn)
    if c.raises then
      print(ok and "RET " or "ERR ", c.name, ok and show(got) or msgof(got))
    else
      print((ok and got == c.want) and "PASS" or "FAIL", c.name, ok and show(got) or ("error: " .. msgof(got)),
        "want " .. show(c.want), "type " .. (type(got) == "number" and mt(got) or type(got)),
        "wanttype " .. (type(c.want) == "number" and mt(c.want) or type(c.want)))
    end
  end
end
for _, d in ipairs(OP.devs) do
  local ok, got = pcall(d.fn)
  print("DEV", d.name, ok and ("value " .. fmtint(got)) or ("raised " .. msgof(got)), "at " .. tostring(d.where()), "want53 " .. d.want53)
end
for _, bb in ipairs(OP.benches) do
  print("BENCHWANT", bb.name, show(bb.want), type(bb.want) == "number" and mt(bb.want) or type(bb.want))
end
