/* traj.c -- the PUC-like rule on LuaJIT's own trajectory.  One UNCAPPED run
 * (cap 64 MB) of probe3.lua per shape, with a full collection at every marker
 * (the start of each batch iteration, the step's outside code, paint, the
 * dispatcher, the kernel) and the full allocator log of the repro's third
 * instrumented copy (mkfull.py).  Writes <out>.marks (seq class live) and
 * <out>.log (one delta per allocator call); model.py decides, for every cap,
 * where "refuse only when live + request > limit" would first refuse.
 *
 * usage: traj probe3.lua shape capk out
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
extern long long *oclj_log;
extern long long oclj_logcap, oclj_logn;
#include <stdint.h>
typedef struct { uint64_t u[4]; } PRNGStateX;
int __wrap_lj_prng_seed_secure(PRNGStateX *rs) {
  uint64_t x = 1 * 0x9E3779B97F4A7C15ULL + 0x632BE59BD9B4E019ULL;
  int i;
  for (i = 0; i < 4; i++) {
    uint64_t z = (x += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    rs->u[i] = (z ^ (z >> 31)) | (1ULL << 63);
  }
  return 1;
}
static FakeState WS;
static FILE *MK;
static int c_mark(lua_State *L) {
  fprintf(MK, "%lld\t%d\t%lld\n", oclj_logn, (int)lua_tointeger(L, 1), lj52_mem_used(L));
  return 0;
}
static int c_rec(lua_State *L) { (void)L; lua_pushboolean(L, 0); return 1; }
static char *slurp(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb"); char *b; long n;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
  b = (char *)malloc((size_t)n + 1); if (fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
  b[n] = 0; fclose(f); *len = (size_t)n; return b;
}
int main(int argc, char **argv) {
  char *src; size_t srclen; char fn[1024];
  lua_State *W; long long base, capk, i; int st; FILE *LG;
  if (argc < 5) return 2;
  src = slurp(argv[1], &srclen); capk = atol(argv[3]);
  W = luaL_newstate();
  memset(&WS, 0, sizeof WS);
  WS.total = 64 * 1024 * 1024;
  lua_setallocf(W, NULL, W);
  {
    void **ref = (void **)lua_newuserdata(W, sizeof(void *));
    *ref = &WS;
    lua_setfield(W, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
  }
  lj52_mem_settotal(W, WS.total);
  luaL_openlibs(W);
  (void)luaL_dostring(W, "jit.off()");
  lua_pushcfunction(W, c_rec); lua_setglobal(W, "__rec");
  lua_pushcfunction(W, c_mark); lua_setglobal(W, "__mark");
  lua_pushstring(W, argv[2]); lua_setglobal(W, "P_SHAPE");
  lua_pushinteger(W, 100); lua_setglobal(W, "P_BATCH");
  lua_pushinteger(W, 24); lua_setglobal(W, "P_JUNK");
  lua_pushinteger(W, 20000); lua_setglobal(W, "P_MAXRES");
  lua_pushinteger(W, 1); lua_setglobal(W, "P_ARM");
  lua_pushinteger(W, 1); lua_setglobal(W, "P_PAINT");
  lua_pushinteger(W, 0); lua_setglobal(W, "P_HB");
  lua_pushinteger(W, 0); lua_setglobal(W, "P_CONTROL");
  lua_pushinteger(W, -1); lua_setglobal(W, "P_MEAS_B");
  lua_pushinteger(W, 0); lua_setglobal(W, "P_MEAS_SITE");
  lua_pushinteger(W, 1); lua_setglobal(W, "P_MARK");
  lua_pushinteger(W, 0); lua_setglobal(W, "P_STOPAT");
  if (luaL_loadbuffer(W, src, srclen, "=probe") != 0 || lua_pcall(W, 0, 0, 0) != 0) { printf("SETUP FAILED %s\n", lua_tostring(W, -1)); return 1; }
  lua_settop(W, 0);
  lua_gc(W, LUA_GCCOLLECT, 0);
  lua_gc(W, LUA_GCCOLLECT, 0);
  base = lj52_mem_used(W);
  /* P_MARK was 1 at load */
  lua_pushinteger(W, (lua_Integer)(base + capk * 1024 + 65536 + 32768 + 65536)); lua_setglobal(W, "P_STOPAT");
  sprintf(fn, "%s.marks", argv[4]); MK = fopen(fn, "w");
  fprintf(MK, "#base\t%lld\n", base);
  oclj_logcap = 20000000; oclj_log = (long long *)malloc(sizeof(long long) * oclj_logcap); oclj_logn = 0;
  lua_getglobal(W, "__kernel");
  st = lua_pcall(W, 0, 0, 0);
  fprintf(MK, "#end\t%d\t%lld\n", st, oclj_logn);
  fclose(MK);
  sprintf(fn, "%s.log", argv[4]); LG = fopen(fn, "w");
  for (i = 0; i < oclj_logn; i++) fprintf(LG, "%lld\n", oclj_log[i]);
  fclose(LG);
  printf("%s base %lld calls %lld status %d\n", argv[2], base, oclj_logn, st);
  return 0;
}
