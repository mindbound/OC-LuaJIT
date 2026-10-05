# mkinstr.py -- make an INSTRUMENTED copy of lj52shim.c for the repro.
# The copy records, at every refusal, the request's delta and the record's
# state (used, total, credit, tier, armed, ...) in exported globals, and
# nothing else: no branch of the shim's logic changes.  The repo is never
# touched; the copy lives in repro/shimsrc-instr/.
import sys, os
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", newline="") as f:
    s = f.read()

GLOBALS = """
/* ---- REPRO INSTRUMENT (not in the repo) ---- */
long long oclj_ref_n = 0, oclj_ref_delta = 0, oclj_ref_used = 0, oclj_ref_total = 0;
long long oclj_ref_credit = 0, oclj_ref_low = 0, oclj_ref_gctotal = 0, oclj_ref_thresh = 0;
long long oclj_ref_calls = 0;
int oclj_ref_tier = 0, oclj_ref_armed = 0, oclj_ref_hyst = 0, oclj_ref_kernel = 0, oclj_ref_gcstate = 0;
int oclj_ref_armby = 0;
static void oclj_ref_record(lj52_mem *M, long long total, long long used, long long delta);
"""

anchor = "static jint lj52_clampi(long long v) {"
assert s.count(anchor) == 1
s = s.replace(anchor, GLOBALS + anchor, 1)

old_c = """      lj52_gc_refused(M, M->total, M->used);
      return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */"""
new_c = """      oclj_ref_record(M, M->total, M->used, delta);
      lj52_gc_refused(M, M->total, M->used);
      return NULL;                      /* -> lj_err_mem -> LUA_ERRMEM */"""
assert s.count(old_c) == 1
s = s.replace(old_c, new_c, 1)

old_l = """    lj52_gc_refused(M, total, used);
    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */"""
new_l = """    oclj_ref_record(M, total, used, delta);
    lj52_gc_refused(M, total, used);
    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */"""
assert s.count(old_l) == 1
s = s.replace(old_l, new_l, 1)

# The recorder, defined after lj52_gc_credit (it needs G() and the credit).
REC = """
/* REPRO INSTRUMENT: called BEFORE lj52_gc_refused, so tier/armed are the
 * record's state at the moment of the refused request. */
static void oclj_ref_record(lj52_mem *M, long long total, long long used, long long delta)
{
  global_State *g = M->L ? G(M->L) : NULL;
  oclj_ref_n++;
  oclj_ref_delta = delta;
  oclj_ref_used = used;
  oclj_ref_total = total;
  oclj_ref_credit = lj52_gc_credit(M, total, used);
  oclj_ref_tier = M->gc_odstate;
  oclj_ref_armed = M->gc_armed;
  oclj_ref_armby = M->gc_armby;
  oclj_ref_hyst = M->gc_hyst;
  oclj_ref_low = M->gc_low;
  oclj_ref_calls = M->mem_calls;
  oclj_ref_kernel = g ? lj52_gc_kernel(M, g) : -1;
  oclj_ref_gctotal = g ? (long long)g->gc.total : -1;
  oclj_ref_thresh = g ? (long long)g->gc.threshold : -1;
  oclj_ref_gcstate = g ? (int)g->gc.state : -1;
}
"""
anchor2 = "/* A refusal: counted, the valve and the proof seen to first, then the"
assert s.count(anchor2) == 1
s = s.replace(anchor2, REC + anchor2, 1)

os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w", newline="") as f:
    f.write(s)
print("wrote", dst, len(s))
