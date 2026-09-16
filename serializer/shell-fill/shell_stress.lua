-- GC pressure during the graph phase and the drain; nested specials; cycles.
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

print("-- A: nested KIND-1: registry reached FIRST inside a proxy recipe's closed upvalue")
do
  local regmeta = { __persist = function() return function(s) return setmetatable(s, {}) end end }
  local REG = setmetatable({}, regmeta)
  local wrapper = { __persist = function(self)
    local reg = REG   -- CLOSED capture of the registry: its record nests inside this recipe's record
    return function(p) p.type = "userdata"; reg[p] = "d"; return setmetatable(p, {}) end
  end }
  local proxy = setmetatable({}, wrapper)
  REG[proxy] = "d"
  local root = { proxy, { proxy }, reg = REG }   -- proxy is reached before REG
  local blob = eris.persist(P, root)
  local oku, g = pcall(eris.unpersist, U, blob)
  ok(oku, "unpersist", g)
  if oku then
    ok(g.reg[g[1]] == "d", "proxy filled into the ONE registry", g.reg[g[1]])
    ok(g[2][1] == g[1], "identity kept")
    ok(next(g.reg, nil) == g[1] and next(g.reg, g[1]) == nil, "registry has exactly one entry")
  end
end

print("-- B: GC stress: 300 specials in a deep coroutine graph, GC forced aggressive, 20 round trips")
do
  collectgarbage("setpause", 20); collectgarbage("setstepmul", 400)
  local mt = { __persist = function(self)
    local n = self.n
    return function(s) s.n = n; s.pad = {} ; for i = 1, 8 do s.pad[i] = { i } end; return setmetatable(s, getmetatable(s) or { tag = "m" }) end
  end }
  local function mk()
    local co = coroutine.create(function()
      local a = {}
      for i = 1, 300 do a[i] = setmetatable({ n = i, junk = string.rep("x", 100) }, mt) end
      local deep = {}
      local cur = deep
      for i = 1, 200 do cur.next = { i = i, sp = a[(i % 300) + 1] }; cur = cur.next end
      while true do coroutine.yield(a, deep) end
    end)
    coroutine.resume(co)
    return co
  end
  local co = mk()
  local good = 0
  for round = 1, 20 do
    local blob = eris.persist(P, co)
    local oku, g = pcall(eris.unpersist, U, blob)
    if not oku then print("  round " .. round .. " unpersist error: " .. tostring(g)); break end
    local r, a, deep = coroutine.resume(g)
    local sum, cnt = 0, 0
    for i = 1, 300 do sum = sum + a[i].n; if #a[i].pad ~= 8 or getmetatable(a[i]) == nil then cnt = cnt + 1 end end
    local cur, chain = deep, 0
    while cur.next do cur = cur.next; chain = chain + 1; if cur.sp ~= a[(cur.i % 300) + 1] then cnt = cnt + 1000 end end
    if sum == 300 * 301 / 2 and cnt == 0 and chain == 200 then good = good + 1 end
    co = g
    collectgarbage("collect")
  end
  collectgarbage("setpause", 200); collectgarbage("setstepmul", 200)
  ok(good == 20, "20/20 round trips exact under GC pressure", good)
end

print("-- C: special whose recipe reads its own container (L2b) -- allowed now, complete at fill time")
do
  local holder
  local sp = setmetatable({}, { __persist = function() return function(s) s.seen = #holder; return setmetatable(s, {}) end end })
  holder = { 1, 2, 3, sp }
  local blob = eris.persist(P, { holder = holder, h2 = holder })
  local oku, g = pcall(eris.unpersist, U, blob)
  -- the recipe's `holder` upvalue is a CLOSED capture of the container... which is the
  -- object it lives in: persist_keyed's PendingRef refusal does NOT fire (the container is
  -- not the special itself), so this round-trips; the fill sees the complete container.
  ok(oku, "unpersist", g)
  if oku then ok(g.holder[4].seen == 4, "recipe saw the COMPLETE container", g.holder[4].seen) end
end

print("-- D: shell used as a table KEY and as an array value before fill")
do
  local sp = setmetatable({}, { __persist = function() return function(s) s.f = 1; return setmetatable(s, { __eq = function() return true end }) end end })
  local root = { [sp] = "keyed", sp, byname = sp }
  local blob = eris.persist(P, root)
  local oku, g = pcall(eris.unpersist, U, blob)
  ok(oku, "unpersist", g)
  if oku then ok(g[g[1]] == "keyed" and g.byname == g[1] and g[1].f == 1, "key identity and value identity agree") end
end
print("FAILS: " .. fails)
return fails
