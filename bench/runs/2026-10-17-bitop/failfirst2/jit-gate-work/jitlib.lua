local jutil = require("jit.util")
local function f(t)
  local s = -1
  for i = 1, 3 do
    if t[i] then s = s + 1 end
  end
  return s
end
local function hot(n)
  local t, x, y = {}, 0, 3
  for i = 1, n do
    local a = t[1] or y
    x = (((x ~ i) & 0xFFFF) << 3) >> 1
  end
  return x
end
local function count(fn)
  local n = jutil.funcinfo(fn).bytecodes - 1
  for k = -1, -1000000, -1 do
    local c = jutil.funck(fn, k)
    if c == nil then break end
    if type(c) == "proto" then n = n + count(c) end
  end
  return n
end
local function snapend()
  for tr = 1, 100 do
    if jutil.traceinfo(tr) then local s = jutil.tracesnap(tr, 0) return string.format("%.0f", s[#s]) end
  end
  return "none"
end
local fr, hr = f({ true, false, true }), hot(300)
print("jitlib f=" .. fr .. " hot=" .. hr .. " snapend=" .. snapend() .. " bc=" .. count(debug.getinfo(1, "f").func))
