-- Memory of compiling the whole file (not running it) and of the OPS
-- chunk's setup, retained and with the collector stopped (an upper bound
-- on the setup's peak).
local path = arg[1]
local f = assert(io.open(path, "rb"))
local src = f:read("*a")
f:close()
collectgarbage("collect")
local m0 = collectgarbage("count")
local whole = assert(load(src, "=/home/ingame-bitops.lua"))
collectgarbage("collect")
local m1 = collectgarbage("count")
print(string.format("compile whole file, retained: %.1f KB (source string itself %.1f KB, held before)", m1 - m0, #src / 1024))

local open = "local OPS = [==["
local a = assert(src:find(open, 1, true))
local b = assert(src:find("]==]", a, true))
local ops = src:sub(a + #open + 1, b - 1)
collectgarbage("collect")
local m2 = collectgarbage("count")
collectgarbage("stop")
local OP = assert(load(ops, "=ingame-bitops ops"))()
local m3 = collectgarbage("count")
collectgarbage("restart")
collectgarbage("collect")
local m4 = collectgarbage("count")
print(string.format("ops chunk setup: allocated (collector stopped) %.1f KB, retained %.1f KB", m3 - m2, m4 - m2))
