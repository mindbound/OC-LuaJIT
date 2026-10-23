-- test/native/bitop/t_cserev.lua -- the CSE twins, reverse order, in the
-- two shapes that cannot put an int64 ref into a Lua slot: values and IR.
-- lj_opt_cse matched an instruction by its opcode and operands only and
-- returned the existing one with its own type (lj_opt_fold.c:2675 in the
-- build copy at 1a13bed; "build copy" below means build/native's
-- luajit-windows-x86_64/src, luajit.exe f4038cd6, the unfixed base), so when
-- our int64 operator comes first (oclj_bitop_rec.c; on x64 it takes the int
-- loop index directly, simplify_conv_sext's LEFTFOLD) a 32-bit recorder that
-- emits the same opcode on the same operands later gets our int64
-- instruction back, typed IRT_I64.  The fix, patch-bitop-fold.sh hunk 12,
-- refuses a match when exactly one of the two instructions is IRT_I64 (JIT
-- guide P63, 3.9).  test/native/run-bitjit.sh runs this file (part cse)
-- against -joff under 15 option sets, and against PUC 5.3.6.  Written
-- 2026-10-23.
--
--   <vm> t_cserev.lua      (LuaJIT: LUA_PATH must reach the build's src/jit/vmdef.lua)
--
-- ONLY SHAPES WITH NO SLOT (the user's decision D2, 2026-10-23).  Where a
-- 32-bit recorder stores its result in a slot (the bit library's
-- J->base[0], an inner for loop's index slots), a snapshot would carry an
-- int64 ref that snap_restoreval has no case for: crash-class on a build
-- without the fix, and never written or run here, on any build.  The two
-- shapes below hand our int64 instruction only to 32-bit consumers that are
-- C locals of their recorder, never to J->base, so on a build without the
-- fix the pair merges and nothing reaches a slot.  The argument, read in the
-- build copy before this file first ran on build/native:
--
-- R5, select(j, ...) with j beyond the varargs, after j << 3 (the design's
-- G1r).  The loop is in the vararg chunk itself, so its root trace has
-- framedepth 0 and rec_varg takes its "unknown number of varargs" branch.
-- select_detect (lj_record.c:2052): tridx is the slot's TRef, the int loop
-- index (:2053), not converted since it is an int; tr starts as TREF_NIL
-- (:2054).  j > the vararg count at record time, so the path beyond the
-- varargs: tmp2 = ADD tridx, -1 and its ULT guard (:2080), then
-- tmp2 = BSHL tridx, +3 (:2081) -- the merge, which hands back our int64
-- BSHL -- then tmp = ADD tmp2, frofs (:2082), an int ADD of two refs that
-- no fold rule rewrites (ADD any KINT: simplify_intadd_k, k = frofs is not
-- 0; reassoc_intarith_k needs an ADD as fleft), and the guard LT fr, tmp
-- (:2086).  tr is never set on this path, so J->base[dst-2-LJ_FR2] = tr is
-- nil (:2097) and maxslot drops to dst-1-LJ_FR2 (:2098).  tmp2 and tmp are
-- C locals: our int64 BSHL reaches one int ADD, which reaches one guard.
-- Neither enters J->base, so no snapshot names either.  On x64 the int ADD
-- reads the register's low 32 bits, the 32-bit BSHL's own value, so the
-- guard compares what it compares on a fixed build.
--
-- R6, string.byte(S, i + i), string.sub(S, i + i, i + i) and
-- string.byte(S, i * 2), after i << 1 (the design's G2r; i << 1 is our
-- int64 ADD i, i, simplify_shift_ik).  recff_string_range (lj_ffrecord.c:
-- 863) narrows its start argument: trstart = lj_opt_narrow_toint(J,
-- J->base[1]) (:888 for byte, :873 for sub).  For i + i, an int ADDOV i, i,
-- narrow_stripov emits ADD i, i (lj_opt_narrow.c:440) -- the merge -- and
-- caches the ADDOV's narrowing as our instruction (:442); for i * 2, a num
-- ADD of two CONV num.int i (simplify_nummuldiv_k), the CONV int.num that
-- lj_opt_narrow_toint emits (:471) reaches narrow_convert, whose
-- narrow_conv_emit emits ADD i, i (:394) -- the merge -- caches it (:397)
-- and returns it as the CONV's fold result (:401, :419).  Either way
-- trstart is our int64 ADD, a C local, and J->base[1] keeps the ADDOV or the
-- num ADD.  string.byte with one index has trend = trstart (:894);
-- string.sub's end, the same ADDOV, hits the cache (lj_opt_narrow.c:435)
-- and is the same TRef (:879).  So the one-character case (:904): tr = ADD
-- trstart, -1 (:905; reassoc_intarith_k reads fleft's op2, i, no KINT;
-- simplify_intadd_k, -1 is not 0), ULT tr, trlen (:906), STRREF (:907), and
-- J->base[0] = an SNEW, a string (:909), or an XLOAD u8 (:911).  Our int64
-- ADD reaches one int ADD, which reaches a guard and a STRREF; the slot
-- gets a string or a byte.  The cache entry is read only by a later
-- narrowing of the same ADDOV or num ADD in the same trace, and these loops
-- have none (the counter k's narrowing has its own keys).  On x64 the int
-- ADD reads the low 32 bits, i + i's own value (2i < 2^31 here).
--
-- Both: the merge happens at record time, in the pre-roll.  loop_unroll
-- re-emits the pre-roll in order with the body's operands (lj_opt_loop.c:
-- 330); the pre-roll holds no 32-bit BSHL or ADD on these operands (it was
-- merged), so in these loops, whose pairs' operands are the loop index
-- itself, the copy emits no new pair: the copied int ADD takes the body's
-- int64 instruction as its op1, again into no slot, and a body instruction
-- that matched a pre-roll one of another type would raise TYPEINS (the
-- loop-carried branch, :334, raising it at :352), an abort, not a store.
-- (In general the copy can form a pair that record time did not, from
-- operands that differ there and coincide in the copy, such as a slot
-- carried across iterations; nothing type-checks a match between two body
-- instructions, and the fix covers it, since every copied instruction goes
-- through lj_opt_cse.  bitop/t_csefwd.lua's case copy is one, forward.)
-- Snapshots record J->base's TRefs, and none of these slots holds the int64
-- instruction, so no exit restores one; the IR read below counts it anyway
-- (i64slot, 0 on every build).
-- What this file can show on a build without the fix: the merge (rserved,
-- and split 0), so it FAILs there; on a fixed build the two instructions
-- stand apart (split at least 1).
-- MEASURED (2026-10-23, run only after the argument above was written;
-- scratch claude-tmp/oclj/csetwin/round/impl-tests/runs/): on build/native
-- at 1a13bed (luajit.exe f4038cd6) each reverse case reads rserved 2 (the
-- pre-roll's int ADD and the loop copy's), split 0 and i64slot 0, and its
-- values equal -joff's and the reference in all 15 sets, on Windows and in
-- AlmaLinux 8 (luajit cb68e454, whose cited sources are the Windows build
-- copy's byte for byte): the pairs merge and nothing reaches a slot, as
-- read.  On a prototype with the fix (lj_opt_fold.o a6c5fcc2, not the
-- shipped object) split 2 and rserved 0 in every set that judges them, and
-- on one with CSEFWD's text (forward merges only) the same.
--
-- THE CASES, each its own loop prototype (load), called three times, our
-- operator first in program order (checked below):
--   rc-sel, rc-shl1   controls: our operator alone, in R5's and R6's shapes
--   rp-sel, rp-byte   controls: the 32-bit producer alone
--   r5-sel            j << 3, then select(j, ...), j from 6, 5 varargs
--   r6-byte           i << 1, then string.byte(S, i + i)
--   r6-sub            i << 1, then string.sub(S, i + i, i + i)
--   r6-mul            i << 1, then string.byte(S, i * 2)
-- Each value is checked against a plain-arithmetic reference (this file
-- exits 1 otherwise, under any VM), and run-bitjit.sh compares each JIT
-- option set's fields 1-2 with -joff's, and PUC 5.3.6's whole output with
-- -joff's: nothing here means otherwise on PUC (select beyond the varargs
-- returns nothing on both, and every index is small).
--
-- THE IR (LuaJIT with the JIT on), read by bitop/cseir.lua's reader (its
-- header defines served, split, rserved, direct and i64slot), summed over
-- the traces that complete in the case's loop:
--   every case   a trace; served 0; rserved 0; i64slot 0
--   r5, r6       where fold, CSE and narrowing are on: direct at least 1
--                (our operator took the index directly), split + rserved at
--                least 1 (the producer met our operand), and split at least
--                1 (with rserved 0 above: the two kept apart)
--   rc           where the same holds: direct at least 1; split 0
--   rp           split 0
-- Under -O0, -O-fold, -O-cse, -O1 and -O-narrow no pair forms or merges
-- (no LEFTFOLD, no CSE, or the index stays a double), and only the
-- every-case checks apply.
--
-- Prints one line per case, "<case><TAB><call 1>;<call 2>;<call 3><TAB><IR>",
-- each call as bitop/t_csefwd.lua prints one, the IR
--   traces=<n> direct=<n> served=<n> split=<n> rserved=<n> i64slot=<n> <ok|FAILED (why)>
-- or "-" without the JIT (-joff, PUC); with the JIT, the summary
--   t_cserev: <k> of <n> cases ok (fold <on|off>, cse <on|off>, narrow <on|off>, loop <on|off>); reverse cases judged <j> of <r>
-- which run-bitjit.sh requires.  Exit 0 all ok, 1 a value unlike its
-- reference or a case FAILED, 2 (INSTRUMENT) a text is not what it says or
-- the reader is missing.  Value-level only: tables of numbers and strings,
-- nothing through a pointer (FFI is off).  This file holds no backslash: a
-- newline is NL, a tab TAB.
local NL, TAB, BS = string.char(10), string.char(9), string.char(92)
local fmt, floor = string.format, math.floor
local unpack = unpack or table.unpack

local function dig(t, n)  -- bitop/t_csefwd.lua's digest
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
local function mkstr(n, a, b)
  local t = {}
  for j = 1, n do t[j] = string.char((j * a + b) % 256) end
  return table.concat(t)
end
local S8 = mkstr(800, 61, 7)
local N = 400

local function jloop(body)  -- in the vararg chunk: j from 6, beyond its 5 varargs
  return "local O, BO, S = ..." .. NL .. "local k, x = 0, 0" .. NL .. "for j = 6, 405 do" .. NL ..
    body .. NL .. "end" .. NL .. "return k, x"
end
local function iloop(body)
  return "local O, BO, S = ..." .. NL .. "local k = 0" .. NL .. fmt("for i = 1, %d do", N) .. NL ..
    body .. NL .. "end" .. NL .. "return k"
end

-- kind: ctl (ours alone), prod (the producer alone), rev (ours, then the producer).
local CASES = {
  { name = "rc-sel", kind = "ctl", src = jloop("  local c = j << 3" .. NL .. "  k = k + 1; O[k] = c"),
    ref = function(k) return (k + 5) * 8 end },
  { name = "rc-shl1", kind = "ctl", src = iloop("  local c = i << 1" .. NL .. "  k = k + 1; O[k] = c"),
    ref = function(k) return 2 * k end },
  { name = "rp-sel", kind = "prod",
    src = jloop("  local v = select(j, ...)" .. NL .. "  if v ~= nil then x = x + 1 end" .. NL .. "  k = k + 1; O[k] = j"),
    ref = function(k) return k + 5 end },
  { name = "rp-byte", kind = "prod", src = iloop("  local a = string.byte(S, i + i)" .. NL .. "  k = k + 1; O[k] = a"),
    ref = function(k) return S8:byte(2 * k) end },
  { name = "r5-sel", kind = "rev",
    src = jloop("  local c = j << 3; local v = select(j, ...)" .. NL .. "  if v ~= nil then x = x + 1 end" .. NL ..
      "  k = k + 1; O[k] = c"),
    ref = function(k) return (k + 5) * 8 end },
  { name = "r6-byte", kind = "rev", src = iloop("  local c = i << 1; local a = string.byte(S, i + i)" .. NL ..
      "  k = k + 1; BO[k] = a; O[k] = c"),
    ref = function(k) return 2 * k end, bref = function(k) return S8:byte(2 * k) end },
  { name = "r6-sub", kind = "rev", src = iloop("  local c = i << 1; local a = string.sub(S, i + i, i + i)" .. NL ..
      "  k = k + 1; BO[k] = a; O[k] = c"),
    ref = function(k) return 2 * k end, bref = function(k) return S8:byte(2 * k) end },
  { name = "r6-mul", kind = "rev", src = iloop("  local c = i << 1; local a = string.byte(S, i * 2)" .. NL ..
      "  k = k + 1; BO[k] = a; O[k] = c"),
    ref = function(k) return 2 * k end, bref = function(k) return S8:byte(2 * k) end },
}

-- The texts' own check: in each reverse case our operator comes first, and
-- the producer is select or string.byte/sub on the index, nothing that
-- stores to a slot of its own: no text names "bit" at all (the bit library,
-- an alias of it), and each holds exactly one "for " (the loop jloop or
-- iloop writes, never an inner one, however spelled).  It runs before any
-- case is loaded, so a refused text never runs.
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
    local src = C.src
    if count(src, "bit") > 0 or count(src, "for ") ~= 1 then bad[#bad + 1] = C.name .. " (a slot shape)" end
    if C.kind == "rev" then
      local pc = src:find("local c = ", 1, true)
      local pp = src:find("select(", 1, true) or src:find("string.", 1, true)
      if not (pc and pp and pc < pp) then bad[#bad + 1] = C.name .. " (producer first)" end
    end
  end
  if #bad > 0 then
    print("INSTRUMENT: t_cserev's texts: " .. table.concat(bad, ", "))
    os.exit(2)
  end
end

-- THE INSTRUMENT (LuaJIT with the JIT on).
local hasjit = type(jit) == "table" and jit.status and jit.status() and jit.attach
local LIB, FLAG = nil, {}
if hasjit then
  local dir = (arg and arg[0] or ""):match("^(.*[/" .. BS .. "])") or ""
  local chunk, lib = loadfile(dir .. "cseir.lua")
  local okl = false
  if chunk then okl, lib = pcall(chunk, "lib") end
  if not (okl and type(lib) == "table") then
    print("INSTRUMENT: no IR reader (bitop/cseir.lua as a library): " .. tostring(lib))
    os.exit(2)
  end
  LIB, FLAG = lib, lib.flags
end

local function judge(C, c)
  local why = {}
  local needs = FLAG.fold and FLAG.cse and FLAG.narrow
  if c.traces == 0 then why[#why + 1] = "no trace" end
  if c.served > 0 then why[#why + 1] = "served " .. c.served .. ": a 32-bit instruction stands in for our int64 operator" end
  if c.rserved > 0 then why[#why + 1] = "rserved " .. c.rserved .. ": a 32-bit instruction consumes our int64 one (the reverse merge)" end
  if c.i64slot > 0 then why[#why + 1] = "i64slot " .. c.i64slot .. ": a snapshot names an int64 instruction" end
  if C.kind == "rev" and needs then
    if c.direct == 0 then why[#why + 1] = "direct 0: our operator never took the index directly" end
    if c.split + c.rserved == 0 then why[#why + 1] = "split and rserved 0: the producer never met our operand" end
    if c.split == 0 then why[#why + 1] = "split 0: no 32-bit instruction beside our int64 one" end
  end
  if C.kind == "ctl" and needs and c.direct == 0 then why[#why + 1] = "direct 0: the instrument sees no direct operand" end
  if C.kind ~= "rev" and c.split > 0 then why[#why + 1] = "split " .. c.split .. " in a case with no twin" end
  return why, C.kind == "rev" and needs
end

local lines, nbad, nfail, njudged, nrev = {}, 0, 0, 0, 0
for _, C in ipairs(CASES) do
  local f = assert(load(C.src, "=cserev-" .. C.name))
  if LIB then LIB.watch(f) end
  local calls, cbad = {}, 0
  for call = 1, 3 do
    local O, BO = {}, {}
    for k = 1, N do O[k] = 0; BO[k] = 0 end  -- pre-sized: no growth exits
    local n, x = f(O, BO, S8, 1, 2)          -- 5 varargs for the select loops
    if n ~= N then
      print(fmt("INSTRUMENT: case %s ran %s iterations, not %d", C.name, tostring(n), N))
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
    nbad = nbad + cb + cbb
    cbad = cbad + cb + cbb
  end
  local line = C.name .. TAB .. table.concat(calls, ";")
  if LIB then
    local c = LIB.take()
    local why, judged = judge(C, c)
    if cbad > 0 then why[#why + 1] = cbad .. " values unlike the reference" end
    if C.kind == "rev" then nrev = nrev + 1 end
    if judged then njudged = njudged + 1 end
    if #why > 0 then nfail = nfail + 1 end
    line = line .. TAB .. fmt("traces=%d direct=%d served=%d split=%d rserved=%d i64slot=%d %s",
      c.traces, c.direct, c.served, c.split, c.rserved, c.i64slot,
      #why == 0 and "ok" or ("FAILED (" .. table.concat(why, "; ") .. ")"))
  else
    line = line .. TAB .. "-"
  end
  lines[#lines + 1] = line
end
io.write(table.concat(lines, NL), NL)
if LIB then
  print(fmt("t_cserev: %d of %d cases ok (fold %s, cse %s, narrow %s, loop %s); reverse cases judged %d of %d",
    #CASES - nfail, #CASES, FLAG.fold and "on" or "off", FLAG.cse and "on" or "off",
    FLAG.narrow and "on" or "off", FLAG.loop and "on" or "off", njudged, nrev))
end
os.exit((nbad == 0 and nfail == 0) and 0 or 1)
