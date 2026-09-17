-- order.lua -- the discriminator for the step-4 walker graft
-- (docs/shell-fill.md section 6, silent mode 1: a recipe that READS another
-- special's contents and tolerates nil).
--
-- Under descending-id fill the reader runs first whenever it has the higher
-- id and completes WRONG with no error. Under dependency order it is right,
-- and a mutual dependency is refused naming both ordinals. On the shipping
-- binary 9c64817a this file must FAIL (cases 1, 2, 3b, 4, 5, 6, 8, 9 -- the
-- silent ones report "nil", the cycle ones are simply accepted); on the
-- walker binary FAILS: 0. Deleting the open-upvalue edge in reach_visit
-- (the NOEDGE negative control) must make case 2 go silent again.
--
--   ./erislj_test.exe shell-fill/walker/order.lua
local function build_perms()
  local perms, uperms = {}, {}
  local function add(v, name) if perms[v] == nil then perms[v]=name; uperms[name]=v end end
  add(_G, "_G")
  for k, v in pairs(_G) do
    local t = type(v)
    if t == "function" or t == "table" then
      add(v, "_G." .. tostring(k))
      if t == "table" and v ~= _G then
        for k2, v2 in pairs(v) do
          local t2 = type(v2)
          if t2 == "function" or t2 == "table" then add(v2, "_G."..tostring(k).."."..tostring(k2)) end
        end
      end
    end
  end
  return perms, uperms
end
local P, U = build_perms()
local fails = 0
local function ok(c, what, extra) if c then print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what .. "  -- " .. tostring(extra)) end end

-- A special whose recipe copies the captured fields and, optionally, READS
-- another object's field at fill time (tolerating nil, as the silent mode
-- requires). Every closure here is created inside a function that has
-- RETURNED, so its upvalues are closed unless a case says otherwise.
ORDER = {}
local function make(name, fields, read)
  local mt = {}
  mt.__persist = function(o)
    local copy = {}
    for k, v in pairs(o) do if k ~= "copy" then copy[k] = v end end
    return function(s)
      for k, v in pairs(copy) do s[k] = v end
      if read then s.copy = read(s) end
      ORDER[#ORDER + 1] = name
      setmetatable(s, mt)
    end
  end
  return setmetatable(fields, mt)
end
local function rt(v) ORDER = {}; return eris.unpersist(U, eris.persist(P, v)) end

print("-- case 1: A reads B.x through a CLOSED upvalue; A has the higher id")
do
  local B = make("B", { x = 1 })
  local A = make("A", {}, function() return B.x end)
  local g = rt({ B, A })                          -- B is written first: id 1
  ok(g[2].copy == 1, "A.copy == B.x (B filled before A)", g[2].copy)
end

print("-- case 2: A reads B.x through an OPEN upvalue of a suspended coroutine; A higher")
do
  local co = coroutine.create(function()
    local B = setmetatable({ x = 1 }, { __persist = function(o) local x = o.x
      return function(s) s.x = x; setmetatable(s, {}) end end })
    local A = setmetatable({}, { __persist = function()
      return function(s) s.copy = B.x; setmetatable(s, {}) end end })  -- B: open upvalue
    coroutine.yield()
    return B, A
  end)
  coroutine.resume(co)
  local g = rt(co)
  local r, B, A = coroutine.resume(g)
  ok(r and A.copy == 1, "A.copy == B.x through the open-upvalue edge", A and A.copy)
end

print("-- case 3: mutual reach is refused naming both ordinals")
do
  -- (a) The boundary: recipes that capture each other's object DIRECTLY are
  -- already refused by the writer (PendingRef), on every binary. Not the
  -- walker's case, kept here so the two refusals are not confused.
  local A, B
  A = make("A", { x = 1 }, function() return B.x end)
  B = make("B", { x = 2 }, function() return A.x end)
  local oku, err = pcall(rt, { A, B })
  ok(not oku and tostring(err):find("captured the object it reconstructs", 1, true),
     "direct mutual capture is refused at persist time (writer)", err)
  -- (b) The walker's case: each recipe reaches the other only through a
  -- container H that was registered BEFORE either recipe was written, so
  -- the wire carries no order at all; only load-time reachability sees it.
  local H = {}
  local A2 = make("A", { x = 1 }, function() return H.b.x end)
  local B2 = make("B", { x = 2 }, function() return H.a.x end)
  H.a, H.b = A2, B2
  oku, err = pcall(rt, { H, A2, B2 })
  err = tostring(err)
  ok(not oku and err:find("recipe 2 of 2", 1, true) and err:find("recipe 1 of 2", 1, true)
     and err:find("no fill order", 1, true), "mutual reach through shared structure refused, both ordinals named", err)
  ok(not oku and err:find("record at byte", 1, true), "refusal locates the blocked record", err)
end

print("-- case 4: a three-cycle through shared structure is refused")
do
  local H = {}
  local A = make("A", {}, function() return H.b.x end)
  local B = make("B", {}, function() return H.c.x end)
  local C = make("C", {}, function() return H.a.x end)
  H.a, H.b, H.c = A, B, C
  local oku, err = pcall(rt, { H, A, B, C })
  ok(not oku and tostring(err):find("no fill order", 1, true)
     and tostring(err):find("3 recipe(s) depend on each other", 1, true), "three-cycle refused, all three counted", err)
end

print("-- case 5: a chain A->B->C with ids reversed fills C, B, A")
do
  local C = make("C", { x = 1 })
  local B = make("B", {}, function() return (C.x or 0) + 1 end)
  local A = make("A", {}, function() return (B.copy or 0) + 1 end)
  local g = rt({ C, B, A })
  ok(g[3].copy == 3, "A.copy == 3 (transitive order)", g[3].copy)
  ok(table.concat(ORDER, " ") == "C B A", "fill order C B A", table.concat(ORDER, " "))
end

print("-- case 6: independent specials keep descending id; a dependency only reorders what it must")
do
  local S1, S2, S3 = make("1", {}), make("2", {}), make("3", {})
  rt({ S1, S2, S3 })
  ok(table.concat(ORDER, " ") == "3 2 1", "independent: 3 2 1", table.concat(ORDER, " "))
  local T1 = make("1", { x = 7 })
  local T2 = make("2", {})
  local T3 = make("3", {}, function() return T1.x end)
  local g = rt({ T1, T2, T3 })
  ok(table.concat(ORDER, " ") == "2 1 3", "3 reads 1: 2 1 3", table.concat(ORDER, " "))
  ok(g[3].copy == 7, "and 3 saw 1's contents", g[3].copy)
end

print("-- case 7: reading one's own shell is not a dependency")
do
  local S = make("S", { x = 5 }, function(s) return s.x end)
  local g = rt({ S })
  ok(g[1].copy == 5, "self-read fills", g[1].copy)
end

print("-- case 8: dependency through a literal container and a metatable; A higher")
do
  local B = make("B", { x = 1 })
  local H = { inner = setmetatable({}, { __index = { b = B } }) }
  local A = make("A", {}, function() return H.inner.b.x end)
  local g = rt({ B, A, H })
  ok(g[2].copy == 1, "A.copy == B.x via container -> metatable -> B", g[2].copy)
end

print("-- case 9: dependency through a coroutine's stack; A higher")
do
  local B = make("B", { x = 1 })
  local co = coroutine.create(function(b) while true do coroutine.yield(b) end end)
  coroutine.resume(co, B)                         -- B sits in co's frame
  local A = make("A", {}, function() local _, b = coroutine.resume(co); return b.x end)
  local g = rt({ B, A })
  ok(g[2].copy == 1, "A.copy == B.x via a thread slot", g[2].copy)
end

print("FAILS: " .. fails)
return fails
