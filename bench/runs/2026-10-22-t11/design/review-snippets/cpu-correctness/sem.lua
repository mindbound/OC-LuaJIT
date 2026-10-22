-- Small semantic questions about the driver code, on PUC 5.3.6 and LuaJIT.
local mt = math.type or function() return "n/a" end
local n, t = 8, 0.0123
n = math.max(1, math.floor(n * 0.3 / t + 0.5))
print("calibrated n", n, mt(n))
local REPS = math.max(1, math.floor(tonumber("3")))
print("REPS from '3'", REPS, mt(REPS), "reps=" .. REPS)
REPS = math.max(1, math.floor(tonumber("3.0")))
print("REPS from '3.0'", REPS, mt(REPS), "reps=" .. REPS)
local sorted = { 0.1, 0.2, 0.3, 0.4, 0.5 }
print("sorted[(5+1)/2]", sorted[(5 + 1) / 2], "key type", mt((5 + 1) / 2))
local s4 = { 1, 2, 3, 4 }
print("even median keys", s4[4 / 2], s4[4 / 2 + 1])
print("format %d of 38400.0", string.format("%d", 38400.0))
print("38400 == 38400.0", 38400 == 38400.0)
print("tostring(hot_i-like 2000)", tostring(2000))

-- OC's sandbox debug.getinfo wrapper (machine.lua:1002-1021), simulated.
local realgetinfo = debug.getinfo
local wrapper = assert(load([[
  local realgetinfo = ...
  return function(...)
    local result = realgetinfo(...)
    if result then return { source = result.source } end
  end
]], "=machine"))(realgetinfo)
local prog = assert(load([[
  local getinfo = ...
  local info = getinfo(1, "S")
  local src = info.source
  local dir = src:sub(2):match("^(.*)[/\\][^/\\]*$")
  return src, dir
]], "=/home/ingame-bitops.lua"))
print("via wrapper:", prog(wrapper))
print("direct     :", prog(realgetinfo))
