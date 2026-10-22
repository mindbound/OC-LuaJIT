-- Mirrors T10's DEV hot loop (ingame-bitops.lua :256-272) to see whether it
-- compiles before i = 1000 standalone, and at which i recording starts/ends.
local N = tonumber
local K = { p53 = N("9007199254740992") }
local hot_i
local events = {}
if jit and jit.attach then
  jit.attach(function(what, tr, func, pc, otr, oex)
    events[#events + 1] = string.format("trace %s %s at hot_i=%s", tostring(what), tostring(tr), tostring(hot_i))
  end, "trace")
end
local function f()
  local base, r = K.p53 - 1000
  for i = 1, 2000 do hot_i = i r = (base + i) | 1 end
  return r
end
local ok, e = pcall(f)
if jit and jit.attach then jit.attach(function() end) end
print("ok", ok, "err", e, "hot_i", hot_i)
for _, s in ipairs(events) do print(s) end
