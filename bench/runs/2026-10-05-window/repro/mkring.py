# mkring.py -- a second instrumented copy: everything mkinstr.py adds, plus a
# ring of the last 256 C-mode allocator calls (delta, used before, armed,
# gc_low, gc_collects, gc.state, gc.total, gc.threshold, granted).  Logic
# unchanged.  Repo untouched.  Input: the mkinstr.py output.
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline="").read()
RING = """
/* ---- REPRO RING (not in the repo) ---- */
typedef struct { long long delta, used, low, gctotal, thresh; long collects, arms; int armed, state, granted, hyst; } oclj_ringent;
oclj_ringent oclj_ring[256];
long long oclj_ringn = 0;
static void oclj_ring_log(lj52_mem *M, long long delta);
"""
anchor = "/* ---- REPRO INSTRUMENT (not in the repo) ---- */"
assert s.count(anchor) == 1
s = s.replace(anchor, RING + anchor, 1)
old = """    if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {"""
new = """    if (acct) oclj_ring_log(M, delta);
    if (acct && delta > 0 && !M->norefuse && M->total - M->used < delta
        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta) {
      oclj_ring[(oclj_ringn - 1) & 255].granted = 0;"""
assert s.count(old) == 1
s = s.replace(old, new, 1)
FN = """
static void oclj_ring_log(lj52_mem *M, long long delta)
{
  oclj_ringent *re = &oclj_ring[oclj_ringn & 255];
  global_State *rg = M->L ? G(M->L) : NULL;
  oclj_ringn++;
  re->delta = delta; re->used = M->used; re->low = M->gc_low; re->armed = M->gc_armed; re->hyst = M->gc_hyst;
  re->collects = M->gc_collects; re->arms = M->gc_arms; re->granted = 1;
  re->state = rg ? (int)rg->gc.state : -1;
  re->gctotal = rg ? (long long)rg->gc.total : -1;
  re->thresh = rg ? (long long)rg->gc.threshold : -1;
}
"""
anchor2 = "/* REPRO INSTRUMENT: called BEFORE lj52_gc_refused"
assert s.count(anchor2) == 1
s = s.replace(anchor2, FN + anchor2, 1)
open(dst, "w", newline="").write(s)
print("ok")
