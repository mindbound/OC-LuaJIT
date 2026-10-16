local f, e = load("return 1LL", "=lit")
local lit = f and "ACCEPTED" or (tostring(e):find("malformed number", 1, true) and "refused" or "other")
f = nil
local jutil = require("jit.util")
local fmt = string.format
local s = string.rep(string.char(0, 1, 127, 128, 200, 255), 400)
local function arm(hot)
  local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
  local function cb(what, tr, func)
    if what == "start" then mine[tr] = (func == hot)
    elseif what == "stop" and mine[tr] then
      local lt = jutil.traceinfo(tr).linktype
      if st[lt] then st[lt] = st[lt] + 1 end
    elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
  end
  jit.flush()
  jit.attach(cb, "trace")
  local out = hot(s)
  jit.attach(cb)
  return st.loop .. "/" .. st.stitch .. "/" .. st.abort, out
end
local function hs(str) local n = 0 for i = 1, #str do n = n + #fmt("%s", str:byte(i)) end return n end
local function hx(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
local function hi(str) local t = {} for i = 1, #str do local v = str:byte(i) - 128
  t[#t + 1] = fmt("%02x|%X|%#o|%u|%5d|%+d|%-4i;", v, v, v, v, v, v, v) end return table.concat(t) end
jit.off(hi)
local sres = arm(hs)
local xres, xout = arm(hx)
print("lit=" .. lit .. " preload=" .. tostring(package.preload.ffi) .. " loaded=" .. tostring(package.loaded.ffi) ..
  " s=" .. sres .. " x=" .. xres .. " same=" .. tostring(xout == hi(s)))
