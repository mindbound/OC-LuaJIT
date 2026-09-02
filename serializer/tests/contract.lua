-- contract.lua -- do we satisfy the integration contract a real OpenComputers
-- host actually calls?
--
-- m1/m2/m3 test serializer SEMANTICS against our own expectations. This tests
-- the API surface against what a real host does with it, read out of
-- ocelot-brain's PersistenceAPI.scala and NativeLuaArchitecture.scala
-- (ocelot-brain 0.24.2 = OpenComputers 1.8.9a, the emulator that runs OC
-- headlessly). Every check below mirrors a call the host really makes.
--
-- The load-bearing one is re-settability: PersistenceAPI.configure() runs at
-- the TOP OF EVERY persist AND unpersist, so a one-shot settings
-- implementation would fail on a machine's second save.
--
-- Exit status is the number of failures, as with the other suites.
local fails = 0
local function ok(cond, what, extra)
  if cond then print("  ok   " .. what)
  else fails = fails + 1; print("  FAIL " .. what .. "  -- " .. tostring(extra)) end
end

-- Brain builds perms by flattening _G in sorted order, so model that.
local perms, uperms = {}, {}
do
  local cand = {}
  local function offer(v, n) cand[#cand + 1] = { v, n } end
  offer(_G, "_G")
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      offer(v, "_G." .. tostring(k))
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then
            offer(v2, "_G." .. tostring(k) .. "." .. tostring(k2))
          end
        end
      end
    end
  end
  table.sort(cand, function(a, b) return a[2] < b[2] end)
  for _, e in ipairs(cand) do
    if perms[e[1]] == nil then perms[e[1]] = e[2]; uperms[e[2]] = e[1] end
  end
  local named = {}
  for v, n in pairs(perms) do
    if type(v) == "function" then named[#named + 1] = { v, n } end
  end
  table.sort(named, function(a, b) return a[2] < b[2] end)
  for _, e in ipairs(named) do
    local i = 1
    while true do
      local un, uv = debug.getupvalue(e[1], i)
      if not un then break end
      if type(uv) == "function" and perms[uv] == nil then
        perms[uv] = e[2] .. "#uv" .. i; uperms[e[2] .. "#uv" .. i] = uv
      end
      i = i + 1
    end
  end
end

print("contract required by ocelot-brain PersistenceAPI:")

local key1 = "__persist" .. "11111111-2222-3333-4444-555555555555"
local key2 = "__persist" .. "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local a, e = pcall(eris.settings, "spkey", key1)
ok(a, "settings('spkey', <uuid>) accepted", e)
local b, e2 = pcall(eris.settings, "spkey", key2)
ok(b, "settings('spkey', ...) accepted a SECOND time (re-settable)", e2)
ok(eris.settings("spkey") == key2, "and the second value took effect",
   tostring(eris.settings("spkey")))
local c, e3 = pcall(eris.settings, "path", true)
ok(c, "settings('path', true) accepted", e3)
local d, e4 = pcall(eris.settings, "path", false)
ok(d, "settings('path', false) accepted again", e4)

local function cycle(n)
  eris.settings("spkey", key1)          -- brain re-configures before persist
  eris.settings("path", true)
  local blob = eris.persist(perms, { n = n, s = "payload" })
  eris.settings("spkey", key1)          -- ... and again before unpersist
  eris.settings("path", true)
  local back = eris.unpersist(uperms, blob)
  return back.n == n and back.s == "payload"
end
ok(cycle(1), "configure->persist->configure->unpersist, pass 1")
ok(cycle(2), "and pass 2 (the case a one-shot setting would break)")

-- machine.lua's only two eris sites use spkey the same way: a metafield
-- returning a closure, persisted with its upvalues, called on restore.
-- The closure must NOT capture the object it rebuilds -- that cycle is
-- deliberately rejected, and machine.lua does not write one.
eris.settings("spkey", key2)
local handlemt = {}
local captured = "device-handle-7"
local wrapped = setmetatable({}, { [key2] = function()
  local c = captured
  return function() return setmetatable({ restored = c }, handlemt) end
end })
local okp, blob = pcall(eris.persist, perms, wrapped)
ok(okp, "spkey metafield under a randomised per-machine key", blob)
if okp then
  eris.settings("spkey", key2)
  local oku, back = pcall(eris.unpersist, uperms, blob)
  ok(oku and type(back) == "table" and back.restored == captured,
     "and the closure ran on restore, rebuilding the object", back)
end

-- Brain persists TWO roots per machine: the kernel coroutine (_kernel) and,
-- when a synchronized call is pending, a bare closure (_stack).
local co = coroutine.create(function() coroutine.yield("parked"); return "done" end)
coroutine.resume(co)
local okk, ek = pcall(eris.persist, perms, co)
ok(okk, "a suspended coroutine as the persist root (the _kernel tag)", ek)
if okk then
  local g = eris.unpersist(uperms, ek)
  local _, v = coroutine.resume(g)
  ok(v == "done", "and it resumes to completion", tostring(v))
end
local n = 7
local okc, ec = pcall(eris.persist, perms, function() return 35 + n end)
ok(okc, "a bare closure as the persist root (the _stack tag)", ec)
if okc then
  ok(eris.unpersist(uperms, ec)() == 42, "and it restores callable, with upvalues")
end

print()
print(fails == 0 and "CONTRACT: all checks pass" or ("CONTRACT: " .. fails .. " FAILED"))
return fails
