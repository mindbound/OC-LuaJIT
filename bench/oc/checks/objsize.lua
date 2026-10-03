-- objsize.lua -- bytes per live object on this VM, by shape: the hermetic half of the
-- RAM-scale calibration (bench/results-ramscale-2026-10-03.md, "Object sizes").
--
--     <vm> bench/oc/checks/objsize.lua [openos-dir]
--
-- Runs unchanged on PUC 5.2.4 and on our LuaJIT (GC64, LUA52COMPAT).  On 2026-10-03,
-- PUC 5.2.4 built from JNLua-Natives/lua/src with mingw gcc -O2 against
-- build/native/luajit-windows-x86_64/src/luajit.exe -joff, LuaJIT/PUC came out at:
-- empty table 1.14, array of 16 numbers 0.64, hash of 16 string keys 0.64, strings
-- 1.06-1.07, closure with 3 upvalues 1.18, suspended coroutine 0.52, record 0.85, and
-- 126 of OpenOS's 127 sources compiled (one fails on both) 0.69.  LuaJIT GC64 objects
-- are mostly SMALLER.
--
-- METHOD.  The holder array is allocated and filled with `false` BEFORE the baseline,
-- so storing an object into slot i changes the count by exactly that object's own
-- bytes -- which also means the slot itself is NOT counted: 16 B per held object on
-- PUC (no NaN-tagging on x86_64), 8 B on GC64.  For "how many fit" add it back: a
-- held closure is then 216 vs 192 B (1.13: LuaJIT fits 0.89x as many), a held 32-byte
-- string 80.7 vs 84.5 B (0.96: it fits 1.05x as many).
-- collectgarbage("collect") runs three times before every reading and the three
-- counts are compared, so a reading taken mid-cycle is flagged "(count unsettled)"
-- rather than averaged in.  Closures capture a FRESH upvalue each time: PUC 5.2
-- caches a closure whose upvalues are all the same, so an upvalue-free closure would
-- cost nothing there.  Single runs; in the machine, stock's per-string cost read ~35%
-- above this file's figure, unexplained (the results document).

local VM = (jit and jit.version) or _VERSION
local function count() return collectgarbage("count") * 1024 end
local function settle()
  local a, b, c
  collectgarbage("collect"); a = count()
  collectgarbage("collect"); b = count()
  collectgarbage("collect"); c = count()
  return c, (a == b and b == c)
end

local results = {}
local function measure(name, n, make)
  local hold = {}
  for i = 1, n do hold[i] = false end
  local c0, s0 = settle()
  for i = 1, n do hold[i] = make(i) end
  local c1, s1 = settle()
  local per = (c1 - c0) / n
  results[#results + 1] = { name, n, per, s0 and s1 }
  print(string.format("SIZE| %-34s n=%-6d %9.2f B/obj%s", name, n, per, (s0 and s1) and "" or "   (count unsettled)"))
  hold = nil
end

local function uniq(len, i)
  local s = tostring(i)
  return string.rep("x", len - #s) .. s
end

measure("empty table {}", 20000, function(i) return {} end)
measure("array table, 4 numbers", 20000, function(i) return { i, i, i, i } end)
measure("array table, 16 numbers", 5000, function(i)
  return { i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i } end)
measure("array table, 256 numbers (grown)", 500, function(i)
  local t = {} for k = 1, 256 do t[k] = k end return t end)
measure("hash table, 4 string keys", 20000, function(i) return { a = i, b = i, c = i, d = i } end)
measure("hash table, 16 string keys", 5000, function(i)
  return { a=i,b=i,c=i,d=i,e=i,f=i,g=i,h=i,j=i,k=i,l=i,m=i,n=i,o=i,p=i,q=i } end)
measure("string, 8 bytes (unique)", 20000, function(i) return uniq(8, i) end)
measure("string, 32 bytes (unique)", 20000, function(i) return uniq(32, i) end)
measure("string, 256 bytes (unique)", 5000, function(i) return uniq(256, i) end)
measure("closure, 1 fresh upvalue", 20000, function(i) local x = i return function() return x end end)
measure("closure, 3 fresh upvalues", 20000, function(i)
  local x, y, z = i, i, i return function() return x + y + z end end)
measure("coroutine (suspended, fresh)", 2000, function(i)
  local co = coroutine.create(function(a) coroutine.yield(a) end) coroutine.resume(co, i) return co end)
measure("record {name=str,size=n,flags={..}}", 10000, function(i)
  return { name = uniq(12, i), size = i, flags = { true, false } } end)

-- OS code: compile every .lua under the given directory and keep the chunk functions alive.
-- Prototypes (bytecode, constants, debug info) are most of what an OS holds after boot.
local dir = arg and arg[1]
if dir then
  local files = {}
  local p = io.popen('dir /b /s "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul')
  if p then for line in p:lines() do files[#files + 1] = line end p:close() end
  table.sort(files)
  local srcs = {}
  for _, f in ipairs(files) do
    local h = io.open(f, "rb")
    if h then srcs[#srcs + 1] = { f, h:read("*a") } h:close() end
  end
  local hold = {}
  for i = 1, #srcs do hold[i] = false end
  local c0, s0 = settle()
  local ok, bad, bytes = 0, 0, 0
  for i, s in ipairs(srcs) do
    local fn = (loadstring or load)(s[2], "=" .. s[1])
    if fn then hold[i] = fn ok = ok + 1 bytes = bytes + #s[2] else bad = bad + 1 end
  end
  local c1, s1 = settle()
  print(string.format("SIZE| %-34s files=%d (failed %d) source=%d B  live=%.0f B  %.3f B per source byte%s",
    "OS prototypes (" .. dir:match("[^/\\]+$") .. ")", ok, bad, bytes, c1 - c0, (c1 - c0) / bytes,
    (s0 and s1) and "" or "   (count unsettled)"))
  hold = nil
end
print("VM| " .. VM .. "  baseline count after settle: " .. string.format("%.0f", (settle())) .. " B")
