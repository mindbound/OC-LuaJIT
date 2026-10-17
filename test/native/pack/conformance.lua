-- test/native/pack/conformance.lua -- string.pack, string.unpack and
-- string.packsize, 308 cases (written 2026-10-13 for the first assessment).
-- test/native/run-pack.sh runs it on the build's luajit.exe and requires the
-- output to equal conformance.expect exactly; when PUC Lua 5.3.6 is built
-- (bench/vendor/lua-5.3.6), it also runs it there and requires the two to
-- differ in exactly the lines deviations.txt lists.  Every line is
-- "id | OK <hex/values>" or "id | ERR <normalised message>".
--
-- With a file argument (run-pack.sh part 2, on PUC Lua 5.3.6), each line of
-- the file is "<class>|<case id>", from deviations.txt, and the decided
-- deviation is applied to the case it names, so that 5.3.6's output must
-- equal the .expect line: DEV1, each integer result v is given as v + 0.0
-- (the nearest double of 5.3.6's exact value); DEV2, the case runs with
-- 'l'/'L' in its format rewritten to 'i8'/'I8'; RESID and RESID-scan, both,
-- so that run-pack.sh can require that neither explains the difference.
local P, U, S = string.pack, string.unpack, string.packsize
if not (P and U and S) then error("string.pack/unpack/packsize missing") end
local fmt = string.format

local function hex(s)
  return (s:gsub(".", function(c) return fmt("%02x", c:byte()) end))
end

local function num(v)
  if type(v) == "number" then
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    if v == 0 and 1 / v < 0 then return "-0" end
    if v == math.floor(v) and v >= -2^63 and v < 2^63 then return fmt("%d", v) end
    return fmt("%.17g", v)
  elseif type(v) == "string" then
    return "s:" .. hex(v)
  end
  return tostring(v)
end

local function norm(e)
  e = tostring(e)
  e = e:gsub("^[^:]*:%d+: ", "")
  e = e:gsub("to '[^']*'", "to 'F'")
  return e
end

-- the deviations to apply (see the header): id -> class
local dev = {}
if arg and arg[1] then
  for line in io.lines(arg[1]) do
    local c, id = line:match("^([^|]+)|(.+)$")
    if c then dev[id] = c end
  end
end

local function dev2(f, ...)  -- DEV2: 'l'/'L' in the format become 'i8'/'I8'
  local fs = ...
  if (f == P or f == U or f == S) and type(fs) == "string" then
    return (fs:gsub("[lL]", {l = "i8", L = "I8"})), select(2, ...)
  end
  return ...
end

local function case(id, f, ...)
  local c = dev[id]
  local resid = c ~= nil and c:sub(1, 5) == "RESID"
  local r
  if c == "DEV2" or resid then r = table.pack(pcall(f, dev2(f, ...)))
  else r = table.pack(pcall(f, ...)) end
  if not r[1] then
    print(id .. " | ERR " .. norm(r[2]))
  else
    local out = {}
    for i = 2, r.n do
      local v = r[i]
      if (c == "DEV1" or resid) and math.type and math.type(v) == "integer" then v = v + 0.0 end
      out[#out + 1] = num(v)
    end
    print(id .. " | OK " .. table.concat(out, " "))
  end
end

-- integers, every width and both orders
for _, e in ipairs{"<", ">"} do
  for sz = 1, 16 do
    case("i" .. sz .. e .. "+1", P, e .. "i" .. sz, 1)
    case("i" .. sz .. e .. "-1", P, e .. "i" .. sz, -1)
    case("I" .. sz .. e .. "max", P, e .. "I" .. sz, sz < 7 and (2 ^ (8 * sz) - 1) or 2 ^ 52)
    case("i" .. sz .. e .. "min", P, e .. "i" .. sz, sz < 7 and -(2 ^ (8 * sz - 1)) or -(2 ^ 52))
    case("i" .. sz .. e .. "ovf+", P, e .. "i" .. sz, sz < 7 and 2 ^ (8 * sz - 1) or 2 ^ 62)
    case("I" .. sz .. e .. "ovf-", P, e .. "I" .. sz, -1)
  end
end
for _, o in ipairs{"b", "B", "h", "H", "i", "I", "j", "J", "T"} do
  case("opt " .. o, P, "<" .. o, 100)
  case("size " .. o, S, o)
end
-- l/L: 8 bytes on every platform (D2); 5.3.6 uses sizeof(long), 4 on Win64
case("size l", S, "l"); case("size L", S, "L")
-- 5.3 integer conversion rules
case("nonint", P, "i4", 1.5)
case("strnum", P, "<i4", "10")
case("strhex", P, "<i4", "0x10")
case("strbad", P, "<i4", "x")
case("nan", P, "<j", 0 / 0)
case("inf", P, "<j", math.huge)
case("2^63", P, "<j", 2 ^ 63)
case("-2^63", P, "<j", -(2 ^ 63))
case("2^62", P, "<j", 2 ^ 62)
case("2^53+2", P, "<j", 2 ^ 53 + 2)
case("J -1", P, "<J", -1)
case("i16 -2", P, "<i16", -2)
-- floats
for _, v in ipairs{0, -0.0, 1.5, -2.25, 1 / 3, 1e300, 2 ^ -1074, math.huge, -math.huge} do
  case("f " .. num(v), P, "<f", v)
  case("d " .. num(v), P, ">d", v)
  case("n " .. num(v), P, "<n", v)
end
case("f nan rt", function() local x = U("<f", P("<f", 0 / 0)); return x ~= x end)
case("f round", U, "<f", P("<f", 0.1))
case("f ovf", U, "<f", P("<f", 1e300))
-- strings
case("z", P, "z", "hello")
case("z zero", P, "z", "a\0b")
case("s1", P, "s1", "hi")
case("s1 long", P, "s1", ("x"):rep(256))
case("s2 255", function() return #P("s2", ("x"):rep(255)) end)
case("s", P, "<s", "abc")
case("c5", P, "c5", "ab")
case("c2 long", P, "c2", "abc")
case("c miss", P, "c", "a")
case("c0", P, "c0", "")
-- alignment, padding, options
case("align !4", P, "<!4 b i4", 1, 2)
case("align !8 d", P, "<!8 b d", 1, 1.5)
case("align X", P, "<!8 b Xi4 b", 1, 2)
case("X bad", P, "<!8 Xc1", 1)
case("X end", P, "<!8 X")
case("!3", P, "!3 i4", 1)
case("! default", S, "! b j")
case("x", P, "bxxb", 1, 2)
case("spaces", P, "< i2 > i2", 1, 1)
case("= native", P, "=i2", 1)
case("bad opt", P, "y", 1)
case("i0", P, "i0", 1)
case("i17", P, "i17", 1)
case("packsize s", S, "s")
case("packsize z", S, "z")
case("packsize big", S, "c2147483647c2147483647")
case("missing arg", P, "i4")
-- unpack
local d = P("<i2 i4 z s1 d c3", -2, 70000, "zz", "s", 2.5, "abc")
case("u all", U, "<i2 i4 z s1 d c3", d)
case("u pos3", U, "<i4", d, 3)
case("u neg", U, "<c3", d, -3)
case("u pos0", U, "<b", d, 0)
case("u farneg", U, "<b", d, -1000)
case("u beyond", U, "<b", d, #d + 2)
case("u atend", U, "<b", d, #d + 1)
case("u atend none", U, "", d, #d + 1)
case("u short", U, "<i8", "abc")
case("u z unterminated", U, "z", "abc")
case("u z then c", U, "z c1", "abc")
case("u s too long", U, "<s1", "\5ab")
case("u s8 huge", U, "<s8", "\255\255\255\255\255\255\255\255")
case("u s4 big", U, "<s4", "\255\255\255\127")
case("u i9 fit", U, "<i9", P("<i9", -5))
case("u i9 nofit", U, "<i9", "\0\0\0\0\0\0\0\0\1")
case("u I9 nofit", U, "<I9", "\255\255\255\255\255\255\255\255\255")
case("u j small", U, "<j", P("<j", 123456789))
case("u J -1", U, "<J", ("\255"):rep(8))
case("u 2^53", U, "<j", P("<j", 2 ^ 53))
case("u 2^60", U, "<j", P("<j", 2 ^ 60))
-- 64-bit integers: 'u 2^53+1' and 'u maxint' need more than 53 bits and
-- diverge from 5.3.6 by design (D1, the nearest double); 'u minint' (-2^63)
-- and 'u J 2^64-2' (-2) are exact in a double and match
case("u 2^53+1", U, "<j", "\1\0\0\0\0\0\32\0")
case("u maxint", U, "<j", "\255\255\255\255\255\255\255\127")
case("u minint", U, "<j", "\0\0\0\0\0\0\0\128")
case("u J 2^64-2", U, "<J", "\254" .. ("\255"):rep(7))
case("u T", U, "<T", P("<T", 4096))
-- method syntax through the string metatable
case("method", function() return ("<i2"):pack(258) end)
