/* lj52shim.c -- implementation of the Lua 5.2 C API surface OC-JNLua needs,
 * on top of LuaJIT 2.1 (Lua 5.1 ABI) built with LUAJIT_ENABLE_LUA52COMPAT and
 * LUAJIT_ENABLE_CHECKHOOK.
 *
 * See lj52shim.h for the contract and for the two comment blocks that matter
 * most: THE MODE GATE and the allocator STOPGAP.
 *
 * HOUSE RULES FOR THIS FILE (same as serializer/eris_lj.c):
 *   - every place where LuaJIT's 5.1 semantics differ from 5.2 gets a comment
 *     saying WHAT differs and WHY the chosen behaviour is the 5.2 one, so a
 *     future reader never has to re-derive the reasoning;
 *   - no getenv(), anywhere. A shipping shim has exactly ONE behaviour. The
 *     variants this file replaces carried OCLJ_NOMODECHECK (disabled the
 *     bytecode gate), OCLJ_TRACE (installed a LUA_MASKCOUNT hook -- the very
 *     hook slot OC's deadline watchdog owns), OCLJ_JITOFF, OCLJ_JITOPT,
 *     OCLJ_JITATTACH and LJ52_MEMLIMIT. Every one of those is a switch that
 *     changes security- or scheduling-relevant behaviour from the process
 *     environment, where no server operator would ever see it. If a JIT-off
 *     escape hatch is wanted it belongs in OC's own config file.
 *   - no build flags that select a known-broken behaviour.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <luajit.h>

#include "lj52shim.h"

/* Inside this file we need the GENUINE 5.1 entry points that the header
 * redirects for jnlua.c's benefit. lua_load stays redirected: it now maps to
 * LuaJIT's own lua_loadx, which is what we would want here anyway. */
#undef lua_resume
#undef luaL_newstate
#undef lua_pushcfunction
#undef lua_setallocf
#undef lua_setfield
#undef lua_close

#include "eris_lj.h"

/* ================================================================== *
 * registry-cached VM helpers
 * ================================================================== */

/* lua_compare, lua_arith and lua_len must fire METAMETHODS, and must fire the
 * RIGHT ones. The only way to be sure of that on LuaJIT is to let the VM do
 * the operation, so we keep one compiled chunk per state and call into it.
 *
 * The chunk is cached in the registry under a LIGHT USERDATA key -- the
 * address of a file-static object. A string key would sit in the same
 * namespace as everything else that stores things in the registry (jnlua's
 * own "_LOADED", OC's persistence keys, luaL_ref's freelist), and this key can
 * never collide with any of them. */
static const char LJ52_HELPERS_KEY = 0;

static const char LJ52_HELPERS_SRC[] =
  /* op codes here are 5.2's: LUA_OPEQ=0 LUA_OPLT=1 LUA_OPLE=2, and
   * LUA_OPADD=0 .. LUA_OPUNM=6. */
  "local function cmp(op, a, b)\n"
  "  if op == 0 then return a == b\n"
  "  elseif op == 1 then return a < b\n"
  "  else return a <= b end\n"
  "end\n"
  "local function arith(op, a, b)\n"
  "  if op == 0 then return a + b\n"
  "  elseif op == 1 then return a - b\n"
  "  elseif op == 2 then return a * b\n"
  "  elseif op == 3 then return a / b\n"
  "  elseif op == 4 then return a % b\n"
  "  elseif op == 5 then return a ^ b\n"
  "  elseif op == 6 then return -a\n"
  "  end\n"
  "  error('bad arith op')\n"
  "end\n"
  "local function len(a) return #a end\n"
  "return { cmp = cmp, arith = arith, len = len }\n";

/* Compile and install the helper table. Leaves nothing on the stack.
 * Called once from lj52_newstate; lj52_gethelper re-runs it lazily for any
 * state we did not create. */
static void lj52_installhelpers(lua_State *L) {
  if (luaL_loadbuffer(L, LJ52_HELPERS_SRC, sizeof(LJ52_HELPERS_SRC) - 1,
                      "=[lj52shim]") != 0)
    lua_error(L);
  lua_call(L, 0, 1);                                   /* t */
  lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY); /* t k */
  lua_insert(L, -2);                                   /* k t */
  lua_rawset(L, LUA_REGISTRYINDEX);
}

/* Pushes helpers[name]. Raises on failure; every caller is reached from a
 * protected frame in jnlua. */
static void lj52_gethelper(lua_State *L, const char *name) {
  lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lj52_installhelpers(L);
    lua_pushlightuserdata(L, (void *)&LJ52_HELPERS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
  }
  lua_getfield(L, -1, name);
  lua_remove(L, -2);
}

/* ================================================================== *
 * lua_pushcfunction memo
 * ================================================================== */

/* See the long comment in lj52shim.h. The memo table lives at
 * registry[LJ52_CF_RIDX]; keys are the C function pointers as light userdata,
 * values are the one GCfunc we ever build for them in this state.
 *
 * Casting a function pointer to void* is not something ISO C blesses, but it
 * is well defined on every ABI this DLL can be built for (Win64, SysV x64) and
 * the union spelling keeps -Wall -Wpedantic quiet. */
typedef union { lua_CFunction f; void *p; } lj52_cfkey;

/* An address in this DLL's image, used only for its address -- see the
 * pre-intern in lj52_newstate. */
static const char LJ52_LIGHTUD_SEED = 0;

static void lj52_pushcfunction_raw(lua_State *L, lua_CFunction f) {
  lj52_cfkey k;
  k.p = NULL;
  k.f = f;
  lua_rawgeti(L, LUA_REGISTRYINDEX, LJ52_CF_RIDX);
  if (!lua_istable(L, -1)) {
    /* A state we did not create (or one whose registry has been reset).
     * Fall back to the plain 5.1 behaviour rather than failing. */
    lua_pop(L, 1);
    lua_pushcclosure(L, f, 0);
    return;
  }
  lua_pushlightuserdata(L, k.p);   /* t key */
  lua_rawget(L, -2);               /* t val */
  if (lua_isfunction(L, -1)) {     /* warm: allocation-free */
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);                   /* t */
  lua_pushlightuserdata(L, k.p);   /* t key */
  lua_pushcclosure(L, f, 0);       /* t key fn   -- cold: once per state */
  lua_pushvalue(L, -1);            /* t key fn fn */
  lua_insert(L, -4);               /* fn t key fn */
  lua_rawset(L, -3);               /* fn t */
  lua_pop(L, 1);                   /* fn */
}

/* ================================================================== *
 * memory accounting
 * ================================================================== */

/* Read the long comment in lj52shim.h first; it explains why jnlua's own
 * l_alloc_checked cannot run on LuaJIT and why this reimplements its
 * arithmetic instead of wrapping it.
 *
 * One record per lua_State, reachable from every thread of that state through
 * lua_getallocf, because allocf/allocd live in the shared global_State.  No
 * table keyed by lua_State*, and therefore no lock: a server running twenty
 * machines on twenty threads touches twenty disjoint records. */
typedef struct lj52_mem {
  lj52_envfn    envfn;      /* jnlua's getthreadenv                          */
  lj52_getmemfn getmem;     /* jnlua's getluamemory                          */
  lj52_setmemfn setmem;     /* jnlua's setluamemory                          */
  const char   *jskey;      /* jnlua's JNLUA_JAVASTATE, not a copy of it     */
  jobject      *javaref;    /* &(the weak global ref) inside jnlua's userdata */
  int           accounting; /* jnlua asked for a capped state (ud != NULL)   */
  int           norefuse;   /* >0: charge, but never refuse -- see below     */
  long long     pending;    /* bytes moved while nobody could be told yet    */
  /* -- the deadline watchdog; see its section below -- */
  lua_State    *L;          /* main thread: what the timer callback hooks    */
  void         *wd_timer;   /* pending Win32 timer-queue timer, or NULL      */
  int           wd_depth;   /* nested arms                                   */
  double        wd_stack[LJ52_WD_MAXDEPTH]; /* absolute deadlines, ms      */
  lua_State    *wd_for[LJ52_WD_MAXDEPTH];   /* the thread each arm protects */
  lua_State    *wd_by[LJ52_WD_MAXDEPTH];    /* the thread that armed each   */
  /* Diagnostics, written by the timer thread and the hook, read by stats().
   * Plain ints on purpose: they are counters for a human, not for logic. */
  volatile int  wd_fired;    /* the current timer has fired at least once   */
  volatile long wd_fires;    /* first fires, ever                            */
  volatile long wd_refires;  /* periodic re-fires, ever                      */
  volatile long wd_filtered; /* hook invocations ignored by the thread filter */
} lj52_mem;

static void *lj52_alloc(void *ud, void *ptr, size_t osize, size_t nsize);

/* The record for L, or NULL for a state this shim did not create. */
static lj52_mem *lj52_memof(lua_State *L) {
  void *ud = NULL;
  if (L == NULL) return NULL;
  return lua_getallocf(L, &ud) == lj52_alloc ? (lj52_mem *)ud : NULL;
}

/* Plain libc, the allocator every one of our states is born on.  jnlua's
 * l_alloc_unchecked is realloc/free too, and so was lj52_defalloc before this,
 * so blocks stay interchangeable across every path including lua_close. */
static void *lj52_libc(void *ptr, size_t nsize) {
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

/* THE ALLOCATOR.  Reproduces l_alloc_checked's arithmetic exactly -- charge
 * nsize for a fresh block, nsize-osize for a resize, credit osize on free, and
 * treat total <= 0 or a shrink as always permitted -- with two differences,
 * both deliberate:
 *
 *   1. It never calls the Lua API.  jnlua reaches the Java object through
 *      getjavastate() -> lua_getfield() on every single allocation; we read it
 *      from a pointer cached when jnlua bound it (lj52_setfield).  This is the
 *      whole fix: re-entering the VM from inside a lua_Alloc callback is what
 *      takes the JVM down on LuaJIT.
 *
 *   2. It charges only what it actually got.  jnlua writes used+delta before
 *      knowing whether realloc succeeded, so a failed resize permanently
 *      inflates the machine's usage.  Ours charges after the fact.
 *
 * norefuse is the other half of this change; see lj52_pushcfunction. */
/* The Java side stores used/total as jint, so that is what crosses the JNI
 * boundary -- but the arithmetic in between is done in long long and saturated
 * on the way out.  jnlua does it all in int, computing `int delta` from a
 * size_t expression (jnlua.c:268) and `used - osize` by promote-and-truncate
 * (jnlua.c:265); both are accidentally correct only while every quantity fits
 * in 32 bits.  Being right costs nothing here.  Note the clamp is to the jint
 * RANGE, not to zero: a `used` that has gone negative is a bug worth seeing
 * (see the pending accumulator below), and mem_test's M4b asserts on it, so
 * silently flooring it at zero would hide exactly what we want reported. */
static jint lj52_clampi(long long v) {
  if (v > 2147483647LL) return 2147483647;
  if (v < -2147483647LL - 1) return -2147483647 - 1;
  return (jint)v;
}

static void *lj52_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  lj52_mem *M = (lj52_mem *)ud;
  JNIEnv *env;
  jobject obj;
  jint jtotal = 0, jused = 0;
  long long total, used, delta;
  void *p;

  /* jnlua's delta: the whole block when it is new, the difference when it is
   * resized, and a credit of the old size when it is freed. */
  delta = nsize == 0 ? -(long long)osize
                     : (ptr == NULL ? (long long)nsize
                                    : (long long)nsize - (long long)osize);

  if (M == NULL) return lj52_libc(ptr, nsize);

  /* Ordered so the JNI call is the LAST thing tried, not the first: this runs
   * on every allocation, and during lua_close -- where jnlua disarms us and
   * then frees the entire heap -- getthreadenv() would otherwise be called
   * once per block for nothing. */
  obj = M->accounting && M->javaref != NULL ? *M->javaref : NULL;
  env = obj != NULL && M->envfn != NULL ? M->envfn() : NULL;
  if (obj == NULL || env == NULL) {
    /* Not chargeable YET, or no longer.  There is a real window here:
     * controlled_newstate installs the cap before newstate_protected has bound
     * the Java LuaState, so the state's own creation is allocated before
     * anyone can be told about it -- and jnlua clears the binding again at
     * close.  Bank the bytes rather than dropping them.  Dropping them is not
     * merely imprecise, it makes `used` go NEGATIVE the moment those blocks
     * are freed under a live binding, and a negative `used` reads back through
     * NativeLuaArchitecture as a machine with MORE memory than its cap, or as
     * a nonsense total.  Measured, before this was banked: used fell to
     * -387188 across an ordinary allocate-then-collect cycle. */
    p = lj52_libc(ptr, nsize);
    if (p != NULL || nsize == 0) M->pending += delta;
    return p;
  }

  M->getmem(env, obj, &jtotal, &jused);
  total = jtotal;
  used = jused;
  if (M->pending != 0) {                /* first chargeable call: settle up */
    used += M->pending;
    M->pending = 0;
    M->setmem(env, obj, lj52_clampi(used));
  }
  if (nsize == 0) {
    free(ptr);
    M->setmem(env, obj, lj52_clampi(used + delta));
    return NULL;
  }
  if (!(total <= 0 || delta <= 0 || total - used >= delta || M->norefuse))
    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */
  p = realloc(ptr, nsize);
  if (p != NULL) M->setmem(env, obj, lj52_clampi(used + delta));
  return p;
}

/* jnlua's three lua_setallocf sites, intercepted.  We install nothing: the
 * (lj52_alloc, record) pairing set at newstate must survive, because it is how
 * lj52_memof finds the record.  All that changes is a flag. */
void lj52_setallocf(lua_State *L, lua_Alloc f, void *ud,
                    lj52_envfn envfn, lj52_getmemfn getmem,
                    lj52_setmemfn setmem, const char *jskey) {
  lj52_mem *M = lj52_memof(L);
  (void)f;
  if (M == NULL) return;
  M->envfn = envfn;
  M->getmem = getmem;
  M->setmem = setmem;
  M->jskey = jskey;
  M->accounting = ud != NULL;
}

/* Cache the Java LuaState as jnlua binds it, so the allocator never has to ask
 * the VM for it.  Everything else forwards untouched; the guard is an integer
 * compare, and the strcmp only runs for registry writes, of which jnlua does a
 * handful in a state's lifetime.
 *
 * The value stored is a FULL userdata holding a weak global ref, and we keep
 * its ADDRESS rather than the ref, so we follow jnlua if it ever rewrites the
 * ref in place.  The userdata is kept alive by the registry entry itself, and
 * close_protected clears that entry by storing nil -- which lands here and
 * clears the cache in the same breath. */
void lj52_setfield(lua_State *L, int idx, const char *k) {
  if (idx == LUA_REGISTRYINDEX && k != NULL) {
    lj52_mem *M = lj52_memof(L);
    if (M != NULL && M->jskey != NULL && strcmp(k, M->jskey) == 0)
      M->javaref = lua_type(L, -1) == LUA_TUSERDATA
                     ? (jobject *)lua_touserdata(L, -1) : NULL;
  }
  lua_setfield(L, idx, k);
}

/* ================================================================== *
 * the deadline watchdog
 * ================================================================== */

/* WHY THIS EXISTS.  OpenComputers enforces its per-resume timeout with a
 * COUNT HOOK: machine.lua arms debug.sethook(co, checkDeadline, "", N)
 * before every resume of the sandbox and inside every sandbox
 * coroutine.resume, and never clears the outer one.  On PUC Lua that is
 * cheap.  On LuaJIT it is ruinous, for two reasons that compose:
 *   - hooks are GLOBAL to the state, not per-thread (lj_dispatch.c:337-348),
 *     and an armed count hook forces instruction dispatch for the whole VM
 *     (lj_dispatch.c:121) and aborts any trace being recorded (:345);
 *   - the CHECKHOOK patch we need in order to boot at all makes every compiled
 *     trace exit to the interpreter on entry while a hook is set.
 * Measured inside a real machine (docs/research/hook-vs-jit.md section 6): the
 * same loop in the sandbox is 18.8x SLOWER with the JIT on than off, OpenOS
 * boots 40% slower, and ~2700 traces are compiled and thrown away per boot.
 * CHECKHOOK's own comment says it is "only useful if hooks are NOT set most
 * of the time" -- it was written for an asynchronous interrupt, which is what
 * this is.
 *
 * WHAT IT IS.  arm(seconds, fn) programs a one-shot OS timer and touches no
 * hook at all.  When the timer expires, its callback -- on a thread that is
 * not the Lua thread -- calls lua_sethook(L, hook, LUA_MASKCOUNT, 1).  The
 * next trace-entry guard fails, the trace exits, the interpreter fires the
 * hook on the very next instruction, and the hook calls fn.  fn is
 * machine.lua's own checkDeadline, UNCHANGED: the tooLongWithoutYielding
 * sentinel, the +0.5s grace, the count=1 re-arm that keeps a pcall-swallowing
 * loop from escaping -- all of it stays exactly as OC wrote it.  What changes
 * is only who arms the hook and when: never, until the deadline has actually
 * passed.  Between deadlines g->hookmask is zero and traces run.
 *
 * disarm() cancels the timer -- BLOCKING until a callback already in flight
 * has finished -- and clears whatever hook is set, including checkDeadline's
 * own re-arm.  It must be called when the resume returns, or a deadline that
 * expires while the machine is idle between ticks would set a count=1 hook
 * that fires on the first instruction of the NEXT resume as a spurious
 * timeout.
 *
 * ARMS NEST.  The kernel arms around the sandbox resume, the sandbox's
 * coroutine.resume wrapper arms around each user coroutine, and the
 * synchronous-__gc path arms around a finaliser -- one inside the other.  So
 * arm pushes an absolute deadline and the timer always runs for the top of
 * the stack.  This is BETTER than what OC's machine.lua does on LuaJIT today:
 * its inner debug.sethook(co) clears the one global hook, and the outer
 * resume then runs with no deadline at all until it yields -- a per-thread-
 * hooks assumption that holds on PUC and not here.
 *
 * ... AND A STACK CAN LEAK, so it is built to heal.  After a deadline fires,
 * checkDeadline's count=1 re-arm is GLOBAL (hooks are, on LuaJIT), so it also
 * fires on the kernel's own instructions between the resume returning and
 * disarm() being called.  Inside the grace that is harmless; past it,
 * checkDeadline errors THERE, disarm() is never reached -- and if the error is
 * then caught by a sandbox pcall (OpenOS's event loop catches callback
 * errors), the machine lives on with one stale entry left on the stack.  A
 * naive pop-one disarm would deepen the stack by one per such leak and, worse,
 * re-program the stale, already-expired deadline the moment a legitimate one
 * popped above it: a spurious "too long without yielding" on the very next
 * instruction.  (Found in adversarial review, not in testing.)  So:
 *   - arm() RETURNS its depth, and disarm(token) restores the stack TO that
 *     level rather than popping one entry -- whatever leaked inside is gone;
 *   - the kernel's main-loop arm passes outermost=true and RESETS the stack
 *     first, so every resume starts clean no matter what the previous one
 *     left behind.  OC's stock kernel has the same self-healing property by
 *     accident: its arm simply overwrites the one global hook.
 * depth() exists for the tests and for diagnostics; the sandbox cannot reach
 * any of these.
 *
 * WHO MAY CALL IT.  The table is a raw global (_OCLJ_WATCHDOG), captured by
 * the kernel as an upvalue before it builds the sandbox; the sandbox's debug
 * table exposes getinfo and traceback only (machine.lua:1001), so sandbox
 * code can neither arm a standing hook nor clear ours.  Being reachable from
 * the raw _G also makes the table and its two C functions PERMANENTS for the
 * serializer, which is what lets a kernel holding them as upvalues persist.
 *
 * THREADING, stated plainly.  lua_sethook from another thread is the case
 * CHECKHOOK documents (lj_record.c:2963, "from a signal handler or another
 * native thread") and what prototype/watchdog/ validated on hardware.  The
 * callback does exactly one thing, lua_sethook, and nothing else; disarm
 * cancels the timer BEFORE touching the hook itself, and arm creates the new
 * timer only AFTER cancelling any old one, so the callback never runs
 * concurrently with a lua_sethook on the Lua thread.  The one lua_sethook the
 * kernel still makes itself, checkDeadline's count=1 re-arm, runs from inside
 * the hook the callback installed -- i.e. after the callback has returned.
 *
 * ... WHICH IS NOT THE WHOLE STORY, and the adversarial review said so.
 * g->hookmask is ONE byte holding both the event bits (LUA_MASKCOUNT and
 * friends) and LuaJIT's own state bits: HOOK_ACTIVE while a hook is running,
 * HOOK_GC inside a finaliser, HOOK_VMEVENT inside a VM event.  The Lua thread
 * read-modify-writes that byte constantly and never through lua_sethook --
 * hook_enter/hook_leave around EVERY hook call, hook_entergc/hook_restore
 * around every finaliser, and the VM-event pair around every trace event --
 * and lua_sethook itself is a plain RMW too (lj_dispatch.c:344).  Two threads
 * doing plain RMWs on one byte lose updates in both directions:
 *   - the Lua thread's restore lands last: the count bit the callback just set
 *     is GONE.  With a one-shot timer that resume's deadline is never
 *     enforced.  Hence the timer RE-FIRES every LJ52_WD_REFIRE_MS until
 *     disarm() cancels it -- the escalation prototype/watchdog/ ran -- so a
 *     lost update costs one interval, not the deadline;
 *   - the callback's stale value lands last: a state bit the Lua thread had
 *     just CLEARED is back.  A resurrected HOOK_ACTIVE is a hook that never
 *     runs again -- callhook refuses while ACTIVE is set, every later
 *     lua_sethook preserves the non-event bits, and the only clear is a
 *     hook_leave that can no longer happen.  The machine is then silently
 *     undefended for the rest of its life.  And the re-fire that fixes the
 *     first direction multiplies exposure to this one: during the 0.5 s
 *     grace after a fire, checkDeadline's count=1 re-arm has the Lua thread
 *     in hook_enter/hook_leave on every instruction while the timer lands ten
 *     more RMWs into that stream.
 * So the timer thread does NOT call lua_sethook.  lj52_wd_inject stores
 * hookf and hookcount (aligned words, atomic on x64), then ORs the single
 * count bit into hookmask with an atomic fetch-or.  An OR cannot resurrect a
 * cleared bit and cannot clear a set one, so the second direction cannot
 * happen; the first still can (a plain store of a stale byte can still drop
 * the ORed bit) and the re-fire still covers it, and the re-fire is now
 * harmless to repeat.  This is the discipline LuaJIT's own profiler -- the one
 * sanctioned cross-thread writer of hookmask -- gets from a mutex it wraps
 * around both its RMW and the Lua thread's hook_enter/leave
 * (lj_profile.c:98-131); we cannot have that mutex, so we use the operation
 * that does not need one.  lj_trace_abort is deliberately not called: the
 * CHECKHOOK guard makes a trace recorded across the fire exit on its next
 * entry anyway.  lj_dispatch_update is still called, and still races the Lua
 * thread's own dispatch updates on trace start/stop; that tear is bounded by
 * the re-fire and by the recorder's next hot event, and is recorded.
 *
 * Only the Win32 timer-queue backend exists.  It is what this DLL is built
 * for; a pthread backend is a roadmap item, and a build for any other
 * platform refuses below rather than shipping an untested one. */

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#error "lj52 watchdog: only the Win32 timer-queue backend is implemented"
#endif

/* LuaJIT internals, for the one thing the timer thread must do without
 * lua_sethook: see lj52_wd_inject. */
#include "lj_obj.h"
#include "lj_dispatch.h"

#define LJ52_WD_REFIRE_MS 50            /* see THREADING above */
static const char LJ52_WD_KEY = 0;      /* registry slot for the armed fn */

/* Monotonic milliseconds, QueryPerformanceCounter-backed like the prototype. */
static double lj52_wd_now(void) {
  static LARGE_INTEGER freq;
  LARGE_INTEGER t;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}

/* The hook the timer installs.  Runs on the Lua thread, on the first
 * instruction after the trace exit.  callhook() has already reserved
 * 1+LUA_MINSTACK slots (lj_dispatch.c), so the push is safe, and an error
 * raised by fn propagates out of the hook exactly as it does from a Lua hook
 * installed by debug.sethook -- which is how "too long without yielding" has
 * always been raised. */
static void lj52_wd_hook(lua_State *L, lua_Debug *ar) {
  lj52_mem *M = lj52_memof(L);
  (void)ar;
  /* THE THREAD FILTER.  The hook is global and the timer thread cannot know
   * whether the sandbox is still running when it installs it.  If the fire
   * lands in the microseconds between the sandbox coroutine yielding and the
   * kernel reaching disarm(), the hook runs on the KERNEL's coroutine --
   * checkDeadline sees realTime past the deadline, raises inside main(), and
   * the machine crashes with "too long without yielding" although the sandbox
   * yielded on time.  OC's design excludes that crash (PUC hooks are per-
   * thread; the kernel thread has none).
   *
   * The predicate took three tries, and the two failures are worth keeping.
   *   (a) "fire only on the thread the arm is FOR" leaves a hole for any
   *       thread running sandbox code without an entry of its own -- a
   *       coroutine nested past LJ52_WD_MAXDEPTH gets none, so its fires
   *       matched nothing and it ran with no deadline at all.  Reproduced in
   *       adversarial review: 1500 ms under a 300 ms deadline, checkDeadline
   *       called zero times.
   *   (b) "skip only the thread that ARMED" closes that hole but breaks the
   *       case where the armer is itself what overruns -- which is every
   *       wd_test case, and W2 hung on it.
   * Both facts are needed, so both are recorded.  A fire is skipped only when
   * the running thread is a PARENT WAITING ON A CHILD: it armed one of the
   * live entries and is not the thread the top entry protects.  Then, and
   * only then, is the fire spurious -- its child has already returned and
   * disarm() is a few instructions away.  Everything else fires: the
   * protected thread itself, and any thread that armed nothing (the deep
   * nesting of (a)).  The count=1 hook stays set, harmless, until disarm()
   * clears it. */
  if (M != NULL && M->wd_depth > 0 && M->wd_for[M->wd_depth - 1] != L) {
    int i, armer = 0;
    for (i = 0; i < M->wd_depth; i++)
      if (M->wd_by[i] == L) { armer = 1; break; }
    if (armer) { M->wd_filtered++; return; }
  }
  lua_pushlightuserdata(L, (void *)&LJ52_WD_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isfunction(L, -1)) lua_call(L, 0, 0);
  else lua_pop(L, 1);
}

/* Install the count=1 hook FROM ANOTHER THREAD, without lua_sethook.
 * Order matters and x86-TSO keeps it: hookf and hookcount are in place
 * before the interpreter can see the count bit.  See THREADING above. */
static void lj52_wd_inject(lj52_mem *M) {
  global_State *g = G(M->L);
  g->hookf = lj52_wd_hook;
  g->hookcount = g->hookcstart = 1;
  __atomic_fetch_or(&g->hookmask, (uint8_t)LUA_MASKCOUNT, __ATOMIC_SEQ_CST);
  lj_dispatch_update(g, 0);
}

/* Timer callback: the ONLY thing that ever runs off the Lua thread. */
static VOID CALLBACK lj52_wd_fire(PVOID p, BOOLEAN timedOut) {
  lj52_mem *M = (lj52_mem *)p;
  (void)timedOut;
  if (!M->wd_fired) { M->wd_fired = 1; M->wd_fires++; } else M->wd_refires++;
  lj52_wd_inject(M);
}

/* Cancel the pending timer, waiting for an in-flight callback to finish. */
static void lj52_wd_cancel(lj52_mem *M) {
  if (M->wd_timer != NULL) {
    DeleteTimerQueueTimer(NULL, (HANDLE)M->wd_timer, INVALID_HANDLE_VALUE);
    M->wd_timer = NULL;
  }
}

/* Program the timer for the deadline at the top of the stack -- or, if that
 * deadline has already passed, install the hook right now, synchronously. */
static void lj52_wd_program(lj52_mem *M) {
  double remaining = M->wd_stack[M->wd_depth - 1] - lj52_wd_now();
  HANDLE h = NULL;
  M->wd_fired = 0;
  if (remaining <= 0.0) {
    lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1);
    return;
  }
  /* OC's computer.timeout has no upper bound (Settings.scala: `max 0`), and
   * an admin disabling the watchdog with a huge value would otherwise hand
   * CreateTimerQueueTimer a (DWORD) of an out-of-range double -- undefined,
   * and on x64 GCC typically 0: a timer that fires at once and leaves the
   * whole tick running under a count=1 hook.  Past what a DWORD of
   * milliseconds can express (~49 days) there is no deadline to enforce. */
  if (remaining >= 4294967000.0) return;
  /* +5 ms so that when checkDeadline reads computer.realTime() -- Java's
   * wall clock, not this counter -- the deadline it compares against has
   * genuinely passed.  If it had not, the count=1 hook would simply call
   * checkDeadline again on the next instruction, which is correct but slow. */
  /* Period LJ52_WD_REFIRE_MS, not WT_EXECUTEONLYONCE: the callback keeps
   * re-asserting the hook until disarm() cancels it.  See THREADING above. */
  if (!CreateTimerQueueTimer(&h, NULL, lj52_wd_fire, M,
                             (DWORD)(remaining + 5.0), LJ52_WD_REFIRE_MS, 0)) {
    /* No timer: fall back to the standing hook OC has always used.  The
     * machine is then slow rather than undefended. */
    lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1000);
    return;
  }
  M->wd_timer = (void *)h;
}

/* _OCLJ_WATCHDOG.arm(seconds, fn [, outermost [, protects]]) -> depth token.
 * `protects` is the thread about to be resumed; it defaults to the caller,
 * which is what a test (or any caller that arms for itself) wants. */
static int lj52_wd_arm(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  double secs = luaL_checknumber(L, 1);
  int outermost;
  lua_State *co;
  luaL_checktype(L, 2, LUA_TFUNCTION);
  outermost = lua_toboolean(L, 3);
  co = lua_isthread(L, 4) ? lua_tothread(L, 4) : L;
  if (M == NULL) return luaL_error(L, "watchdog: not an lj52 state");
  /* At the cap: push nothing, touch nothing, and hand back a token disarm()
   * will treat as a no-op.  The enclosing deadline stays live, which is what
   * a nested arm would have set anyway (the sandbox wrapper passes the same
   * `deadline`).  The first version of this function cancelled the live
   * timer and THEN raised -- so a sandbox nested past the cap whose pcall
   * swallowed the error ran with no deadline at all.  Found in adversarial
   * review.  Nothing here may fail after the cancel below. */
  if (!outermost && M->wd_depth >= LJ52_WD_MAXDEPTH) {
    lua_pushinteger(L, M->wd_depth + 1);
    return 1;
  }
  lj52_wd_cancel(M);
  if (outermost) {
    /* Heal whatever the last resume leaked: the stack, AND the hook.  A
     * skipped disarm leaves checkDeadline's count=1 re-arm in place, and a
     * new resume that started under it would run one hook call per
     * instruction until something cleared it.  OC's stock kernel is immune
     * by accident -- its next arm simply overwrites the hook.  Only the
     * OUTERMOST arm may do this: inside a nested arm that same re-arm is the
     * escalation a pcall-swallowing loop must not be allowed to escape.
     * (wd_test W8c, found the first time the healing was tested.) */
    M->wd_depth = 0;
    if (lua_gethook(L) != NULL) lua_sethook(L, NULL, 0, 0);
  }
  lua_pushlightuserdata(L, (void *)&LJ52_WD_KEY);
  lua_pushvalue(L, 2);
  lua_rawset(L, LUA_REGISTRYINDEX);
  M->wd_stack[M->wd_depth] = lj52_wd_now() + secs * 1000.0;
  M->wd_for[M->wd_depth] = co;
  M->wd_by[M->wd_depth] = L;
  M->wd_depth++;
  lj52_wd_program(M);
  lua_pushinteger(L, M->wd_depth);
  return 1;
}

/* _OCLJ_WATCHDOG.disarm([token])  -- restore the stack to BELOW the level arm
 * returned; with no token, pop one (the tests use that form). */
static int lj52_wd_disarm(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  int to;
  if (M == NULL) return 0;
  to = lua_isnoneornil(L, 1) ? M->wd_depth - 1 : (int)luaL_checkinteger(L, 1) - 1;
  if (to < 0) to = 0;
  lj52_wd_cancel(M);
  /* Clear ours AND checkDeadline's count=1 re-arm ("avoid gc issues", as the
   * kernel's own comment at the coroutine.resume site puts it).  Guarded so
   * the common case -- nothing armed, the resume simply yielded -- does not
   * pay lj_trace_abort + lj_dispatch_update on every return. */
  if (lua_gethook(L) != NULL) lua_sethook(L, NULL, 0, 0);
  /* A token deeper than the current stack means an outermost arm already
   * reset underneath us; there is nothing of ours left to remove. */
  if (to < M->wd_depth) M->wd_depth = to;
  if (M->wd_depth == 0) {
    lua_pushlightuserdata(L, (void *)&LJ52_WD_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
  } else {
    lj52_wd_program(M);
  }
  return 0;
}

/* _OCLJ_WATCHDOG.depth() -- for the tests and for diagnostics. */
static int lj52_wd_depth(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  lua_pushinteger(L, M ? M->wd_depth : -1);
  return 1;
}

/* _OCLJ_WATCHDOG.stats() -> fires, refires, filtered, depth, hooked
 * Read on the Lua thread at a quiet moment; the harness prints it after the
 * timeout probe so "the watchdog fired" is an observation with a number. */
static int lj52_wd_stats(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  lua_pushinteger(L, M ? M->wd_fires : -1);
  lua_pushinteger(L, M ? M->wd_refires : -1);
  lua_pushinteger(L, M ? M->wd_filtered : -1);
  lua_pushinteger(L, M ? M->wd_depth : -1);
  lua_pushboolean(L, lua_gethook(L) != NULL);
  return 5;
}

/* Installed by lj52_newstate as the raw global _OCLJ_WATCHDOG. */
static void lj52_wd_install(lua_State *L) {
  lua_createtable(L, 0, 2);
  lua_pushcclosure(L, lj52_wd_arm, 0);
  lua_setfield(L, -2, "arm");
  lua_pushcclosure(L, lj52_wd_disarm, 0);
  lua_setfield(L, -2, "disarm");
  lua_pushcclosure(L, lj52_wd_depth, 0);
  lua_setfield(L, -2, "depth");
  lua_pushcclosure(L, lj52_wd_stats, 0);
  lua_setfield(L, -2, "stats");
  lua_setglobal(L, "_OCLJ_WATCHDOG");
}

/* lua_close does not free the record, so we do -- after making sure no timer
 * callback can still arrive and hook a state that no longer exists. */
void lj52_close(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  if (M != NULL) lj52_wd_cancel(M);
  lua_close(L);
  free(M);
}

/* THE OTHER HALF OF THE MEMORY CHANGE, and it may not be separated from it.
 *
 * jnlua calls lua_pushcfunction(L, <something>_protected) at 38 sites, each of
 * them in a BARE JNI frame, before the lua_pcall that protects the real work.
 * On PUC 5.2 that pushes a light C function: a tagged pointer, no allocation,
 * cannot fail.  On LuaJIT there is no such type, so it builds a GCfunc -- and
 * the moment the cap above is genuinely enforced, that allocation can be
 * REFUSED, which raises LUA_ERRMEM with no protected frame anywhere below it.
 * On Win x64 (LJ_UNWIND_EXT) lj_err_throw then issues a RaiseException whose
 * handler lives in LuaJIT's own generated VM assembler -- reachable only if a
 * LuaJIT VM frame is on the machine stack, and in a bare JNI frame there is
 * none.  The exception finds no handler, the OS terminates the process, and
 * lua_atpanic is NEVER CALLED: the panic handler below cannot name this one on
 * the way down, which is why the failure is completely silent.  Enforcing the
 * cap without this is strictly worse than not enforcing it at all.
 *
 * The roadmap's plan was an EAGER warm-up: push all 38 once at newstate while
 * memory is plentiful.  It cannot be written -- the 38 targets are file-static
 * in jnlua.c, so lj52shim.c cannot name them, and the macro that could name
 * them expands at the push sites rather than at newstate.
 *
 * So the guarantee is bought a different and, as it turns out, better way:
 * inside this function the allocator CHARGES but never REFUSES.  Three
 * properties make that safe rather than a hole:
 *   - the overshoot is bounded by a compile-time constant.  The 38 sites push
 *     38 DISTINCT named statics, one apiece, so a state memoises at most 38
 *     GCfuncs (~1.5 KB with the memo table's growth).  Sandbox Lua cannot
 *     reach lua_pushcfunction and cannot add a 39th;
 *   - the bytes are still charged, so freeMemory stays honest and the machine
 *     simply runs over budget by that bounded amount, which the very next
 *     allocation refuses -- as a clean, catchable "not enough memory", at a
 *     point where a protected frame exists;
 *   - it covers the WHOLE body, not just the cold push, and that is load-
 *     bearing rather than cautious.  On GC64 lua_pushlightuserdata INTERNS the
 *     pointer's segment, and that path calls lj_mem_reallocvec
 *     (lj_udata.c:38-58, lj_lightud_intern) -- so even the warm lookup, whose
 *     whole point is that it allocates nothing, pushes a light userdata key
 *     that can.  lua_rawset can grow the memo table, and every lua_push* ends
 *     in incr_top.
 *
 * For the record, the one hazard that turned out NOT to exist: checkstack().
 * jnlua guards all 38 sites with it, and LuaJIT's lua_checkstack grows the
 * stack through lj_state_cpgrowstack -- a PROTECTED call -- and returns 0 on
 * failure (lj_api.c) rather than throwing.  jnlua converts that to a Java
 * IllegalStateException.  lua_pushcfunction is the only UNCONDITIONAL
 * bare-frame LUA_ERRMEM source in
 * jnlua.c.  lua_1load and lua_1setmetatable are the only other entry points
 * touching the Lua API unprotected, and both are safe -- lua_load returns its
 * status, lua_setmetatable does not allocate.  One conditional site remains,
 * named here rather than rounded away: throw() (jnlua.c:2356-2368) calls
 * lua_tostring in a bare frame when throw_protected itself failed, and
 * stringifying a NON-string error value allocates.  It does not bite on the
 * path that matters, because LuaJIT preallocates and GC-fixes the "not enough
 * memory" message at state creation (lj_state.c:202), so lua_tostring on an
 * ERRMEM object is a no-op; it could only bite on something like error(42)
 * raised exactly at the wall.  Not covered by the window. */
void lj52_pushcfunction(lua_State *L, lua_CFunction f) {
  lj52_mem *M = lj52_memof(L);
  if (M != NULL) M->norefuse++;
  lj52_pushcfunction_raw(L, f);
  if (M != NULL) M->norefuse--;
}

/* ================================================================== *
 * state creation
 * ================================================================== */

/* An unprotected Lua error inside a JNI frame otherwise aborts the process
 * with no diagnostic at all; at least name it on the way down. */
static int lj52_panic(lua_State *L) {
  const char *s = lua_tostring(L, -1);
  fputs("LJ52 PANIC: unprotected error in call to Lua API (", stderr);
  fputs(s ? s : "?", stderr);
  fputs(")\n", stderr);
  fflush(stderr);
  return 0;
}

lua_State *lj52_newstate(void) {
  /* The state is born on OUR allocator, with a per-state accounting record as
   * its ud, and that pairing is never changed again -- see the memory
   * accounting section above, and the "allocator ownership" comment in
   * lj52shim.h for why the state cannot use LuaJIT's own lj_alloc. */
  lj52_mem *M = (lj52_mem *)calloc(1, sizeof(lj52_mem));
  lua_State *L = M ? lua_newstate(lj52_alloc, M) : NULL;
  if (!L) {
    free(M);
    M = NULL;
    /* Non-GC64 LuaJIT refuses a foreign allocator on x64. build-native.sh
     * gates on this at stage 1b, so reaching here means someone linked a
     * different libluajit.a. Fall back so the failure shows up as a
     * crash-on-close rather than a silent NULL. */
    L = luaL_newstate();
    if (!L) return NULL;
  }
  if (M != NULL) M->L = L;               /* the watchdog hooks this thread */
  lua_atpanic(L, lj52_panic);

  /* --- 5.2 registry layout -------------------------------------------
   * 5.2 keeps the main thread at registry[LUA_RIDX_MAINTHREAD == 1] and the
   * globals table at registry[LUA_RIDX_GLOBALS == 2]. LuaJIT keeps neither:
   * it has LUA_GLOBALSINDEX instead. JNLua's LuaState.register(module, fns,
   * global=true) does rawGet(REGISTRYINDEX, RIDX_GLOBALS) followed by
   * setField, so on an unseeded LuaJIT registry it would index nil.
   * Neither OC nor ocelot-brain calls register() today, so this is latent
   * rather than load-bearing -- but it is one of the 5.2 invariants a caller
   * is entitled to assume, and seeding it costs two stores at startup.
   * Side effect worth knowing: luaL_ref numbers references from
   * lua_objlen(registry)+1, so refs now start at 4 instead of 1, exactly as
   * they do on 5.2 (which starts at 3). Nothing persists a raw ref number
   * across a state, so this is safe. */
  lua_pushthread(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, 1);
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  lua_rawseti(L, LUA_REGISTRYINDEX, 2);

  /* registry[3] = the lua_pushcfunction memo table (LJ52_CF_RIDX).
   * Sized for its final population up front -- jnlua pushes 38 distinct C
   * functions and nothing can add a 39th -- so no cold push ever has to rehash
   * the node array.  That matters because a cold push runs in a bare JNI
   * frame: every allocation removed from that path is one fewer thing the
   * no-refuse window in lj52_pushcfunction has to cover. */
  lua_createtable(L, 0, 64);
  lua_rawseti(L, LUA_REGISTRYINDEX, LJ52_CF_RIDX);

  /* Pre-intern a light userdata from this DLL's own address range, for the
   * same reason.  On GC64 lua_pushlightuserdata does not just tag a pointer:
   * lj_lightud_intern (lj_udata.c:38-58) looks the pointer's 512 GB segment up
   * in a segment map and lj_mem_reallocvec's that map when it sees a new one.
   * Every memo key is a C function pointer inside this image, so interning one
   * address from the image here -- while memory is plentiful and no JNI frame
   * is waiting -- means later pushes find the segment already present. */
  lua_pushlightuserdata(L, (void *)&LJ52_LIGHTUD_SEED);
  lua_pop(L, 1);

  /* The VM helper chunk used by lua_compare / lua_arith / lua_len. Built
   * eagerly so those three never have to compile anything on a hot path. */
  lj52_installhelpers(L);

  /* --- turn the JIT on ------------------------------------------------
   * LuaJIT only sets JIT_F_ON inside luaopen_jit, and jnlua never opens the
   * jit library (5.2 has no such library to open). Without this the state
   * runs interpreter-only and the entire point of the exercise is lost.
   * pcall'd because a failure here must degrade to interpreter mode, not
   * take the JVM down; the outcome is recorded in _OCLJ_JIT so a harness can
   * assert on it.
   *
   * NOTE the nresults=0. luaopen_jit installs the global `jit` table ITSELF
   * (LJ_LIB_REG -> lj_lib_register, which writes _LOADED.jit and the global),
   * and its `return 1` does NOT describe the top of the stack: lib_jit.c
   * pushes four scratch values for use as upvalues, registers jit and jit.opt,
   * and then does `L->top -= 2`, so what a caller sees on top is a leftover
   * STRING. The base variant of this shim took that value and did
   * lua_setglobal(L, "jit") with it, clobbering the freshly registered jit
   * table with the string "x64" -- measured: `jit` was type string, not table.
   * The JIT itself was still on (jit_init runs first), which is why it went
   * unnoticed, but jit.on/jit.off/jit.status were unreachable from Lua.
   * Asking for zero results and letting the opener do its own registration is
   * both correct and simpler. */
  lua_pushcclosure(L, luaopen_jit, 0);
  lua_pushliteral(L, LUA_JITLIBNAME);
  if (lua_pcall(L, 1, 0, 0) == 0) {
    lua_pushliteral(L, "ok");
  } else {
    /* pcall pushed the error message even with nresults == 0. */
    lua_pushfstring(L, "luaopen_jit failed: %s", lua_tostring(L, -1));
    lua_remove(L, -2);
  }
  lua_setglobal(L, "_OCLJ_JIT");

  /* An unfakeable marker that this state came from the LuaJIT-backed native.
   * ocelot-brain sets includeLuaJ = !isAvailable, so a failed native load
   * SILENTLY substitutes LuaJ -- which has no Eris, so every persistence test
   * then passes vacuously. Any harness that claims a result must read this
   * global out of the live state and refuse to report a pass without it. */
  lua_pushliteral(L, "luajit/" LUAJIT_VERSION);
  lua_setglobal(L, "_OCLJ_NATIVE");

  /* _OCLJ_WATCHDOG -- the kernel's replacement for its standing count hook.
   * A raw global like _OCLJ_NATIVE: the sandbox never sees it, and being
   * reachable from _G makes it a permanent for the serializer. */
  lj52_wd_install(L);
  return L;
}

/* ================================================================== *
 * index / length / comparison
 * ================================================================== */

int lua_absindex(lua_State *L, int idx) {
  /* Same shape as 5.2's lua_absindex. On LuaJIT every pseudo-index
   * (LUA_REGISTRYINDEX, LUA_ENVIRONINDEX, LUA_GLOBALSINDEX and the upvalue
   * indices) is <= LUA_REGISTRYINDEX, so 5.2's test transfers unchanged.
   * Using LUA_GLOBALSINDEX as the floor instead would mangle
   * LUA_REGISTRYINDEX, which is more negative. */
  return (idx > 0 || idx <= LUA_REGISTRYINDEX) ? idx : lua_gettop(L) + idx + 1;
}

size_t lua_rawlen(lua_State *L, int idx) {
  /* 5.2's lua_rawlen is 5.1's lua_objlen: raw length, no __len. */
  return lua_objlen(L, idx);
}

int lua_compare(lua_State *L, int idx1, int idx2, int op) {
  int r;
  /* THE __le FIX. -----------------------------------------------------
   * The obvious 5.1 spelling for LUA_OPLE is `!lua_lessthan(L, idx2, idx1)`,
   * because 5.1 itself implements `a <= b` as `not (b < a)` when there is no
   * __le. That is wrong on 5.2 in three distinct ways, all measured against
   * this LuaJIT build with a differential harness (see AUDIT/le_test.c):
   *   - on a metatable defining ONLY __le, the fallback looks up a __lt that
   *     is not there and RAISES "attempt to compare two table values", both
   *     when __le would return true and when it would return false;
   *   - with __le and __lt both present and both returning true, the fallback
   *     returns FALSE where 5.2 returns TRUE;
   *   - it fires the WRONG metamethod: __lt once, __le never.
   * A third spelling seen in sibling variants, `lua_lessthan(a,b) ||
   * lua_equal(a,b)`, is wrong the same way and additionally fires __eq.
   * Routing through the VM's own `<=` gets all of it right for free, because
   * LUAJIT_ENABLE_LUA52COMPAT already makes the VM use 5.2's __le rules.
   * (Nothing in OC or ocelot-brain calls LuaState.compare today, so this was
   * latent rather than a live regression -- but it is a wrong 5.2 surface and
   * costs nothing to get right.) */
  idx1 = lua_absindex(L, idx1);
  idx2 = lua_absindex(L, idx2);
  lj52_gethelper(L, "cmp");
  lua_pushinteger(L, op);
  lua_pushvalue(L, idx1);
  lua_pushvalue(L, idx2);
  lua_call(L, 3, 1);
  r = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return r;
}

void lua_arith(lua_State *L, int op) {
  /* 5.2: pops the operands (2, or 1 for LUA_OPUNM) and pushes the result,
   * honouring the arithmetic metamethods. Routed through the VM for the same
   * reason as lua_compare. */
  int nargs = (op == LUA_OPUNM) ? 1 : 2;
  int base  = lua_gettop(L) - nargs + 1;   /* index of the first operand */
  lj52_gethelper(L, "arith");              /* a [b] f  */
  lua_insert(L, base);                     /* f a [b]  */
  lua_pushinteger(L, op);                  /* f a [b] op */
  lua_insert(L, base + 1);                 /* f op a [b] */
  lua_call(L, nargs + 1, 1);
}

void lua_len(lua_State *L, int idx) {
  /* 5.2's lua_len honours __len on tables as well as strings; 5.1's
   * lua_objlen does not. `#x` in a LUA52COMPAT VM does. */
  idx = lua_absindex(L, idx);
  lj52_gethelper(L, "len");
  lua_pushvalue(L, idx);
  lua_call(L, 1, 1);
}

/* ================================================================== *
 * unsigned accessors
 * ================================================================== */

/* LuaJIT has no integer subtype: every number is a double. 5.2's
 * lua_pushunsigned/lua_tounsigned are exact for the whole 32-bit range a
 * double can represent, which is the entire domain of lua_Unsigned, so these
 * are exact rather than merely practical. */
void lua_pushunsigned(lua_State *L, lua_Unsigned n) {
  lua_pushnumber(L, (lua_Number)n);
}

lua_Unsigned lua_tounsigned(lua_State *L, int idx) {
  /* 5.2 converts modulo 2^32 (luaconf.h's lua_number2unsigned). Doing the
   * reduction in floating point first avoids the undefined behaviour of
   * casting an out-of-range double straight to an integer type. */
  double d = (double)lua_tonumber(L, idx);
  if (!(d > -9.0e18 && d < 9.0e18)) return 0;   /* NaN / inf / absurd */
  d = d - floor(d / 4294967296.0) * 4294967296.0;
  return (lua_Unsigned)(unsigned long long)d;
}

/* ================================================================== *
 * luaL_getsubtable / luaL_requiref / luaL_tolstring
 * ================================================================== */

int luaL_getsubtable(lua_State *L, int idx, const char *fname) {
  idx = lua_absindex(L, idx);
  lua_getfield(L, idx, fname);
  if (lua_istable(L, -1)) return 1;             /* already there */
  lua_pop(L, 1);
  lua_newtable(L);
  lua_pushvalue(L, -1);
  lua_setfield(L, idx, fname);
  return 0;
}

void luaL_requiref(lua_State *L, const char *modname, lua_CFunction openf, int glb) {
  /* 5.2's luaL_requiref consults package.loaded first and only calls openf if
   * the module is not already there; several sibling variants always called
   * openf, which re-runs a library opener and discards the previous module
   * table (so anything that had already been stored into it is lost). */
  luaL_getsubtable(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_getfield(L, -1, modname);
  if (!lua_toboolean(L, -1)) {
    lua_pop(L, 1);
    lua_pushcclosure(L, openf, 0);
    lua_pushstring(L, modname);
    lua_call(L, 1, 1);
    lua_pushvalue(L, -1);
    lua_setfield(L, -3, modname);
  }
  if (glb) {
    lua_pushvalue(L, -1);
    lua_setglobal(L, modname);
  }
  lua_replace(L, -2);   /* drop _LOADED, leave the module on top */
}

const char *luaL_tolstring(lua_State *L, int idx, size_t *len) {
  idx = lua_absindex(L, idx);
  if (luaL_callmeta(L, idx, "__tostring")) {
    if (!lua_isstring(L, -1)) luaL_error(L, "'__tostring' must return a string");
  } else {
    switch (lua_type(L, idx)) {
      case LUA_TNUMBER:
      case LUA_TSTRING:
        lua_pushvalue(L, idx);
        break;
      case LUA_TBOOLEAN:
        lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false");
        break;
      case LUA_TNIL:
        lua_pushliteral(L, "nil");
        break;
      default:
        lua_pushfstring(L, "%s: %p", luaL_typename(L, idx), lua_topointer(L, idx));
        break;
    }
  }
  return lua_tolstring(L, -1, len);
}

/* ================================================================== *
 * resume
 * ================================================================== */

int lj52_resume(lua_State *L, lua_State *from, int nargs) {
  (void)from;
  return lua_resume(L, nargs);
}

/* ================================================================== *
 * coroutine
 * ================================================================== */

int luaopen_coroutine(lua_State *L) {
  /* 5.2 splits the coroutine library out of the base library and gives it its
   * own opener. LuaJIT's luaopen_base already registers the global
   * `coroutine` table, and OC always opens BASE before COROUTINE
   * (LuaStateFactory.openLibs), so the right answer is to hand back the table
   * that already exists rather than build a second one. */
  lua_getglobal(L, LUA_COLIBNAME);
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
  }
  return 1;
}

/* ================================================================== *
 * bit32 -- Lua 5.2 semantics
 * ================================================================== */

/* This is a real 5.2 bit32, NOT an alias for LuaJIT's luaopen_bit. Two
 * sibling variants defined luaopen_bit32 as luaopen_bit; that is wrong
 * because BitOp returns SIGNED 32-bit results (bit.bnot(0) == -1) whereas
 * 5.2's bit32 returns unsigned ones (bit32.bnot(0) == 4294967295), and OpenOS
 * arithmetic on the result then differs. */

#define B32MASK 0xFFFFFFFFu

static unsigned int b32arg(lua_State *L, int i) {
  /* 5.2: "the given argument is converted to an integer modulo 2^32". The
   * base variant of this shim did `(unsigned)((long long)d & 0xFFFFFFFF)`,
   * which TRUNCATES toward zero before masking -- so it disagrees with 5.2
   * for any argument with a fractional part (-3.5 becomes -3, not -4) and is
   * undefined for |d| >= 2^63. The floating-point floor-modulo below is
   * 5.2's actual definition and has neither problem. */
  double d = (double)luaL_checknumber(L, i);
  if (!(d > -9.0e18 && d < 9.0e18)) return 0;   /* NaN / inf */
  d = d - floor(d / 4294967296.0) * 4294967296.0;
  return (unsigned int)(unsigned long long)d;
}

static int b32_band(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = B32MASK;
  for (i = 1; i <= n; i++) r &= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_bor(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = 0;
  for (i = 1; i <= n; i++) r |= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_bxor(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = 0;
  for (i = 1; i <= n; i++) r ^= b32arg(L, i);
  lua_pushnumber(L, (lua_Number)r);
  return 1;
}
static int b32_btest(lua_State *L) {
  int n = lua_gettop(L), i;
  unsigned int r = B32MASK;
  for (i = 1; i <= n; i++) r &= b32arg(L, i);
  lua_pushboolean(L, r != 0);
  return 1;
}
static int b32_bnot(lua_State *L) {
  lua_pushnumber(L, (lua_Number)(~b32arg(L, 1) & B32MASK));
  return 1;
}

/* 5.2's shifts are logical, saturate to 0 past 32 bits, and treat a negative
 * displacement as a shift in the other direction. */
static int b32_lshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) { i = -i; res = (i >= 32) ? 0 : ((r >> i) & B32MASK); }
  else       { res = (i >= 32) ? 0 : ((r << i) & B32MASK); }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_rshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) { i = -i; res = (i >= 32) ? 0 : ((r << i) & B32MASK); }
  else       { res = (i >= 32) ? 0 : ((r >> i) & B32MASK); }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_arshift(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2);
  unsigned int res;
  if (i < 0) {                       /* negative displacement: shift left */
    i = -i;
    res = (i >= 32) ? 0 : ((r << i) & B32MASK);
  } else {
    int neg = (r & 0x80000000u) != 0;
    if (i >= 32) res = neg ? B32MASK : 0;
    else if (i == 0) res = r;
    else {
      res = r >> i;
      if (neg) res |= (B32MASK << (32 - i)) & B32MASK;
    }
  }
  lua_pushnumber(L, (lua_Number)res);
  return 1;
}
static int b32_lrotate(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2) & 31;
  lua_pushnumber(L, (lua_Number)(((r << i) | (r >> ((32 - i) & 31))) & B32MASK));
  return 1;
}
static int b32_rrotate(lua_State *L) {
  unsigned int r = b32arg(L, 1);
  int i = (int)luaL_checknumber(L, 2) & 31;
  lua_pushnumber(L, (lua_Number)(((r >> i) | (r << ((32 - i) & 31))) & B32MASK));
  return 1;
}

/* 5.2's exact argument-error messages for the field accessors, so a Lua-side
 * pcall that matches on them behaves the same as on PUC 5.2. */
static int b32field(lua_State *L, int i, int *width) {
  int f = (int)luaL_checknumber(L, i);
  int w = (int)luaL_optnumber(L, i + 1, 1);
  luaL_argcheck(L, 0 <= f, i, "field cannot be negative");
  luaL_argcheck(L, 0 < w, i + 1, "width must be positive");
  if (f + w > 32) luaL_error(L, "trying to access non-existent bits");
  *width = w;
  return f;
}
static int b32_extract(lua_State *L) {
  int w;
  unsigned int v = b32arg(L, 1);
  int f = b32field(L, 2, &w);
  lua_pushnumber(L, (lua_Number)((v >> f) & (B32MASK >> (32 - w))));
  return 1;
}
static int b32_replace(lua_State *L) {
  int w;
  unsigned int v = b32arg(L, 1);
  unsigned int r = b32arg(L, 2);
  int f = b32field(L, 3, &w);
  unsigned int m = B32MASK >> (32 - w);
  lua_pushnumber(L, (lua_Number)(((v & ~(m << f)) | ((r & m) << f)) & B32MASK));
  return 1;
}

static const luaL_Reg bit32lib[] = {
  {"arshift", b32_arshift}, {"band",    b32_band},    {"bnot",    b32_bnot},
  {"bor",     b32_bor},     {"bxor",    b32_bxor},    {"btest",   b32_btest},
  {"extract", b32_extract}, {"lrotate", b32_lrotate}, {"lshift",  b32_lshift},
  {"replace", b32_replace}, {"rrotate", b32_rrotate}, {"rshift",  b32_rshift},
  {NULL, NULL}
};

int luaopen_bit32(lua_State *L) {
  /* lua_newtable + luaL_register(L, NULL, ...) and NOT
   * luaL_register(L, LUA_BITLIBNAME, ...): the latter also creates a global
   * named "bit32" as a side effect. jnlua reaches this through
   * luaL_requiref(L, LUA_BITLIBNAME, luaopen_bit32, glb), which is the code
   * that gets to decide whether a global is created. */
  lua_newtable(L);
  luaL_register(L, NULL, bit32lib);
  return 1;
}

/* ================================================================== *
 * eris
 * ================================================================== */

int luaopen_eris(lua_State *L) {
  /* jnlua.c's openlib case for ERIS is
   *     luaL_requiref(L, LUA_ERISLIBNAME, luaopen_eris, 1)
   * -- one name, one opener, no other eris-specific constant anywhere in
   * jnlua.c. Our serializer's luaopen_eris_lj leaves the module table on the
   * stack exactly as requiref needs. */
  int n = luaopen_eris_lj(L);

  /* _VERSION. OC's platform is 5.2 source and the harness fingerprint reads
   * this out of the live state. It has to be set HERE rather than in
   * lj52_newstate for an ordering reason that is easy to get wrong:
   * LuaStateFactory.openLibs opens BASE first, and LuaJIT's luaopen_base
   * assigns _VERSION = "Lua 5.1", clobbering anything set at state creation.
   * ERIS is opened after BASE (BASE, BIT32, COROUTINE, DEBUG, ERIS, ...), so
   * this is the last opener that can win.
   * The string must not contain "5.3" or "5.4": machine.lua:65-66 pattern-
   * matches _VERSION to decide which Lua dialect it is running on, and
   * machine.lua:812 derives the sandbox's own _VERSION from it. */
  lua_pushliteral(L, "Lua+Eris 5.2");
  lua_setglobal(L, "_VERSION");
  return n;
}
