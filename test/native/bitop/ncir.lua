-- test/native/bitop/ncir.lua -- FIX-NUMCONV read from the compiled traces.
-- The rule (native/luajit/patch-bitop-fold.sh hunk 7, simplify_conv_i64_num;
-- oclj_isnumconv in oclj_bitop_fold.c; roadmap row 211 (5), JIT guide 3.11)
-- folds (i64)(num)y ==> y when y is an unguarded CONV i64.num of a double,
-- so the result guard of an identity operation (x | 0, x & -1, x ~ 0,
-- x << 0, x >> 0, and the like), whose result folds to x's own conversion,
-- disappears: it could never fail.  That changes no value, so no
-- differential suite can see the rule switched off (the NUMCONVOFF
-- sabotage); this file counts the guards it leaves (JIT guide P56,
-- checklist 19).  It is also the rule's p4v.lua: the rule returns a
-- pre-roll ref across a PHI, so each loop here must compile (a trace stops
-- in its function, no "persistent type instability" abort, its FORL becomes
-- JFORL; S4) and its result must equal -joff's (run-bitjit.sh, part nc,
-- compares the r= field).  Written 2026-10-21.
--
--   luajit [options] ncir.lua      (LUA_PATH must reach the build's src/jit/vmdef.lua)
--
-- THE SIGNATURE, keyed on operands.  oclj_rec_bitop guards a result res by
--   d = CONV num.i64 res [exact]; back = CONV i64.num d [exact]; EQ.i64 back, res
-- and an identity's res is x's own conversion, an unguarded, unmarked int64
-- CONV i64.num of a double (op2 & 0x7ff = 0x2ae).  sig counts the i64 EQ
-- guards whose operands are such a conversion and a marked CONV i64.num
-- (0x6ae): exactly the guards the rule removes, which the width rule never
-- can (it scores that conversion 64).  eq counts every i64 EQ guard.  Both
-- per trace, in the pre-roll and in the loop body (after LOOP; a trace with
-- no LOOP is all pre-roll).  On round 3's rules without FIX-NUMCONV
-- (build/native at 209aa95) an identity reads eq 1 and sig 1 in each part
-- that holds it, a cancellation eq 2 and sig 1 (argument.md's ir_ident
-- counts, 1|1 and 2|2); with the rule 0 and 0, and 1 and 0.
--
-- THE FORMS (x a table's double, y a small number), each in its own loop:
--   id     identities: the result folds to x's conversion; eq 0 in every part
--   can    cancellations: the outer result folds to x's conversion, the
--          inner operator keeps its guard; eq at most 1 in every part, and
--          1 in the first trace's pre-roll
--   keep   controls whose guard must stay (their result is no conversion):
--          eq at most 1 in every part, and 1 in the first trace's pre-roll,
--          which also shows that the instrument sees a result guard
--   wid    x & 0xff: the width rule takes its guard; eq 0
-- and sig 0 everywhere.  Without CSE (-O-cse) the two conversions of x in
-- x & x, x | x and (x ~ y) ~ y stay distinct, so comm_dup and reassoc_bxor
-- reach no conversion and those three keep their guards on every build
-- (measured 2026-10-21, impl-tests/runs/explore-2): with cse off they are
-- held to sig 0 only.
-- THE LOOPS that carry values across the PHI (each must compile):
--   swap1  t = h & g; h = x; g = x, with x also converted in the loop (as
--          x & 0xff): in the loop copy h and g both forward the pre-roll's
--          x, whose conversion CSEs to the pre-roll's y, so h & g folds to
--          y (comm_dup), its d CSEs to the pre-roll's marked CONV num.i64 F
--          of y, which loop_unroll has PHI-marked, and the guard's back
--          CONV i64.num F reaches the rule with a PHI-marked fleft: the
--          rule returns the pre-roll y, of the folded instruction's type
--          (S4), already PHI-marked, and EQ.i64 y, y drops (loop_emit_phi
--          then drops y's i64 PHI, unused once the guard is gone: -jdump of
--          the loop alone, 2026-10-21, impl-tests/runs/swap1-dump-1).  Read:
--          phiF, the PHI-marked pre-roll CONV num.i64 of a conversion (the
--          fleft the rule meets), at least 1 in each trace with a LOOP; fb,
--          the loop body's marked CONV i64.num of such an F (the
--          instruction the rule folds away; 1 a LOOP trace on the base
--          build), 0; psig, the body's sig on a PHI-marked y, 0.  Checked
--          when loop and cse are on.
--   swap0  the same without converting x: the conversion of x is emitted
--          in the loop body, so the rule fires in the copy on an unmarked
--          fleft; body sig 0 (1 on the base build)
--   carry, carry2, self   identity results carried in a slot and used by
--          an identity or a xor next iteration
--   ctl    h | 1 on a carried x: body eq at least 1 when loop is on, the
--          positive control that the instrument sees a guard in a body
-- A removal leaves no instruction of its own: what the IR shows is the
-- guard missing where its precondition (an identity's conversion, swap1's
-- PHI-marked F) is present, which the base build reads as present.
-- WHICH CHECKS FAIL ALONE (every reason is listed, none stops the others;
-- 2026-10-21, impl-tests/runs/ncir-sets-1 and ff/): sig, alone on swap0,
-- carry, carry2 and self on the base build and under NUMCONVOFF; the first
-- trace's pre-roll count of 1, alone on every can and keep form but shl1
-- under NUMCONVOP1 and NUMCONVW (their guards go; x << 1 is ADD y, y after
-- simplify_shift_ik, which neither sabotage reaches); ctl's body guard,
-- alone under the same two; swap1's phiF, alone when the fleft is never
-- found (a mutated copy, ff/phif0).  Implied, and kept for their messages:
-- an id form's eq 0, a part's eq at most 1, and swap1's fb and psig, which
-- a build fails only together with sig.
-- MEASURED (2026-10-21, on the prototype's build and sabotage copies of it,
-- three runs on Windows and two in AlmaLinux 8, every count the same in
-- each): the prototype 29 of 29 ok in each of the 13 sets that fold; the
-- base build and NUMCONVOFF fail 22 cases a set, 20 under -O1 and -O-loop,
-- 17 under -O-cse; NUMCONVOP1 and NUMCONVW fail 10, 9 under -O1, -O-loop
-- and -O-cse.
--
-- Prints one line per case,
--   <case><TAB>r=<a>,<b><TAB>traces=<n> typeins=<n> loop=<op> pre=<eq>/<sig> body=<eq>/<sig> [phiF=<n> fb=<n> psig=<n>] <ok|FAILED [why]>
-- (pre and body summed over the case's traces), and with -joff
-- "<case><TAB>r=<a>,<b><TAB>-".  Exit 0 every case ok (or the JIT off), 1 a
-- case FAILED, 2 the instrument cannot test: no jit.vmdef or jit.util, no
-- TYPEINS message, or fold off (-O0, -O-fold: no rule runs, and the base
-- build reads sig 0 there too).  Value-level only: the loops read and write
-- Lua tables of doubles, nothing through a pointer (FFI is off).  This file
-- holds no backslash: a newline is NL, a tab TAB.
local NL, TAB = string.char(10), string.char(9)
local fmt = string.format
local FORMS = {
  { "or0", "id", "x | 0" }, { "or0l", "id", "0 | x" }, { "andm1", "id", "x & -1" },
  { "andm1l", "id", "-1 & x" }, { "xor0", "id", "x ~ 0" }, { "xor0l", "id", "0 ~ x" },
  { "shl0", "id", "x << 0" }, { "shr0", "id", "x >> 0" }, { "sar0", "id", "x ~>> 0" },
  { "andxx", "id", "x & x", true }, { "orxx", "id", "x | x", true },
  { "or0andm1", "id", "(x | 0) & -1" },
  { "notnot", "can", "~~x" }, { "xoryy", "can", "(x ~ y) ~ y", true },
  { "xor55", "can", "(x ~ 5) ~ 5" }, { "notxm1", "can", "~(x ~ -1)" },
  { "or1", "keep", "x | 1" }, { "xory", "keep", "x ~ y" }, { "shl1", "keep", "x << 1" },
  { "bnot", "keep", "~x" }, { "xor1", "keep", "x ~ 1" }, { "or0or1", "keep", "(x | 0) | 1" },
  { "andff", "wid", "x & 0xff" },
}
local LOOPS = {  -- name, body (x = T[...] is set first), class
  { "swap1", "out[(i & 7) + 1] = h & g; out[9] = x & 0xff; h = x; g = x", "swap1" },
  { "swap0", "out[(i & 7) + 1] = h & g; h = x; g = x", "swap0" },
  { "carry", "out[(i & 7) + 1] = h | 0; h = x | 0", "loop" },
  { "carry2", "out[(i & 7) + 1] = (h | 0) ~ x; h = x | 0", "loop" },
  { "self", "h = h | 0; out[(i & 7) + 1] = h + x", "loop" },
  { "ctl", "out[(i & 7) + 1] = h | 1; out[9] = x & 0xff; h = x", "ctl" },
}

local hasjit = type(jit) == "table" and jit.status and jit.status()
local function instrument(msg) print("ncir: INSTRUMENT: " .. msg); os.exit(2) end
local okv, vmdef = pcall(require, "jit.vmdef")
local oku, jutil = pcall(require, "jit.util")
if hasjit and not (okv and oku) then instrument("no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)") end
local FLAG = {}
if hasjit then
  local st = { jit.status() }
  for k = 2, #st do FLAG[st[k]] = true end
  if not FLAG.fold then instrument("fold is off (-O0 or -O-fold): no fold rule runs, so the rule cannot be read") end
end
local TYPEINS, OPS = nil, {}
if hasjit then
  for code, msg in pairs(vmdef.traceerr) do
    if msg == "persistent type instability" then TYPEINS = code end
  end
  if not TYPEINS then instrument('jit.vmdef has no "persistent type instability" trace error') end
  for o = 0, #vmdef.irnames / 6 - 1 do
    OPS[(vmdef.irnames:sub(o * 6 + 1, o * 6 + 6):gsub(" +$", ""))] = o
  end
  if not (OPS.CONV and OPS.EQ and OPS.LOOP) then instrument("jit.vmdef names no CONV, EQ or LOOP IR op") end
end
local IRT_I64 = 21
local M_NC, M_BACK, M_D = 686, 1710, 1493  -- op2 % 2048: 0x2ae, 0x6ae, 0x5d5

-- The counts of trace tr.
local function scan(tr)
  local nins = jutil.traceinfo(tr).nins
  local ir, loop = {}, nil
  for ref = 1, nins do
    local _, ot, op1, op2 = jutil.traceir(tr, ref)
    if not ot then break end
    local t = ot % 256
    ir[ref] = { o = math.floor(ot / 256), t = t % 32, g = t >= 128, phi = math.floor(t / 64) % 2 == 1,
      op1 = op1, op2 = op2 }
    if ir[ref].o == OPS.LOOP then loop = ref end
  end
  local function conv(r, mode) local x = r > 0 and ir[r]; return x and x.o == OPS.CONV and x.op2 % 2048 == mode end
  local function nc(r) return conv(r, M_NC) and ir[r].t == IRT_I64 and not ir[r].g end
  local function phiF(r) return loop and r < loop and conv(r, M_D) and ir[r].phi and nc(ir[r].op1) end
  local c = { loop = loop ~= nil, pre = { eq = 0, sig = 0 }, body = { eq = 0, sig = 0 }, phiF = 0, fb = 0, psig = 0 }
  for ref = 1, #ir do
    local x = ir[ref]
    local inbody = loop and ref > loop
    local part = inbody and c.body or c.pre
    if x.o == OPS.EQ and x.t == IRT_I64 and x.g then
      part.eq = part.eq + 1
      local y = (nc(x.op1) and conv(x.op2, M_BACK) and x.op1) or (nc(x.op2) and conv(x.op1, M_BACK) and x.op2)
      if y then
        part.sig = part.sig + 1
        if inbody and y < loop and ir[y].phi then c.psig = c.psig + 1 end
      end
    end
    if phiF(ref) then c.phiF = c.phiF + 1 end
    if inbody and conv(ref, M_BACK) and phiF(x.op1) then c.fb = c.fb + 1 end
  end
  return c
end

local cur, traces, typeins = nil, nil, 0
if hasjit then
  jit.attach(function(what, tr, func, pc, code)
    if what == "stop" and func == cur then traces[#traces + 1] = scan(tr)
    elseif what == "abort" and code == TYPEINS then typeins = typeins + 1 end
  end, "trace")
end
-- The name of f's loop opcode (the only FORL family instruction in f).
local function loopop(f)
  for pc = 1, 10000 do
    local ins = jutil.funcbc(f, pc)
    if not ins then break end
    local op = ins % 256
    local name = vmdef.bcnames:sub(op * 6 + 1, op * 6 + 6):gsub(" +$", "")
    if name:match("FORL$") then return name end
  end
  return "none"
end

local T, Y = {}, {}
for i = 1, 64 do T[i] = (i % 2 == 0) and (i * 2^20) or -(i * 3) end
for i = 1, 8 do Y[i] = 12345 + i end

-- Run one case; returns its line and whether it is ok.
local function runcase(name, body, class, needcse)
  local src = "local T, Y, n = ...; local out = {}; local h, g = T[2], T[2]" .. NL ..
    "for i = 1, n do local x = T[(i & 63) + 1]; local y = Y[(i & 7) + 1]; " .. body .. " end" .. NL ..
    "return out[1], out[8]"
  local f = assert(load(src, "=ncir-" .. name))
  cur, traces, typeins = f, {}, 0
  local a, b
  for _ = 1, 3 do a, b = f(T, Y, 3000) end
  cur = nil
  local line = fmt("%s%sr=%.17g,%.17g", name, TAB, a, b)
  if not hasjit then return line .. TAB .. "-", true end
  local op = loopop(f)
  local why = {}
  if #traces == 0 then why[#why + 1] = "no trace" end
  if typeins > 0 then why[#why + 1] = "type instability" end
  if op ~= "JFORL" then why[#why + 1] = "loop " .. op end
  local P, B, phiF, fb, psig, nloop = { eq = 0, sig = 0 }, { eq = 0, sig = 0 }, 0, 0, 0, 0
  local maxeq = 0
  for _, c in ipairs(traces) do
    for _, part in ipairs({ c.pre, c.body }) do
      if part.eq > maxeq then maxeq = part.eq end
    end
    P.eq, P.sig, B.eq, B.sig = P.eq + c.pre.eq, P.sig + c.pre.sig, B.eq + c.body.eq, B.sig + c.body.sig
    phiF, fb, psig = phiF + c.phiF, fb + c.fb, psig + c.psig
    if c.loop then nloop = nloop + 1 end
  end
  local first = traces[1]
  local relax = needcse and not FLAG.cse
  if P.sig + B.sig > 0 then why[#why + 1] = "an identity's result guard is left (sig)" end
  if not relax then
    if class == "id" or class == "wid" then
      if P.eq + B.eq > 0 then why[#why + 1] = "a result guard is left (eq)" end
    elseif class == "can" or class == "keep" then
      if maxeq > 1 then why[#why + 1] = "more than one result guard in a part" end
      if first and first.pre.eq ~= 1 then why[#why + 1] = "the first trace's pre-roll has " .. first.pre.eq .. " result guards, not 1" end
    end
  end
  if class == "swap1" and FLAG.loop and FLAG.cse then
    if nloop == 0 then why[#why + 1] = "no trace with a LOOP" end
    for _, c in ipairs(traces) do
      if c.loop and c.phiF == 0 then why[#why + 1] = "a LOOP trace with no PHI-marked fleft (phiF 0)"; break end
    end
    if fb > 0 or psig > 0 then why[#why + 1] = "the guard on the PHI-marked fleft is left in the body" end
  elseif class == "swap0" and FLAG.loop then
    if nloop == 0 then why[#why + 1] = "no trace with a LOOP" end
  elseif class == "ctl" and FLAG.loop then
    if B.eq == 0 then why[#why + 1] = "no result guard in a loop body (the control)" end
  end
  local extra = class == "swap1" and fmt(" phiF=%d fb=%d psig=%d", phiF, fb, psig) or ""
  line = line .. fmt("%straces=%d typeins=%d loop=%s pre=%d/%d body=%d/%d%s %s", TAB, #traces, typeins, op,
    P.eq, P.sig, B.eq, B.sig, extra, #why == 0 and "ok" or ("FAILED (" .. table.concat(why, "; ") .. ")"))
  return line, #why == 0
end

local nbad, ncase = 0, 0
for _, F in ipairs(FORMS) do
  local line, ok = runcase(F[1], "out[(i & 7) + 1] = " .. F[3], F[2], F[4])
  print(line); ncase = ncase + 1
  if not ok then nbad = nbad + 1 end
end
for _, L in ipairs(LOOPS) do
  local line, ok = runcase(L[1], L[2], L[3], false)
  print(line); ncase = ncase + 1
  if not ok then nbad = nbad + 1 end
end
if hasjit then
  print(fmt("ncir: %d of %d cases compiled with FIX-NUMCONV's guards as expected (fold%s, cse %s, loop %s)",
    ncase - nbad, ncase, FLAG.fold and " on" or " off", FLAG.cse and "on" or "off", FLAG.loop and "on" or "off"))
end
os.exit(nbad == 0 and 0 or 1)
