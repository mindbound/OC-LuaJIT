-- Same emulation as boundary.lua, reordered so nothing allocates between A's
-- single save-collect and lua_close (a chunk unload: save, then close).
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

-- C: a pending finalizer runs INSIDE a userdata allocation?
do local p = mk("C-pending") end
collectgarbage("collect")
collectgarbage("setpause", 1)
collectgarbage("setstepmul", 1000)
local hitAt
for i = 1, 200000 do
  local before = fin
  local x = newproxy(false)
  if fin ~= before then hitAt = i break end
end
io.write("C: finalizer ran inside newproxy() at iteration ", tostring(hitAt), "\n")
collectgarbage("setpause", 200); collectgarbage("setstepmul", 200)
collectgarbage("collect"); collectgarbage("collect")

-- B: proxy dropped, save does TWO collects, then close
do local p = mk("B-two-collects") end
collectgarbage("collect"); collectgarbage("collect")
io.write("after B's two collects, fin=", fin, "\n")

-- A: proxy dropped, save does ONE collect, then close
do local p = mk("A-one-collect") end
collectgarbage("collect")
io.write("after A's one collect (the save), fin=", fin, "\n")
closing = true
io.write("[script-end -> lua_close]\n")
