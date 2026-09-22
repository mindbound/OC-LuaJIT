/* penalty_test.c -- the trace-abort penalty cache must not outlive a prototype.
 *
 * THE DEFECT (2026-09-22, the flush-cost bisect; established standalone by two
 * analysts before this test existed).  LuaJIT's J->penalty[64] is keyed by the
 * raw ADDRESS of a loop-head bytecode and is scrubbed by exactly one thing,
 * lj_trace_flushall.  lj_func_freeproto is a bare lj_mem_free.  A machine's
 * heap is CRT realloc/free (native/lj52shim.c lj52_alloc), which hands a dead
 * prototype's block straight back to the next same-size load(), so a FRESH
 * prototype inherits the DEAD one's penalty slots; its own ordinary
 * nested-loop aborts (LLEAVE / LINNER) double them; on the 8th-11th re-load at
 * that address blacklist_pc rewrites its loop heads to ILOOP/IFORL on their
 * first abort, and the program runs interpreted (~6x slower) forever after,
 * on every re-load.  That is any player program re-run from source: a shell
 * loop, a REPL, an OS re-loading a program, the harness's encore.
 *
 * THE CURE is native/luajit/patch-penalty-scrub.sh, applied by build-native.sh
 * to the build copy of lj_func.c: lj_func_freeproto NULLs every penalty slot
 * whose pc lies inside the dying prototype's bytecode.
 *
 * THIS HOST links the very libluajit.a build-native.sh produced, creates the
 * state on a CRT realloc/free allocator exactly as the shim does, and hands
 * penalty_test.lua a `penalty` module that reads J->penalty and friends
 * directly, so each check is an observation of the cache and the bytecode,
 * not an inference from timing alone:
 *
 *   P1  every re-load computes the published checksum (the chunk ran)
 *   P2  no re-load reads a blacklisted loop head (ILOOP/IFORL/IITERL)
 *   P3  no re-load is slower than 3x the first
 *   P4  THE MECHANISM: after a prototype dies and is collected, no penalty
 *       slot still points into its bytecode
 *   P5  POSITIVE CONTROL: blacklisting still works WITHIN a live prototype --
 *       a `while` loop whose recording always aborts (its body creates a
 *       closure; BC_FNEW is an unconditional NYI in lj_record.c, where a C
 *       call merely stitches) reads ILOOP after enough aborts, on the patched
 *       library as on the unpatched one
 *   P6  the same for a numeric `for` (FORL -> IFORL)
 *
 * FAIL-FIRST: against an UNPATCHED libluajit.a P2/P3/P4 fail (a head reads
 * ILOOP around the 8th-14th re-load and the run time jumps ~6x) while P1/P5/P6
 * pass; see run-penalty.sh's OCLJ_LJLIB for pointing it at another archive.
 *
 * Build: see run-penalty.sh next to this file.  Exit status 0 iff every check
 * passes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Internals, on purpose: the cache under test is not reachable any other way. */
#include "lj_obj.h"
#include "lj_jit.h"
#include "lj_dispatch.h"
#include "lj_bc.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static double now_ms(void) {
  static LARGE_INTEGER f;
  LARGE_INTEGER t;
  if (f.QuadPart == 0) QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)f.QuadPart;
}
#else
#include <time.h>
static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}
#endif

/* The machine's allocator: the branch lj52_alloc takes for every block once
 * the state is up.  luaL_newstate would use LuaJIT's own lj_alloc, whose
 * reuse pattern differs; the defect needs the libc one. */
static void *crt_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud; (void)osize;
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

static GCproto *checkproto(lua_State *L, int idx) {
  GCfunc *fn;
  luaL_checktype(L, idx, LUA_TFUNCTION);
  fn = funcV(L->base + (idx - 1));
  if (!isluafunc(fn)) luaL_error(L, "not a Lua function");
  return funcproto(fn);
}

/* penalty.bcbase(fn) -> base address of fn's bytecode (as a number), sizebc */
static int p_bcbase(lua_State *L) {
  GCproto *pt = checkproto(L, 1);
  lua_pushnumber(L, (lua_Number)(uintptr_t)proto_bc(pt));
  lua_pushinteger(L, (lua_Integer)pt->sizebc);
  return 2;
}

/* penalty.slots_in(base, sizebc) -> n, maxval
 * The penalty slots whose pc lies in [base, base + 4*sizebc): a RANGE rather
 * than a function, so the caller can ask about a prototype that no longer
 * exists -- which is the whole question. */
static int p_slots_in(lua_State *L) {
  jit_State *J = L2J(L);
  uintptr_t base = (uintptr_t)luaL_checknumber(L, 1);
  uintptr_t end = base + (uintptr_t)luaL_checkinteger(L, 2) * sizeof(BCIns);
  int i, n = 0, maxval = 0;
  for (i = 0; i < PENALTY_SLOTS; i++) {
    uintptr_t pc = (uintptr_t)mref(J->penalty[i].pc, const BCIns);
    if (pc >= base && pc < end) {
      n++;
      if (J->penalty[i].val > maxval) maxval = J->penalty[i].val;
    }
  }
  lua_pushinteger(L, n);
  lua_pushinteger(L, maxval);
  return 2;
}

/* penalty.slots() -> number of non-NULL slots in the whole cache */
static int p_slots(lua_State *L) {
  jit_State *J = L2J(L);
  int i, n = 0;
  for (i = 0; i < PENALTY_SLOTS; i++)
    if (mref(J->penalty[i].pc, const BCIns) != NULL) n++;
  lua_pushinteger(L, n);
  return 1;
}

/* penalty.live_traces() -> non-NULL J->trace[i], 1..sizetrace-1: the traces
 * that exist right now (what _OCLJ_JITSTATS's fifth value reports). */
static int p_live_traces(lua_State *L) {
  jit_State *J = L2J(L);
  MSize i, live = 0;
  for (i = 1; i < J->sizetrace; i++)
    if (gcref(J->trace[i]) != NULL) live++;
  lua_pushinteger(L, (lua_Integer)live);
  return 1;
}

/* penalty.clock() -> wall milliseconds, monotonic */
static int p_clock(lua_State *L) { lua_pushnumber(L, now_ms()); return 1; }

static const luaL_Reg p_funcs[] = {
  { "bcbase",      p_bcbase },
  { "slots_in",    p_slots_in },
  { "slots",       p_slots },
  { "live_traces", p_live_traces },
  { "clock",       p_clock },
  { NULL, NULL }
};

int main(int argc, char **argv) {
  lua_State *L;
  int i, status;
  if (argc < 2) {
    fprintf(stderr, "usage: penalty_test <penalty_test.lua> [args...]\n");
    return 2;
  }
  L = lua_newstate(crt_alloc, NULL);
  if (!L) { fprintf(stderr, "cannot create state\n"); return 2; }
  luaL_openlibs(L);
  luaL_register(L, "penalty", p_funcs);
  /* The opcode numbers, from the header the library was built with, so the
   * Lua side never hard-codes 80/86. */
#define BCCONST(name) lua_pushinteger(L, BC_##name); lua_setfield(L, -2, "BC_" #name)
  BCCONST(LOOP); BCCONST(ILOOP); BCCONST(JLOOP);
  BCCONST(FORL); BCCONST(IFORL); BCCONST(JFORL);
  BCCONST(ITERL); BCCONST(IITERL); BCCONST(JITERL);
#undef BCCONST
  lua_pop(L, 1);
  lua_newtable(L);
  for (i = 2; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - 1);
  }
  lua_setglobal(L, "arg");
  printf("penalty_test: alloc=crt realloc/free  jit=%s  PENALTY_SLOTS=%d MIN=%d MAX=%d\n",
         (L2J(L)->flags & JIT_F_ON) ? "on" : "OFF", PENALTY_SLOTS, PENALTY_MIN, PENALTY_MAX);
  status = luaL_dofile(L, argv[1]);
  if (status != 0) {
    fprintf(stderr, "penalty_test: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 2;
  }
  /* The script leaves its failure count on the stack. */
  status = (int)lua_tointeger(L, -1);
  lua_close(L);
  return status == 0 ? 0 : 1;
}
