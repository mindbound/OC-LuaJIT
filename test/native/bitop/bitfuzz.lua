-- test/native/bitop/bitfuzz.lua -- differential fuzzer for Lua 5.3's bitwise
-- operators (& | ~ << >> and unary ~) on our LuaJIT (round 3) against PUC Lua
-- 5.3.6.  test/native/run-bitfuzz.sh drives it; bitfuzz-cmp.lua (run under
-- PUC) compares.  Written by the round-3 "tests" investigator (r3/tests/proto,
-- 2026-10-17); F13's comparator pattern added by the round-3 designer
-- (r3/synth/fuzz); the U1-B reference rule, the sim-round control and the
-- E:INEXACT class by role C2 of the round-3 implementation.
--
--   <vm> bitfuzz.lua <side> <seed> <cases> <out-file> [tuples] [profile]
--
-- THE RULE (U1-B, decided 2026-10-17): an operator's 64-bit result r becomes
-- its double d when (int64)d == r -- r has at most 53 significant bits -- and
-- otherwise raises "result of '<op>' has more than 53 significant bits (mask
-- each operand to 32 bits first)" (the hint decided 2026-10-17).  Every
-- result that does not raise is 5.3.6's exactly.
--
-- side:
--   puc          the REFERENCE (run on PUC 5.3.6).  Per tuple it writes
--                  REF    every bitwise op's result passed through X(r, op),
--                         the rule above applied at every operator: the
--                         result's double, or the error.  A raising
--                         intermediate stops the expression where ours stops
--                  RAW    the plain 5.3.6 result (exact int64), to classify
--                  RAWMIN the same expression printed with minimal parentheses
--                         (5.3 precedence): must equal RAW, else the printer
--                         is broken (the comparator exits 2)
--                  REFK   REF with the operands spliced in as literals (PUC's
--                         constant folding): must equal REF, else the literal
--                         printer is broken (exit 2)
--   ours         the VM under test (the build's luajit.exe, run with and
--                without -joff).  Per tuple it writes the result in five modes:
--                  K  every operand a literal: the PARSER's constant folding
--                     (an inexact result is not folded: the run time raises)
--                  V  operands are arguments: the interpreter, called once
--                  P  as V, minimal parentheses: the parser's precedence
--                  H  as V inside a loop over all tuples, REP times: traces
--                     compile (the result is the last repetition's; any
--                     disagreement between repetitions is flagged)
--                  U  operands are literals stored to locals inside a loop
--                     body run 120 times: not folded by the parser, CONSTANTS
--                     to the recorder, so the trace's FOLD engine computes
--                     (first U_T tuples only)
--   sim-wrap     PUC playing a CORRECT round-3 VM: the ours modes, each op
--                wrapped in X as REF is.  The comparator must PASS it (the
--                instrument does not reject the rule it encodes)
--   sim-raw      PUC playing a VM without the rule (exact 5.3.6): the
--                comparator must FAIL it, in exactly the INEXACT tuples (the
--                rule is not vacuous)
--   sim-round    PUC playing the rejected U1-A, each op's result rounded to
--                the nearest double ("+ 0.0") instead of raising: the
--                comparator must FAIL it in exactly the tuples whose REF is
--                E:INEXACT (the instrument tells raising from rounding)
--
-- The generator below draws the same cases on every VM: an integer-exact PRNG
-- (Park-Miller, products < 2^47), no bitwise operator anywhere outside the
-- generated chunks, and every literal is built by exact digit arithmetic, so
-- PUC (integers) and LuaJIT (doubles) print the same text.  Every operand
-- value is EXACTLY representable as a double (default profile), so the two
-- VMs start from the same mathematical values.  There is no ~>> here (5.3 has
-- none): bitop/t_sar.lua (run-bitop.sh) and the generator (run-bitjit.sh)
-- cover it.
local side, seed, ncases, outf, ntup, profile = ...
seed = tonumber(seed) or 1
ncases = tonumber(ncases) or 1000
ntup = tonumber(ntup) or 16
profile = profile or "default"
local REP, U_T, U_N = 8, 3, 120
assert(side == "puc" or side == "ours" or side == "sim-wrap" or side == "sim-raw" or side == "sim-round", "bad side")
local fmt, floor = string.format, math.floor
local TAB = string.char(9)
local unpack = table.unpack or unpack
local out = assert(io.open(outf, "wb"))

------------------------------------------------------------------ the rule
-- X(r, op), PUC only (the reference and sim-wrap): r is 5.3.6's integer
-- result.  math.tointeger(r + 0.0) == r exactly when r has a double equal to
-- it; r + 0.0 = 2^63 (r near maxinteger) has no integer and fails too.  The
-- message is ours (oclj_bitop.h's rule, oclj_bitop_meta.c's text), so the
-- comparator reads both sides alike.
if side == "puc" or side == "sim-wrap" then
  assert(math.type, "side " .. side .. " runs on PUC Lua 5.3.6")
  local tointeger = math.tointeger
  X = function(r, op)
    local f = r + 0.0
    if tointeger(f) ~= r then error("result of '" .. op .. "' has more than 53 significant bits (mask each operand to 32 bits first)", 2) end
    return f
  end
end

------------------------------------------------------------------ PRNG
local st = (seed * 7919 + 12345) % 2147483646 + 1
local function rnd(n)            -- 1..n, n <= 2^31
  st = (st * 48271) % 2147483647
  return st % n + 1
end
local function pick(t) return t[rnd(#t)] end

------------------------------------------------------------------ exact literals
local P2 = { [0] = 1 }            -- 2^k as integers (PUC keeps them integer)
for k = 1, 64 do P2[k] = P2[k - 1] * 2 end
local LIMB = 10000000
local function dec_of(m, e)       -- decimal text of m * 2^e; 0 <= m < 2^53
  if m == 0 then return "0" end
  local d, x = {}, m
  while x > 0 do local q = floor(x / LIMB); d[#d + 1] = x - q * LIMB; x = q end
  for _ = 1, e do
    local c = 0
    for i = 1, #d do
      local t = d[i] * 2 + c
      if t >= LIMB then d[i] = t - LIMB; c = 1 else d[i] = t; c = 0 end
    end
    if c > 0 then d[#d + 1] = c end
  end
  local s = { fmt("%d", d[#d]) }
  for i = #d - 1, 1, -1 do s[#s + 1] = fmt("%07d", d[i]) end
  return table.concat(s)
end
local HEX = "0123456789abcdef"
local function hex_of(m, e)       -- "0x..." of m * 2^e, m * 2^(e % 4) < 2^56
  local r = e % 4
  local x, s = m * P2[r], ""
  if x == 0 then s = "0" end
  while x > 0 do
    local q = floor(x / 16); local dgt = x - q * 16
    s = HEX:sub(dgt + 1, dgt + 1) .. s; x = q
  end
  return "0x" .. s .. string.rep("0", (e - r) / 4)
end
local function neg(s) return "(-" .. s .. ")" end
local function sgn(s) if rnd(2) == 1 then return neg(s) end return s end
local function m53() return (rnd(67108864) - 1) * 134217728 + (rnd(134217728) - 1) end

------------------------------------------------------------------ value pools
local pools = {}
pools.small = function() local n = rnd(81) - 41; if n < 0 then return neg(dec_of(-n, 0)) end return dec_of(n, 0) end
pools.shift = function()
  local r = rnd(10)
  if r <= 2 then return pick({ "31", "32", "33", "52", "53", "63", "64", "65", "(-63)", "(-64)", "(-65)", "0", "1" }) end
  if r <= 7 then return dec_of(rnd(65) - 1, 0) end
  local n = rnd(141) - 71; if n < 0 then return neg(dec_of(-n, 0)) end return dec_of(n, 0)
end
pools.pow2 = function()
  local k = rnd(63) - 1
  local d = (k <= 52) and (rnd(5) - 3) or 0
  local v = P2[k] + d; if v < 0 then v = 0 end
  return sgn(dec_of(v, 0))           -- 2^k + d < 2^53 when d ~= 0
end
pools.big = function()
  local m, e = m53(), rnd(11) - 1    -- < 2^63
  if rnd(3) == 1 then return sgn(hex_of(m, e)) end
  return sgn(dec_of(m, e))
end
pools.mask = function()
  local r = rnd(4)
  if r == 1 then return hex_of(P2[rnd(53)] - 1, 0) end
  if r == 2 then return dec_of(P2[rnd(53)] - 1, 0) end
  if r == 3 then return hex_of(P2[53] - 1, rnd(10)) end         -- 0x7ffffffffffffc00 etc.
  return pick({ "0xff", "0xffff", "0xffffffff", "0x80000000", "0x100000000", "0xff00ff00ff00" })
end
pools.floatint = function()
  local r = rnd(6)
  if r == 1 then return "0x1p" .. (rnd(63) - 1) end
  if r == 2 then return "(-0x1p63)" end
  return pick({ "3.0", "(-0.0)", "1e3", "4096.0", "(-7.0)", "0x1.8p61" })
end
pools.str = function()
  return pick({ '"10"', '"0x10"', '" 7 "', '"1e2"', '"-3"', '"2.0"', '"0x1p4"', '"9007199254740992"', '"  0xff  "' })
end
pools.bad = function()
  return pick({ "1.5", "(-0.5)", "0x1p63", "0x1p64", "1e300", "(1/0)", "(0/0)", '"1.5"', '"abc"', "nil", "true", "{}" })
end
local GOOD = { "small", "pow2", "big", "mask", "small", "big" }
local function draw(pool)          -- one tuple value of a slot whose pool is `pool`
  local r = rnd(100)
  if r <= 2 then return pools.bad() end
  if r <= 6 then return pools.str() end
  if r <= 12 then return pools.floatint() end
  return pools[pool]()
end

------------------------------------------------------------------ expressions
local SLOTN = { "a", "b", "c", "d" }
local BIN = { "&", "|", "~", "<<", ">>" }
local PRIO = { ["|"] = 4, ["~"] = 5, ["&"] = 6, ["<<"] = 7, [">>"] = 7 }
local function gen(depth, shiftpos, slots, root)
  if depth == 0 or (not root and rnd(10) <= 3) then
    local pool = shiftpos and "shift" or pick(GOOD)
    if rnd(10) <= 6 then                         -- a slot (runtime value)
      if #slots > 0 and rnd(10) <= 3 then return { slot = rnd(#slots) } end
      if #slots < 4 then slots[#slots + 1] = pool; return { slot = #slots } end
      return { slot = rnd(#slots) }
    end
    local lit = (rnd(25) == 1) and pools.bad() or (rnd(20) == 1 and pools.str()) or pools[pool]()
    return { lit = lit }
  end
  if rnd(8) == 1 then return { op = "u", gen(depth - 1, false, slots) } end
  local op = pick(BIN)
  return { op = op, gen(depth - 1, false, slots), gen(depth - 1, op == "<<" or op == ">>", slots) }
end
-- Full parentheses.  wrap: false, the plain expression; "x", every op's
-- result through X(r, op) (the rule); "round", every op's result + 0.0 (U1-A,
-- the sim-round control).  lits: slot -> literal text.
local function full(n, wrap, lits)
  if n.lit then return n.lit end
  if n.slot then return lits and lits[n.slot] or SLOTN[n.slot] end
  local s
  if n.op == "u" then s = "~" .. full(n[1], wrap, lits)
  else s = "(" .. full(n[1], wrap, lits) .. " " .. n.op .. " " .. full(n[2], wrap, lits) .. ")" end
  if wrap == "x" then return "X(" .. s .. ", '" .. (n.op == "u" and "~" or n.op) .. "')" end
  if wrap == "round" then return "((" .. s .. ") + 0.0)" end
  return s
end
local function minp(n)             -- minimal parentheses by 5.3's precedence
  if n.lit then return n.lit, 100 end
  if n.slot then return SLOTN[n.slot], 100 end
  if n.op == "u" then
    local s, p = minp(n[1]); if p < 12 then s = "(" .. s .. ")" end
    return "~" .. s, 12
  end
  local pr = PRIO[n.op]
  local ls, lp = minp(n[1]); if lp < pr then ls = "(" .. ls .. ")" end
  local rs, rp = minp(n[2]); if rp <= pr then rs = "(" .. rs .. ")" end
  return ls .. " " .. n.op .. " " .. rs, pr
end

------------------------------------------------------------------ results
-- hi:lo split of an integral number.  A PUC integer splits in integer
-- arithmetic (modular, so an hi one too high near 2^63 still corrects); a float
-- (every LuaJIT number, PUC's REF) in float arithmetic, which is exact here.
local TWO32I, TWO32F = 4294967296, 4294967296.0
local mtype = math.type
-- Error kinds:
--   E:INEXACT:<op>   the rule's error, naming the operator (ours: the message
--                    of oclj_bitop_meta.c and of the interpreter's and the
--                    JIT's exits to it; PUC: X above).  Read up to "bits":
--                    the kind classifies, whatever hint follows; the text
--                    is pinned by run-bitop.sh's matrix and bitop_test.c BT3
--   E:NOINT          "number ... has no integer representation", either word
--                    order and with or without the variable's name
--   E:TYPE:<t>:<verb> "attempt to perform <verb> on ... (a <t> value)" in
--                    5.3.6's word order or in LuaJIT's ("on local 'a' (a
--                    boolean value)", F13: r3/synth/logs/fuzz-b1-s1.log);
--                    the comparator ignores the verb unless "strict"
--   E:OTHER:<text>   anything else, compared as text
local function errkind(e)
  e = tostring(e)
  local msg = e:gsub("^[^\n]-:%d+: ", "")
  local op = msg:match("^result of '([^']+)' has more than 53 significant bits")
  if op then return "E:INEXACT:" .. op end
  if msg:find("has no integer representation", 1, true) then return "E:NOINT" end
  local t = msg:match("^attempt to perform bitwise operation on a (%a+) value")
     or msg:match("^attempt to perform bitwise operation on [%a]+ '[^']*' %(a (%a+) value%)")  -- LuaJIT's order (F13)
  if t then return "E:TYPE:" .. t .. ":bitwise" end
  t = msg:match("^attempt to perform arithmetic on a (%a+) value")
     or msg:match("^attempt to perform arithmetic on [%a]+ '[^']*' %(a (%a+) value%)")
  if t then return "E:TYPE:" .. t .. ":arith" end
  return "E:OTHER:" .. msg:gsub("[\t\n]", "/")
end
local function res(ok, v)
  if not ok then return errkind(v) end
  if type(v) == "table" then return errkind(v[1]) end     -- H-mode error marker
  if type(v) ~= "number" then return "T:" .. type(v) end
  if v ~= v then return "NAN" end
  if v == 0 and 1 / v < 0 then return "N-0" end
  if v >= 2 ^ 64 or v <= -(2 ^ 64) or v ~= floor(v) then return fmt("F%.17g", v) end
  local TWO32 = (mtype and mtype(v) == "integer") and TWO32I or TWO32F
  local hi = floor(v / TWO32F)
  local lo = v - hi * TWO32
  if lo < 0 then hi = hi - 1; lo = lo + TWO32 elseif lo >= TWO32 then hi = hi + 1; lo = lo - TWO32 end
  return fmt("N%d:%d", hi, lo)
end

-- the formatter, at the boundaries where it once broke (PUC integers near 2^63)
assert(res(true, 2 ^ 63) == "N2147483648:0" and res(true, -(2 ^ 63)) == "N-2147483648:0")
assert(res(true, -1) == "N-1:4294967295" and res(true, 2 ^ 53) == "N2097152:0" and res(true, 0) == "N0:0")
if mtype then  -- PUC: integers beyond 2^53 (these literals are read but never run on LuaJIT)
  assert(res(true, 4611686018427387905) == "N1073741824:1")
  assert(res(true, 9223372036854775807) == "N2147483647:4294967295")
  assert(res(true, -9223372036854775807 - 1) == "N-2147483648:0")
  assert(res(true, 9223372036854775807 + 0.0) == "N2147483648:0")
end
-- the error kinds, on both word orders and the rule's own message
assert(errkind("x:1: result of '>>' has more than 53 significant bits (mask each operand to 32 bits first)") == "E:INEXACT:>>")
assert(errkind("x:1: result of '~' has more than 53 significant bits") == "E:INEXACT:~")
assert(errkind("x:1: number (local 'a') has no integer representation") == "E:NOINT")
assert(errkind("x:1: attempt to perform bitwise operation on local 'a' (a boolean value)") == "E:TYPE:boolean:bitwise")
assert(errkind("x:1: attempt to perform bitwise operation on a nil value (local 'a')") == "E:TYPE:nil:bitwise")
if X then  -- the rule at its boundaries (PUC): 2^53 + 1 raises, 2^53 and -2^63 do not
  assert(not pcall(X, (1 << 53) + 1, "|") and pcall(X, 1 << 53, "|") and pcall(X, math.mininteger, "|"))
  assert(not pcall(X, math.maxinteger, ">>") and X(-1, "~") == -1.0)
  assert(errkind(select(2, pcall(X, math.maxinteger, ">>"))) == "E:INEXACT:>>")
end

------------------------------------------------------------------ JIT coverage (ours on LuaJIT)
local hasjit = (type(jit) == "table") and jit.attach and jit.status and jit.status()
local nstop, nabort, aborts = 0, 0, {}
local traced = setmetatable({}, { __mode = "k" })   -- functions a completed trace started in
if hasjit then
  local okv, vmdef = pcall(require, "jit.vmdef")
  local te = okv and vmdef.traceerr or {}
  jit.attach(function(what, tr, func, pc, code, info)
    if what == "stop" then nstop = nstop + 1; traced[func] = true
    elseif what == "abort" then
      nabort = nabort + 1
      local f, k = te[code], tostring(code)
      if f then
        if type(info) == "function" then info = "fn" end
        if f:find("bytecode", 1, true) and type(info) == "number" and okv and vmdef.bcnames then
          info = (vmdef.bcnames:sub(info * 6 + 1, info * 6 + 6):gsub(" +$", ""))
        end
        local okf, s = pcall(fmt, (f:gsub("%%d", "%%s")), tostring(info))
        k = okf and s or (f .. " " .. tostring(info))
      end
      k = k:gsub("[,%[%]\t]", " ")
      aborts[k] = (aborts[k] or 0) + 1
    end
  end, "trace")
end

------------------------------------------------------------------ run
local HEAD = "local a, b, c, d = ...\n"
local function call(src, ...)
  local f, err = load(src, "=x")
  if not f then return "E:LOAD:" .. tostring(err):gsub("[\t\n]", "/") end
  return res(pcall(f, ...))
end
local t0 = os.clock()
local hotcases, ncomp, ntuples, hotu = 0, 0, 0, 0
out:write(fmt("#side %s seed %d cases %d tuples %d profile %s vm %s\n", side, seed, ncases, ntup, profile,
  (jit and jit.version) or _VERSION))
for ci = 1, ncases do
  local slots = {}
  local tree = gen(rnd(4), false, slots, true)   -- the root is always an operator
  local ns = #slots
  -- the tuples: per slot, ntup literals
  local L = {}
  for s = 1, ns do L[s] = {}; for t = 1, ntup do L[s][t] = draw(slots[s]) end end
  local src = full(tree, false)
  out:write("C", TAB, ci, TAB, src, TAB, ns, "\n")
  -- the slot values, through the same lexer as the literals
  local vals = {}
  for s = 1, 4 do
    if s <= ns then
      -- table constructors with nil leave holes; index explicitly
      local parts = {}
      for t = 1, ntup do parts[t] = "[" .. t .. "] = " .. L[s][t] end
      vals[s] = assert(load("return {" .. table.concat(parts, ", ") .. "}"))()
    else vals[s] = {} end
  end
  local function lits(t) local x = {}; for s = 1, ns do x[s] = L[s][t] end; return x end
  local function args(t) return vals[1][t], vals[2][t], vals[3][t], vals[4][t] end
  if side == "puc" then
    local fref = assert(load(HEAD .. "return " .. full(tree, "x")))
    local fraw = assert(load(HEAD .. "return " .. src))
    local fmin = assert(load(HEAD .. "return " .. (minp(tree))))
    for t = 1, ntup do
      ntuples = ntuples + 1
      local ref = res(pcall(fref, args(t)))
      local raw = res(pcall(fraw, args(t)))
      local rmin = res(pcall(fmin, args(t)))
      local refk = call("return " .. full(tree, "x", lits(t)))
      out:write("T", TAB, ci, ".", t, TAB, table.concat(lits(t), " "), TAB, ref, TAB, raw, TAB, rmin, TAB, refk, "\n")
    end
  else
    local wrap = (side == "sim-wrap" and "x") or (side == "sim-round" and "round") or false
    local esrc = full(tree, wrap)
    local psrc = wrap and esrc or (minp(tree))
    local fv = assert(load(HEAD .. "return " .. esrc))
    local fp = assert(load(HEAD .. "return " .. psrc))
    -- H: the hot loop
    local OUT = {}
    local hsrc = "local SA, SB, SC, SD, OUT, N, REP = ...\nlocal pos = 0\n" ..
      "local function body(p0)\n  for p = p0, N * REP do\n    pos = p\n    local i = (p - 1) % N + 1\n" ..
      "    local a, b, c, d = SA[i], SB[i], SC[i], SD[i]\n    OUT[p] = " .. esrc .. "\n  end\nend\n" ..
      "return function()\n  local p0 = 1\n  while true do\n    local ok, e = pcall(body, p0)\n" ..
      "    if ok then return end\n    OUT[pos] = { e }\n    p0 = pos + 1\n  end\nend, body\n"
    local runh, body = assert(load(hsrc))(vals[1], vals[2], vals[3], vals[4], OUT, ntup, REP)
    runh()
    if traced[body] then hotcases = hotcases + 1 end   -- a trace STARTED in this case's own loop
    for t = 1, ntup do
      ntuples = ntuples + 1
      local k = call("return " .. full(tree, wrap, lits(t)))
      local v = res(pcall(fv, args(t)))
      local p = res(pcall(fp, args(t)))
      local h = res(true, OUT[(REP - 1) * ntup + t])
      local drift = "-"
      for r = 1, REP - 1 do
        local hr = res(true, OUT[(r - 1) * ntup + t])
        if hr ~= h then drift = "rep" .. r .. "=" .. hr; break end
      end
      local u = "-"
      if t <= U_T then
        ncomp = ncomp + 1
        -- the operands are literals stored to locals INSIDE the loop body: the
        -- parser does not fold an op on locals, and the recorder sees constant
        -- TRefs, so the trace's FOLD engine computes.  (Immutable upvalues would
        -- not do: lj_record.c:1795 tests flags >= PROTO_CLC_POLY (0x60), which
        -- PROTO_BITOP (0x80) always passes, so a bit-op function's upvalues are
        -- never constified -- measured: UREFC/ULOAD in the IR.  F17.)
        local ul = ns > 0 and ("local " .. table.concat(SLOTN, ", ", 1, ns) .. " = " .. table.concat(lits(t), ", ") .. "; ") or ""
        local usrc = "return function(n) local r for k = 1, n do " .. ul .. "r = " .. esrc .. " end return r end"
        local mk = assert(load(usrc))
        local ok, g = pcall(mk)
        u = ok and res(pcall(g, U_N)) or errkind(g)
        if ok and traced[g] then hotu = hotu + 1 end
      end
      out:write("T", TAB, ci, ".", t, TAB, k, TAB, v, TAB, p, TAB, h, TAB, u, TAB, drift, "\n")
    end
  end
end
local ab = {}
for k, n in pairs(aborts) do ab[#ab + 1] = k .. "=" .. n end
table.sort(ab)
out:write(fmt("#cov tuples %d hotcases %d/%d hotU %d/%d traces %d aborts %d [%s] jit %s\n", ntuples, hotcases, ncases,
  hotu, ncomp, nstop, nabort, table.concat(ab, ","), hasjit and "on" or "off"))
out:write(fmt("#time %.3f\n", os.clock() - t0))
out:write("#end\n")
out:close()
