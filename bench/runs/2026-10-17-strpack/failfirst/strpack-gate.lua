local P, U, S = string.pack, string.unpack, string.packsize
local fn = type(P) .. "/" .. type(U) .. "/" .. type(S)
if fn ~= "function/function/function" then print("fn=" .. fn) return end
local function hex(s) local t = {} for i = 1, #s do t[i] = string.format("%02x", s:byte(i)) end return table.concat(t) end
local b = P("<i4", -2)
local v, nx = U("<i4", b)
local big = U("<I8", string.rep(string.char(255), 7) .. string.char(127))
local ok1, e1 = pcall(U, "<i4", "abc")
local ok2, e2 = pcall(P, "<j", 1.5)
local jutil = require("jit.util")
local st, mine = { loop = 0, stitch = 0, abort = 0 }, {}
local function hot(n) local acc = 0 for i = 1, n do acc = acc + #P("<i4 z", i, "ab") end return acc end
local function cb(what, tr, func)
  if what == "start" then mine[tr] = (func == hot)
  elseif what == "stop" and mine[tr] then
    local lt = jutil.traceinfo(tr).linktype
    if st[lt] then st[lt] = st[lt] + 1 end
  elseif what == "abort" and mine[tr] then st.abort = st.abort + 1 end
end
jit.flush()
jit.attach(cb, "trace")
local acc = hot(2000)
jit.attach(cb)
print("fn=" .. fn .. " i4=" .. hex(b) .. " method=" .. tostring(("<i4"):pack(-2) == b) ..
  " u=" .. v .. "/" .. nx .. " I8max=" .. tostring(big == 2^63) .. " l=" .. S("l") .. "/" .. S("<L") ..
  " short=" .. tostring(not ok1 and e1:find("data string too short", 1, true) ~= nil) ..
  " int=" .. tostring(not ok2 and e2:find("number has no integer representation", 1, true) ~= nil) ..
  " hot=" .. acc .. " jit=" .. st.loop .. "/" .. st.stitch .. "/" .. st.abort)
