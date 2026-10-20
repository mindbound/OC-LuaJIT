-- test/native/bitop/gen.lua -- adversarial loop generator for the JIT's
-- recording of Lua 5.3's bitwise operators (round 3).  Written by the round-3
-- width-fold reviewer (r3/review/widthfold/gen, 2026-10-17) to break the fold
-- engine's width rule; its U1-B form (the PUC twin raises instead of
-- rounding: r3/b/gen/mkgen_b.py) by the main session; the operator named in
-- X and the iteration converter by role C2 of the round-3 implementation.
-- test/native/run-bitjit.sh drives it; bitop/drv.lua runs the cases.
--
--   luajit gen.lua <seed> <count> <outdir> [phi|idx|rg2]
--
-- Writes <outdir>/cases_lj.lua (our LuaJIT's text) and <outdir>/cases_puc.lua
-- (the same loops for PUC 5.3.6: every bit operator's result goes through
-- X(r, '<op>'), U1-B's rule -- the result's double if it equals it, else the
-- error "result of '<op>' has more than 53 significant bits (mask each
-- operand to 32 bits first)", X as drv.lua defines it; ~>> becomes
-- SAR(); loop indices are floats so all arithmetic is double arithmetic, as
-- on our VM).  "phi" makes half the statements carry a finitely-bounded value
-- across the loop's PHI.  "idx" (proto-folda, 2026-10-20, for the CRC32
-- follow-up's table-index fold) makes a third of the atoms index expressions
-- bounded at exactly 32 or 33 bits used as table keys, string.byte arguments
-- and shift counts, or slots used as keys, and a third of the statements set
-- a slot to such an index (below, at IDXMODE).  "rg2" (proto-rg2,
-- 2026-10-20) puts results at and past 2^53, where a result's guard decides
-- between a value and a raise (below, bigatom: a quarter of the atoms and
-- half the statements).  The modes exclude each other, and each one's draws
-- sit behind its own flag (MODE and rnd(n), so a mode that is off draws
-- nothing), so every mode's seeds generate what that mode's prototype
-- generated, and the default and phi modes what they generated before idx
-- and rg2 existed (checked byte for byte, 2026-10-20).
-- Each case is a chunk returning run(n, x0, y0, z0), the getter of the loop
-- variable's last value, and a converter from that value to the iteration
-- count; carried values live in slots (x, y, z, h), a table t, an upvalue u;
-- statements include branches (side traces), a flipped boolean (loop
-- unrolled on TYPEINS), inner loops (constant: unrolled; variable: own
-- trace), a helper call, int-typed results, string.byte (U8) values, and
-- double arithmetic on the same variables.  Shift counts and masks cluster
-- around the width rule's bound (w <= 54, lj_opt_fold.c oclj_bitwidth):
-- counts 9..12, 43..46, 52..54, masks 2^52..2^54; the boundary templates (BT)
-- sit at exactly 55 and 54.  The PRNG and every draw are the reviewer's, so a
-- seed generates the loops the reviewer and the main session measured.
local seed = tonumber(arg[1]) or 1
local COUNT = tonumber(arg[2]) or 1000
local OUT = arg[3] or "."
local st = (seed * 7919 + 12345) % 2147483646 + 1
local function rnd(n) st = (st * 48271) % 2147483647; return st % n + 1 end
local function pick(t) return t[rnd(#t)] end

-- Constant operands: identical text and value in both dialects (no hex >= 2^63,
-- no decimal literal above 2^53).
local KC = { "0", "1", "3", "7", "0xff", "0xffff", "0xffffffff", "0xfffffffff",
  "0xfffffffffffff", "0x1fffffffffffff", "2^52", "2^53", "(2^53 - 2)", "(2^54 - 2)",
  "(2^53 + 2)", "-4096", "-2^53", "-2^63", "2^62", "0x7ffffffffffffc00", "-1",
  "0x5555555555555", "0x1fffffffffff", "0x3ffffffffff" }
-- Masks that give the fold a finite bound (non-negative) and around 2^53.
local KM = { "0xff", "0xffff", "0xffffffff", "0xfffffffffffff", "0x1fffffffffffff",
  "2^52", "2^53", "(2^53 - 2)", "(2^54 - 2)", "0x3ffffffffff", "0x1fffffffffff",
  "0xfffffffffff", "0x7ffffffffff", "-4096", "-2^53", "0x7ffffffffffffc00" }
local KS = { "0", "1", "2", "9", "10", "11", "12", "20", "21", "31", "32", "33", "40",
  "43", "44", "45", "46", "52", "53", "54", "62", "63", "64", "65", "100",
  "(-1)", "(-10)", "(-11)", "(-54)", "(-64)", "(-65)" }
local VARS = { "x", "y", "z" }

-- Every builder returns two texts: lj, puc.
local function bin(op, a, b)
  if op == "~>>" then
    return "(" .. a[1] .. " ~>> " .. b[1] .. ")", "SAR(" .. a[2] .. ", " .. b[2] .. ")"
  end
  return "(" .. a[1] .. " " .. op .. " " .. b[1] .. ")",
         "X(" .. a[2] .. " " .. op .. " " .. b[2] .. ", '" .. op .. "')"
end
local function P(lj, puc) return { lj, puc or lj } end
local function B(op, a, b) local l, p = bin(op, a, b); return { l, p } end
local function U(a) return { "(~" .. a[1] .. ")", "X(~" .. a[2] .. ", '~')" } end
local function K(t) local s = pick(t); return P(s) end
local function KA(t) local s = pick(t); return P(s, "(" .. s .. " + 0.0)") end

-- "rg2" (proto-rg2, 2026-10-20, for the CRC32 follow-up's range guard, a
-- loop-body guard that a result lies in [-2^53, 2^53), which speculated: an
-- exact result outside it left the trace; prototyped, measured and not
-- shipped).  These atoms put results at and past 2^53, which every build's
-- result guards must handle as the interpreter does: exact values in bits
-- 53-63, exact values just outside [-2^53, 2^53), inexact ones just past it
-- (they raise), and values that cross it late, after the loop compiled.
-- They are drawn only in this mode, so the default and phi seeds generate
-- the loops they did.
local RG2MODE = arg[4] == "rg2"
local function bigatom()
  local r = rnd(12)
  local i7 = B("&", P("i"), P("7"))
  -- (i & 255) >> 6 is 0 below 64, then 1, 2, 3: past 2^53 late, after the
  -- loop compiled; a descending or negative index crosses the other way.
  local hi = B(">>", B("&", P("i"), P("255")), P("6"))
  if r == 1 then return B("<<", i7, K({ "53", "56", "60", "61" })) end   -- counters in bits 53-63
  if r == 2 then return B("<<", B("&", P("i"), P("1")), P("63")) end     -- 0 or -2^63
  if r == 3 then  -- flags 2^50 .. 2^57: 2^53 when i & 7 is 3
    return B("<<", P("1"), P("(50 + " .. i7[1] .. ")", "(50 + " .. i7[2] .. ")"))
  end
  if r == 4 then return B("<<", hi, P("52")) end  -- 2^52, then 2^53 and 3 * 2^52: exact, outside
  if r == 5 then return B("|", B("<<", hi, P("52")), K({ "1", "2", "3" })) end  -- 2^53 + 1 raises, 2^53 + 2 not
  if r == 6 then  -- -2^53 + 1 exact and inside; -3 * 2^52 + 1 raises
    return B("~", P("(" .. hi[1] .. " * -2^52)", "(" .. hi[2] .. " * -2^52)"), P("1"))
  end
  if r == 7 then  -- -2^53 (inside, the bound), -3 * 2^52 (exact, outside)
    return B("|", P("(" .. hi[1] .. " * -2^52)", "(" .. hi[2] .. " * -2^52)"), P("0"))
  end
  if r == 8 then  -- -2^63 ~>> k: -2^53 at k = 10, exact and outside below it
    return B("~>>", K({ "-2^63", "-2^62", "2^62" }), B("&", P("i"), P("15")))
  end
  if r == 9 then return B("&", P(pick(VARS)), K({ "-2^53", "-2^56", "-2^60" })) end  -- top-bit masks
  local i3 = B("&", P("i"), P("3"))
  if r == 10 then  -- 2^53 - 2, 2^53 - 1 (inside); 2^53 (exact, outside; 2^53 + 1 rounds to it)
    return B("|", P("(2^53 - 2 + " .. i3[1] .. ")", "(2^53 - 2 + " .. i3[2] .. ")"), P("0"))
  end
  if r == 11 then  -- -2^53 - 2 (exact, outside), -2^53, -2^53 + 2, -2^53 + 4
    return B("~", P("(-2^53 - 2 + " .. i3[1] .. " * 2)", "(-2^53 - 2 + " .. i3[2] .. " * 2)"), P("0"))
  end
  return B("<<", P("i"), K({ "44", "45", "46" }))  -- past 2^53 from i = 512, 256, 128
end

local INNERJ = false  -- inside an inner loop, j is an atom
local function atom0()
  if RG2MODE and rnd(4) == 1 then return bigatom() end
  local r = rnd(INNERJ and 17 or 16)
  if r <= 5 then return P(pick(VARS)) end
  if r == 6 then return P("i") end
  if r == 7 then return P(pick({ "(i + 7)", "(i * 4096)", "(i * 2^40)", "(2^53 + i)",
    "(i * 2^45 - i)", "(x + i)", "(y - i)", "(2^52 + i * 3)" })) end
  if r == 8 then return KA(KC) end
  if r == 9 then  -- table load, index from a bit operator
    local ix = B("&", P("(i + " .. rnd(8) .. ")"), P("7"))
    return P("t[" .. ix[1] .. " + 1]", "t[" .. ix[2] .. " + 1]")
  end
  if r == 10 then return P("u") end
  if r == 11 then  -- string.byte: an IRT_U8 value in LuaJIT
    local ix = B("&", P("i"), P("15"))
    return P("s:byte(" .. ix[1] .. " + 1)", "(s:byte(" .. ix[2] .. " + 1) + 0.0)")
  end
  if r == 12 then return P("t[1]") end
  if r == 13 then return KA(KM) end
  if r >= 14 and r <= 16 then return P(pick(VARS)) end
  return P("j")
end

-- "idx" mode (OCLJ_BITJIT_GENMODE=idx; the CRC32 follow-up's table-index
-- fold, patch-bitop-fold.sh hunk 11, which folds CONV int.num (CONV num.i64
-- y) to CONV int.i64 y when oclj_bitwidth(y) <= 32): index expressions whose
-- bound is exactly 32 (fold) or 33 (no fold: a fold would keep only y's low
-- 32 bits), used where LuaJIT converts a number to an int32 -- a table key
-- (tk, which holds keys at and past +-2^31 and +-2^32), string.byte's
-- argument and a variable shift count -- and a slot read as a table key, so
-- that an index set by an idx statement crosses the loop's PHI.  Every draw
-- of this mode is behind IDXMODE, so the other modes' seeds generate what
-- they generated before (gen.lua's header).
local IDXMODE = arg[4] == "idx"
local IDXE = {
  function(a) return B("~>>", a, P("32")) end,                       -- 32
  function(a) return B("&", a, P("0x7fffffff")) end,                 -- 32
  function(a) return B("<<", B("&", a, P("0xffff")), P("15")) end,   -- 32
  function(a) return B(">>", a, P("33")) end,                        -- 32
  function(a) return U(B("&", a, P("0x7fffffff"))) end,              -- 32
  function(a) return B("~>>", a, P("31")) end,                       -- 33
  function(a) return B("&", a, P("0xffffffff")) end,                 -- 33
  function(a) return B("<<", B("&", a, P("0xffff")), P("16")) end,   -- 33
  function(a) return B(">>", a, P("32")) end,                        -- 33
  function(a) return U(B("&", a, P("0xffffffff"))) end,              -- 33
  function(a) return U(B("~>>", a, P("31"))) end,                    -- 33
}
local function idxatom()
  local r = rnd(7)
  if r == 7 then  -- a slot as a key: set by an idx statement, across the PHI
    local v = pick(VARS)
    return P("(tk[" .. v .. "] or 0)", "(tk[" .. v .. "] or 0.0)")
  end
  local e = IDXE[rnd(#IDXE)](atom0())
  if r <= 2 then return P("(tk[" .. e[1] .. "] or 0)", "(tk[" .. e[2] .. "] or 0.0)") end
  if r == 3 then return P("(s:byte(" .. e[1] .. ") or 0)", "((s:byte(" .. e[2] .. ") or 0) + 0.0)") end
  if r == 4 then return B("<<", P("3"), e) end
  if r == 5 then return B(">>", P("0x7fffffff"), e) end
  return B("~>>", P("-0x40000000"), e)
end
local function atom()
  if IDXMODE and rnd(3) == 1 then return idxatom() end
  return atom0()
end

-- Boundary shapes: each one's correct bound is exactly 55 (no fold), and an
-- off-by-one in a single oclj_bitwidth rule makes it 54 (fold).  OR/XOR with
-- low bits afterwards makes a wrongly kept 54-bit value visible.
local BT = {
  function(a) return B(">>", a, P("10")) end,
  function(a) return B("<<", B(">>", a, P("11")), P("1")) end,
  function(a) return B("<<", B(">>", a, P("12")), P("2")) end,
  function(a) return B("<<", B(">>", a, P("30")), P("20")) end,
  function(a) return B("<<", B("&", a, P("0xffff")), P("38")) end,
  function(a) return B("<<", B("&", a, P("0xff")), P("46")) end,
  function(a) return B("<<", B("&", a, P("0xffffffff")), P("22")) end,
  function(a) return B("<<", B("&", a, P("0xfffffffffffff")), P("2")) end,
  function(a) return B("<<", B("&", a, P("0x1fffffffffffff")), P("1")) end,
  function(a) return B("~>>", a, P("9")) end,
  function(a) return B("<<", B("~>>", a, P("10")), P("1")) end,
  function(a) return U(B(">>", a, P("10"))) end,
  function(a) return B("<<", B("&", a, P("0x7fff")), P("39")) end,
  function(a) return B("<<", B("<<", B("&", a, P("0xff")), P("40")), P("6")) end,
  function(a) return B("~>>", B("<<", B("&", a, P("0xffff")), P("40")), P("2")) end,
  function(a) return B("|", B(">>", a, P("10")), B("&", a, P("0xff"))) end,
  -- BSHL by a count >= 32 on a non-BAND operand (a BAND operand is rewritten
  -- by simplify_shiftk_andk into (x << k) & (m << k) and never reaches the
  -- BSHL rule)
  function(a) return B("<<", B(">>", a, P("42")), P("32")) end,
  function(a) return B("<<", B("~>>", a, P("50")), P("41")) end,
  function(a) return B("<<", B("|", B(">>", a, P("47")), P("3")), P("37")) end,
  function(a) return B("<<", B("~", B(">>", a, P("40")), P("1")), P("30")) end,
  -- negative masks: no finite bound from the mask
  function(a) return B("&", a, P("-2^53")) end,
  function(a) return B("&", a, P("-4096")) end,
  -- exactly 54: these fold; values stay below 2^53
  function(a) return B(">>", a, P("11")) end,
  function(a) return B("~>>", a, P("10")) end,
  function(a) return B("<<", B("&", a, P("0xffff")), P("37")) end,
  function(a) return B("<<", B(">>", a, P("12")), P("1")) end,
}
local LOWB = { "1", "i", "3", "0x5555" }

local function expr(d)
  if d <= 0 then return atom() end
  local r = rnd(19)
  if r >= 17 then
    local a = expr(d - 1)
    local sh = BT[rnd(#BT)](a)
    local lb = rnd(3) == 1 and B("&", expr(d - 2), P("0xffff")) or P(pick(LOWB))
    return B(pick({ "|", "~" }), sh, lb)
  end
  local a = expr(d - 1)
  if r == 1 then return B(">>", a, K(KS)) end
  if r == 2 then return B("<<", a, K(KS)) end
  if r == 3 then return B("&", a, K(KM)) end
  if r == 4 then return U(a) end
  if r == 5 then return B("~>>", a, K(KS)) end
  if r == 6 then  -- shift then OR/XOR low bits: makes a wrong bound visible
    local sh = B(pick({ "<<", ">>", "~>>" }), a, K(KS))
    return B(pick({ "|", "~" }), sh, expr(d - 2))
  end
  if r == 7 then  -- rotate-like
    local k1, k2 = K(KS), K(KS)
    return B("|", B(">>", a, k1), B("<<", a, k2))
  end
  if r == 8 then  -- variable count, masked
    return B(pick({ "<<", ">>", "~>>" }), a, B("&", expr(d - 2), P("63")))
  end
  if r == 9 then  -- variable count, possibly negative or >= 64
    local c = B("&", expr(d - 2), P("127"))
    return B(pick({ "<<", ">>", "~>>" }), a, P("(" .. c[1] .. " - 32)", "(" .. c[2] .. " - 32)"))
  end
  if r == 10 then return B(">>", B("&", a, K(KM)), K(KS)) end
  if r == 11 then return B("<<", B("&", a, K(KM)), K(KS)) end
  local b = expr(d - 1)
  if r == 12 or r == 13 then return B("~", a, b) end
  if r == 14 then return B("|", a, b) end
  if r == 15 then return B("&", a, b) end
  return B(pick({ "<<", ">>" }), a, B("&", b, P("63")))
end

local function E() return expr(rnd(4)) end

-- Statements: return lj, puc lines.
local stmt
local function assign(v, e) return { v .. " = " .. e[1], v .. " = " .. e[2] } end
local PHIMODE = arg[4] == "phi"
-- Top-level operators whose bound is finite, so the carried value crosses the
-- PHI as an int64 when the next iteration feeds it to a bit operator.
local KMF = { "0xff", "0xffff", "0xffffffff", "0xfffffffffffff", "0x1fffffffffffff",
  "2^52", "0x3ffffffffff", "0x1fffffffffff", "0x7ffffffffff", "(2^53 - 2)", "(2^54 - 2)", "2^53" }
local KSF = { "10", "11", "12", "13", "20", "31", "32", "40", "52", "53", "63" }
local function finite(e)
  local r = rnd(6)
  if r == 1 then return B("&", e, K(KMF)) end
  if r == 2 then return B(">>", e, K(KSF)) end
  if r == 3 then return B("~>>", e, K(KSF)) end
  if r == 4 then return U(B("&", e, K(KMF))) end
  if r == 5 then return B(pick({ "|", "~" }), B(">>", e, K(KSF)), B("&", expr(1), K(KMF))) end
  return B("<<", B("&", e, K(KMF)), K({ "1", "2", "8", "20", "37", "38" }))
end
-- rg2 mode: a statement whose result sits at or past 2^53.
local function rg2stmt(v)
  local r = rnd(6)
  local b = bigatom()
  if r == 1 then return assign(v, b) end
  if r == 2 then return assign(v, B("~", B("&", P(v), P("-2^50")), b)) end  -- carried, high bits only
  if r == 3 then return assign(v, B(pick({ ">>", "~>>" }), b, K({ "0", "1", "3", "9", "10", "11" }))) end
  if r == 4 then return assign(v, B("|", b, B("&", E(), P("0xff")))) end  -- low bits joined: raises past 2^53
  if r == 5 then return assign(v, B("~", P(v), b)) end  -- carried as it is
  return assign(v, B(pick({ "&", "|", "~" }), b, bigatom()))
end
stmt = function(depth)
  local r = rnd(20)
  local v = pick(VARS)
  if PHIMODE and rnd(2) == 1 then return assign(v, finite(E())) end
  if RG2MODE and rnd(2) == 1 then return rg2stmt(v) end
  -- idx: a slot set to an index-shaped value, read as a key next iteration
  if IDXMODE and rnd(3) == 1 then return assign(v, IDXE[rnd(#IDXE)](E())) end
  if r <= 7 then return assign(v, E()) end
  if r == 8 then  -- double arithmetic on a bit result
    local e = E()
    local tail = pick({ " + i * 2^40", " + i", " - y", " * 3", " + 2^53", " * 0.5", " - i * 2^45" })
    return { v .. " = " .. e[1] .. tail, v .. " = " .. e[2] .. tail }
  end
  if r == 9 then  -- branch: side exit, side trace
    local c = B("&", P("i"), P(tostring(pick({ 1, 3, 7, 15 }))))
    local e = E()
    local kc = rnd(2)
    return { "if " .. c[1] .. " == " .. kc .. " then " .. v .. " = " .. e[1] .. " end",
             "if " .. c[2] .. " == " .. kc .. " then " .. v .. " = " .. e[2] .. " end" }
  end
  if r == 10 then  -- flipped boolean: type instability, the loop is unrolled
    local e1, e2 = E(), E()
    return { "f = not f; if f then " .. v .. " = " .. e1[1] .. " else " .. v .. " = " .. e2[1] .. " end",
             "f = not f; if f then " .. v .. " = " .. e1[2] .. " else " .. v .. " = " .. e2[2] .. " end" }
  end
  if r == 11 then  -- table store, fed back next iteration
    local ix = B("&", P("i"), P("7"))
    local e = E()
    if rnd(2) == 1 then
      return { "t[" .. ix[1] .. " + 1] = " .. e[1], "t[" .. ix[2] .. " + 1] = " .. e[2] }
    end
    return { "t[1] = " .. e[1], "t[1] = " .. e[2] }
  end
  if r == 12 then return assign("u", E()) end
  if r == 13 and depth == 0 then  -- inner loop, constant trip count (unrolled)
    INNERJ = true
    local e = E()
    INNERJ = false
    local n = rnd(4)
    return { "for j = 1, " .. n .. " do " .. v .. " = " .. e[1] .. " end",
             "for j = 1.0, " .. n .. " do " .. v .. " = " .. e[2] .. " end" }
  end
  if r == 14 and depth == 0 then  -- inner loop, variable trip count
    INNERJ = true
    local e = E()
    INNERJ = false
    local c = B("&", P("i"), P("3"))
    return { "for j = 1, " .. c[1] .. " do " .. v .. " = " .. e[1] .. " end",
             "for j = 1.0, " .. c[2] .. " do " .. v .. " = " .. e[2] .. " end" }
  end
  if r == 15 then  -- helper call (inlined)
    local a = pick(VARS)
    return { v .. " = F(" .. a .. ", i)", v .. " = F(" .. a .. ", i)" }
  end
  if r == 16 then  -- swap through a multiple assignment
    local e = E()
    return { "x, y = y, " .. e[1], "x, y = y, " .. e[2] }
  end
  if r == 17 then  -- int-typed results (the loop index through a bit op)
    local e = B(pick({ "|", "&", "~" }), P("i"), K({ "0", "255", "0xffff", "-1", "0x1fffffffffffff" }))
    return assign(v, e)
  end
  if r == 19 then  -- an uncompiled C call: trace stitching around it
    local c = B("&", P("i"), P("7"))
    local e = E()
    return { "if " .. c[1] .. " == 5 then NY(EMPTY) end; " .. v .. " = " .. e[1],
             "if " .. c[2] .. " == 5 then NY(EMPTY) end; " .. v .. " = " .. e[2] }
  end
  if r == 18 then  -- shift by the int index directly
    local e = B(pick({ "<<", ">>", "~>>" }), P(pick(VARS)), B("&", P("i"), P("63")))
    return assign(v, e)
  end
  return assign(v, E())
end

-- Helpers, built with the same builders so both dialects agree.
local function helper(kind)
  local a, b = P("a"), P("b")
  local e
  if kind == 1 then
    e = B("&", B("~", B("~", B("<<", a, P("13")), B(">>", a, P("7"))), b), P("0xffffffffffff"))
  elseif kind == 2 then
    e = B("~", B(">>", a, P("11")), B("<<", b, P("40")))
  elseif kind == 3 then
    e = B("|", B("<<", B("&", a, P("0xfffff")), P("33")), B(">>", a, P("31")))
  else
    e = B("~", B("~>>", a, P("10")), b)
  end
  return { "local function F(a, b) return " .. e[1] .. " end",
           "local function F(a, b) return " .. e[2] .. " end" }
end

local fl = assert(io.open(OUT .. "/cases_lj.lua", "wb"))
local fp = assert(io.open(OUT .. "/cases_puc.lua", "wb"))
fl:write("return {\n"); fp:write("return {\n")
for id = 1, COUNT do
  local ns = rnd(4)
  local L, Q = {}, {}
  for k = 1, ns do local s = stmt(0); L[k] = "      " .. s[1]; Q[k] = "      " .. s[2] end
  local hp = helper(rnd(4))
  local hk = rnd(6)
  -- The loop header, its end, and the iteration count of the loop variable's
  -- value v (it = i is the body's first statement) for drv.lua's coverage line.
  local function header(z)
    if hk == 3 then return "  for i = -7" .. z .. ", n - 8 do\n", "  end\n", "v + 8" end
    if hk == 4 then return "  for i = n" .. (z ~= "" and " + 0.0" or "") .. ", 1, -1 do\n", "  end\n", "n - v + 1" end
    if hk == 5 then return "  for i = 2^40, 2^40 + n - 1 do\n", "  end\n", "v - 2^40 + 1" end
    if hk == 6 then return "  local i = 0" .. z .. "\n  while i < n do\n      i = i + 1\n", "  end\n", "v" end
    return "  for i = 1" .. z .. ", n do\n", "  end\n", "v"
  end
  -- idx mode's key table: 0..15, and keys at and past +-2^31 and +-2^32,
  -- among them the ones whose low 32 bits are small (-2^32 + 5, + 40, + 49).
  local function tkline(z)
    if not IDXMODE then return "" end
    local kv = {}
    for k = 0, 15 do kv[#kv + 1] = "[" .. k .. "] = " .. (100 + k) .. z end
    local H = { "-1", "-5", "2^31", "(2^31 + 5)", "(2^32 - 6)", "-2^31", "(-2^31 - 1)",
      "(-2^32 + 5)", "(2^32 + 5)", "(2^31 - 1)", "2^32", "-2^32", "(-2^32 + 40)", "(-2^32 + 49)" }
    for j, k in ipairs(H) do kv[#kv + 1] = "[" .. k .. "] = " .. (-j) .. z end
    return "local tk = { " .. table.concat(kv, ", ") .. " }\n"
  end
  local function chunk(body, helperline, istart, z)
    local hd, ft, iter = header(z)
    return "local SAR, NY = ...\nlocal EMPTY = {}\n" .. tkline(z) ..
      "local t = { 0" .. z .. ", 1" .. z .. ", 2" .. z .. ", 3" .. z .. ", 4" .. z ..
      ", 5" .. z .. ", 6" .. z .. ", 7" .. z .. " }\nlocal u = 0" .. z .. "\n" ..
      "local s = '\\1\\255\\128\\0\\7\\63\\64\\200\\3\\254\\17\\129\\99\\31\\32\\33'\n" ..
      helperline .. "\n" ..
      "local it = 0\n" ..
      "local function run(n, x, y, z)\n" ..
      "  local h, f = 0" .. z .. ", false\n" ..
      hd ..
      "      it = i\n" ..
      table.concat(body, "\n") .. "\n" ..
      "      h = h + x - y * 0.5 + z * 0.25\n" ..
      ft ..
      "  return x, y, z, h\n" ..
      "end\n" ..
      "return run, function() return it end, function(v, n) return " .. iter .. " end\n"
  end
  local function q(s) return string.format("%q", s) end
  fl:write(q(chunk(L, hp[1], "1", "")), ",\n")
  fp:write(q(chunk(Q, hp[2], "1.0", ".0")), ",\n")
end
fl:write("}\n"); fp:write("}\n")
fl:close(); fp:close()
print("wrote", COUNT, "cases, seed", seed)
