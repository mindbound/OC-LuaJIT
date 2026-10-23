-- test/native/bitop/t_csefwd.lua -- the CSE twins, forward order: values.
-- lj_opt_cse matched an instruction by its opcode and operands only (op12)
-- and returned the existing one with its own type; on x64
-- simplify_conv_sext hands our int64 operators (oclj_bitop_rec.c) the int
-- loop index or a string.byte value directly, so a 32-bit instruction on the
-- same operands, recorded first, served our operator: the 5.3 operator got
-- the 32-bit result, zero-extended (the CSE twins; JIT guide P63, 3.9; the
-- round's design, scratch claude-tmp/oclj/csetwin/design.md).  The fix,
-- patch-bitop-fold.sh hunk 12, refuses a match when exactly one of the two
-- instructions is IRT_I64.  test/native/run-bitjit.sh runs this file (part
-- cse) against -joff under 15 option sets, and bitop/cseir.lua reads the IR
-- of the same loops.  Written 2026-10-23.
--
--   luajit [options] t_csefwd.lua
--
-- FORWARD ORDER ONLY.  In every loop here the 32-bit producer (LuaJIT's bit
-- library, select beyond its varargs, a narrowed string.byte or string.sub
-- argument, an inner for loop's step) comes before our operator in program
-- order, so on a build without the fix our operator's request finds the
-- 32-bit instruction and gets its ref back; no int64 instruction with that
-- op12 is ever created, so no 32-bit recorder can be handed an int64 ref,
-- and loop_unroll re-emits the body in the pre-roll's order, so the same
-- holds in the loop copy (lj_opt_fold.c lj_opt_cse; lj_opt_loop.c
-- loop_unroll), also for a pair that forms only there (copy); a side trace
-- records its branch in program order and stops at its root's loop, so the
-- same holds there (side).  Value-only: this file reads and writes Lua
-- tables of numbers and strings, nothing through a pointer (FFI is off).
-- The reverse order (our operator first) is bitop/t_cserev.lua's, and only
-- in shapes that cannot put an int64 ref into a Lua slot (its header).
--
-- THE CASES, each its own loop prototype (load), called three times; one
-- pair per loop, the 32-bit producer first:
--   pairs whose served value is wrong (the defect's values):
--     lsh3    bit.lshift(i, 3), then i << 3, i from 2^29
--     bnot    bit.bnot(i), then ~i
--     bnotx   bit.bnot(i), then i ~ -1 (simplify_bxor_k makes it BNOT)
--     bxorm1  bit.bxor(i, -1) (an int BNOT, simplify_bxor_k), then ~i
--     lsh35   bit.lshift(i, 35) (its count masked to 3), then i << 3
--     u8sh30  b = string.byte(S, i), a u8 XLOAD: bit.lshift(b, 30), then
--             b << 30 (needs no narrowing: the XLOAD is the operand)
--     nested  bit.lshift(i, 8), then (i & 0x1FFFFFFFFFFFFF) << 8, i from
--             2^24: simplify_shiftk_andk's inner BSHL i, 8 is served
--     reassoc bit.lshift(i, 3), then (i << 2) << 1 (reassoc_shift)
--     chain   bit.bnot(i), then (~i) ~>> 40: a served value fed on
--     vlsh    in a loop over n = 32..63, b a byte: bit.lshift(b, n), then
--             b << n (a 32-bit shift masks its count to n & 31)
--     vrsh    the same with bit.rshift(b, n), then b >> n
--     copy    a pair that forms only in loop_unroll's copy: j carries
--             string.byte(S, i + 2) into the next iteration, and each
--             iteration does bit.lshift(j, 30), then string.byte(S, i + 1)
--             << 30; at record time their operands differ (j's TOBIT, an
--             XLOAD), and in the copy both are the pre-roll's one XLOAD
--             (the code verifier's body-v2, 2026-10-23)
--     side    a pair that forms only in a side trace: past i = 300, a
--             branch the root trace never recorded, b = string.byte(S, i),
--             then bit.lshift(b, 30) and b << 30 (the verifier's side-pair)
--   pairs whose served value is right (only the IR shows them; the in-game
--   families G1, G2 and G3 among them):
--     lsh1    bit.lshift(i, 1), then i << 1, i from 2^30 (both ADD i, i)
--     band    bit.band(i, b), then i & b, b a byte
--     rsh5    bit.rshift(i, 5), then i >> 5
--     select  select(j, ...) with j beyond the varargs (rec_varg's path
--             beyond them, BSHL j, 3), then j << 3 (G1)
--     byte2   string.byte(S, i + i), then i << 1 (narrow_stripov's
--             ADD i, i; G2)
--     sub2    string.sub(S, 2 * i, 2 * i), then i << 1 (2 * i is i + i of
--             doubles, narrowed by narrow_conv_emit to ADD i, i; G2)
--     forin   an inner for j = i, i + i - 1, i, which runs once, so the
--             loop's trace records its FORL, ADD i, i (rec_for_loop); then
--             i << 1 (G3, in this order only)
--   controls, run first (P59): each 5.3 operator alone (ctl-shl3, ctl-bnot,
--   ctl-shl1, ctl-shr5, ctl-band, ctl-vshl, and ctl-copy and ctl-side, the
--   copy and side shapes with plain arithmetic for the bit library's call,
--   x * 2^30 % 2^32, which leaves our operator alone); the bit library alone
--   (bit-lsh3); a same-type pair, which CSE merges on every build (same-bit,
--   same-53); and c1, our operator on the bit library's result,
--   bit.lshift(i, 3) | 0, whose operand stays a sign-extending CONV, so no
--   pair forms.
-- Every result is exact (at most 53 significant bits), so nothing raises.
--
-- THE REFERENCE.  Each 5.3 result is checked against a reference computed
-- with plain arithmetic, no bit operator and no bit library (shl, shr, band,
-- wrap32 below), and so is each bit library result where the case has one;
-- -joff must agree with it (this file exits 1 otherwise, under any VM), and
-- run-bitjit.sh compares each JIT option set's whole output with -joff's.
-- No PUC twin: the 32-bit halves are LuaJIT's bit library, which PUC 5.3.6
-- lacks, and the reference here checks the 5.3 halves under every VM.
--
-- MEASURED (2026-10-23; the round's test implementer, scratch
-- claude-tmp/oclj/csetwin/round/impl-tests/runs/, and its fixer,
-- round/fix/runs/ and fix/alma1/): on build/native at 1a13bed (luajit.exe
-- f4038cd6, no fix) the first list's first eleven cases differ from their
-- reference in each of the 10 option sets with fold, CSE and narrowing on
-- (lsh3 327-328 of its first call's 400 results, the first ~56 being
-- interpreted, and all 400 of each later call; vrsh 66 and 78 of 416,
-- since b >> (n & 31) is 0 too for most bytes), u8sh30 alone of them under
-- -O1 and -O-narrow, none under -O0, -O-fold and -O-cse; copy (336, 393
-- and 393 of 400) in the 9 of those 10 sets with the loop optimisation on,
-- and side (285, 295 and 295 of 600) wherever a trace compiles its branch,
-- which varies from run to run in a few sets: a side trace in every run
-- under the 7 of those 10 sets other than the two -Omaxside=0 ones and
-- -Ohotloop=1 -Ohotexit=1, and under -O1 and -O-narrow, and in 6 of 7 runs
-- under -Ohotloop=1 -Ohotexit=1;
-- under the two -Omaxside=0 sets, where a side trace is a stub, a trace
-- compiled it in 1 of 14 readings (-Ohotloop=1 -Omaxside=0, the fixer's
-- runs/cse-base-5, from the first call's 594th result on).  So 13 cases in
-- 6 sets in every run and in a 7th in 6 of 7, 12 under -O-loop and (but
-- that once) the two -Omaxside=0 sets, 2 under -O1 and -O-narrow; the
-- second list and the controls in none (the fixer's runs cse-base-1 to -6
-- on Windows and alma1 in AlmaLinux 8).  With the fix (round/fix/b1,
-- lj_opt_fold.o a6c5fcc2) every result equals its reference in all 15
-- sets, on Windows and in AlmaLinux 8.
--
-- Prints one line per case, "<case><TAB><call 1>;<call 2>;<call 3>", each
-- call "n=<results> bad=<5.3 results unlike the reference> bbad=<bit
-- library results unlike theirs> dig=<digest> bdig=<digest>[ x=<extra>]
-- [ first=<k>:<got>/<want>]".  On stderr, LuaJIT with the JIT on, one line:
--   #cov cases <n> traced <n> pairs <n> of <n> served <n> split <n> i64slot <n> jit <on|off>
-- traced: the cases in which a trace completed in the case's loop; pairs,
-- of the pair cases (the two lists above), those whose trace shows the pair
-- (our operator on the producer's own operand: served or split, read by
-- bitop/cseir.lua's reader); served, split and i64slot summed over every
-- case (cseir.lua's header defines them).  run-bitjit.sh requires, in the
-- default run, jit on, a trace in OCLJ_BITJIT_HOTMIN of the cases and pairs
-- at least 1.  Exit 0 every result equal to its reference, 1 one is not, 2
-- (INSTRUMENT) the case list is not what it says or the IR reader is
-- missing.  Loaded by cseir.lua as loadfile(...)("cases"), it returns its
-- case list and runs nothing.  This file holds no backslash: a newline is
-- NL, a tab TAB.
local NL, TAB, BS = string.char(10), string.char(9), string.char(92)
local fmt, floor = string.format, math.floor
local MODE = ...

-- THE REFERENCE: plain arithmetic on integral doubles, exact throughout.
local P2 = {}
for e = 0, 64 do P2[e] = 2 ^ e end
local function bits(x)  -- the set bits of an integer 0 <= x < 2^53, low first
  local r, p = {}, 0
  while x > 0 do
    if x % 2 == 1 then r[#r + 1] = p end
    x = floor(x / 2); p = p + 1
  end
  return r
end
-- x << k as 5.3.6 computes it (int64, wrapping), for 0 <= x < 2^31 and
-- 0 <= k <= 63: each set bit p moves to p + k, bit 63 is the sign, higher
-- bits drop; the terms are distinct powers of two within a 31-bit window.
local function shl(x, k)
  local r = 0
  for _, p in ipairs(bits(x)) do
    local q = p + k
    if q < 63 then r = r + P2[q] elseif q == 63 then r = r - P2[63] end
  end
  return r
end
local function shr(x, k) return floor(x / P2[k]) end  -- x >= 0; also x ~>> k for any x
local function band(x, y)  -- x, y >= 0
  local r, p = 0, 0
  while x > 0 and y > 0 do
    if x % 2 == 1 and y % 2 == 1 then r = r + P2[p] end
    x, y, p = floor(x / 2), floor(y / 2), p + 1
  end
  return r
end
local function wrap32(v)  -- the bit library's int32 of an integer v >= 0
  v = v % 4294967296
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end
-- A digest of n results, exact for any integral double (a string counts as
-- its first byte): power-of-two divisions, floor and % are exact here.
local function dig(t, n)
  local s = 0
  for k = 1, n do
    local v = t[k]
    if type(v) == "string" then v = v:byte() end
    local lo = v % 1048576
    local mid = floor(v / 1048576) % 1048576
    local hi = floor(v / 1099511627776) % 16777216
    s = (s + lo + 3 * mid + 7 * hi) % 4294967296
  end
  return s
end

-- THE INPUTS.  S6: 32 bytes for the n loops; S4: 400 for the byte cases;
-- S8: 800 for string.byte(S, i + i) and string.sub(S, 2 * i, 2 * i).
local function mkstr(n, a, b)
  local t = {}
  for j = 1, n do t[j] = string.char((j * a + b) % 256) end
  return table.concat(t)
end
local S6, S4, S8 = mkstr(32, 37, 11), mkstr(400, 97, 13), mkstr(800, 61, 7)
local N = 400
local A24, A29, A30 = 16777216, 536870912, 1073741824

-- The loops.  iloop: i from i0, N iterations; nloop: 13 times n = 32..63.
-- Each stores its 5.3 result in O[k] and the 32-bit producer's in BO[k].
local function iloop(i0, body)
  return "local O, BO, S = ..." .. NL .. "local k = 0" .. NL ..
    fmt("for i = %d, %d do", i0, i0 + N - 1) .. NL .. body .. NL .. "end" .. NL .. "return k"
end
local function nloop(body)
  return "local O, BO, S = ..." .. NL .. "local k = 0" .. NL .. "for rep = 1, 13 do" .. NL ..
    "  for n = 32, 63 do" .. NL .. "    local b = string.byte(S, n - 31)" .. NL .. body .. NL ..
    "  end" .. NL .. "end" .. NL .. "return k"
end
local function nb(k) local n = 32 + (k - 1) % 32; return S6:byte(n - 31), n end
-- body(a, c): the producer a first, then our operator c.
local function ac(a, c)
  return "  local a = " .. a .. "; local c = " .. c .. NL .. "  k = k + 1; BO[k] = a; O[k] = c"
end
local function c0(c) return "  local c = " .. c .. NL .. "  k = k + 1; O[k] = c" end
-- The copy shape: j carries string.byte(S, i + 2) into the next iteration,
-- so in the loop copy j and the copy's string.byte(S, i + 1) are the
-- pre-roll's one XLOAD; a is the producer, first.
local function cloop(a)
  return "local O, BO, S = ..." .. NL .. "local k = 0" .. NL .. "local j = string.byte(S, 2)" .. NL ..
    fmt("for i = 1, %d do", N) .. NL ..
    "  local a = " .. a .. "; local c = string.byte(S, i + 1) << 30" .. NL ..
    "  k = k + 1; BO[k] = a; O[k] = c" .. NL ..
    "  j = string.byte(S, i + 2)" .. NL .. "end" .. NL .. "return k"
end
-- The side shape: past i = 300, a branch the root trace never recorded, so
-- the pair is compiled only in the side trace from that exit.
local function sloop(a)
  return "local O, BO, S = ..." .. NL .. "local k = 0" .. NL .. "for i = 1, 600 do" .. NL ..
    "  if i > 300 then" .. NL ..
    "    local b = string.byte(S, i)" .. NL ..
    "    local a = " .. a .. "; local c = b << 30" .. NL ..
    "    k = k + 1; BO[k] = a; O[k] = c" .. NL ..
    "  else" .. NL ..
    "    k = k + 1; BO[k] = 0; O[k] = string.byte(S, i) * 1073741824" .. NL ..
    "  end" .. NL .. "end" .. NL .. "return k"
end

-- kind: ctl (our operator alone), bit (the bit library alone), same (a
-- same-type pair), c1, pair (wrong when served), eq (right when served).
-- narrow: the pair needs the loop index narrowed to int (an index operand,
-- or copy's string.byte addresses; not u8sh30's operands).
-- need: "loop", the pair forms only in loop_unroll's copy (judged where
-- the loop optimisation is on); "side", only in a side trace (judged where
-- a side trace compiled our operator: cseir.lua).
local CASES = {
  { name = "ctl-shl3", kind = "ctl", narrow = true, n = N, src = iloop(A29, c0("i << 3")),
    ref = function(k) return (A29 + k - 1) * 8 end },
  { name = "ctl-bnot", kind = "ctl", narrow = true, n = N, src = iloop(1, c0("~i")),
    ref = function(k) return -k - 1 end },
  { name = "ctl-shl1", kind = "ctl", narrow = true, n = N, src = iloop(A30, c0("i << 1")),
    ref = function(k) return (A30 + k - 1) * 2 end },
  { name = "ctl-shr5", kind = "ctl", narrow = true, n = N, src = iloop(A29, c0("i >> 5")),
    ref = function(k) return shr(A29 + k - 1, 5) end },
  { name = "ctl-band", kind = "ctl", narrow = true, n = N, S = S4,
    src = iloop(1, "  local b = string.byte(S, i)" .. NL .. c0("i & b")),
    ref = function(k) return band(k, S4:byte(k)) end },
  { name = "ctl-vshl", kind = "ctl", narrow = true, n = 416, S = S6, src = nloop(c0("b << n")),
    ref = function(k) local b, n = nb(k); return shl(b, n) end },
  { name = "ctl-copy", kind = "ctl", narrow = false, n = N, S = S8, src = cloop("j * 1073741824 % 4294967296"),
    ref = function(k) return S8:byte(k + 1) * P2[30] end,
    bref = function(k) return S8:byte(k + 1) * P2[30] % 4294967296 end },
  { name = "ctl-side", kind = "ctl", narrow = false, need = "side", n = 600, S = S8, src = sloop("b * 1073741824 % 4294967296"),
    ref = function(k) return S8:byte(k) * P2[30] end,
    bref = function(k) return k > 300 and S8:byte(k) * P2[30] % 4294967296 or 0 end },
  { name = "bit-lsh3", kind = "bit", narrow = true, n = N, src = iloop(A29, ac("bit.bnot(i)", "bit.lshift(i, 3)")),
    ref = function(k) return wrap32((A29 + k - 1) * 8) end,
    bref = function(k) return -(A29 + k - 1) - 1 end },
  { name = "same-bit", kind = "same", narrow = true, n = N, src = iloop(A29, ac("bit.lshift(i, 3)", "bit.lshift(i, 3)")),
    ref = function(k) return wrap32((A29 + k - 1) * 8) end,
    bref = function(k) return wrap32((A29 + k - 1) * 8) end },
  { name = "same-53", kind = "same", narrow = true, n = N, src = iloop(A29, ac("i << 3", "i << 3")),
    ref = function(k) return (A29 + k - 1) * 8 end,
    bref = function(k) return (A29 + k - 1) * 8 end },
  { name = "c1", kind = "c1", narrow = true, n = N, src = iloop(A29, ac("bit.lshift(i, 3)", "a | 0")),
    ref = function(k) return wrap32((A29 + k - 1) * 8) end,
    bref = function(k) return wrap32((A29 + k - 1) * 8) end },
  { name = "lsh1", kind = "eq", narrow = true, n = N, src = iloop(A30, ac("bit.lshift(i, 1)", "i << 1")),
    ref = function(k) return (A30 + k - 1) * 2 end,
    bref = function(k) return wrap32((A30 + k - 1) * 2) end },
  { name = "band", kind = "eq", narrow = true, n = N, S = S4,
    src = iloop(1, "  local b = string.byte(S, i)" .. NL .. ac("bit.band(i, b)", "i & b")),
    ref = function(k) return band(k, S4:byte(k)) end,
    bref = function(k) return band(k, S4:byte(k)) end },
  { name = "rsh5", kind = "eq", narrow = true, n = N, src = iloop(A29, ac("bit.rshift(i, 5)", "i >> 5")),
    ref = function(k) return shr(A29 + k - 1, 5) end,
    bref = function(k) return shr(A29 + k - 1, 5) end },
  { name = "byte2", kind = "eq", narrow = true, n = N, S = S8, src = iloop(1, ac("string.byte(S, i + i)", "i << 1")),
    ref = function(k) return 2 * k end,
    bref = function(k) return S8:byte(2 * k) end },
  { name = "sub2", kind = "eq", narrow = true, n = N, S = S8, src = iloop(1, ac("string.sub(S, 2 * i, 2 * i)", "i << 1")),
    ref = function(k) return 2 * k end,
    bref = function(k) return S8:byte(2 * k) end },
  { name = "lsh3", kind = "pair", narrow = true, n = N, src = iloop(A29, ac("bit.lshift(i, 3)", "i << 3")),
    ref = function(k) return (A29 + k - 1) * 8 end,
    bref = function(k) return wrap32((A29 + k - 1) * 8) end },
  { name = "bnot", kind = "pair", narrow = true, n = N, src = iloop(1, ac("bit.bnot(i)", "~i")),
    ref = function(k) return -k - 1 end, bref = function(k) return -k - 1 end },
  { name = "bnotx", kind = "pair", narrow = true, n = N, src = iloop(1, ac("bit.bnot(i)", "i ~ -1")),
    ref = function(k) return -k - 1 end, bref = function(k) return -k - 1 end },
  { name = "bxorm1", kind = "pair", narrow = true, n = N, src = iloop(1, ac("bit.bxor(i, -1)", "~i")),
    ref = function(k) return -k - 1 end, bref = function(k) return -k - 1 end },
  { name = "lsh35", kind = "pair", narrow = true, n = N, src = iloop(A29, ac("bit.lshift(i, 35)", "i << 3")),
    ref = function(k) return (A29 + k - 1) * 8 end,
    bref = function(k) return wrap32((A29 + k - 1) * 8) end },
  { name = "u8sh30", kind = "pair", narrow = false, n = N, S = S4,
    src = iloop(1, "  local b = string.byte(S, i)" .. NL .. ac("bit.lshift(b, 30)", "b << 30")),
    ref = function(k) return S4:byte(k) * P2[30] end,
    bref = function(k) return wrap32(S4:byte(k) * P2[30]) end },
  { name = "nested", kind = "pair", narrow = true, n = N, src = iloop(A24, ac("bit.lshift(i, 8)", "(i & 0x1FFFFFFFFFFFFF) << 8")),
    ref = function(k) return (A24 + k - 1) * 256 end,
    bref = function(k) return wrap32((A24 + k - 1) * 256) end },
  { name = "reassoc", kind = "pair", narrow = true, n = N, src = iloop(A29, ac("bit.lshift(i, 3)", "(i << 2) << 1")),
    ref = function(k) return (A29 + k - 1) * 8 end,
    bref = function(k) return wrap32((A29 + k - 1) * 8) end },
  { name = "chain", kind = "pair", narrow = true, n = N, src = iloop(1, ac("bit.bnot(i)", "(~i) ~>> 40")),
    ref = function(k) return shr(-k - 1, 40) end, bref = function(k) return -k - 1 end },
  { name = "vlsh", kind = "pair", narrow = true, n = 416, S = S6, src = nloop(ac("bit.lshift(b, n)", "b << n")),
    ref = function(k) local b, n = nb(k); return shl(b, n) end,
    bref = function(k) local b, n = nb(k); return wrap32(b * P2[n - 32]) end },
  { name = "vrsh", kind = "pair", narrow = true, n = 416, S = S6, src = nloop(ac("bit.rshift(b, n)", "b >> n")),
    ref = function(k) local b, n = nb(k); return shr(b, n) end,
    bref = function(k) local b, n = nb(k); return shr(b, n - 32) end },
  { name = "copy", kind = "pair", narrow = true, need = "loop", n = N, S = S8, src = cloop("bit.lshift(j, 30)"),
    ref = function(k) return S8:byte(k + 1) * P2[30] end,
    bref = function(k) return wrap32(S8:byte(k + 1) * P2[30]) end },
  { name = "side", kind = "pair", narrow = false, need = "side", n = 600, S = S8, src = sloop("bit.lshift(b, 30)"),
    ref = function(k) return S8:byte(k) * P2[30] end,
    bref = function(k) return k > 300 and wrap32(S8:byte(k) * P2[30]) or 0 end },
  { name = "select", kind = "eq", narrow = true, n = N, args = { 7, 8 },
    src = "local O, BO, S = ..." .. NL .. "local k, x = 0, 0" .. NL .. "for j = 6, 405 do" .. NL ..
      "  local v = select(j, ...); local c = j << 3" .. NL .. "  if v ~= nil then x = x + 1 end" .. NL ..
      "  k = k + 1; O[k] = c" .. NL .. "end" .. NL .. "return k, x",
    ref = function(k) return (k + 5) * 8 end },
  { name = "forin", kind = "eq", narrow = true, n = N,
    src = iloop(1, "  local m = 0" .. NL .. "  for j = i, i + i - 1, i do m = m + 1 end" .. NL ..
      "  local c = i << 1" .. NL .. "  k = k + 1; BO[k] = m; O[k] = c"),
    ref = function(k) return 2 * k end, bref = function(k) return 1 end },
}

-- The case list's own check: every pair's producer comes first in its text.
-- The copy and side shapes, whose pair forms only in the loop copy or in a
-- side trace, also hold their statements in this order, with one bit
-- library call and one shift: loop_unroll re-emits the pre-roll in order,
-- and a side trace records its branch in program order.
local function inorder(src, list)
  local at = 1
  for _, s in ipairs(list) do
    local p = src:find(s, at, true)
    if not p then return false end
    at = p + #s
  end
  return true
end
local function count(src, s)
  local n, at = 0, 1
  while true do
    local p = src:find(s, at, true)
    if not p then return n end
    n, at = n + 1, p + #s
  end
end
do
  local bad = {}
  for _, C in ipairs(CASES) do
    if C.kind == "pair" or C.kind == "eq" then
      local pa, pc = C.src:find("local a = ", 1, true), C.src:find("local c = ", 1, true)
      local ok = pa and pc and pa < pc
      if C.name == "select" then ok = C.src:find("select%(j, %.%.%.%); local c = j << 3") ~= nil end
      if C.name == "forin" then
        local pf, pl = C.src:find("for j = i, i + i - 1, i do", 1, true), C.src:find("local c = i << 1", 1, true)
        ok = pf and pl and pf < pl
      end
      if C.need == "loop" then
        ok = ok and inorder(C.src, { "local j = string.byte(S, 2)", "local a = bit.lshift(j, 30)",
          "local c = string.byte(S, i + 1) << 30", "j = string.byte(S, i + 2)" })
      elseif C.need == "side" then
        ok = ok and inorder(C.src, { "if i > 300 then", "local b = string.byte(S, i)", "local a = bit.lshift(b, 30)",
          "local c = b << 30", "else" })
      end
      if C.need then ok = ok and count(C.src, "bit.") == 1 and count(C.src, "<<") == 1 end
      if not ok then bad[#bad + 1] = C.name end
    end
  end
  if #bad > 0 then
    print("INSTRUMENT: t_csefwd's producer-first check fails for " .. table.concat(bad, ", "))
    os.exit(2)
  end
end

if MODE == "cases" then return { CASES = CASES, dig = dig } end

-- THE INSTRUMENT (LuaJIT with the JIT on): bitop/cseir.lua's reader.
local dir = (arg and arg[0] or ""):match("^(.*[/" .. BS .. "])") or ""
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local LIB
if hasjit then
  local chunk, lib = loadfile(dir .. "cseir.lua")
  local okl = false
  if chunk then okl, lib = pcall(chunk, "lib") end
  if not (okl and type(lib) == "table") then
    print("INSTRUMENT: no IR reader (bitop/cseir.lua as a library): " .. tostring(lib))
    os.exit(2)
  end
  LIB = lib
end
local unpack = unpack or table.unpack

-- One case: three calls, each compared with the reference.
local function runcase(C)
  local f = assert(load(C.src, "=csefwd-" .. C.name))
  local calls, bad = {}, 0
  if LIB then LIB.watch(f) end
  for call = 1, 3 do
    local O, BO = {}, {}
    for k = 1, C.n do O[k] = 0; BO[k] = 0 end  -- pre-sized: no growth exits
    local n, x = f(O, BO, C.S or S8, unpack(C.args or {}))
    if n ~= C.n then
      print(fmt("INSTRUMENT: case %s ran %s iterations, not %d", C.name, tostring(n), C.n))
      os.exit(2)
    end
    local cb, cbb, first = 0, 0, nil
    for k = 1, n do
      local want = C.ref(k)
      if O[k] ~= want then
        cb = cb + 1
        if not first then first = fmt("%d:%.17g/%.17g", k, O[k], want) end
      end
      if C.bref then
        local b = BO[k]
        if type(b) == "string" then b = b:byte() end
        if b ~= C.bref(k) then cbb = cbb + 1 end
      end
    end
    calls[call] = fmt("n=%d bad=%d bbad=%d dig=%.17g bdig=%.17g", n, cb, cbb, dig(O, n), dig(BO, n)) ..
      (x and fmt(" x=%.17g", x) or "") .. (first and (" first=" .. first) or "")
    bad = bad + cb + cbb
  end
  return C.name .. TAB .. table.concat(calls, ";"), bad, LIB and LIB.take()
end

local lines, nbad = {}, 0
local cov = { cases = 0, traced = 0, pairs = 0, pcases = 0, served = 0, split = 0, i64slot = 0 }
for _, C in ipairs(CASES) do
  local line, bad, c = runcase(C)
  lines[#lines + 1] = line
  nbad = nbad + bad
  cov.cases = cov.cases + 1
  if c then
    if c.traces > 0 then cov.traced = cov.traced + 1 end
    if C.kind == "pair" or C.kind == "eq" then
      cov.pcases = cov.pcases + 1
      if c.served + c.split > 0 then cov.pairs = cov.pairs + 1 end
    end
    cov.served, cov.split, cov.i64slot = cov.served + c.served, cov.split + c.split, cov.i64slot + c.i64slot
  end
end
io.write(table.concat(lines, NL), NL)
io.stderr:write(fmt("#cov cases %d traced %d pairs %d of %d served %d split %d i64slot %d jit %s",
  cov.cases, cov.traced, cov.pairs, cov.pcases, cov.served, cov.split, cov.i64slot, hasjit and "on" or "off") .. NL)
os.exit(nbad == 0 and 0 or 1)
