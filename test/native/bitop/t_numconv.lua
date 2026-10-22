-- test/native/bitop/t_numconv.lua -- FIX-NUMCONV's value suite: identity
-- and cancelling bit operations on doubles, compiled against the
-- interpreter, at and past 2^53 and on operands that must raise.  FIX-NUMCONV
-- (roadmap row 211 (5), JIT guide 3.11; native/luajit/patch-bitop-fold.sh
-- hunk 7, oclj_isnumconv in oclj_bitop_fold.c) folds (i64)(num)y ==> y in
-- simplify_conv_i64_num when y is an unguarded CONV i64.num of a double: x64
-- compiles that y to one cvttsd2si, whose value (the double's integral
-- part, or -2^63) is always exactly a double, so the result guard of an
-- identity operation, whose result folds to its operand's own conversion,
-- can never fail.  A fact of exactness, not of range: it must never enter
-- oclj_bitwidth.  test/native/run-bitjit.sh runs this file (part nc), and
-- bitop/ncir.lua reads the IR the rule leaves.  Written 2026-10-21.
--
--   <vm> t_numconv.lua [part]      (part: all, the default, or puc)
--
-- THE FORMS, each a function of x and y (a table's double and a small odd
-- or even number), every operator's result wrapped in X(...):
--   identities, whose result folds to x's own conversion (the rule removes
--   their guard): x | 0, 0 | x, x & -1, -1 & x, x ~ 0, 0 ~ x, x << 0,
--   x >> 0, x ~>> 0, x & x, x | x, (x | 0) & -1;
--   cancellations, whose outer result folds to x's conversion and whose
--   inner operator keeps its guard (it is no identity under U1-B: ~x for an
--   exact x >= 2^53 with bit 0 clear is inexact): ~~x, (x ~ y) ~ y,
--   (x ~ 5) ~ 5, ~(x ~ -1);
--   controls, whose result is no conversion and whose guard must stay (or
--   which the width rule already takes): x | 1, x ~ 1, ~x, x ~ y, x << 1,
--   x >> 1, x ~>> 1, x & 0xff, (x | 0) | 1.
-- A build that drops a control's guard (the NUMCONVOP1 sabotage: a bit
-- operator ON a converted double counted as one; NUMCONVW: a converted
-- double scored 54 bits wide in oclj_bitwidth) returns the rounded double,
-- 2^53 | 1 giving 9007199254740992, where the interpreter raises "result of
-- '|' has more than 53 significant bits".  Measured 2026-10-21 on sabotage
-- copies of the prototype's build, three runs on Windows and two in
-- AlmaLinux 8, every count the same in each: NUMCONVOP1 differs in 30 cases
-- under each set with loop optimization and CSE, in 22 under -O1, -O-loop
-- and -O-cse; NUMCONVW in 27 under each set that folds; both in 0 under -O0
-- and -O-fold, which run no fold rule.  The rule switched off (NUMCONVOFF)
-- and the base build differ in none: the rule changes no value, so only
-- bitop/ncir.lua sees it.
--
-- THE LOOPS.  Each case is one form in one mode, its own loop prototype
-- (load), run three times.  The loop records on 300 small values (x = 2i,
-- every result exact), then the same compiled loop, with no branch in
-- between, meets 132 values (BIG's 22, six times each): 2^53, 2^60, -2^60,
-- 2^53 + 2, 3 * 2^61, -2^63, 2^63 - 1024, -2^53, -(2^53 + 2), 2^62 + 2^20;
-- the edges 2^52 + 1, 2^53 - 1 and -0.0; and operands that must raise: NaN,
-- +inf, -inf, 2^63, -2^63 - 2048, 2^64, 1.5, -0.5, 2^51 + 0.5.  Every result
-- is stored unconditionally, an error through pcall, and read after the
-- loop.  The modes:
--   p   the form on the table's double:  pcall(f, T[i], y)
--   c   the form on the previous iteration's identity result, carried in a
--       slot as its marked double:  pcall(f, h, y); h = X(H[i] | 0)  (H is
--       T with every value that would raise replaced by an exact one)
--   s   the form on X(h & g), where h and g both carry the previous
--       iteration's double: in the loop body h & g folds to the pre-roll's
--       conversion of x, a loop-carried value, so the rule meets a PHI-marked
--       CONV num.i64 (bitop/ncir.lua's swap1 reads it)
--
-- THE REFERENCE is -joff: run-bitjit.sh compares the whole output of each
-- JIT option set with it.  ONE TEXT, TWO DIALECTS (bitop/twin.lua): our
-- text drops each X; PUC 5.3.6's applies U1-B's rule there (a result with
-- more than 53 significant bits raises, where 5.3.6 alone would return the
-- integer: JIT guide 11.2, bitop/deviations.txt), and ~>> becomes SAR.  With
-- that rule every case here means the same on both VMs, so part puc is part
-- all (kept as a part for the runner's symmetry with t_select and t_idx2);
-- nothing is excluded: no library integer argument, no lexer-rounded
-- literal (every literal here is exactly a double), no ~>> outside X.
--
-- Prints one line per case, "<form>-<mode><TAB><call 1>;<call 2>;<call 3>",
-- each call "s=<sum of the small part>,e=<raises in it>|<results>", the
-- results of the big part as %.17g or E:<kind> (twin.lua's KIND).
-- On stderr, LuaJIT with the JIT on, one line:
--   #cov cases <n> traced <n> ncin <n> nsig <n> jit <on|off>
-- traced: the cases in which a trace completed in the case's loop or form
-- function; ncin: in those traces, the marked CONV num.i64 (op2 & 0x7ff =
-- 0x5d5) whose operand is an unguarded, unmarked int64 CONV i64.num of a
-- double (0x2ae): the pair the rule reads (fleft and its y), present on any
-- build that compiled a bit operator on a double; nsig: the i64 EQ guards
-- whose operands are such a conversion and a marked CONV i64.num (0x6ae),
-- the result guard the rule removes, 0 on a build with the rule, and not a
-- gate here (bitop/ncir.lua gates it per form).  run-bitjit.sh requires, in
-- the default run, jit on, a trace in OCLJ_BITJIT_HOTMIN of the cases and
-- ncin at least 1.  Exit 2 (INSTRUMENT) if a text is not what it says.
-- Value-level only: no case reads or writes memory through a pointer (FFI
-- is off).  This file holds no backslash: a newline is NL, a tab TAB.
local NL, TAB, BS = string.char(10), string.char(9), string.char(92)
local dir = (arg and arg[0] or ""):match("^(.*[/" .. BS .. "])") or ""
local TW = dofile(dir .. "twin.lua")
local PART = arg and arg[1] or "all"
local fmt = string.format
if PART ~= "all" and PART ~= "puc" then
  print("INSTRUMENT: t_numconv's part is all or puc, not " .. tostring(PART))
  os.exit(2)
end

local FORMS = {
  { "or0", "X(x | 0)" }, { "or0l", "X(0 | x)" }, { "andm1", "X(x & -1)" },
  { "andm1l", "X(-1 & x)" }, { "xor0", "X(x ~ 0)" }, { "xor0l", "X(0 ~ x)" },
  { "shl0", "X(x << 0)" }, { "shr0", "X(x >> 0)" }, { "sar0", "X(x ~>> 0)" },
  { "andxx", "X(x & x)" }, { "orxx", "X(x | x)" }, { "or0andm1", "X(X(x | 0) & -1)" },
  { "notnot", "X(~X(~x))" }, { "xoryy", "X(X(x ~ y) ~ y)" }, { "xor55", "X(X(x ~ 5) ~ 5)" },
  { "notxm1", "X(~X(x ~ -1))" },
  { "or1", "X(x | 1)" }, { "xor1", "X(x ~ 1)" }, { "bnot", "X(~x)" }, { "xory", "X(x ~ y)" },
  { "shl1", "X(x << 1)" }, { "shr1", "X(x >> 1)" }, { "sar1", "X(x ~>> 1)" },
  { "andff", "X(x & 0xff)" }, { "or0or1", "X(X(x | 0) | 1)" },
}
local MODES = { "p", "c", "s" }
-- The form functions per mode (our text or PUC's comes from TW.text).
local FTEXT = {
  p = "return function(x, y) return @F@ end",
  c = "return function(x, y) return @F@ end",
  s = "return function(h, g, x0, y) local x = X(h & g); local u = X(x0 & 0xff); return @F@, u end",
}
-- The loops: one prototype per case.
local LTEXT = {
  p = "local T, Y, H, n, f, OK, R = ..." .. NL ..
      "for i = 1, n do local ok, r = pcall(f, T[i], Y[i]); OK[i] = ok; R[i] = r end",
  c = "local T, Y, H, n, f, OK, R = ..." .. NL .. "local h = H[1]" .. NL ..
      "for i = 1, n do local ok, r = pcall(f, h, Y[i]); OK[i] = ok; R[i] = r; h = X(H[i] | 0) end",
  s = "local T, Y, H, n, f, OK, R = ..." .. NL .. "local h, g = T[1], T[1]" .. NL ..
      "for i = 1, n do local x = T[i]; local ok, r = pcall(f, h, g, x, Y[i]); OK[i] = ok; R[i] = r; h = x; g = x end",
}

-- The text checks (twin.lua's): each X wraps one operator at its top level.
do
  local bad = {}
  for _, F in ipairs(FORMS) do
    local p = TW.check(F[1], F[2]); if p then bad[#bad + 1] = p end
  end
  for m, s in pairs(FTEXT) do
    local p = TW.check("ftext-" .. m, s:gsub("@F@", "X(x | 0)")); if p then bad[#bad + 1] = p end
  end
  for m, s in pairs(LTEXT) do
    local p = TW.check("ltext-" .. m, s); if p then bad[#bad + 1] = p end
  end
  if #bad > 0 then
    print("INSTRUMENT: t_numconv's X-wrapped texts are wrong: " .. table.concat(bad, "; "))
    os.exit(2)
  end
end

-- The values: 300 small (recording), then 132 at and past 2^53 and raising.
local NSMALL = 300
local BIG = { 2^53, 2^60, -2^60, 2^53 + 2, 3 * 2^61, -2^63, 2^63 - 1024, -2^53,
  -(2^53 + 2), 2^62 + 2^20, 2^52 + 1, 2^53 - 1, -0.0, 0/0, 1/0, -1/0, 2^63,
  -2^63 - 2048, 2^64, 1.5, -0.5, 2^51 + 0.5 }
local NBIG = 6 * #BIG
local N = NSMALL + NBIG
local YV = { 1, 3, 5, 2, 4, 6, 7 }
local T, Y, H = {}, {}, {}
for i = 1, NSMALL do T[i] = 2.0 * i; H[i] = T[i] end
for j = 1, NBIG do
  local v = BIG[(j - 1) % #BIG + 1]
  T[NSMALL + j] = v
  -- H: an exact value where v would raise (NaN, an infinity, out of range,
  -- a fraction): the carried identity outside pcall must not raise.
  local exact = v == v and v >= -2^63 and v < 2^63 and v == math.floor(v)
  H[NSMALL + j] = exact and v or (2^53 + 2 * j)
end
for i = 1, N do Y[i] = YV[(i - 1) % #YV + 1] + 0.0 end

-- THE INSTRUMENT (LuaJIT with the JIT on).
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local cov = { cases = 0, traced = 0, ncin = 0, nsig = 0, jit = hasjit and "on" or "off" }
local watch1, watch2, hit = nil, nil, false
if hasjit then
  local okv, vmdef = pcall(require, "jit.vmdef")
  local oku, jutil = pcall(require, "jit.util")
  if not (okv and oku) then
    print("INSTRUMENT: no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)")
    os.exit(2)
  end
  local OPS = {}
  for o = 0, #vmdef.irnames / 6 - 1 do
    OPS[(vmdef.irnames:sub(o * 6 + 1, o * 6 + 6):gsub(" +$", ""))] = o
  end
  if not (OPS.CONV and OPS.EQ) then print("INSTRUMENT: jit.vmdef names no CONV or EQ"); os.exit(2) end
  local IRT_I64 = 21
  local function scan(tr)
    local nins = jutil.traceinfo(tr).nins
    local ir = {}
    for ref = 1, nins do
      local _, ot, op1, op2 = jutil.traceir(tr, ref)
      if not ot then break end
      ir[ref] = { o = math.floor(ot / 256), t = ot % 32, g = ot % 256 >= 128, op1 = op1, op2 = op2 }
    end
    local function conv(r, mode)
      local x = r > 0 and ir[r]
      return x and x.o == OPS.CONV and x.op2 % 2048 == mode
    end
    local function nc(r)  -- an unguarded, unmarked int64 CONV i64.num of a double
      return conv(r, 686) and ir[r].t == IRT_I64 and not ir[r].g
    end
    local ncin, nsig = 0, 0
    for ref = 1, #ir do
      local x = ir[ref]
      if conv(ref, 1493) and nc(x.op1) then ncin = ncin + 1 end
      if x.o == OPS.EQ and x.t == IRT_I64 and x.g and
         ((nc(x.op1) and conv(x.op2, 1710)) or (nc(x.op2) and conv(x.op1, 1710))) then
        nsig = nsig + 1
      end
    end
    return ncin, nsig
  end
  jit.attach(function(what, tr, func)
    if what == "stop" and watch1 and (func == watch1 or func == watch2) then
      if not hit then hit = true; cov.traced = cov.traced + 1 end
      local a, b = scan(tr)
      cov.ncin = cov.ncin + a; cov.nsig = cov.nsig + b
    end
  end, "trace")
end

local KIND = TW.KIND
local lines = {}
for _, F in ipairs(FORMS) do
  for _, m in ipairs(MODES) do
    local name = F[1] .. "-" .. m
    local f = assert(load(TW.text((FTEXT[m]:gsub("@F@", F[2]))), "=f-" .. name))()
    local loop = assert(load(TW.text(LTEXT[m]), "=" .. name))
    watch1, watch2, hit = loop, f, false
    local calls = {}
    for call = 1, 3 do
      local OK, R = {}, {}
      for i = 1, N do OK[i] = false; R[i] = 0 end  -- pre-sized: no growth exits
      loop(T, Y, H, N, f, OK, R)
      local s, e = 0, 0
      for i = 1, NSMALL do
        if OK[i] then s = s + R[i] else e = e + 1 end
      end
      local big = {}
      for i = NSMALL + 1, N do
        big[#big + 1] = OK[i] and fmt("%.17g", R[i]) or ("E:" .. KIND(R[i]))
      end
      calls[call] = fmt("s=%.17g,e=%d|", s, e) .. table.concat(big, ",")
    end
    watch1, watch2 = nil, nil
    cov.cases = cov.cases + 1
    lines[#lines + 1] = name .. TAB .. table.concat(calls, ";")
  end
end
io.write(table.concat(lines, NL), NL)
io.stderr:write(fmt("#cov cases %d traced %d ncin %d nsig %d jit %s",
  cov.cases, cov.traced, cov.ncin, cov.nsig, cov.jit) .. NL)
