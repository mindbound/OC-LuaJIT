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
/* The Linux watchdog backend calls pthread_setname_np, which glibc guards with
 * __USE_GNU.  _GNU_SOURCE only WIDENS declarations, and this file calls none of
 * the functions whose SEMANTICS it changes (strerror_r, basename, qsort_r).
 * Do not reach for _POSIX_C_SOURCE instead: setting it explicitly suppresses
 * glibc's default _DEFAULT_SOURCE and would hide pthread_setname_np again,
 * turning build-native.sh's zero-warning gate into an implicit-declaration
 * failure. */
#if !defined(_WIN32) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* THE WATCHDOG BACKEND IS SELECTED HERE, far above the THREADING comment that
 * explains it, for one mechanical reason: lj52_mem carries a pthread_mutex_t
 * and a pthread_cond_t BY VALUE and is declared a little below.  windows.h is
 * deliberately NOT hoisted with this -- it stays down at the THREADING comment,
 * so the shipping Windows translation unit is unaffected by this change. */
#if defined(_WIN32)
#define LJ52_WD_WIN32 1
#elif defined(__linux__)
#define LJ52_WD_PTHREAD 1
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#else
/* NOT "POSIX", and the distinction is load-bearing: pthread_condattr_setclock
 * is POSIX clock-selection and macOS does not have it, so a Darwin build would
 * have to put the deadline condvar on CLOCK_REALTIME and silently inherit an
 * NTP-step hazard on a LIVE deadline.  A third backend is the honest answer
 * there; refusing is the honest answer until someone can build and test one.
 * This #error has narrowed, not vanished -- do not delete it as an oversight. */
#error "lj52 watchdog: only the Win32 and Linux backends exist (macOS needs its own)"
#endif

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
  double        wd_due;     /* ABSOLUTE ms of the next fire; 0 == disarmed.  */
#if defined(LJ52_WD_PTHREAD)
  /* THE OWNERSHIP RULE, and it must not be lost: wd_mtx is a LEAF.  Nothing
   * else may be acquired while it is held, and NO LUA API CALL may be made
   * while it is held.  The timer thread holds it across lj52_wd_inject, which
   * is what makes lj52_wd_cancel block; a Lua call underneath it would invite
   * the allocator, and the allocator is lj52_alloc, which touches this same
   * record. */
  pthread_t       wd_thread;
  pthread_mutex_t wd_mtx;
  pthread_cond_t  wd_cv;     /* CLOCK_MONOTONIC -- see lj52_wd_start          */
  double          wd_wake;   /* when the thread's CURRENT sleep ends; 0 ==    */
                             /* parked indefinitely.  Thread writes, Lua      */
                             /* thread reads to decide whether to signal.     */
  int             wd_started;/* mutex + cond + thread all exist               */
  int             wd_quit;   /* teardown: the thread must return              */
#else
  void         *wd_timer;   /* pending Win32 timer-queue timer, or NULL      */
#endif
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
  /* The reliability instrument, on BOTH backends, because the Win32 one has an
   * open finding against it (fires=0 in 2 of ~6 runs under host load) and
   * "is this backend better" has to be answerable with a number. */
  volatile int  wd_degraded; /* last program() fell back to the standing hook */
  /* -- the emergency collector; see lj52_gc_pressure below -- */
  int           gc_armed;      /* a cycle has been demanded, not yet proven   */
  int           gc_busy;       /* re-entrancy guard; see the note below       */
  /* Fixed-width C types, not LuaJIT's: lj_obj.h is included ~300 lines BELOW
   * this struct, so MSize and friends are not in scope here.  These mirror
   * gc.stepmul (MSize, lj_obj.h:614) and gc.currentwhite (uint8_t, :597). */
  uint32_t      gc_savedmul;   /* gc.stepmul to put back when we disarm       */
  uint8_t       gc_white;      /* gc.currentwhite latched at arm time         */
  unsigned      gc_armedcalls; /* allocator calls since arming -- the bailout */
  volatile long gc_arms;       /* diagnostics, for a human and for the tests  */
  volatile long gc_collects;   /* arms that were PROVEN to complete a cycle   */
  volatile long gc_bailouts;   /* arms abandoned by the safety valve          */
  volatile long gc_refusals;   /* allocations refused -> lj_err_mem           */
} lj52_mem;

static void *lj52_alloc(void *ud, void *ptr, size_t osize, size_t nsize);
/* Defined below the LuaJIT-internal includes -- it needs G(), LJ_MAX_MEM and
 * HOOK_GC -- but called from lj52_alloc, which is above them. */
static void lj52_gc_pressure(lj52_mem *M, long long total, long long used);

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
    /* BEFORE the free, not after: a free is the one call that can take us back
     * under the watermark, and the disarm check wants to see the heap as the
     * VM will see it at the next safepoint. */
    lj52_gc_pressure(M, total, used + delta);
    free(ptr);
    M->setmem(env, obj, lj52_clampi(used + delta));
    return NULL;
  }
  if (!(total <= 0 || delta <= 0 || total - used >= delta || M->norefuse)) {
    /* We are at the wall.  We still do not collect here -- C1/C5/C6 -- but an
     * arm costs nothing and the next safepoint may yet save the machine if
     * this refusal is survivable.  A refusal with gc_arms == 0 means the
     * trip-wire never fired and is a bug here, not a volume failure. */
    M->gc_refusals++;
    lj52_gc_pressure(M, total, used);
    return NULL;                        /* -> lj_err_mem -> LUA_ERRMEM */
  }
  p = realloc(ptr, nsize);
  if (p != NULL) {
    M->setmem(env, obj, lj52_clampi(used + delta));
    lj52_gc_pressure(M, total, used + delta);
  }
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
 * TWO BACKENDS IMPLEMENT THIS, and everything above is common to both: the
 * rule that the timer thread never calls lua_sethook, the store-then-atomic-OR
 * in lj52_wd_inject, and the periodic re-fire that covers a dropped bit.  Only
 * the CLOCK and the TIMER differ.  Win32 uses a timer-queue timer; Linux parks
 * one thread per machine in pthread_cond_timedwait on a CLOCK_MONOTONIC
 * condvar, where the mutex that thread holds across lj52_wd_inject IS the
 * blocking cancel.  macOS has neither and gets an #error until someone can
 * build and test a third. */

#ifdef LJ52_WD_WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

/* LuaJIT internals, for the one thing the timer thread must do without
 * lua_sethook: see lj52_wd_inject. */
#include "lj_obj.h"
#include "lj_dispatch.h"
#include "lj_jit.h"

/* ===================================================================== */
/* THE EMERGENCY COLLECTOR.                                              */
/* ===================================================================== */
/*
 * WHAT IT IS FOR.  PUC Lua's luaM_realloc_ runs luaC_fullgc(L, 1) and RETRIES
 * when the allocator refuses; LuaJIT's lj_mem_realloc calls lj_err_mem on the
 * first refusal and the machine dies.  Measured (memory-accounting.md 8c):
 * `sieve` completes on PUC 3/3 and dies on ours 6/6 in a 3072 real-KB machine
 * whose LIVE SET is 52.4 KB -- over 98% garbage at the moment of refusal.
 *
 * WHY THIS DOES NOT COLLECT AT THE REFUSAL.  Three verified constraints each
 * independently forbid it (memory-accounting.md 11):
 *   C1  lj_gc_fullgc's loop (lj_gc.c:800) runs on gc.state, and GCSatomic
 *       returns LJ_MAX_MEM WITHOUT advancing state while tvref(g->jit_base) is
 *       set (:673-677).  :799 forces GCSpause first, so an on-trace call hangs
 *       unconditionally -- not as a race.
 *   C5  a collect at lj_tab.c:123-124 frees the table under construction:
 *       unreachable, current-white, already rooted.
 *   C6  L->top is stale at arbitrary allocation points, and from
 *       lj_mem_newgco the object is partially initialised AND already rooted
 *       and whitened (lj_gc.c:893-895).
 * So the allocator still never collects.  It writes two scalars the VM already
 * owns and lets the VM collect at a point the VM already considers safe.
 *
 * THE TWO CARRIERS, both the VM's own idioms.
 *   g->gc.threshold = g->gc.total  is "collect at the very next checkpoint":
 *       ~49 lj_gc_check sites, lj_meta.c:382, the interpreter's inline compares
 *       and the JIT's asm_gc_check all test total >= threshold and CALL the
 *       collector.  It is exactly what lj_gc.c:753 and lj_api.c:1252 write.
 *   g->gc.stepmul = 0  makes that step UNBOUNDED: lj_gc.c:734-736 turns a zero
 *       stepmul into lim = LJ_MAX_MEM, and the loop at :739-746 then runs to
 *       GCSpause.  A whole cycle, not a 2000-unit slice.
 *
 * WRITE gc.total, NEVER 0.  lj_gc.c:737-738 charges
 *     if (total > threshold) debt += total - threshold
 * at the entry of the armed step.  With 0 that is the WHOLE HEAP as debt; it
 * survives any step that does not reach GCSpause -- i.e. every on-trace bail
 * through the LJ_MAX_MEM sentinel -- and then :751-755 pins threshold = total
 * and repays 1024 bytes per step for thousands of steps.  Invisible in a
 * pass/fail benchmark; it would surface as an unexplained throughput
 * regression on the JIT-ON path.  With gc.total the charge is exactly zero.
 *
 * GCSpause IS NOT EVIDENCE THAT A CYCLE RAN, which is why we latch the white.
 * gc_onestep reaches GCSpause from GCSsweep (:700, "skip this phase to help
 * the JIT") and from GCSfinalize (:719) WITHOUT ever calling atomic().  Since
 * the whole finding of section 8 is that the collector is chronically behind,
 * mid-sweep is the NORMAL state to arm from -- so disarming on GCSpause alone
 * would credit a tail-of-sweep that re-marked nothing.  atomic() flips
 * g->gc.currentwhite at lj_gc.c:654 and is its only writer in normal operation
 * (:612 is freeall teardown, lj_state.c:282 is state init).  So
 * "currentwhite changed AND state == GCSpause" is an exact
 * mark-plus-atomic-plus-sweep-completed predicate.
 *
 * Compare the whole byte for inequality on purpose: pulling in lj_gc.h for
 * LJ_GC_WHITES would drag lj_gc_step/lj_gc_fullgc declarations into this
 * file's scope, which is the very thing build-native.sh's gate forbids.
 *
 * THE WATERMARK IS FIXED, AND DELIBERATELY SO.  total/4, floor 128 KB.  The
 * quantity it must cover is the largest allocation burst between two
 * safepoints, and lj_tab_resize grows the array part with lj_mem_realloc
 * (lj_tab.c:249) rather than alloc-new-then-free-old, so the positive deltas
 * telescope to the FINAL array size -- 64 KB per repetition for `sieve` at
 * N=8192, matching 8c's measurement, 512 KB at N=65536.  768 KB on a 3072-KB
 * machine covers all of them with margin.  An earlier design learned this
 * watermark at runtime; that was deleted, because the proxy available inside
 * the allocator measures the collector's RUN rate, not safepoint density, and
 * cannot observe the quantity its own correctness condition names.
 *
 * WHAT THIS BUYS, AND WHAT IT DOES NOT.  The survival condition becomes
 *     live + largest inter-safepoint burst  <=  cap
 * where PUC's is
 *     live + largest single allocation      <=  cap.
 * The gap is real and irreducible without a finer safepoint, which would
 * reintroduce C5 and C6.  This narrows the divergence; it does not close it.
 */

#define LJ52_GC_WMIN   (128 * 1024)     /* watermark floor                   */
#define LJ52_GC_ARMCAP (1 << 16)        /* allocator calls before we give up */

/* GCSpause, WITHOUT including lj_gc.h.
 *
 * The collector-state enum is lj_gc.h:11-14, and GCSpause is its first member,
 * so its value is 0.  We do not include that header to say so, because it also
 * declares lj_gc_step and lj_gc_fullgc -- and bringing those into this file's
 * scope is precisely what build-native.sh's collector gate forbids.  The
 * alternative, spelling the constant here, moves the risk from "the shim can
 * call the collector" to "the enum could be reordered", which is the smaller
 * risk and, unlike the other one, is CHECKABLE AT BUILD TIME: build-native.sh
 * asserts the enum still begins with GCSpause.  The enum's own comment reads
 * "Order matters." */
#define LJ52_GCS_PAUSE 0

static void lj52_gc_pressure(lj52_mem *M, long long total, long long used)
{
  global_State *g;
  long long headroom, w;

  /* gc_busy guards nothing today -- this function calls nothing that can
   * re-enter the allocator, it only reads and writes scalars.  It is here so
   * that the day someone adds a call, the guard is already in place rather
   * than being the thing they forgot. */
  if (M->gc_busy || M->norefuse > 0 || M->L == NULL || total <= 0) return;
  M->gc_busy = 1;
  g = G(M->L);

  /* Two states where the VM owns gc.threshold and we must not touch it:
   * inside a finalizer (gc_call_finalizer sets HOOK_GC at lj_gc.c:514 and
   * parks threshold at LJ_MAX_MEM at :516), and after a host lua_gc(GCSTOP),
   * which OC does around persistence. */
  if ((g->hookmask & HOOK_GC) || g->gc.threshold == LJ_MAX_MEM) {
    M->gc_busy = 0;
    return;
  }

  if (M->gc_armed) {
    if (g->gc.currentwhite != M->gc_white && g->gc.state == LJ52_GCS_PAUSE) {
      if (g->gc.stepmul == 0) g->gc.stepmul = M->gc_savedmul;
      M->gc_armed = 0;
      M->gc_collects++;
    } else if (++M->gc_armedcalls > LJ52_GC_ARMCAP) {
      /* The safety valve.  While armed, EVERY lj_gc_step from any site is
       * unbounded, so the window must not be allowed to persist if the latch
       * somehow never resolves.  A nonzero bailouts count is a bug in this
       * code, not a tuning signal: it means the white flip is not being seen
       * and the disarm argument needs re-deriving. */
      if (g->gc.stepmul == 0) g->gc.stepmul = M->gc_savedmul;
      M->gc_armed = 0;
      M->gc_bailouts++;
    }
    M->gc_busy = 0;
    return;
  }

  w = total / 4;
  if (w < LJ52_GC_WMIN) w = LJ52_GC_WMIN;
  headroom = total - used;
  if (headroom < w) {
    M->gc_savedmul = g->gc.stepmul;
    M->gc_white    = g->gc.currentwhite;
    g->gc.stepmul  = 0;                 /* -> lim = LJ_MAX_MEM: a whole cycle */
    g->gc.threshold = g->gc.total;      /* NOT 0 -- see the comment above     */
    M->gc_armed = 1;
    M->gc_armedcalls = 0;
    M->gc_arms++;
  }
  M->gc_busy = 0;
}

#define LJ52_WD_REFIRE_MS 50            /* see THREADING above */
#define LJ52_WD_MAXMS     4294967000.0  /* ~49 d.  The Win32 DWORD bound, kept
                                         * on Linux ON PURPOSE: one policy and
                                         * one behaviour to test, rather than a
                                         * config value that means two things. */
#define LJ52_WD_MAXWAIT_MS 3600000.0    /* caps one WAIT, never the deadline  */
#define LJ52_WD_STACKSZ   (128 * 1024)  /* not glibc's 8 MB: fifty machines is
                                         * then ~1.5 MB of real memory rather
                                         * than 400 MB of reserved address
                                         * space, which is the number someone
                                         * screenshots. */
static const char LJ52_WD_KEY = 0;      /* registry slot for the armed fn */

/* Monotonic milliseconds.
 *
 * CLOCK_MONOTONIC and not CLOCK_BOOTTIME: it excludes host suspend, which is
 * what QueryPerformanceCounter does, so a wd_stack deadline means the same
 * thing on both backends.  Only ever used as differences, so the epoch is as
 * irrelevant as QPC's, and a double still resolves to microseconds after a year
 * of uptime.  vDSO on x86-64 and aarch64, so no syscall. */
#if defined(LJ52_WD_PTHREAD)
static double lj52_wd_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}
#else
static double lj52_wd_now(void) {
  static LARGE_INTEGER freq;
  LARGE_INTEGER t;
  if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
  QueryPerformanceCounter(&t);
  return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
}
#endif

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

#if defined(LJ52_WD_PTHREAD)

/* Sleep until `due`, or LJ52_WD_MAXWAIT_MS from now, whichever is sooner.
 * Enters and leaves with wd_mtx held. */
static void lj52_wd_wait_until(lj52_mem *M, double due) {
  struct timespec ts;
  double now = lj52_wd_now();
  double ms  = (due > now + LJ52_WD_MAXWAIT_MS) ? now + LJ52_WD_MAXWAIT_MS : due;
  double sec = floor(ms / 1000.0);
  ts.tv_sec  = (time_t)sec;
  ts.tv_nsec = (long)((ms - sec * 1000.0) * 1000000.0);
  if (ts.tv_nsec < 0L)         ts.tv_nsec = 0L;
  if (ts.tv_nsec > 999999999L) ts.tv_nsec = 999999999L;
  /* wd_wake is the END OF THE SLEEP WE ARE ABOUT TO TAKE and must never be
   * EARLIER than that: program() skips its signal when the new deadline is not
   * before wd_wake, so a wd_wake that understated the sleep would let the
   * thread sleep straight through a deadline.  Overstating it merely costs a
   * spurious signal.  It is derived from the same `ms` as ts, cap included, so
   * it can be neither. */
  M->wd_wake = ms;
  (void)pthread_cond_timedwait(&M->wd_cv, &M->wd_mtx, &ts);
}

/* The ONLY thing that ever runs off the Lua thread on this backend.
 *
 * DELIVERY IS DERIVED, NOT REGISTERED.  Every iteration re-reads wd_due and
 * recomputes its sleep from it, so a spurious wake costs one re-check and a
 * LOST wake is not expressible -- there is no queued notification whose loss
 * would be silent.  That is the structural answer to the Win32 backend's open
 * finding (fires=0 in 2 of ~6 runs under host load).
 *
 * ITS ONLY BLOCKING POINT, EVER, IS ITS OWN CONDVAR.  It takes no second lock,
 * never allocates, calls no Lua or JNI API, does no I/O, and enters the VM only
 * through lj52_wd_inject -- two word stores, one atomic OR, one
 * lj_dispatch_update, all non-blocking.  Keep that true and lj52_wd_stop can
 * never hang on its join; break it and it hangs a Minecraft server thread. */
static void *lj52_wd_thread(void *p) {
  lj52_mem *M = (lj52_mem *)p;
  pthread_mutex_lock(&M->wd_mtx);
  for (;;) {
    double now;
    if (M->wd_quit) break;
    if (M->wd_due == 0.0) {              /* disarmed: park */
      M->wd_wake = 0.0;
      pthread_cond_wait(&M->wd_cv, &M->wd_mtx);
      continue;
    }
    now = lj52_wd_now();
    if (now < M->wd_due) { lj52_wd_wait_until(M, M->wd_due); continue; }
    if (!M->wd_fired) { M->wd_fired = 1; M->wd_fires++; } else M->wd_refires++;
    lj52_wd_inject(M);                   /* MUTEX HELD -- this IS the cancel */
    /* Re-fire measured from NOW, not from the previous due, so a thread that
     * lost the CPU wakes owing exactly one re-fire rather than a backlog. */
    M->wd_due = now + (double)LJ52_WD_REFIRE_MS;
  }
  M->wd_wake = 0.0;
  pthread_mutex_unlock(&M->wd_mtx);
  return NULL;
}

/* Withdraw the deadline, waiting for any in-flight injection to finish.
 *
 * pthread_mutex_lock IS THE WAIT.  The thread holds wd_mtx continuously from
 * entering its loop to leaving it, releasing it only inside the condvar waits
 * -- that is, only while asleep with nothing in flight -- and in particular it
 * holds it across lj52_wd_inject.  So either it is asleep and we take the mutex
 * at once, or it is mid-fire and we block until that completes.
 *
 * The invariant is STRONGER than DeleteTimerQueueTimer's: afterwards no
 * injection can even START, because the only path into the fire block needs
 * wd_due != 0 and only the Lua thread sets that, in program(), which by
 * contract runs after this.  So arm's window (cancel, mutate wd_depth/wd_stack,
 * program) and disarm's (cancel, then clear the hook) are genuinely exclusive
 * of the timer thread -- and that falls out of "the callback runs under the
 * lock the canceller takes", not out of an ordering argument a reader has to
 * reconstruct.
 *
 * Deliberately NO signal: correctness needs only that no fire happen after we
 * return, which clearing wd_due under the mutex gives. Skipping it is what
 * makes disarm syscall-free, and the stale sleep it leaves usually makes the
 * next arm syscall-free too. */
static void lj52_wd_cancel(lj52_mem *M) {
  if (!M->wd_started) return;
  pthread_mutex_lock(&M->wd_mtx);
  M->wd_due = 0.0;
  pthread_mutex_unlock(&M->wd_mtx);
}

#else  /* LJ52_WD_WIN32 */

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

#endif

/* Program the timer for the deadline at the top of the stack -- or, if that
 * deadline has already passed, install the hook right now, synchronously. */
static void lj52_wd_program(lj52_mem *M) {
  double remaining = M->wd_stack[M->wd_depth - 1] - lj52_wd_now();
#if defined(LJ52_WD_WIN32)
  HANDLE h = NULL;
#endif
  M->wd_fired = 0;
  /* WRITTEN NEGATED, AND THAT IS A FIX RATHER THAN A STYLE CHOICE.  `secs`
   * reaches wd_stack through luaL_checknumber, which accepts NaN, so `remaining`
   * can be NaN -- and NaN fails BOTH `<= 0.0` and `>= LJ52_WD_MAXMS`, so the old
   * spelling fell through to the cast below.  (DWORD)(NaN + 5.0) is undefined;
   * on x86-64 cvttsd2si yields INT_MIN, so the "timer" would land about 24.8
   * days out and the machine would run UNDEFENDED.  Negated, NaN takes the safe
   * branch of each test.  Not reachable from a sandbox today -- _OCLJ_WATCHDOG
   * is a raw global the sandbox never sees, and machine.lua only ever passes a
   * finite difference or math.huge -- but it is reachable from the raw API, and
   * the failure is silent. */
  if (!(remaining > 0.0)) {             /* already past, or NaN */
    lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1);
    return;
  }
  /* OC's computer.timeout has no upper bound (Settings.scala: `max 0`), and
   * an admin disabling the watchdog with a huge value would otherwise hand
   * CreateTimerQueueTimer a (DWORD) of an out-of-range double -- undefined,
   * and on x64 GCC typically 0: a timer that fires at once and leaves the
   * whole tick running under a count=1 hook.  Past what a DWORD of
   * milliseconds can express (~49 days) there is no deadline to enforce. */
  if (!(remaining < LJ52_WD_MAXMS)) return;  /* too far out, or +inf */

#if defined(LJ52_WD_PTHREAD)
  if (!M->wd_started) {          /* no thread: slow rather than undefended */
    M->wd_degraded = 1;
    lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1000);
    return;
  }
  pthread_mutex_lock(&M->wd_mtx);
  /* +5 ms for the reason given below: checkDeadline compares against
   * computer.realTime(), Java's wall clock, not this counter. */
  M->wd_due = M->wd_stack[M->wd_depth - 1] + 5.0;
  /* Signal ONLY if we moved the wake earlier.  wd_wake == 0 means parked
   * indefinitely, i.e. waking at +infinity, so any deadline is earlier. */
  if (M->wd_wake == 0.0 || M->wd_due < M->wd_wake)
    pthread_cond_signal(&M->wd_cv);
  M->wd_degraded = 0;
  pthread_mutex_unlock(&M->wd_mtx);
  return;
#else
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
    M->wd_degraded = 1;
    lua_sethook(M->L, lj52_wd_hook, LUA_MASKCOUNT, 1000);
    return;
  }
  M->wd_timer = (void *)h;
  M->wd_degraded = 0;
#endif
}

#if defined(LJ52_WD_PTHREAD)
/* EAGER, at state creation rather than lazily at the first arm.  pthread_create
 * is fallible, and discovering that at newstate gives a machine that BOOTS on
 * the standing-hook fallback; discovering it on the first arm puts a fallible
 * call in the middle of a game tick.  Afterwards the invariant is total:
 * wd_started == 1 means mutex, cond and thread all exist for the rest of the
 * record's life, and 0 means none of them do.  One int guards every entry. */
static void lj52_wd_start(lj52_mem *M) {
  pthread_condattr_t ca;
  pthread_attr_t     ta;
  sigset_t           block, old;
  size_t             stk = LJ52_WD_STACKSZ;
  int                rc;

  M->wd_quit = 0;
  if (pthread_mutex_init(&M->wd_mtx, NULL) != 0) return;
  if (pthread_condattr_init(&ca) != 0) goto err_mtx;
  /* NOT OPTIONAL.  A condvar's default clock is CLOCK_REALTIME, and on it an
   * NTP step or `date -s` moves a LIVE deadline -- into next week, or into the
   * past.  prototype/watchdog/harness.c does exactly that, with the comment
   * "pthread_cond uses REALTIME"; do not carry it forward.  If clock selection
   * is unavailable, take the standing-hook fallback rather than ship a timer
   * that is subtly wrong. */
  if (pthread_condattr_setclock(&ca, CLOCK_MONOTONIC) != 0) {
    pthread_condattr_destroy(&ca);
    goto err_mtx;
  }
  rc = pthread_cond_init(&M->wd_cv, &ca);
  pthread_condattr_destroy(&ca);
  if (rc != 0) goto err_mtx;
  if (pthread_attr_init(&ta) != 0) goto err_cv;
#ifdef PTHREAD_STACK_MIN
  if (stk < (size_t)PTHREAD_STACK_MIN) stk = (size_t)PTHREAD_STACK_MIN;
#endif
  (void)pthread_attr_setstacksize(&ta, stk);
  /* THIS THREAD IS INVISIBLE TO HOTSPOT -- it is never AttachCurrentThread'd --
   * so it must never be the one chosen to take an asynchronous signal the JVM
   * owns: SIGQUIT's thread dump, SIGTERM, SIGINT, HotSpot's own SR_signum.
   * Block everything across the create; the child inherits the mask.  The four
   * synchronously generated ones stay unblocked, because blocking a
   * hardware-generated SIGSEGV/SIGBUS/SIGFPE/SIGILL is undefined. */
  sigfillset(&block);
  sigdelset(&block, SIGSEGV); sigdelset(&block, SIGBUS);
  sigdelset(&block, SIGFPE);  sigdelset(&block, SIGILL);
  pthread_sigmask(SIG_SETMASK, &block, &old);
  rc = pthread_create(&M->wd_thread, &ta, lj52_wd_thread, M);
  pthread_sigmask(SIG_SETMASK, &old, NULL);
  pthread_attr_destroy(&ta);
  if (rc != 0) goto err_cv;
  M->wd_started  = 1;
  M->wd_degraded = 0;
  (void)pthread_setname_np(M->wd_thread, "ocljit-wd");
  return;

err_cv:
  pthread_cond_destroy(&M->wd_cv);
err_mtx:
  pthread_mutex_destroy(&M->wd_mtx);
  /* wd_started stays 0: every entry point then takes the standing-hook path,
   * which is slow rather than undefended. */
  M->wd_degraded = 1;
}

/* Join the thread and destroy the primitives.  MUST happen before the record
 * is freed and before lua_close, because the thread reaches into G(M->L). */
static void lj52_wd_stop(lj52_mem *M) {
  if (!M->wd_started) return;
  pthread_mutex_lock(&M->wd_mtx);
  M->wd_quit = 1;
  M->wd_due  = 0.0;
  pthread_cond_signal(&M->wd_cv);
  pthread_mutex_unlock(&M->wd_mtx);
  pthread_join(M->wd_thread, NULL);
  pthread_cond_destroy(&M->wd_cv);
  pthread_mutex_destroy(&M->wd_mtx);
  M->wd_started = 0;
}
#else
#define lj52_wd_start(M)  ((void)0)
#define lj52_wd_stop(M)   lj52_wd_cancel(M)
#endif

/* _OCLJ_WATCHDOG.arm(seconds, fn [, outermost [, protects]]) -> depth token.
 * `protects` is the thread about to be resumed; it defaults to the caller,
 * which is what a test (or any caller that arms for itself) wants. */
static int lj52_wd_arm(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  double secs = luaL_checknumber(L, 1);
  int outermost;
  /* NaN -> fire now, the maximally defensive reading; +inf survives to the
   * range guard in program().  Belt and braces with the negated tests there:
   * this one is at the SOURCE, which is where a future caller is likeliest to
   * introduce a NaN, and the file's own rule is that nothing may fail after the
   * cancel further down. */
  if (!(secs >= 0.0)) secs = 0.0;
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

/* ================================================================== *
 * JIT accounting, for measurement only
 * ================================================================== */

/* _OCLJ_JITSTATS() -> mcode_bytes, maxmcode_bytes, traces_used, jit_on
 *
 * Two things this project needs to measure and cannot reach any other way.
 *
 * MCODE IS INVISIBLE TO THE RAM CAP.  Machine code is VirtualAlloc'd by
 * lj_mcode.c and never passes g->allocf, so the per-machine cap the shim
 * enforces cannot see a byte of it -- up to maxmcode (2048 KB by default,
 * lj_jit.h) per state, which for a 1 MB machine exceeds its entire advertised
 * RAM.  J->szallmcarea (lj_jit.h:510, accumulated at lj_mcode.c:369) is the
 * running total, so this is the number that says what a machine ACTUALLY
 * costs a server.
 *
 * AND IT IS THE TRACE-FLUSH SIGNATURE.  lj_trace_flushall zeroes szallmcarea
 * (lj_mcode.c:378), so a reading of 0 after a persist is proof the serializer
 * discarded every compiled trace in the VM.  eris_lj.c does that at two gated
 * sites (:1209 persist, :2127 restore) whenever a for-in loop is involved --
 * which was free while traces never ran and is not free now.  Sampling this
 * around a save is how we find out whether a world save leaves the machine
 * cold.
 *
 * A raw global like _OCLJ_NATIVE and _OCLJ_WATCHDOG: the sandbox never sees
 * raw _G, and jit.util -- the usual way to ask these questions -- is
 * deliberately kept out of it (docs/research/os-shape-census.md).  Read-only,
 * and it allocates nothing. */
static int lj52_jitstats(lua_State *L) {
  jit_State *J = L2J(L);
  lua_pushnumber(L, (lua_Number)J->szallmcarea);
  lua_pushnumber(L, (lua_Number)(J->param[JIT_P_maxmcode] << 10));
  lua_pushinteger(L, (lua_Integer)(J->freetrace ? J->freetrace - 1 : 0));
  lua_pushboolean(L, (J->flags & JIT_F_ON) != 0);
  return 4;
}

/* _OCLJ_GCSTATS() -> arms, collects, bailouts, refusals, armed,
 *                    gc_total, gc_threshold, gc_stepmul, gc_state
 *
 * THE INSTRUMENT FOR THE EMERGENCY COLLECTOR, and it is not optional.  A
 * `sieve` that passes with arms == 0 proves nothing about this code -- it
 * would mean the run never approached the watermark and the trip-wire was
 * never exercised, which is exactly the class of false green that
 * bench/oc/sieve.lua's own retracted paragraph records.  The acceptance test
 * asserts arms >= 1 AND collects == arms AND bailouts == 0.
 *
 * bailouts is the one that matters most.  A nonzero count means the
 * currentwhite latch is not seeing flips it should, so the disarm predicate --
 * the whole safety argument for handing the collector an unbounded budget --
 * needs re-deriving.  It is a bug signal, never a tuning knob.
 *
 * The four gc.* fields are returned raw so a test can tell "never armed" from
 * "armed and still waiting": armed == true with a stepmul of 0 is the window
 * being open, and it should never be observable at rest.
 *
 * Read-only, allocates nothing, raw global like _OCLJ_JITSTATS -- the sandbox
 * never sees raw _G. */
static int lj52_gcstats(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  global_State *g = G(L);
  lua_pushinteger(L, M ? M->gc_arms : -1);
  lua_pushinteger(L, M ? M->gc_collects : -1);
  lua_pushinteger(L, M ? M->gc_bailouts : -1);
  lua_pushinteger(L, M ? M->gc_refusals : -1);
  lua_pushboolean(L, M ? M->gc_armed : 0);
  lua_pushnumber(L, (lua_Number)g->gc.total);
  lua_pushnumber(L, (lua_Number)g->gc.threshold);
  lua_pushnumber(L, (lua_Number)g->gc.stepmul);
  lua_pushinteger(L, (lua_Integer)g->gc.state);
  return 9;
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
  lua_pushcclosure(L, lj52_jitstats, 0);
  lua_setglobal(L, "_OCLJ_JITSTATS");
  lua_pushcclosure(L, lj52_gcstats, 0);
  lua_setglobal(L, "_OCLJ_GCSTATS");
}

/* lua_close does not free the record, so we do -- after making sure no timer
 * callback can still arrive and hook a state that no longer exists. */
void lj52_close(lua_State *L) {
  lj52_mem *M = lj52_memof(L);
  /* STOP, not merely cancel: on Linux the timer thread must be JOINED before
   * lua_close, because lj52_wd_inject reaches into G(M->L) and the state is
   * about to stop existing. */
  if (M != NULL) lj52_wd_stop(M);
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
  if (M != NULL) {
    M->L = L;                            /* the watchdog hooks this thread */
    lj52_wd_start(M);                    /* no-op on Win32; see lj52_wd_start */
  }
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
