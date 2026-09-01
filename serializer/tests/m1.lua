-- m1.lua — test suite for the M1 data serializer.
-- Run via the test harness: serializer/erislj_test[.exe]

local pass, fail = 0, 0
local failures = {}

local function ok(cond, name, detail)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
    io.write("  FAIL: ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
  end
end

--------------------------------------------------------------------- oracle

-- Structural comparison. Byte-equality is NOT a valid oracle: table hash
-- iteration order changes across a restore (string hashes are process-random
-- by design), so a re-persisted blob legitimately differs. We compare graph
-- shape instead, including sharing/identity topology.
local function same(a, b, amap, bmap)
  amap, bmap = amap or {}, bmap or {}
  if type(a) ~= type(b) then return false, "type: " .. type(a) .. " vs " .. type(b) end
  if type(a) ~= "table" then
    if a ~= b then
      -- distinguish -0 from 0 and NaN from NaN
      if a ~= a and b ~= b then return true end
      return false, tostring(a) .. " ~= " .. tostring(b)
    end
    if type(a) == "number" and a == 0 then
      local sa = (1 / a) < 0
      local sb = (1 / b) < 0
      if sa ~= sb then return false, "zero sign differs" end
    end
    return true
  end
  -- identity topology: a must map to exactly one b and vice versa
  if amap[a] or bmap[b] then
    if amap[a] ~= b or bmap[b] ~= a then return false, "sharing topology differs" end
    return true
  end
  amap[a], bmap[b] = b, a
  local na, nb = 0, 0
  -- Table-valued keys need matching by structure, and greedily taking the
  -- first structural match is wrong when several table keys could match:
  -- a bad pairing poisons amap/bmap. Collect them and search for a
  -- consistent assignment, undoing tentative mappings that fail.
  local tkeys = {}
  for k2, v2 in pairs(b) do
    if type(k2) == "table" then tkeys[#tkeys + 1] = { k = k2, v = v2 } end
  end
  local taken = {}
  for k, v in pairs(a) do
    na = na + 1
    local bv, matched
    if type(k) == "table" then
      for i, cand in ipairs(tkeys) do
        if not taken[i] then
          -- try this pairing on a scratch copy of the mappings
          local a2, b2 = {}, {}
          for kk, vv in pairs(amap) do a2[kk] = vv end
          for kk, vv in pairs(bmap) do b2[kk] = vv end
          if same(k, cand.k, a2, b2) and same(v, cand.v, a2, b2) then
            for kk, vv in pairs(a2) do amap[kk] = vv end
            for kk, vv in pairs(b2) do bmap[kk] = vv end
            taken[i], bv, matched = true, cand.v, true
            break
          end
        end
      end
      if not matched then return false, "no consistent match for a table key" end
    else
      bv = b[k]
      if bv == nil then return false, "missing key " .. tostring(k) end
      local eq, why = same(v, bv, amap, bmap)
      if not eq then return false, "at key " .. tostring(k) .. ": " .. tostring(why) end
    end
  end
  for _ in pairs(b) do nb = nb + 1 end
  if na ~= nb then return false, "key count " .. na .. " vs " .. nb end
  local ma, mb = getmetatable(a), getmetatable(b)
  if (ma == nil) ~= (mb == nil) then return false, "metatable presence differs" end
  if ma then
    local eq, why = same(ma, mb, amap, bmap)
    if not eq then return false, "metatable: " .. tostring(why) end
  end
  return true
end

local function roundtrip(v, perms, uperms)
  local blob = eris.persist(perms or {}, v)
  return eris.unpersist(uperms or {}, blob), blob
end

local function rt_ok(v, name)
  local got = roundtrip(v)
  local eq, why = same(v, got)
  ok(eq, name, why)
  return got
end

------------------------------------------------------------------ scalars

print("-- scalars")
rt_ok(nil, "nil")
rt_ok(true, "true")
rt_ok(false, "false")
rt_ok(0, "zero")
rt_ok(-0.0, "negative zero keeps its sign")
rt_ok(1, "one")
rt_ok(-1, "minus one")
rt_ok(42, "small int")
rt_ok(-2147483648, "int32 min")
rt_ok(4294967296, "2^32")
rt_ok(9007199254740992, "2^53")
rt_ok(-9007199254740992, "-2^53")
rt_ok(0.5, "half")
rt_ok(1/3, "one third")
rt_ok(math.pi, "pi")
rt_ok(1e308, "huge finite")
rt_ok(-1e308, "negative huge")
rt_ok(math.huge, "positive infinity")
rt_ok(-math.huge, "negative infinity")
do
  local nan = roundtrip(0/0)
  ok(nan ~= nan, "NaN stays NaN")
end
rt_ok("", "empty string")
rt_ok("hello", "short string")
rt_ok(string.rep("x", 100000), "100k string")
rt_ok("bin\0ary\255\1data", "binary string with NULs")

do -- exact integer round-trips must stay integers, not drift
  local vals = { 0, 1, -1, 127, 128, 255, 256, 65535, 65536, 2^31, -2^31, 2^52 }
  local allok = true
  for _, v in ipairs(vals) do
    local g = roundtrip(v)
    if g ~= v then allok = false end
  end
  ok(allok, "integer values are exact")
end

------------------------------------------------------------------- tables

print("-- tables")
rt_ok({}, "empty table")
rt_ok({ 1, 2, 3 }, "array")
rt_ok({ a = 1, b = "two", c = false }, "hash")
rt_ok({ 1, 2, x = "y", [true] = "bool key", [3.5] = "float key" }, "mixed keys")
rt_ok({ { { { { "deep" } } } } }, "nested")
rt_ok({ [""] = "empty key" }, "empty-string key")

do -- big table
  local t = {}
  for i = 1, 10000 do t[i] = i * 2 end
  for i = 1, 1000 do t["k" .. i] = "v" .. i end
  rt_ok(t, "10k array + 1k hash")
end

--------------------------------------------------------- cycles & sharing

print("-- cycles and sharing")
do
  local t = {}
  t.self = t
  local g = roundtrip(t)
  ok(g.self == g, "direct self-reference")
end
do
  local a, b = {}, {}
  a.b, b.a = b, a
  local g = roundtrip({ a = a, b = b })
  ok(g.a.b == g.b and g.b.a == g.a, "mutual cycle")
end
do
  local shared = { value = 1 }
  local g = roundtrip({ x = shared, y = shared })
  ok(g.x == g.y, "shared subtable stays one object")
  g.x.value = 99
  ok(g.y.value == 99, "sharing is live after restore")
end
do
  local shared = {}
  local g = roundtrip({ [shared] = "as key", list = { shared } })
  ok(g.list[1] ~= nil, "shared table as key and value")
  local found
  for k in pairs(g) do if type(k) == "table" then found = k end end
  ok(found == g.list[1], "key/value identity preserved")
end
do
  local s = "interned"
  local g = roundtrip({ s, s, { s } })
  ok(g[1] == g[2] and g[2] == g[3][1], "string identity preserved")
end
do -- deep chain, well inside the recursion limit
  local root = {}
  local cur = root
  for _ = 1, 500 do cur.next = {}; cur = cur.next end
  local g = roundtrip(root)
  local n = 0
  cur = g
  while cur.next do n = n + 1; cur = cur.next end
  ok(n == 500, "500-deep chain", n)
end

--------------------------------------------------------------- metatables

print("-- metatables")
do
  local mt = { __index = function() return "dynamic" end }
  local ok_, err = pcall(roundtrip, setmetatable({}, mt))
  ok(not ok_ and tostring(err):find("function"), "metatable with a function errors cleanly (M2)", err)
end
do
  local mt = { greeting = "hi" }
  local g = roundtrip(setmetatable({}, mt))
  ok(getmetatable(g) ~= nil and getmetatable(g).greeting == "hi", "plain metatable round-trips")
end
do
  local mt = {}
  local a, b = setmetatable({}, mt), setmetatable({}, mt)
  local g = roundtrip({ a, b })
  ok(getmetatable(g[1]) == getmetatable(g[2]), "shared metatable stays shared")
end
do
  local mt = {}
  mt.__index = mt
  local t = setmetatable({}, mt)
  local g = roundtrip(t)
  ok(getmetatable(g).__index == getmetatable(g), "self-referential metatable")
end

------------------------------------------------------------------- spkey

print("-- spkey protocol")
do
  local t = setmetatable({ secret = 1 }, { __persist = false })
  local ok_, err = pcall(eris.persist, {}, t)
  ok(not ok_ and tostring(err):find("forbidden"), "__persist = false is refused", err)
end
do
  local t = setmetatable({ data = "kept" }, { __persist = true })
  local g = roundtrip(t)
  ok(g.data == "kept", "__persist = true persists literally")
end
do
  eris.settings("spkey", "__mykey")
  local t = setmetatable({}, { __mykey = false })
  local ok_, err = pcall(eris.persist, {}, t)
  ok(not ok_ and tostring(err):find("forbidden"), "custom spkey is honored", err)
  local t2 = setmetatable({ n = 5 }, { __persist = false })
  local ok2 = pcall(eris.persist, {}, t2)
  ok(ok2, "default spkey no longer applies once changed")
  eris.settings("spkey", "__persist")
end

-------------------------------------------------------------- permanents

print("-- permanents")
do
  local f = print
  local perms = { [f] = "the_print_function" }
  local uperms = { the_print_function = f }
  local g = roundtrip({ fn = f }, perms, uperms)
  ok(g.fn == print, "C function via perms")
end
do
  local t = { marker = true }
  local perms = { [t] = "shared_table" }
  local uperms = { shared_table = t }
  local g = roundtrip({ a = t, b = { t } }, perms, uperms)
  ok(g.a == t and g.b[1] == t, "table permanent, referenced twice")
end
do -- perms keys need not be strings, but must round-trip to an equal key
  local perms = { [string.byte] = 12345 }
  local uperms = { [12345] = string.byte }
  local g = roundtrip({ string.byte }, perms, uperms)
  ok(g[1] == string.byte, "numeric perms key")
end
do -- ...so a fresh table as a perms key cannot work: it is persisted by
  -- value and restores as a different object. Same in upstream Eris.
  local key = {}
  local perms = { [string.byte] = key }
  local uperms = { [key] = string.byte }
  local ok_, err = pcall(roundtrip, { string.byte }, perms, uperms)
  ok(not ok_ and tostring(err):find("unknown permanent"),
     "table perms key fails cleanly (documented limitation)", err)
end
do
  local perms = { [print] = "p" }
  local ok_, err = pcall(eris.unpersist, {}, eris.persist(perms, { print }))
  ok(not ok_ and tostring(err):find("unknown permanent"), "missing uperm errors", err)
end
do
  local perms = { [print] = "p" }
  local blob = eris.persist(perms, { print })
  local ok_, err = pcall(eris.unpersist, { p = "not a function" }, blob)
  ok(not ok_ and tostring(err):find("type"), "perm type change is caught", err)
end
do -- a permanent inside a cycle: ids must stay in lockstep
  local t = {}
  t.self = t
  t.fn = print
  local g = roundtrip(t, { [print] = "p" }, { p = print })
  ok(g.self == g and g.fn == print, "permanent inside a cycle")
end
do -- metatable that is itself a permanent
  local mt = {}
  local g = roundtrip(setmetatable({}, mt), { [mt] = "mt" }, { mt = mt })
  ok(getmetatable(g) == mt, "permanent as metatable")
end

------------------------------------------------------- unsupported types

print("-- unsupported types error cleanly")
do
  local ok_, err = pcall(eris.persist, {}, function() end)
  ok(not ok_ and tostring(err):find("M2"), "Lua function errors with a milestone hint", err)
end
do
  local ok_, err = pcall(eris.persist, {}, coroutine.create(function() end))
  ok(not ok_ and tostring(err):find("M3"), "thread errors with a milestone hint", err)
end
do
  local ok_, err = pcall(eris.persist, {}, { nested = print })
  ok(not ok_, "unsupported value nested in a table still errors", err)
end

-------------------------------------------------------- malformed input

print("-- malformed input is rejected, never crashes")
do
  local blob = eris.persist({}, { 1, 2, 3 })
  local ok_, err = pcall(eris.unpersist, {}, blob:sub(1, #blob - 6))
  ok(not ok_, "truncated blob rejected", err)
end
do
  local blob = eris.persist({}, { 1, 2, 3 })
  local flipped = blob:sub(1, #blob - 8) .. string.char((blob:byte(#blob - 7) + 1) % 256) .. blob:sub(#blob - 6)
  local ok_, err = pcall(eris.unpersist, {}, flipped)
  ok(not ok_ and tostring(err):find("checksum"), "bit flip caught by checksum", err)
end
do
  local ok_, err = pcall(eris.unpersist, {}, "not a blob at all")
  ok(not ok_ and tostring(err):find("magic"), "garbage rejected by magic", err)
end
do
  local ok_, err = pcall(eris.unpersist, {}, "")
  ok(not ok_, "empty string rejected", err)
end
do
  local blob = eris.persist({}, { 1 })
  local bad = blob:sub(1, 3) .. string.char(99) .. blob:sub(5)
  local ok_, err = pcall(eris.unpersist, {}, bad)
  ok(not ok_ and tostring(err):find("format"), "format version mismatch caught", err)
end
do -- every single-byte truncation must error rather than crash
  local blob = eris.persist({}, { a = { 1, 2 }, b = "x" })
  local crashed = false
  for i = 1, #blob - 1 do
    local ok_ = pcall(eris.unpersist, {}, blob:sub(1, i))
    if ok_ then crashed = true end
  end
  ok(not crashed, "no prefix of a valid blob unpersists successfully")
end

--------------------------------------------------------- recursion limit

print("-- recursion limit")
do
  local old = eris.settings("maxrec")
  eris.settings("maxrec", 100)
  local deep = {}
  local cur = deep
  for _ = 1, 500 do cur.n = {}; cur = cur.n end
  local ok_, err = pcall(eris.persist, {}, deep)
  ok(not ok_ and tostring(err):find("too complex"), "deep graph hits the limit cleanly", err)
  eris.settings("maxrec", old)
end

------------------------------------------------------------- idempotence

print("-- oracle: persist -> unpersist -> persist")
do
  local shared = { s = 1 }
  local v = { 1, 2, "three", t = { shared, shared }, [shared] = "key" }
  v.cycle = v
  local once = eris.persist({}, v)
  local back = eris.unpersist({}, once)
  local twice = eris.persist({}, back)
  local back2 = eris.unpersist({}, twice)
  local eq, why = same(back, back2)
  ok(eq, "double round-trip is structurally stable", why)
  ok(#once == #twice, "blob size is stable across round-trips", #once .. " vs " .. #twice)
end

----------------------------------------- regressions from the M1 review
-- Every case below was a confirmed defect found by adversarial review of
-- the first M1 build; each is reproduced here so it cannot come back.

print("-- regressions (review findings)")

-- Craft CRC-valid blobs by hand, so we can test the parser the way an
-- attacker would: a checksum is not a MAC, and any tampered save can be
-- re-sealed.
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
local function seal(body)
  local c = crc32(body)
  return body .. string.char(bit.band(c, 0xff), bit.band(bit.rshift(c, 8), 0xff),
                             bit.band(bit.rshift(c, 16), 0xff),
                             bit.band(bit.rshift(c, 24), 0xff))
end
local _, fp = eris.version()
local HDR = eris.persist({}, nil):sub(1, 5 + #fp)   -- magic..fingerprint

do -- CRITICAL: an out-of-range permanent type byte reached lua_typename(),
   -- an unchecked array index in LuaJIT -> out-of-bounds read -> SIGSEGV.
  local worst
  for t = 0, 255 do
    local blob = seal(HDR .. string.char(7, t, 5, 1, string.byte("p")))
    local ok_ = pcall(eris.unpersist, { p = print }, blob)
    if ok_ and t ~= 6 then worst = t end        -- only TFUNCTION may succeed
  end
  ok(worst == nil, "every permanent type byte 0..255 is handled safely", worst)
end

do -- HIGH: a graph at exactly maxrec depth persisted into a blob that could
   -- never be read back (write-only save data).
  local old = eris.settings("maxrec")
  local function chain(d)
    local root = {}
    local cur = root
    for _ = 1, d do cur.n = {}; cur = cur.n end
    return root
  end
  local asymmetric
  for _, d in ipairs({ 0, 1, 2, 10, 100 }) do
    for _, extra in ipairs({ 0, 1, 2, 3 }) do
      eris.settings("maxrec", d + extra)
      local okp, blob = pcall(eris.persist, {}, chain(d))
      if okp then
        local oku = pcall(eris.unpersist, {}, blob)
        if not oku then asymmetric = "depth " .. d .. " maxrec " .. (d + extra) end
      end
    end
  end
  eris.settings("maxrec", old)
  ok(asymmetric == nil, "anything that persists can be unpersisted", asymmetric)
end

do -- HIGH: maxrec had no upper clamp, so a deep crafted blob could exhaust
   -- the native C stack (uncatchable crash) instead of erroring.
  eris.settings("maxrec", 1e9)
  local enforced = eris.settings("maxrec")
  ok(enforced <= 3000, "maxrec is clamped to a stack-safe ceiling", enforced)
  local deep = seal(HDR .. string.rep(string.char(6, 0), 20000) .. string.char(0))
  local ok_, err = pcall(eris.unpersist, {}, deep)
  ok(not ok_ and tostring(err):find("too complex"),
     "deeply nested crafted blob errors instead of crashing", err)
  eris.settings("maxrec", nil)
end

do -- MEDIUM: settings(name, nil) must reset to the default, not just read.
  eris.settings("spkey", "__custom")
  ok(eris.settings("spkey") == "__custom", "spkey was changed")
  eris.settings("spkey", nil)
  ok(eris.settings("spkey") == "__persist", "settings(name, nil) resets to default")
  local old = eris.settings("maxrec")
  ok(old == 2000, "maxrec default restored by reset", old)
end

do -- MEDIUM: the maxrec getter must report the limit actually enforced.
  eris.settings("maxrec", 50)
  ok(eris.settings("maxrec") == 50, "maxrec getter reflects the set value")
  eris.settings("maxrec", 999999)
  ok(eris.settings("maxrec") == 3000, "out-of-range maxrec is normalised on set")
  eris.settings("maxrec", nil)
end

do -- MEDIUM: a TAG_REF id >= 2^63 defeated the signed range check.
  local huge = string.char(8) .. string.rep(string.char(0xff), 9) .. string.char(0x01)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. huge))
  ok(not ok_, "huge reference id is rejected", err)
end

do -- LOW: an over-long varint was silently truncated instead of rejected.
  local overlong = string.char(3) .. string.rep(string.char(0x80), 10) .. string.char(0x7f)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. overlong))
  ok(not ok_ and tostring(err):find("varint"), "over-long varint rejected", err)
end

do -- LOW: a nil value in a table record was silently dropped.
  -- table, literal, key "k", value nil, end-of-pairs nil, no metatable
  local body = string.char(6, 0) .. string.char(5, 1, string.byte("k"))
              .. string.char(0) .. string.char(0) .. string.char(0)
  local ok_, err = pcall(eris.unpersist, {}, seal(HDR .. body))
  ok(not ok_ and tostring(err):find("nil"), "nil table value rejected", err)
end

do -- The oracle itself: several table-valued keys must not confuse same().
  local k1, k2 = { id = 1 }, { id = 2 }
  local v = { [k1] = "one", [k2] = "two", plain = true }
  local g = roundtrip(v)
  local eq, why = same(v, g)
  ok(eq, "oracle handles multiple table-valued keys", why)
end

do -- A permanent whose reserved id is referenced again later.
  local perms, uperms = { [print] = "p" }, { p = print }
  local g = roundtrip({ print, print, { print } }, perms, uperms)
  ok(g[1] == print and g[2] == print and g[3][1] == print,
     "repeated permanent resolves through its reserved id")
end

do -- Memory: a failed persist must leave the library usable.
  local ok_ = pcall(eris.persist, {}, { bad = coroutine.create(function() end) })
  ok(not ok_, "persist of an unsupported value fails")
  local g = roundtrip({ still = "working" })
  ok(g.still == "working", "library still usable after a failed persist")
end

------------------------------------------------------------------ report

print()
if fail == 0 then
  print(string.format("M1 RESULT: ALL %d TESTS PASS", pass))
else
  print(string.format("M1 RESULT: %d passed, %d FAILED", pass, fail))
  for _, f in ipairs(failures) do print("  * " .. f) end
end
return fail
