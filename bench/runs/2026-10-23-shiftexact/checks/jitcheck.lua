-- jitcheck.lua -- the shift-exactness claim on the built LuaJIT, compiled and
-- interpreted.  Written 2026-10-23 under claude-tmp/oclj/shiftexact/checks/
-- (the checks part of the shift-exactness round).  Revised the same day for
-- the refute part's finding F3 (claude-tmp/oclj/shiftexact/refute/notes.md:
-- the JIT runs showed only JIT == interpreter, sguards and exits gated
-- nothing, WATCH spanned the result loop, exits were not filtered by trace).
-- Revised again the same day (revision 3) for the review of the revised
-- checks, its findings 1, 4 and 5: no snapshot holding a result guard was
-- OWN in any trace this file builds (oclj_rec_bitarg's operand guard shares
-- it, and var's count guards), so the FAIL gate could never fire and the
-- controls never exercised it; the controls' expected exits were about ten
-- times too high; sggate and traced had no negative case.
-- NOT RUN when written or revised: run.sh runs it under -joff and under JIT
-- option sets and compares them.
--
--   luajit [-joff | -O<opts>] jitcheck.lua [nrand [seed]]    (defaults 24 20261023)
--
-- With the JIT on it needs jit.vmdef and jit.util: LUA_PATH must name the
-- build's src/?.lua (run.sh sets it, as test/native/run-bitjit.sh does).
-- It reads no stdin and no file.  Value-level only: no FFI (the build has
-- none), no pointer, no test that forces a crash, no use of LuaJIT's bit
-- library (so nothing meets the type-blind CSE of int and int64 twins, the
-- refute part's F1).  No bit operator appears outside the loaded forms
-- below; the references and the instrument use double arithmetic only.
-- jit.util.tracek is never called (on this no-FFI build a KINT64 constant
-- falls to lj_ir_kvalue's default case).  This file holds no backslash.
--
-- THE CLAIM (JIT guide 3.11, "Shifts of an exact operand"; 3.12, "x << 20,
-- x a double: both guards stay (bound 64) ... the result guard can never
-- fail").  For an int64 x with at most 53 significant bits and a count k in
-- [0, 63], x << k (wrapping; the IR's BSHL) and x ~>> k (the dialect's
-- arithmetic shift, README's "~>>"; the IR's BSAR) have at most 53
-- significant bits, so oclj_rec_bitop's result guard after them
-- (native/luajit/oclj_bitop_rec.c :150-154) never fails, and the
-- interpreter (oclj_bit2num, oclj_bitop.h :101-108) never raises "result of
-- '<<' has more than 53 significant bits (mask each operand to 32 bits
-- first)" for them (the message: oclj_bitop_meta.c :129-134).  model.py
-- checks the arithmetic; this file checks the build: every result against
-- a reference, every raise counted, and, with the JIT on, every exit
-- through a result guard's snapshot counted.
--
-- THE PARTS.  Each case is one form in its own loop prototype (load), run
-- three times over its operand table, every call through pcall, results
-- stored unconditionally into pre-sized tables and read after the loop
-- (P25, P28):
--   shlK    x << K, K = 0..64, on the table's double (mode p: the operand is
--           the double's CONV i64.num) and on an earlier guarded result
--           (mode r: (x ~ z) << K, z = 0 from a table, the operand a BXOR)
--   sarK    x ~>> K, K = 0..64 and 1000 (64 or more records as BSAR 63),
--           modes p and r
--   shlneg  x >> -K and x ~>> -K, K = 1..64: BSHL reached through a negative
--           constant count (oclj_rec_bitop's constant-count paths, :116-134)
--   var     x << k and x ~>> k, k from a table, 0..63 in turn: BSHL and BSAR
--           by a variable count after CONV int.num and ULT 64; modes p, r
--   chain   (x << A) ~>> B, (x ~>> A) << B, (x << A) << B, (x ~>> A) ~>> B
--           for eight (A, B): a shift of a shift's result (reassoc_shift
--           folds the last two; a combined count past 63 gives 0 or BSAR 63)
--   shapes  (x & M) << K and (x & M) >> K, M = 2^53 - 1 or 2^32 - 1, and
--           ((x & M) >> K) << J: simplify_shiftk_andk (lj_opt_fold.c, build
--           copy :1751-1773) rewrites them as (x o K) & (M o K), whose inner
--           shift is a new instruction with no guard of its own, and for
--           >> on a negative x an INEXACT one (x >> K logical), which the
--           next << then shifts; every dialect-level result here is exact,
--           so none may raise and every value must match.  For the proof
--           part: an i64 ref in a trace is not exact merely by being one.
--   ctl-shr     THE CONTROL: x >> K (logical), K = 1..8
--   ctl-shlneg  THE CONTROL: x << -K, K = 1..8 (BSHR by K in the IR)
-- The first six are the LEMMA PARTS (every result exact); the last two the
-- CONTROL PARTS.  Before them, not a part:
--   probe   THE TRACED COUNT'S NEGATIVE CASE: x << 3 on TL with its form
--           function jit.off'd (jit.off(f)), so that every trace its loop
--           starts aborts when it records into f (rec_func_setup, lj_record.c
--           build copy :1907-1912, LJ_TRERR_CJITOFF; or :2710-2712 at an
--           IFUNCF) [S]; its values are checked as a lemma part's are.
-- The lemma parts' operands (TL): x = 2i for i = 1..300, then 0 and every
-- m * 2^e in [-2^63, 2^63) for m in {+-1, +-3, +-(2^52 - 1), +-(2^52 + 1),
-- +-(2^53 - 1)} and nrand seeded random m (|m| < 2^53, a random bit length
-- 1..53, a random sign): every one an exact integral double, built at run
-- time, so the parser folds nothing.  Each loop runs hundreds of
-- iterations past LuaJIT's hotloop (56), so it records in the first call
-- and runs compiled from then on.
-- The controls' operands (TC): x = 2i for i = 1..300, where x >> K is exact,
-- so the loop records and compiles on them (P28, P59); then -1, -3, ...,
-- -15, six times each, which the same compiled loop meets with no branch
-- between.  For each, the logical x >> K is 2^(64-K) - c with
-- c = ceil(|x| / 2^K), whose significant bits are 64 - K - v2(c) >= 56
-- (checked below by that derivation, with no bit operator), so every one
-- must raise "result of '>>' (for x << -K: '<<') has more than 53
-- significant bits (mask each operand to 32 bits first)".
--
-- THE REFERENCE, double arithmetic only, in functions the JIT is turned off
-- for (jit.off(mkref, true)).  x << k: x * 2^k when that lies in
-- [-2^63, 2^63); otherwise, with x = m * 2^e (m odd) and t = e + k, 0 when
-- t >= 64, else (m mod 2^(64-t)) * 2^t, less 2^64 when it is 2^63 or more.
-- M = 2^(64-t) <= 2^53 there is L1's own case B (|m| >= 2^(63-t) and
-- |m| < 2^53), so every step is exact; a larger M is counted and fails the
-- run as INSTRUMENT.  x ~>> k: floor(x / 2^min(k, 63)).  x >> k for x >= 0
-- (the controls' small part): floor(x / 2^k).  Twenty known answers check
-- the reference first.  A self-test then proves the comparator can fail:
-- x << 1 compared with the reference of x << 2 must differ.
--
-- THE GUARDS' EXITS (the JIT on; stderr only).
--   WATCH is true only while a case's loop runs: runcase sets it around each
--   loop(...) call, so the loop that reads OK and R afterwards, which may be
--   traced too, is never counted.
--   A case's traces: a trace whose "start" event names the case's loop or
--   form function while WATCH is true (P29: per-trace state set at start,
--   cleared at "abort", whose number is freed and reused), or whose "stop"
--   event names one of them while WATCH is true (the earlier rule).  Each
--   is scanned at its "stop"; a "flush" event forgets every trace.  starts
--   and aborts count the "start" and "abort" events of the first kind.
--   Exits: "texit" events while WATCH is true, counted only for the case's
--   traces; exits of other traces are "foreign" (reported, never gated).
--   The exit number of a guard [S]: jit.util.tracesnap(tr, n)[0] is the
--   first IR ref snapshot n covers (lib_jit.c, build copy :358,
--   snap->ref - REF_BIAS, the index jit.util.traceir takes); the assembler
--   gives a guard at ref r the exit of the last snapshot n with
--   ref(n) <= r (asm_snap_prev, lj_asm.c build copy :1073-1086, run for
--   every instruction at :2571; asm_guardcc, lj_asm_x86.h :77,
--   exitstub_addr(J, as->snapno)); and "texit" reports that n with the
--   trace's number (lj_trace.c :928-931: J->parent, J->exitno).  So an exit
--   number names a snapshot, and the scan knows the guards each snapshot
--   holds, of three kinds (op2 & 0x7ff is read as op2 % 2048; IRCONV_DSH 5,
--   OCLJ_IRCONV_EXACT 0x400, oclj_bitop.h :124; IRT_NUM 14, IRT_INT 19,
--   IRT_I64 21, lj_ir.h build copy :320-327):
--     RESULT guards: EQ.i64 of a result guard's own conversion back (CONV
--       with op2 & 0x7ff = 0x6ae, P30; oclj_bitop_rec.c :150-154), among
--       them the shift's (the other operand an i64 BSHL, BSAR or ADD);
--     OPERAND guards: an operand's own round trip, EQ.num of a CONV with
--       op2 & 0x7ff = 0x5d5 whose operand is a CONV i64.num (op2 & 0x7ff =
--       0x2ae) of the EQ's other operand (oclj_rec_bitarg, :64-67); and a
--       variable count's guards (:141-142): its CONV int.num CHECK (op2 &
--       0x7ff = 0x26e, conversion mode 3 in op2's top four bits) when it is
--       the count of an i64 BSHL, BSHR or BSAR, and the ULT of that count
--       (by 64).  The test is structural: a guard is never taken for an
--       operand guard by its op2 bits alone;
--     OTHER guards: every other guard, and the exits the IR does not show:
--       the trace head's GC check (snapshot 0, lj_asm.c :2587-2590), the
--       loop's GC check (the LOOP instruction's snapshot, :1690-1692; LOOP
--       is itself a guard), a root trace's stack check at its end (the last
--       snapshot, :2133-2139, :2182) and a GCSTEP's check (its snapshot).
--       A side trace's own stack check leaves through its parent's exit
--       (:2098-2109) and is charged to it.
--   An exit is ATTRIBUTABLE when its snapshot holds result guards and,
--   beside them, operand guards only; SHARED: result guards and other
--   guards, where which one failed is not known; OPERAND-ONLY: operand
--   guards and nothing else; UNKNOWN: a snapshot holding no guard the scan
--   knows, which means the exit map is wrong.
--   WHY AN ATTRIBUTABLE EXIT IN A LEMMA PART IS A FAILED RESULT GUARD: the
--   operand guards cannot fail on the tables' data.  The round trip: for an
--   integral double x in [-2^63, 2^63), cvttsd2si gives x's integer exactly,
--   and that integer is a double (x itself), so cvtsi2sd gives x back in
--   any rounding mode and the EQ.num holds [I: the instructions'
--   definitions; Lemma D of argue/argument.md].  Every operand a loop
--   passes (TL, TC, Z) is such a double: stdout's instrument "operands"
--   checks it.  The count's CONV int.num CHECK fails only for a double that
--   is not an int32 exactly, and its ULT only for a count outside 0..63
--   [S: :141-142]; KVAR holds the integers 0..63: the instrument "counts"
--   checks it.  The snapshot holds nothing else, so a result guard failed
--   [I].  A guard the scan does not know is "other", which makes a
--   snapshot SHARED, never ATTRIBUTABLE.
--   WHERE THE GUARDS SIT [I, not run]: a form's guards sit in the snapshot
--   that pcall's needsnap opens at the form function's FUNCF (lj_ffrecord.c
--   recff_pcall :537, after lj_record_call has emitted the call's own guard
--   into the snapshot before; lj_record.c :2301-2305 adds it before the next
--   bytecode), and the return through pcall's frame sets needsnap again
--   (lj_record.c :945), so a new snapshot opens before the store into OK;
--   the loop's end guard has rec_for's own snapshot (:578).  So in every
--   part that snapshot holds operand guards (x's round trip; z's too in
--   mode r; none for a constant operand or for one that is an earlier
--   result, whose round trip folds away with fold on; under -O-fold it
--   stays, and holds because the earlier result's own guard precedes it in
--   the same snapshot [I]; var's count guards) and result
--   guards: ATTRIBUTABLE.  Revision 2 of this file expected OWN in modes p
--   and r and SHARED in var; with the operand guards counted as "other",
--   all three were SHARED, so no exit could be OWN (the review's finding 1).
--
-- OUTPUT.  stdout, the same text under -joff and under every JIT option set:
--   jitcheck nrand <n> seed <s> values <n> small 300 calls 3 cases <n>
--   instrument kat <n>/<n> ctl-derivation <n>/<n> operands <n>/<n> counts <n>/<n>
--   selftest comparator pairs <n> wrong <n> (must be > 0) verdict <PASS|INSTRUMENT>
--   probe untraced pairs <n> ok <n> wrong <n> raised <n> verdict <PASS|FAIL> first <...>
--   part <name> cases <n> pairs <n> ok <n> wrong <n> raised <n> inexact53 <n>
--     mustraise <n> raisedok <n> returned <n> verdict <PASS|FAIL> first <...>
--   verdict <PASS | FAIL parts ... | INSTRUMENT ...>
-- operands: the values of TL, TC and Z that are integral doubles in
-- [-2^63, 2^63); counts: KVAR's that are integers in 0..63.  ok: returned
-- values equal to the reference; wrong: returned values that differ;
-- raised: every raise; inexact53: raises with the 53-bit message;
-- mustraise: control pairs that must raise; raisedok: those that raised
-- with the exact expected message; returned: those that returned a value.
-- A lemma part (and the probe) passes with ok = pairs, wrong 0, raised 0; a
-- control passes with wrong 0, returned 0, raised = raisedok = mustraise.
-- stderr (never compared), the JIT on:
--   #case <part> <name> traced <0|1> traces <n> starts <n> aborts <n>
--     interp <n> rguards <n> sguards <n> oguards <n> rgsnaps <n>
--     rgshared <n> exits <n> rgexits <n> attrib <n> shared <n> sgexits <n>
--     opexits <n> unknown <n> foreign <n> flushes <n>   (one per case)
--   #cov probe untraced starts <n> aborts <n> traced <n> traces <n> jit on
--   #cov part <name> cases <n> traced <n> traces <n> starts <n> aborts <n>
--     interp <n> rguards <n> sguards <n> sggate <n|-> oguards <n>
--     rgsnaps <n> rgshared <n> exits <n> rgexits <n> attrib <n> shared <n>
--     sgexits <n> opexits <n> unknown <n> exbad <n> snapbad <n> foreign <n>
--     maxexits <n> <case> jit on                            (one per part)
--   #cov measured result guards never failed in the lemma parts: <YES|NO|UNKNOWN> (...)
--   #cov verdict <ok | FAIL: ... | PROVED NOTHING: ...>
-- the JIT off: the "#cov probe" line and each "#cov part" line with zeros
-- and "jit off", then "#cov measured: not measured (jit off)" and "#cov
-- verdict jit off".
-- traced: cases with a trace of their own (P29); traces: those traces;
-- starts, aborts: the case's trace starts and aborts (side-trace attempts
-- among them); interp: its traces whose link type is "interpreter"
-- (jit.util.traceinfo's linktype, lib_jit.c build copy :277-295), such as
-- the stub a hot exit gets once its side traces have failed; rguards:
-- result guards in its traces; sguards: those of an i64 BSHL, BSAR or ADD
-- (simplify_shift_ik's x << 1 ==> x + x), the guards the claim says can
-- never fail; sggate: the sguards the gate reads (all of the part's, or in
-- sarK those of K 1..9; "-" for a part without the gate); oguards: operand
-- guards; rgsnaps: snapshots holding a result guard; rgshared: those also
-- holding an other guard; exits: the case's traces' exits while its loop
-- ran; rgexits: those through a result guard's snapshot, split into attrib
-- (attributable) and shared; sgexits: those through a snapshot holding a
-- shift's result guard; opexits: exits through an operand-only snapshot;
-- unknown, exbad (an exit number past the trace's snapshots) and snapbad
-- (a snapshot list out of order, or of another length than traceinfo's
-- nexit): instrument errors; maxexits: the largest exit count of one case,
-- and that case.
--
-- THE GATES, the JIT on (stderr's verdict and the exit status; stdout never
-- changes with them):
--   PROVED NOTHING:
--   - a part traced in fewer than half its cases;
--   - sggate 0 in shlK, shlneg, var or chain, or in sarK's K 1..9 (where
--     the width rule leaves the guard: bound 64 - K >= 55; for K >= 10 it
--     already removes it, and K = 0 folds to the operand);
--   - a control part with rguards 0 (the scan cannot see its guards), with
--     sguards > 0 (its shifts are BSHRs, which the sguard scan must not
--     count: the scan's negative case), or with attrib 0 (every negative
--     operand must leave through an attributable snapshot; with none, the
--     FAIL path below was never shown to fire);
--   - a lemma part with shared > 0 (not attributable);
--   - any part with opexits > 0 (an operand guard left, which the data rule
--     out: the attribution's premise is wrong);
--   - the probe with traced or traces > 0 (the traced count's negative
--     case), or with starts 0 (no trace was tried, so its 0 shows nothing);
--   - unknown, exbad or snapbad > 0, or an event handler that raised (the
--     instrument).
--   FAIL: a lemma part with attrib > 0: an exit through a snapshot that
--     holds only result guards and operand guards, which cannot fail on the
--     data (above), where every result is exact (the -joff run and the
--     reference show it): a result guard failed.  The controls' attrib > 0
--     is that same path firing, on purpose.
--
-- EXPECTED on this build (build/native, luajit.exe md5 f4038cd6) [I, not
-- run]:
--   stdout: every lemma part verdict PASS (ok = pairs, wrong 0, raised 0);
--   ctl-shr and ctl-shlneg verdict PASS with mustraise = raisedok = raised
--   = 8 * 48 * 3 = 1152, returned 0, ok = 8 * 300 * 3 = 7200; selftest
--   wrong > 0 (close to all its pairs); probe verdict PASS; operands and
--   counts n/n.
--   stderr, the JIT on:
--   - the probe: starts > 0 (its loop gets hot), aborts = starts, traced 0,
--     traces 0;
--   - traced in nearly every case; oguards > 0 in every part (each operand
--     read from a table has its round trip; var adds two count guards per
--     shift); sguards > 0 in shlK (K 1..63), shlneg (K 1..63), var and
--     chain, and in sarK only from its K = 1..9 cases unless -O-fold keeps
--     them all; rgsnaps > 0 and rgshared 0 in every part;
--   - every lemma part: rgexits 0 (attrib 0, shared 0), opexits 0, unknown
--     0, exbad 0, snapbad 0, and about one exit per call through other
--     guards (the loop's end: about 3 per case, fewer under -Ohotexit=1,
--     where a side trace takes the later loop ends); interp reported, not
--     predicted (he1's loop-end side traces record on into runcase);
--   - each control part: rguards > 0, sguards 0, attrib = rgexits > 0,
--     shared 0, opexits 0, and attrib far below 1152 (revision 2's "close
--     to 1152" was about ten times too high: the review's finding 4).  An
--     exit sends texit only for its first takings: from its hotexit'th (10)
--     each starts a side trace, whose recording meets the raise and aborts
--     (oclj_bitop_rec.c :102-103); at its (hotexit + tryside)'th (14th) the
--     side trace stops at once as a stub linked to the interpreter
--     (lj_record.c build copy :2908-2918; lj_jit.h :112, :117-118), the exit
--     is patched to the stub, and later takings never reach lj_trace_exit's
--     texit (lj_trace.c :928-931).  So 14 per exit that reaches its stub
--     (10 under ms0, where maxside 0 makes the first attempt the stub; 5
--     under he1).  With the loop optimization the form's snapshot has two
--     copies: each call's first negative operand (i = 301) is met in the
--     loop body (3 takings per case, below hotexit; under he1 each starts a
--     side trace that aborts), and every later one re-enters the trace at
--     its head and leaves in the pre-roll's copy, which gets the stub.  Per
--     case about 14 + 3 = 17 under jon, hl1 and nofold (136 per part), 14
--     under noloop (one copy: 112), 10 + 3 = 13 under ms0 (104), 5 + 3 = 8
--     under he1 (64); a few more if an exit falls in the GC's atomic or
--     finalize phase, where lj_trace_exit skips trace_hotside (lj_trace.c
--     :942-946) [S].  interp 8 per control part (one stub per case);
--   - the measured line YES.
--   A build or rule that took a logical right shift for exactness-
--   preserving would make the controls return values (returned > 0, stdout
--   verdict FAIL): that is what the controls' values are for; their
--   attributable exits show that a lemma part's failing result guard would
--   read FAIL on stderr.
-- EXIT: 0 PASS (stdout verdict PASS, and #cov verdict ok or jit off); 1 FAIL
-- (stdout verdict FAIL: a lemma part, the probe or a control failed by
-- value; or #cov verdict FAIL: a lemma part's result guard left); 2
-- INSTRUMENT (a known answer, the controls' derivation, an operand, a count,
-- the reference or the self-test is wrong; stdout) or PROVED NOTHING (a
-- coverage gate; stderr).

local NL = string.char(10)
local fmt = string.format

local function usage(msg)
  print("INSTRUMENT: " .. msg .. " (usage: jitcheck.lua [nrand [seed]])")
  os.exit(2)
end
local NRAND = tonumber(arg and arg[1] or "24")
local SEED = tonumber(arg and arg[2] or "20261023")
if not NRAND or NRAND < 0 or NRAND > 10000 or NRAND ~= math.floor(NRAND) then
  usage("nrand must be a whole number from 0 to 10000")
end
if not SEED or SEED < 1 or SEED > 2147483646 or SEED ~= math.floor(SEED) then
  usage("seed must be a whole number from 1 to 2147483646")
end

-- Powers of two, exact.
local TWO = {}
do
  local p = 1
  for j = 0, 64 do TWO[j] = p; p = p * 2 end
end

-- THE REFERENCE: no bit operator; interpreted always (jit.off below).
local function mkref()
  local bad = 0
  local function split(x)  -- x a nonzero integral double: odd m, e, x = m * 2^e
    local m, e = x, 0
    while m % 2 == 0 do m = m / 2; e = e + 1 end
    return m, e
  end
  local function shl(x, k)  -- x << k on int64, k >= 0 (0 for k >= 64)
    if x == 0 or k >= 64 then return 0 end
    local p = x * TWO[k]
    if p >= -TWO[63] and p < TWO[63] then return p end
    local m, e = split(x)
    local t = e + k
    if t >= 64 then return 0 end
    local M = TWO[64 - t]
    if M > TWO[53] then bad = bad + 1; return 0 / 0 end
    local y = (m % M) * TWO[t]
    if y >= TWO[63] then y = y - TWO[64] end
    return y
  end
  local function sar(x, k)  -- x ~>> k, k >= 0 (sign fill for k >= 64)
    if k > 63 then k = 63 end
    return math.floor(x / TWO[k])
  end
  local function shr(x, k)  -- x >> k (logical), for x >= 0 only
    return math.floor(x / TWO[k])
  end
  local function nbad() return bad end
  return { shl = shl, sar = sar, shr = shr, nbad = nbad }
end
if type(jit) == "table" and jit.off then jit.off(mkref, true) end
local REF = mkref()

-- Known answers for the reference (each worked by hand from the definition).
local KAT = {
  { "shl", 1, 63, -TWO[63] },              -- 2^63 wraps to -2^63
  { "shl", 3, 62, -TWO[62] },              -- 3 * 2^62 - 2^64
  { "shl", -1, 63, -TWO[63] },             -- in range
  { "shl", -1, 64, 0 },
  { "shl", -3, 62, TWO[62] },              -- 2^64 - 3 * 2^62
  { "shl", 5, 61, -3 * TWO[61] },          -- 5 * 2^61 - 2^64
  { "shl", TWO[53] - 1, 11, -2048 },       -- 2^64 - 2^11 wraps
  { "shl", TWO[53] - 1, 12, -4096 },       -- (2^53 - 1) * 2^12 mod 2^64 = 2^64 - 2^12
  { "shl", -(TWO[53] - 1), 11, 2048 },
  { "shl", TWO[52] + 1, 1, TWO[53] + 2 },
  { "shl", 7, 0, 7 },
  { "shl", 0, 5, 0 },
  { "sar", -1, 5, -1 },
  { "sar", -TWO[63], 63, -1 },
  { "sar", -TWO[63], 1000, -1 },
  { "sar", TWO[63] - 1024, 1000, 0 },
  { "sar", -3, 1, -2 },
  { "sar", TWO[53] - 1, 52, 1 },
  { "sar", -(TWO[53] - 1), 52, -2 },
  { "shr", 6, 1, 3 },
}

-- The operands.
local seed = SEED
local function rnd() seed = (seed * 16807) % 2147483647; return seed end
local MS = { 1, -1, 3, -3, TWO[52] - 1, -(TWO[52] - 1), TWO[52] + 1, -(TWO[52] + 1),
  TWO[53] - 1, -(TWO[53] - 1) }
for _ = 1, NRAND do
  local L = rnd() % 53 + 1
  local r53 = (rnd() % TWO[26]) * TWO[27] + rnd() % TWO[27]
  local m = TWO[L - 1] + r53 % TWO[L - 1]
  if rnd() % 2 == 0 then m = -m end
  MS[#MS + 1] = m
end
local NSMALL = 300
local TL = {}
for i = 1, NSMALL do TL[i] = 2 * i end
TL[#TL + 1] = 0
for _, m in ipairs(MS) do
  for e = 0, 63 do
    local x = m * TWO[e]
    if x >= -TWO[63] and x < TWO[63] then TL[#TL + 1] = x end
  end
end
local NEGV = { -1, -3, -5, -7, -9, -11, -13, -15 }
local NREP = 6
local TC, MUSTC = {}, {}
for i = 1, NSMALL do TC[i] = 2 * i; MUSTC[i] = false end
for _ = 1, NREP do
  for _, v in ipairs(NEGV) do TC[#TC + 1] = v; MUSTC[#MUSTC + 1] = true end
end
local NMAX = #TL > #TC and #TL or #TC
local Z, K0, KVAR = {}, {}, {}
for i = 1, NMAX do Z[i] = 0; K0[i] = 0; KVAR[i] = (i - 1) % 64 end

-- The controls' inexactness, by derivation: the logical v >> K of a small
-- negative v is 2^(64-K) - c, c = ceil(|v| / 2^K), with 64 - K - v2(c)
-- significant bits when 1 <= c <= 2^(63-K).
local function ctlsig(v, K)
  local c = math.ceil(-v / TWO[K])
  if c < 1 or c > TWO[63 - K] then return nil end
  local t = 0
  while c % 2 == 0 do c = c / 2; t = t + 1 end
  return 64 - K - t
end

-- THE CASES.  add returns the case; sgwant marks sarK's K 1..9 cases.
local CASES, PARTORDER = {}, {}
local function add(part, name, form, refkey, ref, T, KV, MUST, opname)
  if not CASES[part] then CASES[part] = {}; PARTORDER[#PARTORDER + 1] = part end
  local list = CASES[part]
  local c = { part = part, name = name, form = form, refkey = refkey, ref = ref,
    T = T, KV = KV, MUST = MUST, opname = opname }
  list[#list + 1] = c
  return c
end
for K = 0, 64 do
  local rf = function(x) return REF.shl(x, K) end
  add("shlK", fmt("shl%d-p", K), fmt("x << %d", K), "shl" .. K, rf, TL, K0, nil, "<<")
  add("shlK", fmt("shl%d-r", K), fmt("(x ~ z) << %d", K), "shl" .. K, rf, TL, K0, nil, "<<")
end
do
  local SARK = {}
  for K = 0, 64 do SARK[#SARK + 1] = K end
  SARK[#SARK + 1] = 1000
  for _, K in ipairs(SARK) do
    local rf = function(x) return REF.sar(x, K) end
    local want = K >= 1 and K <= 9
    local cp = add("sarK", fmt("sar%d-p", K), fmt("x ~>> %d", K), "sar" .. K, rf, TL, K0, nil, "~>>")
    local cr = add("sarK", fmt("sar%d-r", K), fmt("(x ~ z) ~>> %d", K), "sar" .. K, rf, TL, K0, nil, "~>>")
    cp.sgwant = want
    cr.sgwant = want
  end
end
for K = 1, 64 do
  local rf = function(x) return REF.shl(x, K) end
  add("shlneg", fmt("shrneg%d", K), fmt("x >> -%d", K), "shl" .. K, rf, TL, K0, nil, ">>")
  add("shlneg", fmt("sarneg%d", K), fmt("x ~>> -%d", K), "shl" .. K, rf, TL, K0, nil, "~>>")
end
do
  local rshl = function(x, k) return REF.shl(x, k) end
  local rsar = function(x, k) return REF.sar(x, k) end
  add("var", "shlv-p", "x << k", "shlv", rshl, TL, KVAR, nil, "<<")
  add("var", "shlv-r", "(x ~ z) << k", "shlv", rshl, TL, KVAR, nil, "<<")
  add("var", "sarv-p", "x ~>> k", "sarv", rsar, TL, KVAR, nil, "~>>")
  add("var", "sarv-r", "(x ~ z) ~>> k", "sarv", rsar, TL, KVAR, nil, "~>>")
end
do
  local AB = { { 1, 1 }, { 11, 11 }, { 32, 20 }, { 63, 63 }, { 5, 40 }, { 40, 5 }, { 30, 34 }, { 20, 50 } }
  for _, ab in ipairs(AB) do
    local A, B = ab[1], ab[2]
    add("chain", fmt("shl%d-sar%d", A, B), fmt("(x << %d) ~>> %d", A, B), fmt("c1-%d-%d", A, B),
      function(x) return REF.sar(REF.shl(x, A), B) end, TL, K0, nil, "~>>")
    add("chain", fmt("sar%d-shl%d", A, B), fmt("(x ~>> %d) << %d", A, B), fmt("c2-%d-%d", A, B),
      function(x) return REF.shl(REF.sar(x, A), B) end, TL, K0, nil, "<<")
    add("chain", fmt("shl%d-shl%d", A, B), fmt("(x << %d) << %d", A, B), fmt("c3-%d-%d", A, B),
      function(x) return REF.shl(REF.shl(x, A), B) end, TL, K0, nil, "<<")
    add("chain", fmt("sar%d-sar%d", A, B), fmt("(x ~>> %d) ~>> %d", A, B), fmt("c4-%d-%d", A, B),
      function(x) return REF.sar(REF.sar(x, A), B) end, TL, K0, nil, "~>>")
  end
end
do
  -- The masks are spelled as numerals of at most 53 significant bits, which
  -- the lexer reads exactly (P47): 9007199254740991 = 2^53 - 1,
  -- 4294967295 = 2^32 - 1.  x & (2^n - 1) is x mod 2^n (Lua's % is floored,
  -- so non-negative), exact in doubles here.
  for _, K in ipairs({ 1, 11, 12, 31, 32, 52, 63 }) do
    add("shapes", fmt("m53-shl%d", K), fmt("(x & 9007199254740991) << %d", K), fmt("m53shl%d", K),
      function(x) return REF.shl(x % TWO[53], K) end, TL, K0, nil, "<<")
    add("shapes", fmt("m32-shl%d", K), fmt("(x & 4294967295) << %d", K), fmt("m32shl%d", K),
      function(x) return REF.shl(x % TWO[32], K) end, TL, K0, nil, "<<")
  end
  for _, K in ipairs({ 1, 11, 31, 52 }) do
    add("shapes", fmt("m53-shr%d", K), fmt("(x & 9007199254740991) >> %d", K), fmt("m53shr%d", K),
      function(x) return REF.shr(x % TWO[53], K) end, TL, K0, nil, ">>")
  end
  for _, kj in ipairs({ { 1, 63 }, { 11, 11 }, { 20, 40 }, { 52, 1 } }) do
    local K, J = kj[1], kj[2]
    add("shapes", fmt("m53-shr%d-shl%d", K, J), fmt("((x & 9007199254740991) >> %d) << %d", K, J),
      fmt("m53shr%dshl%d", K, J), function(x) return REF.shl(REF.shr(x % TWO[53], K), J) end,
      TL, K0, nil, "<<")
  end
end
for K = 1, 8 do
  local rf = function(x) return REF.shr(x, K) end
  add("ctl-shr", fmt("ctl-shr%d", K), fmt("x >> %d", K), "shr" .. K, rf, TC, K0, MUSTC, ">>")
end
for K = 1, 8 do
  local rf = function(x) return REF.shr(x, K) end
  add("ctl-shlneg", fmt("ctl-shlneg%d", K), fmt("x << -%d", K), "shr" .. K, rf, TC, K0, MUSTC, "<<")
end
local SELF = { part = "selftest", name = "selftest", form = "x << 1", refkey = "selftest",
  ref = function(x) return REF.shl(x, 2) end, T = TL, KV = K0, MUST = nil, opname = "<<" }
-- The probe: a lemma form whose form function runcase turns the JIT off for.
local PROBE = { part = "probe", name = "untraced", form = "x << 3", refkey = "shl3",
  ref = function(x) return REF.shl(x, 3) end, T = TL, KV = K0, MUST = nil, opname = "<<",
  nojit = true }
local NCASES = 0
for _, part in ipairs(PARTORDER) do NCASES = NCASES + #CASES[part] end
-- The coverage gate on sguards, by part: "all" reads every case's, "want"
-- only the cases marked sgwant (sarK's K 1..9).
local SGGATE = { shlK = "all", sarK = "want", shlneg = "all", var = "all", chain = "all" }

-- THE INSTRUMENTS FIRST.
local katok = 0
for _, t in ipairs(KAT) do
  local got = REF[t[1]](t[2], t[3])
  if got == t[4] then
    katok = katok + 1
  else
    print(fmt("INSTRUMENT: the reference's %s(%.17g, %d) gives %.17g, not %.17g", t[1], t[2], t[3], got, t[4]))
  end
end
local dok, dn = 0, 0
for K = 1, 8 do
  for _, v in ipairs(NEGV) do
    dn = dn + 1
    local s = ctlsig(v, K)
    if s and s > 53 then
      dok = dok + 1
    else
      print(fmt("INSTRUMENT: the control x = %d, K = %d is not inexact by derivation (%s significant bits)", v, K, tostring(s)))
    end
  end
end
-- Every operand a loop passes must be an integral double in [-2^63, 2^63),
-- and every variable count an integer in 0..63: the operand guards' premise.
local function opgood(x)
  return type(x) == "number" and x == math.floor(x) and x >= -TWO[63] and x < TWO[63]
end
local function cntgood(k)
  return type(k) == "number" and k == math.floor(k) and k >= 0 and k <= 63
end
local opok, opn = 0, 0
for _, T in ipairs({ TL, TC, Z }) do
  for i = 1, #T do
    opn = opn + 1
    if opgood(T[i]) then opok = opok + 1 end
  end
end
local cok = 0
for i = 1, #KVAR do
  if cntgood(KVAR[i]) then cok = cok + 1 end
end
-- The same two predicates on planted values each must reject (re-review
-- finding 3: prove these instruments can fail).
local BADOP = { 0.5, 0 / 0, 1 / 0, -1 / 0, TWO[63], -TWO[63] - 2048 }
local BADCNT = { -1, 64, 1.5, 0 / 0 }
local rej, rejn = 0, #BADOP + #BADCNT
for i = 1, #BADOP do if not opgood(BADOP[i]) then rej = rej + 1 end end
for i = 1, #BADCNT do if not cntgood(BADCNT[i]) then rej = rej + 1 end end
print(fmt("jitcheck nrand %d seed %d values %d small %d calls 3 cases %d", NRAND, SEED, #TL, NSMALL, NCASES))
print(fmt("instrument kat %d/%d ctl-derivation %d/%d operands %d/%d counts %d/%d rejects %d/%d", katok, #KAT, dok, dn,
  opok, opn, cok, #KVAR, rej, rejn))
if katok ~= #KAT or dok ~= dn or opok ~= opn or cok ~= #KVAR or dn ~= #NEGV * 8 or rej ~= rejn then
  print("verdict INSTRUMENT the reference, the controls' derivation, the operands or the counts are wrong")
  io.stderr:write("#cov verdict PROVED NOTHING: instrument" .. NL)
  os.exit(2)
end

-- THE COVERAGE INSTRUMENT (LuaJIT with the JIT on).
local COVKEYS = { "traced", "traces", "starts", "aborts", "interp", "rguards", "sguards", "oguards",
  "rgsnaps", "rgshared", "snapbad", "flushes", "exits", "rgexits", "attrib", "shared", "sgexits",
  "opexits", "foreign", "unknown", "exbad" }
local function newcc()
  local t = {}
  for _, k in ipairs(COVKEYS) do t[k] = 0 end
  return t
end
local function newcv()
  local t = newcc()
  t.sgwant = 0
  t.maxexits = 0
  t.maxcase = "-"
  return t
end
local function addto(dst, src)
  for _, k in ipairs(COVKEYS) do dst[k] = dst[k] + src[k] end
end
local hasjit = (type(jit) == "table" and jit.status and jit.status() and jit.attach) and true or false
local W1, W2, HIT, WATCH = nil, nil, false, false
local CC = newcc()        -- the running case's counters (a sink before the first case)
local MINE, CASETR = {}, {}  -- MINE[tr]: started in the case's functions; CASETR[tr]: its scan
local HERR, HERRMSG = 0, nil
if hasjit then
  local okv, vmdef = pcall(require, "jit.vmdef")
  local oku, jutil = pcall(require, "jit.util")
  if not (okv and oku) then
    print("verdict INSTRUMENT no jit.vmdef or jit.util (set LUA_PATH to the build's src/?.lua)")
    io.stderr:write("#cov verdict PROVED NOTHING: no jit.vmdef" .. NL)
    os.exit(2)
  end
  local OPS = {}
  for o = 0, #vmdef.irnames / 6 - 1 do
    OPS[(vmdef.irnames:sub(o * 6 + 1, o * 6 + 6):gsub(" +$", ""))] = o
  end
  for _, nm in ipairs({ "CONV", "EQ", "ULT", "BSHL", "BSHR", "BSAR", "ADD", "LOOP" }) do
    if not OPS[nm] then
      print("verdict INSTRUMENT jit.vmdef names no " .. nm)
      io.stderr:write("#cov verdict PROVED NOTHING: jit.vmdef" .. NL)
      os.exit(2)
    end
  end
  local OPGCSTEP = OPS.GCSTEP or -1
  local IRT_NUM, IRT_I64 = 14, 21
  -- op2 & 0x7ff (op2 % 2048) of the conversions oclj_bitop_rec.c emits:
  local CV_RBACK = 1710  -- 0x6ae: (I64 << 5) | NUM | EXACT, a result guard's back (:152-153)
  local CV_OBACK = 1493  -- 0x5d5: (NUM << 5) | I64 | EXACT, an operand's back (:65-66), and d (:150)
  local CV_OI = 686      -- 0x2ae: (I64 << 5) | NUM, an operand's CONV i64.num (:64)
  local CV_CNT = 622     -- 0x26e: (INT << 5) | NUM, a variable count's CONV int.num CHECK (:141)
  -- scan(tr): the trace's guards and its exit map, kind[n] for each
  -- snapshot n that holds a guard: { rg, sg, og, other }.
  local function scan(tr)
    local res = { rg = 0, sg = 0, og = 0, rgsnaps = 0, rgshared = 0, snapbad = 0, nsnap = 0,
      interp = 0, kind = {} }
    local info = jutil.traceinfo(tr)
    if not info then res.snapbad = 1; return res end
    if info.linktype == "interpreter" then res.interp = 1 end
    local ir = {}
    for ref = 1, info.nins do
      local _, ot, op1, op2 = jutil.traceir(tr, ref)
      if not ot then break end
      ir[ref] = { o = math.floor(ot / 256), t = ot % 32, g = ot % 256 >= 128, op1 = op1, op2 = op2 }
    end
    local sref, ns = {}, 0
    while true do
      local s = jutil.tracesnap(tr, ns)
      if not s then break end
      sref[ns] = s[0]
      if ns > 0 and s[0] < sref[ns - 1] then res.snapbad = res.snapbad + 1 end
      ns = ns + 1
    end
    res.nsnap = ns
    if ns == 0 or ns ~= info.nexit then res.snapbad = res.snapbad + 1 end
    local K = res.kind
    local function at(ex)
      local k = K[ex]
      if not k then k = { rg = false, sg = false, og = false, other = false }; K[ex] = k end
      return k
    end
    local function exitof(r)  -- the last snapshot n with sref[n] <= r
      local ex = 0
      for n = 1, ns - 1 do
        if sref[n] <= r then ex = n end
      end
      return ex
    end
    local function isconv(r, low)  -- a CONV whose op2 % 2048 is low
      local x = r and r > 0 and ir[r]
      return x and x.o == OPS.CONV and x.op2 % 2048 == low
    end
    local function isback(r)  -- a result guard's own conversion back
      return isconv(r, CV_RBACK)
    end
    local function isrt(a, b)  -- a is b's own round trip: CONV 0x5d5 of a CONV i64.num of b
      if not isconv(a, CV_OBACK) then return false end
      local i = ir[a].op1
      return isconv(i, CV_OI) and ir[i].op1 == b
    end
    local function isshift(r)  -- an i64 BSHL, BSAR, or ADD (x << 1 ==> x + x)
      local x = r and r > 0 and ir[r]
      return x and x.t == IRT_I64 and (x.o == OPS.BSHL or x.o == OPS.BSAR or x.o == OPS.ADD)
    end
    -- The variable counts: refs that are the count (op2) of an i64 BSHL,
    -- BSHR or BSAR (a constant count is a negative ref here).
    local CNT = {}
    for ref = 1, #ir do
      local x = ir[ref]
      if x.t == IRT_I64 and (x.o == OPS.BSHL or x.o == OPS.BSHR or x.o == OPS.BSAR) and x.op2 > 0 then
        CNT[x.op2] = true
      end
    end
    if ns > 0 then
      at(0).other = true       -- the head's GC check
      at(ns - 1).other = true  -- a root trace's stack check at its end
    end
    for ref = 1, #ir do
      local x = ir[ref]
      if x.g or x.o == OPGCSTEP then
        local k = at(exitof(ref))
        if x.g and x.o == OPS.EQ and x.t == IRT_I64 and (isback(x.op1) or isback(x.op2)) then
          res.rg = res.rg + 1
          k.rg = true
          if (isback(x.op1) and isshift(x.op2)) or (isback(x.op2) and isshift(x.op1)) then
            res.sg = res.sg + 1
            k.sg = true
          end
        elseif x.g and x.o == OPS.EQ and x.t == IRT_NUM and (isrt(x.op1, x.op2) or isrt(x.op2, x.op1)) then
          res.og = res.og + 1  -- an operand's round trip
          k.og = true
        elseif x.g and x.o == OPS.CONV and x.op2 % 2048 == CV_CNT and math.floor(x.op2 / 4096) == 3 and CNT[ref] then
          res.og = res.og + 1  -- a variable count's CONV int.num CHECK
          k.og = true
        elseif x.g and x.o == OPS.ULT and x.op1 > 0 and CNT[x.op1] then
          res.og = res.og + 1  -- a variable count's ULT 64
          k.og = true
        else
          k.other = true  -- any other guard, LOOP (its GC check) and GCSTEP among them
        end
      end
    end
    for _, k in pairs(K) do
      if k.rg then
        res.rgsnaps = res.rgsnaps + 1
        if k.other then res.rgshared = res.rgshared + 1 end
      end
    end
    return res
  end
  local function ontrace(what, tr, func)
    if what == "start" then
      MINE[tr] = WATCH and (func == W1 or func == W2) or nil
      if MINE[tr] then CC.starts = CC.starts + 1 end
    elseif what == "abort" then
      if MINE[tr] then CC.aborts = CC.aborts + 1 end
      MINE[tr] = nil
    elseif what == "flush" then
      MINE, CASETR = {}, {}
      if WATCH then CC.flushes = CC.flushes + 1 end
    elseif what == "stop" then
      if MINE[tr] or (WATCH and (func == W1 or func == W2)) then
        if not HIT then HIT = true; CC.traced = 1 end
        local m = scan(tr)
        if not CASETR[tr] then CC.traces = CC.traces + 1 end
        CASETR[tr] = m
        CC.rguards = CC.rguards + m.rg
        CC.sguards = CC.sguards + m.sg
        CC.oguards = CC.oguards + m.og
        CC.rgsnaps = CC.rgsnaps + m.rgsnaps
        CC.rgshared = CC.rgshared + m.rgshared
        CC.snapbad = CC.snapbad + m.snapbad
        CC.interp = CC.interp + m.interp
      end
      MINE[tr] = nil
    end
  end
  local function ontexit(tr, ex)
    if not WATCH then return end
    local m = CASETR[tr]
    if not m then CC.foreign = CC.foreign + 1; return end
    CC.exits = CC.exits + 1
    if type(ex) ~= "number" or ex < 0 or ex >= m.nsnap then CC.exbad = CC.exbad + 1; return end
    local k = m.kind[ex]
    if not k then CC.unknown = CC.unknown + 1; return end
    if k.rg then
      CC.rgexits = CC.rgexits + 1
      if k.other then CC.shared = CC.shared + 1 else CC.attrib = CC.attrib + 1 end
      if k.sg then CC.sgexits = CC.sgexits + 1 end
    elseif k.og and not k.other then
      CC.opexits = CC.opexits + 1
    end
  end
  -- P11: one handler per event, so "trace" and "texit" each have this
  -- file's only one.  A raising handler is reported by the VM to stderr and
  -- swallowed (lj_vmevent.c, build copy :47-51), so each body runs under
  -- pcall and is counted.
  jit.attach(function(...)
    local ok, err = pcall(ontrace, ...)
    if not ok then HERR = HERR + 1; HERRMSG = HERRMSG or tostring(err) end
  end, "trace")
  jit.attach(function(...)
    local ok, err = pcall(ontexit, ...)
    if not ok then HERR = HERR + 1; HERRMSG = HERRMSG or tostring(err) end
  end, "texit")
end

-- THE RUNNER.
local LOOPTEXT = "local T, Z, KV, n, f, OK, R = ..." .. NL ..
  "for i = 1, n do local ok, r = pcall(f, T[i], Z[i], KV[i]); OK[i] = ok; R[i] = r end"
local INEXACT = "has more than 53 significant bits (mask each operand to 32 bits first)"
local refcache = {}
local function refs(c)
  local key = c.refkey .. "@" .. tostring(c.T) .. "@" .. tostring(c.KV)
  local RF = refcache[key]
  if not RF then
    RF = {}
    local T, KV, ref = c.T, c.KV, c.ref
    for i = 1, #T do RF[i] = ref(T[i], KV[i]) end
    refcache[key] = RF
  end
  return RF
end
local function newacc()
  return { cases = 0, pairs = 0, ok = 0, wrong = 0, raised = 0, inexact53 = 0,
    mustraise = 0, raisedok = 0, returned = 0, first = nil }
end
local function note(acc, c, i, msg)
  if not acc.first then
    acc.first = fmt("%s i=%d x=%.17g k=%s %s", c.name, i, c.T[i], tostring(c.KV[i]), msg)
  end
end
local function runcase(c, acc, cv)
  local f = assert(load("return function(x, z, k) return " .. c.form .. " end", "=f-" .. c.name))()
  if c.nojit and type(jit) == "table" and jit.off then jit.off(f) end
  local loop = assert(load(LOOPTEXT, "=" .. c.name))
  local T, KV, MUST, n = c.T, c.KV, c.MUST, #c.T
  local RF = refs(c)
  local want = "result of '" .. c.opname .. "' " .. INEXACT
  local cc = newcc()
  W1, W2, HIT, CC, MINE, CASETR = loop, f, false, cc, {}, {}
  for _ = 1, 3 do
    local OK, R = {}, {}
    for i = 1, n do OK[i] = false; R[i] = 0 end
    WATCH = true
    loop(T, Z, KV, n, f, OK, R)
    WATCH = false
    for i = 1, n do
      local must = MUST and MUST[i]
      acc.pairs = acc.pairs + 1
      if must then acc.mustraise = acc.mustraise + 1 end
      if OK[i] then
        if must then
          acc.returned = acc.returned + 1
          note(acc, c, i, fmt("returned %.17g where it must raise", R[i]))
        elseif R[i] == RF[i] then
          acc.ok = acc.ok + 1
        else
          acc.wrong = acc.wrong + 1
          note(acc, c, i, fmt("got %.17g want %.17g", R[i], RF[i]))
        end
      else
        acc.raised = acc.raised + 1
        local msg = tostring(R[i])
        if string.find(msg, INEXACT, 1, true) then acc.inexact53 = acc.inexact53 + 1 end
        if must then
          if string.find(msg, want, 1, true) then
            acc.raisedok = acc.raisedok + 1
          else
            note(acc, c, i, "raised another error: " .. msg)
          end
        else
          note(acc, c, i, "raised: " .. msg)
        end
      end
    end
  end
  acc.cases = acc.cases + 1
  addto(cv, cc)
  if c.sgwant then cv.sgwant = cv.sgwant + cc.sguards end
  if cc.exits > cv.maxexits then cv.maxexits = cc.exits; cv.maxcase = c.name end
  if hasjit then
    io.stderr:write(fmt("#case %s %s traced %d traces %d starts %d aborts %d interp %d rguards %d sguards %d oguards %d rgsnaps %d rgshared %d exits %d rgexits %d attrib %d shared %d sgexits %d opexits %d unknown %d foreign %d flushes %d",
      c.part, c.name, cc.traced, cc.traces, cc.starts, cc.aborts, cc.interp, cc.rguards, cc.sguards,
      cc.oguards, cc.rgsnaps, cc.rgshared, cc.exits, cc.rgexits, cc.attrib, cc.shared, cc.sgexits,
      cc.opexits, cc.unknown, cc.foreign, cc.flushes) .. NL)
  end
end

-- THE SELF-TEST: the comparator must see a wrong value.
local sacc = newacc()
runcase(SELF, sacc, newcv())
local selfok = sacc.wrong > 0
print(fmt("selftest comparator pairs %d wrong %d (must be > 0) verdict %s", sacc.pairs, sacc.wrong,
  selfok and "PASS" or "INSTRUMENT"))

local fails, nothing, covfail = {}, {}, {}

-- THE PROBE: the traced count's negative case.  Its values as a lemma
-- part's; with the JIT on, it must read traced 0 after starting traces.
local pacc, pcv = newacc(), newcv()
runcase(PROBE, pacc, pcv)
local probeok = pacc.pairs > 0 and pacc.ok == pacc.pairs and pacc.wrong == 0 and pacc.raised == 0
print(fmt("probe untraced pairs %d ok %d wrong %d raised %d verdict %s first %s", pacc.pairs, pacc.ok,
  pacc.wrong, pacc.raised, probeok and "PASS" or "FAIL", pacc.first or "-"))
if not probeok then fails[#fails + 1] = "probe-untraced" end
io.stderr:write(fmt("#cov probe untraced starts %d aborts %d traced %d traces %d jit %s",
  pcv.starts, pcv.aborts, pcv.traced, pcv.traces, hasjit and "on" or "off") .. NL)
if hasjit then
  if pcv.traced > 0 or pcv.traces > 0 then
    nothing[#nothing + 1] = fmt("the probe, whose form function is jit.off'd, reads traced %d traces %d (the traced count counts traces a case cannot have)",
      pcv.traced, pcv.traces)
  end
  if pcv.starts == 0 then
    nothing[#nothing + 1] = "the probe's loop started no trace, so its traced 0 shows nothing"
  end
end

-- THE PARTS.
local LEM, LEMCASES, CTLATTRIB = newcv(), 0, 0
for _, part in ipairs(PARTORDER) do
  if hasjit then jit.flush() end
  local acc = newacc()
  local cv = newcv()
  local list = CASES[part]
  for _, c in ipairs(list) do runcase(c, acc, cv) end
  local isctl = list[1].MUST ~= nil
  local pass
  if isctl then
    pass = acc.wrong == 0 and acc.returned == 0 and acc.mustraise > 0 and
      acc.raised == acc.mustraise and acc.raisedok == acc.mustraise and
      acc.ok == acc.pairs - acc.mustraise
  else
    pass = acc.wrong == 0 and acc.raised == 0 and acc.ok == acc.pairs and acc.pairs > 0
  end
  if not pass then fails[#fails + 1] = part end
  print(fmt("part %s cases %d pairs %d ok %d wrong %d raised %d inexact53 %d mustraise %d raisedok %d returned %d verdict %s first %s",
    part, acc.cases, acc.pairs, acc.ok, acc.wrong, acc.raised, acc.inexact53, acc.mustraise,
    acc.raisedok, acc.returned, pass and "PASS" or "FAIL", acc.first or "-"))
  local sgn = nil
  if SGGATE[part] == "all" then sgn = cv.sguards elseif SGGATE[part] == "want" then sgn = cv.sgwant end
  io.stderr:write(fmt("#cov part %s cases %d traced %d traces %d starts %d aborts %d interp %d rguards %d sguards %d sggate %s oguards %d rgsnaps %d rgshared %d exits %d rgexits %d attrib %d shared %d sgexits %d opexits %d unknown %d exbad %d snapbad %d foreign %d maxexits %d %s jit %s",
    part, acc.cases, cv.traced, cv.traces, cv.starts, cv.aborts, cv.interp, cv.rguards, cv.sguards,
    sgn and tostring(sgn) or "-", cv.oguards, cv.rgsnaps, cv.rgshared, cv.exits, cv.rgexits, cv.attrib,
    cv.shared, cv.sgexits, cv.opexits, cv.unknown, cv.exbad, cv.snapbad, cv.foreign, cv.maxexits,
    cv.maxcase, hasjit and "on" or "off") .. NL)
  if hasjit then
    if cv.traced * 2 < acc.cases then
      nothing[#nothing + 1] = fmt("%s traced in %d of %d cases", part, cv.traced, acc.cases)
    end
    if cv.snapbad > 0 or cv.exbad > 0 or cv.unknown > 0 then
      nothing[#nothing + 1] = fmt("%s: the exit map is wrong (bad snapshot lists %d, exit numbers past the snapshots %d, exits through a snapshot with no guard the scan knows %d)",
        part, cv.snapbad, cv.exbad, cv.unknown)
    end
    if sgn and sgn == 0 then
      nothing[#nothing + 1] = fmt("%s: no result guard of an i64 BSHL, BSAR or ADD in its traces%s",
        part, SGGATE[part] == "want" and " from its K 1..9 cases" or "")
    end
    if cv.opexits > 0 then
      nothing[#nothing + 1] = fmt("%s: %d exits through snapshots holding operand guards alone, which the operands' data rule out (the attribution's premise is wrong)",
        part, cv.opexits)
    end
    -- Re-review finding 1: a result guard that shares its snapshot with a
    -- guard the scan does not know could never read as attributable, so
    -- this part's FAIL path could not fire.
    if cv.rgshared > 0 then
      nothing[#nothing + 1] = fmt("%s: %d snapshots hold result guards beside guards the scan does not know, so a failing result guard there could not be attributed",
        part, cv.rgshared)
    end
    if isctl then
      CTLATTRIB = CTLATTRIB + cv.attrib
      if cv.rguards == 0 then
        nothing[#nothing + 1] = fmt("%s: no result guard in its traces (the scan cannot see the controls' guards)", part)
      end
      if cv.sguards > 0 then
        nothing[#nothing + 1] = fmt("%s: %d result guards counted as an i64 BSHL, BSAR or ADD's where every shift is a BSHR (the sguard scan is wrong)",
          part, cv.sguards)
      end
      if cv.attrib == 0 then
        nothing[#nothing + 1] = fmt("%s: no attributable exit (through a snapshot holding only result and operand guards), where the negative operands must leave through one: the FAIL path was never shown to fire",
          part)
      end
    else
      LEMCASES = LEMCASES + acc.cases
      addto(LEM, cv)
      if cv.attrib > 0 then
        covfail[#covfail + 1] = fmt("%s: %d exits through snapshots that hold only result and operand guards: a result guard failed where every result is exact and the operand guards cannot fail",
          part, cv.attrib)
      end
      if cv.shared > 0 then
        nothing[#nothing + 1] = fmt("%s: %d exits through snapshots that hold result guards and other guards (not attributable)",
          part, cv.shared)
      end
    end
  end
end

-- THE VERDICT.  stdout's reads the values only; stderr's the coverage.
local code
local inst = {}
if not selfok then inst[#inst + 1] = "the self-test's comparator saw no wrong value" end
if REF.nbad() > 0 then
  inst[#inst + 1] = fmt("the reference met %d shifts with M > 2^53 past the range (L1's case B says none)", REF.nbad())
end
if #inst > 0 then
  print("verdict INSTRUMENT " .. table.concat(inst, "; ") ..
    (#fails > 0 and ("; parts not passing: " .. table.concat(fails, " ")) or ""))
  code = 2
elseif #fails > 0 then
  print("verdict FAIL parts " .. table.concat(fails, " "))
  code = 1
else
  print("verdict PASS")
  code = 0
end
if not hasjit then
  io.stderr:write("#cov measured: not measured (jit off)" .. NL)
  io.stderr:write("#cov verdict jit off" .. NL)
else
  if HERR > 0 then
    nothing[#nothing + 1] = fmt("the event handlers raised %d times (first: %s)", HERR, tostring(HERRMSG))
  end
  local word
  if LEM.attrib > 0 then
    word = "NO"
  elseif #nothing == 0 and LEM.shared == 0 and LEM.opexits == 0 and LEM.sguards > 0 and CTLATTRIB > 0 then
    word = "YES"
  else
    word = "UNKNOWN"
  end
  io.stderr:write(fmt("#cov measured result guards never failed in the lemma parts: %s (result guards %d, %d of them on an i64 BSHL, BSAR or ADD, and operand guards %d, in %d traces of %d cases; exits through result guards' snapshots %d: attributable %d, shared %d; operand-only exits %d; exits counted %d, foreign %d; the controls' attributable exits %d, which must be > 0)",
    word, LEM.rguards, LEM.sguards, LEM.oguards, LEM.traces, LEMCASES, LEM.rgexits, LEM.attrib,
    LEM.shared, LEM.opexits, LEM.exits, LEM.foreign, CTLATTRIB) .. NL)
  if #covfail > 0 then
    io.stderr:write("#cov verdict FAIL: " .. table.concat(covfail, "; ") ..
      (#nothing > 0 and ("; and proved nothing: " .. table.concat(nothing, "; ")) or "") .. NL)
    if code == 0 then code = 1 end
  elseif #nothing > 0 then
    io.stderr:write("#cov verdict PROVED NOTHING: " .. table.concat(nothing, "; ") .. NL)
    if code == 0 then code = 2 end
  else
    io.stderr:write("#cov verdict ok" .. NL)
  end
end
io.stdout:flush()
io.stderr:flush()
os.exit(code)
