/* ===================================================================== */
/* OCLJ REFUSAL FORENSICS: the hooks (instrumented copy only).           */
/* ===================================================================== */
/* Everything here READS the record and the VM.  It writes only the oc_*
 * fields, the two static rings, and stderr.  Nothing allocates through the
 * Lua allocator, nothing calls the Lua API, and the frame walk is bounded
 * and checks each frame slot before it follows it.
 *
 * WHERE: the running thread is g->cur_L; its base is lj_err_mem's own
 * choice (g->jit_base while a trace runs, else L->base).  The current
 * frame's function gives fk (lua, c, ff with its ffid); the nearest Lua
 * frame gives at=chunk:line, its PC taken as lj_debug's debug_framepc takes
 * it (pcsrc 1: the C frame's saved PC, top frame; 2: the next frame's link;
 * 3: a continuation) -- not on a trace, where the saved PC is stale.  ctx
 * names the JIT context: "rec" = the recorder's own J->pt/J->pc (J->state
 * not idle), "trace" = the executing trace's start (vmstate >= 0).
 *
 * RECORDER: the refusal was raised inside the trace recorder's protected
 * call, whose error trace_abort drops (lj_trace.c), i.e. the program never
 * sees it.  Decided as: the innermost C frame is a cpcall frame
 * (lj_vm_cpcall: saved PC == L, negative nres), J->state is not idle, and
 * vmstate is neither C, GC nor EXIT.  vmstate alone is NOT enough: it stays
 * RECORD after lj_record_ins returns, while the interpreter executes the
 * instruction just recorded, and an allocation there reaches the program. */
#include "lj_frame.h"
#include "lj_debug.h"

#if !defined(LJ52_WD_WIN32)
extern char **environ;
#endif

static oclj_refrec oclj_ring[OCLJ_RING_N] __attribute__((used));
static long long   oclj_ringn __attribute__((used));
static oclj_gcev   oclj_gcring[OCLJ_GCRING_N] __attribute__((used));
static long long   oclj_gcringn __attribute__((used));
static long long   oclj_gseq;

/* The rings, for a test or a debugger: the refusal ring (OCLJ_RING_N
 * entries; *n records ever written, the newest at (*n - 1) % cap) and the
 * arm/proof ring.  Not JNIEXPORT: the DLL's export table is unchanged. */
const void *oclj_refring(long long *n, int *cap)
{
  *n = __atomic_load_n(&oclj_ringn, __ATOMIC_RELAXED);
  *cap = OCLJ_RING_N;
  return (const void *)oclj_ring;
}
const void *oclj_gcevring(long long *n, int *cap)
{
  *n = __atomic_load_n(&oclj_gcringn, __ATOMIC_RELAXED);
  *cap = OCLJ_GCRING_N;
  return (const void *)oclj_gcring;
}

static void oclj_ref_init(lj52_mem *M)
{
  char buf[16];
  int lv = 0, have = 0;
#if defined(LJ52_WD_WIN32)
  DWORD n = GetEnvironmentVariableA("OCLJ_REFLOG", buf, (DWORD)sizeof buf);
  if (n > 0 && n < sizeof buf) have = 1;
  else if (n >= sizeof buf) { have = 1; buf[0] = '1'; buf[1] = 0; }
#else
  char **e;
  for (e = environ; e != NULL && *e != NULL; e++) {
    if (strncmp(*e, "OCLJ_REFLOG=", 12) == 0 && (*e)[12] != 0) {
      size_t j;
      for (j = 0; j < sizeof buf - 1 && (*e)[12 + j] != 0; j++) buf[j] = (*e)[12 + j];
      buf[j] = 0;
      have = 1;
      break;
    }
  }
#endif
  if (have)
    lv = (buf[0] == '0' && buf[1] == 0) ? 0
       : (buf[0] == '2' && buf[1] == 0) ? 2
       : (buf[0] == '3' && buf[1] == 0) ? 3 : 1;
  M->oc_log = lv;
  if (lv > 0) {
    fprintf(stderr, "OCLJREFINIT| st=%p level=%d ring=%d gcring=%d\n",
            (void *)M, lv, OCLJ_RING_N, OCLJ_GCRING_N);
    fflush(stderr);
  }
}

static const char *oclj_vmname(int32_t st)
{
  static const char *const n[] = {"INTERP", "C", "GC", "EXIT", "RECORD", "OPT", "ASM"};
  if (st >= 0) return "TRACE";
  st = ~st;
  return (st >= 0 && st < 7) ? n[st] : "?";
}

static const char *oclj_jname(int js)
{
  switch (js) {
  case LJ_TRACE_IDLE: return "IDLE";
  case LJ_TRACE_ACTIVE: return "ACTIVE";
  case LJ_TRACE_RECORD: return "RECORD";
  case LJ_TRACE_RECORD_1ST: return "RECORD_1ST";
  case LJ_TRACE_START: return "START";
  case LJ_TRACE_END: return "END";
  case LJ_TRACE_ASM: return "ASM";
  case LJ_TRACE_ERR: return "ERR";
  default: return "?";
  }
}

static const char *oclj_fkname(int fk)
{
  switch (fk) {
  case -2: return "badframe";
  case -1: return "badbase";
  case 1: return "lua";
  case 2: return "c";
  case 3: return "ff";
  default: return "none";
  }
}

/* The chunkname's last cap-1 bytes, blanks and '|' made '_'.  Reads the
 * GCstr's own bytes; allocates nothing. */
static void oclj_chunk(char *out, size_t cap, GCproto *pt)
{
  GCstr *s;
  const char *p;
  size_t n, i, from, k = 0;
  out[0] = 0;
  if (pt == NULL) return;
  s = proto_chunkname(pt);
  if (s == NULL) return;
  p = strdata(s);
  n = (size_t)s->len;
  from = n > cap - 1 ? n - (cap - 1) : 0;
  for (i = from; i < n && k < cap - 1; i++) {
    unsigned char c = (unsigned char)p[i];
    out[k++] = (c <= 32 || c >= 127 || c == '|') ? '_' : (char)c;
  }
  out[k] = 0;
}

static void oclj_where(lua_State *L, global_State *g, oclj_refrec *r, int ontrace)
{
  TValue *stk, *base, *frame, *bot, *nextframe = NULL;
  int i;
  r->fkind = 0; r->ffid = -1; r->line = -1; r->pcsrc = 0; r->chunk[0] = 0;
  if (L == NULL) return;
  stk = tvref(L->stack);
  base = tvref(g->jit_base);
  if (base == NULL) base = L->base;
  if (base < stk + 1 + LJ_FR2 || base > stk + L->stacksize) { r->fkind = -1; return; }
  bot = stk + LJ_FR2;
  frame = base - 1;
  for (i = 0; i < 256 && frame > bot; i++) {
    GCfunc *fn;
#if LJ_FR2
    if (!tvisfunc(frame - 1)) { if (i == 0) r->fkind = -2; return; }
#endif
    fn = frame_func(frame);
    if (i == 0) {
      r->fkind = isluafunc(fn) ? 1 : fn->c.ffid > FF_C ? 3 : 2;
      r->ffid = fn->c.ffid;
    }
    if (isluafunc(fn)) {
      GCproto *pt = funcproto(fn);
      const BCIns *ins = NULL;
      if (nextframe == NULL) {
        void *cf = cframe_raw(L->cframe);
        if (!ontrace && cf != NULL && (char *)cframe_pc(cf) != (char *)cframe_L(cf)) {
          ins = cframe_pc(cf);
          r->pcsrc = 1;
        }
      } else if (frame_islua(nextframe)) {
        ins = frame_pc(nextframe);
        r->pcsrc = 2;
      } else if (frame_iscont(nextframe)) {
        ins = frame_contpc(nextframe);
        r->pcsrc = 3;
      }
      oclj_chunk(r->chunk, sizeof r->chunk, pt);
      if (ins != NULL) {
        BCPos pos = proto_bcpos(pt, ins) - 1;
        r->line = pos <= pt->sizebc ? (int)lj_debug_line(pt, pos) : -1;
      }
      return;
    }
    nextframe = frame;
    frame = frame_prev(frame);
  }
}

/* lj52_gc_credit without its one side effect (lj52_gc_reserve can move a
 * fresh record to the reserve tier): the same arithmetic, read only.  THE
 * RESERVE'S SIZE: in the reserve tier the credit is lj52_gc_rsvcredit's
 * (what the refusal that opened it set, clamped to [G/2, G]); a fresh
 * record past the burst top would be moved there with gc_rsv = G, so its
 * credit is G.  No credit under HOOK_VMEVENT, as in the shim. */
static long long oclj_credit(lj52_mem *M, global_State *g, long long total, long long used, int kernel)
{
  long long c;
  if (M->L == NULL || total <= 0) return 0;
  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) return 0;
  if (g->hookmask & HOOK_VMEVENT) return 0;
  c = lj52_gc_odmax(total);
  if (M->gc_odstate == LJ52_OD_RESERVE) c = lj52_gc_rsvcredit(M, c);
  else if (!(!M->gc_hyst && !M->gc_win && used > total + (lj52_gc_odmax(total) >> 1)))
    c >>= 1;
  if (kernel) c += LJ52_GC_KSLICE;
  return c;
}

/* THE RESERVE'S SIZE: one line per reserve a refusal sized (OCLJ_REFLOG),
 * from the sizing block of lj52_gc_refused, after gc_rsv is set and before
 * the tier is opened.  over = used - total, the heap past the cap the
 * refused request found (negative: a refusal under the cap by one big
 * request); top = the reserve tier's top as it will be read, through
 * lj52_gc_rsvcredit's clamp.  Reads only; prints only. */
static void oclj_rsv_note(lj52_mem *M, long long total, long long used)
{
  long long g = lj52_gc_odmax(total);
  if (M->oc_log <= 0) return;
  fprintf(stderr, "OCLJXP| fired=1 kind=rsv rsv=%lld used=%lld total=%lld over=%lld top=%lld G=%lld calls=%lld\n",
          M->gc_rsv, used, total, used - total, total + lj52_gc_rsvcredit(M, g), g, M->mem_calls);
  fflush(stderr);
}

static void oclj_ref_pre(lj52_mem *M, long long total, long long used, long long delta, int legacy)
{
  oclj_refrec *r = &M->oc_cur;
  global_State *g = M->L != NULL ? G(M->L) : NULL;
  memset(r, 0, sizeof *r);
  M->oc_inref = 1;
  M->oc_tryproof = 0;
  M->oc_trytier = -1;
  r->gseq = __atomic_add_fetch(&oclj_gseq, 1, __ATOMIC_RELAXED);
  r->seq = M->gc_refusals + 1;
  r->calls = M->mem_calls;
  r->M = (void *)M;
  r->legacy = legacy;
  r->delta = delta;
  r->used = used;
  r->total = total;
  r->G = total > 0 ? lj52_gc_odmax(total) : 0;
  r->tier0 = M->gc_odstate;
  r->rsv0 = M->gc_rsv;
  r->win0 = M->gc_win;
  r->hyst = M->gc_hyst;
  r->armed0 = M->gc_armed;
  r->armby0 = M->gc_armby;
  r->low = M->gc_low;
  r->grown = M->gc_grown;
  r->wd_depth = M->wd_depth;
  r->mainL = (void *)M->L;
  r->kby = M->wd_depth > 0 ? (void *)M->wd_by[0] : NULL;
  r->vmstate = 0x7fffffff;
  r->jstate = -1;
  r->trec = r->tpar = r->texit = -1;
  r->tline = -1;
  if (g != NULL) {
    lua_State *L = gco2th(gcref(g->cur_L));
    int ontrace = g->vmstate >= 0;
    r->curL = (void *)L;
    r->kthr = M->wd_depth > 0 && L == M->wd_by[0];
    r->mainthr = L == M->L;
    r->kernel = lj52_gc_kernel(M, g);
    r->credit = oclj_credit(M, g, total, used, r->kernel);
    r->top = total + r->credit;
    r->vmstate = g->vmstate;
    r->hookmask = g->hookmask;
    r->gcstate = g->gc.state;
    r->gctotal = (long long)g->gc.total;
    r->gcthresh = (long long)g->gc.threshold;
    if (L != NULL) {
      void *cf = cframe_raw(L->cframe);
      if (cf != NULL) {
        r->cfnres = cframe_nres(cf);
        r->incp = r->cfnres < 0 && (char *)cframe_pc(cf) == (char *)cframe_L(cf);
      }
    }
#if LJ_HASJIT
    {
      jit_State *J = G2J(g);
      r->jstate = J->state;
      if (J->state != LJ_TRACE_IDLE) {
        r->recorder = r->incp && g->vmstate < 0 && g->vmstate != ~LJ_VMST_C
                      && g->vmstate != ~LJ_VMST_GC && g->vmstate != ~LJ_VMST_EXIT;
        r->trec = (int)J->cur.traceno;
        r->tpar = (int)J->parent;
        r->texit = (int)J->exitno;
        r->ctx = 1;
        if (J->pt != NULL) {
          oclj_chunk(r->tchunk, sizeof r->tchunk, J->pt);
          if (J->pc != NULL) {
            BCPos pos = proto_bcpos(J->pt, J->pc);
            r->tline = pos <= J->pt->sizebc ? (int)lj_debug_line(J->pt, pos) : -1;
          }
        }
      } else if (ontrace && (MSize)g->vmstate < J->sizetrace) {
        GCtrace *T = (GCtrace *)gcref(J->trace[g->vmstate]);
        r->ctx = 2;
        if (T != NULL) {
          GCproto *pt = gco2pt(gcref(T->startpt));
          const BCIns *spc = mref(T->startpc, const BCIns);
          oclj_chunk(r->tchunk, sizeof r->tchunk, pt);
          if (pt != NULL && spc != NULL) {
            BCPos pos = proto_bcpos(pt, spc);
            r->tline = pos <= pt->sizebc ? (int)lj_debug_line(pt, pos) : -1;
          }
        }
      }
    }
#endif
    oclj_where(L, g, r, ontrace);
  }
}

static void oclj_ref_post(lj52_mem *M)
{
  oclj_refrec *r = &M->oc_cur;
  long long i;
  long long ceil;
  int k;
  r->tier1 = M->gc_odstate;
  r->rsv = M->gc_rsv;
  r->tier = r->total <= 0 ? 0
          : M->gc_odstate == LJ52_OD_RESERVE ? lj52_gc_rsvcredit(M, lj52_gc_odmax(r->total))
          : lj52_gc_odmax(r->total) >> 1;
  r->win1 = M->gc_win;
  r->armed1 = M->gc_armed;
  r->armby1 = M->gc_armby;
  r->tryproof = M->oc_tryproof;
  r->trytier = M->oc_trytier;
  r->opened = r->tier1 == LJ52_OD_RESERVE
              && (r->tier0 != LJ52_OD_RESERVE || (r->tryproof && r->trytier != LJ52_OD_RESERVE));
  for (k = 0; k < 5; k++) r->arms[k] = M->oc_arms[k];
  r->proofs = M->oc_proofs;
  r->lends = M->gc_lends;
  r->collects = M->gc_collects;
  M->oc_inref = 0;
  i = __atomic_fetch_add(&oclj_ringn, 1, __ATOMIC_RELAXED);
  oclj_ring[i & (OCLJ_RING_N - 1)] = *r;
  if (M->oc_log <= 0) return;
  ceil = r->kernel ? r->top : r->top + LJ52_GC_LEND;
  fprintf(stderr,
          "OCLJREF| gseq=%lld st=%p seq=%lld mode=%s delta=%lld used=%lld total=%lld G=%lld"
          " credit=%lld top=%lld ceil=%lld over=%lld rsv0=%lld rsv=%lld tier=%lld"
          " tier0=%d tier1=%d opened=%d tryproof=%d win0=%d win1=%d hyst=%d"
          " armed0=%d armby0=%d armed1=%d armby1=%d low=%lld grown=%lld"
          " kernel=%d wd=%d kthr=%d mainthr=%d curL=%p mainL=%p kby=%p"
          " vm=%s vmstate=%d jst=%s jstate=%d incp=%d cfnres=%d recorder=%d"
          " trec=%d tpar=%d texit=%d hook=%d gcst=%d gctotal=%lld gcthr=%lld"
          " fk=%s ffid=%d at=%s:%d pcsrc=%d ctx=%s cat=%s:%d"
          " calls=%lld arms=%ld/%ld/%ld/%ld/%ld proofs=%ld lends=%ld collects=%ld\n",
          r->gseq, r->M, r->seq, r->legacy ? "legacy" : "c", r->delta, r->used, r->total, r->G,
          r->credit, r->top, ceil, r->used + r->delta - r->top, r->rsv0, r->rsv, r->tier,
          r->tier0, r->tier1, r->opened, r->tryproof, r->win0, r->win1, r->hyst,
          r->armed0, r->armby0, r->armed1, r->armby1, r->low, r->grown,
          r->kernel, r->wd_depth, r->kthr, r->mainthr, r->curL, r->mainL, r->kby,
          oclj_vmname(r->vmstate), r->vmstate, oclj_jname(r->jstate), r->jstate,
          r->incp, r->cfnres, r->recorder,
          r->trec, r->tpar, r->texit, r->hookmask, r->gcstate, r->gctotal, r->gcthresh,
          oclj_fkname(r->fkind), r->ffid, r->chunk[0] ? r->chunk : "?", r->line, r->pcsrc,
          r->ctx == 1 ? "rec" : r->ctx == 2 ? "trace" : "-",
          r->tchunk[0] ? r->tchunk : "?", r->tline,
          r->calls, r->arms[0], r->arms[1], r->arms[2], r->arms[3], r->arms[4],
          r->proofs, r->lends, r->collects);
  fflush(stderr);
}

static void oclj_gc_note(lj52_mem *M, int kind, int why, int cause, long long total,
                         long long used, int tier0, int win0, long long grown)
{
  oclj_gcev e;
  global_State *g = M->L != NULL ? G(M->L) : NULL;
  long long i;
  e.gseq = __atomic_add_fetch(&oclj_gseq, 1, __ATOMIC_RELAXED);
  e.calls = M->mem_calls;
  e.used = used;
  e.total = total;
  e.low = M->gc_low;
  e.grown = grown;
  e.M = (void *)M;
  e.kind = kind;
  e.why = why;
  e.cause = cause;
  e.tier0 = tier0;
  e.tier1 = M->gc_odstate;
  e.win0 = win0;
  e.win1 = M->gc_win;
  e.flush = M->gc_flush_wanted;
  e.vmstate = g != NULL ? g->vmstate : 0;
#if LJ_HASJIT
  e.jstate = g != NULL ? (int)G2J(g)->state : -1;
#else
  e.jstate = -1;
#endif
  e.inref = M->oc_inref;
  i = __atomic_fetch_add(&oclj_gcringn, 1, __ATOMIC_RELAXED);
  oclj_gcring[i & (OCLJ_GCRING_N - 1)] = e;
  if (kind == 'P' && M->oc_log >= 2) {
    fprintf(stderr,
            "OCLJPRF| gseq=%lld st=%p proof=%ld used=%lld total=%lld low=%lld grown=%lld"
            " win0=%d win1=%d tier0=%d tier1=%d armby=%d flush=%d inref=%d vm=%s jst=%s calls=%lld\n",
            e.gseq, e.M, M->oc_proofs, e.used, e.total, e.low, e.grown,
            e.win0, e.win1, e.tier0, e.tier1, e.why, e.flush, e.inref,
            oclj_vmname(e.vmstate), oclj_jname(e.jstate), e.calls);
    fflush(stderr);
  } else if (kind == 'A' && M->oc_log >= 3) {
    static const char *const cn[] = {"gate", "wall", "window", "refusal", "flush"};
    fprintf(stderr,
            "OCLJARM| gseq=%lld st=%p why=%d cause=%s used=%lld total=%lld low=%lld"
            " tier=%d win=%d inref=%d vm=%s jst=%s calls=%lld\n",
            e.gseq, e.M, e.why, (cause >= 0 && cause < 5) ? cn[cause] : "?", e.used, e.total, e.low,
            e.tier1, e.win1, e.inref, oclj_vmname(e.vmstate), oclj_jname(e.jstate), e.calls);
    fflush(stderr);
  }
}

/* Called at the end of lj52_gc_arm.  The cause: the flush's arm; inside
 * lj52_gc_pressure (gc_busy) THE CADENCE's, gate below the cap or wall past
 * it; inside a refusal (between the pre and post hooks) the refusal's own;
 * otherwise THE WINDOW's lend, the one remaining caller. */
static void oclj_arm_note(lj52_mem *M, int why)
{
  int cause = why == LJ52_ARM_FLUSH ? 4
            : M->gc_busy ? (why == LJ52_ARM_GATE ? 0 : 1)
            : M->oc_inref ? 3 : 2;
  long long total = M->csync ? M->total : M->gc_seentotal;
  M->oc_arms[cause]++;
  oclj_gc_note(M, 'A', why, cause, total, M->used, M->gc_odstate, M->gc_win, M->gc_grown);
}

/* A proven cycle: called at the top of lj52_gc_pressure's proof branch
 * (before) and at its end (after). */
static void oclj_prf_pre(lj52_mem *M)
{
  M->oc_pwin = M->gc_win;
  M->oc_ptier = M->gc_odstate;
  M->oc_parmby = M->gc_armby;
  M->oc_pgrown = M->gc_grown;
}

static void oclj_prf_post(lj52_mem *M, long long total, long long used)
{
  M->oc_proofs++;
  if (M->oc_inref) {
    M->oc_tryproof = 1;
    M->oc_trytier = M->gc_odstate;
  }
  oclj_gc_note(M, 'P', M->oc_parmby, -1, total, used, M->oc_ptier, M->oc_pwin, M->oc_pgrown);
}

