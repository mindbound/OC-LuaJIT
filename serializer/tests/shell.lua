-- shell.lua -- Design 1's "test that must fail first", as the design specifies.
-- Case 1: poc2 ported to the shell protocol (OC's exact chain, ascending slots,
--         recipe reaches wrapInto through an OPEN upvalue declared HIGHER).
-- Case 2: legacy recipe returning a fresh table -> must be refused.
-- Case 3: inert recipe -> must be refused (no metatable).
-- Case 4: a special used as a metatable -> must be refused.
-- Case 5: a recipe that raises -> loud, names ordinal and offset.
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
LOADS = 0
function udload(className) LOADS = LOADS + 1; return "data:one" end
local P, U = build_perms()
local fails = 0
local function ok(c, what, extra) if c then print("  ok   " .. what) else fails = fails + 1; print("  FAIL " .. what .. "  -- " .. tostring(extra)) end end

print("-- case 1: OC chain on the shell protocol")
do
  local co = coroutine.create(function()
    local SANDBOX                                   -- :753 (low slot)
    local registryMeta, wrapInto, wrapper           -- :1075 group
    local REGISTRY                                  -- :1091 (special)
    SANDBOX = {}
    registryMeta = { __mode = "k",
      __persist = function() return function(s) return setmetatable(s, registryMeta) end end }
    REGISTRY = setmetatable({}, registryMeta)
    wrapper = { __persist = function(self)
        local className = REGISTRY[self]
        return function(p) return wrapInto(p, udload(className)) end
      end }
    wrapInto = function(proxy, data)
      proxy.type = "userdata"
      REGISTRY[proxy] = data
      return setmetatable(proxy, wrapper)
    end
    SANDBOX.p = wrapInto({}, "data:one")
    SANDBOX.holder = { SANDBOX.p }
    SANDBOX.report = function()
      return REGISTRY[SANDBOX.p], getmetatable(SANDBOX.p) == wrapper, SANDBOX.holder[1] == SANDBOX.p,
             getmetatable(REGISTRY) == registryMeta, SANDBOX.p.type
    end
    coroutine.yield(SANDBOX)
    return SANDBOX
  end)
  coroutine.resume(co)
  local okp, blob = pcall(eris.persist, P, co)
  ok(okp, "persist", blob)
  LOADS = 0
  local oku, g = pcall(eris.unpersist, U, blob)
  ok(oku, "unpersist", g)
  if oku then
    local r, sb = coroutine.resume(g)
    ok(r, "resume", sb)
    local reg, mt, same, regmt, ty = sb.report()
    ok(reg == "data:one", "registry[proxy] == data:one", reg)
    ok(mt == true, "getmetatable(proxy) == wrapper")
    ok(same == true, "holder[1] == proxy (same object)")
    ok(regmt == true, "registry got its metatable")
    ok(ty == "userdata", "proxy.type filled", ty)
    ok(LOADS == 1, "udload called exactly once", LOADS)
  end
end

print("-- case 2: legacy recipe (returns a fresh table) is refused")
do
  local t = setmetatable({ keep = "x" }, { __persist = function(obj)
    local kept = obj.keep
    return function() return { keep = kept, rebuilt = true } end end })
  local blob = eris.persist(P, { t })
  local oku, err = pcall(eris.unpersist, U, blob)
  ok(not oku and tostring(err):find("instead of filling its argument", 1, true), "legacy recipe refused", err)
end

print("-- case 3: inert recipe is refused")
do
  local t = setmetatable({}, { __persist = function() return function(s) end end })
  local blob = eris.persist(P, { t })
  local oku, err = pcall(eris.unpersist, U, blob)
  ok(not oku and tostring(err):find("without a metatable", 1, true), "inert recipe refused", err)
end

print("-- case 4: a special as somebody's metatable is refused")
do
  local special = setmetatable({}, { __persist = function() return function(s) return setmetatable(s, {}) end end })
  local victim = setmetatable({}, special)
  local blob = eris.persist(P, { victim, special })
  local oku, err = pcall(eris.unpersist, U, blob)
  ok(not oku and tostring(err):find("is the metatable of another object", 1, true), "special-as-metatable refused", err)
end

print("-- case 5: a raising recipe is loud and located")
do
  local t = setmetatable({}, { __persist = function() return function(s) error("boom", 0) end end })
  local blob = eris.persist(P, { t })
  local oku, err = pcall(eris.unpersist, U, blob)
  ok(not oku and tostring(err):find("recipe 1 of 1", 1, true) and tostring(err):find("boom", 1, true), "raising recipe located", err)
end

print("-- case 6: two references, one shell; special nested in a literal container (L2b)")
do
  local sp = setmetatable({}, { __persist = function() return function(s) s.filled = true; return setmetatable(s, {}) end end })
  local holder = { a = sp, b = sp, inner = { sp } }
  local blob = eris.persist(P, holder)
  local oku, g = pcall(eris.unpersist, U, blob)
  ok(oku, "unpersist", g)
  if oku then
    ok(g.a == g.b and g.inner[1] == g.a, "one object, three references")
    ok(g.a.filled == true, "filled in place")
  end
end
print("FAILS: " .. fails)
return fails
