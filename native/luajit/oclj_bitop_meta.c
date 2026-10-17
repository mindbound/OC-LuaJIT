/*
** native/luajit/oclj_bitop_meta.c -- the interpreter's slow path for Lua
** 5.3.6's bitwise operators.  native/build-native.sh copies this file into
** the LuaJIT build copy's src/, and native/luajit/patch-bitop-meta.sh makes
** that copy's lj_meta.c #include it directly above lj_meta_bitop
** (lj_meta.c:242), whose no-FFI tail then calls oclj_meta_bitop.  The rules
** are oclj_bitop.h's, the ones folding and the recorder use.
**
** vm_x64.dasc's fast path (patch-bitop-vm.sh) computes when both operands
** are doubles that are exactly integers in [-2^63, 2^63), the shift count of
** << >> ~>> is in [0, 63], and the result has a double that equals it.
** Everything else lands here, through ->vmeta_bnot or ->vmeta_bitop
** (vm_x64.dasc:1098-1105):
**   - a string operand: coerced by 5.3.6's luaO_str2num (lobject.c:331-343),
**     the reading string.pack gives its arguments (oclj_num53.h): a decimal
**     numeral that fits int64 is exact, a hex numeral of any length wraps
**     mod 2^64, and anything else is read as a float.
**   - a shift count outside [0, 63]: 5.3.6's luaV_shiftl (oclj_bitop.h).
**   - a result with more than 53 significant bits: "result of '<op>' has
**     more than 53 significant bits (mask each operand to 32 bits first)"
**     (oclj_bit2num; decided 2026-10-17, the hint added the same day).
**     The fast path sends it here from the untouched operand slots, and this
**     recomputes it, so the message names the operator from the bytecode.
**   - a number with no integer representation, or any other type: 5.3.6's
**     errors (ltm.c:142-149): if both operands are numbers or numeric
**     strings, "number has no integer representation", naming the first that
**     fails the conversion (ldebug.c:610-615), else "attempt to perform
**     bitwise operation on", naming the first that is not a number
**     (ldebug.c:598-604).
**   - no bitwise metamethods: LuaJIT 2.1 has none (a2ce8114, "Not
**     backported: bit operator metamethods"); a later round adds them.
** The messages use LuaJIT's slot names (lj_debug_slotname) and, for the type
** error, LuaJIT's word order, as every other operator error on this VM does:
** "attempt to perform bitwise operation on local 't' (a table value)".  They
** are raised the way lj_err.c's err_msgv raises (lj_err.c:931), by a copy
** here, so lj_err.c, which patch-fastfunc-errmem-top.sh already changes, is
** not changed again, and lj_errmsg.h gains no message.
*/

#if LJ_HASFFI
#error "oclj_bitop_meta.c replaces lj_meta_bitop's no-FFI path only"
#endif

#include "lj_debug.h"
#include "oclj_bitop.h"

/* What 5.3.6 sees in an operand (lvm.c:94-117, lobject.c:331-343):
** 0 not a number, 1 an integer (*pi), 2 a float (*pn).  Every number of
** this VM is a float; only a string can yield a 5.3 integer. */
static int ob_tonum(cTValue *o, int64_t *pi, double *pn)
{
  if (tvisnum(o)) { *pn = numV(o); return 2; }
  if (tvisstr(o)) {
    if (oclj_str2int(strVdata(o), strV(o)->len, pi)) return 1;
    if (oclj_str2d(strVdata(o), strV(o)->len, pn)) return 2;
  }
  return 0;
}

/* 5.3.6 luaV_tointeger, mode 0. */
static int ob_toint(cTValue *o, int64_t *p)
{
  int64_t i;
  double n;
  switch (ob_tonum(o, &i, &n)) {
  case 1: *p = i; return 1;
  case 2: return oclj_flt2int(n, p);
  default: return 0;
  }
}

/* lj_err.c's err_msgv (lj_err.c:931-945), with a format string instead of
** an ErrMsg. */
LJ_NORET LJ_NOINLINE static void ob_errv(lua_State *L, const char *fmt, ...)
{
  const char *msg;
  va_list argp;
  va_start(argp, fmt);
  if (LJ_HASJIT) {
    TValue *base = tvref(G(L)->jit_base);
    if (base) L->base = base;
  }
  if (curr_funcisL(L)) L->top = curr_topL(L);
  msg = lj_strfmt_pushvf(L, fmt, argp);
  va_end(argp);
  lj_debug_addloc(L, msg, L->base-1, NULL);
  lj_err_run(L);
}

#define OB_VERB		"perform bitwise operation on"

/* lj_err_optype (lj_err.c:968) with 5.3's verb, LuaJIT's formats
** (lj_errmsg.h:27-28). */
LJ_NORET LJ_NOINLINE static void ob_err_type(lua_State *L, cTValue *o)
{
  const char *tname = lj_typename(o);
  if (curr_funcisL(L)) {
    GCproto *pt = curr_proto(L);
    const BCIns *pc = cframe_Lpc(L) - 1;
    const char *oname = NULL;
    const char *kind = lj_debug_slotname(pt, pc, (BCReg)(o-L->base), &oname);
    if (kind)
      ob_errv(L, err2msg(LJ_ERR_BADOPRT), OB_VERB, kind, oname, tname);
  }
  ob_errv(L, err2msg(LJ_ERR_BADOPRV), OB_VERB, tname);
}

/* 5.3.6 luaG_tointerror: "number%s has no integer representation". */
LJ_NORET LJ_NOINLINE static void ob_err_noint(lua_State *L, cTValue *o)
{
  if (curr_funcisL(L)) {
    GCproto *pt = curr_proto(L);
    const BCIns *pc = cframe_Lpc(L) - 1;
    const char *oname = NULL;
    const char *kind = lj_debug_slotname(pt, pc, (BCReg)(o-L->base), &oname);
    if (kind)
      ob_errv(L, "number (%s '%s') has no integer representation", kind, oname);
  }
  ob_errv(L, "number has no integer representation");
}

/* A result with more than 53 significant bits has no double (oclj_bit2num).
** Not a 5.3.6 message: 5.3.6 has an integer subtype and computes it.  The
** hint names the remedy for the cases that meet it in practice: a negative
** number shifted (-2 >> 8), and halves joined before their mask, as in the
** 32-bit rotate ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF, whose | has up
** to 64 - n significant bits; masking each piece first keeps every result
** within 32 bits, (x >> n) | ((x << (32 - n)) & 0xFFFFFFFF). */
LJ_NORET LJ_NOINLINE static void ob_err_inexact(lua_State *L, BCReg op)
{
  static const char *const opname[] = { "~", "&", "|", "~", "<<", ">>", "~>>" };
  ob_errv(L, "result of '%s' has more than 53 significant bits"
	  " (mask each operand to 32 bits first)", opname[op - BC_BNOT]);
}

/* ra = rb op rc; for BC_BNOT, rb and rc are the same operand
** (vm_x64.dasc:1098-1102). */
static void oclj_meta_bitop(lua_State *L, TValue *ra, cTValue *rb,
			    cTValue *rc, BCReg op)
{
  int64_t b, c, i;
  double n;
  if (ob_toint(rb, &b) && ob_toint(rc, &c)) {
    if (!oclj_bit2num(oclj_bitop64((int)op, b, c), &n))
      ob_err_inexact(L, op);
    setnumV(ra, n);
    return;
  }
  if (ob_tonum(rb, &i, &n) && ob_tonum(rc, &i, &n))
    ob_err_noint(L, ob_toint(rb, &i) ? rc : rb);
  ob_err_type(L, ob_tonum(rb, &i, &n) ? rc : rb);
}
