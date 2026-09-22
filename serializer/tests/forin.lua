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

-- machine.lua's component proxy shape (kernel :1397-1406 in the patched
-- kernel): {address, type, slot, fields = {...}, <method> = ...}.  Twenty
-- methods and four fields, hash-keyed like a real gpu proxy; "fields" is the
-- one key componentProxy.__pairs hides, and its members are the second phase.
RECIPES.proxy = function()
  local t = { address = "0a1b2c3d-0000-4000-8000-0123456789ab", type = "gpu",
              slot = 1, fields = {} }
  local methods = { "bind", "getScreen", "getBackground", "setBackground",
    "getForeground", "setForeground", "getPaletteColor", "setPaletteColor",
    "maxDepth", "getDepth", "setDepth", "maxResolution", "getResolution",
    "setResolution", "getViewport", "setViewport", "get", "set", "copy", "fill" }
  for _, m in ipairs(methods) do t[m] = { address = t.address, name = m } end
  for _, f in ipairs { "fieldA", "fieldB", "fieldC", "fieldD" } do
    t.fields[f] = { getter = true, setter = (f == "fieldB") }
  end
  return t
end

local function recipe_for(c)
  if c == "array" or c == "jitwarm" then return RECIPES.array end
  if c == "mixed" or c == "sequential" then return RECIPES.mixed end
  if c == "big" then return RECIPES.big end
  if c == "falsevals" then return RECIPES.falsevals end
  if c == "ocpairs" or c == "ocpairs_snap" then return RECIPES.proxy end
  return RECIPES.strings
end

-- componentProxy.__pairs as OpenComputers ships it (kernel :1306-1319): a
-- two-phase closure over next with three mutable upvalues -- the proxy's own
-- keys except "fields", then the names in fields.  Both cursors are plain
-- keys held in upvalues, which is the oclist mechanism twice over, plus a
-- phase flag that flips at the wrong moment when the rebuilt layout runs the
-- first phase out early (os-shape-census.md #3: most pads lose AND
-- duplicate).  Kept as a known-DIVERGENT control, like oclist.
local OCPAIRS_CURRENT = {
  __pairs = function(self)
    local keyProxy, keyField, value
    return function()
      if not keyField then
        repeat
          keyProxy, value = next(self, keyProxy)
        until not keyProxy or keyProxy ~= "fields"
      end
      if not keyProxy then
        keyField, value = next(self.fields, keyField)
      end
      return keyProxy or keyField, value
    end
  end,
}

-- What kernel site 11 ships: both phases snapshotted into one array at
-- __pairs time (a synchronous loop, cannot be suspended) and walked by an
-- integer upvalue.  Same key set, same values, "fields" still hidden; no
-- next after the snapshot, so nothing depends on the hash layout.
local OCPAIRS_SNAP = {
  __pairs = function(self)
    local ks, vs, n = {}, {}, 0
    for k, v in next, self do
      if k ~= "fields" then n = n + 1; ks[n] = k; vs[n] = v end
    end
    for k, v in next, self.fields do n = n + 1; ks[n] = k; vs[n] = v end
    local i = 0
    return function()
      i = i + 1
      return ks[i], vs[i]
    end
  end,
}

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

-- What kernel site 10 ships.  oclist_fixed proves the raw triple, but the
-- kernel cannot return that: component.list's value must stay a TABLE that
-- callers index (list[addr] -> type) and that is ALSO callable, including the
-- `component.list("eeprom")()` idiom the kernel itself uses at :1532.  So the
-- keys are snapshotted into an array at list() time and __call walks that
-- array by an integer upvalue.  The loop's func slot then holds a callable
-- table the replay scan never sees -- and it must not need to: keys[i+1] is
-- the right next key whatever the rebuilt node order.  Exact on the shipping
-- serializer with NO serializer change is the whole claim.
BODIES.oclist_snap = function(t)
  local function mklist(tbl)
    local keys, n = {}, 0
    for k in next, tbl do n = n + 1; keys[n] = k end
    local i = 0
    return setmetatable(tbl, { __call = function()
      i = i + 1
      local key = keys[i]
      if key ~= nil then return key, tbl[key] end
    end })
  end
  return function()
    -- The API constraint, asserted: still a table, still indexable, and the
    -- () idiom still hands back a key.
    local probe = mklist(t)
    local k1, v1 = probe()
    assert(type(probe) == "table" and k1 ~= nil and probe[k1] == v1,
           "component.list API broke: () idiom or indexing")
    for k in mklist(t) do coroutine.yield(k) end
    return "DONE"
  end
end

-- componentProxy.__pairs, current (divergent control) and snapshot (site 11).
-- The loop is `for k in pairs(proxy)`: ISNEXT's guard fails on the closure
-- __pairs returns and the loop despecialises to ITERC over a Lua closure,
-- exactly as in the kernel.
BODIES.ocpairs = function(t)
  setmetatable(t, OCPAIRS_CURRENT)
  return function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end
end

BODIES.ocpairs_snap = function(t)
  setmetatable(t, OCPAIRS_SNAP)
  return function()
    for k in pairs(t) do coroutine.yield(k) end
    return "DONE"
  end
end

-- The snapshot cases assert the SEQUENCE, not just the multiset: the save
-- side records what the same body yields when never saved.
local function is_snap(c) return c == "oclist_snap" or c == "ocpairs_snap" end

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

---------------------------------------------------------- #9 diagnostic ---

-- The #9 diagnostic (docs/forin-iterator-gap.md, "The #9 diagnostic"). The
-- one shape left after kernel sites 10-11 is an OS author's OWN next-wrapper:
-- a Lua-closure iterator whose position lives in its upvalues, where the
-- replay cannot reach it. It cannot be rewritten -- at save time it is not
-- soundly distinguishable from a custom iterator with its own ordering -- so
-- persist() NAMES it under eris.settings("forin", "warn" | "refuse"), and the
-- default "ignore" writes the bytes it always wrote.
--
-- These cases run in ONE process (ELJ_MODE=diag): the detection is a property
-- of the saving VM. Every shape is a loadstring chunk with a chunkname WE
-- choose, so the expected "chunk:line" fragments are constants rather than
-- whatever line this file happens to put them on.
--
-- Fail-first: the shipping binary does not know the "forin" setting, so every
-- case that sets it fails there at eris.settings; the identity case uses that
-- binary as the REFERENCE WRITER (ELJ_MODE=diagblob) and passes on it, which
-- is the instrument's own determinism check.

local DIAG_TAIL = "that calls next; its position is not replayable and "
  .. "resumes against a different hash layout after a reload -- return "
  .. "next, t, nil from the iterator, or walk a snapshot array by index"

local DIAG_SHAPES = {
  -- (1) OC's componentProxy.__pairs shape: a closure over `self` calling the
  -- GLOBAL next, handed back through pairs() so the loop's state slot is nil
  -- and the table rides in an upvalue.
  wrap = { chunk = "diag_wrap", loop = 12, iter = 4, src = {
    "local t = ...",                                    -- 1
    "setmetatable(t, { __pairs = function(self)",       -- 2
    "  local key",                                      -- 3
    "  return function()",                              -- 4  the iterator closure
    "    local v",                                      -- 5
    "    key, v = next(self, key)",                     -- 6
    "    return key, v",                                -- 7
    "  end",                                            -- 8
    "end })",                                           -- 9
    "return function()",                                -- 10
    "  for k in pairs(t) do",                           -- 11
    "    coroutine.yield(k)",                           -- 12 the frame's current line
    "  end",                                            -- 13
    "  return 'DONE'",                                  -- 14
    "end" } },
  -- (2) Kernel site 11's shape: the walk snapshotted at __pairs time and an
  -- integer cursor over the array. The __pairs function itself reaches next,
  -- but it is not the iterator; the closure in the func slot holds only `ks`
  -- and `i`. This is the design's stated criterion: it must NOT be named.
  snap = { chunk = "diag_snap", src = {
    "local t = ...",                                    -- 1
    "setmetatable(t, { __pairs = function(self)",       -- 2
    "  local ks, n = {}, 0",                            -- 3
    "  for k in next, self do n = n + 1; ks[n] = k end",-- 4
    "  local i = 0",                                    -- 5
    "  return function()",                              -- 6  no next in here
    "    i = i + 1",                                    -- 7
    "    return ks[i]",                                 -- 8
    "  end",                                            -- 9
    "end })",                                           -- 10
    "return function()",                                -- 11
    "  for k in pairs(t) do",                           -- 12
    "    coroutine.yield(k)",                           -- 13
    "  end",                                            -- 14
    "  return 'DONE'",                                  -- 15
    "end" } },
  -- (2b) The documented FALSE POSITIVE: a legitimate custom iterator with its
  -- own integer position that happens to call next on an UNRELATED table.
  -- "Reaches next" is a heuristic, and this is its price; acceptable for an
  -- opt-in warning, and the reason the diagnostic names rather than rewrites.
  fp = { chunk = "diag_fp", loop = 10, iter = 3, src = {
    "local t = ...",                                    -- 1
    "local other = { a = 1 }",                          -- 2
    "local function iter(arr, i)",                      -- 3  the iterator closure
    "  i = i + 1",                                      -- 4
    "  local _ = next(other)",                          -- 5  next, on another table
    "  if arr[i] ~= nil then return i, arr[i] end",     -- 6
    "end",                                              -- 7
    "return function()",                                -- 8
    "  for i, v in iter, t, 0 do",                      -- 9
    "    coroutine.yield(v)",                           -- 10 the frame's current line
    "  end",                                            -- 11
    "  return 'DONE'",                                  -- 12
    "end" } },
}

-- A coroutine suspended two keys into the shape's loop.
local function diag_suspended(shape, tbl)
  local chunk = assert(loadstring(table.concat(shape.src, "\n"), "=" .. shape.chunk))
  local co = coroutine.create(chunk(tbl))
  for _ = 1, 2 do
    local okr, v = coroutine.resume(co)
    assert(okr and v ~= "DONE", "shape " .. shape.chunk .. " did not yield twice")
  end
  return co
end

local function diag_expected(shape)
  return string.format("for-in loop at %s:%d iterates with a Lua closure (%s:%d) %s",
                       shape.chunk, shape.loop, shape.chunk, shape.iter, DIAG_TAIL)
end

-- The identity value: shape (1) over an ARRAY, so the bytes cannot depend on
-- the string-hash layout. (Under LUAJIT_SECURITY_STRID=1 string ids are
-- reseeded from the PRNG every <256 strings, so a string-keyed table's next()
-- order -- and with it its wire order -- is per-process. That is a property
-- of the instrument, not of the change under test.)
local function diag_identity()
  local P = build_perms()
  return P, diag_suspended(DIAG_SHAPES.wrap, { 10, 20, 30, 40, 50, 60 })
end

-- The blob body: everything between the fingerprint header
-- ('E' 'L' 'J' <u8 format> <u8 fplen> <fingerprint>) and the trailing CRC,
-- which covers the header and so moves with the fingerprint by construction.
local function diag_body(blob)
  assert(blob:sub(1, 3) == "ELJ", "not an eris-lj blob")
  local fplen = blob:byte(5)
  return blob:sub(6 + fplen, -5), blob:byte(4)
end

-- One thing in a thread blob is per-process even so: the slot loop writes
-- every stack slot, and a Lua frame's LINK slot is its return PC -- a heap
-- address, written as it stands (TAG_NUM, 8 LE bytes). The restore rebuilds
-- every link from the frame records and never reads it, so it is inert; but
-- it makes two processes' blobs of one value differ in exactly those bytes
-- (measured: the shipping binary's own two runs differ at 6 bytes of one
-- 8-byte payload and nowhere else). The identity check masks precisely that
-- payload, located structurally: the same shape loaded as a SECOND chunk in
-- this process can differ from the first nowhere but that pointer, and the
-- payload must sit behind its own TAG_NUM byte. Anything else is a real
-- difference and fails. (README, known limitations, records the finding.)
local function diag_link_window(bodyA, bodyB)
  assert(#bodyA == #bodyB, "two in-process blobs of one shape differ in length")
  local first, last
  for i = 1, #bodyA do
    if bodyA:byte(i) ~= bodyB:byte(i) then first = first or i; last = i end
  end
  if not first then return nil end
  local cands = {}
  for p = math.max(2, last - 7), first do
    if bodyA:byte(p - 1) == 4 and last < p + 8 then cands[#cands + 1] = p end
  end
  assert(#cands == 1, string.format(
    "cannot localise the frame-link payload: %d candidates for diffs at %d..%d",
    #cands, first, last))
  return cands[1], cands[1] + 7
end

if mode == "diagblob" then
  -- The reference writer: the identity value, default mode, to ELJ_BLOB.
  -- tests/fixtures/forin-identity.blob was written by the shipping binary
  -- this way (see run-forin.sh).
  local P, co = diag_identity()
  local blob = eris.persist(P, co)
  write_file(path, blob)
  io.write(string.format("DIAGBLOB bytes=%d body=%d\n", #blob, #diag_body(blob)))
  return 0
end

if mode == "diag" then
  local nfail = 0
  local function case(name, fn)
    local okc, note = pcall(fn)
    pcall(eris.settings, "forin", nil)              -- never leak a mode
    if okc then
      io.write("OK   diag/", name, note and ("  -- " .. tostring(note)) or "", "\n")
    else
      nfail = nfail + 1
      io.write("FAIL diag/", name, "  -- ", tostring(note), "\n")
    end
  end
  local function drain()
    local d = eris.diagnostics()
    assert(type(d) == "table", "diagnostics() returned a " .. type(d))
    return d
  end

  case("0-setting", function()
    assert(eris.settings("forin") == "ignore", "the default is not ignore")
    assert(eris.settings("forin", "warn") == "ignore", "set did not return the old value")
    assert(eris.settings("forin") == "warn", "set did not stick")
    local okb, e = pcall(eris.settings, "forin", "loud")
    assert(not okb and tostring(e):find("invalid option", 1, true),
           "a bogus mode was accepted: " .. tostring(e))
    assert(eris.settings("forin", "refuse") == "warn")
    assert(eris.settings("forin", nil) == "refuse" and eris.settings("forin") == "ignore",
           "nil did not reset to the default")
    assert(type(eris.diagnostics) == "function", "no eris.diagnostics")
    assert(next(drain()) == nil, "diagnostics() is not empty before any persist")
    return "ignore/warn/refuse validated, bogus refused, nil resets; diagnostics() empty"
  end)

  case("1-wrap-warn", function()
    local P = build_perms()
    local co = diag_suspended(DIAG_SHAPES.wrap, RECIPES.proxy())
    eris.settings("forin", "warn")
    eris.persist(P, co)
    local d = drain()
    assert(#d == 1, "expected exactly one diagnostic, got " .. #d
           .. (d[1] and ("; first: " .. tostring(d[1])) or ""))
    assert(d[1]:find("diag_wrap:12", 1, true), "the loop location is missing: " .. d[1])
    assert(d[1]:find("(diag_wrap:4)", 1, true), "the iterator location is missing: " .. d[1])
    local want = diag_expected(DIAG_SHAPES.wrap)
    assert(d[1] == want, "message differs:\n     got  " .. d[1] .. "\n     want " .. want)
    assert(next(drain()) == nil, "diagnostics() did not clear the list")
    return d[1]
  end)

  case("1b-ocpairs-body-warn", function()
    -- This file's own ocpairs control body, as the pad matrix runs it.
    local P = build_perms()
    local co = coroutine.create(BODIES.ocpairs(RECIPES.proxy()))
    for _ = 1, 2 do assert(coroutine.resume(co)) end
    eris.settings("forin", "warn")
    eris.persist(P, co)
    local d = drain()
    assert(#d == 1, "expected exactly one diagnostic, got " .. #d)
    local _, n = d[1]:gsub("forin%.lua:%d+", "")
    assert(n == 2, "expected two forin.lua locations in: " .. d[1])
    return d[1]
  end)

  case("2-snap-warn", function()
    local P = build_perms()
    local co = diag_suspended(DIAG_SHAPES.snap, RECIPES.proxy())
    eris.settings("forin", "warn")
    eris.persist(P, co)
    local d = drain()
    assert(#d == 0, "the snapshot walker was named: " .. tostring(d[1]))
    return "no diagnostic for the snapshot-array iterator"
  end)

  case("2b-kernel-snap-bodies-warn", function()
    -- This file's own site 10 / site 11 bodies (oclist_snap: a callable
    -- table in the func slot; ocpairs_snap: a closure over an array).
    local P = build_perms()
    eris.settings("forin", "warn")
    for _, c in ipairs { "oclist_snap", "ocpairs_snap" } do
      local co = coroutine.create(BODIES[c](recipe_for(c)()))
      for _ = 1, 2 do assert(coroutine.resume(co)) end
      eris.persist(P, co)
      local d = drain()
      assert(#d == 0, c .. " was named: " .. tostring(d[1]))
    end
    return "oclist_snap and ocpairs_snap: no diagnostic"
  end)

  case("2c-false-positive-warn", function()
    local P = build_perms()
    local co = diag_suspended(DIAG_SHAPES.fp, { 10, 20, 30, 40 })
    eris.settings("forin", "warn")
    eris.persist(P, co)
    local d = drain()
    assert(#d == 1, "expected the documented false positive, got " .. #d)
    local want = diag_expected(DIAG_SHAPES.fp)
    assert(d[1] == want, "message differs:\n     got  " .. d[1] .. "\n     want " .. want)
    return "KNOWN FALSE POSITIVE, documented: " .. d[1]
  end)

  case("3-wrap-refuse", function()
    local P = build_perms()
    local co = diag_suspended(DIAG_SHAPES.wrap, RECIPES.proxy())
    eris.settings("forin", "refuse")
    local okp, err = pcall(eris.persist, P, co)
    assert(not okp, "persist succeeded under refuse")
    local want = diag_expected(DIAG_SHAPES.wrap)
    assert(tostring(err):find(want, 1, true),
           "the error does not carry the message:\n     " .. tostring(err))
    assert(next(drain()) == nil, "refuse also queued the message")
    eris.settings("forin", "ignore")
    assert(#eris.persist(P, co) > 0, "still not persistable under ignore")
    return tostring(err)
  end)

  case("4-identity", function()
    local ref = os.getenv("ELJ_REF")
    assert(ref and ref ~= "", "ELJ_REF (the reference blob) is not set")
    local rbody, rfmt = diag_body(read_file(ref))
    -- Runnable on the reference writer too, which does not know the setting:
    -- there it is the instrument's own cross-process determinism check.
    local oks, m = pcall(eris.settings, "forin")
    assert(not oks or m == "ignore", "not in the default mode")
    local P, coA = diag_identity()
    local _, coB = diag_identity()              -- a second chunk: another address
    local bodyA, fmt = diag_body(eris.persist(P, coA))
    local bodyB = diag_body(eris.persist(P, coB))
    local lo, hi = diag_link_window(bodyA, bodyB)
    local function masked(b)
      if not lo then return b end
      return b:sub(1, lo - 1) .. string.rep("\0", hi - lo + 1) .. b:sub(hi + 1)
    end
    assert(fmt == rfmt, string.format("format byte %d vs reference %d", fmt, rfmt))
    local a, r = masked(bodyA), masked(rbody)
    if a ~= r then
      local at = math.min(#a, #r) + 1
      for i = 1, math.min(#a, #r) do
        if a:byte(i) ~= r:byte(i) then at = i; break end
      end
      error(string.format("body differs from the reference at byte %d (lengths %d vs %d)",
                          at, #a, #r))
    end
    return string.format("%d body bytes identical to %s outside the frame-link payload at %s (format %d)",
                         #bodyA, ref, lo and (lo .. ".." .. hi) or "none", fmt)
  end)

  case("4b-default-quiet-warn-same-bytes", function()
    local P, co = diag_identity()
    local blob0 = eris.persist(P, co)                 -- the default: ignore
    assert(next(drain()) == nil, "the default mode queued a diagnostic")
    eris.settings("forin", "warn")
    local blob1 = eris.persist(P, co)
    local d = drain()
    assert(#d == 1, "warn named " .. #d .. " loops")
    assert(blob0 == blob1, "warn mode changed the bytes")
    return "ignore queues nothing; warn queues 1 and writes the identical blob"
  end)

  io.write(string.format("DIAG %d case(s) failed\n", nfail))
  return nfail
end

-------------------------------------------------------------------- save ---

if mode == "save" then
  local t = recipe_for(case)()
  local P, _ = build_perms()
  if case == "perms" or case == "permsfn" then P[t] = "THE_TABLE" end

  local mk = body_for(case)
  if is_snap(case) then
    -- The never-saved reference: the same body over the same table in this
    -- process, run to completion before the real coroutine is created.  The
    -- snapshot both take is of the same layout, so the load side can demand
    -- the identical sequence, not merely the same multiset.
    local ref = coroutine.create(mk(t))
    local full = {}
    while coroutine.status(ref) ~= "dead" do
      local okr, v = coroutine.resume(ref)
      assert(okr, v)
      if v == "DONE" then break end
      full[#full + 1] = v
    end
    write_file(path .. ".full", serialize_keys(full))
  end
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

-- What a complete walk must yield.  For the proxy cases that is NOT keyset(t):
-- the reference semantics are the CURRENT two-phase __pairs, run to
-- completion in this process and never saved -- the proxy's own keys except
-- "fields", then the names in fields.  ocpairs_snap is held to exactly this
-- multiset, which is the "same as ocpairs's never-saved run" claim; the two
-- asserts keep the reference honest (a plain pairs walk would show "fields"
-- and no field names).
local function expected_for(c, tbl)
  if c == "ocpairs" or c == "ocpairs_snap" then
    local ref = setmetatable(recipe_for(c)(), OCPAIRS_CURRENT)
    local s = {}
    for k in pairs(ref) do
      assert(s[k] == nil, "the reference walk repeated " .. tostring(k))
      s[k] = true
    end
    assert(s.fields == nil and s.fieldA == true and s.bind == true,
           "the reference walk is not the two-phase walk")
    return s
  end
  return keyset(tbl)
end

local expected = expected_for(case, t)
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

-- The snapshot cases must reproduce the never-saved SEQUENCE: an integer
-- cursor over an array has no other correct answer.
if is_snap(case) then
  local full = parse_keys(read_file(path .. ".full"))
  local where = (#full == #visited) and 0 or -1
  if where == 0 then
    for i = 1, #full do
      if full[i] ~= visited[i] then where = i; break end
    end
  end
  if where ~= 0 then
    fail(string.format("ORDER differs from the never-saved run at %s (ref %d keys, got %d)",
                       where < 0 and "length" or tostring(where), #full, #visited))
  end
end

io.write(string.format("%s case=%s pad=%d visited=%d/%d%s\n",
  #failures == 0 and "OK  " or "FAIL", case, pad, #visited,
  (function() local n = 0; for _ in pairs(expected) do n = n + 1 end; return n end)(),
  #failures == 0 and "" or ("  " .. table.concat(failures, "; "))))

return #failures == 0 and 0 or 1
