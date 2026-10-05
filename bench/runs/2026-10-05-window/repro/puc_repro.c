/* puc_repro.c -- the same probe (probe2.lua) on STOCK PUC Lua 5.2.4
 * (JNLua-Natives/lua/src, unmodified, built -DLUA_COMPAT_ALL as its Makefile
 * does), under jnlua's l_alloc_checked rule (OC-JNLua/native/src/jnlua.c:251-288):
 * refuse a growth when total - used < delta.  PUC's luaM_realloc_ then runs
 * luaC_fullgc(L, 1) and retries (lmem.c:84-90): the "stock" side.
 *
 * usage: puc_repro probe.lua shapes off_from off_to off_step capk paint hb control [junk] [batch]
 * Same TSV columns as lj_repro where they apply; delta/ref_used are the LAST
 * refused request (the one after which luaD_throw ran) and the used figure
 * then -- AFTER the emergency collection, i.e. the live set plus the frame.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static long long P_total = 0, P_used = 0, P_refusals = 0, P_lastdelta = -1, P_lastused = -1;
static void *puc_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  long long delta;
  (void)ud;
  if (nsize == 0) {
    if (ptr) { free(ptr); P_used -= (long long)osize; }
    return NULL;
  }
  delta = ptr ? (long long)nsize - (long long)osize : (long long)nsize;
  if (P_total <= 0 || delta <= 0 || P_total - P_used >= delta) {
    void *p = realloc(ptr, nsize);
    if (p) P_used += delta;
    return p;
  }
  P_refusals++; P_lastdelta = delta; P_lastused = P_used;
  return NULL;
}

typedef struct { int code; long long count, used, batches, delta, rused, refusals; } Ev;
#define MAXEV 64
static Ev EV[MAXEV];
static int nev = 0, nref = 0, measure_at = -1;
static int c_rec(lua_State *L) {
  int code = (int)lua_tointeger(L, 1), m = 0;
  Ev *e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
  e->code = code; e->count = (long long)lua_tointeger(L, 2); e->batches = (long long)lua_tointeger(L, 3);
  e->used = P_used; e->delta = P_lastdelta; e->rused = P_lastused; e->refusals = P_refusals;
  if (code >= 1 && code <= 7 && code != 6) {
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

int main(int argc, char **argv) {
  const char *shapes_all[] = {"record", "array", "string", "closure"};
  const char *shapes[4]; int nshape = 0, si;
  char *src; size_t srclen;
  long off, off0, off1, offs, capk; int paint, hb, control, junk = 24, batch = 100;
  if (argc < 10) { fprintf(stderr, "usage: see the header\n"); return 2; }
  src = slurp(argv[1], &srclen);
  if (!src) { fprintf(stderr, "no %s\n", argv[1]); return 2; }
  if (strcmp(argv[2], "all") == 0) { for (si = 0; si < 4; si++) shapes[nshape++] = shapes_all[si]; }
  else { char *p = strtok(argv[2], ","); while (p && nshape < 4) { shapes[nshape++] = p; p = strtok(NULL, ","); } }
  off0 = atol(argv[3]); off1 = atol(argv[4]); offs = atol(argv[5]); capk = atol(argv[6]);
  paint = atoi(argv[7]); hb = atoi(argv[8]); control = atoi(argv[9]);
  if (argc > 10) junk = atoi(argv[10]);
  if (argc > 11) batch = atoi(argv[11]);
  setvbuf(stdout, NULL, _IOFBF, 1 << 16);
  printf("shape\toff\tbase\tcap\tstatus\tterm\tcount\tevents\tused_at\tlive\tdelta\tref_used\trefusals\ttb\n");
  for (si = 0; si < nshape; si++) {
    for (off = off0; off <= off1; off += offs) {
      lua_State *L;
      long long base, cap, live = -1;
      int st, i, ti = -1;
      char evs[512];
      Ev *T = NULL;
      P_total = 0; P_used = 0; P_refusals = 0; P_lastdelta = -1; P_lastused = -1;
      L = lua_newstate(puc_alloc, NULL);
      if (!L) { printf("NOSTATE\n"); return 1; }
      luaL_openlibs(L);
      lua_pushcfunction(L, c_rec); lua_setglobal(L, "__rec");
      lua_pushstring(L, shapes[si]); lua_setglobal(L, "P_SHAPE");
      lua_pushinteger(L, batch); lua_setglobal(L, "P_BATCH");
      lua_pushinteger(L, junk); lua_setglobal(L, "P_JUNK");
      lua_pushinteger(L, 20000); lua_setglobal(L, "P_MAXRES");
      lua_pushinteger(L, 0); lua_setglobal(L, "P_ARM");
      lua_pushinteger(L, paint); lua_setglobal(L, "P_PAINT");
      lua_pushinteger(L, hb); lua_setglobal(L, "P_HB");
      lua_pushinteger(L, control); lua_setglobal(L, "P_CONTROL");
      lua_pushinteger(L, -1); lua_setglobal(L, "P_MEAS_B");
      lua_pushinteger(L, 0); lua_setglobal(L, "P_MEAS_SITE");
      if (luaL_loadbuffer(L, src, srclen, "=probe") != 0 || lua_pcall(L, 0, 0, 0) != 0) {
        printf("SETUP FAILED: %s\n", lua_tostring(L, -1)); return 1;
      }
      lua_settop(L, 0);
      lua_gc(L, LUA_GCCOLLECT, 0);
      lua_gc(L, LUA_GCCOLLECT, 0);
      lua_getglobal(L, "__kernel");
      base = P_used;
      cap = base + capk * 1024 + off;
      nev = 0; nref = 0;
      P_total = cap;
      st = lua_pcall(L, 0, 0, 0);
      if (st != 0) {
        Ev *e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
        e->code = 5; e->count = -1; e->batches = -1; e->used = P_used; e->delta = P_lastdelta; e->rused = P_lastused; e->refusals = P_refusals;
        lua_settop(L, 0);
        lua_gc(L, LUA_GCCOLLECT, 0); lua_gc(L, LUA_GCCOLLECT, 0);
        e = &EV[nev < MAXEV ? nev++ : MAXEV - 1];
        e->code = 20; e->count = -1; e->batches = -1; e->used = P_used; e->delta = P_lastdelta; e->rused = P_lastused; e->refusals = P_refusals;
      }
      lua_settop(L, 0);
      P_total = 0;
      evs[0] = 0;
      for (i = 0; i < nev; i++) {
        char one[48];
        sprintf(one, "%s%d", i ? "," : "", EV[i].code);
        if (strlen(evs) + strlen(one) < sizeof evs - 1) strcat(evs, one);
        if (EV[i].code == 20) live = EV[i].used;
      }
      for (i = 0; i < nev; i++) if (EV[i].code == 2 || EV[i].code == 4 || EV[i].code == 5 || EV[i].code == 7) { ti = i; break; }
      if (ti < 0) for (i = 0; i < nev; i++) if (EV[i].code == 1) { ti = i; break; }
      if (ti < 0) for (i = 0; i < nev; i++) if (EV[i].code == 0) { ti = i; break; }
      if (ti >= 0) T = &EV[ti];
      printf("%s\t%ld\t%lld\t%lld\t%d\t%d\t%lld\t%s\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\n",
             shapes[si], off, base, cap, st, T ? T->code : -1, T ? T->count : -1, evs, T ? T->used : -1, live,
             T ? T->delta : -1, T ? T->rused : -1, T ? T->refusals : -1, T ? T->batches : -1);
      lua_close(L);
    }
    fflush(stdout);
  }
  return 0;
}
