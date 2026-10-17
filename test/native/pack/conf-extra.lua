-- test/native/pack/conf-extra.lua -- 411 edge cases beyond conformance.lua's
-- 308: argument conversion (5.3.6's luaL_checkinteger on strings), packsize's
-- check order, alignment, z and s at the end of the data, method syntax,
-- round trips.  Run by test/native/run-pack.sh exactly as conformance.lua is
-- (conf-extra.expect; deviations.txt).  Same line format.  Ids starting
-- "DEV1" (unpacked integers beyond 2^53 are rounded) and "DEV2" ('l'/'L' are
-- 8 bytes) are the two decided deviations.  "RESID" ids differ from 5.3.6
-- for other reasons, which deviations.txt names: the "RESID exp" and "RESID
-- frac" lines are pack's own (RESID-scan: its converter uses LuaJIT's numeral
-- scanner, decided D5/D7); the others are the VM's, not pack's (NaN payloads,
-- the C stack's 8000 slots, LuaJIT's number formatting, a tail call's lost
-- name).  Most of test/native/negctl-pack.sh's sabotages are caught by this
-- suite alone, but not all: DOUBLEBUF, which changes only what is charged to
-- the RAM cap, and D4OFFBY1, which changes only a result of exactly
-- LJ_MAX_STR bytes (this suite packs nothing that large), are caught by
-- pack_test.c instead (PT3, PT7); negctl-pack.sh's summary names the suite
-- that caught each arm.
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
    if #v > 64 then
      local h = 0
      for i = 1, #v do h = (h * 31 + v:byte(i)) % 2147483647 end
      return "s#" .. #v .. ":" .. h
    end
    return "s:" .. hex(v)
  end
  return tostring(v)
end

local function norm(e)
  e = tostring(e)
  e = e:gsub("^[^:]*:%d+: ", "")
  e = e:gsub("to '[^']*'", "to 'F'")
  e = e:gsub("calling '[^']*' on", "calling 'F' on")
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

-- as case(), but an error's message is printed raw, not norm()ed, so a
-- position prefix ("chunk:line: ") shows
local function rawcase(id, f, ...)
  local ok, e = pcall(f, ...)
  print(id .. " | " .. (ok and "OK " .. num(e) or "ERR " .. tostring(e)))
end

local named = setmetatable({}, {__name = "MyType"})
local badname = setmetatable({}, {__name = 42})

-- A. argument conversion: 5.3.6's luaL_checkinteger / checknumber / checklstring
for i, v in ipairs{"10", " 10 ", "+7", "-7", "0x10", "0X1f", " 0x10 ", "0x7FFFFFFFFFFFFFFF",
    "0x8000000000000000", "0xFFFFFFFFFFFFFFFF", "0x1FFFFFFFFFFFFFFFF", "9007199254740993",
    "-9223372036854775808", "9223372036854775807", "9223372036854775808",
    "-9223372036854775809", "1e2", "1.0", "1.5", "0x1p4", "0x1.8", "0x.8p1", ".5", "5.",
    "inf", "-inf", "nan", "infinity", "0b101", "0B1", "-0b1", "1e999", "0x", "", " ",
    "1 2", "10\0", "1e", "0x1p", "00000000000000000000000000001", "1E2", "1e-400", "-0", "0x-1"} do
  case("A j str " .. i, P, "<j", v)
  case("A d str " .. i, P, "<d", v)
end
case("A i4 str hexmax", P, "<i4", "0x7FFFFFFF")
case("A i4 str hexovf", P, "<i4", "0x80000000")
case("A I4 str neg", P, "<I4", "-1")
case("A j true", P, "<j", true)
case("A j table", P, "<j", {})
case("A j named", P, "<j", named)
case("A j badname", P, "<j", badname)
case("A d named", P, "<d", named)
case("A z named", P, "z", named)
case("A c1 named", P, "c1", named)
case("A s named", P, "s", named)
case("A fmt named", P, named)
case("A fmt nil", P, nil)
case("A fmt none", P)
case("A fmt number", P, 1)
case("A fmt number2", S, 4)
case("A z number", P, "z", 12)
case("A c3 number", P, "c3", 12)
case("A s1 number", P, "s1", -7)
case("A missing 2", P, "i4 i4", 1)
case("A missing z", P, "z")
case("A missing d", P, "d")
case("A missing after pad", P, "i4 x i4", 1)
case("A extra args", P, "i1", 1, 2, 3)
case("A nil arg", P, "i1", nil)
case("A fn arg", P, "i1", print)
case("A co arg", P, "i1", coroutine.create(function() end))
case("A u data none", U, "b")
case("A u data nil", U, "b", nil)
case("A u data num", U, "c2", 12)
case("A u data named", U, "b", named)
case("A u fmt none", U)
case("A u pos str", U, "b", "abc", "2")
case("A u pos strf", U, "b", "abc", "2.0")
case("A u pos strhex", U, "b", "abc", "0x2")
case("A u pos frac", U, "b", "abc", 1.5)
case("A u pos bad", U, "b", "abc", "x")
case("A u pos named", U, "b", "abc", named)
case("A u pos nan", U, "b", "abc", 0/0)
case("A u pos inf", U, "b", "abc", 1/0)
case("A u pos nil", U, "b", "abc", nil)
case("A u pos false", U, "b", "abc", false)
case("A ps none", S)
case("A ps named", S, named)

-- B. packsize: order of checks and limits
case("B c max", S, "c2147483639")
case("B c max+1", S, "c2147483640")
case("B c 2^31-1", S, "c2147483647")
case("B c big c8", S, "c2147483639c8")
case("B c big c9", S, "c2147483639c9")
case("B order s", S, "c2147483639c8s")
case("B order z", S, "c2147483639c8z")
case("B order s1", S, "c2147483639c8s1")
case("B s first", S, "s c2147483639c9")
case("B ok then s", S, "i4 s")
case("B leading zeros", S, "i0000000000000000004")
case("B many digits", S, "i999999999999")
case("B c digits", S, "c00000000000000000001")
case("B ! align", S, "!8 b d")
case("B ! align 16", S, "!16 b i16")
case("B ! align 16 j", S, "!16 b j")
case("B ! X", S, "!4 Xi8")
case("B ! b X", S, "!4 b Xi8")
case("B ! b X 2", S, "!2 b Xi8 b")
case("B ! b X d", S, "!8 b Xd")
case("B ! b Xx", S, "!8 b Xx")
case("B Xs", S, "!8 b Xs4")
case("B X end", S, "b X")
case("B X space", S, "b X ")
case("B X <", S, "b X<")
case("B X !", S, "b X!4")
case("B X X", S, "b XXi4")
case("B X c", S, "b Xc")
case("B X c1", S, "b Xc1")
case("B X z", S, "b Xz")
case("B X y", S, "b Xy")
case("B X i17", S, "b Xi17")
case("B !3 i3", S, "!3 i3")
case("B !3 i2", S, "!3 b i2")
case("B !5 i8", S, "!5 b i8")
case("B !8 i3", S, "!8 b i3")
case("B !8 i6", S, "!8 b i6")
case("B i3 default", S, "b i3")
case("B !0", S, "!0")
case("B !17", S, "!17")
case("B !", S, "! b j")
case("B i0", S, "i0")
case("B i16", S, "i16")
case("B s0", S, "s0")
case("B c", S, "c")
case("B c0", S, "c0")
case("B bad", S, "q")
case("B bad hi", S, "\200")
case("B embedded nul", S, "i4\0garbage")
case("B leading nul", S, "\0i4")
case("B empty", S, "")
case("B spaces", S, "   ")
case("B all fixed", S, "<>=! bBhHiIjJTfdnxi1I16c3")
case("B endian only", S, "<>=")

-- C. pack: formats, alignment, padding
case("C embedded nul", P, "i1\0i1", 1, 2)
case("C ! b i4 at 1", P, "<!4 b i4", 1, 2)
case("C ! X then", P, "<!4 b Xi4 b", 1, 2)
case("C ! s4 align", P, "<!4 b s4", 1, "ab")
case("C ! s align def", P, "<! b s", 1, "ab")
case("C ! z noalign", P, "<!8 b z b", 1, "ab", 2)
case("C ! c noalign", P, "<!8 b c3 i8", 1, "ab", 3)
case("C ! x", P, "<!8 x i8", 3)
case("C ! d", P, ">!8 b d", 1, 0.5)
case("C ! f", P, "<!4 b f", 1, 0.5)
case("C ! i16", P, "<!16 b i16", 1, -1)
case("C ! I16", P, "<!16 b I16", 1, -1)
case("C endian mix", P, "<i2>i2=i2", 0x102, 0x102, 0x102)
case("C i3", P, "<i3 >i3", -2, -2)
case("C I3 max", P, "<I3", 16777215)
case("C I3 ovf", P, "<I3", 16777216)
case("C i3 min", P, "<i3", -8388608)
case("C i3 min-1", P, "<i3", -8388609)
case("C i7 2^53", P, "<i7", 2^53)
case("C i7 -2^53", P, "<i7", -2^53)
case("C I7 2^53", P, "<I7", 2^53)
case("C i7 2^55", P, "<i7", 2^55)
case("C i7 -2^55", P, "<i7", -2^55)
case("C I7 2^56", P, "<I7", 2^56)
case("C i8 -2^63", P, "<i8", -2^63)
case("C i8 2^63", P, "<i8", 2^63)
case("C I8 2^63", P, "<I8", 2^63)
case("C I8 -1", P, "<I8", -1)
case("C J -2^63", P, "<J", -2^63)
case("C i9 -1", P, "<i9", -1)
case("C I9 -1", P, "<I9", -1)
case("C i9 big", P, ">i9", 2^62)
case("C i12 -2^63", P, "<i12", -2^63)
case("C I16 2^62", P, ">I16", 2^62)
case("C i16 -3", P, ">i16", -3)
case("C b -0", P, "b", -0.0)
case("C j nan", P, "j", 0/0)
case("C j -inf", P, "j", -1/0)
case("C B -1", P, "B", -1)
case("C B 255", P, "B", 255)
case("C B 256", P, "B", 256)
case("C b 127", P, "b", 127)
case("C b 128", P, "b", 128)
case("C b -128", P, "b", -128)
case("C b -129", P, "b", -129)
case("C h", P, "<h >H", -2, 65535)
case("C H ovf", P, "H", 65536)
case("C i 2^31", P, "i", 2^31)
case("C I 2^32-1", P, "<I", 2^32 - 1)
case("C T", P, "<T", 12345)
case("C T -1", P, "<T", -1)
case("C f max", P, "<f", 3.4028234663852886e38)
case("C f just over", P, "<f", 3.4028235677973366e38)
case("C f over", P, "<f", 3.402823669209385e38)
case("C f tiny", P, "<f", 1e-46)
case("C f denorm", P, "<f", 1e-40)
case("C f -0", P, "<f", -0.0)
case("C f nan", P, "<f", 0/0)
case("C f -nan", P, "<f", -(0/0))
case("C d nan", P, "<d", 0/0)
case("C d -nan", P, "<d", -(0/0))
case("C n", P, ">n", 1/3)
case("C d str", P, "<d", "1.5")
case("C c0 a", P, "c0", "a")
case("C c1 empty", P, "c1", "")
case("C c pad", P, "c5", "\0")
case("C z empty", P, "z", "")
case("C z zero end", P, "z", "abc\0")
case("C s1 255", function() return #P("s1", ("x"):rep(255)) end)
case("C s1 256", P, "s1", ("x"):rep(256))
case("C s2 65535", function() return #P("s2", ("x"):rep(65535)) end)
case("C s2 65536", P, "s2", ("x"):rep(65536))
case("C s3 65536", function() return #P("<s3", ("x"):rep(65536)) end)
case("C s16", P, "<s16", "ab")
case("C s9 big", P, ">s9", "ab")
case("C x only", P, "xxx")
case("C nothing", P, "")
case("C big c", P, "<i4 c100000 i4", 1, "abc", 2)
case("C big s", P, "<s4", ("y"):rep(70000))
case("C big z", P, "z", ("q"):rep(5000))
case("C many", P, ("b"):rep(200), table.unpack((function() local t = {} for i = 1, 200 do t[i] = i - 100 end return t end)()))
case("C bad opt mid", P, "i4 y", 1)
case("C bad opt before arg err", P, "i4 y", "x")
case("C arg err before bad opt", P, "y i4", "x")
case("C ovf before bad", P, "b i17", 1000)
case("C X before arg", P, "b X", 1)
case("C missing c", P, "c", "a")

-- D. unpack: bounds, positions, z and s
local d = P("<i2 i4 z s1 d c3", -2, 70000, "zz", "s", 2.5, "abc")
case("D all", U, "<i2 i4 z s1 d c3", d)
case("D pos len+1", U, "", "abc", 4)
case("D pos len+2", U, "", "abc", 5)
case("D pos -3", U, "b", "abc", -3)
case("D pos -4", U, "b", "abc", -4)
case("D pos 0", U, "", "abc", 0)
case("D pos 2^53", U, "b", "abc", 2^53)
case("D pos -2^63", U, "b", "abc", -2^63)
case("D pos 2^63", U, "b", "abc", 2^63)
case("D empty data", U, "", "")
case("D empty z", U, "z", "")
case("D z at end", U, "bz", "a")
case("D z mid", U, "z z", "ab\0cd\0")
case("D z unterminated then nop", U, "z ", "abc")
case("D z unterminated then <", U, "z<", "abc")
case("D z unterminated then x", U, "z x", "abc")
case("D z unterminated then X", U, "!4 z Xi4", "abc")
case("D z unterminated alone", U, "z", "abc")
case("D z nul only", U, "z", "\0")
case("D z then B", U, "zB", "a\0\1")
case("D z embedded", U, "z", "ab\0cd")
case("D s1", U, "<s1", "\3abc")
case("D s1 short", U, "<s1", "\4abc")
case("D s1 exact end", U, "<s1 b", "\3abc")
case("D s2 big", U, "<s2", "\255\255x")
case("D s4 be", U, ">s4", "\0\0\0\2ab")
case("D s9", U, "<s9", "\1" .. ("\0"):rep(8) .. "x")
case("D s9 nofit", U, "<s9", ("\0"):rep(8) .. "\1")
case("D s16 zero", U, "<s16", ("\0"):rep(16))
-- an s8 length so large that 5.3.6's "pos + len + size <= ld" wraps: 5.3.6
-- then dies in luaS_newlstr, "memory allocation error: block too big", and
-- so must we, without the wrap (oclj_strpack.c reads nothing)
case("D s8 wrap -8", U, "<s8", "\248\255\255\255\255\255\255\255" .. "abcdefgh")
case("D s8 wrap -1", U, "<s8", ("\255"):rep(8) .. "x")
-- the same, called NON-TAIL from a Lua function, and the message raw: 5.3.6
-- raises it through luaG_runerror, which adds a position only when the
-- running function is a Lua function (ldebug.c:653-663), and here it is
-- str_unpack, so 5.3.6's message has none; nor may ours (luaL_error would
-- add the caller's "conf-extra.lua:N: ", which norm() strips and this keeps)
rawcase("D s8 wrap nontail raw", function() local a = U("<s8", ("\255"):rep(8) .. "x"); return a end)
case("D s8 2^63", U, "<s8", ("\0"):rep(7) .. "\128")
case("D s8 2^62", U, "<s8", ("\0"):rep(7) .. "\64")
case("D s4 4GB", U, "<s4", "\255\255\255\255abc")
case("D s4 at pos", U, "<s4", "xx\1\0\0\0a", 3)
case("D align pos", U, "<!4 i4", "\0\1\2\3\4\0\0\0", 2)
case("D align X", U, "<!4 b Xi4 b", "\1\0\0\0\2")
case("D align short", U, "<!8 b d", "\1\0\0\0\0\0\0\0\0\0\0\0")
case("D x", U, "bxb", "\1\2\3")
case("D x short", U, "bxb", "\1\2")
case("D x at end", U, "bx", "\1")
case("D c0", U, "c0", "")
case("D c huge", U, "c2147483639", "abc")
case("D i16 -1", U, "<i16", ("\255"):rep(16))
case("D I16 wrapped", U, "<I16", ("\255"):rep(8) .. ("\0"):rep(8))
case("D I16 nofit", U, "<I16", ("\255"):rep(9) .. ("\0"):rep(7))
case("D i12 min", U, "<i12", "\0\0\0\0\0\0\0\128\255\255\255\255")
case("D i12 min bad", U, "<i12", "\0\0\0\0\0\0\0\128\0\0\0\0")
case("D i9 pos", U, ">i9", "\0\0\0\0\0\0\0\0\1")
case("D i9 neg", U, ">i9", "\255\255\255\255\255\255\255\255\254")
case("D I9 >", U, ">I9", "\1" .. ("\0"):rep(8))
case("D i3", U, "<i3 >i3", "\254\255\255\255\255\254")
case("D I3", U, "<I3", "\255\255\255")
case("D i5 min", U, "<i5", "\0\0\0\0\128")
case("DEV1 i7 max", U, "<i7", "\255\255\255\255\255\255\127")
case("DEV1 I7 max", U, "<I7", "\255\255\255\255\255\255\255")
case("D j 2^53-1", U, "<j", "\255\255\255\255\255\255\31\0")
case("D j -2^53", U, "<j", "\0\0\0\0\0\0\224\255")
case("D J 2^63", U, "<J", "\0\0\0\0\0\0\0\128")
case("D f", U, "<f >f", "\0\0\128\63\63\128\0\0")
case("D f nan", function() local x = U("<f", "\1\0\192\127"); return x ~= x end)
case("D f inf", U, "<f", "\0\0\128\127")
case("D f denorm", U, "<f", "\1\0\0\0")
case("D d -0", U, "<d", "\0\0\0\0\0\0\0\128")
case("D n", U, ">n", P(">n", 1/3))
case("D many", function() return select("#", U(("b"):rep(7000), ("\1"):rep(7000))) end)
case("D short at opt 2", U, "<i4 i4", "\1\0\0\0\2\0")
case("D bad opt after data", U, "b y", "\1")
case("D bad opt before short", U, "y i8", "")
case("D short before bad opt", U, "i8 y", "")

-- E. method syntax: arg 1 is self.  Each call is NOT a tail call: LuaJIT
-- keeps no caller name for a tail-called C function (see E-tail below).
local function m(f) return function() local a, b, c = f() return a, b, c end end
case("E method ok", m(function() local r = ("<i2"):pack(258) return r end))
case("E method bad self", function() local r = ("!3 i4"):pack(1) return r end)
case("E method bad self X", function() local r = ("b X"):pack(1) return r end)
case("E method arg", function() local r = ("<i2"):pack(70000) return r end)
case("E method luaL_error", function() local r = ("i17"):pack(1) return r end)
case("E method unpack", function() local a, b = ("<i2"):unpack("\2\1") return a, b end)
case("E method unpack short", function() local a = ("<i4"):unpack("\2\1") return a end)
case("E method unpack pos", function() local a = ("<b"):unpack("\2\1", 0) return a end)
case("E method packsize", function() local r = ("!3 i4"):packsize() return r end)
case("E method packsize var", function() local r = ("s"):packsize() return r end)
case("E global call", function() local r = string.pack("i17", 1) return r end)
case("E global argerr", function() local r = string.pack("i2", 1e6) return r end)
-- RESID-tail: the same errors through a tail call (VM-level naming)
case("RESID-tail method bad self", function() return ("!3 i4"):pack(1) end)
case("RESID-tail method arg", function() return ("<i2"):pack(70000) end)

-- F. round trips
for i, v in ipairs{0, 1, -1, 2^31, -2^31, 2^52, -2^52, 2^53, -2^53, 2^62, -2^63} do
  case("F rt j " .. i, function() return U("<j", P("<j", v)) end)
  case("F rt i9 " .. i, function() return U(">i9", P(">i9", v)) end)
  case("F rt d " .. i, function() return U("<d", P("<d", v)) end)
end

-- DEV (decided deviations): D1 rounding, D2 'l'/'L' 8 bytes
case("DEV1 2^53+1", U, "<j", "\1\0\0\0\0\0\32\0")
case("DEV1 2^53+3", U, "<j", "\3\0\0\0\0\0\32\0")
case("DEV1 maxint", U, "<j", "\255\255\255\255\255\255\255\127")
case("DEV1 J 2^64-2^10-1", U, "<J", "\255\251\255\255\255\255\255\255")
case("DEV1 minint+1", U, "<j", "\1\0\0\0\0\0\0\128")
case("DEV1 I16 2^63-1", U, "<I16", "\255\255\255\255\255\255\255\127" .. ("\0"):rep(8))
case("DEV1 s9-like", U, "<i9", "\255\255\255\255\255\255\255\127\0")
case("DEV2 l", P, "<l", -1)
case("DEV2 L", P, "<L", 1)
case("DEV2 l size", S, "l")
case("DEV2 !l", S, "!8 b l")
case("DEV2 l u", U, "<l", ("\255"):rep(8))
case("D s8 wrap abc", U, "<s8", ("\255"):rep(8) .. "abc")

-- RESID-scan (pack's own, decided D5/D7, expected to differ): pack's
-- converter uses LuaJIT's numeral scanner, which refuses an exponent of 2^20
-- or more (lj_strscan.c:468) and a numeral with 2^20 or more digits after the
-- radix point, leading zeros counted and trailing zeros not (:449-453);
-- 5.3.6's strtod reads the first as inf or 0 and the second as its value,
-- here 0 (milliseconds on PUC; not a fraction of 2^20 '1' digits, on which
-- 5.3.6's strtod takes over a minute)
case("RESID exp 2^20", P, "<d", "1e2000000")
case("RESID exp -2^20", P, "<j", "1e-2000000")
case("RESID frac 2^20", P, "j", "0." .. ("0"):rep(2^20) .. "1")
-- RESID (the VM, not pack: expected to differ)
case("RESID many results", function() return select("#", U(("b"):rep(9000), ("\1"):rep(9000))) end)
case("C numstr big", P, "z", 2^53)
case("RESID numstr float", P, "z", 1.0)
case("RESID nan payload", function() return P("<d", U("<d", "\1\0\0\0\0\0\248\127")) end)
