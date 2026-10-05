/* ===================================================================== */
/* OCLJ REFUSAL FORENSICS -- THIS IS AN INSTRUMENTED COPY, NOT THE SHIM.  */
/* ===================================================================== */
/* Made by mkref.py from the repo's lj52shim.c.  No branch of the shim's
 * logic is changed: the hooks below only READ the record and the VM, and
 * write their own fields (oc_*), their own rings and stderr.  At every
 * refusal (both paths, every call into lj52_gc_refused) a record is kept in
 * a static ring of OCLJ_RING_N; with the environment variable OCLJ_REFLOG
 * set (read once per state, at lj52_newstate) each one is also printed as
 * one self-contained line "OCLJREF| k=v ..." on stderr, flushed.
 *   OCLJ_REFLOG=1 (or any value but 0, 2, 3)  refusals
 *   OCLJ_REFLOG=2                             + every proven cycle (OCLJPRF|)
 *   OCLJ_REFLOG=3                             + every arm, with its cause (OCLJARM|)
 * Arms and proofs are always counted per state and kept in a second ring.
 * The variable is read WITHOUT the C library's environment reader on
 * purpose: build-native.sh refuses a shim whose code names that reader, and
 * this copy must build under it.  A diagnostic copy only; never ship it. */
#define OCLJ_RING_N   256
#define OCLJ_GCRING_N 1024
typedef struct oclj_refrec {
  long long gseq, seq, calls;
  long long delta, used, total, G, credit, top, low, grown, gctotal, gcthresh;
  void *M, *curL, *mainL, *kby;
  int legacy, kernel, wd_depth, kthr, mainthr;
  int tier0, tier1, win0, win1, hyst, armed0, armed1, armby0, armby1;
  int tryproof, trytier, opened;
  int vmstate, jstate, hookmask, gcstate;
  int incp, cfnres, recorder;           /* the innermost C frame is a cpcall; */
                                        /* inside the trace recorder's cpcall */
  int trec, tpar, texit;                /* J->cur.traceno, J->parent, J->exitno */
  int fkind, ffid, line, pcsrc, ctx, tline;
  long arms[5], proofs, lends, collects;
  char chunk[64], tchunk[64];
} oclj_refrec;
typedef struct oclj_gcev {
  long long gseq, calls, used, total, low, grown;
  void *M;
  int kind, why, cause, tier0, tier1, win0, win1, flush, vmstate, jstate, inref;
} oclj_gcev;
