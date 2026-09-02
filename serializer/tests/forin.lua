-- forin.lua — cross-process test harness for the for-in replay iterator (A').
--
-- The defect this exists to catch CANNOT be seen in one process: a table
-- rebuilt inside the saving VM lands its string keys on the same nodes,
-- because the strings are already interned and carry their sids. Every case
-- here therefore runs save and load in SEPARATE processes, and the load side
-- can intern K throwaway strings first to rotate the hash part by a known
-- amount -- which turns an intermittent failure into a deterministic matrix
-- (see docs/research/pg-fix-design.md section 5).
--
-- Driven entirely by the environment, because test_main.c takes one argument:
--   ELJ_MODE  save | relay | load
--   ELJ_CASE  one of CASES below
--   ELJ_BLOB  path prefix for the blob and its sidecar
--   ELJ_PAD   number of throwaway strings to intern before unpersisting
--
-- Exit status is the number of failures, as with the other suites.

local mode = os.getenv("ELJ_MODE") or "save"
local case = os.getenv("ELJ_CASE") or "strings"
local path = os.getenv("ELJ_BLOB") or "forin"
local pad  = tonumber(os.getenv("ELJ_PAD") or "0")

------------------------------------------------------------------ perms ---

local function build_perms()
  local perms, uperms = {}, {}
  -- Collect every (object, name) candidate first, then assign in NAME order.
  -- An object reachable under two names -- unpack and table.unpack are the
  -- same function, and a bare _G has three such aliases -- would otherwise
  -- take whichever name pairs() reached first, and pairs() order differs
  -- BETWEEN PROCESSES. That made the perms table itself process-dependent: a
  -- blob written under one naming failed to load under the other with
  -- "unknown permanent" in 5 of 10 fresh-process loads, which is write-only
  -- save data. Real OC sorts for exactly this reason (PersistenceAPI.scala).
  local cand = {}
  local function offer(v, name) cand[#cand + 1] = { v, name } end
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
  local function add(v, name)
    if perms[v] == nil then perms[v] = name; uperms[name] = v end
  end
  for _, e in ipairs(cand) do add(e[1], e[2]) end
  -- `next` and the ipairs aux are only reachable as upvalues of the builtins
  -- that use them, and a suspended for-in loop holds one in a hidden slot.
  local named = {}
  for v, n in pairs(perms) do
    if type(v) == "function" then named[#named + 1] = { v, n } end
  end
  table.sort(named, function(a, b) return a[2] < b[2] end)  -- same reason
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

------------------------------------------------------------------ cases ---

-- Every case builds the SAME table in both processes from the same recipe, so
-- the load side knows the full key set without being told it.

local function words(n)
  local w = {}
  for i = 1, n do w[i] = string.format("key%03d_%s", i, string.rep("x", i % 7)) end
  return w
end

local RECIPES = {}

RECIPES.strings = function()
  local t = {}
  for _, k in ipairs(words(14)) do t[k] = k:upper() end
  return t
end

RECIPES.mixed = function()
  local t = { 10, 20, 30, 40, 50, 60, 70, 80 }
  for _, k in ipairs(words(8)) do t[k] = k:upper() end
  return t
end

RECIPES.array = function()
  local t = {}
  for i = 1, 12 do t[i] = i * i end
  return t
end

RECIPES.big = function()
  local t = {}
  for _, k in ipairs(words(200)) do t[k] = #k end
  return t
end

RECIPES.falsevals = function()
  local t = {}
  for i, k in ipairs(words(10)) do t[k] = (i % 2 == 0) and false or i end
  return t
end

local function recipe_for(c)
  if c == "array" or c == "jitwarm" then return RECIPES.array end
  if c == "mixed" or c == "sequential" then return RECIPES.mixed end
  if c == "big" then return RECIPES.big end
  if c == "falsevals" then return RECIPES.falsevals end
  return RECIPES.strings
end

-- Each body is a coroutine function that iterates `t` with pairs (or a
-- variant), yielding each key. Extra behaviours are folded in per case.
local BODIES = {}

local function plain(t)
  return function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.strings   = plain
BODIES.mixed     = plain
BODIES.array     = plain
BODIES.big       = plain
BODIES.perms     = plain
BODIES.permsfn   = plain
BODIES.deep      = nil  -- built below
BODIES.falsevals = function(t)
  return function()
    for k, v in pairs(t) do
      assert(v ~= nil, "pairs handed back a nil value")
      coroutine.yield(k)
    end
    return "DONE"
  end
end

BODIES.deep = function(t)
  local function lvl3() coroutine.yield("TICK") end
  local function lvl2() lvl3() end
  return function()
    for k in pairs(t) do coroutine.yield(k); lvl2() end
    return "DONE"
  end
end

BODIES.nested = function(t)
  return function()
    for k in pairs(t) do
      local inner = 0
      for _ in pairs { p = 1, q = 2 } do inner = inner + 1 end
      assert(inner == 2, "inner loop lost keys")
      coroutine.yield(k)
    end
    return "DONE"
  end
end

BODIES.sequential = function(t)
  return function()
    local first = 0
    for _ in pairs(t) do first = first + 1 end        -- completes; frees RA
    assert(first > 0)
    for k in pairs(t) do coroutine.yield(k) end       -- same base register
    return "DONE"
  end
end

BODIES.delcurrent = function(t)
  return function()
    for k in pairs(t) do t[k] = nil; coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.nextlocal = function(t)
  local nx = next                                    -- defeats predict_next:
  return function()                                  -- compiles to ITERC
    for k in nx, t do coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.nextdel = function(t)
  local nx = next                                    -- ITERC arm, and the
  return function()                                  -- current key is deleted
    for k in nx, t do t[k] = nil; coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.foreach = function(t)
  return function()                                  -- a build-time ITERN loop
    table.foreach(t, function(k) coroutine.yield(k) end)
    return "DONE"
  end
end

-- machine.lua's component.list(): a __call table whose closure keeps its
-- traversal position in an UPVALUE, not in the loop's control slot. That is a
-- DIFFERENT mechanism from the ctl-slot gap the replay iterator closes -- the
-- key round-trips perfectly, and the meaning still changes, because the key's
-- POSITION in the rebuilt table differs. No serializer change can reach it.
BODIES.oclist = function(t)
  local function mklist(tbl)
    local key = nil
    return setmetatable({}, { __call = function()
      key = next(tbl, key)
      if key ~= nil then return key, tbl[key] end
    end })
  end
  return function()
    for k in mklist(t) do coroutine.yield(k) end
    return "DONE"
  end
end

-- The one-line fix: hand back the raw triple, so the position lives in the
-- control slot where the replay iterator can rewrite it.
BODIES.oclist_fixed = function(t)
  local function mklist(tbl) return next, tbl, nil end
  return function()
    for k in mklist(t) do coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.despec = function(t)
  -- Make BC_ISNEXT's guard fail once so it rewrites the PROTOTYPE in place
  -- (ISNEXT->JMP, ITERN->ITERC) before the real run. This is the shape a
  -- Lua-5.2 __pairs shim leaves behind, and the one that used to persist
  -- silently wrong.
  local function walk(tbl, start)
    for k in next, tbl, start do coroutine.yield(k) end
    return "DONE"
  end
  local first = next(t)
  local warm = coroutine.create(function() return walk(t, first) end)
  coroutine.resume(warm)                             -- despecialises `walk`
  return function() return walk(t, nil) end
end

BODIES.jitwarm = function(t)
  return function()
    local spin = 0
    for _ = 1, 400 do
      for _, v in pairs(t) do spin = spin + v end     -- hot enough to trace
    end
    assert(spin > 0)
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end
end

local function body_for(c)
  if c == "perms" or c == "permsfn" or c == "twice" then return plain end
  return BODIES[c] or plain
end

------------------------------------------------------------------- utils ---

local function keyset(t)
  local s = {}
  for k in pairs(t) do s[k] = true end
  return s
end

local function serialize_keys(list)
  local out = {}
  for i, k in ipairs(list) do
    out[i] = (type(k) == "number") and ("n:" .. k) or ("s:" .. tostring(k))
  end
  return table.concat(out, "\n")
end

local function parse_keys(str)
  local out = {}
  for line in (str .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local kind, rest = line:sub(1, 2), line:sub(3)
      out[#out + 1] = (kind == "n:") and tonumber(rest) or rest
    end
  end
  return out
end

local function write_file(p, data)
  local f = assert(io.open(p, "wb")); f:write(data); f:close()
end

local function read_file(p)
  local f = assert(io.open(p, "rb")); local d = f:read("*a"); f:close(); return d
end

-------------------------------------------------------------------- save ---

if mode == "save" then
  local t = recipe_for(case)()
  local P, _ = build_perms()
  if case == "perms" or case == "permsfn" then P[t] = "THE_TABLE" end

  local mk = body_for(case)
  local fn = mk(t)
  if case == "permsfn" then
    -- The loop lives in a closure the loader gets from uperms, so its
    -- prototype is never serialized: the restore has to despecialise the
    -- HOST's own prototype in the new VM.
    P[fn] = "THE_BODY"
  end

  local co = coroutine.create(fn)
  local consumed, want = {}, 6
  while #consumed < want do
    local okr, v = coroutine.resume(co)
    assert(okr, v)
    if coroutine.status(co) == "dead" then break end
    if type(v) == "string" and v ~= "TICK" then consumed[#consumed + 1] = v
    elseif type(v) == "number" then consumed[#consumed + 1] = v end
  end

  local blob
  if case == "control_naive" then
    -- NEGATIVE CONTROL. Persist the iteration position the way the code did
    -- before A': a table plus the last key, resumed with `next` on the far
    -- side. Nothing here goes through the replay path, so this case MUST fail
    -- for at least one pad value -- otherwise the harness has no power to
    -- detect the defect it exists for.
    blob = eris.persist(P, { t = t, last = consumed[#consumed] })
  else
    blob = eris.persist(P, co)
  end

  write_file(path .. ".blob", blob)
  write_file(path .. ".keys", serialize_keys(consumed))
  io.write(string.format("SAVED case=%s bytes=%d consumed=%d\n",
                         case, #blob, #consumed))
  return 0
end

-------------------------------------------------------------------- load ---

-- Rotate this VM's string hash layout by interning throwaway strings BEFORE
-- the blob's own keys are interned. LuaJIT places a string key at
-- hashmask(t, s->sid), and sid comes from a per-VM counter, so K controls the
-- offset -- which is what makes the matrix below deterministic instead of a
-- 20%-flaky coin flip.
local ballast = {}
for i = 1, pad do ballast[i] = "pad/" .. i .. "/" .. string.rep("z", i % 5) end

-------------------------------------------------------------------- relay --

-- Load, consume a few more keys, save again. This is the step that exercises a
-- coroutine ALREADY in replay form: its loop's hidden func slot now holds the
-- replay iterator rather than `next`, and if the body came from uperms its
-- prototype in the NEXT process is that process's own -- still specialised,
-- even though this one's was despecialised on load. A suite that round-trips
-- only once cannot see any of that.
if mode == "relay" then
  local t = recipe_for(case)()
  local P, U = build_perms()
  if case == "perms" or case == "permsfn" then
    P[t] = "THE_TABLE"; U["THE_TABLE"] = t
  end
  if case == "permsfn" then
    local fn = body_for(case)(t)
    P[fn] = "THE_BODY"; U["THE_BODY"] = fn
  end
  local co = eris.unpersist(U, read_file(path .. ".blob"))
  local consumed = parse_keys(read_file(path .. ".keys"))
  local want = #consumed + 3
  while #consumed < want and coroutine.status(co) ~= "dead" do
    local okr, v = coroutine.resume(co)
    assert(okr, v)
    if v == "DONE" then break end
    if type(v) == "string" and v ~= "TICK" then consumed[#consumed + 1] = v
    elseif type(v) == "number" then consumed[#consumed + 1] = v end
  end
  local blob = eris.persist(P, co)
  write_file(path .. ".blob", blob)
  write_file(path .. ".keys", serialize_keys(consumed))
  io.write(string.format("RELAYED case=%s bytes=%d consumed=%d status=%s\n",
                         case, #blob, #consumed, coroutine.status(co)))
  return 0
end

local t = recipe_for(case)()
local _, U = build_perms()
if case == "perms" or case == "permsfn" then U["THE_TABLE"] = t end
if case == "permsfn" then U["THE_BODY"] = body_for(case)(t) end

local expected = keyset(t)
local consumed = parse_keys(read_file(path .. ".keys"))
local blob = read_file(path .. ".blob")

local visited, failures = {}, {}
local function fail(msg) failures[#failures + 1] = msg end

for _, k in ipairs(consumed) do visited[#visited + 1] = k end

if case == "control_naive" then
  local st = eris.unpersist(U, blob)
  for k in next, st.t, st.last do visited[#visited + 1] = k end
else
  local co = eris.unpersist(U, blob)
  if type(co) ~= "thread" then fail("restored value is a " .. type(co)) end
  local guard, last = 0, nil
  while coroutine.status(co) ~= "dead" do
    guard = guard + 1
    if guard > 100000 then fail("loop did not terminate"); break end
    local okr, v = coroutine.resume(co)
    if not okr then fail("resume failed: " .. tostring(v)); break end
    if v == "DONE" then last = v
    elseif type(v) == "string" and v ~= "TICK" then visited[#visited + 1] = v
    elseif type(v) == "number" then visited[#visited + 1] = v end
  end
  if last ~= "DONE" and #failures == 0 then
    fail("coroutine did not reach the end of its body")
  end
end

-- The whole point: the exact key multiset, not the count.
local seen, dup, missing = {}, {}, {}
for _, k in ipairs(visited) do
  if seen[k] then dup[#dup + 1] = tostring(k) end
  seen[k] = true
end
for k in pairs(expected) do if not seen[k] then missing[#missing + 1] = tostring(k) end end
for _, k in ipairs(visited) do
  if expected[k] == nil and not (case == "delcurrent") then
    dup[#dup + 1] = "alien:" .. tostring(k)
  end
end

table.sort(dup); table.sort(missing)
if #dup > 0 then fail("DUP=[" .. table.concat(dup, " ") .. "]") end
if #missing > 0 then fail("MISSING=[" .. table.concat(missing, " ") .. "]") end

io.write(string.format("%s case=%s pad=%d visited=%d/%d%s\n",
  #failures == 0 and "OK  " or "FAIL", case, pad, #visited,
  (function() local n = 0; for _ in pairs(expected) do n = n + 1 end; return n end)(),
  #failures == 0 and "" or ("  " .. table.concat(failures, "; "))))

return #failures == 0 and 0 or 1
