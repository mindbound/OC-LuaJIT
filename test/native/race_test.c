/* race_test.c -- the cross-thread hookmask race, driven hard enough to see.
 *
 * WHY THIS EXISTS.  The watchdog installs a count=1 hook from a timer thread.
 * g->hookmask is ONE byte carrying both the event bits and LuaJIT's own state
 * bits -- HOOK_ACTIVE while a hook is running above all -- and the Lua thread
 * read-modify-writes it constantly (hook_enter/hook_leave around every hook
 * call, lj_obj.h; lj_err.c:155 and :185; lj_gc.c around finalisers).  If the
 * timer thread ALSO does a read-modify-write -- which is what lua_sethook is
 * (lj_dispatch.c:345, `hookmask = (hookmask & ~HOOK_EVENTMASK) | mask`) -- its
 * stale byte can land last and resurrect a HOOK_ACTIVE the Lua thread had just
 * cleared.  A hook LuaJIT believes is already running is a hook that never
 * runs again: vm_inshook skips it, callhook refuses it, and every later
 * lua_sethook preserves the high bits, so nothing in the shim can undo it.
 * The machine is then silently undefended for the rest of its life.
 *
 * That is not theoretical.  An adversarial review reproduced it on the shipped
 * build: about one wedge per 3000 re-fires with a realistic hook body, every
 * one with the same fingerprint -- hookmask 0x18 (HOOK_ACTIVE|MASKCOUNT), zero
 * hook calls afterwards, and a coroutine dying with an error (the lj_err.c:155
 * hook_leave) reviving it.  A 0.5 s grace is ~10 re-fires, so roughly 0.3% of
 * pcall-swallowing deadline hits would end in a wedged machine.
 *
 * THE FIX, AND WHY THIS TEST IS THE ONLY THING THAT CAN CHECK IT.  The timer
 * thread no longer calls lua_sethook: lj52_wd_inject stores hookf and
 * hookcount and then ORs the single count bit into hookmask ATOMICALLY, which
 * can neither resurrect a cleared bit nor clear a set one.  A 1-in-3000 event
 * is invisible to wd_test's W13 (~20 re-fires) and to the smoke test; only a
 * probe that drives the race at thousands of re-fires per second can tell the
 * two injections apart.  So this test runs BOTH:
 *
 *   sethook  the old injection.  MUST wedge -- if it does not, the probe has
 *            no teeth and the inject result below proves nothing.
 *   inject   the current one.  MUST NOT wedge, over at least as many re-fires.
 *
 * Exit 0 iff both hold.  Build: see run-race.sh next to this file.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "lj_obj.h"
#include "lj_dispatch.h"

static lua_State *GL;
static volatile LONG g_stop = 0;
static volatile LONG g_refires = 0;
static double g_period_ms = 0.1;
static double g_burn_us = 0.0;
static int g_inject = 0;                 /* 0 = lua_sethook, 1 = atomic OR */

static double now_ms(void) {
  static LARGE_INTEGER f;
  LARGE_INTEGER t;
  if (!f.QuadPart) QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)f.QuadPart;
}

/* Same shape as lj52_wd_hook: call a Lua function. */
static void chook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  lua_getglobal(L, "HOOKFN");
  if (lua_isfunction(L, -1)) lua_call(L, 0, 0); else lua_pop(L, 1);
}

/* The two injections under test, byte for byte what each version does. */
static void inject_sethook(void) {
  lua_sethook(GL, chook, LUA_MASKCOUNT, 1);
}
static void inject_atomic(void) {
  global_State *g = G(GL);
  g->hookf = chook;
  g->hookcount = g->hookcstart = 1;
  __atomic_fetch_or(&g->hookmask, (uint8_t)LUA_MASKCOUNT, __ATOMIC_SEQ_CST);
  lj_dispatch_update(g, 0);
}

static DWORD WINAPI refire(LPVOID p) {
  (void)p;
  while (!g_stop) {
    if (g_inject) inject_atomic(); else inject_sethook();
    InterlockedIncrement(&g_refires);
    if (g_period_ms >= 1.0) Sleep((DWORD)g_period_ms);
    else { double t = now_ms(); while (now_ms() - t < g_period_ms) YieldProcessor(); }
  }
  return 0;
}

static int l_burn(lua_State *L) {
  double t = now_ms();
  while ((now_ms() - t) * 1000.0 < g_burn_us) ;
  lua_pushnumber(L, t);
  return 1;
}
static int l_now(lua_State *L) { lua_pushnumber(L, now_ms()); return 1; }

static int run(lua_State *L, const char *code) {
  if (luaL_loadstring(L, code) != 0) { printf("  LOAD ERROR: %s\n", lua_tostring(L, -1)); return -1; }
  return lua_pcall(L, 0, 0, 0);
}

/* The Lua side reproduces the state the machine is in for the whole 0.5 s
 * grace after a deadline fire: a count=1 hook streaming on every instruction
 * while sandbox code spins in pcall -- `while true do pcall(...) end` being
 * exactly the shape the deadline exists to stop. */
static const char *PRELUDE =
  "HOOKCALLS = 0\n"
  "HOOKFN = function() HOOKCALLS = HOOKCALLS + 1 burn() end\n"
  "SPIN = function(max_ms)\n"
  "  local t0 = now()\n"
  "  while now() - t0 < max_ms do\n"
  "    local before = HOOKCALLS\n"
  "    for i = 1, 2000 do pcall(error, 0) end\n"
  "    if HOOKCALLS == before then return 'dead', now() - t0 end\n"
  "  end\n"
  "  return 'alive', now() - t0\n"
  "end\n"
  "PROBE = function()\n"
  "  local before = HOOKCALLS\n"
  "  local x = 0 for i = 1, 200 do x = x + i end\n"
  "  return HOOKCALLS - before\n"
  "end\n"
  "HEAL = function()\n"
  "  local co = coroutine.create(function() error('x') end)\n"
  "  coroutine.resume(co)\n"
  "end\n";

/* Returns the number of trials that wedged; adds re-fires to *refires. */
static int run_mode(lua_State *L, const char *label, int inject,
                    int trials, double max_s, long *refires_total) {
  int t, wedged = 0;
  printf("  --- %s ---\n", label);
  for (t = 1; t <= trials; t++) {
    HANDLE th;
    char code[128];
    const char *r;
    double dt;
    long refires;
    int mask_after, probe_calls;

    g_inject = inject;
    run(L, "HOOKCALLS = 0 debug.sethook(HOOKFN, '', 1)");
    g_stop = 0; g_refires = 0;
    th = CreateThread(NULL, 0, refire, NULL, 0, NULL);
    sprintf(code, "R, T = SPIN(%f)", max_s * 1000.0);
    run(L, code);
    InterlockedExchange(&g_stop, 1);
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    refires = g_refires;
    *refires_total += refires;

    lua_getglobal(L, "R"); r = lua_tostring(L, -1);
    lua_getglobal(L, "T"); dt = lua_tonumber(L, -1);
    lua_settop(L, 0);
    mask_after = (int)G(L)->hookmask;
    lua_getglobal(L, "PROBE"); lua_call(L, 0, 1);
    probe_calls = (int)lua_tointeger(L, -1);
    lua_settop(L, 0);

    printf("    trial %d: %-5s after %7.1f ms, refires=%-7ld hookmask=0x%02x "
           "(ACTIVE=%d COUNT=%d) hook calls after=%d\n",
           t, r ? r : "?", dt, refires, mask_after,
           !!(mask_after & HOOK_ACTIVE), !!(mask_after & LUA_MASKCOUNT), probe_calls);
    if (r && strcmp(r, "dead") == 0) {
      int healed, probe2;
      wedged++;
      /* The fingerprint: a coroutine dying with an error runs the one
       * hook_leave that can still reach a wedged mask (lj_err.c:155). */
      run(L, "HEAL()");
      healed = (int)G(L)->hookmask;
      lua_getglobal(L, "PROBE"); lua_call(L, 0, 1);
      probe2 = (int)lua_tointeger(L, -1);
      lua_settop(L, 0);
      printf("      WEDGED -- after a coroutine dies with an error: "
             "hookmask=0x%02x, hook calls=%d\n", healed, probe2);
    }
    lua_sethook(L, NULL, 0, 0);
    G(L)->hookmask &= (uint8_t)~HOOK_ACTIVE;    /* clean slate for the next trial */
  }
  return wedged;
}

int main(int argc, char **argv) {
  lua_State *L;
  int trials = argc > 1 ? atoi(argv[1]) : 4;
  double max_s = argc > 2 ? atof(argv[2]) : 3.0;
  int wedge_old, wedge_new, failures = 0;
  long refires_old = 0, refires_new = 0;

  g_period_ms = argc > 3 ? atof(argv[3]) : 0.1;
  g_burn_us = argc > 4 ? atof(argv[4]) : 0.0;
  setvbuf(stdout, NULL, _IONBF, 0);
  printf("race_test -- cross-thread hookmask injection, %d trials x %.1f s, "
         "period %.3f ms, burn %.1f us\n", trials, max_s, g_period_ms, g_burn_us);

  L = luaL_newstate();                    /* -> lj52_newstate */
  GL = L;
  if (!L) { printf("  FAIL  luaL_newstate returned NULL\n"); return 1; }
  luaL_openlibs(L);
  lua_pushcfunction(L, l_burn); lua_setglobal(L, "burn");
  lua_pushcfunction(L, l_now); lua_setglobal(L, "now");
  if (run(L, PRELUDE) != 0) { printf("  FAIL  prelude: %s\n", lua_tostring(L, -1)); return 1; }

  wedge_old = run_mode(L, "sethook  (the OLD injection -- must wedge)", 0,
                       trials, max_s, &refires_old);
  wedge_new = run_mode(L, "inject   (the CURRENT atomic OR -- must NOT wedge)", 1,
                       trials, max_s, &refires_new);

  printf("\n");
  printf("  %s  R1 the probe has teeth: lua_sethook wedges       %d/%d trials over %ld re-fires\n",
         wedge_old >= 1 ? "PASS" : "FAIL", wedge_old, trials, refires_old);
  if (wedge_old < 1) {
    failures++;
    printf("        <- nothing wedged, so R2 below proves nothing.  Raise the trial\n");
    printf("           count or the duration; the review measured ~1 wedge per 3000\n");
    printf("           re-fires with a realistic hook body.\n");
  }
  printf("  %s  R2 the atomic OR never wedges                    %d/%d trials over %ld re-fires\n",
         wedge_new == 0 ? "PASS" : "FAIL", wedge_new, trials, refires_new);
  if (wedge_new != 0) {
    failures++;
    printf("        <- the fix does not hold: a cross-thread injection still\n");
    printf("           resurrected HOOK_ACTIVE.\n");
  }
  printf("\nchecks=2 failures=%d\n", failures);
  lua_close(L);
  return failures ? 1 : 0;
}
