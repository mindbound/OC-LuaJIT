armlist() {
arm canon - 'bitop fuzz gen genrg2 floor fix1 idx sel nc cse security gate stage4' '' ''
arm WRAP32-INTERP vm_x64.dasc 'bitop:t_ops fuzz:V' \
  '    |  ins RC, RA' \
  '    |  ins RCd, RAd@T@@T@// SABOTAGE WRAP32-INTERP: and/or/xor in 32 bits, as BitOp computed them'
arm WRAP32-FOLD lj_parse.c 'bitop:t_fold fuzz:K' \
  '      if (!oclj_bit2num(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))' \
  '      if (!oclj_bit2num((uint64_t)(int64_t)(int32_t)oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))  /* SABOTAGE WRAP32-FOLD: a folded result wraps to 32 bits */'
arm SHIFTMASK vm_x64.dasc 'bitop:t_ops fuzz' \
  "    |  ja ->vmeta_bitop_pc@T@@T@// Count < 0 or > 63: 5.3's rules, in C." \
  '    |  // SABOTAGE SHIFTMASK: no count check, so the shift takes the count mod 64'
arm NEGSHIFT oclj_bitop.h 'bitop:t_ops' \
  '  case BC_BSHL: return oclj_shiftl(x, c);' \
  '  case BC_BSHL: return c < 0 ? 0 : oclj_shiftl(x, c);  /* SABOTAGE NEGSHIFT: << by a negative count gives 0, not a right shift */'
arm SARSHR oclj_bitop.h 'bitop:t_sar' \
  '  return (int64_t)x < 0 ? ~(~x >> (unsigned)y) : x >> (unsigned)y;' \
  '  return x >> (unsigned)y;  /* SABOTAGE SARSHR: ~>> shifts zeros in, as >> does */'
arm NOINT-FOLD lj_parse.c 'bitop:t_fold' \
  '    if (!oclj_flt2int(expr_numberV(e1), &k1) ||' \
  '    if (!oclj_flt2int(__builtin_floor(expr_numberV(e1)), &k1) ||  /* SABOTAGE NOINT-FOLD: a fractional left operand is floored and folded */'
arm NOINT-JIT oclj_bitop_rec.c 'floor:t_jit2/guard-exit genrg2' \
  '    emitir(IRTG(IR_EQ, IRT_NUM), back, tr);' \
  '    (void)back;  /* SABOTAGE NOINT-JIT: no guard that the operand is an integer */'
arm RANGE-HI oclj_num53.h 'bitop:t_ops fuzz' \
  '  if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))' \
  '  if (n == 9223372036854775808.0) { *p = INT64_MAX; return 1; } if (!(n >= -9223372036854775808.0 && n < 9223372036854775808.0))  /* SABOTAGE RANGE-HI: 2^63 reads as math.maxinteger (U2-B) */'
arm STRCOERCE oclj_bitop_meta.c 'bitop:t_ops bitop:coerce' \
  '    if (oclj_str2int(strVdata(o), strV(o)->len, pi)) return 1;' \
  '    if (0 && oclj_str2int(strVdata(o), strV(o)->len, pi)) return 1;  /* SABOTAGE STRCOERCE: a string is read as a float, as LuaJIT arithmetic reads it */'
arm ERROPERAND oclj_bitop_meta.c 'bitop:t_ops' \
  '  ob_err_type(L, ob_tonum(rb, &i, &n) ? rc : rb);' \
  '  ob_err_type(L, ob_tonum(rc, &i, &n) ? rb : rc);  /* SABOTAGE ERROPERAND: the type error blames the second operand first */'
arm NARROW lj_opt_fold.c 'floor:t_rec floor:t_jit2' \
  '  if (fins->o == IR_CONV && irt_is64(fins->t))' \
  '  if (0 && fins->o == IR_CONV && irt_is64(fins->t))  /* SABOTAGE NARROW: an operand conversion to int64 is narrowed */'
arm KFOLD64 lj_opt_fold.c 'fuzz:U floor:t_rec genrg2' \
  '#if 1  /* OC-LuaJIT: the 64-bit bit operators, without FFI. */
  case IR_BAND: k1 &= k2; break;' \
  '#if LJ_HASFFI  /* SABOTAGE KFOLD64: the int64 constant folds are FFI-only again */
  case IR_BAND: k1 &= k2; break;'
arm SARCONST oclj_bitop_rec.c 'floor:t_rec-counts bitop:t_sar' \
  '      if (k >= 64)' \
  '      if (k >= 64 || k <= -64)  /* SABOTAGE SARCONST: a constant ~>> count of -64 or less fills with the sign */'
arm BCDUMP lj_bcdump.h 'security:FF12 gate:dump' \
  '#define BCDUMP_VERSION@T@@T@0x80' \
  '#define BCDUMP_VERSION@T@@T@2  /* SABOTAGE BCDUMP: upstream version 2 */'
arm WORDTOKEN eris_lj.c 'stage4' \
  '#define ELJ_W_BIT "bit64"' \
  '#define ELJ_W_BIT "bit32"  /* SABOTAGE WORDTOKEN: the word says 32-bit operators */'
arm INEXACT-INTERP vm_x64.dasc 'bitop:t_ops fuzz:V' \
  '    |  cmp RA, RC' \
  '    |  cmp RA, RA@T@@T@// SABOTAGE INEXACT-INTERP: the result check always passes'
arm INEXACT-BNOT vm_x64.dasc 'bitop:t_ops bitop:t_fold fuzz:V' \
  '    |  cmp TMPR, RB' \
  '    |  cmp TMPR, TMPR@T@@T@// SABOTAGE INEXACT-BNOT: the result check of unary ~ always passes'
arm INEXACT-SLOW oclj_bitop_meta.c 'bitop:t_ops-str' \
  '      ob_err_inexact(L, op);' \
  '      n = (double)oclj_u2s(oclj_bitop64((int)op, b, c));  /* SABOTAGE INEXACT-SLOW: the slow path stores the rounded double */'
arm INEXACT-FOLD lj_parse.c 'bitop:t_fold fuzz:K' \
  '      if (!oclj_bit2num(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2), &d))' \
  '      if (d = (double)oclj_u2s(oclj_bitop64((int)opr-OPR_BAND+BC_BAND, k1, k2)), 0)  /* SABOTAGE INEXACT-FOLD: the parser folds the rounded double */'
arm INEXACT-JIT oclj_bitop_rec.c 'gen genrg2' \
  '  if (!tref_isk(res)) {' \
  '  if (0) {  /* SABOTAGE INEXACT-JIT: no guard after a recorded result */'
arm SELFGUARD lj_opt_fold.c 'gen genrg2' \
  '@T@!(fins->op2 & OCLJ_IRCONV_EXACT))' \
  "@T@1)  /* SABOTAGE SELFGUARD: the exact-mark rule also folds a result guard's own check */"
arm WIDTH55 lj_opt_fold.c 'gen genrg2' \
  '    if (oclj_bitwidth(J, fleft->op1, 0) <= 54)' \
  '    if (oclj_bitwidth(J, fleft->op1, 0) <= 55)  /* SABOTAGE WIDTH55: a bound of 55 bits passes */'
arm WSHR oclj_bitop_fold.c 'gen' \
  '      return 65 - (IR(ir->op2)->i & 63);  /* In [0, 2^(64-k)). */' \
  '      return 64 - (IR(ir->op2)->i & 63);  /* SABOTAGE WSHR: BSHR by k bounded by 64 - k */'
arm WBAND oclj_bitop_fold.c 'gen' \
  '    if (IR(ir->op2)->o == IR_KINT64 && (int64_t)ir_k64(IR(ir->op2))->u64 >= 0)' \
  "    if (IR(ir->op2)->o == IR_KINT64)  /* SABOTAGE WBAND: BAND bounded by its constant's width, whatever the constant's sign */"
arm WADD0 oclj_bitop_fold.c 'gen' \
  '    wa = (wa > wb ? wa : wb) + 1;' \
  '    wa = (wa > wb ? wa : wb) + 0;  /* SABOTAGE WADD0: x + x as wide as x */'
arm WSHL0 oclj_bitop_fold.c 'gen' \
  '      wa = oclj_bitwidth(J, ir->op1, depth+1) + (IR(ir->op2)->i & 63);' \
  '      wa = oclj_bitwidth(J, ir->op1, depth+1) + (IR(ir->op2)->i & 31);  /* SABOTAGE WSHL0: BSHL by k widens by k mod 32 */'
arm FIX1 lj_opt_fold.c 'fix1' \
  '      (irt_isi64(IR(fleft->op1)->t) || !irt_isphi(fleft->t))) {' \
  '      (1 || !irt_isphi(fleft->t))) {  /* SABOTAGE FIX1: across a PHI, the fold takes any y */'
arm WIDTHIDX33 lj_opt_fold.c 'idx:t_idx idx:t_cnt33 idx:t_idx2' \
  '      oclj_bitwidth(J, fleft->op1, 0) <= 32) {' \
  '      oclj_bitwidth(J, fleft->op1, 0) <= 33) {  /* SABOTAGE WIDTHIDX33: the table-index fold takes a 33-bit y, whose low 32 bits are not y */'
arm PHIIDX lj_opt_fold.c 'idx:phiidx' \
  '  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && !irt_isphi(fleft->t) &&' \
  '  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && (1 || !irt_isphi(fleft->t)) &&  /* SABOTAGE PHIIDX: the table-index fold crosses a PHI */'
arm NOLOOPFOLD lj_opt_fold.c 'idx:phiidx' \
  '  if ((fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && !irt_isphi(fleft->t) &&' \
  '  if (!J->chain[IR_LOOP] && (fleft->op2 & IRCONV_SRCMASK) == IRT_I64 && !irt_isphi(fleft->t) &&  /* SABOTAGE NOLOOPFOLD: the table-index fold never fires in a loop body, where the speed is (verify-folda) */'
arm SELGUARD lj_record.c 'sel:t_select' \
  '@T@  emitir(IRTGI(IR_ULT), tmp2, lj_ir_kint(J, OCLJ_SELECT_KMAX));  /* OC-LuaJIT: 1 <= k <= 2^27, or exit. */' \
  "@T@  (void)0;  /* SABOTAGE SELGUARD: no guard on select's k before the shift, upstream's path C: a k whose 8*k wraps, or a k <= 0 in a short call, gives nil */"
arm SELRECK lj_record.c 'sel:kmax' \
  '      if (idx > OCLJ_SELECT_KMAX) goto nyivarg;  /* OC-LuaJIT: as for k < 0. */' \
  "      /* SABOTAGE SELRECK: no record-time bound on select's k, so a loop recorded with k above 2^27 compiles, as upstream's does */"
arm NUMCONVOP1 lj_opt_fold.c 'nc:t_numconv nc:ncir' \
  '    if (oclj_isnumconv(J, fleft->op1))' \
  '    if (oclj_isnumconv(J, fleft->op1) || (IR(fleft->op1)->o >= IR_BNOT && IR(fleft->op1)->o <= IR_BSAR && oclj_isnumconv(J, IR(fleft->op1)->op1)))  /* SABOTAGE NUMCONVOP1: a bit operator on a converted double counts as one, so its result guard goes */'
arm NUMCONVW oclj_bitop_fold.c 'nc:t_numconv nc:ncir' \
  '    if ((ir->op2 & IRCONV_SRCMASK) == IRT_INT)' \
  '    if ((ir->op2 & IRCONV_SRCMASK) == IRT_NUM) return 54; else if ((ir->op2 & IRCONV_SRCMASK) == IRT_INT)  /* SABOTAGE NUMCONVW: a converted double scored 54 bits wide, exactness put into the bound */'
arm NUMCONVOFF lj_opt_fold.c 'nc:ncir' \
  '    if (oclj_isnumconv(J, fleft->op1))' \
  '    if (0 && oclj_isnumconv(J, fleft->op1))  /* SABOTAGE NUMCONVOFF: FIX-NUMCONV switched off, so every identity keeps its result guard */'
arm NUMCONVNOOP oclj_bitop_fold.c 'gen' \
  '  return ir->o == IR_CONV && irt_isi64(ir->t) && !irt_isguard(ir->t) &&' \
  '  return irt_isi64(ir->t) && !irt_isguard(ir->t) &&  /* SABOTAGE NUMCONVNOOP: no opcode test, so a bit operator whose op2 ref reads as NUM passes for a converted double and loses its result guard */'
arm CSEFWD lj_opt_fold.c 'cse:t_csefwd cse:cseir' \
  '@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))' \
  '@T@  (irt_isi64(IR(ref)->t) == irt_isi64(fins->t) || irt_isi64(fins->t)))  /* SABOTAGE CSEFWD: an int64 instruction may common with an older narrower one, the forward order, as before hunk 12; the reverse stays refused */'
}
