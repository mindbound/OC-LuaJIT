# mklend.py -- an EXPLORATORY SKETCH (not a design) of the roadmap's idea on
# record, "lend the first crossing after each proof and let the cycle it arms
# decide", applied to a copy of the stage-C shim, C mode only, to see whether
# W16 can pass on a behavioural change.  Repo untouched.
#   - gc_canlend: set at a proof that finds the heap at or under the tier's top
#     (sandbox's: total + G/2, or + G in the reserve), cleared when a crossing
#     is lent.  A proof that finds the heap past the top leaves it clear, so
#     the next crossing is refused: no ratchet past one lent request per proof.
#   - a crossing (a growth past total + credit) while gc_canlend, of at most
#     LEND_MAX bytes, where the credit applies at all: granted, the cycle armed.
import sys
src, dst, lendmax = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, newline="").read()
def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new, 1)
rep("  long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */",
    "  long long     gc_odpeak;     /* the largest excursion past the cap, bytes   */\n  int           gc_canlend;    /* SKETCH: one crossing may be lent            */")
rep("static void lj52_gc_refused(lj52_mem *M, long long total, long long used);",
    "static void lj52_gc_refused(lj52_mem *M, long long total, long long used);\nstatic int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta);")
rep("""    if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {
      lj52_gc_refused(M, M->total, M->used);""",
    """    if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta
        && !lj52_gc_lend(M, M->total, M->used, delta)) {
      lj52_gc_refused(M, M->total, M->used);""")
rep("""static void lj52_gc_refused(lj52_mem *M, long long total, long long used)
{""", """#define LJ52_GC_LENDMAX (""" + lendmax + """)
/* SKETCH: lend this crossing?  Arms the cycle that will decide. */
static int lj52_gc_lend(lj52_mem *M, long long total, long long used, long long delta)
{
  global_State *g;
  (void)used;
  if (!M->gc_canlend || delta > LJ52_GC_LENDMAX || M->L == NULL || total <= 0) return 0;
  g = G(M->L);
  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;
  M->gc_canlend = 0;
  if (M->gc_armed) M->gc_armby = LJ52_ARM_WALL;
  else lj52_gc_arm(M, g, LJ52_ARM_WALL);
  return 1;
}

static void lj52_gc_refused(lj52_mem *M, long long total, long long used)
{""")
rep("""      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */""",
    """      if (used <= total) M->gc_odstate = LJ52_OD_BURST;   /* repaid */
      M->gc_canlend = used <= total + (M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_odmax(total)
                                                                        : lj52_gc_odmax(total) >> 1);""")
open(dst, "w", newline="").write(s)
print("ok")
