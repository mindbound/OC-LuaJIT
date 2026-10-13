-- Does a SECOND save-time collect dispose a proxy that died just before the save,
-- also when an incremental cycle is mid-flight (propagate or sweep) at the save?
jit.off()
local closing = false
local wrapped = setmetatable({}, {__mode = "k"})
local function mk(name)
  local u = newproxy(true)
  getmetatable(u).__gc = function()
    if closing then io.write("SKIPPED-at-close:", name, "\n")
    else io.write("disposed:", name, "\n") end
  end
  local proxy = {type = "userdata"}
  wrapped[proxy] = u
  return proxy
end
local junk = {}
for i = 1, 20000 do junk[i] = {i} end
local function case(name, steps, ncollect)
  collectgarbage("collect"); collectgarbage("collect")
  local p = mk(name)
  for i = 1, steps do collectgarbage("step", 1) end  -- leave an incremental cycle mid-flight
  p = nil
  for i = 1, ncollect do collectgarbage("collect") end
  io.write("  [", name, " after ", ncollect, " save-collect(s)]\n")
end
case("one-collect-idle", 0, 1)
case("two-collect-idle", 0, 2)
case("two-collect-midprop", 3, 2)
case("two-collect-midlate", 40, 2)
case("one-collect-midlate", 40, 1)
closing = true
io.write("[lua_close]\n")
