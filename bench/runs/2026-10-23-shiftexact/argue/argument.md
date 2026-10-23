# SHIFT-EXACT, the argue part: the soundness argument

JIT guide 3.11's last bullet ("Shifts of an exact operand ... Measured, not proved, and not prototyped: no rule reads it [I]") and 3.12's `x << 20` ("the result guard can never fail ... but no rule reads that"); roadmap row 211 (5)'s closing sentence. Written 2026-10-23 by the argue agent, structured like `claude-tmp/oclj/numconv/argue/argument.md` (FIX-NUMCONV step 1). Repo at HEAD `1a13bed`, clean, not edited; `build/` read only.

**Nothing was run for this part.** The user is timing benchmarks in Minecraft on this machine, so the round's hard rule allowed file reads and small greps only. Every [M] below cites an earlier, archived run by its path; no new measurement was made. Section 6.3 lists what is still to be measured.

**Revision 2** (2026-10-23, the revise part) answers the refute part's findings F1, F6 and F7 (`claude-tmp/oclj/shiftexact/refute/notes.md`). It corrects section 3.4 and adds section 8, on int/i64 CSE twins: a separate, older bug, whose forward order the main session confirmed [M]. It restates section 4.5's induction on execution order, and fixes two wordings (2.6, 3.3, 3.4). The lemmas, their proofs and the sketched rule are unchanged. The revise part ran nothing; its one new [M] is the main session's run, cited by path in section 8. Findings F2 to F5 concern the check scripts, not this file. The changelog is section 9.

**Revision 3** (2026-10-23, the checks-fix part) answers finding 3 of the review of the revised checks. It corrects section 8.1's three shift rows and 8.5's list of tests:
- With fold on, `simplify_shift_ik` takes an int shift's constant count & 31 before CSE, so a constant count of 32 or more in ours never twins.
- Under `-O-fold` nothing twins.
- The value-changing test for BSHR and BSAR is a variable int count of 32 or more.

6.2's row follows from it. Nothing else changed, and nothing was run.

Marks: **[S]** read in source; **[I]** inferred, which includes the proofs in section 2 (a proof is an argument and can be wrong; section 6.3 names the cheap checks that would make each one [M]); **[M]** measured, with the run named. Line cites: "build copy :N" is a line of `build/native/luajit-windows-x86_64/src/<file>` (patched, LF); a repo file is cited as `path :N` at HEAD `1a13bed`; `~:N` is the guide's pristine hint.

## 0. Verdict

1. **The claim is true, and proved here.** For every int64 x that is exactly a double and every count k in 0..63, the wrapped `x << k` (Lemma BSHL) and the arithmetic `x >> k` (Lemma BSAR) are exactly doubles. More strongly, their number of significant bits never exceeds x's (section 2) [I: proof]. The logical right shift is not exactness-preserving: `-1 >> 1` is 2^63 - 1 (section 2.5).
2. **A second, operand-free fact, beyond the brief: Lemma BSHL10.** `x << k` with 10 <= k <= 63 is exactly a double for every int64 x, exact or not, because every multiple of 2^10 in [-2^63, 2^63) is a double. The threshold is tight: `(2^54 + 1) << 9` is not [I: proof, section 2.4].
3. **A third fact, beyond the brief, that contradicts the brief's list: BAND preserves exactness.** The task listed BAND among the operators of exact operands to refute; there is no counterexample: `x & y` is exactly a double whenever x and y are (Lemma BAND, section 2.7) [I: proof]. It is consistent with the PUC-made expectations: every one of `t_ops.expect`'s 20 raises of `&` has a string operand outside D (section 2.9) [S]. BOR, BXOR, BNOT, an ADD of two different operands and BSHR do have counterexamples (section 2.8).
4. **Every count is covered.** On this build an i64 BSHL/BSAR shifts by its count taken & 63, in the IR, in the constant folds and in the x64 backend, so lemmas stated for k in 0..63 cover every count the code can execute, variable counts and `simplify_shift_andk`'s unmasked ones included (section 2.1) [S].
5. **A rule can read it soundly**: in `simplify_conv_i64_num`, inside fix1's block, after the width rule and FIX-NUMCONV, on a line of its own, `(i64)(num)y ==> y` when y is an i64 BSHL by a constant of 10 or more (whatever its operand), or an i64 BSHL or BSAR by any count, or an `ADD z, z` (`simplify_shift_ik`'s `z << 1`), of an operand that is exact by construction (a set E read from opcodes, IR types and constants only: a KINT64 in D, a value the bound puts within [-2^53, 2^53), an operand's own `CONV i64.num`, or recursively such a shift) (section 5). It reads no guard and no mark (S2), returns an existing I64 ref (requirement 2, S4), adds no PHI, and holds in every iteration by an induction on execution order: on the iteration, then on IR order (section 4.5, restated in revision 2) [S][I].
6. **Never in `oclj_bitwidth`** (P60): scored 54, a shift of an exact value would let `(x << 20) | 1` lose its guard and return 2^60 for x = 2^40, where the interpreter raises; and `(x << 20) ~>> 22` would reach the table-index fold at 32 bits and truncate (section 5.3) [I].
7. **What a structural rule cannot see**: a shift's operand that is an earlier BOR, BXOR, BNOT or BSHR result is exactly a double at run time, past its own guard, but nothing in the IR says so once the exact-mark rule has folded the operand's conversion to it. A first rule should not read guards or marks for it (section 4.3). Lemma BSHL10 recovers the counts of 10 or more; the loop-carried hash idiom `h = (h << 5) ~ c` keeps its guard in the loop body (section 5.4) [I].
8. **x64 only, through one leaf.** The lemmas are integer facts and hold on any target; the rule inherits FIX-NUMCONV's x64 dependency through its `oclj_isnumconv` leaf alone (section 6.1) [S][I].
9. **Found on the way**: two comments have been stale since FIX-NUMCONV ("only the width rule may remove it", `native/luajit/oclj_bitop.h` :122-123; "which only the width rule removes", `native/luajit/oclj_bitop_rec.c` :148); and ncir.lua's control `shl1` (`x << 1`, "keep") would fail under the rule and must be reclassified (section 5.6) [S].
10. **A separate bug: int/i64 CSE twins** (section 8; found by the refute part, confirmed by the main session). `lj_opt_cse` matches `op12` and ignores the type. After x64's LEFTFOLD of `CONV i64.int SEXT`, our i64 BSHL or BNOT on the int loop index can therefore share an `op12` with LuaJIT's `bit` library's int op on that index. Under the JIT, `bit.lshift(i, 3)` then `i << 3` gave 341 of 401 values wrong, and `bit.bnot(i)` then `~i` gave 341 of 401 wrong; the controls and every `-joff` value were right [M: `claude-tmp/oclj/shiftexact/cse/run-3`].
    - **Scope.** The bug predates this round. It reaches standalone `luajit.exe` with the `bit` library, not the mod in game: [S] the game does not open `bit` and has no FFI; [I] for `rec_varg`'s guarded int shift and narrowing's int ADD.
    - **What it breaks.** S5's premise "CSE preserves values". It does not touch the lemmas or the rule, because a twin's value is an int op's, which is in D (8.4).
    - **Fixes.** Section 8.5 lists the fix options for a later round and does not choose one. The reverse order must not be run (8.6).

## 1. Definitions as the code has them

### 1.1 The three tests of a result

Every result of a bit operator that does not raise must be "exactly a double". The fork tests it in three places, each a round trip int64 -> double -> int64 [S]:

| where | code | the test |
|---|---|---|
| the interpreter's fast path | `ins_bitop`, `native/luajit/patch-bitop-vm.sh` :177-180 (hunk 3's new text; BC_BNOT's, :124-127) | `cvtsi2sd xmm0, RC; cvttsd2si RA, xmm0; cmp RA, RC; jne ->vmeta_bitop_pc` |
| the parser, the slow path, the recorder's record-time check | `oclj_bit2num`, `native/luajit/oclj_bitop.h` :101-108; called by `foldbitop` (lj_parse.c build copy :829), `oclj_meta_bitop` (`native/luajit/oclj_bitop_meta.c` :144) and `oclj_rec_bitop` (`native/luajit/oclj_bitop_rec.c` :98, :102) | `i = (int64)r; n = (double)i; if (n >= 2^63) return 0; return (int64_t)n == i` |
| the JIT's result guard | `oclj_rec_bitop`, `oclj_bitop_rec.c` :150-155 | `d = CONV num.i64 res` (`cvtsi2sd`), `back = CONV i64.num d` (`cvttsd2si r64`), `EQ.i64 back, res` |

A failing test raises "result of '<op>' has more than 53 significant bits (mask each operand to 32 bits first)" (`oclj_bitop_meta.c` :132), or, in a trace, leaves through the guard's exit to the interpreter, which recomputes and raises (guide 4.7, S8) [S].

### 1.2 The set D

**Definition.** D is the set of int64 values r in [-2^63, 2^63) that are exactly an IEEE double: r = 0, or r = m * 2^e with m an odd integer, |m| < 2^53, and 0 <= e <= 63.

**Lemma D.** For an int64 r, each of the three tests passes if and only if r is in D, in every MXCSR rounding mode [I: proof].

*Proof.* (r in D => pass.) `cvtsi2sd`, and C's `(double)` of an `int64_t` (gcc compiles it to `cvtsi2sd` on x64), convert a representable integer exactly, whatever the rounding mode. The double n = r lies in [-2^63, 2^63), where `cvttsd2si r64` and C's `(int64_t)` are exact (-2^63 is in range; the largest double below 2^63 is 2^63 - 1024), so the round trip gives r back, and C's `n >= 2^63` branch is not taken.
(r not in D => fail.) Every integer of magnitude at most 2^53 is a double, so |r| > 2^53, and the conversion rounds r to a double n != r with |n| >= 2^53, an integer. If n < 2^63, `cvttsd2si` and C's cast give n != r. If n = 2^63 (an r near 2^63 - 1, rounded up in round-to-nearest or toward +inf), C returns 0 at `n >= 2^63`, and `cvttsd2si` returns the indefinite value -2^63 != r (r > 0). n < -2^63 cannot occur: -2^63 is a double <= r, so no rounding mode goes below it. DAZ and FTZ do not act: no denormal is read or made. QED

So "exact", "at most 53 significant bits" and "passes the guard" are one set, D [I]. Edge values: 0 is in D (it converts to +0.0 and back); -2^63 is in D (m = -1, e = 63); 2^63 - 1024 is in D; 2^63 - 1, 2^53 + 1 and -(2^53 + 1) are not.

**Significant bits.** For r != 0 let sig(r) be the bit length of the odd part |m|; sig(-2^63) = 1. Then r is in D iff sig(r) <= 53. This is `shiftexact.lua`'s `sigbits` (lowest set bit to highest of the magnitude, `math.mininteger` counted as one bit, `crc/verify-rg2/probes/shiftexact.lua` :7-16) [S].

### 1.3 A second characterization, by divisibility

**Lemma De.** An int64 v is in D iff for some e in 0..63, 2^e divides v and -2^(e+53) <= v < 2^(e+53) [I: proof].

*Proof.* (=>) v = m * 2^e with |m| < 2^53 gives |v| < 2^(e+53), and 2^e divides v; v = 0 takes e = 0. (<=) Write v = j * 2^e; the range gives -2^53 <= j < 2^53. If j = -2^53, v = -2^(e+53) is a power of two (an int64 only if e <= 10), a double. Otherwise |j| < 2^53, so j is a double, and so is j * 2^e (|v| < 2^63: no overflow), and v's odd part divides j, so it is below 2^53. QED

Two corollaries used below [I]:
- (C1) every int64 of magnitude at most 2^53 is in D;
- (C2) **every multiple of 2^10 in [-2^63, 2^63) is in D**: with e = 10, the range [-2^63, 2^63) is the whole int64 range.

## 2. The lemmas

### 2.1 What the IR's shifts compute, and the counts they see

An i64 `BSHL x, c`, `BSHR x, c`, `BSAR x, c` computes, on two's-complement int64, the left shift modulo 2^64, the logical right shift and the arithmetic right shift (floor division by 2^k) by k = c & 63 [S]:

- **The backend** (`asm_bitshift`, lj_asm_x86.h build copy :2318-2372; `asm_bshl`/`asm_bshr`/`asm_bsar` :2374-2376): a constant count is reduced `shift &= (irt_is64(ir->t) ? 63 : 31)` (:2326-2327) and emitted as `shl`/`shr`/`sar r64, imm` (:2336-2340); a variable count goes to `shl`/`shr`/`sar r64, cl` (:2361, REX.W through `REX_64IR`) or, with BMI2, `shlx`/`shrx`/`sarx` (:2341-2347). With a 64-bit operand those take the count modulo 64 [I: Intel SDM, SAL/SAR/SHL/SHR and SARX/SHLX/SHRX].
- **The constant folds**: `kfold_int64shift` takes `sh = (fright->i & 63)` (lj_opt_fold.c build copy :435, patch-bitop-fold.sh hunk 3) and `kfold_int64arith` `(k2 & 63)` (:381-383, used by `simplify_shiftk_andk` for its shifted mask).
- **The simplifications** normalize a constant count to `k & 63` (`simplify_shift_ik` :1675-1687) and combine two masked counts (`reassoc_shift` :1911-1919: BSHL and BSHR of a sum above 63 fold to KINT64 0, BSAR to a count of 63), each equal to applying the two shifts in turn.
- **What the recorder emits** (section 3.1): constant counts 0..63 as KINT, and a variable count behind `ULT cnt, 64` (`oclj_bitop_rec.c` :142). `simplify_shift_andk` may then replace a count `j & 63` by j (lj_opt_fold.c build copy :1698-1717, because x64 has `LJ_TARGET_MASKSHIFT 1`, lj_arch.h build copy :213), which the hardware masks back to j & 63.
- **The interpreter agrees**: its fast path shifts only for a count in [0, 63] (`cmp RA, 63; ja ->vmeta_bitop_pc`, then `shl/shr/sar RC, cl`, patch-bitop-vm.sh :170-176), and leaves every other count to 5.3.6's rule in C (`oclj_shiftl`, `oclj_shiftar`, oclj_bitop.h :58-76).

So a lemma proved for every k in 0..63 holds for every BSHL or BSAR the trace executes, whatever its count operand holds [S][I].

### 2.2 Lemma BSHL

**Lemma BSHL.** If x is in D and 0 <= k <= 63, the wrapped r = x << k (the int64 congruent to x * 2^k modulo 2^64) is in D, and sig(r) <= sig(x) [I: proof].

*Proof.* If x = 0, r = 0. Otherwise x = m * 2^e with m odd, |m| < 2^53, 0 <= e <= 63 (e = 63 only for x = -2^63, m = -1). Let n = e + k, so x * 2^k = m * 2^n.
- **n >= 64.** 2^64 divides m * 2^n, so r = 0, in D.
- **n <= 63.** Let b = 64 - n >= 1, and let m' be the signed reduction of m to b bits: the unique integer in [-2^(b-1), 2^(b-1)) with m' = m modulo 2^b. Then m' * 2^n = m * 2^n modulo 2^(b+n) = 2^64, and m' * 2^n lies in [-2^63, 2^63), so r = m' * 2^n. Since b >= 1, m' = m modulo 2, so m' is odd (and r != 0). If m lies in [-2^(b-1), 2^(b-1)), then m' = m. Otherwise |m| >= 2^(b-1) >= |m'|. Either way |m'| <= |m| < 2^53, so r = m' * 2^n with m' odd, |m'| < 2^53 and 0 <= n <= 63: r is in D, and sig(r) = bitlength(|m'|) <= bitlength(|m|) = sig(x). QED

Examples [I]: `(2^53 - 1) << 10` = 2^63 - 1024 (m' = m); `(2^53 - 1) << 11` = -2048 (m' = -1); `3 << 62` = -2^62; `1 << 63` = -2^63; `-(2^53 - 1) << 11` = 2048.

Cross-check by Lemma De [I]: x in D_e (a multiple of 2^e within +-2^(e+53)) gives x * 2^k a multiple of 2^(e+k) within +-2^(e+k+53); reducing modulo 2^64 keeps the multiple of 2^(e+k) (which divides 2^64 when e + k <= 63) and lands in [-2^63, 2^63); if e + k >= 10 the result is a multiple of 2^10, in D by C2, and if e + k < 10 no wrap occurs (|x * 2^k| < 2^(e+k+53) <= 2^62) and the result is in D_(e+k).

### 2.3 Lemma BSAR

**Lemma BSAR.** If x is in D and 0 <= k <= 63, r = x >> k arithmetic (floor(x / 2^k)) is in D, and sig(r) <= sig(x) [I: proof].

*Proof.* If x = 0, r = 0. Otherwise x = m * 2^e as above.
- **k <= e.** r = m * 2^(e-k) exactly: no bit is lost; same m, in D.
- **k > e.** Let j = k - e >= 1; r = floor(m / 2^j). As |m| < 2^53, |m / 2^j| < 2^52, so r lies in [-2^52, 2^52 - 1] (for m > 0, 0 <= r < 2^52; for m < 0, -2^52 <= r <= -1), which is in D by C1. And |r| <= ceil(|m| / 2^j) <= |m|, so sig(r) <= bitlength(|m|). QED

`~>>` by a count of 64 or more is recorded as BSAR by 63 (section 3.1): -1 or 0, in D [S][I].

### 2.4 Lemma BSHL10: a left shift by 10 or more, whatever the operand

**Lemma BSHL10.** For every int64 x (in D or not) and every k with 10 <= k <= 63, x << k is in D [I: proof].

*Proof.* The wrapped result is congruent to x * 2^k modulo 2^64, and 2^10 divides both x * 2^k and 2^64, so it is a multiple of 2^10 in [-2^63, 2^63): in D by C2. QED

**Tight** [I]: `(2^54 + 1) << 9` is 2^63 + 2^9 modulo 2^64, the int64 -(2^63 - 2^9), whose magnitude has bits 9..62 set: 54 significant bits, not in D. So no count below 10 works for every operand. This is a fact of divisibility, not of range, and not of the operand's exactness: it reads only the count, a constant.

Note the parallel with what the width rule already reads [S: `oclj_bitop_fold.c` :104-114]: an arithmetic shift right by k >= 10 is bounded by 64 - k <= 54 bits, and a logical one by k >= 11 by 65 - k <= 54, so the width rule already removes those guards; for the left shift no range bound can (its range is the whole int64 range), and divisibility does.

### 2.5 The logical shift BSHR: the counterexample

x = -1 is in D (m = -1, e = 0), and `-1 >> 1` (logical) is 2^63 - 1, which has 63 significant bits: not in D [I]. 5.3.6 raises on it: `t_ops.expect`'s line `>> -1 1	ERR:result of '>>' has more than 53 significant bits ...` [S: test/native/bitop/t_ops.expect, made mechanically from PUC 5.3.6's output, guide 11.6]. Exactly when BSHR is exact [I]: for x >= 0 it equals BSAR (Lemma BSAR); for k = 0 it is x; for k >= 11 its result lies in [0, 2^53) (the width rule's 65 - k); for x < 0 and 1 <= k <= 10 the result is at least 2^53 and in general not in D (x = -2^63, k = 1 gives 2^62, in D; x = -1 does not).

### 2.6 ADD z, z

`simplify_shift_ik` rewrites `z << 1` as `ADD z, z` (lj_opt_fold.c build copy :1679-1683) [S].

**It is not the only source of an i64 ADD.** Revision 1 said it was, after guide 3.11's table and `oclj_bitop_fold.c` :93's comment "From x << 1 ==> x + x". That is wrong as worded, because upstream can make an i64 ADD from a SUB [S]:
- on GC64 x64, `IRT_IGC` and `IRT_INTP` are I64 (lj_ir.h build copy :339-340);
- upstream emits I64 SUBs: lj_record.c build copy :2036 and :2090, lj_ffrecord.c build copy :1199 and :1421;
- `simplify_intsub_k` and `simplify_intsub_k64` rewrite a SUB by a constant as an ADD (lj_opt_fold.c build copy :1430-1438 and :1460-1469).

Whether any of those four SUBs ever has a constant right operand was not traced [I].

**What the argument needs is weaker, and holds whatever made the ADD.** An i64 `ADD z, z` (one ref used twice) wraps modulo 2^64 (x64 `add r64` or `lea`), so it is z << 1. Lemma BSHL with k = 1 then makes it exact for z in D [I]. E's ADD case tests `op1 == op2` and is entered only at a bit result or below its shifts (5.1), so other ADD sources change nothing in it [S][I]. `ADD a, b` with a != b is not exactness-preserving: 2^53 + 1 [I]. The width bound's ADD case, max(wa, wb) + 1, bounds any sum, so it also holds for any ADD [I].

### 2.7 Lemma BAND (beyond the brief; it contradicts the brief's list)

**Lemma BAND.** If x and y are in D, x & y is in D [I: proof].

*Proof.* If x, y or r = x & y is 0, done. Take x in D_ex and y in D_ey (Lemma De; ex, ey the trailing-zero counts of x and y), and E = max(ex, ey). Every bit of r below E is 0, since one of x, y has it 0, so 2^E divides r.
- **One of them non-negative, say x >= 0.** The set bits of r are a subset of x's, so 0 <= r <= x < 2^(ex+53) <= 2^(E+53).
- **Both negative.** A negative int64 v with v >= -2^p (p <= 63) has bits p..63 all set, because v + 2^64 >= 2^64 - 2^p. So x has bits ex+53..63 set and y bits ey+53..63 (where those are <= 63), and r has bits E+53..63 set, so r >= -2^(E+53) (if E + 53 > 63, r >= -2^63 >= -2^(E+53) trivially); and r < 0 (bit 63 set in both).
In both cases 2^E divides r and -2^(E+53) <= r < 2^(E+53): r is in D_E. QED

A check by hand [I]: x = 2^53 - 1 (bits 0..52), y = -2 (bits 1..63): r = 2^53 - 2, in D; x = -2^63 + 2^10, y = 2^63 - 2^10: r = 2^10.

**Consequences, outside this round's brief** [I]: an i64 BAND of two exact operands could join the rule's set E (section 5.1, an option), and a BAND result's own guard can never fail when both operands are exact: `x & y` and `x & -256` on two doubles, which the width rule keeps today (both operands score 64), and the shape `simplify_shiftk_andk` makes of `(x & m) << k`, a BAND of a shifted operand and a shifted mask (section 5.4). In the interpreter, `&` on two numbers never raises U1-B: every number operand is an integral double, so in D. The decision whether a BAND rule joins this one belongs to the user (open points).

### 2.8 The operators that do not preserve exactness

Each counterexample takes operands in D and gives a result outside it [I]:

| operator | operands | result | sig |
|---|---|---|---|
| BOR | 2^53, 1 | 2^53 + 1 | 54 |
| BXOR | 2^53, 1 | 2^53 + 1 | 54 |
| BNOT | 2^53 | -2^53 - 1 | 54 |
| ADD a, b (a != b) | 2^53, 1 | 2^53 + 1 | 54 |
| BSHR | -1, 1 | 2^63 - 1 | 63 |
| BROL (never i64 here) | -2^62 (0xC000000000000000), 1 | 0x8000000000000001 = -2^63 + 1 | 63 |

BROL is listed only for completeness [S][I]: no recorder path emits an i64 rotate on this build (only `lib_bit` emits rotates, as int, section 3.4, and `simplify_shift_ik`'s BROR-to-BROL rewrite acts only on a BROR), so the rule never meets one, and the predicate (5.1) does not accept BROL or BROR. The example shows why a rotate differs from a shift: `-2^62 << 1` is -2^63, in D, but the rotate carries bit 63 around to bit 0.

### 2.9 Consistent with what was measured

- **verify-rg2's probe on PUC 5.3.6** [M: `claude-tmp/oclj/crc2/docs/shiftexact-1/out.txt`, `inputs.md5`: probe md5 `e3fad85c`, PUC `lua.exe` md5 `7bd7faf2`, 2026-10-20 15:54:30-15:54:58Z]: `pairs 25600000  shl-inexact 0  sar-inexact 0  control(x|1<<k)-inexact 2089279`. Lemmas BSHL and BSAR predict 0 and 0, and a nonzero control [I]. The probe draws exact x as an odd m of 1..53 bits shifted left by j in 0..63 with either sign (which also wraps), plus `math.mininteger`, `(1 << 53) - 1`, `-(1 << 53)`, `((1 << 53) - 1) << 10` and `3 << 62` every 97th draw, and keeps x only if `sigbits(x) <= 53` (`shiftexact.lua` :28-36) [S].
- **The PUC-made expectations** [S: `test/native/bitop/t_ops.expect`, 7467 lines; `t_sar.expect`]: of the 13 raises of `<<` and `>>` in `t_ops.expect`, 12 are logical right shifts by 5.3.6's rule (`<< -1 -1` and `<< -1 '-1'`, a negative left count; and ten `>> x k` with k = 1 or 3, of -1, -2, -2^31-1, -2^53-2, `'-1'`, `'0xffffffffffffffff'` or `'0x7fffffffffffffff'`), and the 13th, `<< '9007199254740993' 1`, shifts a string operand outside D (2^53 + 1); none is a left or arithmetic shift of a number. Its 20 raises of `&` all have an operand outside D, the string `'9007199254740993'` or `'0x7fffffffffffffff'`. `t_sar.expect`'s 5 raises of `~>>` all have the string operand `'0x7fffffffffffffff'` or `'-0x7fffffffffffffff'`. Strings are read as integers by 5.3.6's reader (README's dialect section) and can be outside D; a number operand cannot (`oclj_flt2int`, `native/luajit/oclj_num53.h` :47-53, accepts only an integral double). The recorder never compiles a string operand (`oclj_rec_bitarg`, `oclj_bitop_rec.c` :55-56, aborts). So the data agree with Lemmas BSHL, BSAR and BAND [S][I].

## 3. Which operations reach an i64 BSHL or BSAR

### 3.1 The recorder

`lj_record_ins` sends BC_BNOT..BC_BSAR to `oclj_rec_bitop` (lj_record.c build copy :2528-2532) [S]. A constant result (both operands constant) folds to a KINT64 and takes no guard (`oclj_bitop_rec.c` :151). Otherwise, for the shifts [S: `oclj_bitop_rec.c` :113-145]:

| Lua (and dialect) form | count | IR | where |
|---|---|---|---|
| `x << k` | constant 0..63 | `BSHL x, k` (k = 0 folds to x, k = 1 to `ADD x, x`, section 3.3) | :125-134 |
| `x << k` | constant >= 64 or <= -64 (5.3.6's rule) | KINT64 0 | :129-130 |
| `x << -k` | constant, 1 <= k <= 63 | `BSHR x, k` (logical) | :127, :132 |
| `x >> k` | constant 1..63 | `BSHR x, k` | :128, :132 |
| `x >> 0` | | `BSHL x, 0`, folds to x | :128, :132 |
| `x >> -k` | constant, 1 <= k <= 63 | `BSHL x, k` | :128, :132 |
| `x >> k` | constant >= 64 or <= -64, and k = INT64_MIN | KINT64 0 | :128-130 |
| `x ~>> k` | constant 0..63 | `BSAR x, k` | :119-120 |
| `x ~>> k` | constant >= 64 | `BSAR x, 63` (the sign) | :117-118 |
| `x ~>> -k` | constant, 1 <= k <= 63 | `BSHL x, k` | :121-122 |
| `x ~>> k` | constant <= -64 | KINT64 0 | :123-124 |
| `x << i`, `x >> i`, `x ~>> i` | variable, in [0, 63] at record time | `cnt` (the int itself, or `CONV int.num CHECK`, which the table-index fold may make a `CONV int.i64`), `ULT cnt, 64`, then `BSHL`, `BSHR` or `BSAR x, cnt` | :135-145 |
| the same | variable, outside [0, 63] at record time | not recorded (`lj_trace_err`, BADTYPE); at run time `ULT` exits | :137, :142 |

Each row agrees with the interpreter's rule (`oclj_shiftl`, `oclj_shiftar`, `oclj_bitop64`, oclj_bitop.h :58-93) [S]. So **an i64 BSHL comes from `<<` by 1..63, `>>` by -63..-1 and `~>>` by -63..-1, constant, and from `<<` by a variable count; an i64 BSAR from `~>>` by 0..63 or 64 and more, constant, and from `~>>` by a variable count.** BSHR (not exactness-preserving) comes from `<<` by a negative constant, `>>` by a positive one and `>>` by a variable count.

**The compound assignments** `x <<= k`, `x >>= k`, `x ~>>= k`: `parse_compound` (lj_parse.c build copy :2416-2451) accepts every binary operator ordered before `OPR_NE` except `OPR_POW` (:2428; the order, :165-169, puts BSHL, BSHR and BSAR there), and emits the same `bcemit_binop` as the infix form (:2447), so they reach the same bytecode and the same recorder path [S]. That `~>>=` lexes as the token `~>>` followed by `=` (:2433-2435 check `ls->c == '='`) is [I] (the lexer was not read).

### 3.2 The operand x, as the recorder hands it over

`oclj_rec_bitarg` (`oclj_bitop_rec.c` :50-70) gives the shifted operand as one of [S]: `CONV i64.int SEXT` of an int-typed ref (:53-54), which `simplify_conv_sext` may fold to the int ref itself (lj_opt_fold.c build copy :1278-1308: the loop index with a SCEV proof of >= 0, or a u8/u16 XLOAD); a KINT64 of a constant number (:57-58), the value `oclj_flt2int` read from an integral double, so in D; or `CONV i64.num x` (`IRCONV_ANY`, :64), which `simplify_conv_i64_num` and `kfold_conv_knum_i64_num` may fold (section 4.1).

### 3.3 The folds that produce, keep or rewrite an i64 BSHL or BSAR

| fold (lj_opt_fold.c build copy) | key | what it does to an i64 shift [S] |
|---|---|---|
| `simplify_shift_ik` :1668-1696 | `BSHL/BSHR/BSAR any KINT` | count 0: `LEFTFOLD` (no shift); BSHL by 1: `ADD x, x`; a count outside 0..63: rewritten to `k & 63`, same op1 |
| `simplify_shift_andk` :1698-1717 | `BSHL/BSHR/BSAR any BAND` | count `j & 63` becomes j, same op1 (x64 masks the count, section 2.1); it needs the count to be an int BAND with a KINT, which the recorder's int-typed count path passes through unchanged (`oclj_bitop_rec.c` :138-139), e.g. LuaJIT's own `bit.band`, recorded as an int BAND; a count from our own `&` arrives as a CONV instead (the table-index fold's `CONV int.i64`) [S][I] |
| `simplify_shiftk_andk` :1747-1773 | `BSHL/BSHR BAND KINT` (not BSAR) | `(x & K) << k` becomes `(x << k) & (K << k)`: a **new** BSHL (or BSHR) of the BAND's op1, built by a nested `lj_opt_fold` (:1766-1767), and the result is the BAND |
| `reassoc_shift` :1901-1926 | `BSHL BSHL KINT`, `BSAR BSAR KINT` | `(x << k1) << k2` becomes `x << (k1 + k2)` (KINT64 0 above 63); `(x ~>> k1) ~>> k2` becomes `x ~>> min(k1 + k2, 63)`; op1 is the inner shift's op1; refuses a PHI-marked `fleft` (:1909) |
| `kfold_int64shift` :426-447 | `BSHL/BSHR/BSAR KINT64 KINT` | a constant operand and a constant count give a KINT64, so no shift remains |
| `simplify_shift1_ki` :1719-1730; `simplify_shift2_ki` :1732-1745 | `BSHL/BSHR KINT64 any`; `BSAR KINT64 any` | a constant operand and a variable count: only operand 0 folds, to 0 (and, for BSAR, operand -1, to -1); every other constant keeps the shift, e.g. `1 << i` stays `BSHL KINT64 1, cnt` (5.4). Revision 1's "a constant: no shift remains" was wrong for this row |
| `simplify_intmul_k` :1471-1487 | `MUL any KINT`, `MUL any KINT64` | `x * 2^k` becomes `BSHL`; for an i64 only through `simplify_intmul_k64`, which returns FAILFOLD without FFI (:1497-1507), and no recorder emits an i64 MUL [S][I] |
| `loop_unroll` (lj_opt_loop.c build copy :318-331) | | re-emits each BSHL/BSAR of the pre-roll on substituted operands, through FOLD and CSE; a literal (constant) op2 is not substituted (:323) |

### 3.4 Not producers of an i64 shift, but producers of the instruction that serves ours (corrected in revision 2)

Revision 1 called the int emitters below "not producers on this build". That is true of the instruction they emit and false of what can serve our i64 op: through CSE they are producers (the refute part's F1; section 8).

**What they emit** [S]:
- **LuaJIT's `bit` library, int ops only.** `recff_bit_shift` (lj_ffrecord.c build copy :800-821) emits int shifts (`IRTI(op)`, :819). `recff_bit_unary` (:773-780) emits int BNOT (`IRTI(rd->data) tr, 0`, :779). `recff_bit_nary` (:783-797) emits int BAND, BOR and BXOR. Their 64-bit paths are under `LJ_HASFFI` (e.g. :802-805).
- **`rec_varg`, int shifts only.** It emits `int BSHL tridx, 3` (lj_record.c build copy :2081, behind select's `ULT tridx - 1, 2^27` at :2080) and `int BSHR tmp, 3` (:2071). None of these emitters makes an i64 shift.

**Why they still produce our op's instruction** [S]:
- `lj_opt_cse` (lj_opt_fold.c build copy :2663-2677) compares `op12` within the opcode's chain and not the type. It returns the existing instruction with that instruction's own type.
- On x64, `simplify_conv_sext` (:1278-1308) LEFTFOLDs our operand's `CONV i64.int SEXT` to the int ref itself (3.2).
- So our `BSHL i, KINT 3` and `bit.lshift(i, 3)`'s `BSHL i, KINT 3` have the same `op12`, and so do our `BNOT i, 0` and `bit.bnot(i)`'s. Whichever is emitted second gets the first's ref and type.
- So an int op can serve our i64 BSHL, BSHR, BSAR, BNOT, BAND, BOR or BXOR, and, through `simplify_shift_ik`'s rewrite of `z << 1`, our ADD.

**Confirmed and scoped.** The main session confirmed this in the forward order, on standalone `luajit.exe` with `bit`: wrong values [M: `claude-tmp/oclj/shiftexact/cse/run-3`]. In game, `bit` is not opened [S]. Section 8 has the mechanism, the measurement, the scope, and why the lemmas and the rule are untouched.

**The rest of revision 1 stands** [S]:
- `lj_crecord.c` is FFI-only;
- `lj_opt_split.c` is a no-op on x64 (guide 4.9);
- `lj_opt_narrow.c` emits no shift (grep of the build copy);
- `lj_snap.c` names none.

**i64 ADD sources.** `simplify_shift_ik` is not the only source of an i64 ADD (2.6, corrected); none of the others matters to E [S][I].

## 4. Which operands at an i64 BSHL/BSAR are exact by construction

### 4.1 The operand kinds

The shifted operand op1 of an i64 BSHL/BSAR, by its source; "E" marks the kinds a rule can recognize from the IR alone (section 5.1) [S unless marked]:

| op1 | source | in D? | in E? |
|---|---|---|---|
| unguarded `CONV i64.num` of a double (op2 0x12ae) | `oclj_rec_bitarg` :64; its loop copy | always: `cvttsd2si` gives the double's integral part or -2^63 (FIX-NUMCONV's fact, `numconv/argue/argument.md` section 3; guide 3.11) [S][M: that argument's `runs/cvt-rt-1`] | yes, `oclj_isnumconv` (`oclj_bitop_fold.c` :170-175) |
| an `IRT_INT` ref: the loop index after `simplify_conv_sext`'s LEFTFOLD; an int from a parent's snapshot; or an int-typed op that CSE returned for one of ours (an int/i64 twin, section 8) | `oclj_rec_bitarg` :53-54, lj_opt_fold.c build copy :1297-1299; a twin's producers, 3.4 | yes: an int32, sign- or zero-extended, so of magnitude below 2^32 (C1) [I]. A twin's value is the int op's 32-bit result, zero-extended: in D, but not the interpreter's value [M: section 8.2][I] | yes, the bound scores it 33 (`oclj_bitop_fold.c` :76) |
| `CONV i64.int` | the same, unfolded | yes | yes, 32 or 33 (:79-81) |
| an I8..U16 ref (`string.byte`'s u8 XLOAD after the LEFTFOLD) | lj_opt_fold.c build copy :1285-1286 | yes, below 2^16 [I] | no: the bound scores it 64 (:77). A range fact; scoring it belongs to roadmap row 211 (1), not here |
| KINT64 | `oclj_rec_bitarg` :57-58 (in D); `kfold_conv_knum_i64_num` (`cvttsd2si`, in D) | for every constant that can be a shift's op1 [I: fold-made constants outside D, such as `simplify_shiftk_andk`'s `K >> k` for a negative K, appear only as a BAND's op2] | yes, tested by value (`oclj_bit2num`) |
| any ref the bound puts at 54 or less | `oclj_bitwidth` | yes, in [-2^53, 2^53) (C1) | yes |
| a BSHL or BSAR of an E operand | the recorder, `reassoc_shift`, `simplify_shiftk_andk`'s nested shift, the loop copy | yes (Lemmas BSHL, BSAR) | yes, recursively |
| a BSHL by a constant of 10 or more, any op1 | the same | yes (Lemma BSHL10) | yes |
| `ADD z, z` with z in E | `simplify_shift_ik` | yes (2.6) | yes |
| a BAND of two E operands | the recorder; `simplify_shiftk_andk`'s result | yes (Lemma BAND) | an option (section 5.1) |
| an earlier operator's result, BOR, BXOR, BNOT, BSHR (or a BAND or shift that is not E), reached through the exact-mark rule | `oclj_rec_bitarg`'s `i` folded to `res0` (lj_opt_fold.c build copy :1183-1185) | yes, at run time, past res0's guard or the proof that removed it (S1) [I] | no (section 4.3) |
| a fold intermediate with no guard of its own, e.g. `simplify_shiftk_andk`'s BSHR | lj_opt_fold.c build copy :1766-1767 | not necessarily: `((x & -2) >> 1)`'s inner BSHR of x = -1 is 2^63 - 1 [I] | no |

### 4.2 Not exact by construction: BOR, BXOR, BNOT, ADD, BSHR

Section 2.8's counterexamples apply to the IR as they stand [I]: a BOR, BXOR or BNOT of E operands can be outside D (2^53 | 1, 2^53 ~ 1, ~2^53), so can an ADD of two different refs and a BSHR by 1..10 of a negative value. A rule that took any of them as E would remove guards that can fail, unless something else (its own guard) made it exact; section 4.3 is that case. BAND is the exception (Lemma BAND).

### 4.3 "A bit op's result after its result guard": exact at run time, invisible in the IR

When a shift's operand is an earlier result `d0`, `oclj_rec_bitarg`'s `i = CONV i64.num d0` folds by the exact-mark rule to `res0`, and the shift's op1 is `res0` [S]. Past res0's guard (emitted right after res0, S1) or past the proof that removed it (the width rule, FIX-NUMCONV, this rule), res0 is in D, and the shift of it is in D by the lemmas, so its guard can never fail either [I]. In fact, on this build, **every op1 of a guarded i64 BSHL/BSAR is in D at run time** [I]: a recorded shift's op1 is `oclj_rec_bitarg`'s value, each of whose outcomes (an int, a constant from a double, `cvttsd2si`, an exact-marked result, a width- or FIX-NUMCONV-proved value) is in D; `reassoc_shift` replaces it by the inner shift's op1, which is one too; and `simplify_shiftk_andk`, the one fold that builds a shift on a possibly inexact intermediate, makes the result a BAND, not a shift. So today every result guard of an i64 BSHL/BSAR is one that cannot fail [I]. Section 8's twins leave this true [I]:
- a twin replaces our shift by an int op, whose `res` is INT-typed, and the width rule drops its guard;
- a twin used as an operand is an int value, in D.

**A rule should not lean on that** [I]:
1. It is a global property of the recorder and of every fold, not a local fact about the instruction: a new recorder path, a new fold, or FFI (which emits i64 shifts of its own, `lj_crecord.c`) could hand a shift an inexact operand, and the rule would then remove a guard that can fail. A local predicate stays true under such changes.
2. The IR keeps no trace of res0's guard at the shift. To read it, a rule would look for res0's marked `d0 = CONV num.i64 res0` (op2 0x5d5) or its `EQ.i64` guard by walking `J->chain[IR_CONV]` or `J->chain[IR_EQ]`, and would then have to argue that what it found precedes the shift in every copy, across PHIs and CSE in the loop body: P55's territory (guide 8.4a), and a fact justified by another guard, which S2 permits only for a different guard and which the guide's rules have so far never used.
3. Lemma BSHL10 already gives the counts of 10 or more without any operand fact.

So the first rule should recognize E structurally and leave the rest to a later decision (open points). What it misses is a speed matter only: such a guard stays and never fails.

### 4.4 Why E's recursion stops at BOR, BXOR, BNOT and BSHR even where they are guarded

E is a property of the instruction's opcode tree. A BOR in the IR may be a guarded recorded result (in D at run time) or, in principle, an intermediate; E cannot tell which, so it refuses both [I]. This is the same discipline as the width rule's: `oclj_bitwidth` scores a guarded BOR of two doubles 64, though its value is in D past the guard [S: `oclj_bitop_fold.c` :87-90].

### 4.5 Loops: PHIs and the loop copy

The argument follows `numconv/argue/argument.md` section 4.6 [S][I]:

- **Where it sits.** Inside fix1's `if` (`(fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && irt_isi64(fins->t) && (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))`, lj_opt_fold.c build copy :1177-1178) and before `PHIBARRIER` (:1199), like the three rules there. y = `fleft->op1` is an i64 BSHL, BSAR or ADD, so fix1 never refuses it.
- **Requirement 2 and S4.** It returns an existing ref, y, whose type I64 is the folded instruction's; `loop_unroll`'s type check (lj_opt_loop.c build copy :343-352) sees equal types.
- **S5: what it reads.** y's opcode and IR type; for BSHL10, y's count, a KINT (a literal operand the copy never substitutes, :323); for `ADD z, z`, the equality of its two operand refs, which the copy keeps (`ADD subst[z], subst[z]`); and, recursively below y, opcodes, IR types, KINT64 values and `oclj_bitwidth`, which reads only opcodes, types and constants (S5's instance). No run-time value, no guard, no mark.
- **Why the fact holds in every iteration: induction on execution order.** Revision 2 restates this. Revision 1 used induction on n's depth in E's tree, and the refute part's F6 showed that order is cyclic through a PHI.
  - *The order.* A run of the trace executes the pre-roll once (iteration 1), then the body in iterations 2, 3, ... until an exit. Within an iteration, instructions run in IR order. Order a run's events by (iteration, IR position). Every operand value an instruction reads was produced strictly earlier in this order, by one of three:
    - a lower ref in the same iteration;
    - the pre-roll, for an invariant ref read in the body;
    - for a PHI-marked pre-roll ref n read in the body in iteration t: the pre-roll itself when t = 2, or n's copy `subst[n]` in iteration t - 1.

    A run is finite, so the order is well-founded.
  - *The claim.* On every run, every value produced by an instruction that stands for an E-accepted node is in D. "E-accepted" means accepted by `oclj_isexact` or `oclj_isexactshift` as the IR stood when the rule read it, or the rule's subject y.
    - A pre-roll node n is stood for by n itself in iteration 1, and by `subst[n]` in each body iteration (the PHI carries its value).
    - A body node is stood for by itself.

    Consequently no guard the rule removes could ever have failed, and removing it changes no value (Lemma D).
  - *The step.* Take the earliest event at which the claim would fail: an instruction x that stands for an E-accepted node n.
    - **n is a leaf.** x's value is in D without the hypothesis:
      - a KINT64 that is in D (tested by value);
      - an unguarded `CONV i64.num` of a double: every value is `cvttsd2si`'s, whatever the input (FIX-NUMCONV's fact);
      - an INT-typed ref: an int32 sign-extended, or a 32-bit result zero-extended (C1). This includes a twin (section 8);
      - a value the bound puts at 54 or less (S5's instance for the bound, carried by the bound's own argument).
    - **n is a BSHL or BSAR of an E-accepted op1.** x computes n's opcode on the value of op1's representative. That value was produced strictly earlier, so it is in D by minimality, and Lemma BSHL or BSAR applies.
    - **n is a BSHL by 10 or more.** Nothing is needed (Lemma BSHL10).
    - **n is an `ADD z, z`.** It uses z's value, which is in D by minimality (2.6).
  - *The premise, and where the order matters.* The step assumes "x computes n's opcode on its operands' representatives' values", that is, folds and CSE preserve values. Three mechanisms matter:
    - **Upstream's folds.** That they preserve values is an assumption, as in S5 [I].
    - **The exact-mark fold.** `CONV i64.num` of a marked `CONV num.i64 r` becomes r. This preserves the value only if r's value is in D at that event. That holds for one of two reasons:
      - r's guard, emitted right after r (S1), ran earlier;
      - or a proof removed r's guard, and that proof's claim holds at an earlier event. For this rule, that claim is the induction hypothesis itself.

      This is where the depth order failed, in the refute part's `h = h << 3`. In the body, the copy of the operand's conversion folds to the PHI-marked pre-roll shift y0. y0's value in iteration t is the body shift y1's value from iteration t - 1, and y1 is the very shift whose guard the rule removed because E(y0) held. Execution order is well-founded here: y1 in iteration t - 1 precedes y1 in iteration t.
    - **CSE.** It preserves values, except for an int/i64 twin (section 8). There x is an int op, not n's opcode. Its value is a 32-bit result zero-extended, in [0, 2^32), so in D by C1 [I]. So the claim's conclusion survives where the premise does not.
  - So this is S5's induction with "in D" in place of "bounded", ordered by execution [I]. Like S5 for the width rule, it assumes that upstream's copy-substitution and fold rules preserve values past the guards before them. Guide S5's own wording, "by induction over the pre-roll's DAG", has the same form. Whether the width bound meets the same cycle through the exact-mark fold was not examined; if it does, the same reordering applies [I].
- **It adds no PHI.** When `fleft` is PHI-marked, it is a pre-roll `CONV num.i64 F` that the copy of `d` CSE'd to (PHI marks go only on pre-roll refs, lj_opt_loop.c build copy :334-341), so `F->op1 == subst[res]`: res's copy returned that pre-roll y, which `loop_unroll` PHI-marked then. Returning y adds nothing. If `fleft` is an unmarked pre-roll ref, `d` was invariant, `back`'s copy took the invariant shortcut (:324-326) and no fold ran.
- **TYPEINS cannot arise from it**: y is I64.
- **It emits nothing on the side** (P55 does not apply) [S].

### 4.6 Snapshots, exits, side traces, DCE, option sets

As for FIX-NUMCONV (`numconv/argue/argument.md` sections 4.1-4.5, 4.7) [S][I]: the rule makes `back` = y, so `EQ.i64 y, y` reaches `comm_equal` (lj_opt_fold.c build copy :2038-2049), which drops it (`!irt_isnum`); nothing else consumes `back`; the guard had no snapshot of its own, and a dropped guard does not set `J->guardemit`, so a later snapshot may merge into the previous one by upstream's own mechanism, the one the width rule's drops already trigger; no side trace can hang on an exit that is never taken; a guard is a DCE root and `back` is never emitted. Under `-O-fold` no rule runs; under `-O-cse` rules run and `comm_equal` still drops the EQ; under `-O-loop` there is no copy. The double `d` stays: slots and snapshots name it (S6), so a bit result still crosses a trace boundary as its double.

## 5. What a rule could read

### 5.1 The precondition (a sketch, not implemented)

In the style of `oclj_isnumconv`, in `oclj_bitop_fold.c`, below it (it calls it and `oclj_bitwidth`), with a forward declaration for the mutual recursion [I]:

```c
static int oclj_isexactshift(jit_State *J, IRRef ref, int depth);

/* E: the int64 IR value ref is exactly a double by construction.  Leaves: a
** KINT64 that is one, a value the bound puts in [-2^53, 2^53), an operand's
** own conversion of a double; and a shift that oclj_isexactshift accepts.
** Exactness, not a range: never scored in oclj_bitwidth. */
static int oclj_isexact(jit_State *J, IRRef ref, int depth)
{
  IRIns *ir = IR(ref);
  double d;
  if (ir->o == IR_KINT64) return oclj_bit2num(ir_k64(ir)->u64, &d);
  if (oclj_bitwidth(J, ref, 0) <= 54 || oclj_isnumconv(J, ref)) return 1;
  return depth <= 6 && oclj_isexactshift(J, ref, depth);
}

/* SHIFT-EXACT: y is exactly a double because of its opcode: a left shift by
** a constant of 10 or more (a multiple of 2^10, whatever its operand), or a
** left or arithmetic right shift by any count, or z + z (simplify_shift_ik's
** z << 1), of an exact operand. */
static int oclj_isexactshift(jit_State *J, IRRef ref, int depth)
{
  IRIns *ir = IR(ref);
  if (!irt_isi64(ir->t)) return 0;
  switch (ir->o) {
  case IR_BSHL:  /* By 10 or more: Lemma BSHL10.  Else as BSAR. */
    if (irref_isk(ir->op2) && IR(ir->op2)->o == IR_KINT &&
        (IR(ir->op2)->i & 63) >= 10)
      return 1;  /* Lemma BSHL10. */
    /* fallthrough */
  case IR_BSAR:  /* Lemmas BSHL and BSAR, any count (taken & 63). */
    return oclj_isexact(J, ir->op1, depth+1);
  case IR_ADD:  /* z + z is z << 1. */
    return ir->op1 == ir->op2 && oclj_isexact(J, ir->op1, depth+1);
  default:
    return 0;
  }
}
```

The rule, in `simplify_conv_i64_num`: `if (oclj_isexactshift(J, fleft->op1, 0)) return fleft->op1;`.

**What each test is for** [S][I]:
- The opcode tests are the subject: BSHR, BNOT, BOR, BXOR and ADD of two refs are not exactness-preserving (2.5, 2.8); BROL/BROR are never i64 here and are not accepted.
- `irt_isi64`: an int-typed BSHL/BSAR is a 32-bit shift with its count & 31 (`lib_bit`), and returning an int ref for an i64 conversion would break requirement 1. This is unreachable here, because the width rule, the first rule in fix1's block, takes any int-typed y at 33. It is stated as a precondition, as FIX-NUMCONV's type tests are.
  - It is also what refuses an int/i64 twin (section 8): `res` is then the int op, INT-typed. The width rule takes such a y first; this test would refuse it anyway [S].
- `irref_isk(op2) && KINT` before reading `->i`: a variable count is a ref whose value BSHL10 cannot read.
- `ir->op1 == ir->op2` for ADD: this is the lemma's precondition (2.6). Upstream can make other i64 ADDs (2.6, corrected in revision 2). No such ADD was found where E looks, at a bit result or below its shifts [I]. So the test may never filter anything today, and it is kept for soundness, whatever made the ADD.
- KINT64 by value: a fold-made constant can be outside D (4.1), though none reaches a shift's op1 [I].
- The depth bound (6, as `oclj_bitwidth`'s) only makes it conservative; the recursion terminates anyway (operand refs are lower, constants are leaves). Its cost: each level of E calls `oclj_bitwidth`, at most 255 calls (a binary tree of depths 0 to 7), along a chain of at most 7 shifts: about two thousand calls in the worst case per guard folded, a handful in the shapes of 5.4 [I]. A later round may prefer to test the leaves without the full bound.
- **The BAND option** (Lemma BAND), if the user wants it: `case IR_BAND: return oclj_isexact(J, ir->op1, depth+1) && oclj_isexact(J, ir->op2, depth+1);` on a line of its own in this switch, with the function renamed for what it then holds (exactness-preserving operators), its own comment, and its own arm (5.6). It would also remove a BAND result's own guard when both operands are E (`x & y`, `x & -256` on doubles; `simplify_shiftk_andk`'s `(x << k) & (K << k)`), which is a change beyond the shift claim.

**What it does not read**: no guard, no mark (`OCLJ_IRCONV_EXACT`), no run-time value, nothing of a variable count but that it is not a constant [S].

### 5.2 Where it would sit in lj_opt_fold.c

In `simplify_conv_i64_num` (build copy :1169-1212), inside fix1's block (:1177-1198), as a fourth rule on a line of its own **after** FIX-NUMCONV's (:1196-1197) and before the block's closing brace (:1198), so before `PHIBARRIER` (:1199) [S][I]:
- After the width rule: the width rule is cheaper and takes every y bounded at 54; a y it takes never reaches this line, which is why E's leaves may assume nothing about y's own bound.
- After FIX-NUMCONV: O(1), and its y (a CONV) is never a shift. Order changes no value: each rule returns the same ref, y.
- Before `PHIBARRIER`, so it fires across a PHI (4.5).
- Its own comment (why it holds, the two lemmas and BSHL10, "exactness, not a range: never in `oclj_bitwidth`").
- `patch-bitop-fold.sh` (hunk 7, :216-248) gains the lines, `NADD` grows, and `verify_content` (:462-489) gains: the call named once; the call below FIX-NUMCONV's (`LN`) and above the block's `  }` directly above the PHIBARRIER; and the call followed directly by its own `      return fleft->op1;` (the code verifier's m11 lesson). The header's hunk-7 text says "three rules" (:48), which becomes four.
- `build-native.sh`'s `bitop_wgate.c` calls each new static function (checklist item 15), or `-Wunused-function` fails the warning gate.
- Never merged into the width rule's line or into `oclj_isnumconv` (P62): two proofs on one line break `verify_content`'s count of `<= 54)` and negctl's WIDTH55 and NUMCONV anchors, and leave no one-line arm for the new proof alone.

### 5.3 Why it must never enter oclj_bitwidth

`oclj_bitwidth` is a range, and a range composes through every operator above it; exactness and divisibility do not (P60, guide 3.11) [S][I]. Two ways a scored shift would go wrong [I]:
- **Through BOR, BXOR, BNOT.** With a shift of an exact operand (or by 10 or more) scored 54, `(x << 20) | 1` scores max(54, 2) = 54 and loses its guard; for x = 2^40, (2^60) | 1 = 2^60 + 1 is outside D, the interpreter raises, and the trace would return 2^60. Likewise `~(x << 20)` and `(x << 20) ~ y`.
- **Through BSAR into the table-index fold.** `(x << 20) ~>> 22` would score 54 - 22 = 32 and reach the table-index fold (`oclj_bitwidth(...) <= 32`, lj_opt_fold.c build copy, simplify_conv_int_num), which would truncate to the low 32 bits: for x = 2^40, (2^60) ~>> 22 = 2^38, whose low 32 bits are 0, a different table key or count.

So the fact lives in its own predicate, read by its own rule line, and an arm holds that line by putting the fact into the bound (SHIFTW, 5.6). A sound way to make divisibility compose would be a second abstract fact beside the bound, a lower bound on trailing zeros (a BOR or BXOR keeps the smaller, a BAND the larger, a left shift by k adds k, an arithmetic right shift by k subtracts k): a value bounded at w bits with at least t trailing zeros is in D when w - t <= 54, so `(x << 20) | (y << 30)` would qualify. That is a new design, not proposed here (open points).

### 5.4 The shapes it would affect

Expected result guards (`EQ.i64`) per shape, today and with the rule, read from the code [S][I]; nothing here was run, and section 6.3 lists the IR reads to make. "x" is a double from a table slot (op1 = `CONV i64.num`).

| shape | IR result (after folds) | today | with the rule | why |
|---|---|---|---|---|
| `x << 20` (guide 3.12) | `BSHL i, 20` | kept (bound 64) | gone | BSHL10; and i in E |
| `x << 3` | `BSHL i, 3` | kept | gone | Lemma BSHL, i in E |
| `x << 1` | `ADD i, i` | kept | gone | 2.6 |
| `x ~>> 3` | `BSAR i, 3` | kept (61) | gone | Lemma BSAR |
| `x ~>> 22` | `BSAR i, 22` | gone (42, the width rule) | gone | unchanged |
| `x >> -3`, `x ~>> -3` | `BSHL i, 3` | kept | gone | Lemma BSHL |
| `x << i`, `x ~>> i` (variable) | `BSHL/BSAR i, cnt` | kept (64) | gone | Lemmas BSHL, BSAR (count & 63) |
| `1 << i` | `BSHL KINT64 1, cnt` | kept | gone | KINT64 1 in D |
| `i << 40` (i the loop index) | `BSHL i, 40` | kept (73 -> 64) | gone | BSHL10; i in E (33) |
| `((a >> 42) << 32) \| 1` (review1's shape) | `BSHR` (23, gone today), `BSHL` (55), `BOR` (55) | BSHL kept, BOR kept | BSHL gone, **BOR kept** | BSHL10, op1 bounded at 23; BOR is no exactness-preserving op, and can be outside D (a = -1 gives (2^22 - 1) * 2^32 + 1) |
| `(x << 8) << 8` | `BSHL i, 16` (`reassoc_shift`) | both kept | both gone | the inner by Lemma BSHL, the outer BSHL10 |
| `(x << 20) ~>> 3` | `BSAR (BSHL i, 20), 3` | kept | gone | recursion |
| `x >> 1`, `x << -1` (logical) | `BSHR i, 1` | kept | **kept** | BSHR is not exact (-1 >> 1) |
| `(x << 20) \| 1`, `~(x << 20)`, `(x << 20) ~ y` | BOR / BNOT / BXOR of a shift | outer kept | outer **kept**, inner gone | 2.8 |
| `(x \| 1) << 4` | `BSHL (BOR ...), 4` | kept | kept | op1 a BOR, not E (4.3); its guard cannot fail |
| `(x \| 1) << 16`, `(a ~ b) << 24` | `BSHL (BOR/BXOR ...), k >= 10` | kept | gone | BSHL10, whatever the operand |
| `h = (h << 5) ~ c` in a loop (hash) | body: `BSHL (BXOR res), 5` | kept | pre-roll's gone (h a slot's double), **body's kept** | op1 in the body is the carried BXOR (4.3) |
| `(x & 0xff) << 50` | `BAND (BSHL i, 50), 0xff << 50` (`simplify_shiftk_andk`) | kept (59) | kept, unless the BAND option | the result is a BAND; BAND(E, E) by Lemma BAND |
| `x & y`, `x & -256` | `BAND i, j` | kept (64) | kept, unless the BAND option | Lemma BAND |
| `string.byte(s, k) << 3` | `BSHL (u8 XLOAD), 3` | kept | kept | the XLOAD scores 64; row 211 (1)'s |

Per guard removed: one `cvttsd2si`, one `cmp` and one `jnz` and its exit, as FIX-NUMCONV's [S: numconv's argument section 3, the dump]. What that buys in time is to be measured.

### 5.5 Tests a later round would need (not written here)

Following guide 8.4 and the nc part (11.5c) [I]:

1. **A value suite**, e.g. `t_shiftexact.lua` in `test/native/bitop/`, with a PUC twin through `twin.lua`, run against `-joff` under `SELOPTS`' 15 sets. Forms: the rule's (`x << k` for k in {2, 3, 9, 10, 11, 20, 52, 53, 63}, `x << 1`, `x ~>> k` for k in {1, 3, 9, 63, 64, 100}, `x >> -k`, `x ~>> -k`, `x << i`, `x ~>> i`, `1 << i`, `-1 << i`, `(-2^63) ~>> i`, `i << 40`, `(x << 8) << 8`, `(x << 20) ~>> 3`, `(x | 1) << 16`); the controls whose guards must stay (`x >> 1`, `x << -1`, `x >> i`, `(x << 20) | 1`, `~(x << 20)`, `(x << 20) ~ y`, `((a >> 42) << 32) | 1`) and the honest misses (`(x | 1) << 4`, the hash idiom). Modes p, c and s as t_numconv's (a table's double, a carried result, a PHI-crossing operand). Each loop records on small values, then the same compiled loop, with no branch between, meets the big ones: 2^53, -2^53, 2^53 - 1, 2^63 - 1024, -2^63, 3 * 2^61, -0.0, odd values near 2^53, and raising operands (NaN, +-inf, 2^63, 1.5, -2^63 - 2048); the controls must raise exactly where `-joff` does. A coverage gate as `ncin`: the rule's precondition present in the IR (a BSHL/BSAR whose op1 is an unmarked `CONV i64.num`) in the run that counts.
2. **An IR read**, e.g. `seir.lua`, as ncir: `sig`, the `EQ.i64` guards whose right operand is an i64 BSHL/BSAR (or `ADD z, z`) whose op1 is an unmarked `CONV i64.num` of a double (op2 & 0x7ff = 0x2ae), a KINT64 or an int ref, keyed on operands (P56), must be 0 for the rule's forms; the controls' guards must be present (at least 1 in the first trace's pre-roll); a shift by 10 or more of a BOR must read 0 (BSHL10). A loop that meets the PHI case (ncir's swap1 pattern: the guard's `fleft` PHI-marked; `phiF` >= 1, the body's guard 0; every loop a `stop`, JFORL, no TYPEINS). It refuses `-O0` and `-O-fold` (P61) and requires its summary line (the ncir lesson). Fail-first: on `build/native` (HEAD `1a13bed`, `lj_opt_fold.o` `f6d916e2`), `sig` must be nonzero, so the IR read FAILs there, while the value suite passes.
3. **ncir's reclassification**: its form `shl1` (`x << 1`, class "keep", `test/native/bitop/ncir.lua` :108) records as `ADD y, y` and would lose its guard under the rule, so ncir would FAIL on the new build; it moves to the new rule's class (or to the new IR read), and ncir's header comment on it (:76-77) is updated. t_numconv's controls `x << 1` and `x ~>> 1` (`t_numconv.lua` :26-27, :104) are value-level only and stay correct, but its header's "controls whose guard must stay" no longer holds for them.
4. **The generator**: gen's shift atoms (`test/native/bitop/gen.lua` :93-117, :156-205) already meet the rule; re-run gen, genrg2 and the fuzzer (mode U) under the option sets. Consider atoms with a variable count on an exact operand meeting big values (`x << (i & 63)`, `1 << (i & 63)`).
5. **A PUC check of the lemmas**, cheap: every e and k in 0..63 with edge odd parts m (1, 3, 2^52 + 1, 2^53 - 1, both signs) and random ones, for BSHL, BSAR, BSHL10 (any x, k >= 10) and BAND pairs; with the controls that must find counterexamples (BSHR, BOR, BSHL by 9 on inexact x). Section 6.3.
6. **Timing**, as FIX-NUMCONV's step 1: identity-style loops of the rule's forms against `build/native`, alternating, ratios to a same-run reference.

### 5.6 negctl arms a later round would need

Each one line, anchored once, memory-safe by negctl's property 8 [I]:

| arm | file, anchor | change | visible as | catcher |
|---|---|---|---|---|
| **SHIFTOP** (the fix site) | `oclj_bitop_fold.c`, the sketch's line `  case IR_BSAR:  /* Lemmas BSHL and BSAR, any count (taken & 63). */` | `  case IR_BSAR: case IR_BSHR:` | a value: `x >> 1` for x = -2 loses its guard and returns 2^63 (rounded) where the interpreter raises | the value suite's BSHR controls on negative values; gen [I: margins to be measured] |
| **SHIFTW** (the design trap, P60) | `oclj_bitop_fold.c`, `oclj_bitwidth`'s whole line `  case IR_BSHL:` (:98; unique as a whole line because the sketch's BSHL case carries a comment; count it in every copy) | `  case IR_BSHL: if (IR(ir->op1)->o == IR_CONV && (IR(ir->op1)->op2 & IRCONV_SRCMASK) == IRT_NUM) return 54;` | a value through composition: `(x << 20) \| 1` for x = 2^40 returns 2^60 | the value suite's `(x << 20) \| 1` rows; gen |
| **SHIFTOFF** (coverage; no value changes) | `lj_opt_fold.c`, the rule's line | `if (0 && oclj_isexactshift(...))` | only in the IR | the IR read alone (P61), as NUMCONVOFF is ncir's |
| **SHIFT9** (BSHL10's threshold; no value changes on this build) | the BSHL10 line `(IR(ir->op2)->i & 63) >= 10)` | `>= 9)` | only in the IR (every guarded shift's operand is in D at run time on this build, 4.3, so no value changes) | the IR read: `(x \| 1) << 9`'s guard must stay |
| **ANDOP** (only with the BAND option) | the BAND case's line | `case IR_BAND: case IR_BOR:` | a value: `x \| 1` for x = 2^53 | the value suite; gen |

Memory safety [S][I]: SHIFTOP reads a BSHR's op1, a ref (lj_ir.h build copy :63, `BSHR ref ref`); SHIFTW reads a BSHL's op1 (a ref, :62) and that instruction's op2 as a field, never as a ref, and its 54 can let the table-index fold truncate `(x << k) ~>> j` for j >= 22, a different int checked by the same ABC, length check or `ULT 64` as WIDTHIDX33's; SHIFTOFF only keeps guards; SHIFT9 removes only guards that cannot fail on this build; ANDOP reads a BOR's two refs. All let a fold take an inexact value as exact: a wrong value, never an address.

**No arm** (preconditions stated, as the user decided for FIX-NUMCONV's type tests on 2026-10-21) [I]: the `irt_isi64` tests, ADD's `op1 == op2`, the KINT64 value test and the depth bound: no test can show one matters on this build (4.1, 4.3).

**Existing arms to re-measure** on a build with the rule, since it removes guards some catches may have passed through [I]: WIDTH55, WSHR, WSHL0 (`negctl-bitop.sh` :810-812 anchors on `oclj_bitwidth`'s BSHL line :100, so SHIFTW must anchor elsewhere), WBAND, WADD0, SELFGUARD, KFOLD64, the table-index fold's three, NUMCONVOP1 (whose widened range BNOT..BSAR includes BSHR, which stays value-visible, `negctl-bitop.sh` :831-833), NUMCONVW, NUMCONVOFF and NUMCONVNOOP (whose dropped opcode test now also reaches E's `oclj_isnumconv` leaf). Canon's catcher list gains the new part.

### 5.7 Upkeep a later round would carry (checklist item 9's grep)

[S] The sentences that name the rules that remove a result guard: guide 2.6 ("two rules do"), 3.9 ("What the mark means", both bullets), 3.10's title and table, 3.11's last two bullets and 3.12's `x << 20`, S2's instance list (9.2), S5's instance (9.5), Appendix B's FIX-NUMCONV entry; `oclj_bitop.h` :118-123 ("or the width rule proved it", "only the width rule may remove it", stale since FIX-NUMCONV); `oclj_bitop_rec.c` :35-37 and :147-149 ("which only the width rule removes", stale since FIX-NUMCONV); `oclj_bitop_fold.c`'s header (:1-56) and FIX-NUMCONV's comment (:120-169); `patch-bitop-fold.sh`'s header (:48-79); roadmap row 211 (5)'s last sentence.

Added in revision 2, the review's F1 and F7 [S]:
- guide 3.9's CSE bullet ("It does not compare the type"), which should name the twins' consequence (section 8);
- S5's (9.5) premise "folds and CSE preserve values" and its "induction over the pre-roll's DAG" (4.5);
- guide 3.11's table and `oclj_bitop_fold.c` :93's comment, which say an int64 ADD comes only from `x << 1` (2.6).

## 6. Platform scope, and what is [S], [I] or still to be measured

### 6.1 x64 only, through one leaf

- **The lemmas are target-free** [I]: Lemmas D, De, BSHL, BSAR, BSHL10 and BAND are statements about two's-complement int64 and IEEE doubles.
- **The IR's shift semantics** (count & 63, wrapping) are read for x64 [S: section 2.1]; LuaJIT's other 64-bit backends also mask a 64-bit shift's count to 6 bits [I: not read].
- **The leaves**: the bound and the KINT64 test are target-free; an int-typed op1 is exact on any target. The `oclj_isnumconv` leaf is x64's alone: arm64's `fcvtzs` saturates to 2^63 - 1, which is not in D (FIX-NUMCONV's argument section 6). Worse, there the operand guard has a hole at x = 2^63 (i = 2^63 - 1 passes `EQ.num`), so `x ~>> 1` would give 2^62 - 1, outside D: today its result guard exits and the interpreter raises 5.3.6's "number has no integer representation"; with the rule the trace would return a value [I]. Moot while aarch64 is parked (guide 1.1; build-native.sh refuses any machine but x64) [S]; a port must re-argue or drop that leaf.
- **The guard's own check**: on x64 it passes exactly on D (Lemma D) [I].
- So: **x64 only, as FIX-NUMCONV**, because of the one leaf; the rule without that leaf would be target-free given the IR semantics [I].

### 6.2 Ledger

| claim | mark |
|---|---|
| The three tests and their code | [S] |
| Lemma D (the tests pass exactly on D, every rounding mode) | [I: proof]; x64 instruction behaviour [I: Intel SDM]; the round trip on doubles [M: FIX-NUMCONV's `cvt_rt.c` run, which measured `cvttsd2si` outputs, not arbitrary int64] |
| Lemmas De, BSHL, BSAR, BSHL10 (and its tightness), BAND; ADD z, z; the counterexamples | [I: proofs] |
| PUC agrees on BSHL and BSAR, 25.6 million pairs | [M on PUC: `crc2/docs/shiftexact-1`] |
| The PUC-made expectations agree on BSHL, BSAR, BAND | [S: t_ops.expect, t_sar.expect] |
| Every count is taken & 63 | [S] code; [I] the hardware's masking (SDM) |
| Which Lua forms reach BSHL/BSAR; compound forms | [S]; the lexing of `~>>=` [I] |
| The folds that make or keep shifts; the non-producers; the int emitters that serve our ops through CSE (3.4, revision 2) | [S] |
| An i64 ADD can come from upstream's I64 SUBs too; E is unaffected (2.6, revision 2) | [S]; that one of those SUBs has a constant right operand [I], not traced |
| Every guarded shift's op1 is in D at run time on this build | [I] (4.3) |
| The rule's soundness in loops (4.5, by induction on execution order) | [S][I]. It assumes upstream's folds preserve values. The exact-mark fold's value preservation comes from the induction hypothesis. CSE's holds except for int/i64 twins, whose values are in D (section 8) |
| Int/i64 CSE twins give wrong values in the forward order: `bit.lshift(i, 3)` then `i << 3`, and `bit.bnot(i)` then `~i`, 341 of 401 each | [M: `claude-tmp/oclj/shiftexact/cse/run-3`, the main session's run] |
| The twins' other members: BSHL by another constant in 2..31; BSHR or BSAR by a constant in 1..31 (equal) or by a variable int count (differs at 32 or more); BAND, BOR and BXOR; `ADD z, z`. A constant count of 32 or more in ours never twins, and nothing twins under `-O-fold` (8.1, revision 3) | [S] that their op12 can match, and the fold that keeps a constant count of 32 or more from matching; [I] which values differ (8.1); not measured |
| The twins do not reach the mod in game | [S] `bit` is not opened and FFI is off; [I] `rec_varg`'s BSHL and narrowing's stripped `ADD z, z` give the same value (8.3) |
| The reverse order puts an I64-typed TRef in a Lua slot, which `snap_restoreval` has no case for | [S] from reading the code; [I] its effect; never run (8.6) |
| Expected IR per shape (5.4) | [I] from the code; not read in a dump |
| The arms' visibility and catchers | [I] |
| x64 only through `oclj_isnumconv` | [S][I] |

### 6.3 Still to be measured (all deferred by the hard rule)

1. **The lemmas on PUC and on `-joff`**, a structured check (5.5 item 5): seconds of CPU; would make Lemmas BSHL, BSAR, BSHL10 and BAND [M] beside [I], with controls that must find counterexamples (BSHR, BOR, BSHL by 9 on an inexact x from a string). BAND has never been measured.
2. **The base build's IR** for 5.4's shapes (`-jdump=+rsT` and a `traceir` count of the result guards), to confirm the "today" column, especially that `(x & 0xff) << 50` ends as a BAND and `x << 1` as `ADD i, i`.
3. **After a prototype**: the "with the rule" column; the value suite and IR read under every option set; gen, genrg2 and the fuzzer; the arms' margins over at least three runs; canon and restore.
4. **Timing**, as FIX-NUMCONV's chain, and how often real code meets the rule, BSHL10 and the misses (the hash idiom), for instance in the harness's CRC32, SHA-256 and FNV loops.
5. **The CSE twins' other members** (section 8.1's table), by value, forward order only, against `-joff`. This belongs to the fix round (8.5), not to the shift rule. The reverse order is never to be run (8.6).

## 7. Doubts and limits

- **The proofs are mine, and have had one review.** The refute part checked them by hand and could not break them [I: `refute/notes.md`, "What I tried and could not break"]. Lemma BAND contradicts the brief's list, and Lemma BSHL10 is stronger than the guide's measured claim. No script checks either yet (the refute part's F2). Each still wants 6.3 item 1 before a rule reads it.
- **"Every guarded shift's operand is in D at run time" (4.3) is a whole-build claim** read from the recorder and the folds I found; a fold I missed that builds a shift on an unguarded intermediate and returns it as a result would break it. The proposed rule does not depend on it; only the arms' visibility (SHIFT9, the no-arm list) does.
- **5.4's table is predicted, not read.** Fold order matters (`simplify_shift_ik` turns `x << 1` into an ADD before any shift rule can see it; `reassoc_shift` and `simplify_shiftk_andk` reshape chains), and the guide's own history has a mechanism traced on one loop and later found too narrow (8.4 item 8).
- **4.5's induction assumes upstream's copy-substitution and folds preserve values** past the guards before them, as the width rule's and FIX-NUMCONV's arguments do [I].
  - CSE does not preserve values for int/i64 twins (section 8). There, 4.5 concludes membership in D directly from the twin's int value, which rests on x64's zero-extended 32-bit registers [I].
  - Revision 1 stated the induction on the depth of E's tree, which is cyclic through a PHI (the refute part's F6). Revision 2 orders it by execution.
- **"Not in game" for the twins (8.3) is a reading, not a census.** It covers the int producers found by grepping the recorders and folds, and it is [I] for `rec_varg` and for narrowing's stripped ADD. A fix round should grep again.
- **The BAND option and the trailing-zero design widen the round**; both are outside the brief and left to the user.

## 8. A separate bug: int/i64 CSE twins

The refute part found this bug (its F1), and the main session confirmed its forward order [M]. It is older than this round. The shift rule neither causes it nor widens it, and neither the lemmas nor the rule depend on it (8.4). Fixing it is a later round's work, and the choice of fix is the user's (8.5).

### 8.1 The mechanism

- **CSE ignores the type** [S]. `lj_opt_cse` (lj_opt_fold.c build copy :2663-2677) walks the opcode's chain down to the higher operand ref. It returns the first instruction whose `op12` equals the new one's, as `TREF(ref, irt_t(IR(ref)->t))`: with the existing instruction's type, not the one asked for. Guide 3.9 says so ("It does not compare the type").
- **The SEXT LEFTFOLD** [S]. On x64, `simplify_conv_sext` (:1278-1308) LEFTFOLDs `CONV i64.int SEXT` to its int operand in three cases:
  - the SCEV loop index whose lower bound is non-negative;
  - `ADD idx, k` from that index;
  - a u8 or u16 XLOAD.

  In those cases `oclj_rec_bitarg`'s operand is the int ref itself (`oclj_bitop_rec.c` :53-54), as guide 3.12's `i << 7` shows: `i64 BSHL 0003 +7`, with no CONV [M, the guide's]. All three are non-negative int32 values [S: :1293-1296, and the XLOAD types].
- **The same op12** [S]. Constants are interned, so our `BSHL i, KINT 3` (`oclj_bitop_rec.c` :132) and `bit.lshift(i, 3)`'s `IRTI(IR_BSHL) i, KINT 3` (lj_ffrecord.c build copy :819) have one `op12`. So do our `BNOT i, 0` (:107) and `bit.bnot(i)`'s `IRTI(IR_BNOT) i, 0` (:779).
- **The two orders.** Whichever op is emitted second is CSE'd to the first, and gets the first's ref and type.
  - **Forward** (the int op first): our `res` is the int op.
    - `d = CONV num.i64 res` takes its source type from op2, which is I64, so `asm_conv` emits `cvtsi2sd` with REX.W (lj_asm_x86.h build copy :859-860, :896-897) [S]. That reads the int op's 64-bit register, which the 32-bit op zero-extended [I].
    - The width rule scores the INT y 33 (`oclj_bitop_fold.c` :76) and drops the guard [S]. The drop is not the fault: the value is in D, so the guard could not have failed.
    - So `i << 3` gives the low 32 bits of 8i, and `~i` gives 2^32 - 1 - i.
  - **Reverse** (ours first): the `bit` library's result is our I64 ref, put into a Lua slot (8.6).

**The class, by reading.** An int instruction twins with one of ours when it has the same opcode and the same two operand refs. The table gives, for the non-negative int32 operands the LEFTFOLD leaves, when the twin's value differs from ours [I: x64 arithmetic; only the first two rows' cases were measured].

**With fold on, and only then** (revision 3).
- **Under `-O-fold` nothing twins** [S][I]. The class needs the SEXT LEFTFOLD, which is a fold rule. With fold off, `lj_opt_fold` chains straight to CSE (lj_opt_fold.c build copy :2595-2597) [S]. Our operand then stays its `CONV i64.int SEXT` (`oclj_bitop_rec.c` :53-54), a ref that no int op has, so no `op12` matches [I].
- **With fold on, constant counts are reshaped before CSE** [S]. `simplify_shift_ik` (lj_opt_fold.c build copy :1673-1687) takes the count & 31 for an int shift and & 63 for ours. It folds a count of 0 to the operand, and it turns a left shift by 1 into `ADD x, x`.
- **So** an int shift that reaches CSE has a constant count in 1..31 (2..31 for BSHL). Ours keeps its own k, at most 63 (`oclj_bitop_rec.c` :116-134 emits no larger KINT). A constant count of 32 or more in ours therefore never twins. Revision 2's rows said such a count differs (finding 3 of the review of the checks).

| our op (`oclj_bitop_rec.c`) | int producer on the same refs (build copy) | the twin's value against ours |
|---|---|---|
| BNOT x (:107) | `bit.bnot` (lj_ffrecord.c :779) | always differs: 2^32 - 1 - x, where ours is -1 - x [M] |
| BSHL x, KINT k (:132) | `bit.lshift` (:819); `rec_varg` (lj_record.c :2081, k = 3) | twins only for 2 <= k <= 31, with any `bit.lshift(x, k')` whose k' & 31 is k (so `bit.lshift(i, 35)` twins with our `i << 3`). The twin's value is x * 2^k mod 2^32, ours x * 2^k: they differ exactly when x * 2^k >= 2^32 [M for k = 3]. Ours with k >= 32 never twins. For `rec_varg`, its guard keeps 8x < 2^31 (8.3) |
| BSHR or BSAR x, KINT k (:132; :117-120) | `bit.rshift`, `bit.arshift` (:819); `rec_varg`'s BSHR (:2071) | twins only for 1 <= k <= 31, and is then equal: on a non-negative int32 x, the 32-bit and the 64-bit right shifts by such a k agree. Ours with k >= 32, BSAR by 63 included, never twins: `bit.rshift(i, 35)` records as `int BSHR i, 3`, which twins with our `i >> 3` (equal) and not with our `i >> 35`. `rec_varg`'s BSHR shifts `ADD fr, k` of the frame slot, which would be our operand only if the frame slot were the SCEV index |
| BSHL, BSHR or BSAR x, cnt, an int count (:138-139, :143) | `bit.lshift(x, j)` and the others (:819; on x64 no `BAND j, 31` is added, :810-812) | twins only when both ops get the same count ref. Ours takes an int-typed count as it is (:138-139). `lj_opt_narrow_tobit` (lj_opt_narrow.c build copy :482-495) returns an int count unchanged, unless it is an ADDOV or SUBOV, which it strips to a new ref. So the clean case is the loop index itself as the count (`bit.rshift(i, i)` then `i >> i`). A double count loaded from a table becomes our `CONV int.num` and the library's TOBIT, two refs [S]; a double that is itself a converted int may fold to that int on both sides, which is the int case again [I]. No fold rewrites a run-time count, so the int op shifts by j & 31 and ours by j (0..63, by our ULT guard). BSHR and BSAR then differ when j >= 32, unless both results are 0. BSHL differs when j >= 32 or x * 2^j >= 2^32, unless both are 0. This row, not a constant count, is the value-changing test for BSHR and BSAR [I] |
| BAND, BOR or BXOR of two LEFTFOLDed int refs (:112) | `bit.band`, `bit.bor`, `bit.bxor` (:783-797) | equal: on two non-negative int32 values, the 32-bit and 64-bit results agree. A constant operand never matches, because ours is a KINT64 (`oclj_rec_bitarg` :57-58) and `bit`'s a KINT |
| ADD z, z (`z << 1`, through `simplify_shift_ik`) | an int `ADD z, z`, made when `narrow_stripov` (lj_opt_narrow.c build copy :427-447) strips an `ADDOV z, z`, through `lj_opt_narrow_toint` (:466-479) or `lj_opt_narrow_tobit` (:482-495) | equal: z < 2^31, so 2z < 2^32 fits the zero-extended 32-bit result |

### 8.2 What was measured: the forward order

[M: `claude-tmp/oclj/shiftexact/cse/cse-fwd2.lua` (md5 39539055), run by the main session on 2026-10-23 with `build/native`'s `luajit.exe` (md5 f4038cd6). Outputs are in `claude-tmp/oclj/shiftexact/cse/run-3/`: `joff.txt`, `jit.txt` and `jdump.txt`.]

| loop | wrong under `-joff` | wrong under the JIT | the first wrong value under the JIT |
|---|---|---|---|
| `a = bit.lshift(i, 3); b = i << 3`, i = 2^29 .. 2^29 + 400 | 0 of 401 | 341 of 401 | i = 536870969: 456, for 4294967752 |
| `a = bit.bnot(i); b = ~i`, i = 1 .. 401 | 0 of 401 | 341 of 401 | i = 58: 4294967237, for -59 |
| control: `i << 3` alone | 0 | 0 | |
| control: `~i` alone | 0 | 0 | |
| fail-first: `~i` against a wrong reference | 401 | 401 | the checker does report mismatches |

- **The IR** [M: `jdump.txt`]:
  - Trace 1 (the lshift loop): the pre-roll has `0018 int BSHL 0001 +3` and `0019 num CONV 0018 num.i64` (b's double), with no `EQ.i64` after them. The body has `0049 int BSHL 0043 +3` and `0050 num CONV 0049 num.i64`.
  - Trace 4 (the bnot loop): `0018 int BNOT 0001` and `0049 int BNOT 0043` in the same places.
  - The controls' traces 7 and 9: `i64 BSHL 0001 +3` and `i64 BNOT 0001`.
- **The arithmetic** [I]: 8 * 536870969 = 2^32 + 456, so its low 32 bits are 456. The int32 ~58 is 0xFFFFFFC5, which zero-extends to 2^32 - 59 = 4294967237.
- **Not run.** The reverse order, on purpose (8.6).

### 8.3 Scope

- **Standalone `luajit.exe` with the `bit` library: affected.** The forward order was measured, and the reverse order follows from the code [S]. The project's suites and gen use only the operators, so nothing in them has met it (the refute part's reading [S]).
- **The mod in game: not affected by any producer found.**
  - **No `bit` library** [S]. `LuaJITStateFactory.openLibs` opens BASE, BIT32, COROUTINE, DEBUG, ERIS, MATH, STRING and TABLE (`src/main/java/io/github/astronfo/ocluajit/arch/LuaJITStateFactory.java` :117-125). BIT32 is lj52shim's C `bit32`, "NOT an alias for LuaJIT's luaopen_bit" (`native/lj52shim.c` :3000), and `native/lj52shim.h` :83-87 renames `LUA_BITLIBNAME` to "bit32". That bit32's functions are plain C functions, which `recff_bit_*` never records, is [I].
  - **No FFI** [S]. `oclj_bitop_rec.c` :46-47 stops an `LJ_HASFFI` build with `#error`, so there is no FFI int64 bit op either.
  - **`rec_varg`'s `int BSHL tridx, 3`** [I]:
    - forward order (select first): its guard `ULT tridx - 1, 2^27` (lj_record.c :2080) comes before it in trace order. So 1 <= k <= 2^27 and 8k <= 2^30 < 2^31, and the int shift's zero-extended value equals ours.
    - reverse order (ours first): select's consumers of the I64 ref, the `int ADD` (:2082) and the `LT` guard (:2086), run after that guard and read the low 32 bits of 8k, the same value. The ref goes into no Lua slot.
  - **Narrowing's stripped int `ADD z, z`** [I]. String functions narrow their arguments through `lj_opt_narrow_toint` (e.g. lj_ffrecord.c :333, :344). The twin's value equals ours in both orders, since 2z < 2^32 for the non-negative int32 z that the LEFTFOLD leaves (8.1's table), and its own `ADDOV z, z` guard comes first. The reverse order's later uses of an I64 ref there were not traced in full.
  - **No other int producer found** [S]. A grep of lj_record.c, lj_ffrecord.c, lj_opt_narrow.c, lj_opt_loop.c and lj_snap.c for int bit-op emitters found none on our operands:
    - lj_record.c :2956's BAND of the hook mask has a KINT constant, and no op of ours has one;
    - lj_ffrecord.c :1253 and :1258 are `IRT_IGC` (I64) BAND and BXOR of a string buffer's field: the same type as ours, and other operands;
    - lj_ffrecord.c :812's `BAND tsh, 31` is not emitted on x64.
  - **No int MUL either** [S][I]. `simplify_intmul_k` (lj_opt_fold.c :1471-1487) turns an int MUL by 2^k into an int BSHL, but an int MUL needs a MULOV to strip. The non-DUALNUM recorder makes only ADDOV and SUBOV (lj_opt_narrow.c :532) [S], so that BSHL does not arise [I].
  - **So** "not in game" is [S] for `bit` and FFI, and [I] for `rec_varg`, narrowing, and the completeness of the grep (7).
- **Upstream with FFI may have the analogue** [I]. Its `bit` on int64 cdata converts operands through `crec_bit64_arg` (lj_crecord.c build copy :1831). Whether that yields a `CONV i64.int SEXT` that the same LEFTFOLD removes was not traced. It is not to be tested here (the build has no FFI, and the round allows no FFI code). It matters only if the bug is reported upstream.

### 8.4 Why the lemmas and the sketched rule are untouched

- **The lemmas** (section 2) are facts about integers; CSE does not enter them [I].
- **A twin's value is in D** [I]. An int op writes its 32-bit register zero-extended. Whatever reads it as an int64 (our `CONV num.i64`, the guard, or an i64 op above it) sees a value in [0, 2^32), in D by C1. The refute part reads the registers the same way ("INT refs have zero-extended registers"). The one exception, `CONV int.intp NONE` (guide 3.9), is never an operand of an i64 op.
- **At the rule's line** [S]. A twin `res` is INT-typed. The width rule, the first rule in fix1's block, takes any INT y at 33 (`oclj_bitop_fold.c` :76), and the sketch's `irt_isi64` refuses it anyway (5.1).
- **Below y** [I]. A twin is an INT leaf, which E accepts through the bound's 33. Its value is in D, which is all a leaf of E promises.
- **So** [I]: every guard the rule would remove still never fails. The wrong value is the twin's, with or without the rule.
- **What fails** is the premise of guide S5 (9.5), and of revision 1's 4.5, that "folds and CSE preserve values": for a twin, CSE puts an int op's value where an int64 op's belongs. Revision 2's 4.5 uses that premise only for "x computes n's opcode", and its CSE case reaches membership in D without it.
- **The arms** (5.6) name forms such as `x >> 1` and `(x << 20) | 1`, which use no `bit` library, so the twins do not change their visibility [I].

### 8.5 Fix options, for a later round (not chosen)

A roadmap row, and the user's choice [I]:

1. **Abort the recording in `oclj_rec_bitop`.**
   - *The test.* After `emitir` of our op, abort (`lj_trace_err`) when `res` comes back as our opcode but not I64-typed.
   - *Identity folds.* Their legitimate non-I64 `res` must still pass, and this test lets it pass because its opcode is another one. `i | 0` returns `a`, the int index (the refute part's note). `~~i` returns the inner BNOT's operand i, which is neither `a` nor `b` (`shortcut_leftleft`, lj_opt_fold.c build copy :996-1002) [S].
   - *A gap, and whether it matters.* The opcode test misses `z << 1`, which comes back as an ADD (8.1). 8.1's table finds the ADD twins value-equal, and the BAND, BOR and BXOR twins too, so the test does catch every value-changing member found: BNOT and the shifts [I]. A test on the type alone would also catch the ADD twins. It would then have to exempt every legitimate identity fold, `~~i` included, so "not `a` or `b`" would not be enough [I].
   - *Scope.* The forward order only. In the reverse order the int op is the second emitted, by `recff_bit_*` or `rec_varg`, and `oclj_rec_bitop` is not on that path. Covering it needs the same test in those upstream recorders (patches to lj_ffrecord.c and lj_record.c), or option 2. In game, those recorders are unreachable (`bit`) or give the same value (`rec_varg`) (8.3).
   - *Cost.* The change is in our own file, with no upstream patch. A trace with a twin is lost instead of compiled.
2. **A type test in `lj_opt_cse`.**
   - *The test.* Match only on equal types. Compare the `IRT_TYPE` bits with `irt_sametype` (lj_ir.h build copy :366), not `irt_t`. The guard and PHI flags in `irt_t` (:344-346) must not decide a match, because the loop copy CSEs to PHI-marked pre-roll refs [S][I].
   - *Scope.* Both orders, and every producer, present and future.
   - *Cost.* One compare per `op12` match, in the recorder's hottest function [I]. It patches an upstream file and changes upstream's CSE semantics, which may rely on type-blind matches somewhere (not examined) [I]. The twins become two instructions, and both run.
3. **Give our ops a distinguishing operand,** so that our `op12` cannot equal an int op's.
   - *How.* Keep our operand's `CONV i64.int` instead of the int ref. That refuses the SEXT LEFTFOLD for our operands, at the cost of a `movsxd` and of upstream's widening elimination (guide 3.12's `i << 7` would gain a CONV). Or give BNOT a distinct op2, its one free operand; a shift's op2 is its count.
   - *Scope.* Both orders, for the ops it changes.
   - *Cost.* Code in hot loops. It needs a timing comparison, as FIX-NUMCONV's chain.

**What each would need** [I]:
- **Value tests, in the forward order only.**
  - The loops: cse-fwd2.lua's two, plus the other members of 8.1's class that change values (revision 3):
    - BSHL by another constant k in 2..31, with x * 2^k >= 2^32;
    - a variable int count of 32 or more that is the same ref in both ops, such as `bit.rshift(i, i)` then `i >> i` for i = 32..63, and likewise `bit.arshift` with `~>>` and `bit.lshift` with `<<`. This is the test for BSHR and BSAR (8.1's last shift row).
  - The controls:
    - value-equal: BSHR and BSAR by a constant k in 1..31, BAND, and `ADD z, z`;
    - no twin at all, read in the dump as two instructions: ours by a constant count of 32 or more beside the library's same call (`bit.rshift(i, 35)` then `i >> 35`, whose int op's count is 3).
  - The checks: each loop against `-joff`, under the option sets, with a fail-first reference (as cse-fwd2's `failfirst`). A coverage gate requires the twin's trace to be compiled (options 2 and 3) or aborted (option 1). Under `-O-fold` nothing twins (8.1), so the value tests need fold on. A fold-off set shows only that the fix leaves that case alone.
- **An IR read, in the forward order.** For options 2 and 3, the dump must show the int op and our i64 op as two instructions. For option 1, no compiled trace may hold a twin. As P61 does for ncir, the read refuses option sets that would hide the case (`-O-fold`, `-O-cse`).
- **The reverse order, shown without running it, by IR reading.** That means deriving by hand, from `lj_opt_cse` and the producer's source, the IR the recorder would emit:
  - option 2's comparison is the same whichever instruction comes first;
  - option 3's `op12`s differ whichever comes first;
  - option 1 does not cover the reverse order, and the round must say so or add the producer-side tests.

  No round may record, dump or run the reverse order (8.6).
- **A negctl arm per option** that removes the fix and is caught by the forward-order value test. The arm is memory-safe: the forward order fails with a wrong number.
- **Guide upkeep** (5.7, revision 2): 3.9, S5 (9.5), and a P entry for the bug.

### 8.6 The reverse order must not be run

- **What happens** [S]. In the reverse order, the `bit` library's result is an I64-typed TRef in a Lua slot (`J->base[0]`, lj_ffrecord.c build copy :779, :819). On an exit, `snap_restoreval` (lj_snap.c build copy :698-763) restores a slot by its IR type, and on GC64 it has no I64 case: integer types go through `irt_isinteger`, which covers I8 to INT (lj_ir.h :389). An I64 value falls through to `setgcV`, as a GC object made from the raw integer, from a spill slot (:733) or from a register (:760).
- **What that would do** [I]. Whether, and when, that crashes is not to be found out by running it. CLAUDE.md forbids a test that forces a native crash; a crash fix is proved by a black-box census A/B plus build assertions.
- **How it may be shown.** Only by reading the code and the forward order's IR (8.5). Never by a recording, a dump or a run of the reverse order.

## 9. Changelog

- **Revision 1** (2026-10-23, the argue part): sections 0 to 7.
- **Revision 2** (2026-10-23, the revise part), for the refute part's F1, F6 and F7 (`claude-tmp/oclj/shiftexact/refute/notes.md`). Nothing was run for it; its one new [M] is the main session's `cse/run-3`.
  - **F1.**
    - 3.4 is rewritten: the `bit` library's and `rec_varg`'s int ops produce the instruction that serves ours, through type-blind CSE after the SEXT LEFTFOLD.
    - Section 8 is new. It covers the mechanism and the class, the [M] forward-order confirmation, and the scope (standalone `luajit.exe` with `bit`; not the mod in game, with reasons and tags). It also says why the lemmas and the rule are untouched, lists three fix options without choosing one, and explains why the reverse order must not be run.
    - Smaller changes follow from it: 0 item 10, 4.1's INT row, 4.3, 5.1's `irt_isi64` bullet, 5.7, 6.2, 6.3 item 5 and 7.
  - **F6.** 4.5's induction is restated on execution order: the iteration, then IR order. The exact-mark fold's value now comes from the hypothesis at an earlier event, and the CSE twin case is handled explicitly. 0 item 5, 6.2 and 7 follow.
  - **F7.**
    - 3.3's row for `simplify_shift1_ki` and `simplify_shift2_ki` is split from `kfold_int64shift`: with a variable count, they fold only the constant operands 0 and -1.
    - 2.6 and 3.4 no longer say that every i64 ADD comes from `simplify_shift_ik`. 2.6 gives upstream's I64 SUB-to-ADD path, and why E does not depend on it.
    - 5.1's ADD bullet is reworded, and 5.7 lists the guide's and `oclj_bitop_fold.c` :93's copies of the old wording.
  - **Also.** 7's first bullet records the one review, and the header records revision 2.
  - **Unchanged.** Section 2's lemmas and proofs, the sketch and its placement (5.1, 5.2), the shapes (5.4), the tests (5.5) and the arms (5.6).
- **Revision 3** (2026-10-23, the checks-fix part), for finding 3 of the review of the revised checks. Nothing was run for it; its new citations are [S] reads of the build copy.
  - 8.1 gains a paragraph, "With fold on, and only then":
    - under `-O-fold` no fold rule runs (lj_opt_fold.c build copy :2595-2597), so the SEXT LEFTFOLD does not, and nothing twins;
    - with fold on, `simplify_shift_ik` (:1673-1687) takes an int shift's constant count & 31 and ours & 63 before CSE.
  - 8.1's rows follow from it:
    - BSHL by a constant twins only for k in 2..31 and differs only when x * 2^k >= 2^32;
    - BSHR and BSAR by a constant twin only for k in 1..31 and are then equal on the non-negative int32 operands;
    - a constant count of 32 or more in ours never twins;
    - the variable-count row says when the two count refs coincide (`lj_opt_narrow_tobit`, lj_opt_narrow.c build copy :482-495) and is the value-changing test for BSHR and BSAR.
  - 8.5's test list: the value-changing loops, the value-equal controls, a constant count of 32 or more as a control that must show no twin, and why the value tests need fold on.
  - 6.2's row on the twins' other members is reworded to match.
  - **Unchanged.** Everything else, the lemmas, the rule and 8.5's options among it.
