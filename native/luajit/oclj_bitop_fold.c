/*
** native/luajit/oclj_bitop_fold.c -- the bound behind the fold engine's
** width rule for Lua 5.3.6's bitwise operators.  native/build-native.sh
** copies this file into the LuaJIT build copy's src/, and native/luajit/
** patch-bitop-fold.sh makes that copy's lj_opt_fold.c #include it directly
** above simplify_conv_i64_num (lj_opt_fold.c:1138), whose rule body calls
** oclj_bitwidth.  The rule itself stays in lj_opt_fold.c: buildvm -m folddef
** reads that one file for its LJFOLD lines (host/buildvm_fold.c:172, :200)
** and never follows an #include, so this file holds no LJFOLD line.
**
** THE BOUND.  oclj_bitwidth(J, ref, 0) is a w such that the int64 IR value
** ref lies in [-2^(w-1), 2^(w-1)); 64 means unknown.  With w <= 54 the value
** is in [-2^53, 2^53), where every integer is a double, so the round trip
** (i64)(num)y is y and simplify_conv_i64_num folds it.  Round 3's recorder
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
