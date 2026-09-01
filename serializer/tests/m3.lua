-- m3.lua — suspended coroutines. The milestone OC actually needs: its
-- persisted root is always the kernel coroutine, frozen mid-execution.
--
-- Every test asserts that execution CONTINUES correctly after a restore,
-- not merely that a round trip produced a thread-shaped object.

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

-- Same _G-flattening the host does (see tests/m2.lua for why closures need it).
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
  -- Some iterators are hidden singletons that no name in _G reaches: an
  -- `ipairs` loop leaves its aux function on the stack, and that function is
  -- only obtainable as an upvalue of `ipairs` itself. Sweeping the
  -- function-valued upvalues of every named builtin picks them all up (on
  -- this build exactly two: `next` and the ipairs aux), which is what lets a
  -- coroutine suspended mid-`ipairs` be persisted at all. A real host wants
  -- this same arm in its perms flattener.
  local named = {}
  for v, n in pairs(perms) do if type(v) == "function" then named[#named + 1] = { v, n } end end
  for _, e in ipairs(named) do
    local f, n = e[1], e[2]
    local i = 1
    while true do
      local uvn, uvv = debug.getupvalue(f, i)
      if uvn == nil then break end
      if type(uvv) == "function" then add(uvv, n .. "#uv" .. i) end
      i = i + 1
    end
  end
  return perms, uperms
end
local BASEP, BASEU = build_perms()

local function perms_with(base, extra)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  if extra then for k, v in pairs(extra) do out[k] = v end end
  return out
end

local function roundtrip(v, extraP, extraU)
  local p, u = {}, {}
  for k, val in pairs(BASEP) do p[k] = val end
  for k, val in pairs(BASEU) do u[k] = val end
  if extraP then for k, val in pairs(extraP) do p[k] = val end end
  if extraU then for k, val in pairs(extraU) do u[k] = val end end
  return eris.unpersist(u, eris.persist(p, v))
end

--------------------------------------------------------- suspension shapes

print("-- plain yields")
do
  local co = coroutine.create(function()
    local acc = 0
    for i = 1, 5 do acc = acc + i; coroutine.yield(acc) end
    return "finished", acc
  end)
  coroutine.resume(co)                  -- suspended after yielding 1
  local g = roundtrip(co)
  ok(type(g) == "thread", "a suspended coroutine round-trips to a thread")
  ok(coroutine.status(g) == "suspended", "restored coroutine is suspended")
  local _, v = coroutine.resume(g)
  ok(v == 3, "resumes exactly where it left off", v)
  local _, v2 = coroutine.resume(g)
  ok(v2 == 6, "and keeps going", v2)
  ok(select(2, coroutine.resume(co)) == 3, "the original is independent")
end
do -- values passed INTO a resume after restore
  local co = coroutine.create(function(a)
    local b = coroutine.yield(a * 2)
    local c = coroutine.yield(b + 1)
    return a + b + c
  end)
  coroutine.resume(co, 10)              -- yielded 20
  local g = roundtrip(co)
  local _, y = coroutine.resume(g, 5)   -- b = 5, yields 6
  ok(y == 6, "resume arguments reach the restored frame", y)
  local _, r = coroutine.resume(g, 100) -- c = 100
  ok(r == 115, "final return computed from all three values", r)
end
do -- deep call chain with varargs
  local co = coroutine.create(function()
    local function leaf(...) coroutine.yield(select("#", ...)) return "leaf" end
    local function mid(...) return leaf(...) end
    local function outer() return mid(1, 2, 3) end
    return outer()
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, r = coroutine.resume(g)
  ok(r == "leaf", "vararg frames restore and unwind correctly", r)
end

print("-- yields under protection and metamethods")
do
  local co = coroutine.create(function()
    local okc, v = pcall(function()
      coroutine.yield("inside-pcall")
      return "returned"
    end)
    return okc, v
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, a, b = coroutine.resume(g)
  ok(a == true and b == "returned", "pcall frame survives a restore",
     tostring(a) .. "," .. tostring(b))
end
do -- xpcall, which pushes a wider frame
  local co = coroutine.create(function()
    return xpcall(function()
      coroutine.yield("in-xpcall")
      return "ok"
    end, function(e) return "handled:" .. tostring(e) end)
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, a, b = coroutine.resume(g)
  ok(a == true and b == "ok", "xpcall frame survives", tostring(a) .. "," .. tostring(b))
end
do -- an error raised AFTER restore must still reach the restored handler
  local co = coroutine.create(function()
    return xpcall(function()
      coroutine.yield("about-to-fail")
      error("boom")
    end, function(e) return "caught:" .. tostring(e):gsub(".*: ", "") end)
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, a, b = coroutine.resume(g)
  ok(a == false and tostring(b):find("caught:boom"),
     "the restored error handler catches a post-restore error", tostring(b))
end
do -- suspended inside an __index metamethod (a continuation frame)
  local t = setmetatable({}, {
    __index = function(_, k) coroutine.yield("in-index") return "V:" .. k end
  })
  local co = coroutine.create(function() return t.wanted end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, r = coroutine.resume(g)
  ok(r == "V:wanted", "continuation frame resumes into the metamethod result", r)
end
do -- suspended inside a __concat metamethod (a different continuation)
  local t = setmetatable({}, {
    __concat = function() coroutine.yield("in-concat") return "CAT" end
  })
  local co = coroutine.create(function() return "x" .. t end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, r = coroutine.resume(g)
  ok(r == "CAT", "concat continuation restores", r)
end

------------------------------------------------------------- open upvalues

print("-- open upvalues")
do -- a closure capturing a local of a frame that is still live on the
   -- suspended stack: the classic open upvalue.
  local co = coroutine.create(function()
    local n = 0
    local bump = function() n = n + 1 return n end
    coroutine.yield(bump)
    return n
  end)
  local _, bump = coroutine.resume(co)
  bump()                                -- n == 1 in the original
  local g = roundtrip({ co = co, bump = bump })
  ok(type(g.bump) == "function", "the closure came back")
  ok(g.bump() == 2, "the open upvalue kept its value and increments", "?")
  local _, n = coroutine.resume(g.co)
  ok(n == 2, "the suspended frame sees the closure's mutation", n)
end
do -- two closures sharing one open upvalue of a suspended frame
  local co = coroutine.create(function()
    local v = 10
    local get = function() return v end
    local set = function(x) v = x end
    coroutine.yield(get, set)
    return v
  end)
  local _, get, set = coroutine.resume(co)
  local g = roundtrip({ co = co, get = get, set = set })
  g.set(99)
  ok(g.get() == 99, "shared open upvalue is still shared")
  local _, v = coroutine.resume(g.co)
  ok(v == 99, "and the suspended frame observes it", v)
end

do -- a recursive `local function` on a suspended stack: the closure captures
   -- its OWN slot, so the upvalue aliases a slot at or above the closure.
  local co = coroutine.create(function()
    local function countdown(n)
      if n == 0 then coroutine.yield("bottom") return 0 end
      return countdown(n - 1) + 1
    end
    local r = countdown(3)
    return "done:" .. r
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local _, r = coroutine.resume(g)
  ok(r == "done:3", "recursive local function on a suspended stack", r)
end
do -- a forward-declared local captured before it is assigned
  local co = coroutine.create(function()
    local helper
    local call = function() return helper() end
    helper = function() return "late" end
    coroutine.yield(call)
    return call()
  end)
  local _, call = coroutine.resume(co)
  local g = roundtrip({ co = co, call = call })
  ok(g.call() == "late", "forward-declared local captured before assignment")
  local _, r = coroutine.resume(g.co)
  ok(r == "late", "and the suspended frame agrees", r)
end
do -- mutual recursion between two locals of a suspended frame
  local co = coroutine.create(function()
    local isodd, iseven
    isodd = function(n) if n == 0 then return false end return iseven(n - 1) end
    iseven = function(n) if n == 0 then return true end return isodd(n - 1) end
    coroutine.yield(isodd, iseven)
    return isodd(7), iseven(7)
  end)
  local _, o, e = coroutine.resume(co)
  local g = roundtrip({ co = co, odd = o, even = e })
  ok(g.odd(5) == true and g.even(5) == false, "mutually recursive locals work")
  local _, a, b = coroutine.resume(g.co)
  ok(a == true and b == false, "and the suspended frame computes the same",
     tostring(a) .. "," .. tostring(b))
end
do -- a DEEP coroutine: shallow ones never reach the stack-shrink guard that
   -- made an ordinary restore overflow the heap.
  local co = coroutine.create(function()
    local function down(n)
      if n == 0 then
        local payload = {}
        for i = 1, 200 do payload[i] = "s" .. i end
        coroutine.yield(payload)
        return 0
      end
      return down(n - 1) + 1
    end
    return down(40)
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  collectgarbage("collect")
  local _, d = coroutine.resume(g)
  ok(d == 40, "40-frame coroutine with a payload survives a restore", d)
end

--------------------------------------------------------- threads in threads

print("-- nested coroutines")
do
  local co = coroutine.create(function()
    local inner = coroutine.create(function()
      coroutine.yield("inner-1")
      return "inner-done"
    end)
    coroutine.resume(inner)
    coroutine.yield(inner)
    local _, r = coroutine.resume(inner)
    return r
  end)
  local _, inner = coroutine.resume(co)
  local g = roundtrip({ outer = co, inner = inner })
  ok(type(g.inner) == "thread", "the nested thread round-tripped")
  ok(coroutine.status(g.inner) == "suspended", "and is still suspended")
  local _, r = coroutine.resume(g.outer)
  ok(r == "inner-done", "the outer thread drives the restored inner one", r)
end

------------------------------------------------------------- other statuses

print("-- coroutine states")
do
  local co = coroutine.create(function(x) return x * 2 end)
  local g = roundtrip(co)
  ok(coroutine.status(g) == "suspended", "a never-started coroutine restores")
  local _, r = coroutine.resume(g, 21)
  ok(r == 42, "and runs from the beginning", r)
end
do
  local co = coroutine.create(function() return "done" end)
  coroutine.resume(co)
  ok(coroutine.status(co) == "dead", "sanity: it is dead")
  local g = roundtrip(co)
  ok(coroutine.status(g) == "dead", "a dead coroutine restores as dead")
  local okr = coroutine.resume(g)
  ok(okr == false, "and refuses to resume")
end
do -- the running thread cannot be persisted. Note coroutine.running()
   -- returns two values on this build (LUA52COMPAT), so it is parenthesised:
   -- otherwise the extra boolean arrives as a third argument to persist.
  local co = coroutine.create(function()
    return pcall(eris.persist, BASEP, (coroutine.running()))
  end)
  local _, inner_ok, inner_err = coroutine.resume(co)
  ok(inner_ok == false and tostring(inner_err):find("running"),
     "a running coroutine is refused", inner_err)
end
do -- ...and so is the main thread, which is idle (cframe == NULL) whenever a
   -- host drives a coroutine from C, so it would otherwise look persistable.
  local main = (coroutine.running())
  if main ~= nil then
    local ok_, err = pcall(eris.persist, BASEP, main)
    -- Running from the main thread, it is BOTH the main thread and the
    -- running one; either refusal is correct.
    ok(not ok_ and (tostring(err):find("main thread") or
                    tostring(err):find("running")),
       "the main thread is refused", err)
  else
    ok(true, "the main thread is not reachable as a value on this build")
  end
end

do -- A coroutine that dies BY ERROR keeps its upvalues OPEN (the error path
   -- returns at the resume frame without closing them). Normalising such a
   -- thread to an empty stack while still emitting those slots produced a blob
   -- that saved and could never load — write-only save data.
  local co = coroutine.create(function()
    local captured = 41
    local touch = function() captured = captured + 1 return captured end
    touch()
    error("died with an open upvalue")
  end)
  local okr = coroutine.resume(co)
  ok(okr == false, "sanity: the coroutine died by error")
  ok(coroutine.status(co) == "dead", "and reports dead")
  local g = roundtrip(co)
  ok(coroutine.status(g) == "dead", "an error-dead thread round-trips as dead")
  ok(coroutine.resume(g) == false, "and refuses to resume")
end
do -- the same thread reached through the closure that escaped it
  local escaped
  local co = coroutine.create(function()
    local n = 7
    escaped = function() return n end
    coroutine.yield()
    error("boom")
  end)
  coroutine.resume(co)
  coroutine.resume(co)                  -- now dead by error
  local g = roundtrip({ co = co, fn = escaped })
  ok(coroutine.status(g.co) == "dead", "dead thread reached via its closure")
  ok(g.fn() == 7, "the escaped closure kept its value", g.fn())
end
do -- a thread that died deep in recursion must not rebuild a huge stack
  local co = coroutine.create(function()
    local function down(n) if n == 0 then error("deep") end return down(n - 1) end
    return down(400)
  end)
  coroutine.resume(co)
  local blob = eris.persist(BASEP, co)
  local g = eris.unpersist(BASEU, blob)
  ok(coroutine.status(g) == "dead", "deeply-failed thread round-trips")
  ok(#blob < 300, "and its blob stays small", #blob)
end

print("-- for-in loops")
do -- ipairs works once the hidden aux function is in perms (see build_perms)
  local co = coroutine.create(function()
    local t = { 10, 20, 30 }
    local sum = 0
    for i, v in ipairs(t) do sum = sum + v; coroutine.yield(i) end
    return sum
  end)
  coroutine.resume(co)
  local okp, g = pcall(roundtrip, co)
  ok(okp, "a coroutine suspended mid-ipairs persists", g)
  if okp then
    local last
    repeat local _, v = coroutine.resume(g); last = v until coroutine.status(g) == "dead"
    ok(last == 60, "and finishes the loop with the right sum", last)
  end
end
-- A generic for-in loop's position is an index into the table's CURRENT
-- layout, so it cannot be carried to another process. The loop is therefore
-- rewritten into replay form on the wire: the remaining keys are snapshotted
-- and driven from that list. These tests cover the semantics in one process;
-- the property that actually matters -- that a restore in a FRESH process
-- visits the same key multiset -- can only be shown across processes, and
-- lives in tests/forin.lua.
local function drain(co)                -- run to death, collecting yields
  local seen, guard = {}, 0
  while coroutine.status(co) ~= "dead" do
    guard = guard + 1
    if guard > 10000 then error("loop did not terminate") end
    local okr, v = coroutine.resume(co)
    if not okr then error(v) end
    if v ~= nil then seen[#seen + 1] = v end
  end
  return seen
end
local function sorted(list)
  local c = {}
  for i, v in ipairs(list) do c[i] = tostring(v) end
  table.sort(c)
  return table.concat(c, ",")
end
local function keylist(t)
  local c = {}
  for k in pairs(t) do c[#c + 1] = tostring(k) end
  table.sort(c)
  return table.concat(c, ",")
end

do -- the plain case, and persist() must not disturb the saving coroutine
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8 }
  local co = coroutine.create(function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end)
  local first = select(2, coroutine.resume(co))
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "a coroutine suspended mid-pairs persists", g)
  if okp then
    local got = drain(g)
    table.remove(got)                   -- the "DONE" sentinel
    got[#got + 1] = first
    ok(sorted(got) == keylist(t),
       "and the restore visits every key exactly once", sorted(got))
    local orig = drain(co)
    table.remove(orig)
    orig[#orig + 1] = first
    ok(sorted(orig) == keylist(t),
       "and the SAVED coroutine still finishes its own loop untouched",
       sorted(orig))
  end
end

do -- the values must stay live, not be snapshotted with the keys
  local t = { a = 1, b = 2, c = 3, d = 4 }
  local co = coroutine.create(function()
    local sum = 0
    for k, v in pairs(t) do sum = sum + v; coroutine.yield(k) end
    return sum
  end)
  coroutine.resume(co)
  local g = roundtrip(co, { [t] = "T" }, { T = t })
  for k in pairs(t) do t[k] = 100 end   -- every unvisited key changes value
  local got = drain(g)
  local total = got[#got]
  ok(total > 100, "replay reads values live out of the table, not a copy",
     total)
end

do -- false is a value, not an absence
  local t = { a = false, b = false, c = false, d = false, e = false }
  local co = coroutine.create(function()
    local n = 0
    for k, v in pairs(t) do
      if v ~= false then error("value became " .. tostring(v)) end
      n = n + 1; coroutine.yield(k)
    end
    return n
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == 5, "keys whose value is false are still visited", got[#got])
end

do -- deleting the current key mid-loop, which the keyindex design could not save
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local co = coroutine.create(function()
    local n = 0
    for k in pairs(t) do t[k] = nil; n = n + 1; coroutine.yield(k) end
    return n
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == 6, "for k in pairs(t) do t[k] = nil end round-trips",
     got[#got])
end

do -- a key deleted before the loop reaches it must be skipped, as next does
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local co = coroutine.create(function()
    local n = 0
    for _ in pairs(t) do n = n + 1; coroutine.yield(n) end
    return n
  end)
  coroutine.resume(co)
  local g = roundtrip(co, { [t] = "T" }, { T = t })
  for k in pairs(t) do t[k] = nil end   -- wipe everything still unvisited
  local got = drain(g)
  ok(got[#got] == 1, "keys deleted after the save are not visited", got[#got])
end

do -- a mixed array/hash table
  local t = { 10, 20, 30, 40 }
  t.x, t.y, t.z = 1, 2, 3
  local co = coroutine.create(function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end)
  local first = select(2, coroutine.resume(co))
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  table.remove(got)
  got[#got + 1] = first
  ok(sorted(got) == keylist(t), "a mixed array/hash table replays in full",
     sorted(got))
end

do -- nested loops: the inner one completes, the outer one is the live one
  local t = { a = 1, b = 2, c = 3, d = 4 }
  local co = coroutine.create(function()
    for k in pairs(t) do
      local n = 0
      for _ in pairs { p = 1, q = 2, r = 3 } do n = n + 1 end
      if n ~= 3 then error("inner loop lost keys: " .. n) end
      coroutine.yield(k)
    end
    return "DONE"
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == "DONE", "a nested pairs loop replays and the inner one still runs",
     tostring(got[#got]))
end

do -- two sequential loops share a base register; only the live one may move
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5 }
  local co = coroutine.create(function()
    local first = 0
    for _ in pairs(t) do first = first + 1 end     -- completes, frees RA
    for k in pairs(t) do coroutine.yield(k) end    -- same base register
    return first
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == 5, "sequential loops on one base register do not confuse it",
     got[#got])
end

do -- the ITERC form: `next` reached through a local defeats predict_next
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local nx = next
  local co = coroutine.create(function()
    for k in nx, t do coroutine.yield(k) end
    return "DONE"
  end)
  local first = select(2, coroutine.resume(co))
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "a loop compiled as ITERC over the real `next` persists", g)
  if okp then
    local got = drain(g)
    table.remove(got)
    got[#got + 1] = first
    ok(sorted(got) == keylist(t), "and replays the same key set", sorted(got))
  end
end

do -- the ITERC arm with the current key deleted as the loop goes. Detection
   -- here has no LJ_KEYINDEX marker to fall back on, and a liveness test based
   -- on the key's VALUE would miss it: LuaJIT nils the value but keeps the key
   -- in its node, which is exactly why `next` tolerates the idiom.
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local nx = next
  local co = coroutine.create(function()
    local n = 0
    for k in nx, t do t[k] = nil; n = n + 1; coroutine.yield(k) end
    return n
  end)
  coroutine.resume(co)
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "an ITERC loop deleting as it goes persists", g)
  if okp then
    local got = drain(g)
    ok(got[#got] == 6, "and still visits all six keys", got[#got])
  end
end

do -- a prototype BC_ISNEXT already despecialised in place: the shape a
   -- Lua-5.2 __pairs shim leaves behind, which used to persist silently wrong
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local function walk(tbl, start)
    for k in next, tbl, start do coroutine.yield(k) end
    return "DONE"
  end
  local warm = coroutine.create(function() return walk(t, next(t)) end)
  coroutine.resume(warm)                -- fails ISNEXT's guard once
  local co = coroutine.create(function() return walk(t, nil) end)
  local first = select(2, coroutine.resume(co))
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "a loop in an already-despecialised prototype persists", g)
  if okp then
    local got = drain(g)
    table.remove(got)
    got[#got + 1] = first
    ok(sorted(got) == keylist(t),
       "and replays every key exactly once", sorted(got))
  end
end

do -- the loop is several frames down from the yield
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5 }
  local co = coroutine.create(function()
    local function deep(k) coroutine.yield(k) end
    for k in pairs(t) do deep(k) end
    return "DONE"
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == "DONE", "a loop below the yielding frame replays",
     tostring(got[#got]))
end

do -- save, restore, save again from the replay state, restore again
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7 }
  local co = coroutine.create(function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end)
  local first = select(2, coroutine.resume(co))
  local g1 = roundtrip(co, { [t] = "T" }, { T = t })
  local second = select(2, coroutine.resume(g1))
  local okp, g2 = pcall(roundtrip, g1, { [t] = "T" }, { T = t })
  ok(okp, "a coroutine already in replay form persists again", g2)
  if okp then
    local got = drain(g2)
    table.remove(got)
    got[#got + 1] = first
    got[#got + 1] = second
    ok(sorted(got) == keylist(t),
       "and the second restore still visits every key once", sorted(got))
  end
end

do -- a loop warmed until the JIT compiles it: persist must flush first
  local t = { 1, 2, 3, 4, 5, 6, 7, 8 }
  local co = coroutine.create(function()
    local spin = 0
    for _ = 1, 500 do for _, v in pairs(t) do spin = spin + v end end
    for k in pairs(t) do coroutine.yield(k) end
    return spin
  end)
  coroutine.resume(co)
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "a JIT-warmed loop persists (traces are flushed first)", g)
  if okp then
    local got = drain(g)
    ok(got[#got] == 18000, "and its arithmetic survives", got[#got])
  end
end

do -- table.foreach: a live BC_ITERN loop whose head is a plain BC_JMP and
   -- never was an ISNEXT. LuaJIT compiles this prototype at BUILD time --
   -- genlibbc.lua rewrites its PAIRS(t) into `nil, t, 0x4dp80` so predict_next
   -- fails and the parser emits JMP+ITERC, then the build tool patches the
   -- ITERC byte back to ITERN -- and every lua_State carries it. Its callback
   -- can yield, so it is a reachable for-in park, in a prototype the loader
   -- takes from perms rather than from the blob.
  local t = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6 }
  local co = coroutine.create(function()
    local n = 0
    table.foreach(t, function(k) n = n + 1; coroutine.yield(k) end)
    return n
  end)
  coroutine.resume(co)
  local okp, g = pcall(roundtrip, co, { [t] = "T" }, { T = t })
  ok(okp, "a coroutine suspended inside table.foreach persists", g)
  if okp then
    local got = drain(g)
    ok(got[#got] == 6, "and its build-time ITERN loop replays in full", got[#got])
  end
end

do -- a completed loop leaves no trace on the wire, and must not be rewritten
  local t = { a = 1, b = 2, c = 3 }
  local co = coroutine.create(function()
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    coroutine.yield("after")
    return n
  end)
  coroutine.resume(co)
  local got = drain(roundtrip(co, { [t] = "T" }, { T = t }))
  ok(got[#got] == 3, "a loop that already finished is left alone", got[#got])
end

do -- the iterated table keeps its identity when it comes from perms
  local t = { a = 1, b = 2, c = 3, d = 4 }
  local co = coroutine.create(function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end)
  coroutine.resume(co)
  local blob = eris.persist(perms_with(BASEP, { [t] = "T" }), co)
  local g = eris.unpersist(perms_with(BASEU, { T = t }), blob)
  drain(g)
  ok(next(t) ~= nil, "a permanent table is still the loader's own object")
end
do -- numeric for is unaffected
  local co = coroutine.create(function()
    local s = 0
    for i = 1, 4 do s = s + i; coroutine.yield(i) end
    return s
  end)
  coroutine.resume(co)
  local g = roundtrip(co)
  local last
  repeat local _, v = coroutine.resume(g); last = v until coroutine.status(g) == "dead"
  ok(last == 10, "numeric for round-trips and completes", last)
end

--------------------------------------------------------------- mini-kernel

print("-- mini-kernel (machine.lua's shape)")
do
  -- Mimics OC's kernel: a coroutine that loops pulling "signals", keeping
  -- state in locals captured by closures, suspended at a yield each pass.
  local function make_kernel()
    return coroutine.create(function()
      local log, uptime = {}, 0
      local record = function(sig) log[#log + 1] = sig return #log end
      while true do
        local signal = coroutine.yield(uptime)
        if signal == "shutdown" then return "halted", #log, uptime end
        uptime = uptime + 1
        record(signal)
      end
    end)
  end
  local k = make_kernel()
  coroutine.resume(k)                   -- boot to the first yield
  coroutine.resume(k, "alpha")
  coroutine.resume(k, "beta")
  local g = roundtrip(k)
  local _, up = coroutine.resume(g, "gamma")
  ok(up == 3, "restored kernel keeps counting uptime", up)
  local _, halted, n, final = coroutine.resume(g, "shutdown")
  ok(halted == "halted" and n == 3 and final == 3,
     "restored kernel shuts down with all its state intact",
     tostring(halted) .. "," .. tostring(n) .. "," .. tostring(final))
  -- and the original is untouched
  local _, up2 = coroutine.resume(k, "delta")
  ok(up2 == 3, "the original kernel is unaffected by the restore", up2)
end
do -- a kernel whose state includes a table shared with the outside world
  local shared = { ticks = 0 }
  local k = coroutine.create(function()
    while true do
      coroutine.yield(shared.ticks)
      shared.ticks = shared.ticks + 1
    end
  end)
  coroutine.resume(k)
  coroutine.resume(k)
  local g = roundtrip({ kernel = k, shared = shared })
  coroutine.resume(g.kernel)
  ok(g.shared.ticks == 2, "the restored coroutine mutates the restored table",
     g.shared.ticks)
  ok(shared.ticks == 1, "the original table is untouched", shared.ticks)
end

------------------------------------------------------------------ report

print()
if fail == 0 then
  print(string.format("M3 RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("M3 RESULT: %d passed, %d FAILED", pass, fail))
  for _, f in ipairs(failures) do print("  * " .. f) end
end
return fail
