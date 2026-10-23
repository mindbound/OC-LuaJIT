-- test/native/bitop/cseir.lua -- the CSE twins read from the compiled traces.
-- lj_opt_cse matched an instruction by its opcode and operands only and
-- returned the existing one with its own type, so on x64, where
-- simplify_conv_sext hands our int64 operators the int loop index or a
-- string.byte value directly, a 32-bit instruction on the same operands
-- served our operator (the CSE twins; JIT guide P63, 3.9).  The fix,
-- patch-bitop-fold.sh hunk 12, refuses a match when exactly one of the two
-- instructions is IRT_I64; a refused match emits what -O-cse emits.  Where
-- the served value happens to be right (the in-game families) only the IR
-- shows the merge, so this file counts it, keyed on operands (JIT guide
-- P56), in the loops of bitop/t_csefwd.lua (it loads their list from that
-- file), the forward order only: the 32-bit producer first.
-- test/native/run-bitjit.sh runs it (part cse).  Written 2026-10-23.
--
--   luajit [options] cseir.lua      (LUA_PATH must reach the build's src/jit/vmdef.lua)
--
-- THE COUNTS, per case, summed over the traces that complete in its loop,
-- each instruction read through jit.util.traceir and each snapshot through
-- jit.util.tracesnap.  "Our opcodes" are BNOT, BAND, BOR, BXOR, BSHL, BSHR,
-- BSAR and ADD (simplify_shift_ik's x << 1 ==> x + x); a "32-bit bit
-- instruction" is one of them not typed i64, an ADD only when its op2 is
-- an instruction (ADD idx, k is a valid stand-in, simplify_conv_sext's).
--   served   our operator served by a 32-bit instruction, the defect's
--            signature: a marked CONV num.i64 (op2 & 0x7ff = 0x5d5, a
--            result's d) whose operand is a 32-bit bit instruction, or an
--            i64 instruction of our opcodes with one as an operand (op1;
--            op2 too for BAND, BOR, BXOR and ADD, never a shift's count):
--            the nested case (i & m) << k and a served value fed on.  The
--            valid int operands of our operators are SLOAD, XLOAD and
--            ADD idx, k, none of which counts.
--   split    an i64 and a non-i64 instruction with the same opcode, op1 and
--            op2: the pair, kept apart (the fix's signature)
--   rserved  a non-i64 instruction other than a CONV with an i64 operand of
--            our opcodes: a 32-bit consumer handed our int64 instruction
--            (the reverse merge; bitop/t_cserev.lua's, 0 here)
--   direct   i64 instructions of our opcodes with a non-i64 instruction as
--            a value operand: our operator took an int directly (the
--            LEFTFOLD, or a served value fed on)
--   i64slot  snapshot entries that name a non-constant i64 instruction:
--            slots and snapshots hold only d or ints (JIT guide 9.6, S6),
--            measured here on these shapes
-- pre = direct + served: our operator met an int operand directly, which
-- every pair case needs before it can merge or split.
--
-- THE JUDGEMENT, per case (every reason is listed, none stops the others):
--   every case     a trace; served 0; rserved 0; i64slot 0
--   pair, eq       where fold, CSE and (for an index operand) narrowing are
--                  on: pre at least 1 (the pair formed) and split at least 1
--   ctl            where the same holds: direct at least 1 (the instrument
--                  sees our operator on a direct int)
--   bit, same, c1, ctl   split 0 (no twin; same-type pairs merge)
-- Two cases' pairs form in one place only, so they are judged there: copy
-- only where the loop optimisation is on (the loop copy), side and its
-- control ctl-side only where a trace compiled our operator, pre at least
-- 1 (a side trace, past a branch the root trace never records; under
-- -Omaxside=0 that side trace is a stub that links to the interpreter).
-- On a build without the fix (build/native at 1a13bed, luajit.exe f4038cd6)
-- every pair and eq case where the pair forms reads served at least 1 and
-- split 0, so this file FAILs there in every set it runs; with the fix
-- served is 0 and split at least 1.  Under -O0 and -O-fold no pair forms
-- (no LEFTFOLD), and under -O-cse none merges, so split reads at least 1 on
-- every build: the file refuses those sets (INSTRUMENT, exit 2; P61).
-- Under -O1 and -O-narrow the loop index stays a double, so only u8sh30's
-- and side's pairs form (byte operands; copy's needs the index narrowed
-- too) and the others are not judged for pre and split.
-- MEASURED (2026-10-23; scratch claude-tmp/oclj/csetwin/round/impl-tests/
-- runs/, ff/, and the fixer's round/fix/runs/, fix/alma1/): on build/native
-- every pair and eq case reads served 2 (the pre-roll's and the loop
-- copy's; copy and side 1, the copy's and the side trace's) and split 0,
-- rserved and i64slot 0: 20 FAILED a set, 19 under -O-loop and the two
-- -Omaxside=0 sets, 2 under -O1 and -O-narrow, on Windows and in
-- AlmaLinux 8; with the fix (lj_opt_fold.o a6c5fcc2: impl-tests' prototype,
-- five runs before copy and side were added, and the fixer's build b1)
-- served 0 and split 2 (copy 1, side 1 or 2), 32 of 32 ok in all 12 sets.
-- WHICH CHECKS FAIL ALONE: split, on the prototype with split never
-- counted (18 a set, before copy and side); i64slot, with the reader
-- counting NUM refs (every case); the summary line and the default run's
-- "pairs judged", in the runner (PROVED NOTHING).  The copy and side gates
-- above, each removed, FAIL that case on split on the fixed build under
-- -O-loop and -Omaxside=0, where its pair does not form (the fixer's
-- runs/fftests-1).  served never failed alone on a measured build (before
-- copy and side were added): with it never counted, build/native still
-- FAILed 16 cases on pre and split and 2 (nested, chain, whose int64 BAND
-- or BSAR takes the served int directly) on split; it is kept for its
-- message, which names the defect, and side's gate reads it.  rserved
-- fails on t_cserev's reverse cases on build/native, with split.
--
-- Prints one line per case,
--   <case><TAB>r=<d1>,<d2>,<d3><TAB>traces=<n> pre=<n> direct=<n> served=<n> split=<n> rserved=<n> i64slot=<n> <ok|FAILED (why)>
-- (r: the digest of the 5.3 results of each of the three calls), and with
-- -joff "<case><TAB>r=<d1>,<d2>,<d3><TAB>-"; with the JIT on, the summary
--   cseir: <k> of <n> cases ok (fold on, cse on, narrow <on|off>, loop <on|off>); pairs judged <j> of <p>
-- which run-bitjit.sh requires (a JIT-off run prints none and reads
-- nothing; JIT guide 11.5c).  Exit 0 every case ok (or the JIT off), 1 a
-- case FAILED, 2 the instrument cannot test (INSTRUMENT).  Loaded as
-- loadfile(...)("lib"), it returns the reader (a table: flags, scan, watch,
-- take) or a string saying why there is none, and runs nothing; t_csefwd.lua
-- and t_cserev.lua use it so.  Value-level only: the loops read and write
-- Lua tables, nothing through a pointer (FFI is off).  This file holds no
-- backslash: a newline is NL, a tab TAB.
local NL, TAB, BS = string.char(10), string.char(9), string.char(92)
local fmt, floor = string.format, math.floor
local MODE = ...

-- THE READER.
local function mklib()
  local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
  if not hasjit then return "the JIT is off" end
  local okv, vmdef = pcall(require, "jit.vmdef")
  local oku, jutil = pcall(require, "jit.util")
  if not (okv and oku) then return "no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)" end
  local OPS = {}
  for o = 0, #vmdef.irnames / 6 - 1 do
    OPS[(vmdef.irnames:sub(o * 6 + 1, o * 6 + 6):gsub(" +$", ""))] = o
  end
  for _, nm in ipairs({ "BNOT", "BAND", "BOR", "BXOR", "BSHL", "BSHR", "BSAR", "ADD", "CONV" }) do
    if not OPS[nm] then return "jit.vmdef names no " .. nm .. " IR op" end
  end
  -- 1: one value operand; 2: two; 3: a shift (op2 is the count)
  local KIND = { [OPS.BNOT] = 1, [OPS.BAND] = 2, [OPS.BOR] = 2, [OPS.BXOR] = 2, [OPS.ADD] = 2,
    [OPS.BSHL] = 3, [OPS.BSHR] = 3, [OPS.BSAR] = 3 }
  local I64 = 21                -- IRT_I64
  local M_D = 1493              -- 0x5d5: CONV num.i64, marked exact (a result's d)
  local SNAPEND = 4278190080    -- SNAP(255, 0, 0), tracesnap's end marker
  local L = { flags = {} }
  local st = { jit.status() }
  for k = 2, #st do L.flags[st[k]] = true end

  function L.scan(tr)
    local info = jutil.traceinfo(tr)
    local I = {}
    for ref = 1, info.nins do
      local m, ot, op1, op2 = jutil.traceir(tr, ref)
      if not m then break end
      I[ref] = { o = floor(ot / 256), t = ot % 32, op1 = op1, op2 = op2,
        r1 = (m % 4 == 0 and op1 > 0) and op1 or nil,             -- an instruction ref
        r2 = (floor(m / 4) % 4 == 0 and op2 > 0) and op2 or nil }
    end
    local c = { served = 0, split = 0, rserved = 0, direct = 0, i64slot = 0 }
    local function intbit(r)  -- a 32-bit bit instruction
      local x = r and I[r]
      return (x and x.t ~= I64 and KIND[x.o] and (x.o ~= OPS.ADD or x.r2 ~= nil)) and true or false
    end
    local function nonwide(r) local x = r and I[r]; return (x and x.t ~= I64) and true or false end
    local twins = {}
    for ref = 1, #I do
      local x = I[ref]
      local kd = KIND[x.o]
      if x.o == OPS.CONV and x.op2 % 2048 == M_D then
        if intbit(x.r1) then c.served = c.served + 1 end
      elseif kd and x.t == I64 then
        if intbit(x.r1) then c.served = c.served + 1 end
        if kd == 2 and intbit(x.r2) then c.served = c.served + 1 end
        if nonwide(x.r1) or (kd == 2 and nonwide(x.r2)) then c.direct = c.direct + 1 end
      elseif x.t ~= I64 and x.o ~= OPS.CONV then
        for _, r in ipairs({ x.r1 or 0, x.r2 or 0 }) do
          local y = I[r]
          if y and y.t == I64 and KIND[y.o] then c.rserved = c.rserved + 1 end
        end
      end
      if kd then
        local key = x.o .. ":" .. x.op1 .. ":" .. x.op2
        local e = twins[key]
        if not e then e = { 0, 0 }; twins[key] = e end
        if x.t == I64 then e[1] = e[1] + 1 else e[2] = e[2] + 1 end
      end
    end
    for _, e in pairs(twins) do
      if e[1] > 0 and e[2] > 0 then c.split = c.split + 1 end
    end
    for sn = 0, info.nexit - 1 do
      local s = jutil.tracesnap(tr, sn)
      if not s then break end
      local n = 2
      while s[n] and s[n] ~= SNAPEND do
        local r = s[n] % 65536 - 32768   -- the entry's ref, unbiased: > 0 an instruction
        if r > 0 and I[r] and I[r].t == I64 then c.i64slot = c.i64slot + 1 end
        n = n + 1
      end
    end
    return c
  end

  -- watch(f): sum the counts of the traces that complete in f until take().
  local cur, acc = nil, nil
  jit.attach(function(what, tr, func)
    if what == "stop" and cur and func == cur then
      local c = L.scan(tr)
      acc.traces = acc.traces + 1
      for k, v in pairs(c) do acc[k] = acc[k] + v end
    end
  end, "trace")
  function L.watch(f)
    cur, acc = f, { traces = 0, served = 0, split = 0, rserved = 0, direct = 0, i64slot = 0 }
  end
  function L.take() local a = acc; cur, acc = nil, nil; return a end
  return L
end

if MODE == "lib" then return mklib() end

-- THE SCRIPT: the forward cases.
local function instrument(msg) print("cseir: INSTRUMENT: " .. msg); os.exit(2) end
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local LIB, FLAG = nil, {}
if hasjit then
  LIB = mklib()
  if type(LIB) ~= "table" then instrument(tostring(LIB)) end
  FLAG = LIB.flags
  if not FLAG.fold then instrument("fold is off (-O0 or -O-fold): no pair forms on any build (P61)") end
  if not FLAG.cse then instrument("cse is off (-O-cse): nothing merges, and split reads at least 1 on every build (P61)") end
end
local dir = (arg and arg[0] or ""):match("^(.*[/" .. BS .. "])") or ""
local chunk, M = loadfile(dir .. "t_csefwd.lua")
local okc = false
if chunk then okc, M = pcall(chunk, "cases") end
if not (okc and type(M) == "table" and M.CASES) then instrument("no case list from bitop/t_csefwd.lua: " .. tostring(M)) end
local unpack = unpack or table.unpack
local S8 = string.rep("x", 800)

local function judge(C, c)
  local why = {}
  local needs = FLAG.fold and FLAG.cse and (FLAG.narrow or not C.narrow)
  -- The pair forms in the loop copy only, or in a side trace only: our
  -- operator is compiled only past i = 300, a branch the root trace never
  -- records, so pre at least 1 says that a side trace compiled it (with
  -- -Omaxside=0 the side trace is a stub that links to the interpreter).
  if C.need == "loop" then needs = needs and FLAG.loop end
  if C.need == "side" then needs = needs and c.direct + c.served > 0 end
  local pairkind = C.kind == "pair" or C.kind == "eq"
  if c.traces == 0 then why[#why + 1] = "no trace" end
  if c.served > 0 then why[#why + 1] = "served " .. c.served .. ": a 32-bit instruction stands in for our int64 operator" end
  if c.rserved > 0 then why[#why + 1] = "rserved " .. c.rserved .. ": a 32-bit instruction consumes our int64 one" end
  if c.i64slot > 0 then why[#why + 1] = "i64slot " .. c.i64slot .. ": a snapshot names an int64 instruction" end
  local pre = c.direct + c.served
  if pairkind and needs then
    if pre == 0 then why[#why + 1] = "pre 0: our operator never met the producer's operand (no pair formed)" end
    if c.split == 0 then why[#why + 1] = "split 0: no int64 instruction beside the 32-bit one" end
  end
  if C.kind == "ctl" and needs and c.direct == 0 then
    why[#why + 1] = "direct 0: our operator never took an int directly (the instrument sees no operand)"
  end
  if not pairkind and c.split > 0 then why[#why + 1] = "split " .. c.split .. " in a case with no twin" end
  return why, pre, pairkind and needs
end

local nbad, ncase, njudged, npair = 0, 0, 0, 0
for _, C in ipairs(M.CASES) do
  local f = assert(load(C.src, "=cseir-" .. C.name))
  if LIB then LIB.watch(f) end
  local d = {}
  for call = 1, 3 do
    local O, BO = {}, {}
    for k = 1, C.n do O[k] = 0; BO[k] = 0 end
    local n = f(O, BO, C.S or S8, unpack(C.args or {}))
    d[call] = fmt("%.17g", M.dig(O, n))
  end
  local line = C.name .. TAB .. "r=" .. table.concat(d, ",")
  ncase = ncase + 1
  if LIB then
    local c = LIB.take()
    local why, pre, judged = judge(C, c)
    if C.kind == "pair" or C.kind == "eq" then npair = npair + 1 end
    if judged then njudged = njudged + 1 end
    line = line .. TAB .. fmt("traces=%d pre=%d direct=%d served=%d split=%d rserved=%d i64slot=%d %s",
      c.traces, pre, c.direct, c.served, c.split, c.rserved, c.i64slot,
      #why == 0 and "ok" or ("FAILED (" .. table.concat(why, "; ") .. ")"))
    if #why > 0 then nbad = nbad + 1 end
  else
    line = line .. TAB .. "-"
  end
  print(line)
end
if hasjit then
  print(fmt("cseir: %d of %d cases ok (fold %s, cse %s, narrow %s, loop %s); pairs judged %d of %d",
    ncase - nbad, ncase, FLAG.fold and "on" or "off", FLAG.cse and "on" or "off",
    FLAG.narrow and "on" or "off", FLAG.loop and "on" or "off", njudged, npair))
end
os.exit(nbad == 0 and 0 or 1)
