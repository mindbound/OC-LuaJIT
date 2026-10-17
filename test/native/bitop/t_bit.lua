-- test/native/bitop/t_bit.lua -- LuaJIT's own bit library (BitOp 1.0.3:
-- 32-bit, every operand taken by bit.tobit, shift counts mod 32) is untouched
-- by round 3 (U10, decided 2026-10-17): only the six bytecodes BC_BNOT..BC_BSAR
-- changed; the bit fast functions keep their own interpreter code (vm_x64.dasc
-- .ffunc_bit_*) and their own TOBIT recorder path (lj_ffrecord.c), which the
-- fold-engine changes (lj_opt_fold.c, round 3 D6) must not disturb.
-- test/native/run-bitop.sh part 1 runs it on the build's luajit.exe, JIT on
-- and -joff, and requires the output to equal t_bit.expect exactly: today's
-- output, measured on the build before round 3 (r3/synth/b0, luajit.exe md5
-- 2e737b868794) and unchanged on round 3's reference (r3/b/bB).  bit is not
-- in the sandbox (OC opens bit32, the shim's 5.2 library: bitop_test.c BT6).
--
-- One line per case: "<id> TAB <result>", each result computed once and in a
-- loop of 120 iterations (hot enough to compile): the result as %.17g, or
-- "SPLIT once=.. loop=.." if the two differ.  Operands stay within +-2^51,
-- where BitOp specifies its results (outside, it does not).
assert(type(bit) == "table", "t_bit.lua needs LuaJIT's bit library")
local V = { "0", "1", "-1", "5", "255", "0x7fffffff", "0x80000000", "0xffffffff", "2^32", "2^32+5",
  "-2^31", "-2^31-1", "2^40+3", "-2^40-7", "2^51-1", "-2^51", "1.5", "2.5", "-1.5" }
local SH = { "0", "1", "4", "31", "32", "33", "63", "64", "-1", "-31" }
local function val(s) return assert(load("return " .. s))() end

local out = {}
local function case(id, src, ...)
  local once = assert(load("local a, b = ... return " .. src))
  local loop = assert(load("local a, b = ... local r for i = 1, 120 do r = " .. src .. " end return r"))
  local function fmt(ok, r)
    if not ok then return "ERR:" .. (tostring(r):gsub("^[^:]*:%d+: ", "")) end
    if type(r) == "string" then return "s:" .. r end
    return string.format("%.17g", r)
  end
  local r1, r2 = fmt(pcall(once, ...)), fmt(pcall(loop, ...))
  out[#out + 1] = id .. "\t" .. (r1 == r2 and r1 or ("SPLIT once=" .. r1 .. " loop=" .. r2))
end

for _, a in ipairs(V) do
  case("tobit " .. a, "bit.tobit(a)", val(a))
  case("bnot " .. a, "bit.bnot(a)", val(a))
  case("bswap " .. a, "bit.bswap(a)", val(a))
  case("tohex " .. a, "bit.tohex(a)", val(a))
  for _, b in ipairs(V) do
    case("band " .. a .. " " .. b, "bit.band(a, b)", val(a), val(b))
    case("bor " .. a .. " " .. b, "bit.bor(a, b)", val(a), val(b))
    case("bxor " .. a .. " " .. b, "bit.bxor(a, b)", val(a), val(b))
  end
  for _, n in ipairs(SH) do
    for _, f in ipairs({ "lshift", "rshift", "arshift", "rol", "ror" }) do
      case(f .. " " .. a .. " " .. n, "bit." .. f .. "(a, b)", val(a), val(n))
    end
  end
end
io.write(table.concat(out, "\n"), "\n")
