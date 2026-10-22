/*
** native/luajit/oclj_bitop_fold.c -- the bound behind the fold engine's
** width rule and table-index fold for Lua 5.3.6's bitwise operators, and
** FIX-NUMCONV's exactness predicate (oclj_isnumconv, at the end).
** native/build-native.sh copies this file into the LuaJIT build copy's
** src/, and native/luajit/patch-bitop-fold.sh makes that copy's
** lj_opt_fold.c #include it directly above simplify_conv_int_num
** (lj_opt_fold.c:1128), whose table-index fold calls oclj_bitwidth with a
** bound of 32 (an int64 that is exactly an int32), as simplify_conv_i64_num's
** width rule (lj_opt_fold.c:1138) does with 54 (an int64 that is exactly a
** double).  The rules themselves stay in lj_opt_fold.c: buildvm -m folddef
** reads that one file for its LJFOLD lines (host/buildvm_fold.c:172, :200)
** and never follows an #include, so this file holds no LJFOLD line.
**
** THE BOUND.  oclj_bitwidth(J, ref, 0) is a w such that the int64 IR value
** ref lies in [-2^(w-1), 2^(w-1)); 64 means unknown.  With w <= 54 the value
** is in [-2^53, 2^53), where every integer is a double, so the round trip
** (i64)(num)y is y and simplify_conv_i64_num folds it.  With w <= 32 it is
** in [-2^31, 2^31), an int32, so (int)(num)y is y's low 32 bits and
** simplify_conv_int_num folds it to CONV int.i64 y (the table-index fold,
** the CRC32 follow-up).  Round 3's recorder
** (oclj_bitop_rec.c) follows every operator's result with a guard that it
** equals a double: the guard's own conversion back is such a round trip, so
** where the bound is 54 or less it folds to the result, EQ.i64 res, res
** folds away, and the guard is gone.  It follows only the ops
** oclj_bitop_rec.c records, and the folds of those:
**   leaves: KINT64 (its width); an int value (33); CONV i64.int (32
**     sign-extended, 33 zero-extended); BAND with a non-negative constant k
**     (the value is in [0, k]: k's width); BSHR by a constant k >= 1
**     (in [0, 2^(64-k)): 65 - k);
**   operators: BOR, BXOR and BAND take the larger bound; BNOT keeps it; ADD
**     (simplify_shift_ik's i << 1 ==> i + i, lj_opt_fold.c:1617) adds 1;
**     BSHL by a constant k adds k; BSAR by a constant k subtracts k; all are
**     capped at 64, and the bound is 64 beyond depth 6.
**   Everything else scores 64, a CONV i64.num of a double among them,
**   although its value is always exactly a double: that is exactness, not a
**   range, and oclj_isnumconv below says it.  It must never be scored here:
**   a bound composes, and with a converted double scored 54, x | 1 for
**   x = 2^53 would lose its guard and give 2^53 where the interpreter raises.
** WHY IT HOLDS IN EVERY LOOP ITERATION, also where the folded conversion is
** a PHI (reviewed 2026-10-17; a generator of adversarial loops found no
** difference in 120 000, and ships as test/native/bitop/gen.lua):
**   - the bound reads only opcodes, IR types and constants, never a value;
**   - IR types do not change between iterations: loop_unroll converts a
**     loop-carried value whose type changes, or raises TYPEINS
**     (lj_opt_loop.c:343-352);
**   - every value that enters the trace from outside it (a stack slot, a
**     table, an upvalue, a parent trace's snapshot) reaches an int64 op
**     either as a double, through CONV i64.num, which scores 64, or as an
**     int-typed value (a narrowed SLOAD such as the loop index, or an int
**     from a parent snapshot), which scores 33, or 32 sign-extended through
**     CONV i64.int, from its type alone: an int is an int32 whatever its
**     origin.
**   So a finite bound depends on no carried value, and the pre-roll's bound
**   is every iteration's.
*/

#if !defined(OCLJ_BITOP_H)
#error "oclj_bitop_fold.c belongs inside the build copy's lj_opt_fold.c, after its #include of oclj_bitop.h"
#endif

static int oclj_kwidth(int64_t k)
{
  uint64_t u = k < 0 ? ~(uint64_t)k : (uint64_t)k;
  int w = 1;
  while (u) { u >>= 1; w++; }
  return w;
}

static int oclj_bitwidth(jit_State *J, IRRef ref, int depth)
{
  IRIns *ir = IR(ref);
  int wa, wb;
  if (ir->o == IR_KINT64) return oclj_kwidth((int64_t)ir_k64(ir)->u64);
  /* An int value used by an int64 op, sign- or zero-extended: 33 bits. */
  if (irt_isint(ir->t)) return 33;
  if (!irt_isi64(ir->t) || depth > 6) return 64;
  switch (ir->o) {
  case IR_CONV:
    if ((ir->op2 & IRCONV_SRCMASK) == IRT_INT)
      return (ir->op2 & IRCONV_SEXT) ? 32 : 33;
    return 64;
  case IR_BAND:
    if (IR(ir->op2)->o == IR_KINT64 && (int64_t)ir_k64(IR(ir->op2))->u64 >= 0)
      return oclj_kwidth((int64_t)ir_k64(IR(ir->op2))->u64);  /* In [0, k]. */
    /* fallthrough */
  case IR_BOR: case IR_BXOR:
    wa = oclj_bitwidth(J, ir->op1, depth+1);
    wb = oclj_bitwidth(J, ir->op2, depth+1);
    return wa > wb ? wa : wb;
  case IR_BNOT:
    return oclj_bitwidth(J, ir->op1, depth+1);
  case IR_ADD:  /* From x << 1 ==> x + x. */
    wa = oclj_bitwidth(J, ir->op1, depth+1);
    wb = oclj_bitwidth(J, ir->op2, depth+1);
    wa = (wa > wb ? wa : wb) + 1;
    return wa > 64 ? 64 : wa;
  case IR_BSHL:
    if (irref_isk(ir->op2) && IR(ir->op2)->o == IR_KINT) {
      wa = oclj_bitwidth(J, ir->op1, depth+1) + (IR(ir->op2)->i & 63);
      return wa > 64 ? 64 : wa;
    }
    return 64;
  case IR_BSHR:
    if (irref_isk(ir->op2) && IR(ir->op2)->o == IR_KINT &&
	(IR(ir->op2)->i & 63) >= 1)
      return 65 - (IR(ir->op2)->i & 63);  /* In [0, 2^(64-k)). */
    return 64;
  case IR_BSAR:
    if (irref_isk(ir->op2) && IR(ir->op2)->o == IR_KINT) {
      wa = oclj_bitwidth(J, ir->op1, depth+1) - (IR(ir->op2)->i & 63);
      return wa < 1 ? 1 : wa;
    }
    return 64;
  default:
    return 64;
  }
}

/*
** FIX-NUMCONV (roadmap row 211 (5)).  oclj_isnumconv(J, ref) is 1 when the
** IR value ref is an unguarded CONV i64.num of a double, x64's cvttsd2si,
** whose value is exactly a double whatever its range: a fact of exactness,
** not of range, which the bound above does not hold and must not (it scores
** such a conversion 64).  simplify_conv_i64_num reads it on a line of its
** own after the width rule and before its PHIBARRIER (patch-bitop-fold.sh
** hunk 7): (i64)(num)y ==> y for such a y.  An identity operation (x | 0,
** x & -1, x ~ 0, x << 0, x >> 0, x & x and the like) folds its result to
** its operand's own conversion, so the result guard's conversion back folds
** to y, EQ.i64 y, y folds away (comm_equal), and a guard that cannot fail
** is gone.
** WHY IT HOLDS.  For a CONV whose IR type is I64, whose source is NUM and
** which is no guard, x64's asm_conv emits one instruction, cvttsd2si r64,
** xmm/m64 (lj_asm_x86.h:908 and :929-931 at 1ee778a4, in its FP-to-integer
** branch, :900-933): the double x truncated toward zero when that lies in
** [-2^63, 2^63), else (NaN, an infinity, out of range) the indefinite
** integer -2^63.  Each is exactly a double: an x with |x| >= 2^52 is an
** integer, so its truncation is x itself; one with |x| < 2^52 truncates to
** an integer below 2^52 in magnitude; -2^63 is a power of two.  So (num)y
** is y exactly, an integral double in [-2^63, 2^63), and cvttsd2si gives y
** back, in every rounding mode (cvtsi2sd has nothing to round).  A constant
** x never reaches here as a CONV: kfold_conv_knum_i64_num
** (lj_opt_fold.c:901-905) folds it to a KINT64 by lj_num2i64, on x64
** lj_vm_num2i64 (lj_obj.h:1057), the same cvttsd2si (vm_x64.dasc:2684-2686),
** and the bound scores that by its width.  x64 only: arm64's fcvtzs
** saturates to 2^63 - 1, which is no double, so a port must argue again.
** THE TESTS.  The opcode is the subject: only a CONV's op2 is a mode word.
** Another instruction's op2 is a ref, and one that reads as NUM made a bit
** operator pass for a conversion and lose a guard it needs: without this
** test gen and t_rec differ from -joff (2026-10-21; the arm NUMCONVNOOP).
** The three type tests are the argument's preconditions, kept and stated
** although no test can show that one matters on this build: every y they
** turn away is either one the width rule, which runs first, already takes
** (an int-typed y, which scores 33, every guarded CONV being one to int; a
** CONV i64.int, 32 or 33), or a conversion that exists only with FFI (from
** a float, or to or from a u32 or u64: lj_crecord.c, and
** lj_ffrecord.c:1105, both under LJ_HASFFI).  I64, not U64: for a u64
** asm_conv converts again after adding -2^64 (:911-924), so its value is
** not the double's integral part, and a u64-typed y returned for an int64
** conversion would change the folded instruction's type (lj_opt_fold.c's
** requirement 1).  NUM: cvttsd2si, not a float's cvttss2si.  No guard:
** asm_conv checks a guarded conversion only to int (asm_tointg, :901-905),
** and every guarded CONV the pin emits is one to int (IRTGI).  Not read:
** the check mode (IRCONV_CONVMASK), SEXT and the exact mark, which
** asm_conv ignores for an unguarded conversion from a double.
** IN EVERY LOOP ITERATION: it reads no value, only y's opcode, IR type and
** mode, and y's value there, across a PHI too, is cvttsd2si of a double,
** given the guards emitted before it (S1): exact by the same argument.
*/
static int oclj_isnumconv(jit_State *J, IRRef ref)
{
  IRIns *ir = IR(ref);
  return ir->o == IR_CONV && irt_isi64(ir->t) && !irt_isguard(ir->t) &&
	 (ir->op2 & IRCONV_SRCMASK) == IRT_NUM;
}
