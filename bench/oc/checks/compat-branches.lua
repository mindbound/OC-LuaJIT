-- Does compat.lua's bit32 branch produce the SAME digest as its operator
-- branch?  Nothing else answers this.  The standalone VMs available here
-- (luajit, lua5.3, lua5.4) all parse bitwise operators, so all three take the
-- operator branch -- but cell A of the in-machine comparison is PUC Lua 5.2,
-- which cannot parse them and will take the bit32 branch instead.  If the two
-- branches disagree, cell A reports a wrong CHECK and the row is lost.
--
-- bit32 is emulated here in pure arithmetic (no operators, so this file runs
-- anywhere).  That does not test OC's C bit32 -- it tests compat's WIRING of
-- the bit32 branch: argument order, the missing-normalisation trap, rrotate's
-- direction.  Those are the failure modes that are actually plausible.

local R = arg[1] or "."

local function mk32()
  local function norm(x) return x % 4294967296 end
  local function bitop(a, b, f)
    a, b = norm(a), norm(b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      r = r + f(x, y) * p
      a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
  end
  local t = {}
  function t.band(a, b) return bitop(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
  function t.bor(a, b) return bitop(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end) end
  function t.bxor(a, b) return bitop(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
  function t.bnot(a) return norm(-norm(a) - 1) end
  function t.lshift(a, n)
    if n >= 32 or n <= -32 then return 0 end
    if n < 0 then return t.rshift(a, -n) end
    return norm(norm(a) * 2 ^ n)
  end
  function t.rshift(a, n)
    if n >= 32 or n <= -32 then return 0 end
    if n < 0 then return t.lshift(a, -n) end
    return math.floor(norm(a) / 2 ^ n)
  end
  function t.rrotate(a, n)
    n = n % 32
    a = norm(a)
    if n == 0 then return a end
    return norm(t.rshift(a, n) + t.lshift(a, 32 - n))
  end
  return t
end

local function loadcompat(force32)
  local f = assert(io.open(R .. "/bench/oc/compat.lua", "rb"))
  local src = f:read("*a"); f:close()
  if force32 then
    -- Make the operator probe fail the way it fails on PUC 5.2: `load` returns
    -- nil for a syntax error there, so hand compat a load that does the same.
    src = "local load = function() return nil, 'forced: no bitwise operators' end\n"
       .. "local bit32 = _FORCED_BIT32\n" .. src
  end
  local chunk = assert(load(src, "=compat"))
  return chunk()
end

-- 1. the two branches must agree on every primitive
local ops = loadcompat(false)
_G._FORCED_BIT32 = mk32()
local b32 = loadcompat(true)
print("operator branch path = " .. tostring(ops.path))
print("bit32    branch path = " .. tostring(b32.path))
assert(ops.path == "operators", "the operator branch did not engage on this VM")
assert(b32.path == "bit32-STITCHED", "the forced bit32 branch did not engage")

local bad = 0
local vals = {0, 1, 2, 255, 256, 0x7FFFFFFF, 0x80000000, 0xDEADBEEF, 0xFFFFFFFF, 12345678}
local function cmp(name, x, y, a, b)
  if ops.norm(x) ~= ops.norm(y) then
    bad = bad + 1
    if bad <= 10 then
      print(string.format("  MISMATCH %s(%s,%s): operators=%s bit32=%s",
        name, tostring(a), tostring(b), ops.tohex32(x), ops.tohex32(y)))
    end
  end
end
for _, a in ipairs(vals) do
  for _, b in ipairs(vals) do
    cmp("band", ops.band(a, b), b32.band(a, b), a, b)
    cmp("bor", ops.bor(a, b), b32.bor(a, b), a, b)
    cmp("bxor", ops.bxor(a, b), b32.bxor(a, b), a, b)
  end
  cmp("bnot", ops.bnot(a), b32.bnot(a), a, nil)
  for n = 0, 31 do
    cmp("lshift", ops.lshift(a, n), b32.lshift(a, n), a, n)
    cmp("rshift", ops.rshift(a, n), b32.rshift(a, n), a, n)
    cmp("rrotate", ops.rrotate(a, n), b32.rrotate(a, n), a, n)
  end
end
print(bad == 0 and "PRIMITIVES: identical on both branches"
                or ("PRIMITIVES: " .. bad .. " MISMATCHES"))

-- 2. and the whole benchmark must produce the same digest through each
-- SIZE is cut to 100 blocks for BOTH branches.  The emulated bit32 above is
-- pure arithmetic -- 32 loop iterations and a closure call per bit -- so the
-- shipped 2 MiB would take hours.  What is being compared is whether the two
-- branches agree, and they agree or disagree on the first block; the published
-- 2 MiB digest is verified separately, on the operator path, by the suite
-- itself.
local function runsha(compat, size)
  local f = assert(io.open(R .. "/bench/oc/sha256.lua", "rb"))
  local src = f:read("*a"); f:close()
  local n
  src, n = src:gsub("local SIZE = 2097152", "local SIZE = " .. size, 1)
  assert(n == 1, "sha256.lua no longer declares SIZE the way this check expects")
  local saved = _G.__OCLJ_COMPAT
  _G.__OCLJ_COMPAT = compat
  local d, t = assert(load(src, "=sha256"))()
  _G.__OCLJ_COMPAT = saved
  return d, t
end
local SMALL = 6400
local d1, t1 = runsha(ops, SMALL)
local d2, t2 = runsha(b32, SMALL)
print(string.format("sha256[%d B] via operators = %s  (%.3f s)", SMALL, d1, t1))
print(string.format("sha256[%d B] via bit32     = %s  (%.3f s)", SMALL, d2, t2))
print(d1 == d2 and "DIGEST: identical -- cell A can run this benchmark"
                or "DIGEST: DIFFERENT -- cell A would report a wrong CHECK")
os.exit((bad == 0 and d1 == d2) and 0 or 1)
