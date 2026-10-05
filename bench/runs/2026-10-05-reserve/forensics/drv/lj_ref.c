/* lj_repro.c -- the capacity probe's residual ("a refusal at a credit tier's
 * top can land outside the program's handler"), hermetic and deterministic,
 * against a given lj52shim.o.  Built the way run-mem.sh builds mem_test.c
 * (-include lj52shim.h, the same objects), with no JVM.  -DINSTR links the
 * repro's instrumented copy of the shim and reads the refused request's delta
 * and the record's state at the refusal.
 *
 * usage: lj_repro probe.lua shapes off_from off_to off_step capk jit arm paint hb control measure_at [junk] [batch]
 *   shapes      comma list or "all"
 *   off_*       the phase sweep: cap = base + capk*1024 + off
 *   measure_at  -1: measure the live set at the terminal events 2/4/7 (and 5,
 *               from C); k > 0: measure at the k-th refusal event instead and stop
 * One TSV line per run on stdout.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#define JNLUA_JAVASTATE "jnlua.JavaState"
typedef struct { jint total; jint used; int gets; int sets; } FakeState;
static JNIEnv FAKE_ENV = NULL;
static JNIEnv *getthreadenv(void) { return &FAKE_ENV; }
static void getluamemory(JNIEnv *env, jobject obj, jint *total, jint *used) {
  FakeState *s = (FakeState *)obj; (void)env; s->gets++; *total = s->total; *used = s->used;
}
static void setluamemory(JNIEnv *env, jobject obj, jint used) {
  FakeState *s = (FakeState *)obj; (void)env; s->sets++; s->used = used;
}

#ifdef INSTR
extern long long oclj_ref_n, oclj_ref_delta, oclj_ref_used, oclj_ref_total;
extern long long oclj_ref_credit, oclj_ref_low, oclj_ref_gctotal, oclj_ref_thresh, oclj_ref_calls;
extern int oclj_ref_tier, oclj_ref_armed, oclj_ref_hyst, oclj_ref_kernel, oclj_ref_gcstate, oclj_ref_armby;
#endif

#ifdef FIXSEED
/* -Wl,--wrap=lj_prng_seed_secure: a FIXED seed per state (OCLJ_SEED, default
 * 1), so the string-hash seed (lj_str.c:367) -- and with it the incremental
 * collector's sweepstring progress -- is the same in every run. */
#include <stdint.h>
typedef struct { uint64_t u[4]; } PRNGStateX;
static uint64_t SEED = 1;
int __wrap_lj_prng_seed_secure(PRNGStateX *rs) {
  uint64_t x = SEED * 0x9E3779B97F4A7C15ULL + 0x632BE59BD9B4E019ULL;
  int i;
  for (i = 0; i < 4; i++) {
    uint64_t z = (x += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    rs->u[i] = (z ^ (z >> 31)) | (1ULL << 63);   /* conditioned: lj_prng.c:64-70 */
  }
  return 1;
}
#endif
#ifdef RING
typedef struct { long long delta, used, low, gctotal, thresh; long collects, arms; int armed, state, granted, hyst; } oclj_ringent;
extern oclj_ringent oclj_ring[256];
extern long long oclj_ringn;
static void ring_dump(int code, long long count, long long batches) {
  long long i, from = oclj_ringn > 48 ? oclj_ringn - 48 : 0;
  if (!getenv("OCLJ_RING")) return;
  fprintf(stderr, "-- ring at event %d (count %lld, batches %lld): seq delta used_before low armed hyst collects arms gc.state gc.total gc.threshold granted\n", code, count, batches);
  for (i = from; i < oclj_ringn; i++) {
    oclj_ringent *e = &oclj_ring[i & 255];
    fprintf(stderr, "%6lld %6lld %8lld %8lld %d %d %4ld %4ld %d %8lld %8lld %s\n", i, e->delta, e->used, e->low, e->armed, e->hyst,
            e->collects, e->arms, e->state, e->gctotal, e->thresh, e->granted ? "" : "REFUSED");
  }
}
#endif
static FakeState WS;
static int LEGACY = 0;
static int REFLOG = 0;
extern const void *oclj_refring(long long *n, int *cap);

static long long j_used(lua_State *L) { long long u = lj52_mem_used(L); return u >= 0 ? u : (long long)WS.used; }

static void bind_javastate(lua_State *L, void *obj) {
  void **ref = (void **)lua_newuserdata(L, sizeof(void *));
  *ref = obj;
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
}
static void clear_javastate(lua_State *L) {
  lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
}
static double statn(lua_State *L, const char *global, int n) {
  double v = -1;
  int top = lua_gettop(L);
  lua_getglobal(L, global);
  if (!lua_isfunction(L, -1) || lua_pcall(L, 0, LUA_MULTRET, 0) != 0) { lua_settop(L, top); return -1; }
  if (lua_gettop(L) - top >= n) {
    int idx = top + n;
    if (lua_isboolean(L, idx)) v = lua_toboolean(L, idx) ? 1 : 0;
    else if (lua_isnumber(L, idx)) v = lua_tonumber(L, idx);
  }
  lua_settop(L, top);
  return v;
}
#define GC_ARMS(L)       statn(L, "_OCLJ_GCSTATS", 1)
#define GC_COLLECTS(L)   statn(L, "_OCLJ_GCSTATS", 2)
#define GC_BAILOUTS(L)   statn(L, "_OCLJ_GCSTATS", 3)
#define GC_REFUSALS(L)   statn(L, "_OCLJ_GCSTATS", 4)
#define GC_ARMED(L)      statn(L, "_OCLJ_GCSTATS", 5)
#define WALL_OVERDRAFTS(L)  statn(L, "_OCLJ_WALLSTATS", 1)
#define WALL_ODPEAK(L)      statn(L, "_OCLJ_WALLSTATS", 2)
#define WALL_ODLIMIT(L)     statn(L, "_OCLJ_WALLSTATS", 5)

static int try_tables(lua_State *L, long n) {
  char buf[192];
  int s, top = lua_gettop(L);
  sprintf(buf, "local t = {} for i = 1, %ld do t[i] = {i, i} end __hold = t", n);
  s = luaL_loadstring(L, buf);
  if (s == 0) s = lua_pcall(L, 0, 0, 0);
  lua_settop(L, top);
  return s;
}
static double settle_gc(lua_State *L) {
  int i;
  for (i = 0; i < 4 && GC_ARMED(L) != 0; i++) { lua_gc(L, LUA_GCCOLLECT, 0); try_tables(L, 10); }
  return GC_ARMED(L);
}

/* ---- the event log ------------------------------------------------------ */
typedef struct {
  int code; long long count; long long used; long long batches;
  long long ref_n, delta, rused, rtotal, credit, low, gctotal, thresh;
  int tier, armed, hyst, kernel, gcstate, armby;
} Ev;
#define MAXEV 64
static Ev EV[MAXEV];
static int nev = 0, nref = 0, measure_at = -1;

static void fill_ref(Ev *e) {
#ifdef INSTR
  e->ref_n = oclj_ref_n; e->delta = oclj_ref_delta; e->rused = oclj_ref_used; e->rtotal = oclj_ref_total;
  e->credit = oclj_ref_credit; e->low = oclj_ref_low; e->gctotal = oclj_ref_gctotal; e->thresh = oclj_ref_thresh;
  e->tier = oclj_ref_tier; e->armed = oclj_ref_armed; e->hyst = oclj_ref_hyst; e->kernel = oclj_ref_kernel;
  e->gcstate = oclj_ref_gcstate; e->armby = oclj_ref_armby;
#else
  e->ref_n = e->delta = e->rused = e->rtotal = e->credit = e->low = e->gctotal = e->thresh = -1;
  e->tier = e->armed = e->hyst = e->kernel = e->gcstate = e->armby = -1;
#endif
}

/* __rec(code, count): allocates nothing (lua_pushboolean). */
static int c_rec(lua_State *L) {
  int code = (int)lua_tointeger(L, 1), m = 0;
  Ev *e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
  e->code = code; e->count = (long long)lua_tointeger(L, 2); e->used = j_used(L); e->batches = (long long)lua_tointeger(L, 3);
  fill_ref(e);
  if (REFLOG) { fprintf(stderr, "OCLJEV| code=%d count=%lld batches=%lld used=%lld\n", code, e->count, e->batches, e->used); fflush(stderr); }
  if (code >= 1 && code <= 7 && code != 6) {
#ifdef RING
    ring_dump(code, e->count, e->batches);
#endif
    nref++;
    if (measure_at > 0) m = (nref == measure_at);
    else if (measure_at < 0) m = (code == 2 || code == 4 || code == 7);
  }
  lua_pushboolean(L, m);
  return 1;
}

static char *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb"); char *b; long n;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
  b = (char *)malloc((size_t)n + 1); if (fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
  b[n] = 0; fclose(f); *len = (size_t)n; return b;
}

static long long odmax(long long total) {
  long long g = total >> 4;
  return g < 32 * 1024 ? 32 * 1024 : g > 512 * 1024 ? 512 * 1024 : g;
}

int main(int argc, char **argv) {
  const char *shapes_all[] = {"record", "array", "string", "closure"};
  const char *shapes[4]; int nshape = 0, si;
  char *src; size_t srclen;
  long off, off0, off1, offs, capk; int jit, arm, paint, hb, control, junk = 24, batch = 100, meas_b = -1, meas_site = 0;
  if (argc < 13) { fprintf(stderr, "usage: see the header\n"); return 2; }
  src = slurp(argv[1], &srclen);
  if (!src) { fprintf(stderr, "no %s\n", argv[1]); return 2; }
  if (strcmp(argv[2], "all") == 0) { for (si = 0; si < 4; si++) shapes[nshape++] = shapes_all[si]; }
  else {
    char *p = strtok(argv[2], ",");
    while (p && nshape < 4) { shapes[nshape++] = p; p = strtok(NULL, ","); }
  }
  off0 = atol(argv[3]); off1 = atol(argv[4]); offs = atol(argv[5]); capk = atol(argv[6]);
  jit = atoi(argv[7]); arm = atoi(argv[8]); paint = atoi(argv[9]); hb = atoi(argv[10]); control = atoi(argv[11]);
  measure_at = atoi(argv[12]);
  if (argc > 13) junk = atoi(argv[13]);
  if (argc > 14) batch = atoi(argv[14]);
  if (argc > 15) meas_b = atoi(argv[15]);
  if (argc > 16) meas_site = atoi(argv[16]);
#ifdef FIXSEED
  if (getenv("OCLJ_SEED")) SEED = (uint64_t)strtoull(getenv("OCLJ_SEED"), NULL, 10);
#endif
  if (getenv("OCLJ_LEGACY")) LEGACY = atoi(getenv("OCLJ_LEGACY"));
  if (getenv("OCLJ_REFLOG")) REFLOG = 1;
  setvbuf(stdout, NULL, _IOFBF, 1 << 16);
  printf("shape\toff\tbase\tcap\tG\tstatus\tterm\tcount\tevents\tused_at\tlive\tdelta\tref_used\tref_total\tcredit\ttop\ttier\tarmed\tarmby\thyst\tlow\tkernel\tgcstate\trefusals\tcollects\tarms\tbailouts\todpeak\tcovered_top\tcovered_cap\ttb\tlive_site\n");
  for (si = 0; si < nshape; si++) {
    for (off = off0; off <= off1; off += offs) {
      lua_State *W = luaL_newstate();
      long long base, cap, live = -1, used_at = -1, live_site = -1;
      int st, i, term = -1, ti = -1;
      char evs[512];
      Ev *T = NULL;
      if (!W) { printf("NOSTATE\n"); return 1; }
      memset(&WS, 0, sizeof WS);
      WS.total = 64 * 1024 * 1024;
      lua_setallocf(W, NULL, W);
      bind_javastate(W, (void *)&WS);
      WS.total = 64 * 1024 * 1024; if (!LEGACY) lj52_mem_settotal(W, WS.total);
      luaL_openlibs(W);
      lua_pushliteral(W, "_OCLJ_WALLSTATS");
      lua_setfield(W, LUA_REGISTRYINDEX, "__wallname");
      if (!jit) { (void)luaL_dostring(W, "jit.off()"); }
      lua_pushcfunction(W, c_rec); lua_setglobal(W, "__rec");
      lua_pushstring(W, shapes[si]); lua_setglobal(W, "P_SHAPE");
      lua_pushinteger(W, batch); lua_setglobal(W, "P_BATCH");
      lua_pushinteger(W, junk); lua_setglobal(W, "P_JUNK");
      lua_pushinteger(W, 20000); lua_setglobal(W, "P_MAXRES");
      lua_pushinteger(W, arm); lua_setglobal(W, "P_ARM");
      lua_pushinteger(W, paint); lua_setglobal(W, "P_PAINT");
      lua_pushinteger(W, hb); lua_setglobal(W, "P_HB");
      lua_pushinteger(W, control); lua_setglobal(W, "P_CONTROL");
      lua_pushinteger(W, meas_b); lua_setglobal(W, "P_MEAS_B");
      lua_pushinteger(W, meas_site); lua_setglobal(W, "P_MEAS_SITE");
      if (luaL_loadbuffer(W, src, srclen, "=probe") != 0 || lua_pcall(W, 0, 0, 0) != 0) {
        printf("SETUP FAILED: %s\n", lua_tostring(W, -1)); return 1;
      }
      lua_settop(W, 0);
      lua_gc(W, LUA_GCCOLLECT, 0);
      lua_gc(W, LUA_GCCOLLECT, 0);
      settle_gc(W);
      lua_getglobal(W, "__kernel");     /* on the stack while there is room */
      base = j_used(W);
      cap = base + capk * 1024 + off;
      nev = 0; nref = 0;
      WS.total = (jint)cap; if (!LEGACY) lj52_mem_settotal(W, cap);
      if (REFLOG) { fprintf(stderr, "OCLJRUN| shape=%s off=%ld base=%lld cap=%lld\n", shapes[si], off, base, cap); fflush(stderr); }
      st = lua_pcall(W, 0, 0, 0);
      if (st != 0) {                    /* the kernel itself was refused: code 5 */
        Ev *e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
        e->code = 5; e->count = -1; e->batches = -1; e->used = j_used(W); fill_ref(e);
        if (REFLOG) { fprintf(stderr, "OCLJEV| code=5 count=-1 batches=-1 used=%lld\n", e->used); fflush(stderr); }
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0); lua_gc(W, LUA_GCCOLLECT, 0);
        e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
        e->code = 20; e->count = -1; e->batches = -1; e->used = j_used(W); fill_ref(e);
      }
      lua_settop(W, 0);
      WS.total = 64 * 1024 * 1024; if (!LEGACY) lj52_mem_settotal(W, WS.total);
      /* the terminal event: the last refusal event (1,2,3,4,5,7) before a measure or the end */
      evs[0] = 0;
      for (i = 0; i < nev; i++) {
        char one[48];
        sprintf(one, "%s%d", i ? "," : "", EV[i].code);
        if (strlen(evs) + strlen(one) < sizeof evs - 1) strcat(evs, one);
        if (EV[i].code == 20) live = EV[i].used;
        if (EV[i].code == 21) live_site = EV[i].used;
      }
      /* terminal: code 2/4/5/7 if present (they end the run), else 6 (done) or the measured event */
      for (i = 0; i < nev; i++) if (EV[i].code == 2 || EV[i].code == 4 || EV[i].code == 5 || EV[i].code == 7) { ti = i; break; }
      if (ti < 0 && measure_at > 0) {
        int k = 0;
        for (i = 0; i < nev; i++) if (EV[i].code >= 1 && EV[i].code <= 7 && EV[i].code != 6) { if (++k == measure_at) { ti = i; break; } }
      }
      if (ti < 0) for (i = 0; i < nev; i++) if (EV[i].code == 1) { ti = i; break; }
      if (ti < 0) for (i = 0; i < nev; i++) if (EV[i].code == 0) { ti = i; break; }
      if (ti >= 0) { T = &EV[ti]; term = T->code; used_at = T->used; }
      {
        long long top = T && T->rtotal >= 0 ? T->rtotal + T->credit : -1;
        int ctop = (T && live >= 0 && T->delta >= 0) ? (live + T->delta <= top) : -1;
        int ccap = (T && live >= 0 && T->delta >= 0) ? (live + T->delta <= T->rtotal) : -1;
        printf("%s\t%ld\t%lld\t%lld\t%lld\t%d\t%d\t%lld\t%s\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\t%d\t%d\t%d\t%d\t%lld\t%d\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%d\t%d\t%lld\t%lld\n",
               shapes[si], off, base, cap, odmax(cap), st, term, T ? T->count : -1, evs, used_at, live,
               T ? T->delta : -1, T ? T->rused : -1, T ? T->rtotal : -1, T ? T->credit : -1, top,
               T ? T->tier : -1, T ? T->armed : -1, T ? T->armby : -1, T ? T->hyst : -1, T ? T->low : -1,
               T ? T->kernel : -1, T ? T->gcstate : -1,
               GC_REFUSALS(W), GC_COLLECTS(W), GC_ARMS(W), GC_BAILOUTS(W), WALL_ODPEAK(W), ctop, ccap, T ? T->batches : -1, live_site);
      }
      if (getenv("OCLJ_MODEDBG")) fprintf(stderr, "mode: legacy=%d jni_gets=%d jni_sets=%d csync=%.0f\n", LEGACY, WS.gets, WS.sets, statn(W, "_OCLJ_GCSTATS", 17));
      if (REFLOG) { long long rn; int rc; (void)oclj_refring(&rn, &rc); fprintf(stderr, "OCLJRING| n=%lld cap=%d\n", rn, rc); fflush(stderr); }
      clear_javastate(W);
      lua_close(W);
    }
    fflush(stdout);
  }
  return 0;
}
