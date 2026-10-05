# mkalloc.py <instrumented lj52shim.c> <out lj52shim.c> <from_call>
# A SCRATCH tracing copy for one run (the deterministic case): with
# OCLJ_REFLOG=4, every C-mode growth from allocator call <from_call> on is
# printed BEFORE the shim decides it, with its location, as
#   OCLJALLOC| calls= delta= used= total= win= armed= vm= jst= fk= at=
# No branch changes; only for reading where the window's lends, the proofs
# and the refusal fell between the batch and the landing.
import sys
src, dst, frm = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = open(src, "r", newline="").read()


def splice(s, anchor, new, what):
    n = s.count(anchor)
    assert n == 1, "%s: %d" % (what, n)
    return s.replace(anchor, new, 1)


s = splice(s, "static void oclj_ref_init(lj52_mem *M);\n",
           "static void oclj_ref_init(lj52_mem *M);\nstatic void oclj_alloc_note(lj52_mem *M, long long delta);\n", "proto")
s = splice(s, "    if (acct && delta > 0 && M->total - M->used < delta)\n      lj52_gc_look(M, M->total, M->used);   /* THE WINDOW: a finished cycle first */\n",
           "    if (acct && delta > 0) oclj_alloc_note(M, delta);\n"
           "    if (acct && delta > 0 && M->total - M->used < delta)\n      lj52_gc_look(M, M->total, M->used);   /* THE WINDOW: a finished cycle first */\n",
           "alloc")
BODY = r'''static void oclj_alloc_note(lj52_mem *M, long long delta)
{
  oclj_refrec r;
  global_State *g;
  if (M->oc_log < 4 || M->mem_calls < FROMCALL || M->L == NULL) return;
  g = G(M->L);
  memset(&r, 0, sizeof r);
  oclj_where(gco2th(gcref(g->cur_L)), g, &r, g->vmstate >= 0);
  fprintf(stderr, "OCLJALLOC| calls=%lld delta=%lld used=%lld total=%lld win=%d armed=%d vm=%s jst=%s fk=%s ffid=%d at=%s:%d\n",
          M->mem_calls, delta, M->used, M->total, M->gc_win, M->gc_armed,
          oclj_vmname(g->vmstate), oclj_jname(G2J(g)->state), oclj_fkname(r.fkind), r.ffid,
          r.chunk[0] ? r.chunk : "?", r.line);
  fflush(stderr);
}
'''.replace("FROMCALL", str(frm))
s = splice(s, "/* lj52_gc_credit without its one side effect",
           BODY + "\n/* lj52_gc_credit without its one side effect", "body")
open(dst, "w", newline="").write(s)
print("wrote", dst)
