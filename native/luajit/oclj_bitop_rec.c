/*
** native/luajit/oclj_bitop_rec.c -- recording Lua 5.3.6's bitwise operators
** as int64 IR on the no-FFI x64 GC64 LuaJIT.  native/build-native.sh copies
** this file into the LuaJIT build copy's src/, and native/luajit/
** patch-bitop-record.sh makes that copy's lj_record.c #include it after its
** emitir macros (lj_record.c:46) and replaces the seven bit-operator cases of
** lj_record_ins (lj_record.c:2511-2546, upstream's int32 recording through
** lj_opt_narrow_tobit) with one call of oclj_rec_bitop.  The rules are
** oclj_bitop.h's, the ones folding and the interpreter's slow path use.
**
** THE OPERANDS.  Each becomes the int64 5.3.6's luaV_tointeger gives it:
**   - an IRT_INT operand (a narrowed value, exact): sign-extended;
**   - a constant number: checked now, becomes a KINT64;
**   - any other number x: i = CONV i64.num x (cvttsd2si), then a guard that
**     the conversion back gives x again: back = CONV num.i64 i, EQ.num back,
**     x.  It fails for a non-integral value, NaN, and anything outside
**     [-2^63, 2^63); the side exit returns to the interpreter, which raises
**     5.3's error.  back carries OCLJ_IRCONV_EXACT: past the guard it equals
**     x, an integral double, so it is i exactly.  When x is itself an
**     earlier operator's result, i folds to that result's int64, back
**     commons with x (cse_conv, lj_opt_fold.c:1286-1303), and the guard
**     EQ.num x, x folds away (comm_equal's "converted integers cannot be
**     NaN", lj_opt_fold.c:1976-1987): an earlier result reaches a later
**     operator with no round trip through a double;
**   - a constant shift count: 5.3.6's rule decided now;
**   - a variable shift count: guarded to [0, 63].
** THE RESULT.  res is the int64 op.  Every result that does not raise is a
** double that equals it (oclj_bit2num), so it is d = CONV num.i64 res,
** marked OCLJ_IRCONV_EXACT, and unless res is a constant, followed at once
** by its guard: back = CONV i64.num d (IRCONV_ANY, and marked: here the mark
** says "this is the guard's own check"), EQ.i64 back, res.  The guard fails
** for a result with more than 53 significant bits; the side exit returns to
** the interpreter, which recomputes the operator and raises.  Because the
** guard directly follows d, every use of d comes after it, and
** simplify_conv_i64_num (patch-bitop-fold.sh) may fold (i64)d to res
** everywhere except in the guard itself; the width rule there removes the
** guard when res provably has 54 bits or fewer.
** NOT RECORDED (the trace aborts, LJ_TRERR_BADTYPE, and the interpreter
** runs the operator): a string operand, an operand with no integer
** representation at record time, a variable shift count outside [0, 63] at
** record time, and an operation whose result at record time has more than
** 53 significant bits -- the interpreter is about to raise, and a trace
** recorded through it would always leave at its guard.
*/

#if LJ_HASFFI
#error "oclj_bitop_rec.c replaces the no-FFI bit-operator recording only"
#endif

static TRef oclj_rec_bitarg(jit_State *J, TRef tr, cTValue *tv)
{
  int64_t k;
  if (tref_isinteger(tr))
    return emitir(IRT(IR_CONV, IRT_I64), tr, (IRT_I64<<5)|IRT_INT|IRCONV_SEXT);
  if (!tref_isnum(tr) || !tvisnum(tv) || !oclj_flt2int(numV(tv), &k))
    lj_trace_err(J, LJ_TRERR_BADTYPE);
  if (tref_isk(tr))
    return lj_ir_kint64(J, (uint64_t)k);
  {
    /* back is marked exact: past the guard it equals tr, an integral
    ** double, so it is the int64 exactly.  When tr is itself an exact
    ** result of an earlier operator, i folds to that operator's int64, back
    ** commons with tr and the guard folds away (comm_equal). */
    TRef i = emitir(IRT(IR_CONV, IRT_I64), tr, (IRT_I64<<5)|IRT_NUM|IRCONV_ANY);
    TRef back = emitir(IRTN(IR_CONV), i,
		       (IRT_NUM<<5)|IRT_I64|OCLJ_IRCONV_EXACT);
    emitir(IRTG(IR_EQ, IRT_NUM), back, tr);
    return i;
  }
}

/* An operand's int64 value now, which the interpreter will use. */
static int64_t oclj_rec_bitval(jit_State *J, cTValue *tv)
{
  int64_t k;
  if (!tvisnum(tv) || !oclj_flt2int(numV(tv), &k))
    lj_trace_err(J, LJ_TRERR_BADTYPE);
  return k;
}

/* The shift count's int64 value now (5.3.6 tointeger), or abort. */
static int64_t oclj_rec_bitcount(jit_State *J, TRef tr, cTValue *tv)
{
  int64_t k;
  if (!tref_isnumber(tr) || !tvisnum(tv) || !oclj_flt2int(numV(tv), &k))
    lj_trace_err(J, LJ_TRERR_BADTYPE);
  return k;
}

static TRef oclj_rec_bitop(jit_State *J, BCOp op, TRef rb, TRef rc,
			   cTValue *rbv, cTValue *rcv)
{
  TRef a, res, d;
  double n;
  /* A result that raises now is not recorded (the trace would always leave
  ** at its guard). */
  if (op == BC_BNOT) {
    if (!oclj_bit2num(oclj_bitop64(BC_BNOT, oclj_rec_bitval(J, rcv), 0), &n))
      lj_trace_err(J, LJ_TRERR_BADTYPE);
  } else {
    int64_t b = oclj_rec_bitval(J, rbv), c = oclj_rec_bitval(J, rcv);
    if (!oclj_bit2num(oclj_bitop64((int)op, b, c), &n))
      lj_trace_err(J, LJ_TRERR_BADTYPE);
  }
  if (op == BC_BNOT) {
    a = oclj_rec_bitarg(J, rc, rcv);
    res = emitir(IRT(IR_BNOT, IRT_I64), a, 0);
  } else if (op <= BC_BXOR) {
    TRef b;
    a = oclj_rec_bitarg(J, rb, rbv);
    b = oclj_rec_bitarg(J, rc, rcv);
    res = emitir(IRT((int)op - (int)BC_BAND + (int)IR_BAND, IRT_I64), a, b);
  } else {
    int64_t k = oclj_rec_bitcount(J, rc, rcv);
    a = oclj_rec_bitarg(J, rb, rbv);
    if (tref_isk(rc) && op == BC_BSAR) {  /* ~>>: oclj_shiftar, case by case. */
      if (k >= 64)
	res = emitir(IRT(IR_BSAR, IRT_I64), a, lj_ir_kint(J, 63));  /* Sign. */
      else if (k >= 0)
	res = emitir(IRT(IR_BSAR, IRT_I64), a, lj_ir_kint(J, (int32_t)k));
      else if (k > -64)
	res = emitir(IRT(IR_BSHL, IRT_I64), a, lj_ir_kint(J, (int32_t)-k));
      else
	res = lj_ir_kint64(J, 0);
    } else if (tref_isk(rc)) {  /* Constant count: 5.3.6's rule, decided now. */
      int64_t s;  /* Left shift by s, or right by -s. */
      if (op == BC_BSHL) s = k;
      else s = (k == INT64_MIN) ? INT64_MIN : -k;
      if (s >= 64 || s <= -64) {
	res = lj_ir_kint64(J, 0);
      } else {
	res = emitir(IRT(s >= 0 ? IR_BSHL : IR_BSHR, IRT_I64), a,
		     lj_ir_kint(J, (int32_t)(s >= 0 ? s : -s)));
      }
    } else {  /* Variable count: specialise to [0, 63], else not recorded. */
      TRef cnt;
      if (k < 0 || k > 63) lj_trace_err(J, LJ_TRERR_BADTYPE);
      if (tref_isinteger(rc))
	cnt = rc;
      else
	cnt = emitir(IRTGI(IR_CONV), rc, IRCONV_INT_NUM|IRCONV_CHECK);
      emitir(IRTGI(IR_ULT), cnt, lj_ir_kint(J, 64));
      res = emitir(IRT(op == BC_BSHL ? IR_BSHL :
		       op == BC_BSHR ? IR_BSHR : IR_BSAR, IRT_I64), a, cnt);
    }
  }
  /* The result is a double only if it is exact.  d is marked exact; the
  ** guard converts it back (its own marked conversion, which only the width
  ** rule removes, when res provably fits) and compares with res. */
  d = emitir(IRTN(IR_CONV), res, (IRT_NUM<<5)|IRT_I64|OCLJ_IRCONV_EXACT);
  if (!tref_isk(res)) {
    TRef back = emitir(IRT(IR_CONV, IRT_I64), d,
		       (IRT_I64<<5)|IRT_NUM|IRCONV_ANY|OCLJ_IRCONV_EXACT);
    emitir(IRTG(IR_EQ, IRT_I64), back, res);
  }
  return d;
}
