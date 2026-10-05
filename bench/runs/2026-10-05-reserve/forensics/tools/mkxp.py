# mkxp.py <instrumented lj52shim.c> <out lj52shim.c> <A|B> <lit|rec>
# THE EXPERIMENT (scratch only, never for the repo): the obvious lever on the
# second-chance path, applied to the instrumented copy so its stream still
# classifies every refusal.
#   A  a refusal raised under the predicate does not open the reserve tier
#      (lj52_gc_refused skips gc_odstate = RESERVE; it still counts, shuts
#      the window and arms, as before)
#   B  a growth under the predicate is never refused: it is granted and
#      charged (like norefuse), before THE WINDOW is consulted
# The predicate:
#   lit  J->state != LJ_TRACE_IDLE  (the task's literal form: also true while
#        the interpreter runs the instruction just recorded)
#   rec  inside the trace recorder's protected call (the instrument's own
#        "recorder" classification: cpcall frame, J->state not idle, vmstate
#        not C/GC/EXIT) -- the refusals trace_abort drops
# Each time the predicate is true where it is consulted (A: in a refusal;
# B: a growth past the top that would otherwise have gone to THE WINDOW or
# been refused) one line "OCLJXP| fired=1 ..." goes to stderr (OCLJ_REFLOG).
import sys
src, dst, kind, pred = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
assert kind in ("A", "B") and pred in ("lit", "rec")
s = open(src, "r", newline="").read()


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: %d" % (what, n)
    return s.replace(anchor, new, 1)


NOTE = r'''/* EXPERIMENT (mkxp.py): one line per firing of the lever (OCLJ_REFLOG set). */
static void oclj_xp_note(lj52_mem *M)
{
  global_State *g = G(M->L);
  if (M->oc_log <= 0) return;
  fprintf(stderr, "OCLJXP| fired=1 used=%lld total=%lld tier=%d win=%d vm=%s jst=%s\n",
          M->used, M->csync ? M->total : M->gc_seentotal, M->gc_odstate, M->gc_win,
          oclj_vmname(g->vmstate), oclj_jname(G2J(g)->state));
  fflush(stderr);
}
'''
LIT = r'''/* EXPERIMENT (mkxp.py): J->state != LJ_TRACE_IDLE. */
static int oclj_xp_pred(lj52_mem *M)
{
  int r;
  if (M->L == NULL) return 0;
  r = G2J(G(M->L))->state != LJ_TRACE_IDLE;
  if (r) oclj_xp_note(M);
  return r;
}
'''
REC = r'''/* EXPERIMENT (mkxp.py): inside the trace recorder's protected call. */
static int oclj_xp_pred(lj52_mem *M)
{
  global_State *g;
  lua_State *L;
  void *cf;
  if (M->L == NULL) return 0;
  g = G(M->L);
  if (G2J(g)->state == LJ_TRACE_IDLE) return 0;
  if (g->vmstate >= 0 || g->vmstate == ~LJ_VMST_C || g->vmstate == ~LJ_VMST_GC
      || g->vmstate == ~LJ_VMST_EXIT) return 0;
  L = gco2th(gcref(g->cur_L));
  if (L == NULL) return 0;
  cf = cframe_raw(L->cframe);
  if (cf != NULL && cframe_nres(cf) < 0 && (char *)cframe_pc(cf) == (char *)cframe_L(cf)) {
    oclj_xp_note(M);
    return 1;
  }
  return 0;
}
'''
s = splice(s, "static void oclj_ref_init(lj52_mem *M);\n",
           "static void oclj_ref_init(lj52_mem *M);\nstatic int oclj_xp_pred(lj52_mem *M);\n", "proto")
# after the name helpers (oclj_vmname/oclj_jname), before the chunk reader
s = splice(s, "/* The chunkname's last cap-1 bytes,",
           NOTE + "\n" + (LIT if pred == "lit" else REC) + "\n/* The chunkname's last cap-1 bytes,",
           "pred body")
if kind == "A":
    s = splice(s, "  M->gc_odstate = LJ52_OD_RESERVE;\n  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n",
               "  if (!oclj_xp_pred(M)) M->gc_odstate = LJ52_OD_RESERVE;   /* EXPERIMENT A */\n"
               "  M->gc_win = 0;                        /* THE WINDOW: its cycle decides anew */\n",
               "refused")
else:
    s = splice(s, "        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta\n        && !lj52_gc_lend(M, M->total, M->used, delta)) {\n",
               "        && M->total + lj52_gc_credit(M, M->total, M->used) - M->used < delta\n"
               "        && !oclj_xp_pred(M)   /* EXPERIMENT B */\n"
               "        && !lj52_gc_lend(M, M->total, M->used, delta)) {\n",
               "C-mode")
    s = splice(s, "        || total + lj52_gc_credit(M, total, used) - used >= delta\n        || lj52_gc_lend(M, total, used, delta))) {\n",
               "        || total + lj52_gc_credit(M, total, used) - used >= delta\n"
               "        || oclj_xp_pred(M)    /* EXPERIMENT B */\n"
               "        || lj52_gc_lend(M, total, used, delta))) {\n",
               "legacy")
assert "\r" not in s
open(dst, "w", newline="").write(s)
print("wrote", dst, kind, pred)
