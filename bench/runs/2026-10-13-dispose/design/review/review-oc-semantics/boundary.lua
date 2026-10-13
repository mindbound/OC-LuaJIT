-- Emulates machine.lua's wrappedUserdata (weak keys, proxy -> raw udata) and the
-- design's lj52 "closing" flag, to see what a save's ONE collect followed by
-- lua_close does to a Value whose proxy died just before the save.
jit.off()
local closing = false
local fin = 0
local wrapped = setmetatable({}, {__mode = "k"})
local function mk(name)
  local u = newproxy(true)
  getmetatable(u).__gc = function()
    fin = fin + 1
    if closing then io.write("SKIPPED-at-close:", name, "\n")
    else io.write("disposed:", name, "\n") end
  end
  local proxy = {type = "userdata"}
  wrapped[proxy] = u
  return proxy
end

-- B: proxy dropped, then the save does TWO collects
do local p = mk("B-two-collects") end
collectgarbage("collect"); collectgarbage("collect")
io.write("after B's two collects\n")

-- A: proxy dropped, then the save does ONE collect (LuaJITArchitecture.save:536), then close
do local p = mk("A-one-collect") end
collectgarbage("collect")
io.write("after A's one collect (save), fin=", fin, "\n")

-- C: does a pending finalizer run INSIDE a userdata allocation (lua_newuserdata's lj_gc_check)?
do local p = mk("C-pending") end
collectgarbage("collect")           -- clears C's weak entry; C's udata now garbage, unfinalized
collectgarbage("setpause", 1)       -- tiny pause so allocation steps the collector often
collectgarbage("setstepmul", 1000)
local hitAt
for i = 1, 200000 do
  local before = fin
  local x = newproxy(false)         -- the same lua_newuserdata jnlua's pushjavaobject calls
  if fin ~= before then hitAt = i break end
end
io.write("C: a finalizer ran inside newproxy() at iteration ", tostring(hitAt), "\n")
collectgarbage("setpause", 200)
closing = true
io.write("[script-end -> lua_close]\n")
