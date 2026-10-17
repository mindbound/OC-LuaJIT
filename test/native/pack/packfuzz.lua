-- test/native/pack/packfuzz.lua -- differential fuzzer for string.pack /
-- string.unpack / string.packsize.  The SAME script runs under PUC Lua 5.3.6
-- (the reference) and under the build's luajit.exe, whose string library
-- carries ours (native/luajit/oclj_strpack.c, registered in lib_string.c, so
-- it is the code path every native ships).  Every case writes ONE canonical
-- line; packfuzz-cmp.lua compares the two files line by line.
-- test/native/run-packfuzz.sh drives both.  Written by the r2 "fuzz"
-- investigator, 2026-10-17.
--
--   <interp> packfuzz.lua <out-file> <puc|ours> [seed] [ncases] [profile] [sync]
--
--   profile  default  every option, edges, malformed formats, sizes <= 128 KiB;
--                     its hostile arguments include the numerals LuaJIT's
--                     own scanner reads differently from 5.3's (pack converts
--                     them by 5.3's rules, so they must match: gated here)
--            long     the default mix plus large strings (s3 near 2^24, 16 MiB)
--            coerce   string<->number coercion of arguments, the same
--                     numerals included; expected to report MISMATCH for
--                     numbers given to c/s/z, which LuaJIT's tostring formats
--                     (documents the VM; not a gate)
--            limits   the C-stack limit on the number of unpacked values
--                     (LUAI_MAXCSTACK, 8000: expected to report MISMATCH)
--   sync     "sync" flushes after every line (to locate a crash)
--
-- LINE FORMAT:  <id>|<kind>|<op>|<desc>|<result>
--   desc    the case as generated, identical on both sides by construction
--   result  "ok <tok> <tok> ..." or "err <normalised message>"
--   tokens  numbers: an exact, VM-independent rendering (no printf):
--             integral |v| < 2^53 -> decimal;  else <odd-ish mantissa>p<exp>;
--             nan / inf / -inf / -0.
--           PUC integers that a double cannot hold print as
--             R<exact decimal>~<rendering of the nearest double>
--           so the comparator can apply the decided rounding deviation.
--           strings: s<len>:<hex>, or s<len>#<hex of 8>.<hash> when long.
-- The PUC side renders 'l' as "i8" and 'L' as "I8" (the decided 8-byte size;
-- PUC's sizeof(long) is 4 on Win64); the desc always shows the format as
-- generated.

local OUT, SIDE, SEED, NCASES, PROFILE, SYNC = ...
if not OUT or not SIDE then
  error("usage: packfuzz.lua <out-file> <puc|ours> [seed] [ncases] [profile] [sync]")
end
SEED = tonumber(SEED) or 1
NCASES = tonumber(NCASES) or 2000
PROFILE = PROFILE or "default"
local HAS_INT = (math.type ~= nil) and (math.type(1) == "integer")
if SIDE == "puc" then
  assert(HAS_INT, "side=puc, but this VM has no integer subtype: wrong interpreter")
elseif SIDE == "ours" then
  assert(not HAS_INT, "side=ours, but this VM has an integer subtype: wrong interpreter")
else
  error("side must be puc or ours")
end
local PK, UN, PS = string.pack, string.unpack, string.packsize
if not (PK and UN and PS) then
  error("string.pack/unpack/packsize missing on side " .. SIDE)
end

local floor, HUGE = math.floor, math.huge
local fmt, char, byte, sub, rep = string.format, string.char, string.byte, string.sub, string.rep
local concat = table.concat
local tunpack = table.unpack or unpack
local function D(n) return fmt("%d", n) end
local function tpack(...) return { n = select("#", ...), ... } end

-- ---------------------------------------------------------------- numbers
-- Powers of two by exact doubling/halving (no pow(): libm differs per VM).
local POW2 = { [0] = 1.0 }
for k = 1, 1023 do POW2[k] = POW2[k - 1] * 2 end
for k = -1, -1074, -1 do POW2[k] = POW2[k + 1] * 0.5 end
local TWO53 = POW2[53]
local NAN = (function() local z = 0.0; return z / z end)()
local NNAN = -NAN
local NZERO = (function() local z = 0.0; return -z end)()

-- exact rendering of a double (the same arithmetic on both VMs)
local function canon(v)
  if v ~= v then return "nan" end
  if v == HUGE then return "inf" end
  if v == -HUGE then return "-inf" end
  if v == 0 then if 1 / v < 0 then return "-0" end return "0" end
  local sign = ""
  if v < 0 then sign = "-"; v = -v end
  if v < TWO53 and v == floor(v) then return sign .. D(v) end
  local e = 0
  while v >= TWO53 do v = v * 0.5; e = e + 1 end
  while v ~= floor(v) do v = v * 2; e = e - 1 end
  return sign .. D(v) .. "p" .. D(e)
end

-- a result number; on PUC an integer is converted the way the decided
-- deviation says ours must: to the nearest double.
local function numtok(v)
  if HAS_INT and math.type(v) == "integer" then
    local f = v + 0.0
    if math.tointeger(f) == v then return canon(f) end
    return "R" .. D(v) .. "~" .. canon(f)
  end
  return canon(v)
end

-- ---------------------------------------------------------------- strings
local HEX = {}
for b = 0, 255 do HEX[char(b)] = fmt("%02x", b) end
local function hex(s) return (s:gsub(".", HEX)) end
local ESC = {}
for b = 0, 255 do
  local c = char(b)
  if b >= 32 and b <= 126 and c ~= "\\" and c ~= "|" then ESC[c] = c else ESC[c] = fmt("\\x%02x", b) end
end
local function esc(s) return (s:gsub(".", ESC)) end
local function hash(s)
  local h1, h2 = 0, 0
  for i = 1, #s do
    local b = byte(s, i)
    h1 = (h1 * 257 + b) % 2147483629
    h2 = (h2 * 263 + b + 1) % 2147483587
  end
  return fmt("%08x%08x", h1, h2)
end
local function strtok(s, lim)
  if #s <= lim then return "s" .. D(#s) .. ":" .. hex(s) end
  return "s" .. D(#s) .. "#" .. hex(sub(s, 1, 8)) .. "." .. hash(s)
end
local function argtok(v)
  local t = type(v)
  if t == "number" then return canon(v) end
  if t == "string" then return strtok(v, 64) end
  if t == "nil" then return "nil" end
  if t == "boolean" then return v and "true" or "false" end
  return t
end
local function normerr(e)
  if type(e) ~= "string" then return "<error object: " .. type(e) .. ">" end
  e = e:gsub("^[^:\n]*:%d+: ", "")
  -- the function name depends on how the call was reached (pcall: PUC
  -- 'string.pack', LuaJIT '?'), not on the implementation
  e = e:gsub("^bad argument #(%d+) to '[^']*'", "bad argument #%1 to 'F'")
  return e
end

-- ---------------------------------------------------------------- PRNG
-- L'Ecuyer's combined MLCG in Schrage form: every intermediate is an integer
-- below 2^47, exact as a double and as a 5.3 integer, so both VMs draw the
-- same sequence.
local s1, s2
local function nextu()
  local k = floor(s1 / 53668)
  s1 = 40014 * (s1 - k * 53668) - k * 12211
  if s1 < 0 then s1 = s1 + 2147483563 end
  k = floor(s2 / 52774)
  s2 = 40692 * (s2 - k * 52774) - k * 3791
  if s2 < 0 then s2 = s2 + 2147483399 end
  local z = s1 - s2
  if z < 1 then z = z + 2147483562 end
  return z
end
local function seed_rng(seed)
  seed = floor(seed) % 2147483562
  s1 = seed + 1
  s2 = (floor(seed / 7) * 7919 + 12345) % 2147483398 + 1
  for _ = 1, 32 do nextu() end
end
local function rand(n) return (nextu() - 1) % n + 1 end         -- 1..n
local function chance(pct) return rand(100) <= pct end
local function pick(t) return t[rand(#t)] end
local function randbits(k)                                        -- [0, 2^k), k <= 53
  local v = 0.0                    -- a float on PUC too: -v must be -0.0 on both VMs
  while k > 0 do
    local b = k < 24 and k or 24
    v = v * POW2[b] + (nextu() % POW2[b])
    k = k - b
  end
  return v
end
local function randint_bits(k)                                    -- [0, 2^k), any k
  if k <= 53 then return randbits(k) end
  return randbits(53) * POW2[k - 53]
end
local function randdouble()
  local m = (POW2[52] + randbits(52)) * POW2[-52]                 -- [1, 2)
  local v = m * POW2[rand(2098) - 1075]                           -- 2^-1074 .. 2^1023
  if chance(50) then v = -v end
  return v
end
local function randstr(n, nozero)
  local t, out = {}, {}
  for i = 1, n do
    t[#t + 1] = nozero and rand(255) or (rand(256) - 1)
    if #t == 512 then out[#out + 1] = char(tunpack(t)); t = {} end
  end
  if #t > 0 then out[#out + 1] = char(tunpack(t)) end
  return concat(out)
end
local function bigstr(n, nozero)                                  -- cheap large string
  if n <= 4096 then return randstr(n, nozero) end
  local block = randstr(4096, nozero)
  local s = rep(block, floor(n / 4096)) .. sub(block, 1, n % 4096)
  local k = rand(n)                                               -- one distinct byte
  return sub(s, 1, k - 1) .. char(nozero and rand(255) or (rand(256) - 1)) .. sub(s, k + 1)
end

-- ---------------------------------------------------------------- pools
local function addv(t, v) t[#t + 1] = v end
local INT_EDGES = {}
for _, k in ipairs{0, 1, 7, 8, 15, 16, 23, 24, 31, 32, 39, 40, 47, 48, 52, 53, 54, 55, 56,
                   62, 63, 64, 65, 72, 120, 127, 128} do
  local p = POW2[k]
  addv(INT_EDGES, p); addv(INT_EDGES, -p)
  addv(INT_EDGES, p - 1); addv(INT_EDGES, -p + 1)
  addv(INT_EDGES, p + 1); addv(INT_EDGES, -p - 1)
end
addv(INT_EDGES, POW2[63] - POW2[10]); addv(INT_EDGES, -POW2[63] - POW2[11])
addv(INT_EDGES, POW2[64] - POW2[11]); addv(INT_EDGES, TWO53 + 2); addv(INT_EDGES, -(TWO53 + 2))
addv(INT_EDGES, 0.0); addv(INT_EDGES, NZERO)
local NONINT = { 0.5, -0.5, 1.5, -1.5, POW2[52] + 0.5, -(POW2[52] + 0.5), 1 / 3, 0.1, 1e-300,
                 POW2[-1074], -POW2[-1074], 1e300, -1e300, NAN, NNAN, HUGE, -HUGE, NZERO }
local FLT_MAX = (2 - POW2[-23]) * POW2[127]
local FLT_EDGES = { FLT_MAX, -FLT_MAX, FLT_MAX + POW2[103], FLT_MAX + POW2[102], POW2[-149],
                    POW2[-150], POW2[-149] * 1.5, POW2[-126], POW2[-126] - POW2[-149],
                    1 + POW2[-24], 1 + POW2[-23] + POW2[-24], 1 + POW2[-52],
                    (2 - POW2[-52]) * POW2[1023], POW2[-1022], POW2[-1022] - POW2[-1074],
                    POW2[127], POW2[128], -POW2[128], 0.0, NZERO, NAN, NNAN, HUGE, -HUGE, 0.1, 1 / 3 }
-- numeric strings both VMs convert identically (decimal |x| <= 2^53, small hex)
local SAFE_STR = { "10", "-10", " 10 ", "\t7\n", "0x10", "0X1f", "1e2", "1E+2", "1.5", "-2.5", "10.",
                   ".5", "+5", "0x1p4", "1e400", "-1e400", "4294967296", "-4294967297",
                   "9007199254740992", "-0.0", "x", "", "0x", "1e", " ", "1 2", "--1",
                   "1_0", "0x1.8", "0x.8p1", "0x10p-1", "00012", "1e-400", "\v5\f", "5\r",
                   "1i", "1LL", "1e+", "0x1p" }  -- verified: checks/safe-strings.lua
-- strings at or near where the VMs' own scanners differ (tonumber gives a
-- different result on the two VMs for all but three of them).  pack and
-- unpack convert them by 5.3.6's rules (decided, D5), so they must match:
-- drawn by the default mix's hostile arguments (k_bad, which gates them)
-- and by the coerce profile.
local COERCE_STR = { "inf", "-inf", "nan", "-nan", "-0", "9007199254740993", "-9007199254740993",
                     "18446744073709551615", "9223372036854775807", "-9223372036854775808",
                     "0xffffffffffffffff", "0x8000000000000000", "0x10000000000000000",
                     "0x7fffffffffffffff", "1e15", "0x1P-1074", "0b101", "0B11" }  -- LuaJIT reads 0b binary
local NONNUM = { "nil", "true", "false", "table" }
local function nonnum()
  local w = pick(NONNUM)
  if w == "nil" then return nil elseif w == "true" then return true
  elseif w == "false" then return false end
  return {}
end

-- ---------------------------------------------------------------- formats
-- An item: { t = text, k = kind, size = data size, asz = alignment size,
--            signed = bool, align = maxalign for '!' }
local FIXED_INTS = { { "b", 1, true }, { "B", 1, false }, { "h", 2, true }, { "H", 2, false },
                     { "l", 8, true }, { "L", 8, false }, { "j", 8, true }, { "J", 8, false },
                     { "T", 8, false } }
local function size_suffix(default, bad)
  if bad and chance(5) then local v = pick{ 0, 17, 99, 255 }; return D(v), v end
  if chance(30) then return "", default end
  local n = rand(16)
  return D(n), n
end
local function pick_csize()
  local r = rand(100)
  if r <= 40 then return rand(9) - 1 end
  if r <= 80 then return 8 + rand(32) end
  if r <= 95 then return pick{ 64, 100, 255, 256, 1000 } end
  return rand(4096)
end
local XOPS = { { "b", 1 }, { "B", 1 }, { "h", 2 }, { "H", 2 }, { "i", 4 }, { "I", 4 }, { "i1", 1 },
               { "i2", 2 }, { "i3", 3 }, { "i4", 4 }, { "i5", 5 }, { "i8", 8 }, { "i16", 16 },
               { "I7", 7 }, { "j", 8 }, { "J", 8 }, { "T", 8 }, { "l", 8 }, { "L", 8 }, { "f", 4 },
               { "d", 8 }, { "n", 8 }, { "s", 8 }, { "s1", 1 }, { "s2", 2 }, { "s4", 4 },
               { "s16", 16 }, { "x", 1 } }
local XOPS_BAD = { "c1", "c", "c0", "z", " ", "<", ">", "=", "!", "!4", "X", "Xi4", "i17", "i0" }
local function gen_X(bad)
  if bad and chance(25) then return { t = "X" .. pick(XOPS_BAD), k = "X", size = 0, asz = 0 } end
  local o = pick(XOPS)
  return { t = "X" .. o[1], k = "X", size = 0, asz = o[2] }
end
local function gen_cfg(bad)
  local r = rand(6)
  if r == 1 then return { t = "<", k = "cfg" } end
  if r == 2 then return { t = ">", k = "cfg" } end
  if r == 3 then return { t = "=", k = "cfg" } end
  if r == 4 then return { t = " ", k = "cfg" } end
  local sfx
  if bad and chance(30) then sfx = pick{ "3", "5", "6", "12", "0", "17" }
  else sfx = pick{ "", "1", "2", "4", "8", "16" } end
  return { t = "!" .. sfx, k = "cfg", align = (sfx == "") and 8 or tonumber(sfx) }
end
local function gen_item(bad)
  local r = rand(23)
  if r <= 9 then
    local f = FIXED_INTS[r]
    return { t = f[1], k = "int", size = f[2], signed = f[3], asz = f[2] }
  end
  if r <= 13 then
    local signed = (r % 2 == 0)
    local sfx, n = size_suffix(4, bad)
    return { t = (signed and "i" or "I") .. sfx, k = "int", size = n, signed = signed, asz = n }
  end
  if r == 14 then return { t = "f", k = "flt", size = 4, asz = 4 } end
  if r == 15 then return { t = "d", k = "flt", size = 8, asz = 8 } end
  if r == 16 then return { t = "n", k = "flt", size = 8, asz = 8 } end
  if r <= 18 then
    local sfx, n = size_suffix(8, bad)
    return { t = "s" .. sfx, k = "s", size = n, asz = n }
  end
  if r == 19 then return { t = "z", k = "z", size = 0, asz = 0 } end
  if r == 20 then
    if bad and chance(5) then return { t = "c", k = "c", size = 0, asz = 0 } end
    local n = pick_csize()
    return { t = "c" .. D(n), k = "c", size = n, asz = 0 }
  end
  if r == 21 then return { t = "x", k = "x", size = 1, asz = 1 } end
  if r == 22 then return gen_X(bad) end
  return gen_cfg(bad)
end
local function gen_format(nmin, nmax, bad)
  local items = {}
  local n = nmin + rand(nmax - nmin + 1) - 1
  for _ = 1, n do items[#items + 1] = gen_item(bad) end
  if bad and chance(3) then items[#items + 1] = { t = "X", k = "X", size = 0, asz = 0 } end
  local parts = {}
  for _, it in ipairs(items) do
    parts[#parts + 1] = it.t
    if chance(8) then parts[#parts + 1] = " " end
  end
  return concat(parts), items
end
local function consumes(it) return it.k == "int" or it.k == "flt" or it.k == "s" or it.k == "z" or it.k == "c" end

-- ---------------------------------------------------------------- values
local function int_arg(it)
  local n, signed = it.size, it.signed
  if n < 1 then n = 1 elseif n > 16 then n = 16 end   -- bad sizes (i0, i255): the call fails anyway
  local r = rand(100)
  if r <= 70 then
    if signed then
      local bits = 8 * n - 1; if bits > 53 then bits = 53 end
      local v = randint_bits(rand(bits + 1) - 1)
      if chance(50) then v = -v end
      return v
    else
      local bits = 8 * n; if bits > 53 then bits = 53 end
      return randint_bits(rand(bits + 1) - 1)
    end
  elseif r <= 90 then
    if n > 16 then n = 16 end
    if signed then
      local lim = POW2[8 * n - 1]
      return pick{ lim - 1, -lim, lim, -lim - 1, lim / 2, -(lim / 2), 0.0, -1.0 }
    else
      local lim = POW2[8 * n]
      return pick{ lim - 1, lim, 0.0, -1.0, lim / 2, 1.0 }
    end
  elseif r <= 97 then
    return pick(INT_EDGES)
  end
  return pick(NONINT)
end
local function flt_arg()
  local r = rand(100)
  if r <= 50 then return randdouble() end
  if r <= 80 then return pick(FLT_EDGES) end
  if r <= 90 then return pick(INT_EDGES) end
  return pick(NONINT)
end
local function str_arg(it, long)
  if it.k == "z" then
    if chance(8) then
      local a, b = randstr(rand(6) - 1, true), randstr(rand(6) - 1, true)
      return a .. "\0" .. b
    end
    return randstr(rand(21) - 1, true)
  elseif it.k == "s" then
    local n = it.size
    if (n == 1 and chance(25)) or (n == 2 and chance(8)) then
      local lim = (n == 1) and 256 or 65536
      return bigstr(lim - 1 + rand(2) - 1)                       -- 2^(8n)-1 or 2^(8n)
    end
    if n == 3 and long and chance(3) then
      return bigstr(16777216 - 1 + rand(2) - 1)                  -- 2^24-1 or 2^24
    end
    return randstr(rand(21) - 1)
  else -- c
    local n = it.size
    if chance(10) then return randstr(n + 1) end
    return randstr(rand(n + 1) - 1)
  end
end
local function good_arg(it, long)
  if it.k == "int" then return int_arg(it) end
  if it.k == "flt" then return flt_arg() end
  return str_arg(it, long)
end
local function hostile_arg(it)
  if it.k == "int" or it.k == "flt" then
    local r = rand(10)
    if r <= 3 then return pick(INT_EDGES) end
    if r <= 5 then return pick(NONINT) end
    if r <= 6 then return pick(SAFE_STR) end
    if r <= 7 then return pick(COERCE_STR) end   -- D5: pack converts these by 5.3.6's rules
    if r <= 8 then return nonnum() end
    if r <= 9 then return randstr(rand(4) - 1) end
    return randdouble()
  end
  local r = rand(10)
  if r <= 5 then return randstr(rand(12) - 1) end
  if r <= 7 then return pick{ "", "\0", "a\0", "\0b", "abc\0def" } end
  if r <= 9 then return nonnum() end
  return randstr(rand(300))
end

-- ---------------------------------------------------------------- data
-- A mirror of the format walk (endianness, '!' maxalign, alignment) so that
-- unpack inputs are mostly well-formed; where the mirror is wrong the input
-- is merely misaligned, and both sides still get the SAME bytes.
local function bytes_le(v, n)        -- integral 0 <= v < 2^53 -> n bytes, little-endian
  local t = {}
  for i = 1, n do local b = v % 256; t[i] = b; v = (v - b) / 256 end
  return t
end
local function twos_le(v, n)         -- integral |v| < 2^53 -> n bytes two's complement
  if v >= 0 then return bytes_le(v, n) end
  local t = bytes_le(-v - 1, n)
  for i = 1, n do t[i] = 255 - t[i] end
  return t
end
local function order(t, little)      -- byte table (LE) -> string in the item's order
  if little then return char(tunpack(t)) end
  local r = {}
  for i = #t, 1, -1 do r[#r + 1] = t[i] end
  return char(tunpack(r))
end
local function hexbytes(h)           -- big-endian hex -> LE byte table
  local t = {}
  for i = #h - 1, 1, -2 do t[#t + 1] = tonumber(sub(h, i, i + 1), 16) end
  return t
end
local F4 = { "7f800000", "ff800000", "7fc00000", "7f800001", "ffc00001", "00000001", "80000000",
             "7f7fffff", "00800000", "007fffff", "3f800000", "7fbfffff" }
local F8 = { "7ff0000000000000", "fff0000000000000", "7ff8000000000000", "7ff0000000000001",
             "fffa000012345678", "ffffffffffffffff", "0000000000000001", "8000000000000000",
             "7fefffffffffffff", "0010000000000000", "000fffffffffffff", "3ff0000000000000",
             "fff8000000000001", "7ff4000000000000" }
local function int_bytes(n, signed)
  local r = rand(100)
  local t
  if r <= 30 then
    t = {}; for i = 1, n do t[i] = rand(256) - 1 end
  elseif r <= 40 then t = bytes_le(0, n)
  elseif r <= 50 then t = {}; for i = 1, n do t[i] = 255 end
  elseif r <= 58 then t = bytes_le(0, n); t[n] = 128                   -- most negative
  elseif r <= 66 then t = {}; for i = 1, n do t[i] = 255 end; t[n] = 127 -- most positive
  elseif r <= 82 then
    local v = pick{ TWO53 - 1, TWO53, -(TWO53 - 1), -TWO53, POW2[31], -POW2[31], POW2[32], 1.0,
                    -1.0, 127.0, 128.0, -128.0, -129.0, 255.0, 256.0, 32767.0, 65535.0 }
    t = twos_le(v, n)
  else
    -- around 2^53 and the 8-byte boundary: the decided rounding, and i9..i16
    t = {}; for i = 1, n do t[i] = 0 end
    local low = twos_le(pick{ TWO53 + 1, TWO53 + 3, POW2[62] + 1, POW2[63] - 1 - 1024 + 1,
                              -(TWO53 + 1) }, 8)
    -- TWO53 + 1 etc. are doubles: write the odd low bit explicitly
    for i = 1, 8 do if i <= n then t[i] = low[i] end end
    if n >= 7 then t[1] = (t[1] - t[1] % 2) + 1 end
    if n >= 8 and chance(30) then t[8] = rand(256) - 1 end
    if n > 8 then
      local hb = rand(4)
      for i = 9, n do
        if hb == 1 then t[i] = 0 elseif hb == 2 then t[i] = 255
        elseif hb == 3 then t[i] = (i == n) and 1 or 0 else t[i] = rand(256) - 1 end
      end
    end
  end
  return t
end
local function flt_bytes(n)
  if chance(40) then
    local t = {}; for i = 1, n do t[i] = rand(256) - 1 end
    return t
  end
  return hexbytes(n == 4 and pick(F4) or pick(F8))
end
-- s[n] length field: modes
--   "exact" the content's length; "off" +-1; "ff" all ones; "huge" 2^63..;
--   "wrap"  2^64 - (pos + n) + j: PUC's 5.3.6 check wraps (lstrlib.c:1518)
--   "rem"   the bytes remaining after the field, +-1 (filled in at the end)
local function sfield(n, mode, len, pos)
  if mode == "exact" or (mode == "wrap" and n < 8) then return bytes_le(len, n) end
  if mode == "off" then
    local v = len + (chance(50) and 1 or -1)
    if v < 0 then local t = {}; for i = 1, n do t[i] = 255 end; return t end
    if n < 7 and v >= POW2[8 * n] then v = POW2[8 * n] - 1 end
    return bytes_le(v, n)
  end
  if mode == "ff" then
    local t = {}; for i = 1, n do t[i] = (i <= 8) and 255 or 0 end
    if chance(30) then for i = 1, n do t[i] = 255 end end
    return t
  end
  if mode == "huge" then
    local t = bytes_le(0, n)
    if n >= 8 then t[8] = pick{ 128, 127, 1, 64 } else t[n] = pick{ 128, 127, 255 } end
    t[1] = rand(256) - 1
    return t
  end
  -- wrap, n >= 8: value 2^64 - k, k = pos + n - j, j in 0..3
  local j = rand(4) - 1
  local k = pos + n - j
  if k < 1 then k = 1 end
  local t = bytes_le(k - 1, 8)
  for i = 1, 8 do t[i] = 255 - t[i] end
  for i = 9, n do t[i] = 0 end
  return t
end
local function gen_data(items, force_s)
  local little, maxalign = true, 1
  local parts, pos = {}, 0
  local fixups = {}
  local function put(s) parts[#parts + 1] = s; pos = pos + #s end
  for _, it in ipairs(items) do
    if it.k == "cfg" then
      if it.t == "<" or it.t == "=" then little = true
      elseif it.t == ">" then little = false
      elseif sub(it.t, 1, 1) == "!" then maxalign = it.align end
    else
      local a = it.asz or 0
      if it.k ~= "c" and a > 1 then
        if a > maxalign then a = maxalign end
        if a == 2 or a == 4 or a == 8 or a == 16 then
          local nt = (a - pos % a) % a
          if nt > 0 then put(randstr(nt)) end
        end
      end
      if it.k == "int" and it.size >= 1 and it.size <= 16 then
        put(order(int_bytes(it.size, it.signed), little))
      elseif it.k == "flt" then
        put(order(flt_bytes(it.size), little))
      elseif it.k == "s" and it.size >= 1 and it.size <= 16 then
        local len = rand(21) - 1
        local mode
        if force_s then mode = pick{ "off", "ff", "huge", "wrap", "wrap", "rem", "rem", "exact" }
        else
          local r = rand(100)
          mode = (r <= 70) and "exact" or (r <= 80) and "off" or (r <= 85) and "ff"
                 or (r <= 90) and "huge" or (r <= 95) and "wrap" or "rem"
        end
        if mode == "rem" then
          parts[#parts + 1] = false
          fixups[#fixups + 1] = { idx = #parts, n = it.size, little = little, at = pos }
          pos = pos + it.size
        else
          put(order(sfield(it.size, mode, len, pos), little))
        end
        put(randstr(len))
      elseif it.k == "z" then
        put(randstr(rand(13) - 1, true))
        if not chance(15) then put("\0") end
      elseif it.k == "c" then
        put(randstr(it.size <= 4096 and it.size or 0))
      elseif it.k == "x" then
        put(randstr(1))
      end
    end
  end
  local total = pos
  for _, f in ipairs(fixups) do
    local v = total - (f.at + f.n) + (rand(3) - 2)
    local t
    if v < 0 then t = {}; for i = 1, f.n do t[i] = 255 end
    else
      if f.n < 7 and v >= POW2[8 * f.n] then v = POW2[8 * f.n] - 1 end
      t = bytes_le(v, f.n)
    end
    parts[f.idx] = order(t, f.little)
  end
  local data = concat(parts)
  local r = rand(100)
  if r <= 10 and #data > 0 then data = sub(data, 1, rand(#data) - 1)
  elseif r <= 15 then data = data .. randstr(rand(8)) end
  return data
end

-- ---------------------------------------------------------------- soup
local SOUP_OPT = "bBhHlLjJTiIfdnszcxX"
local SOUP_CFG = { "<", ">", "=", "!", " " }
local SOUP_NUM = { "0", "1", "2", "3", "4", "5", "7", "8", "9", "15", "16", "17", "99", "255", "256",
                   "65536", "214748363", "214748364", "2147483635", "2147483639", "2147483647",
                   "99999999999", "00000000001", "000" }
local function soup()
  local parts = {}
  for _ = 1, rand(10) do
    local r = rand(100)
    if r <= 45 then
      local k = rand(#SOUP_OPT); local c = sub(SOUP_OPT, k, k)
      parts[#parts + 1] = c
      -- a count right after the options that read one (getnum's digit cap)
      if (c == "c" or c == "i" or c == "I" or c == "s") and chance(50) then parts[#parts + 1] = pick(SOUP_NUM) end
    elseif r <= 65 then parts[#parts + 1] = pick(SOUP_NUM)
    elseif r <= 85 then parts[#parts + 1] = pick(SOUP_CFG)
    elseif r <= 95 then parts[#parts + 1] = char(rand(256) - 1)
    else local k = rand(#SOUP_OPT); parts[#parts + 1] = "X" .. sub(SOUP_OPT, k, k) end
  end
  return concat(parts)
end
-- bound pack's allocation: a 'c' count above 2^20 (as 5.3.6's getnum reads
-- it) becomes "c1000 " followed by the digits getnum would have left over
local function capc(f)
  return (f:gsub("c(%d+)", function(ds)
    local a, i = 0, 0
    repeat i = i + 1; a = a * 10 + (byte(ds, i) - 48) until i >= #ds or a > 214748363
    if a > 1048576 then return "c1000 " .. sub(ds, i + 1) end
    return nil
  end))
end

-- ---------------------------------------------------------------- running
local function sidefmt(f)
  if SIDE ~= "puc" then return f end
  return (f:gsub("([lL])(%d?)", function(c, d)
    local r = (c == "l") and "i8" or "I8"
    if d ~= "" then r = r .. " " .. d end
    return r
  end))
end

local out = assert(io.open(OUT, "wb"))
local sync = (SYNC == "sync")
local nlines = 0
local COVSET = "bBhHlLjJTiIfdnszcxX<>=! "
local cov, opstat = {}, { pack = { 0, 0 }, unpack = { 0, 0 }, packsize = { 0, 0 } }
for i = 1, #COVSET do cov[sub(COVSET, i, i)] = 0 end

local function emit(id, kind, op, desc, res)
  out:write(id, "|", kind, "|", op, "|", desc, "|", res, "\n")
  nlines = nlines + 1
  if sync or nlines % 64 == 0 then out:flush() end
end

local FN = { pack = PK, unpack = UN, packsize = PS }
-- run one operation; args is { n = ..., ... } AFTER the format
local function run(id, kind, op, f, args, desc)
  local fn = FN[op]
  local r = tpack(pcall(fn, sidefmt(f), tunpack(args, 1, args.n)))
  local res
  if not r[1] then
    res = "err " .. esc(normerr(r[2]))
    opstat[op][2] = opstat[op][2] + 1
  else
    local t = {}
    for i = 2, r.n do
      local v = r[i]
      local ty = type(v)
      if ty == "number" then t[#t + 1] = numtok(v)
      elseif ty == "string" then t[#t + 1] = strtok(v, 256)
      else t[#t + 1] = "<" .. ty .. ">" end
    end
    res = concat(t, " ")
    if #res > 16384 then res = "L" .. D(#res) .. "#" .. hash(res) end
    res = "ok " .. res
    opstat[op][1] = opstat[op][1] + 1
    for i = 1, #f do local c = sub(f, i, i); if cov[c] then cov[c] = cov[c] + 1 end end
  end
  emit(id, kind, op, desc, res)
  return r
end
local function fdesc(f) return "f=" .. esc(f) end
local function adesc(args)
  local t = {}
  for i = 1, args.n do t[#t + 1] = argtok(args[i]) end
  return " a=" .. D(args.n) .. ":" .. concat(t, ",")
end

local function do_pack(id, kind, f, args) return run(id, kind, "pack", f, args, fdesc(f) .. adesc(args)) end
local function do_size(id, kind, f) return run(id, kind, "packsize", f, { n = 0 }, fdesc(f)) end
local function do_unpack(id, kind, f, data, pos, haspos)
  local args = haspos and { n = 2, data, pos } or { n = 1, data }
  local desc = fdesc(f) .. " d=" .. argtok(data) .. (haspos and (" p=" .. argtok(pos)) or "")
  return run(id, kind, "unpack", f, args, desc)
end

-- ---------------------------------------------------------------- kinds
local LONG = (PROFILE == "long")

local function k_rt(id)
  local f, items = gen_format(1, 8, chance(10))
  local args = { n = 0 }
  for _, it in ipairs(items) do
    if consumes(it) then args.n = args.n + 1; args[args.n] = good_arg(it, LONG) end
  end
  local r = do_pack(id .. "p", "rt", f, args)
  if r[1] then
    run(id .. "u", "rt", "unpack", f, { n = 1, r[2] }, fdesc(f) .. " d=packed")
  else
    emit(id .. "u", "rt", "unpack", fdesc(f) .. " d=packed", "skip")
  end
  do_size(id .. "z", "rt", f)
end

local function k_un(id)
  local f, items = gen_format(1, 8, chance(15))
  do_unpack(id .. "u", "un", f, gen_data(items, false), nil, false)
end

local function k_slen(id)
  local items = {}
  for _ = 1, rand(3) - 1 do items[#items + 1] = gen_item(false) end
  local n = pick{ 1, 2, 3, 4, 7, 8, 8, 8, 9, 12, 16, 16 }
  local sfx = (n == 8 and chance(30)) and "" or D(n)
  items[#items + 1] = { t = "s" .. sfx, k = "s", size = n, asz = n }
  if chance(40) then items[#items + 1] = gen_item(false) end
  local parts = {}
  for _, it in ipairs(items) do parts[#parts + 1] = it.t end
  local f = pick{ "<", ">", "", "!" } .. concat(parts)
  if sub(f, 1, 1) == "<" or sub(f, 1, 1) == ">" or sub(f, 1, 1) == "!" then
    local cfg = { t = sub(f, 1, 1), k = "cfg", align = 8 }
    table.insert(items, 1, cfg)
  end
  do_unpack(id .. "u", "slen", f, gen_data(items, true), nil, false)
end

local function k_pos(id)
  local f, items = gen_format(1, 5, false)
  local data = gen_data(items, false)
  local ld = #data
  local pos = pick{ 1, 0, -1, 0 - ld, 0 - ld - 1, 0 - ld - 2, ld, ld + 1, ld + 2, 2, 3, floor(ld / 2),
                    POW2[31], -POW2[31], TWO53, -TWO53, POW2[63], -POW2[63], 1.5, "2", "x", NAN,
                    HUGE, -HUGE, NZERO, false, "nil" }
  if pos == "nil" then pos = nil end
  do_unpack(id .. "u", "pos", f, data, pos, true)
end

local function k_bad(id)
  local f, items = gen_format(1, 4, true)
  local args = { n = 0 }
  for _, it in ipairs(items) do
    if consumes(it) then args.n = args.n + 1; args[args.n] = hostile_arg(it) end
  end
  if args.n > 0 and chance(20) then args.n = rand(args.n) - 1 end
  if chance(10) then args.n = args.n + 1; args[args.n] = "extra" end
  do_pack(id .. "p", "bad", f, args)
end

local SOUP_ARGS = { "", "a", "10", "abc", "\0", "1.5", "0x10", "-1", "zz\0", "300" }
local function k_mal(id)
  local f = soup()
  local r = rand(3)
  if r == 1 then do_size(id .. "z", "mal", f)
  elseif r == 2 then
    f = capc(f)
    local args = { n = rand(4) - 1 }
    for i = 1, args.n do args[i] = pick(SOUP_ARGS) end
    do_pack(id .. "p", "mal", f, args)
  else
    do_unpack(id .. "u", "mal", f, randstr(rand(41) - 1), nil, false)
  end
end

local function k_big(id)
  local cap = LONG and 16777216 or 131072
  local r = rand(10)
  if r == 1 then
    local n = pick{ 1, 2 }
    local lim = (n == 1) and 256 or 65536
    do_pack(id .. "p", "big", "s" .. D(n), { n = 1, bigstr(lim - 2 + rand(3) - 1) })
  elseif r == 2 then
    local len = rand(cap)
    local s = bigstr(len, true)
    if chance(30) then s = sub(s, 1, len - 2) .. "\0" .. sub(s, len) end
    do_pack(id .. "p", "big", "z", { n = 1, s })
  elseif r == 3 then
    local n = rand(cap)
    do_pack(id .. "p", "big", "c" .. D(n), { n = 1, randstr(rand(20)) })
  elseif r == 4 then
    do_pack(id .. "p", "big", "<" .. rep("x", rand(5000)) .. "i4", { n = 1, 7 })
  elseif r == 5 then
    local len = rand(cap)
    local body = bigstr(len)
    local field = pick{ len, len + 1, len - 1, POW2[31] - 1, POW2[32] - 1, POW2[31] }
    do_unpack(id .. "u", "big", "<s4", order(bytes_le(field, 4), true) .. body, nil, false)
  elseif r == 6 then
    local len = rand(cap)
    local s = bigstr(len, true)
    if chance(60) then s = s .. "\0" .. randstr(3) end
    do_unpack(id .. "u", "big", "z", s, nil, false)
  elseif r == 7 then
    do_size(id .. "z", "big", rep("i16", rand(2000)))
  elseif r == 8 then
    do_size(id .. "z", "big", rep("c214748364", rand(12)))
  elseif r == 9 then
    local n = rand(cap)
    local d = bigstr(n + rand(3) - 2)
    do_unpack(id .. "u", "big", "c" .. D(n), d, nil, false)
  else
    local len = rand(cap)
    local s = bigstr(len)
    local rr = do_pack(id .. "p", "big", ">s4", { n = 1, s })
    if rr[1] then run(id .. "u", "big", "unpack", ">s4", { n = 1, rr[2] }, fdesc(">s4") .. " d=packed")
    else emit(id .. "u", "big", "unpack", fdesc(">s4") .. " d=packed", "skip") end
  end
end

-- coerce: conversions of arguments.  Numbers given to c/s/z are formatted by
-- the VM (LuaJIT's number formatting vs 5.3's "%.14g"+".0"), not pack's code:
-- the expected MISMATCH class (r == 3).  Strings given to numeric options
-- and positions are converted by pack's own 5.3.6 rules and must match; the
-- default mix draws them too (hostile_arg), where they are gated.
local COERCE_NUMS = { 10, 1.5, 1e15, TWO53, NZERO, 1e100, NAN, 100, 0.1, POW2[63], 1e14,
                      123456789012, -7, POW2[31] }
local function cnum(v)               -- PUC: integral |v| < 2^53 as an integer (as a literal would be)
  -- (not -0.0: an integer has no sign of zero, and the desc must stay the same on both sides)
  if HAS_INT and v == v and v == floor(v) and v > -TWO53 and v < TWO53 and not (v == 0 and 1 / v < 0) then
    return math.tointeger(v)
  end
  return v
end
local function k_coerce(id)
  local r = rand(4)
  if r <= 2 then
    local o = pick{ "<j", "<i4", "<I8", "<d", "<f", "<n", "<J", "<i16" }
    do_pack(id .. "p", "coerce", o, { n = 1, pick(COERCE_STR) })
  elseif r == 3 then
    local o = pick{ "z", "s1", "c20", "<s4" }
    do_pack(id .. "p", "coerce", o, { n = 1, cnum(pick(COERCE_NUMS)) })
  else
    do_unpack(id .. "u", "coerce", "<b", "abcdef", pick(COERCE_STR), true)
  end
end

-- limits: how many values one unpack may return (LuaJIT: LUAI_MAXCSTACK)
local MANY = { 7990, 7994, 7995, 7996, 7997, 7998, 7999, 8000, 8001, 10000, 65536 }
local function k_many(id)
  local n = pick(MANY)
  run(id .. "u", "many", "unpack", rep("b", n), { n = 1, rep("\1", n) }, "f=b*" .. D(n) .. " d=01*" .. D(n))
end

-- ---------------------------------------------------------------- edges
-- Fixed cases, run first on every seed: the spots a random walk can miss.
local EDGES = {}
local function E(op, f, ...) EDGES[#EDGES + 1] = { op = op, f = f, args = tpack(...) } end
local FF8 = rep("\255", 8)
-- format parsing
E("pack", "i0", 1); E("pack", "i17", 1); E("pack", "I99999999999", 1); E("pack", "c", "a")
E("packsize", "c99999999999"); E("packsize", "c2147483647"); E("packsize", "c2147483635")
E("packsize", "c2147483639"); E("packsize", "c214748364c214748364c214748364c214748364c214748364c214748364c214748364c214748364c214748364c214748364")
E("packsize", "!0"); E("packsize", "!17"); E("packsize", "!3"); E("packsize", "!3 i4")
E("packsize", "!3 h"); E("packsize", "!16 b Xi16"); E("packsize", "!2 b Xi8"); E("packsize", "! b j")
E("packsize", "s"); E("packsize", "z"); E("packsize", ""); E("packsize", "\0zzz"); E("packsize", "i4\0z")
E("packsize", "X"); E("packsize", "Xc1"); E("packsize", "Xz"); E("packsize", "X "); E("packsize", "XX")
E("packsize", "X!"); E("packsize", "X<"); E("packsize", "Xi17"); E("packsize", "bXi4"); E("packsize", "!bXi4")
E("packsize", "\1"); E("packsize", "\127"); E("packsize", "\128"); E("packsize", "\255"); E("packsize", "y")
E("packsize", "%"); E("packsize", "'"); E("packsize", "\\"); E("packsize", "l"); E("packsize", "L")
E("packsize", "l5"); E("packsize", "!l"); E("packsize", "Xl b"); E("packsize", "!4 b Xl")
-- pack: ranges
E("pack", "<j", POW2[63]); E("pack", "<j", -POW2[63]); E("pack", "<J", -1); E("pack", "<I8", -1)
E("pack", "<I16", -1); E("pack", "<i16", -1); E("pack", ">i9", -POW2[63]); E("pack", "<i9", POW2[62])
E("pack", "<i3", POW2[23]); E("pack", "<i3", -POW2[23]); E("pack", "<i3", -POW2[23] - 1)
E("pack", "<I3", POW2[24] - 1); E("pack", "<I3", POW2[24]); E("pack", "<I7", POW2[53])
E("pack", "<i7", -POW2[55]); E("pack", "<i7", -POW2[55] - 8); E("pack", "<I5", -1)
E("pack", "<I4", POW2[32] - 1); E("pack", "<I4", POW2[32]); E("pack", "<i4", POW2[31])
E("pack", "<b", 128); E("pack", "<b", -129); E("pack", "<B", 256); E("pack", "<B", -1)
E("pack", "<l", -1); E("pack", "<L", POW2[40]); E("pack", ">l", POW2[62]); E("pack", "<T", -1)
E("pack", "<i4", 1.5); E("pack", "<i4", NAN); E("pack", "<j", HUGE); E("pack", "<i4", "10")
E("pack", "<i4", "0x10"); E("pack", "<i4", "1e2"); E("pack", "<i4", "x"); E("pack", "<i4", "1.5")
E("pack", "<i4"); E("pack", "<i4", nil); E("pack", "<i4", true); E("pack", "<i4", {})
E("pack", "<d", "1.5"); E("pack", "<d", "x"); E("pack", "<i4", NZERO)
-- pack: floats
E("pack", "<d", NAN); E("pack", "<d", NNAN); E("pack", "<f", NAN); E("pack", "<f", 1e300)
E("pack", "<f", -1e300); E("pack", "<n", NZERO); E("pack", ">f", POW2[-149]); E("pack", "<f", POW2[-150])
E("pack", "<f", FLT_MAX + POW2[103]); E("pack", "<f", FLT_MAX + POW2[102]); E("pack", ">d", POW2[-1074])
E("pack", "=d", 0.1); E("pack", "<f", 1 + POW2[-24])
-- pack: strings
E("pack", "s0", "a"); E("pack", "s17", "a"); E("pack", "s1", rep("x", 255)); E("pack", "s1", rep("x", 256))
E("pack", "s2", rep("y", 65535)); E("pack", "s2", rep("y", 65536)); E("pack", "<s", "abc")
E("pack", "z", "a\0b"); E("pack", "z", ""); E("pack", "z", "\0"); E("pack", "z"); E("pack", "z", nil)
E("pack", "c0", ""); E("pack", "c0", "a"); E("pack", "c5", "ab"); E("pack", "c2", "abc")
E("pack", "c3", "a\0b"); E("pack", "s1", {}); E("pack", "s1", true)
-- pack: alignment / padding / options
E("pack", "<!4 b i4", 1, 2); E("pack", "<!8 b d", 1, 1.5); E("pack", "<!8 b Xi4 b", 1, 2)
E("pack", "<!8 Xc1", 1); E("pack", "<!8 X"); E("pack", "!3 i4", 1); E("pack", "!3 h", 1)
E("pack", "<!2 b Xi8 b", 1, 2); E("pack", "<!16 b Xi16 b", 1, 2); E("pack", "<! b Xs4 b", 1, 2)
E("pack", "!4 b Xx b", 1, 2); E("pack", "bxxb", 1, 2); E("pack", "< i2 > i2", 1, 1)
E("pack", "=i2", 1); E("pack", "y", 1); E("pack", ""); E("pack", "   "); E("pack", "i4\0zzz", 1)
E("pack", "<!4 z i4", "ab", 7); E("pack", "<!4 s1 i4", "ab", 7); E("pack", "<!8 c3 d", "ab", 1)
E("pack", "<i4", 1, 2, 3); E("pack", "<i4 i4", 1); E("pack", "<i4 x i4", 1, 2)
-- unpack: z and the 5.3.6 position rules
E("unpack", "z", "abc"); E("unpack", "z z", "abc"); E("unpack", "z ", "abc"); E("unpack", "z<", "abc")
E("unpack", "zb", "ab\0"); E("unpack", "z", ""); E("unpack", "z", "\0"); E("unpack", "zz", "\0\0")
E("unpack", "z", "abc", 3); E("unpack", "z", "abc", 4); E("unpack", "z", "abc", 5); E("unpack", "zXi4", "abc")
E("unpack", "!4 z Xi4", "abc"); E("unpack", "z x", "ab"); E("unpack", "z c0", "ab"); E("unpack", "z i0", "ab")
-- unpack: s[n] lengths (the 5.3.6 Kstring wrap at lstrlib.c:1518)
E("unpack", "<s8", FF8); E("unpack", "<s8", "\248" .. rep("\255", 7)); E("unpack", "<s8", "\249" .. rep("\255", 7) .. "abc")
E("unpack", "<s16", FF8 .. rep("\0", 8) .. "x"); E("unpack", ">s8", FF8); E("unpack", "<s4", "\255\255\255\127")
E("unpack", "<s1", "\5ab"); E("unpack", "<s1", "\2ab"); E("unpack", "<s1", "\3ab"); E("unpack", "<s9", FF8 .. "\1")
E("unpack", "<s8", rep("\0", 7) .. "\128"); E("unpack", "<s2", "\255\255")
E("unpack", "<b s8", "\1\247" .. rep("\255", 7)); E("unpack", "<!8 b s8", "\1" .. rep("\0", 7) .. "\240" .. rep("\255", 7))
-- unpack: integers
E("unpack", "<i9", "\251" .. rep("\255", 8)); E("unpack", "<i9", rep("\0", 8) .. "\1")
E("unpack", "<I9", rep("\255", 9)); E("unpack", "<I9", FF8 .. "\0"); E("unpack", "<i16", rep("\255", 16))
E("unpack", "<i16", rep("\255", 7) .. "\127" .. rep("\0", 8)); E("unpack", "<i16", rep("\0", 7) .. "\128" .. rep("\255", 8))
E("unpack", "<j", "\1\0\0\0\0\0\32\0"); E("unpack", "<j", "\255\255\255\255\255\255\255\127")
E("unpack", "<j", "\0\0\0\0\0\0\0\128"); E("unpack", "<J", "\254" .. rep("\255", 7)); E("unpack", "<J", FF8)
E("unpack", "<T", "\1\0\0\0\0\0\32\0"); E("unpack", ">j", "\0\32\0\0\0\0\0\1"); E("unpack", "<i8", "\3\0\0\0\0\0\32\0")
E("unpack", "<l", "\1\0\0\0\0\0\32\0"); E("unpack", "<L", FF8); E("unpack", ">l", "\128" .. rep("\0", 7))
E("unpack", "<i3", "\255\255\127"); E("unpack", "<i3", "\0\0\128"); E("unpack", "<I3", "\255\255\255")
E("unpack", "<i7", "\0\0\0\0\0\0\128"); E("unpack", "<I7", rep("\255", 7))
-- unpack: floats
E("unpack", "<d", "\0\0\0\0\0\0\248\127"); E("unpack", "<d", "\120\86\52\18\0\0\250\255"); E("unpack", "<f", "\1\0\128\127")
E("unpack", "<d", "\1\0\0\0\0\0\0\0"); E("unpack", ">d", "\128\0\0\0\0\0\0\0"); E("unpack", "<f", "\0\0\128\255")
E("unpack", "<n", "\255\255\255\255\255\255\239\127")
-- unpack: positions and arguments
E("unpack", "<i4", "abcdefgh", 3); E("unpack", "<c3", "abcdefgh", -3); E("unpack", "<b", "abc", 0)
E("unpack", "<b", "abc", -1000); E("unpack", "<b", "abc", 5); E("unpack", "<b", "abc", 4); E("unpack", "", "abc", 4)
E("unpack", "", "abc", 5); E("unpack", "", ""); E("unpack", "<b", "abc", 1.5); E("unpack", "<b", "abc", "2")
E("unpack", "<b", "abc", "x"); E("unpack", "<b", "abc", NAN); E("unpack", "<b", "abc", POW2[63])
E("unpack", "<b", "abc", -POW2[63]); E("unpack", "<b", "abc", -3); E("unpack", "<b", "abc", -4)
E("unpack", "<b", "abc", nil); E("unpack", "<b", "abc", false); E("unpack", "<i8", "abc"); E("unpack", "<b")
E("unpack", "<b", nil); E("unpack", "<b", {}); E("unpack", "c0", ""); E("unpack", "c1", ""); E("unpack", "c2147483647", "abc")
E("unpack", "!4 b Xi4 i4", "\1\0\0\0\2\0\0\0"); E("unpack", "!4 b Xi4 i4", "\1\0\0\0\2\0\0", 1)
E("unpack", "<!4 b i4", "\1\0\0\0\2\0\0\0", 2); E("unpack", "y", "a"); E("unpack", "\200", "a")

local function run_edges()
  for i, e in ipairs(EDGES) do
    local id = "e" .. D(i)
    if e.op == "pack" then do_pack(id, "edge", e.f, e.args)
    elseif e.op == "packsize" then do_size(id, "edge", e.f)
    else
      local a = e.args
      local desc = fdesc(e.f) .. " d=" .. (a.n >= 1 and argtok(a[1]) or "none")
      if a.n >= 2 then desc = desc .. " p=" .. argtok(a[2]) end
      run(id, "edge", "unpack", e.f, a, desc)
    end
  end
end

-- ---------------------------------------------------------------- main
local KINDS
if PROFILE == "coerce" then KINDS = { { k_coerce, 100 } }
elseif PROFILE == "limits" then KINDS = { { k_many, 100 } }
elseif PROFILE == "long" then
  KINDS = { { k_rt, 30 }, { k_un, 15 }, { k_bad, 10 }, { k_mal, 10 }, { k_pos, 5 }, { k_slen, 10 }, { k_big, 20 } }
else
  KINDS = { { k_rt, 34 }, { k_un, 18 }, { k_bad, 14 }, { k_mal, 13 }, { k_pos, 6 }, { k_slen, 13 }, { k_big, 2 } }
end
local WTOTAL = 0
for _, kw in ipairs(KINDS) do WTOTAL = WTOTAL + kw[2] end
local function pick_kind()
  local r = rand(WTOTAL)
  for _, kw in ipairs(KINDS) do
    if r <= kw[2] then return kw[1] end
    r = r - kw[2]
  end
end

out:write(fmt("#begin side=%s seed=%d n=%d profile=%s vm=%s\n", SIDE, SEED, NCASES, PROFILE, _VERSION))
local t0 = os.clock()
seed_rng(SEED)
if PROFILE == "default" or PROFILE == "long" then run_edges() end
local tedge = os.clock()
for i = 1, NCASES do
  pick_kind()(D(i))
end
local t1 = os.clock()
local cl = {}
for i = 1, #COVSET do
  local c = sub(COVSET, i, i)
  cl[#cl + 1] = (c == " " and "sp" or c) .. "=" .. D(cov[c])
end
out:write("#cov ok-option-chars " .. concat(cl, " ") .. "\n")
out:write(fmt("#ops pack=%d/%d unpack=%d/%d packsize=%d/%d (ok/err)\n",
  opstat.pack[1], opstat.pack[2], opstat.unpack[1], opstat.unpack[2], opstat.packsize[1], opstat.packsize[2]))
out:write(fmt("#end cases=%d edges=%d lines=%d secs=%.3f edgesecs=%.3f\n", NCASES, #EDGES, nlines, t1 - t0, tedge - t0))
out:close()
