-- test/native/bitop/coerce_agree.lua -- the two readers of Lua 5.3.6's
-- string-to-integer coercion in our LuaJIT must agree: string.pack's
-- (oclj_strpack.c pk_checkint, round 2 D5) and the bitwise operators'
-- (oclj_bitop_meta.c, round 3 U3).  Both are 5.3.6's luaO_str2num, then
-- tointeger (lobject.c:299-343, lvm.c:94-117).  Run by test/native/run-bitop.sh
-- part 1 on the build's luajit.exe, and in part 2 on PUC Lua 5.3.6, where
-- both readers are 5.3.6's own.  Prints each disagreement and a summary line
-- (r3/synth's coerce_agree.lua, 2026-10-17, with the comparison below).
--
-- Each string s is read by pack("<j", s), then unpacked as two unsigned
-- 32-bit halves, and by the operators as s & 0xFFFFFFFF and s >> 32.  Both
-- halves are below 2^32, so neither operator result can have more than 53
-- significant bits (U1-B, decided 2026-10-17: such a result raises): s | 0
-- would raise for "0x7fffffffffffffff" and "9007199254740993", whose readings
-- agree.  The halves are exact on both VMs, so the readings are compared
-- exactly, not as their nearest doubles.  They must accept the same strings
-- and give the same 64 bits.
local NUL = string.char(0)
local TAB, LF = string.char(9), string.char(10)
local S = { "0", "10", "-10", "+10", " 7 ", TAB .. "7" .. LF, "1e2", "1E2", "1.0", "1.5", "-0", "-0.0",
  "0x10", "0X10", "-0x10", "0x", "0x1p4", "0x1.8p1", "0xffffffffffffffff", "0x10000000000000000",
  "0x7fffffffffffffff", "0x8000000000000000", "9007199254740993", "9223372036854775807",
  "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "1e308", "1e309",
  "inf", "-inf", "nan", "0b101", "", " ", "abc", "1 2", "1" .. NUL, "0x1g", "1e", ".5", "5.",
  "0x.8p1", "  0xff  ", "1e+2", "1e-2", "100000000000000000000", "-0x1", "0x-1", "--1", "+-1" }
local halves = function(x) return x & 0xFFFFFFFF, x >> 32 end
local nd, n = 0, 0
for _, s in ipairs(S) do
  n = n + 1
  local okp, packed = pcall(string.pack, "<j", s)
  local plo, phi
  if okp then plo, phi = string.unpack("<I4I4", packed) end
  local okb, blo, bhi = pcall(halves, s)
  local agree = (okp == okb) and (not okp or (plo == blo and phi == bhi))
  if not agree then
    nd = nd + 1
    print(string.format("DISAGREE %q: pack %s %s | bitop %s %s", s,
      tostring(okp), okp and string.format("%.0f:%.0f", phi, plo) or tostring(packed),
      tostring(okb), okb and string.format("%.0f:%.0f", bhi, blo) or tostring(blo)))
  end
end
print(string.format("coerce-agree: %d strings, %d disagreements", n, nd))
