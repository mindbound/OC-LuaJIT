# SHIFT-EXACT, the refute part: notes

Written 2026-10-23 by the refute agent. Read only: `argue/argument.md` (429 lines), `checks/model.py`, `checks/jitcheck.lua`, `checks/run.sh`, the repo at HEAD `1a13bed` (native/luajit/*, docs/jit-guide.md, test/native/bitop/*.expect, ncir.lua, t_numconv.lua, t_sar.lua, the Java state factory, native/lj52shim.*), and the build copy `build/native/luajit-windows-x86_64/src/` (read only). Nothing was run (the user is timing in Minecraft). "build :N" is a line of that build copy. Marks: [S] read in source, [I] inferred; no [M] is new here.

## Verdict

**Nothing in the proof breaks.** Lemmas D, De, BSHL, BSAR, BSHL10, BAND and ADD z,z survive every edge case I tried, and so does the sketched rule's soundness (E's leaves, the recursion, PHIs, CSE, forwarding, the guard order). The findings are about one side path the argument misses, which predates this round and which the rule neither causes nor worsens (type-blind CSE), about gaps in the checks, and about wording. Details follow, most severe first.

## F1 (medium): type-blind CSE lets an int shift or BNOT stand in for the recorder's i64 `res`. §3.4 misses it, and S5's premise fails for it

- [S] `lj_opt_cse` (build :2663-2677) matches only `op12` within the opcode's chain, and returns `TREF(ref, irt_t(IR(ref)->t))`, which is **the existing instruction's type**, not the one asked for (the guide says so in 3.9: "It does not compare the type").
- [S] On x64, `simplify_conv_sext` LEFTFOLDs `CONV i64.int SEXT` to the int ref itself for the SCEV loop index with start >= 0, for `ADD idx, k`, and for u8/u16 XLOADs (build :1278-1308). So `oclj_rec_bitarg`'s operand is the int SLOAD itself (guide 3.12: "`i << 7` ... `i64 BSHL 0003 +7`, no CONV" [M]).
- [S] LuaJIT's `bit` library records int ops on the same refs: `recff_bit_unary` emits `IRTI(BNOT) tr, 0` (lj_ffrecord.c :773-780), and `recff_bit_shift` emits `IRTI(op) tr, tsh` with a KINT count (:800-821). `lj_opt_narrow_tobit` returns the int index unchanged. `rec_varg` emits `IRTI(IR_BSHL) tridx, KINT 3` (lj_record.c :2081).
- So `oclj_rec_bitop`'s `emitir(IRT(IR_BNOT, IRT_I64), i, 0)` or `emitir(IRT(IR_BSHL, IRT_I64), i, KINT k)` has the same op12 as such an int op, and CSE returns the int instruction [S][I].
  - **Forward order** (the int op recorded first): `res` is the 32-bit op. `d = CONV num.i64 res` makes `asm_conv` take `st` from op2 (I64), so it emits `cvtsi2sd` with REX.W on the int op's zero-extended register (lj_asm_x86.h :859-860, :896-897). The width rule scores the INT y at 33 and drops the guard. Wrong values: `local a = bit.bnot(i); local b = ~i` gives b = 2^32 - 1 - i where the interpreter gives -1 - i; `bit.lshift(i, 3)` then `i << 3` gives the low 32 bits for i >= 2^29 [I].
  - **Reverse order** (ours first): the lib_bit result becomes an **I64-typed TRef in a Lua slot**. `snap_restoreval` (lj_snap.c :735-761, GC64) has no I64 case and would `setgcV` the raw register [I]. Not to be tested by forcing it (CLAUDE.md: census only).
- **Reach** [S][I]: OC's sandbox does not open LuaJIT's `bit`. `LuaJITStateFactory.openLibs` opens BIT32, which is lj52shim's C `bit32` ("NOT an alias for luaopen_bit", native/lj52shim.c :3000), so in game only `rec_varg`'s BSHL can collide. Its `ULT tridx-1, 2^27` guard (lj_record.c :2080) comes first in trace order, so i*8 < 2^31 and both orders give the same value. The standalone `luajit.exe` the tests run does open `bit`; gen and the suites use only the operators, so nothing has met this.
- **Effect on the round** [I]: no new unsoundness. An INT twin's register value is in [0, 2^32), which is in D. The width rule takes an INT y first, and the sketch's `irt_isi64` refuses one. But §3.4 ("Not producers on this build") is incomplete, and S5's premise "folds and CSE preserve values" (guide 9.5, and the argument's §4.5 and §7 assumption) is false for int/i64 twins.
- **What to do**: when the machine is free, the main session can confirm on standalone luajit with value-only loops against `-joff` (bnot, and lshift from i = 2^29) plus `-jdump`. It must not exercise the reverse order beyond reading the IR. Candidate fixes are for the user, as a roadmap row:
  - after `emitir` of an int64 op in `oclj_rec_bitop`, abort when the returned ref has our opcode but is not I64-typed. Mind the legitimate INT `res` of identity folds (`i | 0` returns the index itself, which is `a`);
  - or make the twins distinct.

## F2 (medium): the checks do not test the two lemmas beyond the brief, and BSHL10 is one the proposed rule reads

- [S] model.py's ops are `shl`, `sar` and two controls (`NAMES`, model.py :108). jitcheck tests only operands in D: every Lua-level operand is an integral double (`oclj_flt2int`). BSHL10's new content is "whatever the operand", so it is about IR intermediates only. No script, nor verify-rg2's probe, checks Lemma BSHL10 or Lemma BAND, and §6.3 item 1 says BAND "has never been measured".
- Cheap additions to the scaled model [I]:
  - BSHL10 at scale: x << k is exact at P for every x in the W-bit word when k >= W - 1 - P. Every multiple of 2^(W-1-P) in range has at most P significant bits.
  - BSHL10's tightness control, at k = W - 2 - P with x = 2^(P+1) + 1: it must find P + 1 bits.
  - BAND of every pair in D_P x D_P, exhaustive at W <= 8 or so, with `bor` as its control.
  - In the 64-bit sweep: BSHL10 on random int64 x (k in 10..63), and BAND on pairs from the operand list.

## F3 (medium-low): jitcheck's JIT-on runs cannot show that the guard never fails, and their coverage expectations are unenforced

- [S] A failing result guard exits, and the interpreter recomputes the same value, which `-joff` already showed never raises. So "stdout identical to -joff's" holds whether or not the guard fires.
- [S] `exits` and `sguards` are written to stderr but gate nothing (jitcheck.lua :527-531 gates only `traced`). The header's EXPECTED ("sguards > 0 in shlK, var and chain", "about one exit per call") is unchecked. A scan error, such as a wrong `IRT_I64` or op2 mask, would read sguards 0 and still pass.
- [S] `exits` is polluted. The "texit" handler (:424-426) counts every exit while `WATCH` is true, and `WATCH` stays true through runcase's own result loop (:465-494), which may itself be traced.
- **Fix**:
  - set `WATCH` only around `loop(...)`;
  - record the case's trace numbers from "stop", and count exits only for them;
  - gate sguards > 0 in shlK, shlneg, var and chain (sarK only for K <= 9);
  - gate or at least report exits per case against the loop exits, so that "the result guard never fails" becomes an [M] reading on the base build.

## F4 (low-medium): run.sh reads exit status 1 as a lemma counterexample

- [S] run.sh :154 and :180, :197 put any exit 1 into `fails`. Python exits 1 on an uncaught exception, and luajit on an uncaught Lua error (for example `assert(load(...))` at jitcheck.lua :455-456). An instrument crash would then read "VERDICT FAIL".
- Fix: count 1 as FAIL only with `VERDICT FAIL` (model.out) or `verdict FAIL parts` (jc-*.out) as the last line; otherwise PROVED NOTHING.

## F5 (low): run.sh's documented launch line cannot start

- [S] The header's `nohup sh .../run.sh "$R" > "$R.log" 2>&1 &`, with R under `checks/runs/`, has the calling shell open `checks/runs/run-1.log` before run.sh runs. `checks/runs/` does not exist (the directory holds jitcheck.lua, model.py and run.sh only).
- So no log is written, run.sh never starts, and a monitor waiting for "$R/done" never ends.
- Fix: `mkdir -p` the parent in the documented command, or have run.sh write its own log inside R.

## F6 (low): §4.5's induction is stated on the wrong order

- The argument does "induction on n's depth in E's tree", with a leaf's copy "folded by value-preserving rules ... given the guards emitted before (S1)".
- With the rule there is a case where neither holds [I]. Take `h = h << 3` carried:
  - the pre-roll has `i0 = CONV i64.num h0` and `y0 = BSHL i0, 3`;
  - in the copy, `subst[i0]` folds by the exact-mark rule to the PHI-marked `y0`, and `y1 = BSHL y0, 3`;
  - the rule removes y1's guard because E(y0) holds.
- The leaf's value is the PHI value of y0, which is y1 from the previous iteration, the very value whose guard was removed. So the depth order is cyclic through the PHI, and the exact-mark fold preserves the value because of the induction hypothesis, not because of a guard.
- The conclusion holds by induction on execution order: on the iteration, then on IR order, with every E node's earlier values in D. FIX-NUMCONV never met this because its subject has no recursion. Restate it that way.

## F7 (low): wording

- §3.3's table puts `simplify_shift1_ki` and `simplify_shift2_ki` (`... KINT64 any`) under "a constant: no shift remains". They fold only a constant 0 (or -1 for BSAR), so `1 << i` keeps `BSHL KINT64 1, cnt`. §5.4 has it right.
- §2.6 and guide 3.11 say "every int64 ADD comes from `simplify_shift_ik`". On GC64 x64, `IRT_IGC` and `IRT_INTP` are I64 (lj_ir.h :339-340), upstream emits I64 SUBs (lj_record.c :2036, :2090; lj_ffrecord.c :1199, :1421), and `simplify_intsub_k` and `simplify_intsub_k64` rewrite a SUB by a constant as an ADD (build :1430-1438, :1460-1469). This has no effect on E: its ADD test needs op1 == op2, and E is entered only from a bit result's tree. But as stated, the claim is the kind the guide warns about ("grep the pristine src for every emitter").

## What I tried and could not break

**The lemmas** [I: checked by hand]:
- Lemma D in every rounding mode, at r = 2^63 - 1 (rounds to 2^63, refused by C, and cvttsd2si gives -2^63 != r), at -2^63 and at 2^63 - 1024. The fast path's registers are 64-bit (vm_x64.dasc :38-45: RA rcx, RC rax) [S].
- Lemma BSHL:
  - at m = 2^53 - 1 with n = e + k at 10, 11 and 12 (gives 2^63 - 1024, -2048, -4096);
  - at n = 63 and 64;
  - at x = -2^63 with k = 0 and k = 1;
  - at -(2^53 - 1) << 11 = 2048;
  - the m' parity and |m'| <= |m| steps.
- Lemma BSAR: the k > e floor bound at both signs, and x = -2^63 at k = 63.
- BSHL10 is tight at `(2^54 + 1) << 9`.
- Lemma BAND: in both sign cases, and on four hand pairs, among them -(2^53 - 1) & 2(2^53 - 1) = 2^53.
- The counterexample table is right.

**Counts** [S]:
- Every count is taken & 63: `kfold_int64shift` (build :435), `kfold_int64arith` (:381-383), `simplify_shift_ik` (:1675-1687), `reassoc_shift` (:1911-1919) and `asm_bitshift` (lj_asm_x86.h :2326-2327, cl, shlx/sarx with VEX.W).
- `simplify_shift_andk` (:1703-1717) is protected by the recorder's `ULT cnt, 64`.
- A KINT64 count is masked too (:2326).

**Producers** [S]:
- a grep of the build copy for `IR_BSHL/BSAR/BSHR` emitters and for `fins->o = IR_BS*` and `IR_ADD`;
- the recorder table in §3.1, which agrees with oclj_bitop_rec.c :113-145;
- `simplify_shiftk_andk`'s nested fold (:1751-1773) builds a BSHR intermediate on a possibly inexact value, but only under a BAND. Through CSE such an intermediate can become a recorded `res` only if its operand is a guarded recorded result. E stays structurally sound either way.
- §4.3's claim (every guarded i64 shift's op1 is in D at run time) survived the CSE and swap-through-PHI cases I built.

**E's leaves** [S][I]:
- `oclj_isnumconv` accepts any unguarded CONV i64.num of a double, the guard's own `back` included. Its value is cvttsd2si's, always in D, before or after any guard.
- `oclj_bitwidth` at depth 0 on a subtree is sound per ref. INT refs have zero-extended registers. The only INT refs with live upper bits, CONV int.intp NONE (guide 3.9), never reach an i64 op directly, because simplify_conv_sext does not LEFTFOLD a CONV.
- KINT64 is tested by value.
- An INT-typed shift deeper in the tree (via F1's CSE) is scored 33, and its value is in D.

**The rule's placement and PHIs** [S]:
- fix1's block (build :1177-1198);
- every way `fleft` can be PHI-marked during the copy (lj_opt_loop.c :330-341);
- the returned y is always PHI-marked or invariant, so no new PHI and no TYPEINS;
- `comm_equal` drops `EQ y, y` (:2040-2049);
- snapshot merging is upstream's.

**S2**: no leaf depends on the guard being removed.

**Arms**: SHIFT9 really is value-invisible, also with the BAND option, because shiftk_andk's rewrites keep the value of a shift of a D value. SHIFTOP is value-visible, and SHIFTW reaches the table-index fold as the argument says.

**Expectation files** [S]:
- t_ops.expect: 13 shift raises and 20 `&` raises, as the argument lists, each `&` raise with a string operand outside D.
- t_sar.expect: 5 raises, each on a string operand. Its format is `E:` (lines 392-394, 414-415).

**The probe and the checks** [S]:
- verify-rg2's probe: its sigbits, its sar (`//`) and its operand generator are correct.
- jitcheck's reference is exact:
  - wrapped shl uses M = 2^(64-t) <= 2^53, and the y - 2^64 step is exact;
  - sar is a floor of a division by a power of two;
  - `x % 2^53` is exact.
- The KAT answers and the controls' derivation (>= 56 bits) are right.
- `jit.off(mkref, true)` aborts traces through REF.
- traceir's biasing and the 0x6ae op2 test are right.
- model.py's histogram algebra (`per_p`, mono, vacfails, ctlcover) is consistent, and its controls must fail at every non-vacuous (W, P).
