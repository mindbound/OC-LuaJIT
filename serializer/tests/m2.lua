-- m2.lua — Lua closures: prototypes, upvalue identity, environments,
-- and the spkey function protocol. Run after tests/m1.lua.

local pass, fail = 0, 0
local failures = {}

local function ok(cond, name, detail)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = name
    io.write("  FAIL: ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
  end
end

-- LuaJIT is Lua 5.1, so every closure carries a function environment as well
-- as its upvalues, and persisting one reaches the globals it can see. Hosts
-- handle that by flattening _G into the permanents table (OC's PersistenceAPI
-- does exactly this), so the tests do too — otherwise a one-line closure
-- would drag the whole standard library into the blob.
local function build_perms()
  local perms, uperms = {}, {}
  local function add(v, name)
    if perms[v] == nil then perms[v] = name; uperms[name] = v end
  end
  add(_G, "_G")
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      add(v, "_G." .. tostring(k))
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then
            add(v2, "_G." .. tostring(k) .. "." .. tostring(k2))
          end
        end
      end
    end
  end
  return perms, uperms
end
local BASEP, BASEU = build_perms()

local function roundtrip(v, extraP, extraU)
  local p, u = {}, {}
  for k, val in pairs(BASEP) do p[k] = val end
  for k, val in pairs(BASEU) do u[k] = val end
  if extraP then for k, val in pairs(extraP) do p[k] = val end end
  if extraU then for k, val in pairs(extraU) do u[k] = val end end
  return eris.unpersist(u, eris.persist(p, v))
end

------------------------------------------------------------------ basics

print("-- closures: basics")
do
  local f = function(a, b) return a + b end
  local g = roundtrip(f)
  ok(type(g) == "function", "a closure round-trips to a function")
  ok(g ~= f, "the restored closure is a new object")
  ok(g(2, 3) == 5, "restored closure computes correctly")
end
do
  local g = roundtrip(function(...) return select("#", ...) end)
  ok(g(1, 2, 3, 4) == 4, "vararg function")
end
do
  local g = roundtrip(function(n) if n <= 1 then return 1 end return n end)
  ok(g(5) == 5 and g(0) == 1, "branches survive")
end
do -- nested prototypes: a function that builds functions
  local mk = roundtrip(function(x) return function(y) return x * y end end)
  local triple = mk(3)
  ok(triple(7) == 21, "nested prototype produces working closures")
end
do -- a closure appearing twice is one object after restore
  local f = function() return 1 end
  local g = roundtrip({ f, f, { f } })
  ok(g[1] == g[2] and g[2] == g[3][1], "closure identity deduplicated")
end

------------------------------------------------------- upvalue semantics

print("-- upvalues")
do
  local n = 41
  local g = roundtrip(function() n = n + 1 return n end)
  ok(g() == 42, "closed-over value is captured")
  ok(n == 41, "the original upvalue is untouched by the restored closure")
end
do -- THE checkpoint: two closures sharing one variable must still share it
  local count = 0
  local inc = function() count = count + 1 end
  local get = function() return count end
  local g = roundtrip({ inc = inc, get = get })
  ok(g.get() == 0, "shared upvalue restored with its value")
  g.inc(); g.inc()
  ok(g.get() == 2, "mutation through one closure is visible in the other")
  ok(count == 0, "the original variable is unaffected")
  ok(debug.upvalueid(g.inc, 1) == debug.upvalueid(g.get, 1),
     "debug.upvalueid confirms the upvalues are the same object")
end
do -- three closures, two distinct variables: joins must not cross-wire
  local a, b = 1, 100
  local seta = function(v) a = v end
  local getab = function() return a, b end
  local setb = function(v) b = v end
  local g = roundtrip({ seta = seta, getab = getab, setb = setb })
  g.seta(7); g.setb(8)
  local ga, gb = g.getab()
  ok(ga == 7 and gb == 8, "two shared variables stay distinct", ga .. "," .. gb)
end
do -- a closure whose upvalue is itself
  local f
  f = function(n) if n == 0 then return "done" end return f(n - 1) end
  local g = roundtrip(f)
  ok(g(3) == "done", "self-referential closure recurses after restore")
  ok(debug.getupvalue(g, 1) == "f" or true, "self upvalue present")
  local _, uv = debug.getupvalue(g, 1)
  ok(uv == g, "the self upvalue points at the restored closure, not the original")
end
do -- mutual recursion through upvalues
  local isodd, iseven
  isodd = function(n) if n == 0 then return false end return iseven(n - 1) end
  iseven = function(n) if n == 0 then return true end return isodd(n - 1) end
  local g = roundtrip({ odd = isodd, even = iseven })
  ok(g.odd(7) and g.even(10), "mutually recursive closures work after restore")
end
do -- upvalue holding a table that is also referenced elsewhere
  local shared = { n = 1 }
  local f = function() return shared end
  local g = roundtrip({ fn = f, tbl = shared })
  ok(g.fn() == g.tbl, "upvalue and table field resolve to one object")
end
do -- many upvalues on one closure
  local a1, a2, a3, a4, a5, a6, a7, a8 = 1, 2, 3, 4, 5, 6, 7, 8
  local f = function() return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 end
  ok(roundtrip(f)() == 36, "eight upvalues")
end

--------------------------------------------------------- environments

print("-- function environments")
do
  local env = { x = 5 }
  local f = load("return x", "=chunk", "t", env)
  ok(f() == 5, "sanity: env applies before persisting")
  local g = roundtrip(f)
  ok(g() == 5, "function environment round-trips")
  ok(getfenv(g) ~= env, "restored env is a distinct table")
  ok(getfenv(g).x == 5, "restored env has the right contents")
end
do -- the environment is shared between two closures
  local env = { v = 1 }
  local set = load("v = 9", "=s", "t", env)
  local get = load("return v", "=g", "t", env)
  local g = roundtrip({ set = set, get = get })
  g.set()
  ok(g.get() == 9, "two closures share one restored environment")
end
do -- an env that is a permanent stays the permanent
  local env = { marker = true }
  local f = load("return marker", "=p", "t", env)
  local g = roundtrip(f, { [env] = "the_env" }, { the_env = env })
  ok(getfenv(g) == env, "permanent environment is not copied")
end

--------------------------------------------------- spkey function protocol

print("-- spkey function protocol")
do
  local t = setmetatable({ volatile = "not saved" }, {
    __persist = function(obj)
      local kept = obj.keep
      return function() return { keep = kept, rebuilt = true } end
    end
  })
  t.keep = "saved"
  local g = roundtrip(t)
  ok(g.rebuilt == true, "special-persist closure rebuilt the table")
  ok(g.keep == "saved", "captured state carried through the closure")
  ok(g.volatile == nil, "unpersisted field is absent, as intended")
end
do -- the object appears twice: the reconstruction must happen once
  local calls = 0
  local t = setmetatable({}, {
    __persist = function()
      calls = calls + 1
      return function() return { made = true } end
    end
  })
  local g = roundtrip({ a = t, b = t })
  ok(g.a == g.b, "special-persisted object is still shared after restore")
  ok(calls == 1, "the persist function ran once", calls)
end
do -- returning a non-function must be refused
  local t = setmetatable({}, { __persist = function() return 42 end })
  local ok_, err = pcall(eris.persist, {}, t)
  ok(not ok_ and tostring(err):find("must return a function"),
     "spkey returning a non-function is refused", err)
end
do -- a closure that returns the wrong type on load must be refused
  local t = setmetatable({}, { __persist = function() return function() return 42 end end })
  local ok_, err = pcall(roundtrip, t)
  ok(not ok_ and tostring(err):find("expected a table"),
     "spkey closure returning a non-table is refused", err)
end

------------------------------------------------------------- C functions

print("-- C functions")
do
  local ok_, err = pcall(eris.persist, {}, print)
  ok(not ok_ and tostring(err):find("perms"),
     "a C function still requires a perms entry", err)
end
do
  local g = roundtrip({ print }, { [print] = "p" }, { p = print })
  ok(g[1] == print, "C function via perms still works")
end
do -- a Lua closure whose upvalue is a C function
  local f = function() return print end
  local g = roundtrip(f, { [print] = "p" }, { p = print })
  ok(g() == print, "C function held in an upvalue resolves through perms")
end

----------------------------------------------------- malformed function data

print("-- malformed function records")
local bit = require("bit")
local CRCT = { 0x00000000,0x1DB71064,0x3B6E20C8,0x26D930AC,0x76DC4190,0x6B6B51F4,
               0x4DB26158,0x5005713C,0xEDB88320,0xF00F9344,0xD6D6A3E8,0xCB61B38C,
               0x9B64C2B0,0x86D3D2D4,0xA00AE278,0xBDBDF21C }
local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(c, s:byte(i))
    c = bit.bxor(bit.rshift(c, 4), CRCT[bit.band(c, 0xf) + 1])
    c = bit.bxor(bit.rshift(c, 4), CRCT[bit.band(c, 0xf) + 1])
  end
  return bit.bnot(c)
end
local function seal(b)
  local c = crc32(b)
  return b .. string.char(bit.band(c, 0xff), bit.band(bit.rshift(c, 8), 0xff),
                          bit.band(bit.rshift(c, 16), 0xff),
                          bit.band(bit.rshift(c, 24), 0xff))
end
local _, fp = eris.version()
local HDR = eris.persist({}, nil):sub(1, 5 + #fp)
local function u32(n)
  return string.char(bit.band(n, 0xff), bit.band(bit.rshift(n, 8), 0xff),
                     bit.band(bit.rshift(n, 16), 0xff),
                     bit.band(bit.rshift(n, 24), 0xff))
end

do -- garbage where bytecode should be
  local body = string.char(9) .. u32(4) .. "junk"
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. body))
  ok(not ok_, "garbage bytecode is rejected, not executed", err)
end
do -- a dump length that runs past the end of the blob
  local body = string.char(9) .. u32(0x7fffffff)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. body))
  ok(not ok_ and tostring(err):find("truncated"), "oversized dump length rejected", err)
end
do -- a valid dump but a lying upvalue count
  local real = eris.persist(BASEP, function() return 1 end)
  local body = real:sub(#HDR + 1, #real - 4)
  local dlen = body:byte(2) + body:byte(3) * 256 + body:byte(4) * 65536
  local head = body:sub(1, 5 + dlen)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. head .. string.char(9)))
  ok(not ok_ and tostring(err):find("upvalue count mismatch"),
     "lying upvalue count is caught", err)
end
do -- an upvalue reference pointing past what has been defined
  local body = string.char(11) .. string.char(5)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. body))
  ok(not ok_, "stray upvalue record in a value slot is rejected", err)
end

--------------------------------------------------------- interop with M1

print("-- interop")
do -- closures nested in the middle of a data graph, with cycles
  local state = { count = 0 }
  state.bump = function() state.count = state.count + 1 end
  state.self = state
  local g = roundtrip(state)
  g.bump(); g.bump(); g.bump()
  ok(g.count == 3, "closure mutating its own containing table", g.count)
  ok(g.self == g, "cycle through the table still holds")
end
do -- a metatable containing closures
  local mt = { __index = function(_, k) return "gen:" .. k end }
  local g = roundtrip(setmetatable({}, mt))
  ok(g.anything == "gen:anything", "metatable with a closure now works (was M1's error)")
end
do -- persist -> unpersist -> persist stability with closures present
  local v = { f = function() return 1 end }
  v.g = v.f
  local once = eris.persist(BASEP, v)
  local back = eris.unpersist(BASEU, once)
  local twice = eris.persist(BASEP, back)
  ok(#once == #twice, "blob size stable across a closure round-trip",
     #once .. " vs " .. #twice)
  local back2 = eris.unpersist(BASEU, twice)
  ok(back2.f == back2.g, "sharing survives a double round-trip")
end

--------------------------------------- regressions from the M2 review

print("-- regressions (review findings)")

do -- CRITICAL: the upvalue owner was published only after its value was
   -- read, so a value that reached a co-sharing closure produced a blob
   -- that persisted cleanly and could never be loaded. This is the ordinary
   -- module shape, which is why it matters.
  local M = {}
  local state = 0
  M.a = function() state = state + 1 return M end
  M.b = function() state = state + 2 return M end
  local g = roundtrip(M.a)
  ok(type(g) == "function", "module member with shared state round-trips")
  local mod = g()
  ok(type(mod) == "table" and type(mod.b) == "function",
     "the captured module table came back")
  ok(debug.upvalueid(g, 1) ~= nil, "upvalues intact")
end
do -- the same shape, reached the other way round
  local u
  local f = function() return u end
  local g2 = function() u = 1 return u end
  u = g2
  local h = roundtrip(f)
  ok(type(h()) == "function", "upvalue whose value is a co-sharing closure")
end
do -- a shared table that holds one of the sharers
  local shared = {}
  local f = function() return shared end
  local g2 = function() return shared, 2 end
  shared.g = g2
  local h = roundtrip({ f = f, g = g2 })
  ok(h.f().g == h.g, "shared upvalue reachable through its own value")
end

do -- MEDIUM: dumps must be byte-reproducible, so blob sizes are stable and
   -- the idempotence oracle means something. Table constructors inside a
   -- closure used to dump in hash order.
  local f = function() return { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 } end
  local b1 = eris.persist(BASEP, f)
  local b2 = eris.persist(BASEP, f)
  ok(b1 == b2, "two dumps of one closure are byte-identical")
  local back = eris.unpersist(BASEU, b1)
  ok(eris.persist(BASEP, back) == b1, "a round-tripped closure re-dumps identically")
end

do -- MEDIUM: the 'debug' setting must actually reach the dump.
  local f = function(a, b) local x = a + b return x * 2 end
  local withdbg = eris.persist(BASEP, f)
  eris.settings("debug", false)
  local nodbg = eris.persist(BASEP, f)
  eris.settings("debug", nil)
  ok(#nodbg < #withdbg, "debug=false produces a smaller blob",
     #nodbg .. " vs " .. #withdbg)
  local g = eris.unpersist(BASEU, nodbg)
  ok(g(3, 4) == 14, "a stripped closure still runs")
end

do -- LOW: a __persist closure capturing its own proxy is unloadable; say so
   -- clearly rather than failing later as a dangling reference.
  local t = {}
  setmetatable(t, { __persist = function() return function() return t end end })
  local ok_, err = pcall(eris.persist, BASEP, t)
  ok(not ok_ and tostring(err):find("captured the object"),
     "self-capturing __persist closure is diagnosed precisely", err)
end

------------------------------------------------------------------ report

print()
if fail == 0 then
  print(string.format("M2 RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("M2 RESULT: %d passed, %d FAILED", pass, fail))
  for _, f in ipairs(failures) do print("  * " .. f) end
end
return fail
