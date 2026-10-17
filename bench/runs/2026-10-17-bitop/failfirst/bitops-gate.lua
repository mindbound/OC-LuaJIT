local o = tonumber("1")
local function E(f, ...)
  local ok, r = pcall(f, ...)
  if ok then return string.format("%.17g", r) end
  r = tostring(r)
  if r:find("has more than 53 significant bits", 1, true) then
    return "X" .. (r:match("result of '([^']*)'") or "?")
  elseif r:find("no integer representation", 1, true) then return "noint"
  elseif r:find("perform bitwise operation on", 1, true) then return "type"
  elseif r:find("perform arithmetic on", 1, true) then return "arith"
  end
  return "other"
end
local fold = string.format("%.17g/%.17g/%.17g", 1 << 32, ~0, 1 << 64)
local kx = E(load("return -1 >> 1"))
local rt = E(function() return o << 32 end) .. "/" .. E(function() return (-o) >> 1 end) .. "/" ..
  E(function() return ~0 >> o end) .. "/" .. E(function() return (-o) >> 11 end) .. "/" ..
  E(function() return (-o) >> 10 end) .. "/" .. E(function() return o << 64 end) .. "/" ..
  E(function() return ~(2^53 * o) end) .. "/" .. E(function() return (2^60 * o) | 1 end)
local err = E(function() return 1.5 | o end) .. "/" .. E(function() return "3" & o end) .. "/" ..
  E(function() return "0x10" | o end) .. "/" .. E(function() return {} | o end) .. "/" ..
  E(function() return 2^63 & o end) .. "/" .. E(function() return "-1" >> o end)
local sar = E(function() return (-8 * o) ~>> 2 end) .. "/" .. E(function() return (-o) ~>> 64 end) .. "/" ..
  E(function() return (4 * o) ~>> -1 end)
local dump = string.dump(function() end):byte(4)
local bl = bit and bit.lshift(1, 32)
local jutil = require("jit.util")
local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
local last = 0
local function hot() local s = 0 for i = 1, 300 do last = i s = s + ((150 - i) >> 1) + ((-i & 0xFFFFFFFF) >> 8 & 0xFF) end return s end
local function cold() local s = 0 for i = 1, 300 do last = i s = s + ((150 - i) >> 1) + ((-i & 0xFFFFFFFF) >> 8 & 0xFF) end return s end
local function cb(what, tr, func)
  if what == "start" then mine[tr] = (func == hot)
  elseif what == "stop" and mine[tr] then
    local lt = jutil.traceinfo(tr).linktype
    if st[lt] then st[lt] = st[lt] + 1 end
  elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
end
jit.off(cold)
jit.flush()
jit.attach(cb, "trace")
local hres = E(hot)
local hlast = last
jit.attach(cb)
local cres = E(cold)
local clast = last
print("fold=" .. fold .. " kx=" .. kx .. " rt=" .. rt .. " err=" .. err .. " sar=" .. sar ..
  " dump=" .. dump .. " bit=" .. tostring(bl) .. " hot=" .. hres .. "@" .. hlast ..
  " jit=" .. st.loop .. "/" .. st.stitch .. "/" .. st.abort ..
  " same=" .. tostring(hres == cres and hlast == clast))
