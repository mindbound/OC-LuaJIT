-- shell-order.lua -- fill ORDER under shell-fill: the dependency walker (step 4,
-- docs/shell-fill.md section 5.4, closing silent mode 1 of section 6).
--
-- The current binary (9c64817a) fills recipes in DESCENDING FILL-array index.
-- The spec calls that "descending reference id" and credits it with fixing the
-- nested capture (A's record CONTAINS B's). It does not: u_table's
-- TABLE_SPECIAL arm appends the shell to the array AFTER unpersisting the
-- closure (eris_lj.c:1827 vs :1841), so the array is POST-order -- a nested
-- shell lands BEFORE its container -- and descending index fills the container
-- first. Both directions of a content read are therefore silently wrong today:
-- D1 (B encountered first) and D1n (B nested inside A's record). Only the
-- open-upvalue shape with the dependency in the HIGHER slot (D2-ctl) comes out
-- right, and only by accident. The walker replaces the index order with a
-- dependency order and refuses mutual reach.
--
-- Each case prints its outcome VERBATIM on a "[case] ..." line, including the
-- order in which the recipes actually ran (every recipe appends its name to
-- the permanent LOG table), so the discrimination is visible, not inferred.
--
-- Expected on 9c64817a (no walker):   FAILS: 6  (D1, D1n, D2, C1, C2, B1-dep)
-- Expected on the walker binary:      FAILS: 0
--
-- Dependency media, chosen so the negative control isolates ONE walker edge:
--   D1, D1n  closed upvalue   -> only the closed-upvalue reach_push carries it
--   D2       open upvalue     -> only the open-upvalue reach_push carries it
--   C1, C2, B1  recipe fenv   -> the env edge; untouched by either deletion
-- Deleting the closed edge must silence D1 and D1n alone; deleting the open
-- edge must silence D2 alone; D2-ctl stays green either way.
--
-- A mutual cycle cannot be written with each recipe capturing the other:
-- persist_keyed (eris_lj.c:1546) refuses a reference to a special whose record
-- is still open, and one recipe necessarily nests inside the other's. So C1 and
-- C2 reach each other through a SHARED literal T = {A, B} registered before
-- either recipe -- precisely the "dependency through shared structure" that
-- has no ordering on the wire (docs/shell-fill.md section 1).

LOG = {}   -- fill-order trace. Defined BEFORE build_perms so it is a permanent:
           -- a restored recipe then appends to THIS table, not to a copy.

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
local function clearlog() for i = #LOG, 1, -1 do LOG[i] = nil end end
local function order() return #LOG > 0 and table.concat(LOG, " ") or "(none)" end
local function roundtrip(perms, uperms, obj)
  local okp, blob = pcall(eris.persist, perms, obj)
  if not okp then return nil, "persist: " .. tostring(blob) end
  clearlog()
  local oku, g = pcall(eris.unpersist, uperms, blob)
  return oku, g
end
-- The refusal must name BOTH ordinals in the existing style ("recipe K of N")
-- and the byte offset of the first blocked record ("record at byte ...").
local function refused_naming(err, k1, k2, n)
  err = tostring(err)
  return err:find("eris-lj:", 1, true) ~= nil
     and err:find("recipe " .. k1 .. " of " .. n, 1, true) ~= nil
     and err:find("recipe " .. k2 .. " of " .. n, 1, true) ~= nil
     and err:find("byte", 1, true) ~= nil
end

------------------------------------------------------------------------------
print("-- D1: A reads B's contents through a CLOSED upvalue; container {B, A} gives B the lower id")
-- Everything is built inside make() so that, once it returns, B and the
-- metatables are CLOSED upvalues of the __persist closures and of the recipes
-- they return. A's recipe tolerates nil: on 9c64817a A fills first and A.y
-- silently stays nil.
local function make_d1(shape)
  local mtA, mtB = {}, {}
  local B = setmetatable({}, mtB)
  local A = setmetatable({}, mtA)
  mtB.__persist = function() return function(s) LOG[#LOG+1] = "B"; s.x = 42; setmetatable(s, mtB) end end
  mtA.__persist = function() return function(s) LOG[#LOG+1] = "A"; s.y = B.x; setmetatable(s, mtA) end end
  if shape == "BA" then return { B, A } else return { A, B } end
end
do
  local oku, g = roundtrip(P, U, make_d1("BA"))
  local y = oku and g[2].y or nil
  print(("  [D1] ok=%s A.y=%s order=%s"):format(tostring(oku), tostring(y), order()))
  ok(oku, "D1 unpersist", g)
  if oku then
    ok(#LOG == 2, "D1 both recipes ran and wrote the permanent LOG", order())
    ok(g[1].x == 42, "D1 B.x == 42", g[1].x)
    ok(y == 42, "D1 A.y == 42 (B must fill before A)", y)
  end
end

print("-- D1n: same dependency, container {A, B}: B's record NESTS inside A's (the KIND-1 capture)")
-- The spec says descending id handles this direction. On 9c64817a it does not
-- (post-order array, see the header): A fills first here too.
do
  local oku, g = roundtrip(P, U, make_d1("AB"))
  local y = oku and g[1].y or nil
  print(("  [D1n] ok=%s A.y=%s order=%s"):format(tostring(oku), tostring(y), order()))
  ok(oku, "D1n unpersist", g)
  if oku then ok(y == 42, "D1n A.y == 42 (nested capture: B must fill before A)", y) end
end

------------------------------------------------------------------------------
print("-- D2: A reads B's contents through an OPEN upvalue of a suspended coroutine (the OC shape); B in the LOWER slot")
-- Thread slots are written ascending (eris_lj.c:1313), so the special in the
-- lower slot is registered first and gets the lower id. B below A therefore
-- makes A fill first on 9c64817a: A.y silently nil. The
-- recipes are created at persist time by __persist closures whose upvalues
-- point into the live coroutine frame, so B and mtA are OPEN upvalues of the
-- recipe -- exactly how machine.lua's proxy recipe reaches its kernel locals.
-- The bodies reference only globals, so the coroutine function itself
-- captures nothing from this chunk's frame.
do
  local co = coroutine.create(function()
    local B, A                          -- B: lower slot (lower id); A: higher
    local mtA, mtB = {}, {}
    mtB.__persist = function() return function(s) LOG[#LOG+1] = "B"; s.x = 42; setmetatable(s, mtB) end end
    mtA.__persist = function() return function(s) LOG[#LOG+1] = "A"; s.y = B.x; setmetatable(s, mtA) end end
    B = setmetatable({}, mtB)
    A = setmetatable({}, mtA)
    coroutine.yield()
    return A, B
  end)
  coroutine.resume(co)
  local oku, g = roundtrip(P, U, co)
  local r, a, b
  if oku then r, a, b = coroutine.resume(g) end
  local y = r and a.y or nil
  print(("  [D2] ok=%s A.y=%s order=%s"):format(tostring(oku), tostring(y), order()))
  ok(oku, "D2 unpersist", g)
  if oku then
    ok(r, "D2 resume", a)
    if r then
      ok(b.x == 42, "D2 B.x == 42", b.x)
      ok(y == 42, "D2 A.y == 42 (B must fill before A)", y)
    end
  end
end

print("-- D2-ctl: same, A in the LOWER slot: B gets the higher index, descending order is right by accident")
do
  local co = coroutine.create(function()
    local A, B                          -- A: lower slot; B: higher slot (higher id)
    local mtA, mtB = {}, {}
    mtB.__persist = function() return function(s) LOG[#LOG+1] = "B"; s.x = 42; setmetatable(s, mtB) end end
    mtA.__persist = function() return function(s) LOG[#LOG+1] = "A"; s.y = B.x; setmetatable(s, mtA) end end
    B = setmetatable({}, mtB)
    A = setmetatable({}, mtA)
    coroutine.yield()
    return A, B
  end)
  coroutine.resume(co)
  local oku, g = roundtrip(P, U, co)
  local r, a, b
  if oku then r, a, b = coroutine.resume(g) end
  local y = r and a.y or nil
  print(("  [D2-ctl] ok=%s A.y=%s order=%s"):format(tostring(oku), tostring(y), order()))
  ok(oku, "D2-ctl unpersist", g)
  if oku then
    ok(r, "D2-ctl resume", a)
    if r then ok(y == 42, "D2-ctl A.y == 42 (must stay green with the walker)", y) end
  end
end

------------------------------------------------------------------------------
-- C1, C2, B1 carry their dependency through the recipe's ENVIRONMENT: the
-- recipe has no upvalues at all (DEP, MT, SETMT, LOG are globals resolved
-- through a literal env table), so neither upvalue edge of the walker is
-- involved and the negative control leaves them unchanged.
print("-- C1: A reads B and B reads A through a SHARED literal T = {A, B}; both tolerate nil; Z independent")
local function make_c1()
  local mtA, mtB, mtZ = {}, {}, {}
  local A, B, Z = setmetatable({}, mtA), setmetatable({}, mtB), setmetatable({}, mtZ)
  local T = { A, B }                       -- shared structure: registered before either recipe
  local envA = { DEP = T, MT = mtA, SETMT = setmetatable, LOG = LOG }
  local envB = { DEP = T, MT = mtB, SETMT = setmetatable, LOG = LOG }
  mtA.__persist = function() return setfenv(function(s) LOG[#LOG+1] = "A"; s.a = 1; s.seen = DEP[2].b; SETMT(s, MT) end, envA) end
  mtB.__persist = function() return setfenv(function(s) LOG[#LOG+1] = "B"; s.b = 2; s.seen = DEP[1].a; SETMT(s, MT) end, envB) end
  mtZ.__persist = function() return function(s) LOG[#LOG+1] = "Z"; s.z = true; setmetatable(s, mtZ) end end
  return { T, Z }                          -- ordinals (FILL index): A=1, B=2, Z=3
end
do
  local oku, g = roundtrip(P, U, make_c1())
  if oku then
    print(("  [C1] ok=true A.seen=%s B.seen=%s Z.z=%s order=%s"):format(
      tostring(g[1][1].seen), tostring(g[1][2].seen), tostring(g[2].z), order()))
  else
    print(("  [C1] ok=false order=%s err=%s"):format(order(), tostring(g)))
  end
  ok(not oku and refused_naming(g, 1, 2, 3), "C1 cycle refused naming recipe 1 of 3, recipe 2 of 3 and the byte offset",
     oku and "accepted silently (see the [C1] line)" or g)
end

print("-- C2: identity-only mutual reach (A.ref = B, B.ref = A): EXPECTED-REFUSED")
-- EXPECTED-REFUSED. The recipes never read each other's CONTENTS -- storing
-- the identity is correct in any fill order, and the 9c64817a binary
-- restores this shape correctly (printed below). But the walker cannot tell
-- an identity use from a content use: both are "the closure reaches an
-- unfilled shell", so mutual reach is refused. Refusing is the safe side;
-- this case documents the cost. If a future walker can distinguish the two,
-- flip this assertion to "accepted, A.ref == B and B.ref == A".
local function make_c2()
  local mtA, mtB = {}, {}
  local A, B = setmetatable({}, mtA), setmetatable({}, mtB)
  local T = { A, B }                       -- shared structure, as in C1
  local envA = { DEP = T, MT = mtA, SETMT = setmetatable, LOG = LOG }
  local envB = { DEP = T, MT = mtB, SETMT = setmetatable, LOG = LOG }
  mtA.__persist = function() return setfenv(function(s) LOG[#LOG+1] = "A"; s.ref = DEP[2]; SETMT(s, MT) end, envA) end
  mtB.__persist = function() return setfenv(function(s) LOG[#LOG+1] = "B"; s.ref = DEP[1]; SETMT(s, MT) end, envB) end
  return { T }                             -- ordinals: A=1, B=2
end
do
  local oku, g = roundtrip(P, U, make_c2())
  if oku then
    print(("  [C2] ok=true A.ref==B:%s B.ref==A:%s order=%s"):format(
      tostring(g[1][1].ref == g[1][2]), tostring(g[1][2].ref == g[1][1]), order()))
  else
    print(("  [C2] ok=false order=%s err=%s"):format(order(), tostring(g)))
  end
  ok(not oku and refused_naming(g, 1, 2, 2), "C2 identity-only mutual reach refused (EXPECTED-REFUSED: the conservative cost)",
     oku and "accepted (contents correct; see the [C2] line)" or g)
end

------------------------------------------------------------------------------
print("-- P1: a permanent is a leaf (the walker must not enter host objects)")
-- A permanent cannot contain a shell at walk time: the reader never writes
-- into a permanent and no recipe has run before the walk. So the ONLY
-- observable of the leaf rule is the budget: hang a graph bigger than
-- ERIS_LJ_REACH_BUDGET (~1e6) under a permanent and require the fill to
-- succeed. A walker that entered the permanent would exceed its budget and
-- refuse. Discriminates only while ERIS_LJ_REACH_BUDGET < P1_N; raise P1_N if
-- the budget is raised. (~83 MB, ~0.1 s on this build.)
--   P1a: BIG is reachable ONLY through _G, the recipe's environment. BIG is
--        not itself in the perms (P/U were built before it existed), so a
--        walker that entered _G would find 1.1e6 reader-foreign tables.
--   P1b: BIG is a permanent in its own right, captured as a closed upvalue.
local P1_N = 1100000
BIG = {}
for i = 1, P1_N do BIG[i] = {} end
do
  local mt = {}
  mt.__persist = function() return function(s) LOG[#LOG+1] = "P"; s.p = true; setmetatable(s, mt) end end
  local t0 = os.clock()
  local oku, g = roundtrip(P, U, { setmetatable({}, mt) })
  print(("  [P1a] ok=%s p=%s order=%s (%.3fs, BIG has %d tables, fenv=_G)"):format(
    tostring(oku), tostring(oku and g[1].p), order(), os.clock() - t0, #BIG))
  ok(oku and g[1].p == true, "P1a recipe whose fenv (_G) holds a 1.1e6-table graph fills within budget", g)
end
do
  local P1bP, P1bU = {}, {}
  for k, v in pairs(P) do P1bP[k] = v end
  for k, v in pairs(U) do P1bU[k] = v end
  P1bP[BIG] = "BIG"; P1bU["BIG"] = BIG
  local big = BIG
  local mt = {}
  mt.__persist = function() return function(s) LOG[#LOG+1] = "P"; s.n = #big; setmetatable(s, mt) end end
  local t0 = os.clock()
  local oku, g = roundtrip(P1bP, P1bU, { setmetatable({}, mt) })
  print(("  [P1b] ok=%s n=%s order=%s (%.3fs, BIG captured as a permanent upvalue)"):format(
    tostring(oku), tostring(oku and g[1].n), order(), os.clock() - t0))
  ok(oku and g[1].n == P1_N, "P1b recipe capturing a 1.1e6-table PERMANENT fills within budget", g)
end
BIG = nil
collectgarbage()

------------------------------------------------------------------------------
print("-- B1: a recipe reaching ~2000 reader-built tables (a 1000-deep chain with a pad each) still fills")
-- The shell B sits at the END of the chain, so B1-dep also proves the walk
-- reached the end: on 9c64817a A (higher index) fills first and reads nil
-- through the chain.
local function make_b1(depth)
  local mtA, mtB = {}, {}
  local A, B = setmetatable({}, mtA), setmetatable({}, mtB)
  local head = { pad = {} }
  local node = head
  for i = 2, depth do node.next = { pad = {} }; node = node.next end
  node.b = B
  local envA = { CHAIN = head, MT = mtA, SETMT = setmetatable, LOG = LOG }
  mtA.__persist = function() return setfenv(function(s)
      LOG[#LOG+1] = "A"
      local n, hops = CHAIN, 1
      while n.next do n = n.next; hops = hops + 1 end
      s.hops = hops; s.y = n.b.x; SETMT(s, MT)
    end, envA) end
  mtB.__persist = function() return function(s) LOG[#LOG+1] = "B"; s.x = 42; setmetatable(s, mtB) end end
  return { B, A }                        -- B lower id, A higher
end
do
  local t0 = os.clock()
  local oku, g = roundtrip(P, U, make_b1(1000))
  local y = oku and g[2].y or nil
  print(("  [B1] ok=%s hops=%s A.y=%s order=%s (%.3fs)"):format(
    tostring(oku), tostring(oku and g[2].hops), tostring(y), order(), os.clock() - t0))
  ok(oku, "B1 unpersist (a ~2000-object walk is far inside the budget)", g)
  if oku then
    ok(g[2].hops == 1000, "B1 the chain restored at full depth", g[2].hops)
    ok(y == 42, "B1-dep A.y == 42 through the chain end (B must fill before A)", y)
  end
end

print("FAILS: " .. fails)
return fails
