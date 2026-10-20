-- test/native/bitop/t_select.lua -- select(k, ...) compiled against the
-- interpreter, for the select fix (native/luajit/patch-bitop-record.sh,
-- hunks 4 and 5; roadmap row 213, JIT guide P54).  Written 2026-10-20.
-- test/native/run-bitjit.sh runs it (part sel).
--
--   <vm> t_select.lua [part]      (part: all, the default, or puc)
--
-- THE PATHS.  rec_varg (lj_record.c) records y = select(k, ...) in a
-- vararg function's own frame on one of three paths, chosen by the k it
-- records: a constant k (A: a guard on the frame's size word fr against a
-- constant); a k within the varargs (B: their count from fr, an unsigned
-- ABC on k-1, the load); a k beyond them (C: no load, a guard fr <
-- 8*k+frofs, nil); and '#' (B's count, or C's nil count when the call
-- passed fewer arguments than the function's fixed parameters).  Upstream
-- computes C's 8*k+frofs in 32 bits: a runtime k whose 8*k wraps past the
-- frame, or a k <= 0 in a call with fewer arguments than fixed parameters,
-- passed the guard and gave nil where the interpreter raises "index out of
-- range"; and so did a k that narrowing's unchecked ADD or SUB wrapped
-- (select(x + c, ...) with x a double and c an int16 constant, x + c out
-- of int32, which the interpreter's lj_num2int reads as -2^31) to just
-- below 2^31, in such a call.  The fix aborts the recording for a recorded
-- k above 2^27 and, on path C, exits unless 1 <= k <= 2^27 before the
-- shift.
--
-- THE CASES.  A loop in a vararg function f calls select(k, ...) once per
-- iteration.  Its first call records the loop with the record value r, 150
-- times: r within the varargs (class B), beyond them (C), '#' (H), or a
-- constant (K, one loop per literal).  Then every argument list of the
-- case's shape runs every probe value p, each followed by r twice, so a
-- probe meets the compiled loop, its exits and the side traces they grow.
-- An error ends the call; the driver records it and calls f again where
-- the loop stopped.  The shapes (fixed parameters; the argument lists, the
-- first of which records): v7 (0; 7, 2, 0 and 60 values), v0 (0; 0, 3,
-- 1), p2 (2; 5, 1, 0, 2 arguments: 3, -1, -2 and 0 varargs), p2few (2; 1,
-- 0, 5, 2 arguments, recorded with fewer arguments than parameters).
-- How k reaches the trace (the source):
--   pl   ks[i], a double: CONV int.num INDEX, guarded
--   st   ks[i], a string: STRTO, then the same
--   ap   ks[i] + 1000: narrowing's unchecked ADD (lj_opt_narrow.c), so a
--        sum past 2^31 wraps to just above -2^31
--   am   ks[i] - 1000: the same, a sum below -2^31 wrapping to just below
--        2^31
--   an   ks[i] - 1073741804: a constant beyond int16, which narrowing does
--        not take: one guarded conversion of the sum
--   bx   X(ks[i] * 4294967296 ~>> 32), a bit result of 32 bits: the
--        table-index fold's CONV int.i64 (patch-bitop-fold.sh hunk 11)
--   iap, ian   i + 1000 and i - 1073741804, i the loop's own int index:
--        the recorder's checked ADDOV, run over ranges of i
-- and in a branch (wrap s: select in both arms of an if on i % 3, so a
-- side trace records one).  The probes (each case's own values of k):
-- 1, 2, 3, m-1..m+2, -1..-3, -m..-(m+2) and 0 for each argument list's m
-- varargs; k whose 8k wraps to just past the frame (-2^31 + 20,
-- -2^29 + 20 and their kin); large k (2^27 - 1, 2^27, 2^27 + 1, 2^28 - 2,
-- 2^28 and more, to 2^31 - 1); k out of int32 (2^31 and more, -2^31 - 1
-- and less, -3 * 2^30 + 20); fractions; and for st, " 2 ", "0x2", "2.0",
-- "1e1", "-0x1", "#", "#x", "x" and "".
--
-- THE REFERENCE is -joff: run-bitjit.sh compares the whole output of each
-- JIT option set with it, results and raised errors (by kind: RANGE for
-- "index out of range", NUMBER, NOINT, INEXACT(<op>)).  Part "puc" prints
-- the cases and probes whose meaning PUC Lua 5.3.6 shares: LuaJIT reads k
-- through lj_lib_checkint (lj_num2int: a fraction truncated, every value
-- out of int32 read as -2^31, so a raise), 5.3.6 through
-- luaL_checkinteger (a fraction raises, k >= 2^31 gives nothing), so part
-- puc keeps integral k below 2^31 (bitop/twin.lua's header).  PUC's
-- output of part puc must equal -joff's.
--
-- THE INSTRUMENT (stderr, LuaJIT with the JIT on).  In every completed
-- trace that starts in a case's f, it reads the IR (jit.util.traceir):
-- fr, an SLOAD with IRSLOAD_FRAME (0x02), is rec_varg's select path; selA
-- a guard comparing fr with a constant (path A, and '#' in a call with
-- fewer arguments than parameters); selB a BSHR by 3 of an ADD of fr (B's
-- count, or '#'); selC a guard comparing fr with an ADD of a BSHL by 3
-- (path C); kguard a ULT guard against the constant 2^27 (the fix's
-- guard, which only it emits); convs the CONV int.i64 (mode 0x275) of the
-- bx cases' fold.  And the record-time bound: kmaxbad counts the cases
-- recorded only with a k above 2^27 (v7-K-134217729, p2few-K-134217729,
-- kx-pl) in which a trace through the select path completed (the fix
-- aborts every such recording); kmaxctl counts the kctl control cases
-- recorded with k = 2^27 (v7-K-134217728, p2few-K-134217728, kc-pl) in
-- which one did, of kctl.  One line:
--   #cov cases <n> traced <n> selA <n> selB <n> selC <n> kguard <n> convs <n> kmaxbad <n> kmaxctl <n> kctl <n> jit <on|off>
-- run-bitjit.sh requires, in the default run: jit on, a trace in
-- OCLJ_BITJIT_HOTMIN of the cases, every sel count and kguard at least 1,
-- and kmaxctl equal to kctl (the controls compile, so the count can see a
-- select trace); and kmaxbad 0 in every run.
--
-- Prints one line per case, "<case><TAB><results>": n for nil, a number as
-- %.17g, E:<kind> for a raise.  Exit 2 (INSTRUMENT) if a text is not what
-- it says.  No case reads or writes memory through a pointer: every probe
-- reaches select through Lua values only (FFI is off), and on a build
-- without the fix path C loads nothing and path B's load sits behind its
-- unsigned ABC (lj_record.c rec_varg, read 2026-10-20).  This file holds
-- no backslash: a newline is NL, a tab TAB, a backslash BS.
local NL, TAB, BS = string.char(10), string.char(9), string.char(92)
local dir = (arg and arg[0] or ""):match("^(.*[/" .. BS .. "])") or ""
local TW = dofile(dir .. "twin.lua")
local PART = arg and arg[1] or "all"
local fmt = string.format
if PART ~= "all" and PART ~= "puc" then
  print("INSTRUMENT: t_select's part is all or puc, not " .. tostring(PART))
  os.exit(2)
end
local PUC = PART == "puc"

local KMAX = 2^27  -- OCLJ_SELECT_KMAX

-- The kind of a raise, the same words on both VMs.
local function KIND(e)
  local m = tostring(e)
  if m:find("index out of range", 1, true) then return "RANGE" end
  if m:find("number expected", 1, true) then return "NUMBER" end
  if m:find("has no integer representation", 1, true) then return "NOINT" end
  local op = m:match("result of '([^']+)' has more than 53 significant bits")
  if op then return "INEXACT(" .. op .. ")" end
  m = m:gsub("^[^" .. NL .. "]-:%d+: ", "")
  return "OTHER:" .. (m:gsub("[,%c]", "/"))
end

-- Values of k the two VMs read alike (part puc): integral, below 2^31.
local function agrees(v)
  if type(v) == "string" then
    local n = tonumber(v)
    if n == nil then return true end
    v = n
  end
  return v == math.floor(v) and v < 2^31
end

-- A number as a string both VMs read as that number.
local NONINT = { [0.5] = "0.5", [-0.5] = "-0.5", [1.5] = "1.5", [2.5] = "2.5",
  [-2.5] = "-2.5", [7.5] = "7.5", [1e-300] = "1e-300", [-1e-300] = "-1e-300" }
local function numstr(v)
  if v == math.floor(v) then return fmt("%.0f", v) end
  return assert(NONINT[v], "no string for a probe")
end

local LONG60 = {}
for j = 1, 60 do LONG60[j] = 100 + j end
local SHAPES = {
  { name = "v7", P = 0, alists = { { 11, "b", 13, true, 15, 16.5, 17 }, { 11, 12 }, {}, LONG60 } },
  { name = "v0", P = 0, alists = { {}, { 11, 12, 13 }, { 11 } } },
  { name = "p2", P = 2, alists = { { 1, 2, 31, 32, 33 }, { 1 }, {}, { 1, 2 } } },
  { name = "p2few", P = 2, alists = { { 1 }, {}, { 1, 2, 31, 32, 33 }, { 1, 2 } } },
}

local P_ABS = {
  -2^29 + 20, -2^30 + 20, -3 * 2^29 + 20, -2^31 + 20, -2^29 + 100, -2^31 + 100,
  -2^31 + 1000, -2^31, -2^31 + 1, -2^28, -2^28 - 1, -2^27, -2^27 - 1, -65536, -1000, -100,
  2^27 - 1, 2^27, 2^27 + 1, 2^28 - 2, 2^28, 2^28 + 3, 2^29 + 5, 2^29 + 20, 2^30,
  2^30 + 20, 2^31 - 1, 65500, 65501, 1000, 100,
  2^31, 2^31 + 20, 2^31 + 999, 2^32, 2^32 + 2, 2^32 + 20, -2^31 - 1, -2^31 - 20,
  -3 * 2^30 + 20, -3 * 2^30 + 21, -2^32 + 3, 2^53, -2^53,
  0.5, -0.5, 1.5, 2.5, -2.5, 7.5, 1e-300, -1e-300,
}
local P_STR = { " 2 ", "0x2", "2.0", "1e1", "-0x1", "#", "#x", "x", "" }

-- The probe values of k for a shape's argument list (m varargs, m < 0
-- when the call passes fewer arguments than the fixed parameters).
local function probes(m, str)
  local seen, out = {}, {}
  local function add(v)
    if not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  for _, v in ipairs({ 1, 2, 3, m - 1, m, m + 1, m + 2, -1, -2, -3, -m, -(m + 1), -(m + 2), 0 }) do add(v) end
  for _, v in ipairs(P_ABS) do add(v) end
  local res = {}
  for _, v in ipairs(out) do
    if not PUC or agrees(v) then res[#res + 1] = str and numstr(v) or v end
  end
  if str then
    for _, s in ipairs(P_STR) do res[#res + 1] = s end
  end
  return res
end

-- The text of a case.  The loop is in f, a vararg function with the shape's
-- fixed parameters, which registers itself in REG.f for the instrument.
local TEXT = [[
local SEG, out, REG = ...
local unpack = unpack or table.unpack
local ks, pos, last
local function f(@PARAMS@...)
  for i = pos, last do
    pos = i + 1
    local k = @K@
    @CALL@
    out[#out + 1] = v == nil and 'n' or v
  end
end
REG.f = f
for s = 1, #SEG do
  local sg = SEG[s]
  @SETUP@
  while pos <= last do
    local ok, e = pcall(f, unpack(sg.args, 1, sg.n))
    if not ok then out[#out + 1] = "E:" .. REG.KIND(e) end
  end
end
]]
local CALL = {
  p = "local v = select(k, ...)",
  s = "local v; if i % 3 == 0 then v = select(k, ...) else v = select(k, ...) end",
}
local function text(P, k, wrap, setup)
  return (TEXT:gsub("@(%u+)@", { PARAMS = P == 2 and "a, b, " or "", K = k, CALL = CALL[wrap], SETUP = setup }))
end
local SRC = {
  pl = "ks[i]", st = "ks[i]", ap = "ks[i] + 1000", am = "ks[i] - 1000", an = "ks[i] - 1073741804",
  bx = "X(ks[i] * 4294967296 ~>> 32)",
}
local CADD = { pl = 0, st = 0, ap = 1000, am = -1000, an = -1073741804, bx = 0 }
do
  local p = TW.check("bx", SRC.bx)
  if p then print("INSTRUMENT: t_select's X-wrapped text is wrong: " .. p); os.exit(2) end
end

-- THE INSTRUMENT.
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local cov = { cases = 0, traced = 0, selA = 0, selB = 0, selC = 0, kguard = 0, convs = 0,
  kmaxbad = 0, kmaxctl = 0, kctl = 0, jit = hasjit and "on" or "off" }
local REG = { KIND = KIND }
local cur, hit, selhit = nil, false, false
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
  local CMP = {}
  for _, n in ipairs({ "LT", "GE", "LE", "GT", "ULT", "UGE", "ULE", "UGT" }) do
    if not OPS[n] then print("INSTRUMENT: jit.vmdef names no " .. n); os.exit(2) end
    CMP[OPS[n]] = true
  end
  for _, n in ipairs({ "SLOAD", "ADD", "BSHL", "BSHR", "CONV" }) do
    if not OPS[n] then print("INSTRUMENT: jit.vmdef names no " .. n); os.exit(2) end
  end
  local function scan(tr)
    local nins = jutil.traceinfo(tr).nins
    local ir = {}
    for ref = 1, nins do
      local _, ot, op1, op2 = jutil.traceir(tr, ref)
      if not ot then break end
      ir[ref] = { o = math.floor(ot / 256), g = ot % 256 >= 128, op1 = op1, op2 = op2 }
    end
    local function k(r) if r < 0 then return (jutil.tracek(tr, r)) end end
    local function is(r, o) return r > 0 and ir[r] and ir[r].o == o end
    local fr, c = {}, { fr = 0, selA = 0, selB = 0, selC = 0, kguard = 0, convs = 0 }
    for ref, x in pairs(ir) do
      if x.o == OPS.SLOAD and math.floor(x.op2 / 2) % 2 == 1 then fr[ref] = true; c.fr = c.fr + 1 end
    end
    local function shl3(r) return is(r, OPS.BSHL) and k(ir[r].op2) == 3 end
    for _, x in pairs(ir) do
      if CMP[x.o] and x.g then
        local a, b = x.op1, x.op2
        if fr[b] then a, b = b, a end
        if fr[a] then
          if b < 0 then c.selA = c.selA + 1
          elseif is(b, OPS.ADD) and (shl3(ir[b].op1) or shl3(ir[b].op2)) then c.selC = c.selC + 1 end
        end
        if x.o == OPS.ULT and k(x.op2) == KMAX then c.kguard = c.kguard + 1 end
      elseif x.o == OPS.BSHR and k(x.op2) == 3 and is(x.op1, OPS.ADD) and fr[ir[x.op1].op1] then
        c.selB = c.selB + 1
      elseif x.o == OPS.CONV and x.op2 % 1024 == 629 then
        c.convs = c.convs + 1
      end
    end
    return c
  end
  jit.attach(function(what, tr, func)
    if what == "stop" and cur and func == REG.f then
      if not hit then hit = true; cov.traced = cov.traced + 1 end
      local c = scan(tr)
      if c.fr > 0 then selhit = true end
      for _, n in ipairs({ "selA", "selB", "selC", "kguard", "convs" }) do cov[n] = cov[n] + c[n] end
    end
  end, "trace")
end

-- One case: its text, its segments, and how the instrument reads it (tag
-- kbad: must never compile the select path; kctl: must).
local lines = {}
local function run(name, src, SEG, tag)
  local chunk = assert(load(src, "=" .. name))
  local out = {}
  REG.f = nil
  cur, hit, selhit = name, false, false
  chunk(SEG, out, REG)
  cur = nil
  cov.cases = cov.cases + 1
  if tag == "kbad" and selhit then cov.kmaxbad = cov.kmaxbad + 1 end
  if tag == "kctl" then
    cov.kctl = cov.kctl + 1
    if selhit then cov.kmaxctl = cov.kmaxctl + 1 end
  end
  for j = 1, #out do
    local v = out[j]
    out[j] = type(v) == "number" and fmt("%.17g", v) or tostring(v)
  end
  lines[#lines + 1] = name .. TAB .. table.concat(out, ",")
end
local function seg(args, extra)
  local s = { args = args, n = #args }
  for kk, v in pairs(extra) do s[kk] = v end
  return s
end
local LIST = "ks, pos, last = sg.ks, 1, #sg.ks"

-- A constant k (class K) in a loop of shape sh.
local function constcase(sh, lit)
  local v = lit
  if type(lit) == "string" then v = lit:sub(2, -2) end
  if PUC and not agrees(v) then return end
  local SEG = { seg(sh.alists[1], { count = 150 }) }
  for _, al in ipairs(sh.alists) do SEG[#SEG + 1] = seg(al, { count = 3 }) end
  local lt = type(lit) == "string" and lit or (lit == math.floor(lit) and fmt("%.0f", lit) or fmt("%.17g", lit))
  local tag = (lit == KMAX + 1 and "kbad") or (lit == KMAX and "kctl") or nil
  local nm = type(lit) == "string" and ("s" .. #v .. v:gsub("%W", "_")) or lt
  run(fmt("%s-K-%s", sh.name, nm), text(sh.P, lt, "p", "pos, last = 1, sg.count"), SEG, tag)
end
-- A runtime k recorded above the bound (KX: the recorder must abort, in
-- every recording, since every value is above it) and at it (KC: the loop
-- compiles, path C, the guard passing).
local KX = { "kx", { KMAX + 1, 2^28, 2^31 - 1, 2^30 + 20 }, "kbad" }
local KC = { "kc", { KMAX }, "kctl" }
local function kcase(kc)
  local sh = SHAPES[1]
  local W = {}
  for j = 1, 200 do W[j] = kc[2][(j - 1) % #kc[2] + 1] end
  local SEG = { seg(sh.alists[1], { ks = W }) }
  for _, al in ipairs(sh.alists) do SEG[#SEG + 1] = seg(al, { ks = { W[1], W[2], W[3] } }) end
  run(kc[1] .. "-pl", text(sh.P, SRC.pl, "p", LIST), SEG, kc[3])
end

-- THE CONTROLS FIRST: the loops recorded with k = 2^27 must compile, and a
-- loop's hot counter is shared with every pc that hashes to its slot, which
-- an aborted recording's penalty raises (lj_trace.c penalty_pc), so they
-- run before any case whose recording aborts (2026-10-20: p2few-K-134217728
-- run after the others compiled nothing in 1 of 8 runs).
kcase(KC)
constcase(SHAPES[1], KMAX)
constcase(SHAPES[4], KMAX)

-- The list cases (sources pl, st, ap, am, an, bx; classes B, C, H).
for _, sh in ipairs(SHAPES) do
  local mrec = #sh.alists[1] - sh.P
  local classes = { { "C", math.max(mrec, 0) + 5 } }
  if mrec >= 2 then table.insert(classes, 1, { "B", 2 }) end
  classes[#classes + 1] = { "H", "#" }
  for _, cl in ipairs(classes) do
    for _, sname in ipairs({ "pl", "st", "ap", "am", "an", "bx" }) do
      local wraps = { "p" }
      if sname == "pl" and cl[1] ~= "H" then wraps[2] = "s" end
      if cl[1] ~= "H" or sname == "pl" or sname == "st" then
        local function kv(v)  -- what ks holds for a value v of k
          if type(v) == "string" then return v end
          if sname == "st" then return numstr(v) end
          return v - CADD[sname]
        end
        for _, w in ipairs(wraps) do
          local r = cl[2]
          local W = {}
          for j = 1, 150 do W[j] = kv(r) end
          local SEG = { seg(sh.alists[1], { ks = W }) }
          for _, al in ipairs(sh.alists) do
            local ks = {}
            for _, p in ipairs(probes(#al - sh.P, sname == "st")) do
              ks[#ks + 1] = kv(p); ks[#ks + 1] = kv(r); ks[#ks + 1] = kv(r)
            end
            SEG[#SEG + 1] = seg(al, { ks = ks })
          end
          run(fmt("%s-%s-%s-%s", sh.name, cl[1], sname, w), text(sh.P, TW.text(SRC[sname]), w, LIST), SEG)
        end
      end
    end
  end
end

-- The loop index as k (sources iap, ian): i + C over ranges of i.
for _, sh in ipairs({ SHAPES[1], SHAPES[4] }) do
  local mrec = #sh.alists[1] - sh.P
  for _, c in ipairs({ 1000, -1073741804 }) do
    local r = math.max(mrec, 0) + 5
    local SEG = { seg(sh.alists[1], { from = r - c, to = r - c + 149 }) }
    for _, al in ipairs(sh.alists) do
      local m = #al - sh.P
      local R = { { -3, 3 }, { m - 1, m + 2 }, { -2^31 + 18, -2^31 + 22 }, { 2^28, 2^28 + 2 },
        { 2^27 - 1, 2^27 + 1 }, { -3 * 2^30 + 20, -3 * 2^30 + 24 }, { 2^31 + 10, 2^31 + 18 } }
      for _, kr in ipairs(R) do
        if not PUC or (agrees(kr[1]) and agrees(kr[2])) then
          SEG[#SEG + 1] = seg(al, { from = kr[1] - c, to = kr[2] - c })
        end
      end
    end
    run(fmt("%s-C-ia%s", sh.name, c > 0 and "p" or "n"),
      text(sh.P, "i + " .. fmt("%.0f", c), "p", "pos, last = sg.from, sg.to"), SEG)
  end
end

-- The constants (class K), with the record-time bound's constant cases.
local LITS = { 1, 2, 3, 7, 8, 9, 60, 61, 1000, 65501, KMAX - 1, KMAX, KMAX + 1, 2^28 - 2, 2^28,
  2^29 + 5, 2^31 - 1, '"#"', '"2"', '"#x"', -1, -3, -8, 0, 2.5, 2^31, -2^31 + 20 }
for _, sh in ipairs({ SHAPES[1], SHAPES[4] }) do
  for _, lit in ipairs(LITS) do
    if lit ~= KMAX then constcase(sh, lit) end  -- KMAX: the controls, run first
  end
end
kcase(KX)

io.write(table.concat(lines, NL), NL)
io.stderr:write(fmt("#cov cases %d traced %d selA %d selB %d selC %d kguard %d convs %d kmaxbad %d kmaxctl %d kctl %d jit %s",
  cov.cases, cov.traced, cov.selA, cov.selB, cov.selC, cov.kguard, cov.convs, cov.kmaxbad, cov.kmaxctl, cov.kctl, cov.jit) .. NL)
