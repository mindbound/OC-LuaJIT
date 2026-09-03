/* wd_test.c -- the deadline watchdog, on its own terms.
 *
 * Compiled the way jnlua.c is compiled (-include lj52shim.h), linked against
 * the same lj52shim.o the DLL links, no JVM.  It drives _OCLJ_WATCHDOG exactly
 * as the patched kernel does -- arm(seconds, fn) / disarm() through Lua -- with
 * a deadline function that is a faithful model of machine.lua's checkDeadline,
 * and checks the properties the design rests on:
 *
 *   W1  the table exists with the two entry points
 *   W2  an armed deadline interrupts a JIT-COMPILED `while true do end` --
 *       the trace has to exit at the CHECKHOOK guard for the hook to fire at
 *       all -- within a bounded latency
 *   W3  after it fires, checkDeadline's count=1 re-arm is in place, and the
 *       kernel can still reach disarm() -- through the 0.5 s grace, which is
 *       the ONLY reason it can (see the note at DEADLINE below)
 *   W4  disarm before expiry really cancels: the timer does not fire later
 *   W5  arms nest: an inner short deadline fires, disarm pops back to the
 *       outer one, and the outer keeps running undisturbed
 *   W6  THE POINT.  While armed, the JIT actually runs: a hot loop under a
 *       10 s deadline records a handful of traces and takes milliseconds, not
 *       the hundreds of traces and ~0.9 s a standing hook produces
 *   W7  a deadline already in the past installs the hook synchronously
 *   W9  the timer re-fires until disarmed, so a hookmask update lost to a
 *       concurrent restore on the Lua thread costs one interval, not the
 *       deadline (the threads lens of the adversarial review)
 *   W10 the thread filter: a fire that lands on the thread that ARMED sets
 *       the hook but calls nothing; every other thread is interrupted,
 *       including a coroutine nested past the cap with no entry of its own
 *       (the hole the review reproduced in the first filter)
 *   W11 past the nesting cap, arm() degrades to the enclosing deadline
 *       instead of raising -- and never touches the live timer first
 *   W12 a timeout larger than a DWORD of milliseconds arms nothing
 *   W13 no HOOK_ACTIVE wedge: a second of hook-per-instruction under
 *       twenty re-fires leaves the state bits clean and the next deadline
 *       still fires (the timer thread ORs the count bit atomically instead of
 *       calling lua_sethook -- the verify phase of the adversarial review)
 *   W8  the stack heals: disarm(token) restores TO a level, the outermost arm
 *       resets, and a leaked expired entry is never re-programmed (the
 *       adversarial review's finding; each half asserted against the pop-one
 *       behaviour it replaced)
 *
 * Build: see run-wd.sh next to this file.  Exit status 0 iff every case passes.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* For W13 only: look at g->hookmask's state bits directly. */
#include "lj_obj.h"

/* The lua_setallocf macro in lj52shim.h names these; supply them as
 * mem_test.c does, though nothing here arms accounting. */
#define JNLUA_JAVASTATE "jnlua.JavaState"
static JNIEnv FAKE_ENV = NULL;
static JNIEnv *getthreadenv(void) { return &FAKE_ENV; }
static void getluamemory(JNIEnv *e, jobject o, jint *t, jint *u) { (void)e; (void)o; *t = 0; *u = 0; }
static void setluamemory(JNIEnv *e, jobject o, jint u) { (void)e; (void)o; (void)u; }

static int failures = 0, checks = 0;
static void ok(int cond, const char *what, const char *detail) {
  checks++;
  printf("  %s  %-58s %s\n", cond ? "PASS" : "FAIL", what, detail ? detail : "");
  if (!cond) failures++;
}

static double now_ms(void) {
  static LARGE_INTEGER f;
  LARGE_INTEGER t;
  if (f.QuadPart == 0) QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)f.QuadPart;
}

/* now() for Lua: wall-clock seconds, the role computer.realTime() plays for
 * checkDeadline.  os.clock would not do -- it is CPU time, and stands still
 * while W4 sleeps. */
static int l_now(lua_State *L) { lua_pushnumber(L, now_ms() / 1000.0); return 1; }

/* Run a chunk under pcall; return status, leaving any message at -1. */
static int run(lua_State *L, const char *code) {
  if (luaL_loadstring(L, code) != 0) return -1;
  return lua_pcall(L, 0, 0, 0);
}
static const char *msg(lua_State *L) {
  return lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "<non-string>";
}
static int hooked(lua_State *L) { return lua_gethook(L) != NULL; }

/* THE TEST'S OWN ALARM.  Several checks below run `while true do end` and rely
 * on the watchdog to get them out.  A watchdog that never fires would hang
 * this process forever, which is not a test result.  So the test arms a
 * 10-second timer of its own that kills the process with exit code 99 -- and
 * negative-control.sh's "notimer" sabotage expects EXACTLY that: with the
 * asynchronous injection removed, the deadline is not enforced and the only
 * thing that ends the loop is this alarm.  It is the mirror image of the
 * bare-frame death the pushcfunction window prevents. */
static VOID CALLBACK test_alarm(PVOID p, BOOLEAN t) {
  (void)p; (void)t;
  printf("  ALARM  10 s elapsed inside a check that should have been interrupted -- exiting 99\n");
  ExitProcess(99);
}

/* DEADLINE is machine.lua's checkDeadline, transcribed: error only once the
 * deadline has passed; re-arm a count=1 hook so a pcall that swallows the
 * error cannot keep running; extend the deadline by 0.5 s on the FIRST hit.
 *
 * That last clause is load-bearing in a way OC never had to think about.  On
 * PUC Lua hooks are per-thread, so the re-arm lands on the sandbox coroutine
 * only and the kernel runs on unhooked.  On LuaJIT hooks are GLOBAL: after an
 * expiry, the kernel's own instructions -- including the ones that CALL
 * disarm() -- fire checkDeadline too, and the only reason they get through is
 * that the 0.5 s grace has not yet elapsed.  W3 exercises exactly that path,
 * and a DEADLINE that errored unconditionally would (and, in this file's first
 * draft, did) fail every check after W2. */
static const char *PRELUDE =
  "DL_DEADLINE, DL_HIT = math.huge, false\n"
  "DEADLINE = function()\n"
  "  if now() > DL_DEADLINE then\n"
  "    debug.sethook(coroutine.running(), DEADLINE, '', 1)\n"
  "    if not DL_HIT then DL_DEADLINE = DL_DEADLINE + 0.5 end\n"
  "    DL_HIT = true\n"
  "    error('WD-DEADLINE', 0)\n"
  "  end\n"
  "end\n"
  /* ARM(s) is what each kernel arm site does: set the deadline, then arm. */
  "ARM = function(s, outer) DL_DEADLINE, DL_HIT = now() + s, false return _OCLJ_WATCHDOG.arm(s, DEADLINE, outer) end\n"
  "DISARM = function(t) _OCLJ_WATCHDOG.disarm(t) end\n"
  "DEPTH = function() return _OCLJ_WATCHDOG.depth() end\n";

int main(void) {
  lua_State *L;
  char d[256];
  int st;
  double t0, dt;

  setvbuf(stdout, NULL, _IONBF, 0);
  printf("wd_test -- lj52 deadline watchdog\n");
  {
    HANDLE alarm = NULL;
    CreateTimerQueueTimer(&alarm, NULL, test_alarm, NULL, 10000, 0, WT_EXECUTEONLYONCE);
  }

  L = luaL_newstate();                  /* -> lj52_newstate */
  if (!L) { printf("  FAIL  luaL_newstate returned NULL\n"); return 1; }
  luaL_openlibs(L);
  lua_setallocf(L, NULL, NULL);         /* accounting stays off */
  lua_pushcclosure(L, l_now, 0);
  lua_setglobal(L, "now");
  if (run(L, PRELUDE) != 0) { printf("  FAIL  prelude: %s\n", msg(L)); return 1; }

  /* ---- W1 ---------------------------------------------------------- */
  st = run(L, "assert(type(_OCLJ_WATCHDOG) == 'table')"
             " assert(type(_OCLJ_WATCHDOG.arm) == 'function')"
             " assert(type(_OCLJ_WATCHDOG.disarm) == 'function')");
  ok(st == 0, "W1 _OCLJ_WATCHDOG.arm / .disarm exist", st == 0 ? NULL : msg(L));
  lua_settop(L, 0);

  /* ---- W2: interrupt a compiled infinite loop ------------------------ */
  run(L, "ARM(0.05)");
  t0 = now_ms();
  st = run(L, "while true do end");
  dt = now_ms() - t0;
  sprintf(d, "status=%d msg=%s after %.1f ms", st, msg(L), dt);
  /* 300 ms: measured 56-61 ms, timer-queue jitter is tens of ms at worst,
   * and 300 is still well under the 1000 ms OC's own hookInterval design
   * tolerates.  A bound of a full second would not distinguish this from a
   * hook that fires only when something else happens to yield. */
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL && dt < 300.0,
     "W2 a 50 ms deadline interrupts `while true do end`", d);
  lua_settop(L, 0);

  /* ---- W3: the re-arm is in place; disarm still gets through --------- */
  ok(hooked(L), "W3a after firing, checkDeadline's count=1 re-arm is set", NULL);
  st = run(L, "DISARM()");
  sprintf(d, "status=%d%s%s, hook=%s", st, st ? " msg=" : "", st ? msg(L) : "",
          hooked(L) ? "SET" : "clear");
  ok(st == 0 && !hooked(L),
     "W3b disarm() reached through the grace and cleared it", d);
  lua_settop(L, 0);

  /* ---- W4: disarm before expiry cancels ------------------------------ */
  run(L, "ARM(0.05) DISARM()");
  Sleep(150);
  st = run(L, "local t = now() while now() - t < 0.05 do end");
  sprintf(d, "status=%d, hook=%s after sleeping past the cancelled deadline",
          st, hooked(L) ? "SET" : "clear");
  ok(st == 0 && !hooked(L), "W4 disarm before expiry: nothing fires later", d);
  lua_settop(L, 0);

  /* ---- W5: nesting --------------------------------------------------- */
  run(L, "ARM(10) OUTER = DL_DEADLINE");               /* outer, generous */
  run(L, "ARM(0.05)");                                  /* inner, short */
  t0 = now_ms();
  st = run(L, "while true do end");
  dt = now_ms() - t0;
  sprintf(d, "status=%d after %.1f ms", st, dt);
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL, "W5a inner deadline fires", d);
  lua_settop(L, 0);
  /* pop the inner arm; the kernel's sgc site restores its saved deadline
   * here in the same breath, and so do we */
  run(L, "DISARM() DL_DEADLINE, DL_HIT = OUTER, false");
  st = run(L, "local t = now() while now() - t < 0.1 do end");
  sprintf(d, "status=%d, hook=%s", st, hooked(L) ? "SET" : "clear");
  ok(st == 0 && !hooked(L),
     "W5b popped to the outer 10 s deadline: a 100 ms loop is undisturbed", d);
  run(L, "DISARM()");                                   /* pop outer */
  ok(!hooked(L), "W5c fully disarmed", NULL);
  lua_settop(L, 0);

  /* ---- W6: THE POINT -- the JIT runs while a deadline is armed ------- */
  st = run(L, "assert(jit.status(), 'JIT is off')");
  ok(st == 0, "W6a jit.status() is true", st ? msg(L) : NULL);
  lua_settop(L, 0);
  run(L, "ARM(10)");
  run(L, "TR = {start=0, stop=0, abort=0}"
         " jit.attach(function(what) TR[what] = (TR[what] or 0) + 1 end, 'trace')");
  t0 = now_ms();
  st = run(L, "local s = 0 for i = 1, 4000000 do s = s + (i % 7) * 2 end return s");
  dt = now_ms() - t0;
  run(L, "DISARM()");
  run(L, "TRS = TR.start .. '/' .. TR.stop .. '/' .. TR.abort  TRSTOPS = TR.stop");
  lua_getglobal(L, "TRS");
  lua_getglobal(L, "TRSTOPS");
  {
    /* Read defensively: lua_tointeger on a nil is 0, lua_getfield on a nil
     * would be an unprotected error in a bare frame -- the exact shape of the
     * JVM-killer this project spends so much effort on.  Learned here. */
    int stops = (int)lua_tointeger(L, -1);
    const char *trs = lua_isstring(L, -2) ? lua_tostring(L, -2) : "?";
    sprintf(d, "4M iterations in %.1f ms, traces start/stop/abort=%s "
               "(a standing hook: ~900 ms, ~200 traces)", dt, trs);
    /* dt < 20 ms separates compiled (6-8 ms measured) from interpreted
     * (~30 ms for this loop): "traces run" is asserted on time, not merely
     * inferred from "traces were compiled". */
    ok(st == 0 && stops >= 1 && stops <= 5 && dt < 20.0,
       "W6b traces run while armed: few traces, milliseconds", d);
  }
  lua_settop(L, 0);

  /* ---- W7: a deadline already in the past hooks synchronously --------
   * Slightly past, not a whole second: checkDeadline's grace is +0.5 s from
   * the DEADLINE, not from now, so a kernel that arms more than 0.5 s late
   * cannot reach disarm() -- exactly as OC's own kernel on LuaJIT could not.
   * The kernel sets deadline = realTime + timeout right before arming, so
   * "slightly late" is the only reachable version of this case. */
  st = run(L, "ARM(-0.1)");
  /* The hook goes in synchronously inside arm(), so it fires on the very next
   * instruction -- which is still inside the ARM chunk.  A kernel that arms
   * late is therefore interrupted at the arm site, not somewhere later. */
  sprintf(d, "status=%d msg=%s, hook=%s", st, msg(L), hooked(L) ? "SET" : "clear");
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL && hooked(L),
     "W7a arm(-0.1) hooks synchronously and fires before arm() returns", d);
  lua_settop(L, 0);
  st = run(L, "local x = 0 x = x + 1");
  sprintf(d, "status=%d (inside the grace, so the re-armed hook lets it run)", st);
  ok(st == 0 && hooked(L), "W7b the count=1 re-arm is in place and grace holds", d);
  lua_settop(L, 0);
  st = run(L, "DISARM()");
  ok(st == 0 && !hooked(L), "W7c disarmed again through the grace", st ? msg(L) : NULL);
  lua_settop(L, 0);

  /* ---- W9: the re-fire ----------------------------------------------
   * The cross-thread lua_sethook can lose its update to a concurrent
   * hookmask restore on the Lua thread (see THREADING in lj52shim.c).  The
   * defence is that the timer keeps re-firing until disarmed.  Simulate the
   * lost update directly: let a deadline fire, CLEAR the hook from C as if
   * the update had been lost, and require it to come back on its own. */
  run(L, "ARM(0.05)");
  st = run(L, "while true do end");
  lua_settop(L, 0);
  ok(st != 0 && hooked(L), "W9a deadline fired, hook set", NULL);
  lua_sethook(L, NULL, 0, 0);                          /* "the update was lost" */
  ok(!hooked(L), "W9b hook cleared behind the watchdog's back", NULL);
  Sleep(3 * 50 + 20);
  sprintf(d, "hook=%s after %d ms with the timer still armed", hooked(L) ? "SET" : "clear", 3 * 50 + 20);
  ok(hooked(L), "W9c the re-fire put it back", d);
  run(L, "DISARM()");
  Sleep(3 * 50 + 20);
  sprintf(d, "hook=%s %d ms after disarm", hooked(L) ? "SET" : "clear", 3 * 50 + 20);
  ok(!hooked(L), "W9d and disarm stops the re-fire for good", d);
  lua_settop(L, 0);

  /* ---- W13: no HOOK_ACTIVE wedge across a grace full of re-fires -------
   * The hazard: the timer's stale hookmask landing after the Lua thread's
   * hook_leave resurrects HOOK_ACTIVE, and no hook ever runs again.  Drive
   * the exact exposure -- a count=1 hook calling DEADLINE on every
   * instruction for a whole second while the timer re-fires twenty times --
   * then require the state bits clean and a fresh deadline still enforced.
   * Probabilistic by nature, so this is a positive check, not a control. */
  run(L, "ARM(0.02)");
  st = run(L, "while true do end");                  /* fires; count=1 re-arm */
  lua_settop(L, 0);
  run(L, "DL_DEADLINE = now() + 10");                /* stay inside the 'grace' */
  st = run(L, "local t = now() while now() - t < 1.0 do pcall(error, 0) end");
  {
    int active = (G(L)->hookmask & HOOK_ACTIVE) != 0;
    sprintf(d, "status=%d, HOOK_ACTIVE=%s after 1 s of hook-per-instruction with ~20 re-fires",
            st, active ? "STUCK" : "clear");
    ok(st == 0 && !active, "W13a no HOOK_ACTIVE wedge", d);
  }
  run(L, "DISARM()");
  lua_settop(L, 0);
  run(L, "ARM(0.05)");
  t0 = now_ms();
  st = run(L, "while true do end");
  dt = now_ms() - t0;
  sprintf(d, "status=%d after %.1f ms", st, dt);
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL, "W13b and the next deadline still fires", d);
  lua_settop(L, 0);
  run(L, "DISARM()");

  /* ---- W8: the stack heals -------------------------------------------
   * A disarm that never ran (checkDeadline fired on the kernel's own
   * instructions past the grace; a sandbox pcall swallowed it) leaves an
   * entry behind.  Two properties close that hole, and each is asserted
   * against the OLD behaviour it replaces. */
  run(L, "T1 = ARM(10) ARM(10) ARM(10)");           /* three arms, no disarms */
  run(L, "DISARM(T1)");                              /* restore to below T1 */
  lua_getglobal(L, "DEPTH"); lua_call(L, 0, 1);
  sprintf(d, "depth after disarm(token=1) with two leaked entries above = %d",
          (int)lua_tointeger(L, -1));
  ok(lua_tointeger(L, -1) == 0, "W8a disarm(token) restores TO the level, not one entry", d);
  lua_settop(L, 0);

  /* Now the harmful case: a leaked entry that has already EXPIRED sits under
   * a legitimate one.  Pop-one semantics would re-program the expired
   * deadline the moment the legitimate one popped -- a spurious fire on the
   * very next instruction.  The outermost arm must discard it instead. */
  run(L, "ARM(10)");                                 /* a resume: depth 1 */
  run(L, "ARM(0.05)");                               /* nested: depth 2 */
  st = run(L, "while true do end");                  /* ...which expires */
  lua_settop(L, 0);
  /* Simulate the leak: NO disarm for the expired inner arm; the kernel's
   * next resume simply arms again as the outermost. */
  run(L, "T = ARM(10, true)");
  lua_getglobal(L, "DEPTH"); lua_call(L, 0, 1);
  sprintf(d, "depth after an outermost arm over two leaked entries = %d", (int)lua_tointeger(L, -1));
  ok(lua_tointeger(L, -1) == 1, "W8b the outermost arm resets the stack first", d);
  lua_settop(L, 0);
  st = run(L, "local t = now() while now() - t < 0.1 do end");
  ok(st == 0 && !hooked(L), "W8c the leaked expired deadline is gone: a 100 ms loop is undisturbed",
     st ? msg(L) : NULL);
  lua_settop(L, 0);
  st = run(L, "DISARM(T)");
  sprintf(d, "status=%d hook=%s", st, hooked(L) ? "SET (the stale entry was re-programmed)" : "clear");
  ok(st == 0 && !hooked(L), "W8d and popping the legitimate one re-programs nothing stale", d);
  lua_settop(L, 0);

  /* ---- W10: the thread filter ----------------------------------------
   * Skipped only for a parent waiting on a child: a thread that armed a live
   * entry and is not the thread that entry protects.  Here main arms FOR CO
   * and then runs itself -- exactly the kernel's post-yield window. */
  run(L, "CO = coroutine.create(function() while true do end end)");
  run(L, "DL_DEADLINE, DL_HIT = now() + 0.05, false _OCLJ_WATCHDOG.arm(0.05, DEADLINE, false, CO)");
  st = run(L, "local t = now() while now() - t < 0.15 do end");
  sprintf(d, "status=%d hook=%s", st, hooked(L) ? "SET" : "clear");
  ok(st == 0 && hooked(L), "W10a a fire on a parent waiting on a child calls nothing", d);
  lua_settop(L, 0);
  run(L, "DISARM()");
  ok(!hooked(L), "W10b and disarm clears it as usual", NULL);
  run(L, "DL_DEADLINE, DL_HIT = now() + 0.05, false _OCLJ_WATCHDOG.arm(0.05, DEADLINE, false, CO)");
  st = run(L, "local okc, err = coroutine.resume(CO) if okc then error('CO ran to completion', 0) end error(tostring(err), 0)");
  sprintf(d, "status=%d msg=%s", st, msg(L));
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL, "W10c the same arm interrupts the coroutine it protects", d);
  lua_settop(L, 0);
  run(L, "DISARM()");
  /* The review's reproduction: a coroutine PAST THE CAP has no entry of its
   * own.  The first filter matched entries, so it never fired here and the
   * coroutine ran with no deadline at all.  Fill the stack from main, then
   * spin inside a coroutine whose arm was refused: it must still die -- on
   * the ENCLOSING deadline, which is what "arm past the cap degrades to
   * inheriting" means.  So the stack is filled with SHORT deadlines: with a
   * 10 s outer the inherited deadline is 10 s away and the only thing that
   * would end this check is the test's own alarm, which is how it was first
   * written and why it hung. */
  run(L, "T1 = ARM(0.3) for i = 1, 300 do _OCLJ_WATCHDOG.arm(0.3, DEADLINE) end DL_DEADLINE, DL_HIT = now() + 0.3, false");
  run(L, "CO2 = coroutine.create(function() _OCLJ_WATCHDOG.arm(0.05, DEADLINE) while true do end end)");
  t0 = now_ms();
  st = run(L, "local okc, err = coroutine.resume(CO2) if okc then error('CO2 ran to completion', 0) end error(tostring(err), 0)");
  dt = now_ms() - t0;
  sprintf(d, "status=%d after %.1f ms msg=%s", st, dt, msg(L));
  ok(st != 0 && strstr(msg(L), "WD-DEADLINE") != NULL && dt < 2000.0,
     "W10d a coroutine nested past the cap is still interrupted", d);
  lua_settop(L, 0);
  run(L, "DISARM(T1)");
  ok(!hooked(L), "W10e and disarm(token) unwinds it all", NULL);

  /* ---- W11: past the cap, arm degrades to the enclosing deadline ------- */
  run(L, "T1 = ARM(10) for i = 1, 400 do _OCLJ_WATCHDOG.arm(10, DEADLINE) end");
  lua_getglobal(L, "DEPTH"); lua_call(L, 0, 1);
  sprintf(d, "depth after 401 arms = %d (cap %d), no error raised", (int)lua_tointeger(L, -1), LJ52_WD_MAXDEPTH);
  ok(lua_tointeger(L, -1) == LJ52_WD_MAXDEPTH, "W11a arms past the cap push nothing and raise nothing", d);
  lua_settop(L, 0);
  /* An arm past the cap must not disturb the live outer timer either. */
  st = run(L, "local tok = _OCLJ_WATCHDOG.arm(0.05, DEADLINE) local t = now() while now() - t < 0.1 do end _OCLJ_WATCHDOG.disarm(tok)");
  sprintf(d, "status=%d hook=%s", st, hooked(L) ? "SET" : "clear");
  ok(st == 0 && !hooked(L), "W11b ...and the enclosing 10 s deadline is what stays live", d);
  run(L, "DISARM(T1)");
  lua_getglobal(L, "DEPTH"); lua_call(L, 0, 1);
  ok(lua_tointeger(L, -1) == 0, "W11c disarm(token) unwinds it all", NULL);
  lua_settop(L, 0);

  /* ---- W12: a huge timeout is "no deadline", not an immediate fire ------ */
  run(L, "ARM(1e16)");
  Sleep(120);
  sprintf(d, "hook=%s 120 ms after arm(1e16 s)", hooked(L) ? "SET (the DWORD wrapped and the timer fired at once)" : "clear");
  ok(!hooked(L), "W12 a timeout beyond what a DWORD holds arms no timer at all", d);
  run(L, "DISARM()");
  lua_settop(L, 0);

  printf("\nchecks=%d failures=%d\n", checks, failures);
  lua_close(L);                         /* -> lj52_close: cancels the timer */
  return failures ? 1 : 0;
}
