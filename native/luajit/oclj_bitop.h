/*
** native/luajit/oclj_bitop.h -- Lua 5.3.6's bitwise operators on a VM whose
** numbers are all doubles: the RULES, with no Lua state, shared by the three
** places that compute them in C, so that they cannot disagree:
**   lj_parse.c     constant folding: foldbitop and the unary ~ fold
**                  (native/luajit/patch-bitop-parse.sh)
**   lj_meta.c      the interpreter's slow path: oclj_bitop_meta.c
**                  (patch-bitop-meta.sh)
**   lj_record.c    the recorder's record-time decisions: oclj_bitop_rec.c
**                  (patch-bitop-record.sh)
** lj_opt_fold.c includes it for OCLJ_IRCONV_EXACT (patch-bitop-fold.sh).
** The interpreter's fast path (vm_x64.dasc, patch-bitop-vm.sh) and the IR
** the JIT compiles implement the same rules in machine code; the tests
** compare all five with PUC Lua 5.3.6 (test/native/run-bitop.sh,
** run-bitjit.sh, run-bitfuzz.sh).  native/luajit/oclj_features.h names this
** change once, as OCLJ_OPS_BIT64, and this header refuses to compile without
** it: serializer/eris_lj.c writes the blob fingerprint's bit64 token from
** that macro.
**
** From PUC Lua 5.3.6:
**   operand -> integer: luaV_tointeger, mode 0 (lvm.c:94-117): a float must
**     be integral and in [-2^63, 2^63) (luaconf.h:447-451).  That is
**     oclj_flt2int, in oclj_num53.h, which string.pack shares.
**   & | ~ and unary ~: on int64, wrapping (lvm.h:46 intop; ~x is x ^ ~0,
**     lvm.c:1046-1055).
**   << >>: luaV_shiftl (lvm.c:588-601); x >> n is shiftl(x, -n) (lvm.c:986).
**   result: an int64.  Here it becomes the double that equals it.  A result
**     with more than 53 significant bits has no such double and raises
**     "result of '<op>' has more than 53 significant bits (mask each operand
**     to 32 bits first)" (decided 2026-10-17: a wrong value is worse than an
**     error, and user code has a remedy, masking to the width it means
**     first: (n & 0xFFFFFFFF) >> 8; the hint names it, oclj_bitop_meta.c).
**     So every result that does not raise is exactly 5.3.6's.
**   ~>> (LuaJIT 3.0's arithmetic shift, not 5.3): sar on int64; a count of
**     64 or more fills with the sign; a negative count shifts left (the
**     mirror of >>).
*/
#ifndef OCLJ_BITOP_H
#define OCLJ_BITOP_H

#include <stdint.h>

#include "lj_obj.h"
#include "lj_bc.h"

#ifndef OCLJ_LUAJIT_FEATURES
#error "oclj_bitop.h must be compiled inside native/build-native.sh's LuaJIT build copy, whose lj_arch.h includes native/luajit/oclj_features.h"
#endif
#if !defined(OCLJ_OPS_BIT64) || OCLJ_OPS_BIT64 != 1
#error "oclj_bitop.h: native/luajit/oclj_features.h does not say OCLJ_OPS_BIT64 1, so serializer/eris_lj.c would not name the 64-bit operators in the blob fingerprint (its bit64 token)"
#endif
#if LJ_DUALNUM
#error "oclj_bitop.h: the 64-bit bitwise operators assume every number is a double (no LJ_DUALNUM)"
#endif

#include "oclj_num53.h"  /* oclj_flt2int, oclj_u2s */

/* 5.3.6 luaV_shiftl: shift left by y, or right (logical) by -y. */
static LJ_AINLINE uint64_t oclj_shiftl(uint64_t x, int64_t y)
{
  if (y < 0) {
    if (y <= -64) return 0;
    return x >> (unsigned)(-y);
  } else {
    if (y >= 64) return 0;
    return x << (unsigned)y;
  }
}

/* ~>> on int64 (not 5.3; see the header). */
static LJ_AINLINE uint64_t oclj_shiftar(uint64_t x, int64_t y)
{
  if (y < 0) return y <= -64 ? 0 : x << (unsigned)(-y);
  if (y >= 64) return (int64_t)x < 0 ? ~(uint64_t)0 : 0;
  return (int64_t)x < 0 ? ~(~x >> (unsigned)y) : x >> (unsigned)y;
}

/* op is BC_BNOT..BC_BSAR; for BC_BNOT, c is ignored.  BC_BSHR passes -c to
** luaV_shiftl as 5.3.6 does (lvm.c:986), keeping INT64_MIN as INT64_MIN,
** which shifts to 0 either way. */
static LJ_AINLINE uint64_t oclj_bitop64(int op, int64_t b, int64_t c)
{
  uint64_t x = (uint64_t)b, y = (uint64_t)c;
  switch (op) {
  case BC_BNOT: return ~x;
  case BC_BAND: return x & y;
  case BC_BOR: return x | y;
  case BC_BXOR: return x ^ y;
  case BC_BSHL: return oclj_shiftl(x, c);
  case BC_BSHR: return oclj_shiftl(x, c == INT64_MIN ? INT64_MIN : -c);
  default: return oclj_shiftar(x, c);  /* BC_BSAR */
  }
}

/* The double of an int64 result, if one equals it: 1 and *d, or 0 when the
** result has more than 53 significant bits (such a result raises; see the
** header).  The test is the round trip int64 -> double -> int64, which is
** what the interpreter's fast path (cvtsi2sd, cvttsd2si, cmp) and the JIT's
** guard compute.  2^63 is where a result near INT64_MAX rounds to; it has no
** int64, so it is refused before the conversion back (C99 6.3.1.4). */
static LJ_AINLINE int oclj_bit2num(uint64_t r, double *d)
{
  int64_t i = oclj_u2s(r);
  double n = (double)i;
  if (n >= 9223372036854775808.0) return 0;
  *d = n;
  return (int64_t)n == i;
}

/* OC-LuaJIT IR: a mode bit of a CONV's op2.  LuaJIT 2.1 does not use it: no
** CONV op2 carries bit 0x400, and every exact op2 comparison in LuaJIT is
** against IRCONV_NUM_INT (lj_snap.c:585, :654, :738, :798, lj_opt_sink.c:55,
** lj_asm.c:986), which a marked conversion never is.  It lies inside
** IRCONV_MODEMASK (0x0fff, lj_ir.h:258), so cse_conv (lj_opt_fold.c:1286-1303)
** never merges a marked with an unmarked conversion; and outside the fold
** key's literal mask 0x3ff (lj_opt_fold.c:2566), so every CONV fold rule
** still matches a marked one.
**   On CONV num.i64 (oclj_bitop_rec.c, an operator's result, or an operand's
**   conversion back): the double is exactly the int64, because a guard right
**   after it says so (or the width rule proved it).  (i64) of it folds to
**   the int64 (lj_opt_fold.c's simplify_conv_i64_num, patch-bitop-fold.sh).
**   On CONV i64.num: this conversion is a result guard's own check, which
**   that rule must not fold; only the width rule may remove it. */
#define OCLJ_IRCONV_EXACT	0x0400

#endif
