-- Which iteration of the DEV hot loop does the recorder record (and so the
-- interpreter execute while recording)?  Mirrors ingame-bitops.lua :279-283.
local N = tonumber
local K = { p53 = N("9007199254740992") }
local hot_i
local ev = {}
jit.attach(function(tr, func, pc, depth)
  ev[#ev + 1] = string.format("record tr=%s pc=%s hot_i=%s", tostring(tr), tostring(pc), tostring(hot_i))
end, "record")
jit.attach(function(what, tr)
  ev[#ev + 1] = string.format("trace %s %s hot_i=%s", tostring(what), tostring(tr), tostring(hot_i))
end, "trace")
local function f()
  local base, r = K.p53 - 1000
  for i = 1, 2000 do hot_i = i r = (base + i) | 1 end
  return r
end
local ok, e = pcall(f)
jit.attach(function() end)
print("ok", ok, "hot_i", hot_i)
for _, s in ipairs(ev) do print(s) end
