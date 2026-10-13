local log = {}
local u = newproxy(true)
local mt = getmetatable(u)
mt.__gc = function() log[#log+1] = "orig" end
local v = newproxy(u)
collectgarbage("collect")
local orig = mt.__gc
mt.__gc = function(x) log[#log+1] = "wrap"; orig(x) end
u = nil; v = nil
collectgarbage("collect"); collectgarbage("collect")
print(table.concat(log, ","))
