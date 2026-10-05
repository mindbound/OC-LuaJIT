/* mem_test.c -- the memory-accounting half of the shim, on its own terms.
 *
 * Compiled the way jnlua.c is compiled (-include lj52shim.h) and linked
 * against the same lj52shim.o the DLL links, but with NO JVM anywhere: this
 * file plays the part of jnlua, supplying the three JNI accessors and the
 * registry key that lj52shim.h's lua_setallocf macro borrows from it.  That is
 * the point of the file.  The smoke test proves the accounting works inside
 * real OpenComputers; this proves WHY, in a form that runs in milliseconds and
 * that negative-control.sh can make fail on purpose.
 *
 * Covered:
 *   M0  the state's blocks live in its own lj_alloc arena (_OCLJ_GCSTATS
 *       heap = 1): -1 on an object from before the arena change, 0 on the
 *       C-library fallback; M0b checks the second state, M0c re-checks the
 *       first at the end
 *   M1  a state with no cap installed is not charged, and does not crash
 *   M2  installing a cap starts charging only once the Java object is BOUND --
 *       controlled_newstate really does call lua_setallocf before
 *       newstate_protected has stored the javastate, and that window must be
 *       harmless
 *   M3  allocation raises `used` by roughly what was allocated
 *   M4  freeing LOWERS it again.  The anti-ratchet control: an accounting bug
 *       that credits frees to the wrong side, or not at all, passes M1-M3 and
 *       fails only here
 *   M5  a cap actually refuses, and refuses as a catchable LUA_ERRMEM rather
 *       than by dying
 *   M6  THE COUPLING, in two halves at one instant.  With the cap exhausted,
 *       lua_pushcfunction still succeeds -- refusing it would raise LUA_ERRMEM
 *       in one of jnlua's 38 bare JNI frames and take the process down --
 *       while a plain lua_pushcclosure at the same moment is refused.  If both
 *       halves went the same way this test would be vacuous, which is why both
 *       are asserted.
 *   M7  the bytes lua_pushcfunction takes are still CHARGED.  Unrefusable is
 *       not the same as free, and an unbounded uncharged path would be a hole
 *   M8  clearing registry[JNLUA_JAVASTATE] -- what close_protected does --
 *       stops the accounting instead of writing through a dead reference
 *
 * And the emergency collector's TRACE FLUSH (lj52shim.c, "FLUSHING TRACES
 * UNDER MEMORY PRESSURE"), driven the same way -- the allocator is called
 * directly from C, so every checkpoint is an interpreter one and the JIT can
 * neither help nor hide:
 *   P0  the JIT compiles a few dozen traces that stay resident (pinned by
 *       their live prototypes, as a running program's are)
 *   P1  THE NEGATIVE CONTROL: pressure that a cycle resolves -- garbage, not
 *       live data -- must NOT flush.  The cycle is proven to have run (arms
 *       and collects both advance), the traces are still there afterwards,
 *       and the arm entry point leaves them alone
 *   P2  THE FLUSH: live data holds headroom under the watermark THROUGH a
 *       completed emergency cycle, so garbage alone cannot restore it.  The
 *       collector raises flush_wanted at the proof; the next arm() -- the
 *       kernel's per-resume safe point -- flushes every trace, re-arms the
 *       cycle, and the accounted `used` then drops by at least the trace
 *       metadata the flush unlinked
 *   FAIL-FIRST: on the shim before the flush existed P2 fails (no flush,
 *   traces remain, the stats are absent) and P1's behavioural half passes;
 *   the log of that run is kept next to the change.
 *
 * And the accounting's C MODE (docs/accounting-sync.md): once LuaStateLuaJIT
 * hands the cap over, the figures live in the shim and no allocation crosses
 * into the JVM.  M1-M8 and P0-P2 above keep testing LEGACY mode -- the
 * dropin's, and every state's before the handover -- unchanged; M3c and M9
 * check that legacy mode keeps the native figure ready and never hands over
 * by itself.  On a state of its own, bound and handed over exactly as jnlua
 * and LuaStateLuaJIT(int) do it:
 *   C0  before the handover the state is in legacy mode and its allocations
 *       cross JNI (C1's control, counted two ways that must agree); at the
 *       handover the native cap and figure equal Java's and LuaJIT's own
 *   C1  after it, an allocation burst makes no JNI call at all
 *   C2  the native figure is LuaJIT's g->gc.total to the byte, through
 *       growth and through a collection; getFreeMemory reads it once
 *   C3  a lowered cap bites on the next allocation, a raised one admits
 *   C4  OC's save pattern: setTotalMemory(Integer.MAX_VALUE), a persist
 *       that allocates past the machine's cap, the cap put back -- free reads
 *       0 and refuses until the garbage is collected
 *   C5  the emergency collector arms against the native cap and completes,
 *       and raises flush_wanted when live data holds the headroom down
 *   C6  at an exhausted native cap the raw push is refused while
 *       lua_pushcfunction succeeds and is still charged
 *   C7  with the accounting off (jnlua's close) nothing is refused and the
 *       figure still tracks
 *   C8  -1 from the core for no state, a state on a foreign allocator, and an
 *       uncapped state that never handed over; settotal on those is a no-op
 *   FAIL-FIRST: -DMEMTEST_OLD (run-mem.sh: OCLJ_MEMTEST_CFLAGS) turns the
 *   LuaStateLuaJIT model below into the class as it was, with no overrides
 *   and no cores to call, so the suite links against the object from before
 *   the change: C0, C1, C2, C7, M3c and M9 fail there and the behavioural
 *   cases C3-C6 pass on the legacy path.  Sabotaged copies of the C path
 *   make C2-C7 fail one by one; see the change's gate log.
 *
 * And THE COLLECTOR AT THE WALL (lj52shim.c: THE PARK RESET, THE CREDIT, THE
 * CADENCE, THE WINDOW), the W cases, each with its story at the case:
 *   W1-W15  the park reset and the valve, the credit's tiers and its bound
 *       (W7: caught refusals cannot ratchet it), the cadence's cost, the
 *       flush at half the watermark (bench/results-wall-2026-10-04.md)
 *   W16 the capacity probe's program: no refusal outside the program's
 *       handler where a collection would have made room for the request
 *   W16R, W16Rj  the same in the reserve tier, after a first refusal the
 *       step's handler absorbed, with the JIT off and on; W16L, W16RL and
 *       W16RjL all three on the legacy (dropin) path
 *   W11w a fresh record's window opens no reserve tier without a refusal
 *   W17 a live fill is refused past the top, and within half the window
 *   W7k, C6b, W18, W19  the kernel: its bound, its hard top, never refused
 *       for the sandbox's lent data at 4 and 10 MB, its room past the window
 *   FAIL-FIRST: W16, W16R, W16Rj and W17 fail on the stage-C object in 10 of
 *   10 runs (bench/results-wall-window-2026-10-05.md).
 *
 * Build: see run-mem.sh next to this file.  Exit status 0 iff every case passes.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* ---- we are pretending to be jnlua ---------------------------------------
 * lj52shim.h's lua_setallocf macro expands to a call naming four things out of
 * jnlua.c: JNLUA_JAVASTATE and the three accessors.  Defining them here is not
 * a workaround -- it is the only way to exercise that macro at all, and it
 * PINS their signatures: if OC-JNLua ever changes one, this file stops
 * compiling at the same moment jnlua.c would. */
#define JNLUA_JAVASTATE "jnlua.JavaState"

/* Our stand-in for the Java LuaState: the two int fields jnlua reads and
 * writes, plus call counters.  jobject and JNIEnv are opaque to the shim --
 * it only ever hands them straight back to these functions -- so a pointer to
 * this struct is a perfectly good jobject. */
typedef struct { jint total; jint used; int gets; int sets; } FakeState;
static FakeState FS;
static JNIEnv FAKE_ENV = NULL;   /* JNIEnv is itself a pointer type in C */
/* Calls of jnlua's getthreadenv: the third JVM touch a legacy allocation makes
 * (JavaVM->GetEnv in jnlua), priced with the two field accesses at about a
 * third of the crossing.  C1 asserts C mode makes none of these either. */
static int ENVCALLS = 0;

static JNIEnv *getthreadenv(void) { ENVCALLS++; return &FAKE_ENV; }

static void getluamemory(JNIEnv *env, jobject obj, jint *total, jint *used) {
  FakeState *s = (FakeState *)obj;
  (void)env;
  s->gets++;
  *total = s->total;
  *used = s->used;
}

static void setluamemory(JNIEnv *env, jobject obj, jint used) {
  FakeState *s = (FakeState *)obj;
  (void)env;
  s->sets++;
  s->used = used;
}

/* ---- and we are pretending to be LuaStateLuaJIT ---------------------------
 * Its accounting overrides, in C (the class is emitted by
 * native/jnlua/gen-luastate-subclass.py; docs/accounting-sync.md): the capped
 * constructor and setTotalMemory write jnlua's field and then hand the cap to
 * the native side; getFreeMemory asks the native side for the used figure and
 * falls back to jnlua's field when it answers -1.
 *
 * Under -DMEMTEST_OLD these model the class as it was before the change -- no
 * overrides, no cores -- so that the suite links against the previous
 * lj52shim.o, which defines neither core, and the cases that test the C mode
 * are seen failing there. */
static long long j_core_used(lua_State *L) {
#ifdef MEMTEST_OLD
  (void)L;
  return -1;
#else
  return lj52_mem_used(L);              /* ocljUsedMemory() */
#endif
}

static void j_settotal(lua_State *L, FakeState *s, jint v) {
  s->total = v;                         /* super.setTotalMemory(value) */
#ifdef MEMTEST_OLD
  (void)L;
#else
  lj52_mem_settotal(L, v);              /* ocljSetTotalMemory(getTotalMemory()) */
#endif
}

/* What Java takes the used figure to be: the native one, else jnlua's field. */
static long long j_used(lua_State *L, FakeState *s) {
  long long u = j_core_used(L);
  return u >= 0 ? u : (long long)s->used;
}

/* getFreeMemory(): clamped at zero, by jnlua and by the override alike. */
static long long j_free(lua_State *L, FakeState *s) {
  long long f = (long long)s->total - j_used(L, s);
  return f < 0 ? 0 : f;
}

/* ---- harness ------------------------------------------------------------ */

static int failures = 0;
static int checks = 0;

static void ok(int cond, const char *what, const char *detail) {
  checks++;
  if (cond) {
    printf("  PASS  %-52s %s\n", what, detail ? detail : "");
  } else {
    failures++;
    printf("  FAIL  %-52s %s\n", what, detail ? detail : "");
  }
}

/* Bind the fake Java state exactly as newstate_protected does: a FULL userdata
 * holding the jobject, stored at registry[JNLUA_JAVASTATE].  The shim caches
 * the userdata's address when it sees this write, which is what lets its
 * allocator find the object without lua_getfield. */
static void bind_javastate(lua_State *L, void *obj) {
  void **ref = (void **)lua_newuserdata(L, sizeof(void *));
  *ref = obj;
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
}

static void clear_javastate(lua_State *L) {
  lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
}

/* Allocate n small tables under a protected call; returns the pcall status. */
static int alloc_tables(lua_State *L, long n) {
  char buf[192];
  sprintf(buf, "local t = {} for i = 1, %ld do t[i] = {i, i} end __hold = t", n);
  if (luaL_loadstring(L, buf) != 0) return -1;
  return lua_pcall(L, 0, 0, 0);
}

/* LuaJIT's OWN idea of how many bytes it holds.  g->gc.total is maintained in
 * lj_mem_realloc as the running sum of exactly the (osize, nsize) pairs it
 * hands the allocator callback, so over any window where our accounting is
 * continuously armed the two deltas must agree TO THE BYTE.  That makes this a
 * free, exact, JVM-free oracle for the whole arithmetic: it catches a lost
 * free, a double-counted grow, or a truncated delta, none of which the
 * order-of-magnitude assertions above would notice. */
static long long lj_bytes(lua_State *L) {
  return (long long)lua_gc(L, LUA_GCCOUNT, 0) * 1024 + (long long)lua_gc(L, LUA_GCCOUNTB, 0);
}

/* Distinct C functions to push.  Only their identity matters; c_cfunc is
 * pushed by C6 alone, so its memo entry is cold there. */
static int a_cfunc(lua_State *L) { lua_pushinteger(L, 7); return 1; }
static int b_cfunc(lua_State *L) { lua_pushinteger(L, 8); return 1; }
static int c_cfunc(lua_State *L) { lua_pushinteger(L, 9); return 1; }

/* alloc_tables, except that a refused LOAD reports its own status: below an
 * exhausted cap even the chunk cannot be parsed, and that is a refusal too.
 * Leaves the stack as it found it. */
static int try_tables(lua_State *L, long n) {
  char buf[192];
  int s, top = lua_gettop(L);
  sprintf(buf, "local t = {} for i = 1, %ld do t[i] = {i, i} end __hold = t", n);
  s = luaL_loadstring(L, buf);
  if (s == 0) s = lua_pcall(L, 0, 0, 0);
  lua_settop(L, top);
  return s;
}

/* An allocator that is not the shim's, for a state lj52_memof cannot know. */
static void *foreign_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  (void)osize;
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

/* Pushes a C closure the RAW way -- LuaJIT's own lua_pushcclosure, with
 * nothing suspended -- so that its allocation is refusable.  Run under pcall
 * so a refusal is a status rather than a dead process. */
static int raw_push(lua_State *L) {
  lua_pushcclosure(L, b_cfunc, 0);
  return 1;
}

/* ---- the trace-flush cases' instruments ---------------------------------- */

/* Run a chunk under pcall; on failure leave the message on the stack top. */
static int runstr(lua_State *L, const char *src) {
  if (luaL_loadstring(L, src) != 0) return -1;
  return lua_pcall(L, 0, 0, 0);
}

static const char *errtop(lua_State *L) {
  const char *s = lua_tostring(L, -1);
  return s ? s : "(no message)";
}

/* The n-th (1-based) value returned by a raw global such as _OCLJ_GCSTATS,
 * as a number; booleans read as 1/0.  A value the function does NOT return
 * reads as -1, never as 0: an older shim answers fewer values, and a missing
 * counter must show up as "absent", not as "zero flushes".  This is what
 * lets the same test binary link against the previous object for the
 * fail-first run. */
static double statn(lua_State *L, const char *global, int n) {
  double v = -1;
  int top = lua_gettop(L);
  lua_getglobal(L, global);
  if (!lua_isfunction(L, -1) || lua_pcall(L, 0, LUA_MULTRET, 0) != 0) {
    lua_settop(L, top);
    return -1;
  }
  if (lua_gettop(L) - top >= n) {
    int idx = top + n;
    if (lua_isboolean(L, idx)) v = lua_toboolean(L, idx) ? 1 : 0;
    else if (lua_isnumber(L, idx)) v = lua_tonumber(L, idx);
  }
  lua_settop(L, top);
  return v;
}
/* How many values a raw global such as _OCLJ_GCSTATS returns; -1 if absent. */
static int statcount(lua_State *L, const char *global) {
  int n, top = lua_gettop(L);
  lua_getglobal(L, global);
  if (!lua_isfunction(L, -1) || lua_pcall(L, 0, LUA_MULTRET, 0) != 0) {
    lua_settop(L, top);
    return -1;
  }
  n = lua_gettop(L) - top;
  lua_settop(L, top);
  return n;
}
/* _OCLJ_GCSTATS positions.  1-9 are the original nine; 10-13 were appended
 * with the trace flush (lj52shim.c lj52_gcstats) and read -1 before it. */
#define GC_ARMS(L)       statn(L, "_OCLJ_GCSTATS", 1)
#define GC_COLLECTS(L)   statn(L, "_OCLJ_GCSTATS", 2)
#define GC_BAILOUTS(L)   statn(L, "_OCLJ_GCSTATS", 3)
#define GC_REFUSALS(L)   statn(L, "_OCLJ_GCSTATS", 4)
#define GC_ARMED(L)      statn(L, "_OCLJ_GCSTATS", 5)
#define GC_FLUSHES(L)    statn(L, "_OCLJ_GCSTATS", 10)
#define GC_FLUSHWANT(L)  statn(L, "_OCLJ_GCSTATS", 11)
#define GC_FLUSHREF(L)   statn(L, "_OCLJ_GCSTATS", 12)
#define GC_FLUSHBYTES(L) statn(L, "_OCLJ_GCSTATS", 13)
/* Position 14, appended 2026-10-02: 1 = the state's blocks live in its own
 * lj_alloc arena, 0 = the C library fallback; -1 (absent) on an older shim. */
#define GC_HEAP(L)       statn(L, "_OCLJ_GCSTATS", 14)
/* Positions 15-20, appended 2026-10-03 (docs/accounting-sync.md): the native
 * cap and used figure, whether the state has handed over (1) or not (0), how
 * often the Java side read the figure, and every allocator call against the
 * ones that crossed into the JVM.  -1 (absent) on an older shim. */
#define GC_CTOTAL(L)     statn(L, "_OCLJ_GCSTATS", 15)
#define GC_CUSED(L)      statn(L, "_OCLJ_GCSTATS", 16)
#define GC_CSYNC(L)      statn(L, "_OCLJ_GCSTATS", 17)
#define GC_UREADS(L)     statn(L, "_OCLJ_GCSTATS", 18)
#define GC_ACALLS(L)     statn(L, "_OCLJ_GCSTATS", 19)
#define GC_AJNI(L)       statn(L, "_OCLJ_GCSTATS", 20)

/* Settle a latched emergency cycle before a case that wants to see a FRESH
 * one.  The latch disarms when an allocation finds the white flipped at the
 * pause; one full collection flips it once, so collect-then-allocate
 * resolves it -- but two collections flip it back, and the latch then waits
 * forever (the first draft of C5 did exactly that: the trace flush at the
 * safe point re-arms a cycle, two collections hid its end, and the churn
 * stopped on the stale disarm instead of arming anew).  A few rounds at most;
 * returns the armed flag, 0 when settled. */
static double settle_gc(lua_State *L) {
  int i;
  for (i = 0; i < 4 && GC_ARMED(L) != 0; i++) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    try_tables(L, 10);
  }
  return GC_ARMED(L);
}
/* _OCLJ_JITSTATS position 5: traces_live, the non-NULL J->trace[] slots. */
#define JIT_LIVE(L)      statn(L, "_OCLJ_JITSTATS", 5)

/* Drive the allocator from C: one table per step, popped at once, so each
 * step is exactly one lj_gc_check (lua_createtable's) plus one charged
 * allocation, on the interpreter side of the VM.  `asize` picks the burst:
 * 0 is a 64-byte GCtab, 8192 is a 64 KB array part that outruns the paced
 * collector in a handful of steps.  Stops as soon as gc_collects passes
 * `until_collects`, or after `max` steps.  Under lua_cpcall, because a
 * refusal at the cap from a bare C frame is a panic and a dead process, and
 * this test's whole point is to read numbers out afterwards. */
typedef struct { int asize; double until; int max; int steps; } ChurnArgs;

static int churn_cf(lua_State *L) {
  ChurnArgs *a = (ChurnArgs *)lua_touserdata(L, 1);
  int i;
  for (i = 1; i <= a->max; i++) {
    lua_createtable(L, a->asize, 0);
    lua_pop(L, 1);
    a->steps = i;                       /* kept current: a refusal reports how far it got */
    if (GC_COLLECTS(L) > a->until) return 0;
  }
  a->steps = i - 1;
  return 0;
}

/* Returns the steps taken; *status is the cpcall status (0, or LUA_ERRMEM
 * when the cap refused before the collector caught up). */
static int churn(lua_State *L, int asize, double until_collects, int max, int *status) {
  ChurnArgs a;
  a.asize = asize; a.until = until_collects; a.max = max; a.steps = 0;
  *status = lua_cpcall(L, churn_cf, &a);
  return a.steps;
}

/* The emergency collector's watermark, as lj52_gc_pressure computes it. */
static long wmark(long total) {
  long w = total / 4;
  return w < 128 * 1024 ? 128 * 1024 : w;
}

/* Forty distinct prototypes, each with its own hot loop, each called three
 * times: forty root traces, kept resident by __fns exactly as a running
 * program's traces are kept resident by the function on its stack
 * (gc_traverse_proto marks pt->trace).  The driver is jit.off'd so the only
 * traces are the forty loops, not a side-trace fan-out of the calling loop. */
static const char *TRACE_CHUNK =
  "local fns = {} "
  "for k = 1, 40 do "
  "  fns[k] = assert(loadstring('local s = 0 for i = 1, 300 do s = s + i * ' .. k .. ' end return s')) "
  "end "
  "local function drive() for r = 1, 3 do for k = 1, 40 do fns[k]() end end end "
  "jit.off(drive) "
  "drive() "
  "__fns = fns";

/* The kernel's safe point: _OCLJ_WATCHDOG.arm on the Lua thread, which is
 * what machine.lua calls before every sandbox resume, then disarm so no
 * timer outlives the case.  Nothing else in the kernel's resume path is
 * modelled; a flush that needs more than this call is a design failure. */
static const char *ARM_DISARM =
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "_OCLJ_WATCHDOG.disarm(t)";

/* ---- the collector at the wall (the W cases) ------------------------------
 * _OCLJ_GCSTATS positions the earlier cases do not read, and _OCLJ_WALLSTATS
 * (docs/roadmap.md, "THE COLLECTOR AT THE WALL"; lj52shim.c, THE CREDIT):
 * growths lent past the cap, the largest excursion past it, the credit tier
 * (0 burst, 1 reserve), parked arms restarted, the credit limit G for the
 * current cap, the kernel's slice past it, and THE CADENCE's own state: the
 * heap the last proof left, why the last cycle was armed, whether one has
 * been proven.  Every WALL value reads -1 on a shim older than 2026-10-04. */
#define GC_GTOTAL(L)        statn(L, "_OCLJ_GCSTATS", 6)
#define GC_THRESH(L)        statn(L, "_OCLJ_GCSTATS", 7)
#define GC_STEPMUL(L)       statn(L, "_OCLJ_GCSTATS", 8)
#define GC_STATE(L)         statn(L, "_OCLJ_GCSTATS", 9)
#define WALL_OVERDRAFTS(L)  statn(L, "_OCLJ_WALLSTATS", 1)
#define WALL_ODPEAK(L)      statn(L, "_OCLJ_WALLSTATS", 2)
#define WALL_ODSTATE(L)     statn(L, "_OCLJ_WALLSTATS", 3)
#define WALL_PARKRESETS(L)  statn(L, "_OCLJ_WALLSTATS", 4)
#define WALL_ODLIMIT(L)     statn(L, "_OCLJ_WALLSTATS", 5)
#define WALL_KSLICE(L)      statn(L, "_OCLJ_WALLSTATS", 6)
#define WALL_LOW(L)         statn(L, "_OCLJ_WALLSTATS", 7)
#define WALL_LEND(L)        statn(L, "_OCLJ_WALLSTATS", 10)   /* THE WINDOW; -1 before it */
#define WALL_LENDS(L)       statn(L, "_OCLJ_WALLSTATS", 11)
#define WALL_WIN(L)         statn(L, "_OCLJ_WALLSTATS", 12)   /* 0 shut, 1 open, 2 the verdict */
/* lj_gc.h's GC states, by value (the shim spells GCSpause as 0 too). */
#define W_GCSPAUSE 0
#define W_GCSSWEEP 4

/* A fresh state as LuaStateLuaJIT makes one: the capped constructor, the
 * JavaState bound, the cap handed to the native side (C mode), the libraries
 * open.  With handover = 0 it stays on the legacy path, as the dropin's
 * states do for their whole life. */
static lua_State *w_newstate(FakeState *s, jint total, int handover) {
  lua_State *W = luaL_newstate();
  if (!W) return NULL;
  memset(s, 0, sizeof *s);
  s->total = total;
  lua_setallocf(W, NULL, W);
  bind_javastate(W, (void *)s);
  if (handover) j_settotal(W, s, total);
  luaL_openlibs(W);
  /* Keep "_OCLJ_WALLSTATS" interned.  On a shim that does not define it,
   * lua_getglobal would intern the name afresh -- an allocation -- and at an
   * exhausted cap that is a refusal in a bare C frame, which kills the test
   * (it did, the first time the wall cases ran against the previous object). */
  lua_pushliteral(W, "_OCLJ_WALLSTATS");
  lua_setfield(W, LUA_REGISTRYINDEX, "__wallname");
  return W;
}

/* Set the cap the way Java does in either mode. */
static void w_setcap(lua_State *W, FakeState *s, long long cap, int handover) {
  if (handover) j_settotal(W, s, (jint)cap);
  else s->total = (jint)cap;
}

/* The credit limit G the design gives a cap: total/16, clamped 32-512 KB. */
static long long w_odmax(long long total) {
  long long g = total >> 4;
  return g < 32 * 1024 ? 32 * 1024 : g > 512 * 1024 ? 512 * 1024 : g;
}

/* The most THE CREDIT lends past `total` to the kernel -- and mem_test's own
 * C frames run where the kernel does, with no resume armed: G plus the
 * kernel's slice.  0 on a shim without the credit.  Read while there is room
 * (a statn at an exhausted cap would itself be refused). */
static long long w_creditmax(lua_State *L, long long total) {
  double k = WALL_KSLICE(L);
  return k < 0 ? 0 : w_odmax(total) + (long long)k;
}

/* A cap with not one byte to spare, the credit included: total + G(total) +
 * the kernel's slice == used.  Live data that far past the cap is the
 * reserve tier, so both tiers and the slice are spent.  On a shim without
 * the credit, total == used, as these cases always set it. */
static long long w_exhausted(lua_State *L, long long used) {
  double k = WALL_KSLICE(L);
  long long t;
  int i;
  if (k < 0) return used;
  t = used - (long long)k - w_odmax(used);
  for (i = 0; i < 8; i++) t = used - (long long)k - w_odmax(t);   /* the fixed point */
  return t;
}

/* One lua_createtable of `narray` slots under cpcall: the status, and the
 * table left on the stack when it succeeded (keep = 1) or popped. */
typedef struct { int narray; int keep; } WTab;
static int w_tab_cf(lua_State *L) {
  WTab *a = (WTab *)lua_touserdata(L, 1);
  lua_createtable(L, a->narray, 0);
  if (a->keep) { lua_setfield(L, LUA_REGISTRYINDEX, "__wkeep"); }
  else lua_pop(L, 1);
  return 0;
}
static int w_tab(lua_State *L, int narray, int keep) {
  WTab a;
  a.narray = narray; a.keep = keep;
  return lua_cpcall(L, w_tab_cf, &a);
}

/* Every fill below that ends only at the cap carries its own bound (200 000
 * small tables, ~16 MB, thirty times any cap these cases set): a sabotage
 * that removes the cap -- negative-control.sh's stopgap -- must make them
 * FAIL, and the first unbounded draft instead ran the process to 18 GB. */
/* The W1 program: fill a pre-sized holder until the cap refuses, catch it,
 * drop the data, then do what a program does next -- build a string with an
 * allocate-first library function (string.rep allocates, then checks the GC:
 * lib_string.c) and make a table.  __w1 reports the caught error and the
 * string's length. */
static const char *W1_CHUNK =
  "local h = __h "
  "local ok, err = pcall(function() local i = 0 while i < 200000 do i = i + 1 h[i] = {i} end end) "
  "__h = nil h = nil "
  "local s = string.rep('x', 256) "
  "local t = {1, 2, 3} "
  "__w1 = (ok and 'no error' or tostring(err)) .. '|' .. #s .. '|' .. #t";

/* The W7 program: a caught refusal per live insert, many times over -- a
 * program trying to creep its live data into the credit.  Bounded at 4000
 * attempts: every attempt past the wall costs a full cycle, as each refusal
 * does on PUC. */
/* W1 with one more allocation BETWEEN the catch and the drop: the message
 * concatenated while the data is still held.  Its cycle runs and proves
 * nothing collectable; the recovery after the drop must still work. */
static const char *W8_CHUNK =
  "local h = __h "
  "local ok, err = pcall(function() local i = 0 while i < 200000 do i = i + 1 h[i] = {i} end end) "
  "local msg = 'err: ' .. tostring(err) "
  "__h = nil h = nil "
  "local s = string.rep('y', 256) "
  "local t = {1, 2, 3} "
  "__w8 = msg .. '|' .. #s .. '|' .. #t";

/* The residual: an allocate-first request retried in a loop with no
 * checkpoint in it (FORL, CALL, nothing that runs lj_gc_check), bigger than
 * the headroom plus the credit and covered only by garbage.  Stock collects
 * at the refusal and the first retry succeeds. */
static const char *W9_CHUNK =
  "local n, tries = __w9n, 0 "
  "for i = 1, 20 do tries = i if pcall(string.rep, 'z', n) then break end end "
  "__w9 = tries";

/* The kernel's allocations after the sandbox has exhausted the credit: the
 * sandbox fills inside a coroutine resumed under the watchdog's arm, as the
 * kernel resumes it, until refused twice (both tiers); then the kernel does
 * the table.pack it does after every resume (machine.lua), once still armed
 * and once after the disarm, where Java's signal pushes also land. */
static const char *W10_CHUNK =
  "local h, fails, i = __h, 0, 0 "
  "local args = {} for k = 1, 64 do args[k] = k end "
  "local co = coroutine.create(function() "
  "  for attempt = 1, 10 do "
  "    if fails >= 2 then break end "
  "    if not pcall(function() while i < 200000 do i = i + 1 h[i] = {i} end end) then fails = fails + 1 end "
  "  end "
  "end) "
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "local okr = coroutine.resume(co) "
  "local ok1 = pcall(table.pack, unpack(args)) "
  "_OCLJ_WATCHDOG.disarm(t) "
  "local ok2 = pcall(table.pack, unpack(args)) "
  "__h = nil h = nil "
  "__w10 = tostring(ok1) .. '|' .. tostring(ok2) .. '|' .. fails .. '|' .. tostring(okr)";

/* W11's sandbox: a coroutine made, and the watchdog armed by the main
 * thread, while there is room; mem_test resumes it from C at the cap. */
static const char *W11_CHUNK =
  "__co11 = coroutine.create(function() "
  "  local ok1 = pcall(function() local x = {1, 2, 3, 4, 5, 6, 7, 8} return x end) "
  "  local ok2 = pcall(function() local y = {} for k = 1, 4096 do y[k] = k end return y end) "
  "  coroutine.yield(ok1, ok2) "
  "end) "
  "__t11 = _OCLJ_WATCHDOG.arm(3600, function() end, true)";

/* W7's sandbox: 4000 caught attempts to add 64 tables to a table it never
 * drops, inside a coroutine resumed under the watchdog's arm, as the kernel
 * resumes the sandbox -- so the bound is the sandbox's, cap + G, without the
 * kernel's slice. */
/* W13's fill: live 64-byte tables into __w13 until gc.total reaches __w13t
 * (bounded, see above). */
static const char *W13_FILL =
  "local t = __w13 or {} __w13 = t "
  "local target, i = __w13t, #t "
  "while i < 200000 and collectgarbage('count') * 1024 < target do i = i + 1 t[i] = {i} end";

/* W14's program, in three phases by gc.total: live 64-byte tables into __w14
 * up to __w14a (just outside the watermark), then garbage up to __w14b (into
 * it: the cycle this arms frees that garbage and its proof lands OUTSIDE
 * the watermark), then live tables again up to __w14t.  Bounded throughout. */
static const char *W14_FILL =
  "local t = {} __w14 = t "
  "local a, b, c, i, g = __w14a, __w14b, __w14t, 0, 0 "
  "while i < 200000 and collectgarbage('count') * 1024 < a do i = i + 1 t[i] = {i} end "
  "while g < 200000 and collectgarbage('count') * 1024 < b do g = g + 1 local x = {g} end "
  "while i < 400000 and collectgarbage('count') * 1024 < c do i = i + 1 t[i] = {i} end";

static const char *W7_CHUNK =
  "local h, fails, cur = {}, 0, 0 "
  "local function add() for k = 1, 64 do h[#h + 1] = {cur, k} end end "
  "local co = coroutine.create(function() "
  "  for i = 1, 4000 do cur = i if not pcall(add) then fails = fails + 1 end end "
  "end) "
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "local okr = coroutine.resume(co) "
  "_OCLJ_WATCHDOG.disarm(t) "
  "__w7 = okr and fails or -1";

/* W11w's program (the code review of THE WINDOW, 2026-10-05): a sandbox
 * coroutine, resumed by C under the watchdog's arm, makes ONE table of a
 * given array and hash size from a C function -- three allocator calls (the
 * header, the array part, the hash part) with no checkpoint between them. */
static int w11w_mk(lua_State *L) {
  lua_createtable(L, (int)lua_tointeger(L, 1), (int)lua_tointeger(L, 2));
  return 1;
}
static const char *W11W_CHUNK =
  "__keep = false "
  "__co = coroutine.create(function(na, nh) "
  "  local ok, t = pcall(__w11wmk, na, nh) "
  "  if ok then __keep = t end "
  "  coroutine.yield(ok) "
  "end) "
  "__t = _OCLJ_WATCHDOG.arm(3600, function() end, true)";

#ifndef W16_N
#define W16_N 96             /* caps in the sweep */
#endif
#ifndef W16_STEP
#define W16_STEP 64          /* bytes between them: 96 x 64 B is one step of the fill */
#endif
#ifndef W16R_N
#define W16R_N 96            /* W16R / W16Rj (at 48 x 128 stage C left 1-2 covered) */
#endif
#ifndef W16R_STEP
#define W16R_STEP 64
#endif
/* W16's program: the capacity probe's shape (OcljSmoke.scala, OCLJ_PROBE=
 * capacity), the residual the collector at the wall left (docs/roadmap.md, "A
 * refusal at a credit tier's top can land outside the program's handler").  A
 * sandbox coroutine, resumed under the watchdog's arm as machine.lua resumes
 * it, fills 100 held 32-character strings per step INSIDE a pcall, with a
 * churn string per object; BETWEEN steps, outside any handler of its own, it
 * does what the probe does: the stage string, and event.timer's record for
 * the next step -- and the dispatcher packs each signal (OpenOS's
 * pullSignal) outside any handler at all.  The kernel's loop arms, resumes,
 * packs the results and disarms.  __w16rec(code) records, allocating
 * nothing: 1 refused inside the handler (the probe's normal end), 2 escaped
 * step() into the dispatcher's pcall (the probe's STALL), 3 killed the
 * sandbox (a machine down).  A stall then YIELDS 'stop' and the kernel stops
 * resuming it: the sandbox stays suspended where it landed, as OpenOS's
 * would, so the live set read after the run counts its stack (a coroutine
 * that returned has had its stack shrunk: up to 3.9 KB under, d2-verdict).  Bounded at 400 steps (40 000 strings, ~3 MB, seven
 * times the cap; see W1's note on bounds). */
static const char *W16_CHUNK =
  "local rec, held, count, stage, slot = __w16rec, {}, 0, 'filling/0', {} "
  "__w16h = held "
  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
  "local step "
  "step = function() "
  "  local ok = pcall(function() "
  "    for k = 1, 100 do "
  "      count = count + 1 held[count] = uniq(32, count) "
  "      local junk = uniq(24, count) .. '!' "
  "    end "
  "  end) "
  "  if not ok then rec(1) return end "
  "  stage = 'filling/' .. count "
  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "end "
  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "local co = coroutine.create(function() "
  "  for r = 1, 400 do "
  "    local sig = table.pack(coroutine.yield()) "
  "    local hd = slot[1] "
  "    if not hd then return end "
  "    slot[1] = nil "
  "    if not pcall(hd.callback) then rec(2) coroutine.yield('stop') return end "
  "  end "
  "end) "
  "local cb = function() end "
  "__w16k = function() "
  "  for r = 1, 402 do "
  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "    local res = table.pack(coroutine.resume(co, 'timer')) "
  "    _OCLJ_WATCHDOG.disarm(t) "
  "    if not res[1] then rec(3) return end "
  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
  "  end "
  "end "
  /* the largest single object the program allocates outside a handler: the
   * stage string, event.timer's record, the dispatcher's pack -- measured
   * here, with the collector stopped, so the case never hardcodes LuaJIT's
   * object sizes.  The third round counts: the first also pays one-time
   * allocations (the string buffer, table.pack's first call). */
  "for round = 1, 3 do "
  "  collectgarbage('stop') "
  "  local c0 = collectgarbage('count') "
  "  local s1 = 'filling/' .. (12345 + round) "
  "  local c1 = collectgarbage('count') "
  "  local t1 = { key = false, times = 1, callback = cb, interval = 0, timeout = 0 } "
  "  local c2 = collectgarbage('count') "
  "  local p1 = table.pack('timer') "
  "  local c3 = collectgarbage('count') "
  "  collectgarbage('restart') "
  "  __w16dmax = math.max(c1 - c0, c2 - c1, c3 - c2) * 1024 "
  "end";

/* W16's recorder: what landed where, and the accounted figure at that
 * moment.  A C function the chunk calls: nothing allocated. */
static int W16_CODE = 0;
static long long W16_USED = -1;
static double W16_DELTA = -1;      /* the refused request, WALLSTATS[13]; -1 before it */
static int w16_rec(lua_State *L) {
  W16_CODE = (int)lua_tointeger(L, 1);
  W16_USED = j_core_used(L);
  W16_DELTA = statn(L, "_OCLJ_WALLSTATS", 13);
  return 0;
}

/* W16R's program: W16's, carried into the RESERVE tier -- the shape every
 * bad in-machine outcome had (scratchpad wall2/design/u2-stalls.md: each came
 * at the reserve top, after a FIRST refusal something other than the fill
 * absorbed).  Here the step's own handler absorbs the first refusal and the
 * fill goes on with its data kept; at the second it records, drops its data
 * and stops, as the capacity probe does.  The recorder keeps the FIRST thing
 * recorded and the tier it happened in (the shim's refusal count). */
static const char *W16R_CHUNK =
  "local rec, held, count, stage, slot, nfail = __w16rec, {}, 0, 'filling/0', {}, 0 "
  "__w16h = held "
  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
  "local step "
  "step = function() "
  "  local ok = pcall(function() "
  "    for k = 1, 100 do "
  "      count = count + 1 held[count] = uniq(32, count) "
  "      local junk = uniq(24, count) .. '!' "
  "    end "
  "  end) "
  "  if not ok then "
  "    nfail = nfail + 1 "
  "    if nfail >= 2 then rec(1, nfail) held = nil __w16h = nil return end "
  "  end "
  "  stage = 'filling/' .. count "
  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "end "
  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "local co = coroutine.create(function() "
  "  for r = 1, 400 do "
  "    local sig = table.pack(coroutine.yield()) "
  "    local hd = slot[1] "
  "    if not hd then return end "
  "    slot[1] = nil "
  "    if not pcall(hd.callback) then rec(2, nfail) coroutine.yield('stop') return end "
  "  end "
  "end) "
  "local cb = function() end "
  "__w16k = function() "
  "  for r = 1, 402 do "
  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "    local res = table.pack(coroutine.resume(co, 'timer')) "
  "    _OCLJ_WATCHDOG.disarm(t) "
  "    if not res[1] then rec(3, nfail) return end "
  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
  "  end "
  "end";
static int W16R_TIER = 0;
static double W16R_REF0 = 0;       /* the shim's refusals when the run began */
static int w16r_rec(lua_State *L) {
  if (W16_CODE == 0) {
    W16_CODE = (int)lua_tointeger(L, 1);
    /* The tier the landing was judged in, from the SHIM's count, not the
     * program's: a refusal the JIT recorder absorbed (trace_abort drops the
     * error, lj_trace.c) opens the reserve tier too, and the program never
     * sees it.  Two or more since the run began: an earlier one opened it
     * (the program keeps its data, so no proof can close it between). */
    W16R_TIER = statn(L, "_OCLJ_GCSTATS", 4) - W16R_REF0 >= 2;
    W16_USED = j_core_used(L);
    W16_DELTA = statn(L, "_OCLJ_WALLSTATS", 13);
  }
  return 0;
}

/* W17's sandbox (d2-verdict): a fill of live 64-byte tables into a
 * pre-sized holder, inside a pcall, until refused (bounded: 200 000), in a
 * coroutine resumed under the watchdog's arm -- the sandbox's tops, no
 * kernel slice.  The holder never grows, so every growth is a TNEW: check
 * first, then the table, one checkpoint per object. */
static const char *W17_CHUNK =
  "local h, n = __w17h, 0 "
  "local co = coroutine.create(function() "
  "  local ok = pcall(function() while n < 200000 do n = n + 1 h[n] = {n} end end) "
  "  coroutine.yield(ok and 1 or 0) "
  "end) "
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "local okr, r = coroutine.resume(co) "
  "_OCLJ_WATCHDOG.disarm(t) "
  "__w17 = okr and r or -1";

/* W18's program (j2-safety's K1): the sandbox fills live tables to
 * __k1target (1 KB under its burst top), then crosses with ONE allocation no
 * checkpoint precedes -- mode 1 an array doubling (+32 KB, rawset), mode 2
 * a concatenation of two kept 10 KB strings -- and yields.  The kernel then
 * packs, still armed (the first pack is machine.lua's own, of the resume's
 * results) and after the disarm.  Every one protected here so the case can
 * count; machine.lua's are not, and a refusal there is a dead machine.
 * Bounded: 4 000 000 tables (__f is pre-sized from C, so it never grows). */
static const char *W18_CHUNK =
  "local f, h = __f, {} for i = 1, 4096 do h[i] = i end __h = h "
  "local A, B = string.rep('a', __k1cat), string.rep('b', __k1cat) "
  "local cb = function() end "
  "local nf = 0 "
  "__k1r = {0, 0, 0, 0, 0, 0, 0} "
  "__k1s = false "
  "local R = __k1r "
  "local co = coroutine.create(function() "
  "  local target = __k1target "
  "  local ok = pcall(function() "
  "    while nf < 4000000 and collectgarbage('count') * 1024 < target do nf = nf + 1 f[nf] = {nf} end "
  "  end) "
  "  if not ok then R[3] = R[3] + 1 end "
  "  if __k1mode == 1 then "
  "    if pcall(rawset, h, 4097, true) then R[4] = 1 end "
  "  elseif __k1mode == 2 then "
  "    local okc, s = pcall(function() return A .. B end) "
  "    if okc then __k1s = s R[4] = 1 end "
  "  end "
  "  coroutine.yield() "
  "end) "
  "__k1run = function() "
  "  local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "  local ok0 = pcall(table.pack, coroutine.resume(co)) "
  "  local k = ok0 and 0 or 1 R[7] = k "
  "  for i = 1, 6 do if not pcall(table.pack, i, i, i) then k = k + 1 end end "
  "  _OCLJ_WATCHDOG.disarm(t) "
  "  local k2 = 0 "
  "  for i = 1, 6 do if not pcall(table.pack, i, i, i) then k2 = k2 + 1 end end "
  "  R[1] = k R[2] = k2 R[6] = nf "
  "end";

/* W19's program (j2-safety's K8, its window-filling mode): the sandbox
 * makes 8 000 caught attempts to add one live table each, which leaves the
 * heap at its reserve tier's ceiling -- top plus THE WINDOW; R[5] is the
 * excursion it reached, read before the kernel allocates.  Then the kernel,
 * still armed and then at depth 0, makes ONE table of __k8n array slots. */
static const char *W19_CHUNK =
  "local h, fails, i = __h, 0, 0 local cb = function() end "
  "local n8 = __k8n "
  "__k8r = {0, 0, 0, 0, 0, 0} local R = __k8r "
  "local co = coroutine.create(function() "
  "  local function add1() i = i + 1 h[i] = {i} end "
  "  for attempt = 1, 8000 do if not pcall(add1) then i = i - 1 fails = fails + 1 end end "
  "end) "
  "__k8run = function() "
  "  local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "  R[1] = coroutine.resume(co) and 1 or 0 "
  "  R[5] = select(2, _OCLJ_WALLSTATS()) R[6] = select(14, _OCLJ_WALLSTATS()) or 0 "
  "  R[2] = pcall(__k8mk, n8) and 1 or 0 "
  "  _OCLJ_WATCHDOG.disarm(t) "
  "  R[3] = pcall(__k8mk, n8) and 1 or 0 "
  "  R[4] = fails "
  "end";
static int w19_mk(lua_State *L) { lua_createtable(L, (int)lua_tointeger(L, 1), 0); return 1; }


/* W20's program (design "lifetime", 2026-10-05): W16R's -- the step's own
 * handler absorbs the first refusal and the fill goes on with its data kept,
 * as a refusal the probe's paint or the JIT recorder absorbed lets it -- with
 * the heap recorded at BOTH refusals (rec 10 at the first, before anything
 * else allocates; rec 1 at the second).  What the second chance bought is
 * used_2 - used_1. */
static const char *W20_CHUNK =
  "local rec, held, count, stage, slot, nfail = __w20rec, {}, 0, 'filling/0', {}, 0 "
  "__w20h = held "
  "local function uniq(len, i) local s = tostring(i) return string.rep('x', len - #s) .. s end "
  "local step "
  "step = function() "
  "  local ok = pcall(function() "
  "    for k = 1, 100 do "
  "      count = count + 1 held[count] = uniq(32, count) "
  "      local junk = uniq(24, count) .. '!' "
  "    end "
  "  end) "
  "  if not ok then "
  "    nfail = nfail + 1 "
  "    if nfail == 1 then rec(10, count) end "
  "    if nfail >= 2 then rec(1, count) held = nil __w20h = nil return end "
  "  end "
  "  stage = 'filling/' .. count "
  "  slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "end "
  "slot[1] = { key = false, times = 1, callback = step, interval = 0, timeout = 0 } "
  "local co = coroutine.create(function() "
  "  for r = 1, 400 do "
  "    local sig = table.pack(coroutine.yield()) "
  "    local hd = slot[1] "
  "    if not hd then return end "
  "    slot[1] = nil "
  "    if not pcall(hd.callback) then rec(2, count) coroutine.yield('stop') return end "
  "  end "
  "end) "
  "local cb = function() end "
  "__w20k = function() "
  "  for r = 1, 402 do "
  "    local t = _OCLJ_WATCHDOG.arm(3600, cb, true) "
  "    local res = table.pack(coroutine.resume(co, 'timer')) "
  "    _OCLJ_WATCHDOG.disarm(t) "
  "    if not res[1] then rec(3, count) return end "
  "    if res[2] == 'stop' or coroutine.status(co) == 'dead' then return end "
  "  end "
  "end";
static long long W20_U[16];
static long long W20_C[16];
static double W20_T[16];
static int W20_N[16];
static FakeState *W20_S;       /* the legacy path keeps the figure on the Java side */
static int w20_rec(lua_State *L) {
  int code = (int)lua_tointeger(L, 1);
  if (code < 0 || code > 15) return 0;
  if (W20_N[code]++ == 0) {
    W20_U[code] = W20_S ? j_used(L, W20_S) : j_core_used(L);
    W20_C[code] = (long long)lua_tonumber(L, 2);
    W20_T[code] = statn(L, "_OCLJ_WALLSTATS", 14);   /* the tier's credit; -1 before it */
  }
  return 0;
}
#ifndef W20_N_CAPS
#define W20_N_CAPS 8
#endif
#define W20_RSV 4096          /* FIXED, as W19's 11 KB is: a shim that grows the reserve fails here */

/* W21's sandbox: a fill of live tables (W17's) inside pcall until refused;
 * then, STILL HOLDING, the recovery a real program makes before it drops:
 * 16 kept lines, 100 garbage strings (the cycles THE CADENCE runs on them
 * are the proofs the reserve has to survive), 16 more kept lines -- about
 * 2 KB kept, 8 KB granted -- then the drop, then new data. */
static const char *W21_CHUNK =
  "local h, n, m = __w21h, 0, {} "
  "local co = coroutine.create(function() "
  "  local ok = pcall(function() while n < 200000 do n = n + 1 h[n] = {n} end end) "
  "  if ok then coroutine.yield(-1) return end "
  "  for i = 1, 16 do m[i] = string.format('%s: line %d of the report, still held', 'not enough memory', i) end "
  "  for i = 1, 100 do local junk = string.format('%d', i) .. ' garbage between the lines of the report' end "
  "  for i = 17, 32 do m[i] = string.format('%s: line %d of the report, still held', 'not enough memory', i) end "
  "  __w21h = nil h = nil "
  "  local s = string.rep('y', 256) "
  "  local t = {1, 2, 3} "
  "  coroutine.yield(#m * 1000000 + #s * 100 + #t) "
  "end) "
  "local t = _OCLJ_WATCHDOG.arm(3600, function() end, true) "
  "local okr, r = coroutine.resume(co) "
  "_OCLJ_WATCHDOG.disarm(t) "
  "__w21 = okr and r or -2";

int main(void) {
  lua_State *L;
  jint used0, used1, used2, usedBeforePush, usedAfterPush;
  long long gc0, gc1, gc2;
  int st, pushedMemo, rawStatus;
  long long cmax;
  char d[512];

  /* UNBUFFERED on purpose, and _IONBF rather than _IOLBF.  One of this file's
   * negative controls (negative-control.sh, "norefuse") expects the process to
   * DIE partway through, and a buffered stdout loses every line it had already
   * produced -- turning "it got as far as M5, then the bare-frame push killed
   * it" into an empty log that proves nothing.  _IOLBF does not help: msvcrt
   * accepts it and silently treats it as full buffering, which is exactly how
   * this was measured (an empty log, twice). */
  setvbuf(stdout, NULL, _IONBF, 0);

  printf("mem_test -- lj52 memory accounting\n");

  memset(&FS, 0, sizeof FS);
  L = luaL_newstate();                    /* -> lj52_newstate */
  if (!L) { printf("  FAIL  luaL_newstate returned NULL\n"); return 1; }
  luaL_openlibs(L);
  lua_pushliteral(L, "_OCLJ_WALLSTATS");   /* interned for good: see w_newstate */
  lua_setfield(L, LUA_REGISTRYINDEX, "__wallname");

  /* ---- M0 ---------------------------------------------------------- */
  /* Which allocator the state's blocks live in.  A state on the C library
   * fallback still passes every accounting check below, so without this the
   * suite could not tell the two apart. */
  {
    double h = GC_HEAP(L);
    snprintf(d, sizeof d, "_OCLJ_GCSTATS heap=%g (1 = own lj_alloc arena, 0 = libc, -1 = absent)", h);
    ok(h == 1, "M0 the state's heap is its own lj_alloc arena", d);
  }

  /* ---- M1 ---------------------------------------------------------- */
  st = alloc_tables(L, 2000);
  ok(st == 0 && FS.sets == 0 && FS.used == 0,
     "M1 uncapped state is not charged",
     st == 0 ? "2000 tables allocated, setluamemory never called"
             : "the allocation itself failed");

  /* ---- M2 ---------------------------------------------------------- */
  FS.total = 64 * 1024 * 1024;
  lua_setallocf(L, NULL, L);              /* ud != NULL: jnlua's "capped" form */
  st = alloc_tables(L, 2000);
  ok(st == 0 && FS.sets == 0,
     "M2 capped but unbound: still not charged",
     "lua_setallocf before the javastate exists is harmless");

  bind_javastate(L, (void *)&FS);
  /* Binding allocates a userdata and writes a registry slot, and the shim
   * settles its banked pre-binding bytes on the first chargeable call, so
   * `used` becomes NON-ZERO and POSITIVE here.  Positive is the assertion that
   * matters: before the pending accumulator existed, the bytes allocated
   * before the binding were dropped and then CREDITED when freed, driving
   * `used` negative -- which reads back as a machine with more memory than its
   * cap.  Measured at -387188 across one allocate-then-collect cycle. */
  sprintf(d, "used=%ld after settling up", (long)FS.used);
  ok(FS.used >= 0, "M2b settling up at bind leaves used non-negative", d);

  /* ---- M3 ---------------------------------------------------------- */
  used0 = FS.used;
  gc0 = lj_bytes(L);
  st = alloc_tables(L, 20000);
  used1 = FS.used;
  gc1 = lj_bytes(L);
  sprintf(d, "used %ld -> %ld (+%ld) over 20000 tables",
          (long)used0, (long)used1, (long)(used1 - used0));
  ok(st == 0 && used1 - used0 > 200000, "M3 allocation is charged", d);

  /* M3b -- and charged EXACTLY, against LuaJIT's own counter. */
  sprintf(d, "we charged %+ld, LuaJIT counted %+ld  (difference %ld)",
          (long)(used1 - used0), (long)(gc1 - gc0),
          (long)((used1 - used0) - (gc1 - gc0)));
  ok((long long)(used1 - used0) == gc1 - gc0,
     "M3b charged to the byte, vs lua_gc(GCCOUNT)", d);

  /* M3c -- legacy mode keeps the NATIVE figure as well, absolute and to the
   * byte, so that a handover at any moment starts C mode on the right number
   * (docs/accounting-sync.md, "Handover").  Read the stat first: if reading it
   * allocated, Java's field and LuaJIT's count, taken after, would both move. */
  {
    double cu = GC_CUSED(L);
    long long gb = lj_bytes(L);
    sprintf(d, "native used %.0f, Java's field %ld, LuaJIT %ld", cu, (long)FS.used, (long)gb);
    ok(cu == (double)gb && cu == (double)FS.used,
       "M3c legacy mode keeps the native figure too, exact", d);
  }

  /* ---- M4: THE ANTI-RATCHET CONTROL --------------------------------- */
  lua_pushnil(L);
  lua_setglobal(L, "__hold");
  lua_gc(L, LUA_GCCOLLECT, 0);
  used2 = FS.used;
  gc2 = lj_bytes(L);
  sprintf(d, "used %ld -> %ld (%ld of %ld reclaimed)",
          (long)used1, (long)used2, (long)(used1 - used2), (long)(used1 - used0));
  ok(used1 - used2 > (used1 - used0) / 2, "M4 freeing is credited back", d);

  /* M4c -- credited exactly, too.  M4 only asserts an order of magnitude; a
   * collector pass that freed one block more or less than we credited shows up
   * only here. */
  sprintf(d, "we credited %+ld, LuaJIT counted %+ld  (difference %ld)",
          (long)(used2 - used1), (long)(gc2 - gc1),
          (long)((used2 - used1) - (gc2 - gc1)));
  ok((long long)(used2 - used1) == gc2 - gc1,
     "M4c credited to the byte, vs lua_gc(GCCOUNT)", d);

  /* M4b -- and it never crosses zero.  Separate from M4 on purpose: dropping
   * the pre-binding bytes instead of banking them still passes M4 (the deltas
   * are right) while driving the ABSOLUTE figure negative, which reads back
   * through NativeLuaArchitecture as a machine with more memory than its cap
   * -- and, because OC derives totalMemory from the kernelMemory it measures
   * this way, as a machine sized from an under-measured kernel.  Measured
   * before the fix: kernelMemory 298053 and a boot that ran out of RAM; after:
   * 323809 and a boot that completes, on identical settings. */
  sprintf(d, "used=%ld", (long)used2);
  ok(used2 >= 0, "M4b used never goes negative", d);

  /* ---- M5 ----------------------------------------------------------- */
  FS.total = FS.used + 192 * 1024;
  cmax = w_creditmax(L, FS.total);        /* THE CREDIT: G + the kernel's slice */
  st = alloc_tables(L, 10000000L);
  sprintf(d, "pcall status=%d (LUA_ERRMEM=%d)  used=%ld cap=%ld (+ credit %ld)",
          st, LUA_ERRMEM, (long)FS.used, (long)FS.total, (long)cmax);
  ok(st == LUA_ERRMEM && FS.used <= FS.total + cmax, "M5 the cap refuses", d);
  lua_settop(L, 0);

  /* ---- M6 / M7: the coupling ---------------------------------------
   * Stage the raw-push wrapper and the stack slack WHILE there is still
   * room, so that what the cap refuses below is the pushcclosure under
   * test and not the machinery around it. */
  /* M5's refusal ARMS the collector (lj52shim.c, THE CREDIT), so the push
   * below would collect M5's garbage at its checkpoint and fit: collect it
   * now.  And 64 KB of live ballast, because a cap that the credit and the
   * kernel's slice exhaust must sit 48 KB or more under the live set. */
  lua_gc(L, LUA_GCCOLLECT, 0);
  settle_gc(L);
  lua_gc(L, LUA_GCCOLLECT, 0);            /* settle_gc's own garbage too: the cycle the refusal
                                           * arms must find nothing to free, or M7 reads the push
                                           * net of what it freed (unarmed now: no two-flip alias) */
  lua_createtable(L, 8192, 0);
  lua_setfield(L, LUA_REGISTRYINDEX, "__ballast");
  lua_pushcfunction(L, raw_push);         /* memo now warm for raw_push */
  lua_checkstack(L, 20);

  FS.total = (jint)w_exhausted(L, FS.used);   /* not one byte to spare, the credit included */

  rawStatus = lua_pcall(L, 0, 1, 0);      /* runs raw_push -> lua_pushcclosure */
  lua_settop(L, 0);

  usedBeforePush = FS.used;
  lua_pushcfunction(L, a_cfunc);          /* -> lj52_pushcfunction, cold */
  pushedMemo = lua_isfunction(L, -1);
  usedAfterPush = FS.used;
  lua_settop(L, 0);

  sprintf(d, "used %ld, cap %ld, the credit spent; pushed=%s", (long)usedBeforePush,
          (long)FS.total, pushedMemo ? "yes" : "NO");
  ok(pushedMemo, "M6a lua_pushcfunction survives an exhausted cap",
     pushedMemo ? d : "REFUSED -- this is the bare-frame ERRMEM that kills the JVM");

  sprintf(d, "lua_pushcclosure under pcall -> status %d (LUA_ERRMEM=%d)",
          rawStatus, LUA_ERRMEM);
  ok(rawStatus == LUA_ERRMEM, "M6b a RAW push is refused at that same cap",
     rawStatus == LUA_ERRMEM ? d
       : "the raw push SUCCEEDED, so M6a proves nothing: the cap was not tight");

  sprintf(d, "used %ld -> %ld (+%ld)", (long)usedBeforePush, (long)usedAfterPush,
          (long)(usedAfterPush - usedBeforePush));
  ok(usedAfterPush > usedBeforePush, "M7 the unrefusable push is still charged",
     usedAfterPush > usedBeforePush ? d
       : "the push allocated off the books -- an uncharged path is a hole");

  /* ---- M8 ------------------------------------------------------------ */
  FS.total = 64 * 1024 * 1024;
  clear_javastate(L);
  FS.sets = 0;
  st = alloc_tables(L, 5000);
  ok(st == 0 && FS.sets == 0,
     "M8 clearing the javastate stops the accounting",
     st == 0 ? "5000 tables allocated, setluamemory never called again"
             : "the allocation failed after the javastate was cleared");

  /* ================================================================== *
   * The trace flush under memory pressure
   * ================================================================== */
  /* The main state's flag, as the M cases leave it -- printed, not asserted,
   * because M5-M7's dynamics are not this section's to control.  M5-M7 ran
   * proven emergency cycles AT THE WALL (headroom ~0), each of which raised
   * flush_wanted, and nothing in M1-M8 is a resume, so the flag stands.
   * That is the design: the flag waits for the safe point.  It is also why
   * the P cases below get a state of their own -- the first draft shared
   * this one, P1's arm() consumed the stale flag and flushed, and P2 then
   * had nothing left to measure.  Observed on the first run, then isolated. */
  printf("        main state after M8: flush_wanted=%.0f trace_flushes=%.0f "
         "(-1 == stat absent; a standing flag here is M5-M7's, awaiting a resume)\n",
         GC_FLUSHWANT(L), GC_FLUSHES(L));

  {
    double live0, arms0, coll0, bail0, ref0, fl0, steps;
    double armsA, collA, wantA, liveA, flA;
    double armedB, collB, wantB, liveB, flB, flbytes, flref, armedB2, collB2;
    jint base, base2, usedB, usedB2, usedB3;
    long drop;
    /* A fresh state with its own record and its own counters: every arm,
     * collect and flush below is this section's, from zero. */
    FakeState PS;
    lua_State *P = luaL_newstate();     /* -> lj52_newstate, JIT on */
    if (!P) { printf("  FAIL  luaL_newstate returned NULL for the P state\n"); return 1; }
    luaL_openlibs(P);
    snprintf(d, sizeof d, "_OCLJ_GCSTATS heap=%g", GC_HEAP(P));
    ok(GC_HEAP(P) == 1, "M0b the second state is on its own arena too", d);
    memset(&PS, 0, sizeof PS);
    PS.total = 64 * 1024 * 1024;
    lua_setallocf(P, NULL, P);          /* jnlua's capped form, as in M2 */
    bind_javastate(P, (void *)&PS);
    lua_gc(P, LUA_GCCOLLECT, 0);
    lua_gc(P, LUA_GCCOLLECT, 0);

    /* ---- P0 ------------------------------------------------------------ */
    st = runstr(P, TRACE_CHUNK);
    live0 = JIT_LIVE(P);
    sprintf(d, "traces_live=%.0f after 40 hot loops%s%s", live0,
            st == 0 ? "" : "  chunk failed: ", st == 0 ? "" : errtop(P));
    ok(st == 0 && live0 >= 24, "P0 the JIT compiled a few dozen resident traces", d);
    lua_settop(P, 0);
    lua_gc(P, LUA_GCCOLLECT, 0);
    lua_gc(P, LUA_GCCOLLECT, 0);
    base = PS.used;
    arms0 = GC_ARMS(P); coll0 = GC_COLLECTS(P); bail0 = GC_BAILOUTS(P);
    ref0 = GC_REFUSALS(P); fl0 = GC_FLUSHES(P);
    printf("        base live set used=%ld  arms=%.0f collects=%.0f bailouts=%.0f "
           "refusals=%.0f trace_flushes=%.0f (-1 == stat absent)\n",
           (long)base, arms0, coll0, bail0, ref0, fl0);

    /* ---- P1: garbage resolves the pressure -> no flush ------------------ */
    /* 1 MB of headroom above the live set; the watermark is max(total/4,
     * 128 KB).  64 KB tables outrun the paced collector -- lj_gc_step's
     * budget is 2000 units per checkpoint and a full cycle is hundreds of
     * them -- so the heap climbs into the watermark, the allocator arms, and
     * the very next checkpoint runs the whole cycle and frees every one. */
    PS.total = base + 1024 * 1024;
    steps = churn(P, 8192, coll0, 400, &st);
    armsA = GC_ARMS(P); collA = GC_COLLECTS(P); wantA = GC_FLUSHWANT(P);
    sprintf(d, "%.0f steps of 64 KB garbage (status %d): arms %.0f -> %.0f, collects %.0f -> %.0f, "
            "bailouts %+.0f, refusals %+.0f, used=%ld of %ld",
            steps, st, arms0, armsA, coll0, collA, GC_BAILOUTS(P) - bail0,
            GC_REFUSALS(P) - ref0, (long)PS.used, (long)PS.total);
    ok(st == 0 && armsA > arms0 && collA > coll0 && GC_BAILOUTS(P) == bail0 && GC_REFUSALS(P) == ref0,
       "P1a an emergency cycle armed and was proven to complete", d);
    sprintf(d, "headroom after the cycle = %ld (watermark %ld); flush_wanted=%.0f",
            (long)(PS.total - PS.used), wmark(PS.total), wantA);
    ok(wantA == 0, "P1b garbage restored the headroom: flush NOT wanted",
       wantA < 0 ? "flush_wanted stat ABSENT (older shim)" : d);
    st = runstr(P, ARM_DISARM);
    liveA = JIT_LIVE(P); flA = GC_FLUSHES(P);
    sprintf(d, "arm()+disarm(): traces_live %.0f -> %.0f, trace_flushes=%.0f%s%s",
            live0, liveA, flA, st == 0 ? "" : "  arm failed: ", st == 0 ? "" : errtop(P));
    ok(st == 0 && liveA == live0, "P1c the safe point left the traces alone", d);
    ok(flA == 0, "P1d trace_flushes is 0",
       flA < 0 ? "trace_flushes stat ABSENT (older shim)" : d);
    lua_settop(P, 0);

    /* ---- P2: live data holds headroom under the watermark -> flush ------ */
    lua_gc(P, LUA_GCCOLLECT, 0);
    lua_gc(P, LUA_GCCOLLECT, 0);
    base2 = PS.used;
    coll0 = GC_COLLECTS(P);
    /* 256 KB of headroom, then a 200 KB LIVE table parked in the registry:
     * headroom 56 KB is under half the 128 KB floor -- where a proven cycle
     * asks for the flush (lj52shim.c, HALF THE WATERMARK; until 2026-10-04 it
     * was the whole watermark, and this case held 160 KB) -- and no cycle can
     * free it. */
    PS.total = base2 + 256 * 1024;
    lua_createtable(P, 25600, 0);
    lua_setfield(P, LUA_REGISTRYINDEX, "__live");
    armedB = GC_ARMED(P);
    sprintf(d, "used=%ld of %ld (headroom %ld), armed=%.0f", (long)PS.used,
            (long)PS.total, (long)(PS.total - PS.used), armedB);
    ok(armedB == 1, "P2a the live allocation armed the emergency cycle", d);
    steps = churn(P, 0, coll0, 10000, &st);
    collB = GC_COLLECTS(P); wantB = GC_FLUSHWANT(P); liveB = JIT_LIVE(P);
    sprintf(d, "%.0f steps (status %d): collects %.0f -> %.0f, headroom now %ld "
            "(half the watermark %ld), flush_wanted=%.0f, traces_live=%.0f",
            steps, st, coll0, collB, (long)(PS.total - PS.used), wmark(PS.total) / 2,
            wantB, liveB);
    ok(st == 0 && collB > coll0 && (long)(PS.total - PS.used) < wmark(PS.total) / 2,
       "P2b the cycle completed and headroom is STILL under half the watermark", d);
    ok(wantB == 1, "P2c the collector raised flush_wanted at the proof",
       wantB < 0 ? "flush_wanted stat ABSENT (older shim)" : d);
    ok(liveB == live0, "P2d nothing flushed yet: the allocator never flushes",
       d);

    /* THE SAFE POINT. */
    usedB = PS.used;
    st = runstr(P, ARM_DISARM);
    flB = GC_FLUSHES(P); liveB = JIT_LIVE(P); wantB = GC_FLUSHWANT(P);
    flbytes = GC_FLUSHBYTES(P); flref = GC_FLUSHREF(P); armedB2 = GC_ARMED(P);
    usedB2 = PS.used;
    sprintf(d, "arm(): trace_flushes=%.0f flush_wanted=%.0f traces_live=%.0f "
            "flush_bytes=%.0f refusals=%.0f re-armed=%.0f%s%s",
            flB, wantB, liveB, flbytes, flref, armedB2,
            st == 0 ? "" : "  arm failed: ", st == 0 ? "" : errtop(P));
    ok(st == 0 && flB == 1, "P2e the arm entry point flushed once",
       flB < 0 ? "trace_flushes stat ABSENT (older shim)" : d);
    ok(liveB == 0, "P2f no trace is live after the flush", d);
    ok(wantB == 0 && armedB2 == 1,
       "P2g the flag is consumed and the cycle re-armed", d);
    lua_settop(P, 0);

    /* Drive the re-armed cycle to its proof: the GCtrace objects the flush
     * unlinked are swept and credited back through the allocator. */
    collB = GC_COLLECTS(P);
    steps = churn(P, 0, collB, 10000, &st);
    collB2 = GC_COLLECTS(P);
    usedB3 = PS.used;
    drop = (long)usedB - (long)usedB3;
    sprintf(d, "used %ld -> %ld -> %ld: dropped %ld across arm + %.0f steps "
            "(status %d, collects %.0f -> %.0f); flush unlinked %.0f bytes of trace metadata",
            (long)usedB, (long)usedB2, (long)usedB3, drop, steps, st, collB, collB2, flbytes);
    /* At least the metadata, minus the one 64-byte churn table that is live
     * at the proof and whatever the arm's own registry write grew: 1 KB of
     * slack against a figure in the tens of KB. */
    ok(st == 0 && collB2 > collB && flbytes > 0 && drop >= (long)flbytes - 1024,
       "P2h the accounted used dropped by at least the trace metadata", d);

    /* Unbind before close, as jnlua's close_protected does and M8 proves,
     * so lua_close never writes through the userdata it is about to free. */
    PS.total = 64 * 1024 * 1024;
    clear_javastate(P);
    lua_close(P);                       /* -> lj52_close: stops the timer too */
  }

  /* ================================================================== *
   * C MODE: the figures held natively after the handover
   * (docs/accounting-sync.md).  A state of its own, bound exactly as jnlua
   * binds a capped one and handed over exactly as LuaStateLuaJIT(int) hands
   * it over: LuaState's constructor runs controlled_newstate (lua_setallocf,
   * then newstate_protected binds the javastate), does its own allocating
   * work in legacy mode, and only then does the subclass constructor call
   * ocljSetTotalMemory.  LuaStateFactory.createState opens the libraries
   * after that.
   * ================================================================== */
  {
    FakeState CS;
    lua_State *C;
    jint legacyUsed, cap;
    long long u0, u1, u2, g0, g1, g2, f0, f1, f2, base;
    double calls0, calls1, jni0, jni1, jniL0, reads0, reads1, arms0, coll0;
    double armed0, armedC, want0, wantC, steps;
    int gets0, sets0, getsL0, env0, envL0, nstat, st2, pushed;

    memset(&CS, 0, sizeof CS);
    C = luaL_newstate();                /* -> lj52_newstate */
    if (!C) { printf("  FAIL  luaL_newstate returned NULL for the C state\n"); return 1; }
    CS.total = 64 * 1024 * 1024;        /* LuaState(int): luaMemoryTotal = memory */
    lua_setallocf(C, NULL, C);          /* controlled_newstate: the capped form */
    bind_javastate(C, (void *)&CS);     /* newstate_protected */
    lua_pushliteral(C, "_OCLJ_WALLSTATS");   /* interned for good: see w_newstate */
    lua_setfield(C, LUA_REGISTRYINDEX, "__wallname");

    /* ---- C0: legacy until the handover, then the native figures --------- */
    sprintf(d, "csync=%.0f, native used=%ld (-1 = not handed over)",
            GC_CSYNC(C), (long)j_core_used(C));
    ok(GC_CSYNC(C) == 0 && j_core_used(C) == -1,
       "C0a a freshly bound state is in legacy mode", d);

    getsL0 = CS.gets;
    envL0 = ENVCALLS;
    jniL0 = GC_AJNI(C);
    st = alloc_tables(C, 3000);         /* the LuaState constructor's own work */
    lua_settop(C, 0);
    sprintf(d, "3000 tables in legacy mode: getluamemory calls %+d, getthreadenv %+d, allocator calls through JNI %+.0f",
            CS.gets - getsL0, ENVCALLS - envL0, GC_AJNI(C) - jniL0);
    ok(st == 0 && CS.gets - getsL0 > 3000 && GC_AJNI(C) - jniL0 == (double)(CS.gets - getsL0)
         && ENVCALLS - envL0 == CS.gets - getsL0,
       "C0d legacy allocations cross JNI, counted three ways", d);

    legacyUsed = CS.used;
    g0 = lj_bytes(C);
    j_settotal(C, &CS, CS.total);       /* LuaStateLuaJIT(int): ocljSetTotalMemory(memory) */
    u0 = j_core_used(C);
    sprintf(d, "csync=%.0f, native cap %.0f (Java %ld); used: native %ld, Java's field %ld, LuaJIT %ld",
            GC_CSYNC(C), GC_CTOTAL(C), (long)CS.total, (long)u0, (long)legacyUsed, (long)g0);
    ok(GC_CSYNC(C) == 1 && GC_CTOTAL(C) == (double)CS.total && u0 == (long long)legacyUsed && u0 == g0,
       "C0b the handover: native cap and figure are Java's and LuaJIT's", d);
    nstat = statcount(C, "_OCLJ_GCSTATS");
    sprintf(d, "%d values (14 before 2026-10-03)", nstat);
    ok(nstat == 20, "C0c _OCLJ_GCSTATS returns 20 values", d);

    /* ---- C1: THE POINT OF THE CHANGE ---------------------------------- */
    gets0 = CS.gets; sets0 = CS.sets; env0 = ENVCALLS;
    calls0 = GC_ACALLS(C); jni0 = GC_AJNI(C);
    luaL_openlibs(C);                   /* LuaStateFactory.createState */
    st = alloc_tables(C, 20000);
    lua_settop(C, 0);
    calls1 = GC_ACALLS(C); jni1 = GC_AJNI(C);
    sprintf(d, "openlibs + 20000 tables: allocator calls %+.0f, of them through JNI %+.0f; "
            "getluamemory %+d, setluamemory %+d, getthreadenv %+d",
            calls1 - calls0, jni1 - jni0, CS.gets - gets0, CS.sets - sets0, ENVCALLS - env0);
    ok(st == 0 && calls1 - calls0 > 20000 && jni1 == jni0 && CS.gets == gets0 && CS.sets == sets0
         && ENVCALLS == env0,
       "C1 after the handover no allocation crosses into the JVM", d);

    /* ---- C2: exact, to the byte, absolute ----------------------------- */
    u1 = j_core_used(C); g1 = lj_bytes(C); f1 = j_free(C, &CS);
    sprintf(d, "native used %ld, LuaJIT %ld (difference %ld); getFreeMemory %ld",
            (long)u1, (long)g1, (long)(u1 - g1), (long)f1);
    ok(u1 == g1 && f1 == (long long)CS.total - g1,
       "C2a the native figure is LuaJIT's own count, to the byte", d);
    reads0 = GC_UREADS(C);
    f0 = j_free(C, &CS);
    reads1 = GC_UREADS(C);
    sprintf(d, "getFreeMemory=%ld; used reads %.0f -> %.0f", (long)f0, reads0, reads1);
    ok(reads1 - reads0 == 1, "C2b getFreeMemory reads the native figure, once", d);
    lua_pushnil(C);
    lua_setglobal(C, "__hold");
    lua_gc(C, LUA_GCCOLLECT, 0);
    u2 = j_core_used(C); g2 = lj_bytes(C);
    sprintf(d, "used %ld -> %ld (%ld reclaimed); LuaJIT %ld (difference %ld)",
            (long)u1, (long)u2, (long)(u1 - u2), (long)g2, (long)(u2 - g2));
    ok(u2 == g2 && u1 - u2 > 200000, "C2c frees are credited, to the byte", d);

    /* ---- C3: the cap moves both ways, at once ------------------------- */
    lua_gc(C, LUA_GCCOLLECT, 0);
    u0 = j_used(C, &CS);
    cap = (jint)(u0 + 192 * 1024);
    j_settotal(C, &CS, cap);            /* setTotalMemory(lower) */
    cmax = w_creditmax(C, cap);
    st = alloc_tables(C, 10000000L);
    lua_settop(C, 0);
    u1 = j_used(C, &CS);
    sprintf(d, "cap lowered to used+192 KB = %ld: status %d (LUA_ERRMEM=%d), used %ld (credit %ld), native cap %.0f",
            (long)cap, st, LUA_ERRMEM, (long)u1, (long)cmax, GC_CTOTAL(C));
    ok(st == LUA_ERRMEM && u1 <= cap + cmax, "C3a a lowered cap refuses on the next allocations", d);
    lua_gc(C, LUA_GCCOLLECT, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);   /* setTotalMemory(higher) */
    st = alloc_tables(C, 20000);
    lua_settop(C, 0);
    sprintf(d, "cap raised to 64 MB: status %d, used %ld", st, (long)j_used(C, &CS));
    ok(st == 0, "C3b a raised cap admits at once", d);

    /* ---- C4: OC's save pattern ---------------------------------------- */
    /* NativeLuaArchitecture.save: setTotalMemory(Integer.MAX_VALUE), persist
     * (which allocates freely), finally setTotalMemory(the machine's cap). */
    lua_pushnil(C);
    lua_setglobal(C, "__hold");
    lua_gc(C, LUA_GCCOLLECT, 0);
    u0 = j_used(C, &CS);
    cap = (jint)(u0 + 64 * 1024);
    j_settotal(C, &CS, cap);            /* the machine's cap */
    j_settotal(C, &CS, 2147483647);     /* save(): Integer.MAX_VALUE */
    st = alloc_tables(C, 20000);        /* the persist, far past the machine's cap */
    lua_settop(C, 0);
    u1 = j_used(C, &CS);
    f0 = j_free(C, &CS);
    sprintf(d, "under Integer.MAX_VALUE: status %d, used %ld (machine cap %ld), free %ld",
            st, (long)u1, (long)cap, (long)f0);
    ok(st == 0 && u1 > cap && f0 == 2147483647LL - u1,
       "C4a the save's raised cap lets the persist allocate past the machine's", d);
    j_settotal(C, &CS, cap);            /* finally: the machine's cap again */
    f1 = j_free(C, &CS);
    st2 = try_tables(C, 1000);
    sprintf(d, "cap restored to %ld under used %ld: free %ld, next growth status %d (LUA_ERRMEM=%d)",
            (long)cap, (long)j_used(C, &CS), (long)f1, st2, LUA_ERRMEM);
    ok(f1 == 0 && st2 == LUA_ERRMEM, "C4b the restored cap reads free 0 and refuses growth", d);
    lua_pushnil(C);
    lua_setglobal(C, "__hold");
    lua_gc(C, LUA_GCCOLLECT, 0);
    f2 = j_free(C, &CS);
    st2 = try_tables(C, 100);
    sprintf(d, "after collecting the persist's garbage: free %ld, status %d", (long)f2, st2);
    ok(f2 > 0 && st2 == 0, "C4c once that garbage is collected the machine runs again", d);

    /* ---- C5: the emergency collector against the native cap ----------- */
    /* C3a and C4b ran cycles at the wall, which raise flush_wanted; the
     * kernel's safe point consumes it, as it would before the next resume. */
    st = runstr(C, ARM_DISARM);
    lua_settop(C, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);   /* room, so the settling cannot arm anew */
    armed0 = settle_gc(C);
    lua_gc(C, LUA_GCCOLLECT, 0);        /* the live set, as P1 and P2 take it */
    lua_gc(C, LUA_GCCOLLECT, 0);
    base = j_used(C, &CS);
    arms0 = GC_ARMS(C); coll0 = GC_COLLECTS(C);
    j_settotal(C, &CS, (jint)(base + 1024 * 1024));
    steps = churn(C, 8192, coll0, 400, &st);
    sprintf(d, "%.0f steps of 64 KB garbage under a native cap of used+1 MB (status %d; armed before %.0f): "
            "arms %.0f -> %.0f, collects %.0f -> %.0f",
            steps, st, armed0, arms0, GC_ARMS(C), coll0, GC_COLLECTS(C));
    ok(st == 0 && armed0 == 0 && GC_ARMS(C) > arms0 && GC_COLLECTS(C) > coll0,
       "C5a the emergency cycle arms against the native cap and completes", d);

    st = runstr(C, ARM_DISARM);
    lua_settop(C, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);
    armed0 = settle_gc(C);
    lua_gc(C, LUA_GCCOLLECT, 0);
    lua_gc(C, LUA_GCCOLLECT, 0);
    want0 = GC_FLUSHWANT(C);
    base = j_used(C, &CS);
    coll0 = GC_COLLECTS(C);
    j_settotal(C, &CS, (jint)(base + 256 * 1024));
    lua_createtable(C, 25600, 0);       /* 200 KB LIVE: headroom under half the floor (P2) */
    lua_setfield(C, LUA_REGISTRYINDEX, "__live");
    armedC = GC_ARMED(C);
    steps = churn(C, 0, coll0, 10000, &st);
    wantC = GC_FLUSHWANT(C);
    sprintf(d, "before: armed %.0f, flush_wanted %.0f; 200 KB live under used+256 KB: armed=%.0f, %.0f steps (status %d), "
            "collects %.0f -> %.0f, headroom %ld (half the watermark %ld), flush_wanted=%.0f",
            armed0, want0, armedC, steps, st, coll0, GC_COLLECTS(C),
            (long)((long long)CS.total - j_used(C, &CS)), wmark(CS.total) / 2, wantC);
    ok(armed0 == 0 && want0 == 0 && armedC == 1 && st == 0 && GC_COLLECTS(C) > coll0 && wantC == 1,
       "C5b live data under half the watermark: armed, proven, flush wanted", d);
    lua_pushnil(C);
    lua_setfield(C, LUA_REGISTRYINDEX, "__live");
    st = runstr(C, ARM_DISARM);
    lua_settop(C, 0);

    /* ---- C6: the coupling, at an exhausted native cap ----------------- */
    lua_gc(C, LUA_GCCOLLECT, 0);
    lua_gc(C, LUA_GCCOLLECT, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);
    lua_settop(C, 0);
    lua_createtable(C, 8192, 0);        /* 64 KB of live ballast: see M6 */
    lua_setfield(C, LUA_REGISTRYINDEX, "__ballast");
    lua_pushcfunction(C, raw_push);     /* memo warm for raw_push on this state */
    lua_checkstack(C, 20);
    u0 = j_used(C, &CS);
    cmax = w_exhausted(C, u0);
    j_settotal(C, &CS, (jint)cmax);     /* not one byte to spare, the credit included */
    rawStatus = lua_pcall(C, 0, 1, 0);  /* raw_push -> lua_pushcclosure */
    lua_settop(C, 0);
    u1 = j_used(C, &CS);
    lua_pushcfunction(C, c_cfunc);      /* -> lj52_pushcfunction, cold */
    pushed = lua_isfunction(C, -1);
    u2 = j_used(C, &CS);
    lua_settop(C, 0);
    sprintf(d, "native cap %ld under used %ld, the credit spent: raw push status %d (LUA_ERRMEM=%d); memo push %s, used %ld -> %ld",
            (long)cmax, (long)u0, rawStatus, LUA_ERRMEM, pushed ? "succeeded" : "REFUSED", (long)u1, (long)u2);
    ok(rawStatus == LUA_ERRMEM && pushed && u2 > u1,
       "C6 exhausted cap: raw push refused, memo push succeeds, charged", d);

    /* ---- C6b: THE WINDOW is the sandbox's: the kernel has none --------- */
    /* (d2-prevent's case, with THE WINDOW's state.)  C6 exhausts the RESERVE
     * top; this one exhausts the kernel's BURST top, the record in BURST and
     * no verdict standing, where a kernel window would lend the push.  C
     * frames at depth 0 are the kernel.  The preconditions are asserted, so
     * the case cannot pass vacuously. */
    lua_settop(C, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);
    settle_gc(C);
    lua_gc(C, LUA_GCCOLLECT, 0);
    settle_gc(C);
    lua_pushcfunction(C, raw_push);     /* memo warm (C6 pushed it) */
    lua_checkstack(C, 20);
    {
      double tier6 = WALL_ODSTATE(C), win6 = WALL_WIN(C), k6 = WALL_KSLICE(C);
      long long t6;
      int i6;
      u0 = j_used(C, &CS);
      t6 = u0;
      for (i6 = 0; i6 < 8; i6++) t6 = u0 - (long long)k6 - w_odmax(t6) / 2;   /* T + G(T)/2 + K == used */
      j_settotal(C, &CS, (jint)t6);
      rawStatus = lua_pcall(C, 0, 1, 0);
      lua_settop(C, 0);
      j_settotal(C, &CS, 64 * 1024 * 1024);
      sprintf(d, "burst tier %.0f (want 0), window %.0f (want no verdict: 0, 1, or -1 before THE WINDOW), slice %.0f; "
                 "cap %ld = used %ld - G/2 - slice: raw push status %d (LUA_ERRMEM=%d)",
              tier6, win6, k6, (long)t6, (long)u0, rawStatus, LUA_ERRMEM);
      ok(tier6 == 0 && win6 != 2 && k6 > 0 && rawStatus == LUA_ERRMEM,
         "C6b the kernel at its burst top: raw push refused (no window)", d);
    }

    /* ---- C7: the accounting switched off, as jnlua's close does ------- */
    u0 = j_used(C, &CS);
    j_settotal(C, &CS, (jint)u0);       /* still not one byte to spare */
    lua_setallocf(C, NULL, NULL);       /* close: lua_setallocf(L, l_alloc_unchecked, NULL) */
    gets0 = CS.gets; sets0 = CS.sets;
    st = alloc_tables(C, 5000);
    lua_settop(C, 0);
    u1 = j_core_used(C); g1 = lj_bytes(C);
    sprintf(d, "status %d; getluamemory %+d, setluamemory %+d; native used %ld, LuaJIT %ld",
            st, CS.gets - gets0, CS.sets - sets0, (long)u1, (long)g1);
    ok(st == 0 && CS.gets == gets0 && CS.sets == sets0 && u1 == g1,
       "C7 accounting off: nothing refused, the figure still tracks", d);

    CS.total = 64 * 1024 * 1024;
    clear_javastate(C);
    lua_close(C);                       /* -> lj52_close, in C mode */

    /* ---- C8: the -1 answers ------------------------------------------- */
    {
      FakeState US;
      lua_State *F = lua_newstate(foreign_alloc, NULL);   /* LuaJIT's own: not the shim's allocator */
      lua_State *U = luaL_newstate();                      /* the shim's, never capped */
      long long nNull, nF, nU, fU;
      double syncU;
      if (!F || !U) { printf("  FAIL  a C8 state could not be created\n"); return 1; }
      memset(&US, 0, sizeof US);
      st = alloc_tables(U, 1000);
      lua_settop(U, 0);
#ifndef MEMTEST_OLD
      lj52_mem_settotal(NULL, 12345);   /* a closed state: no-ops, and no crash */
      lj52_mem_settotal(F, 12345);
#endif
      nNull = j_core_used(NULL);
      nF = j_core_used(F);
      nU = j_core_used(U);
      fU = j_free(U, &US);
      syncU = GC_CSYNC(U);
      sprintf(d, "no state %ld, foreign allocator %ld (after settotal), uncapped %ld; "
              "uncapped getFreeMemory %ld, csync %.0f",
              (long)nNull, (long)nF, (long)nU, (long)fU, syncU);
      ok(st == 0 && nNull == -1 && nF == -1 && nU == -1 && fU == 0 && syncU == 0,
         "C8 -1 where there is no handed-over record", d);
      lua_close(F);                     /* -> lj52_close: no record, a plain close */
      lua_close(U);
    }
  }

  /* ==================================================================
   * W: THE COLLECTOR AT THE WALL (docs/roadmap.md; bench/results-ramscale-
   * 2026-10-03.md).  Each case on its own fresh state, in C mode unless it
   * says legacy.  Written to FAIL on the shim of 2026-10-03 (cb29485d) and
   * seen to, before any pass counted.
   * ================================================================== */
  {
    FakeState WS;
    lua_State *W, *Wco;
    long long base, cap, u0, u1, H, G, w16dmax = 256;
    double coll0, coll1, bail0, refu0, arms0, st9, thr, gtot, steps, peak, lim, armedC;
    int round, allok, nreq, st2, st3, nrep;
    double cworst = 0;
    clock_t t0, t1, t2;
    double tnear, tfar, cnear, cfar;

    /* ---- W5: the parked collector (P3) ------------------------------- */
    /* An arm that lands while the collector sweeps: the next checkpoint
     * finishes the OLD cycle without atomic(), stops at the pause with the
     * threshold at 2 x estimate, and the white has not flipped, so the record
     * stays armed.  With the live set over half the cap nothing reaches that
     * threshold again: the collector is parked until the 65 536-call valve. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W5: no state\n"); return 1; }
    runstr(W, "local t = {} for i = 1, 10000 do t[i] = {i} end __live5 = t");
    runstr(W, "for i = 1, 1500 do local x = {i} end");
    lua_settop(W, 0);
    for (round = 0; round < 200000 && GC_STATE(W) != W_GCSSWEEP; round++)
      lua_gc(W, LUA_GCSTEP, 0);
    u0 = j_used(W, &WS);
    cap = u0 + 200 * 1024;              /* headroom under the watermark */
    w_setcap(W, &WS, cap, 1);
    st9 = GC_STATE(W);                  /* read BEFORE the arm: reading it after */
    arms0 = GC_ARMS(W);                 /* one w_tab already sees the pause     */
    /* Each w_tab is two allocator calls: lua_cpcall's closure, which arms in
     * the sweep, then lua_createtable's checkpoint, which ends the OLD cycle
     * at the pause, then its table.  Two of them cover the case where the
     * closure is not the arming call. */
    w_tab(W, 0, 0);
    w_tab(W, 0, 0);
    thr = GC_THRESH(W); gtot = GC_GTOTAL(W);
    sprintf(d, "state %.0f before; arms %.0f -> %.0f; after two checkpoints: state %.0f, armed %.0f, stepmul %.0f, "
            "threshold %.0f vs gc.total %.0f, park resets %.0f",
            st9, arms0, GC_ARMS(W), GC_STATE(W), GC_ARMED(W), GC_STEPMUL(W), thr, gtot, WALL_PARKRESETS(W));
    ok(st9 == W_GCSSWEEP && GC_ARMS(W) > arms0 && (thr <= gtot || GC_ARMED(W) == 0)
         && WALL_PARKRESETS(W) >= 1,
       "W5a an arm in the sweep does not leave the collector parked", d);
    /* 1.28 MB of 64 B garbage through 200 KB of headroom, over 1 MB live:
     * LuaJIT's own threshold (2 x the estimate) is past the cap, so only the
     * emergency cycle can collect it.  Parked, nothing does until the cap. */
    coll0 = GC_COLLECTS(W); bail0 = GC_BAILOUTS(W);
    steps = churn(W, 0, 1e18, 20000, &st);
    sprintf(d, "20000 x 64 B: status %d (LUA_ERRMEM=%d) after %.0f steps; collects %.0f -> %.0f, bailouts %.0f -> %.0f",
            st, LUA_ERRMEM, steps, coll0, GC_COLLECTS(W), bail0, GC_BAILOUTS(W));
    ok(st == 0 && GC_COLLECTS(W) > coll0 && GC_BAILOUTS(W) == bail0,
       "W5b and the churn after it collects, never refused", d);
    clear_javastate(W);
    lua_close(W);

    /* W5c: the valve must count attempts, not the armed cycle's own sweep. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W5c: no state\n"); return 1; }
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCSTOP, 0);
    /* 6.4 MB of garbage, uncollected.  Interpreted: compiled, the table is
     * sunk and the loop allocates nothing (the first draft of this case
     * passed on the previous object for exactly that reason). */
    runstr(W, "jit.off() for i = 1, 100000 do local x = {} end jit.on()");
    lua_settop(W, 0);
    u0 = j_used(W, &WS);
    w_setcap(W, &WS, u0 + 100 * 1024, 1);
    lua_gc(W, LUA_GCRESTART, 0);
    coll0 = GC_COLLECTS(W); bail0 = GC_BAILOUTS(W);
    st = try_tables(W, 2);
    st2 = try_tables(W, 2);
    sprintf(d, "%ld B held, then an armed cycle: statuses %d/%d, collects %.0f -> %.0f, bailouts %.0f -> %.0f",
            (long)u0, st, st2, coll0, GC_COLLECTS(W), bail0, GC_BAILOUTS(W));
    ok(GC_BAILOUTS(W) == bail0 && GC_COLLECTS(W) > coll0,
       "W5c a sweep that frees 100000 blocks is not a bailout", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W2: a refusal with no arm (P1, second shape) ----------------- */
    /* One request larger than the headroom while the headroom is still over
     * the watermark: refused, and today nothing arms, so the garbage that
     * would have covered it is never collected and the retry is refused too. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W2: no state\n"); return 1; }
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    base = j_used(W, &WS);
    cap = base + 1024 * 1024;
    w_setcap(W, &WS, cap, 1);
    w_tab(W, 76800, 0);                 /* 600 KB of garbage, one block */
    H = cap - j_used(W, &WS);
    G = w_odmax(cap);
    nreq = (int)((H + G / 2 + 64 * 1024) / 8);
    armedC = GC_ARMED(W);
    st = w_tab(W, nreq, 0);
    sprintf(d, "headroom %ld (watermark %ld), armed before %.0f; one request of %ld B: status %d (LUA_ERRMEM=%d), armed after %.0f",
            (long)H, wmark((long)cap), armedC, (long)nreq * 8, st, LUA_ERRMEM, GC_ARMED(W));
    ok(armedC == 0 && st == LUA_ERRMEM && GC_ARMED(W) == 1,
       "W2b a refusal arms, from any headroom", d);
    st = w_tab(W, nreq, 0);
    sprintf(d, "the same request again: status %d, used %ld of cap %ld", st, (long)j_used(W, &WS), (long)cap);
    ok(st == 0, "W2c and the retry succeeds once the garbage is collected", d);
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    w_tab(W, 38400, 0);                 /* 300 KB of garbage */
    H = cap - j_used(W, &WS);
    nreq = (int)((H + w_odmax(cap) / 4) / 8);
    st = w_tab(W, nreq, 1);             /* kept live */
    u0 = j_used(W, &WS);
    w_tab(W, 0, 0);                     /* a checkpoint: the armed cycle */
    w_tab(W, 0, 0);
    u1 = j_used(W, &WS);
    sprintf(d, "a request of headroom + G/4 (%ld B): status %d, used %ld vs cap %ld right after; %ld after the next checkpoint",
            (long)nreq * 8, st, (long)u0, (long)cap, (long)u1);
    ok(st == 0 && u0 > cap && u1 <= cap, "W2d a request inside the credit is lent, then repaid", d);
    lua_pushnil(W); lua_setfield(W, LUA_REGISTRYINDEX, "__wkeep");
    clear_javastate(W);
    lua_close(W);

    /* ---- W9: the residual, measured, not asserted ---------------------- */
    /* What the bounded credit does NOT fix (docs/roadmap.md, the collector
     * at the wall): printed so a change in it is seen, never counted, because
     * only a collection outside the checkpoints (the hook carrier, stage 2)
     * would turn it into a pass. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W9: no state\n"); return 1; }
    runstr(W, "jit.off() __w9 = 0 __w9n = 0");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    base = j_used(W, &WS);
    cap = base + 1024 * 1024;
    w_setcap(W, &WS, cap, 1);
    w_tab(W, 76800, 0);                 /* 600 KB of garbage, one block */
    H = cap - j_used(W, &WS);
    G = w_odmax(cap);
    lua_pushinteger(W, (lua_Integer)(H + G + 64 * 1024));
    lua_setglobal(W, "__w9n");
    st = runstr(W, W9_CHUNK);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    lua_getglobal(W, "__w9");
    printf("  INFO  %-52s request %ld B = headroom %ld + G %ld + 64 KB, garbage 600 KB: status %d, %s %ld\n",
           "W9 residual: allocate-first retries, no checkpoint", (long)(H + G + 64 * 1024), (long)H, (long)G, st,
           lua_tointeger(W, -1) > 0 && lua_tointeger(W, -1) < 20 ? "succeeded at try" : "tries made",
           (long)lua_tointeger(W, -1));
    lua_settop(W, 0);
    clear_javastate(W);
    lua_close(W);

    /* ---- W1: recovery at the wall (P1) -------------------------------- */
    /* The probe's measured failure, hermetically: three rounds, C mode, then
     * the same in legacy mode (the dropin's path). */
    for (round = 0; round < 3; round++) {
      int handover = round != 1;        /* C mode, legacy, C mode with the JIT on */
      int r;
      W = w_newstate(&WS, 64 * 1024 * 1024, handover);
      if (!W) { printf("  FAIL  W1: no state\n"); return 1; }
      if (round != 2) runstr(W, "jit.off()");
      allok = 1;
      d[0] = 0;
      for (r = 0; r < 3; r++) {
        const char *res;
        char one[200];
        lua_createtable(W, 1 << 16, 0);  /* the holder, pre-sized: the fill never grows it */
        lua_setglobal(W, "__h");
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        cap = j_used(W, &WS) + 512 * 1024;
        w_setcap(W, &WS, cap, handover);
        coll0 = GC_COLLECTS(W); bail0 = GC_BAILOUTS(W);
        st = runstr(W, W1_CHUNK);
        if (st != 0) { res = errtop(W); }
        else { lua_getglobal(W, "__w1"); res = lua_tostring(W, -1); if (!res) res = "(nil)"; }
        /* Repaid within one credit's worth of further allocation: the
         * dropped data is collected at the latest when the distance to the
         * tier's top has halved (lj52shim.c, THE CADENCE). */
        u0 = j_used(W, &WS);
        nrep = (int)(w_odmax(cap) / 64) + 64;
        churn(W, 0, 1e18, nrep, &st3);
        u1 = j_used(W, &WS);
        if (GC_COLLECTS(W) - coll0 > cworst) cworst = GC_COLLECTS(W) - coll0;
        sprintf(one, "[%d: status %d, '%.40s', used %ld, %ld after %d tables, cap %ld, collects +%.0f] ", r, st, res,
                (long)u0, (long)u1, nrep, (long)cap, GC_COLLECTS(W) - coll0);
        strcat(d, one);
        if (!(st == 0 && strncmp(res, "not enough memory|256|3", 23) == 0 && st3 == 0 && u1 <= cap
              && GC_BAILOUTS(W) == bail0)) allok = 0;
        lua_settop(W, 0);
        w_setcap(W, &WS, 64 * 1024 * 1024, handover);
      }
      peak = WALL_ODPEAK(W); lim = WALL_ODLIMIT(W);
      {
        char tail[96];
        sprintf(tail, "od_peak %.0f, od_limit %.0f", peak, lim);
        strcat(d, tail);
      }
      ok(allok && peak >= 0 && peak <= lim,
         round == 0 ? "W1 C mode: catch the refusal, drop the data, carry on (x3)"
         : round == 1 ? "W1L legacy mode: catch the refusal, drop the data, carry on (x3)"
                      : "W1j C mode, JIT on: catch, drop, carry on (x3)", d);
      clear_javastate(W);
      lua_close(W);
    }

    /* ---- W12: what a fill costs (P2, THE CADENCE) ---------------------- */
    /* Each W1 round fills 512 KB of headroom with live 64-byte tables to the
     * refusal, recovers, and repays.  Measured per round: 21 full cycles
     * (the pre-emptive cycles halving their way to the cap, then the tiers
     * past it), about 1840 without the hysteresis (one per checkpoint pair),
     * and 1551 before any of this.  12 with the back-off this design once
     * had (lj52shim.c, NO BACK-OFF).  The bound is half again the measured
     * count; a per-checkpoint re-arm is two orders of magnitude past it. */
    sprintf(d, "the worst W1 round: %.0f full cycles (bound 32)", cworst);
    ok(cworst >= 1 && cworst <= 32, "W12 a fill to the wall costs a bounded number of cycles", d);

    /* ---- W13: a hold after an earlier fill still gets a cycle ---------- */
    /* Written while chasing the harness's mem-2 on the first stage-B build
     * (one arm in 7 s, 0 flushes, where the stage-A build armed 13 451 times
     * and flushed 118), on the hypothesis that a back-off engaged by an
     * earlier phase's fill had outlived it.  That hazard is real -- on that
     * build a later program holding live data inside the watermark, below
     * the cap so nothing ever armed at the wall, got not one cycle here --
     * though mem-2's own failure turned out to be W14's pattern.  Fill,
     * drop, collect, then hold inside the watermark. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W13: no state\n"); return 1; }
    runstr(W, "jit.off() __w13t = 0");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    base = j_used(W, &WS);
    cap = base + 1024 * 1024;
    w_setcap(W, &WS, cap, 1);
    lua_pushinteger(W, (lua_Integer)(cap - 60 * 1024));
    lua_setglobal(W, "__w13t");
    st = runstr(W, W13_FILL);              /* phase 1: live data to 60 KB short of the cap */
    peak = WALL_LOW(W);
    runstr(W, "__w13 = nil");
    lua_gc(W, LUA_GCCOLLECT, 0);           /* its data gone, the heap back near the base */
    runstr(W, ARM_DISARM);                 /* the safe point consumes fill 1's flush flag */
    lua_settop(W, 0);
    u0 = j_used(W, &WS);
    armedC = GC_FLUSHWANT(W);
    arms0 = GC_ARMS(W); coll0 = GC_COLLECTS(W);
    lua_pushinteger(W, (lua_Integer)(cap - 100 * 1024));
    lua_setglobal(W, "__w13t");
    st2 = runstr(W, W13_FILL);             /* phase 2: hold inside the watermark, below the cap */
    u1 = j_used(W, &WS);
    sprintf(d, "fill 1: status %d, left the post-cycle level at %.0f; dropped and collected, used %ld, flush_wanted %.0f after the safe point; "
            "fill 2 to %ld of cap %ld (watermark %ld): status %d, arms +%.0f, collects +%.0f, flush_wanted %.0f",
            st, peak, (long)u0, armedC, (long)u1, (long)cap, wmark((long)cap), st2,
            GC_ARMS(W) - arms0, GC_COLLECTS(W) - coll0, GC_FLUSHWANT(W));
    ok(st == 0 && st2 == 0 && armedC == 0 && GC_COLLECTS(W) - coll0 >= 1 && GC_FLUSHWANT(W) == 1,
       "W13 a later hold inside the watermark still gets a cycle (the flush)", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W14: a hold that churns as it grows still gets the flush ------ */
    /* mem-2's failure on both builds that had a back-off (2026-10-04):
     * its first pre-emptive cycle freed the program's own garbage and left
     * the heap OUTSIDE the watermark, so that proof rightly asked for no
     * flush -- and then a back-off (freed less than half the growth since a
     * proof taken before the program began) stopped every later cycle while
     * the program grew to 100 KB short of the cap.  One proof inside the
     * watermark is all the trace flush needs. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W14: no state\n"); return 1; }
    runstr(W, "jit.off() __w14t = 0");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    /* a proof before the program, as mem-2's record had one: a tight cap,
     * churn until one cycle is proven, then the program's cap */
    base = j_used(W, &WS);
    w_setcap(W, &WS, base + 100 * 1024, 1);
    coll0 = GC_COLLECTS(W);
    churn(W, 0, coll0, 20000, &st2);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    runstr(W, ARM_DISARM);                 /* the safe point consumes that proof's flush flag */
    lua_settop(W, 0);
    base = j_used(W, &WS);
    cap = base + 2048 * 1024;
    w_setcap(W, &WS, cap, 1);
    settle_gc(W);
    lua_pushinteger(W, (lua_Integer)(cap - wmark((long)cap) - 50 * 1024));
    lua_setglobal(W, "__w14a");
    lua_pushinteger(W, (lua_Integer)(cap - wmark((long)cap) + 150 * 1024));
    lua_setglobal(W, "__w14b");
    lua_pushinteger(W, (lua_Integer)(cap - 100 * 1024));
    lua_setglobal(W, "__w14t");
    arms0 = GC_ARMS(W); coll0 = GC_COLLECTS(W);
    armedC = GC_FLUSHWANT(W);
    st = runstr(W, W14_FILL);
    u1 = j_used(W, &WS);
    sprintf(d, "flush_wanted %.0f before; live to the watermark's edge, garbage into it, live to %ld of cap %ld "
            "(watermark %ld): status %d, arms +%.0f, collects +%.0f, flush_wanted %.0f",
            armedC, (long)u1, (long)cap, wmark((long)cap), st, GC_ARMS(W) - arms0, GC_COLLECTS(W) - coll0,
            GC_FLUSHWANT(W));
    ok(st == 0 && armedC == 0 && GC_COLLECTS(W) - coll0 >= 1 && GC_FLUSHWANT(W) == 1,
       "W14 a hold that churns as it grows still asks for the flush", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W15: the flush is asked for inside HALF the watermark (stage C) */
    /* A 192 KB machine with a trace-free kernelMemory idles with 106-145 KB
     * free against a 130 KB watermark, so every cycle it proved asked for the
     * flush and it threw away ~25 KB of compiled code 8-20 times in 10 s
     * (bench/results-wall-2026-10-04.md, stage C).  160 KB live: with 100 KB
     * free -- inside the watermark, outside half of it -- a proven cycle must
     * NOT ask; with 40 KB free it must. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W15: no state\n"); return 1; }
    runstr(W, "jit.off()");
    lua_createtable(W, 20480, 0);           /* 160 KB live */
    lua_setfield(W, LUA_REGISTRYINDEX, "__live15");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    runstr(W, ARM_DISARM);                  /* no stale flag */
    lua_settop(W, 0);
    u0 = j_used(W, &WS);
    cap = u0 + 100 * 1024;
    w_setcap(W, &WS, cap, 1);
    coll0 = GC_COLLECTS(W);
    churn(W, 0, coll0, 20000, &st);         /* garbage until one cycle is proven */
    armedC = GC_FLUSHWANT(W);
    lua_gc(W, LUA_GCCOLLECT, 0);            /* unarmed after the proof: no alias */
    settle_gc(W);
    runstr(W, ARM_DISARM);
    lua_settop(W, 0);
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, u1 + 40 * 1024, 1);
    coll1 = GC_COLLECTS(W);
    churn(W, 0, coll1, 20000, &st2);
    sprintf(d, "160 KB live, total %ld (watermark %ld): with 100 KB free a cycle proven (collects +%.0f, status %d) "
            "and flush_wanted %.0f; with 40 KB free, collects +%.0f (status %d), flush_wanted %.0f",
            (long)cap, wmark((long)cap), coll1 - coll0, st, armedC, GC_COLLECTS(W) - coll1, st2, GC_FLUSHWANT(W));
    ok(st == 0 && st2 == 0 && coll1 > coll0 && GC_COLLECTS(W) > coll1 && armedC == 0 && GC_FLUSHWANT(W) == 1,
       "W15 the flush is asked for inside half the watermark, not the whole", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W8: an allocation between the catch and the drop (P1) -------- */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W8: no state\n"); return 1; }
    runstr(W, "jit.off()");
    lua_createtable(W, 1 << 16, 0);
    lua_setglobal(W, "__h");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    cap = j_used(W, &WS) + 512 * 1024;
    w_setcap(W, &WS, cap, 1);
    bail0 = GC_BAILOUTS(W);
    st = runstr(W, W8_CHUNK);
    u0 = j_used(W, &WS);
    nrep = (int)(w_odmax(cap) / 64) + 64;
    churn(W, 0, 1e18, nrep, &st3);      /* repaid within one credit: see W1 */
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    {
      const char *res;
      if (st != 0) res = errtop(W);
      else { lua_getglobal(W, "__w8"); res = lua_tostring(W, -1); if (!res) res = "(nil)"; }
      sprintf(d, "status %d, '%.60s', used %ld, %ld after %d tables (status %d), cap %ld, bailouts %.0f -> %.0f",
              st, res, (long)u0, (long)u1, nrep, st3, (long)cap, bail0, GC_BAILOUTS(W));
      allok = st == 0 && strstr(res, "err: not enough memory|256|3") == res && st3 == 0 && u1 <= cap
              && GC_BAILOUTS(W) == bail0;
    }
    lua_settop(W, 0);
    ok(allok, "W8 an allocation between catch and drop: still recovers", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W3: one allocation at an exhausted cap (P1, trace exits) ------ */
    /* A compiled loop whose table is sunk: the exit at i == n restores it,
     * and the restore allocates.  At a cap with not one byte to spare that
     * restore (or, uncompiled, the TDUP) is lent from the credit. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W3: no state\n"); return 1; }
    runstr(W, "function __w3(n) for i = 1, n do local t = {i, i + 1} if i == n then return t end end end "
              "for k = 1, 20 do __w3(2000) end");
    lua_settop(W, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    lua_getglobal(W, "__w3");
    lua_pushinteger(W, 2000);
    cap = j_used(W, &WS);
    w_setcap(W, &WS, cap, 1);
    st = lua_pcall(W, 1, 1, 0);
    u1 = st == 0 && lua_istable(W, -1) ? (lua_rawgeti(W, -1, 1), (long long)lua_tointeger(W, -1)) : -1;
    lua_settop(W, 0);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    sprintf(d, "cap == used: status %d (LUA_ERRMEM=%d), t[1] = %ld, overdrafts %.0f",
            st, LUA_ERRMEM, (long)u1, WALL_OVERDRAFTS(W));
    ok(st == 0 && u1 == 2000 && WALL_OVERDRAFTS(W) >= 1,
       "W3 a lone allocation at an exhausted cap is lent", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W4: the re-arm cadence in the last quarter (P2) -------------- */
    /* 256 KB live, 64 B garbage churn.  Near: 64 KB of headroom, inside the
     * watermark.  Far: four watermarks of headroom.  Today every proven cycle
     * that leaves the heap inside the watermark re-arms at the next
     * allocation -- a full cycle per checkpoint pair.  Stock pays one full
     * cycle per (cap - live) bytes. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W4: no state\n"); return 1; }
    runstr(W, "jit.off()");
    lua_createtable(W, 32768, 0);
    lua_setfield(W, LUA_REGISTRYINDEX, "__live4");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    base = j_used(W, &WS);
    w_setcap(W, &WS, base + 4 * wmark((long)(base + 4 * 128 * 1024)), 1);
    settle_gc(W);
    coll0 = GC_COLLECTS(W);
    t0 = clock();
    churn(W, 0, 1e18, 20000, &st2);
    t1 = clock();
    cfar = GC_COLLECTS(W) - coll0;
    lua_gc(W, LUA_GCCOLLECT, 0);        /* the far phase leaves its garbage: */
    settle_gc(W);                       /* the near cap counts from the live set */
    base = j_used(W, &WS);
    w_setcap(W, &WS, base + 64 * 1024, 1);
    settle_gc(W);
    coll1 = GC_COLLECTS(W); refu0 = GC_REFUSALS(W);
    t1 = clock();
    churn(W, 0, 1e18, 20000, &st);
    t2 = clock();
    cnear = GC_COLLECTS(W) - coll1;
    tfar = (double)(t1 - t0) > 0 ? (double)(t1 - t0) : 1;
    tnear = (double)(t2 - t1);
    /* The bound is R2's: within 3x stock's cycle count, and stock runs one
     * full cycle per (cap - live) bytes -- here 1.28 MB / 64 KB, about 20. */
    lim = 3.0 * (20000.0 * 64 / (64 * 1024)) + 2;
    sprintf(d, "20000 x 64 B, 256 KB live: far (4 watermarks) %.0f collects, status %d; near (64 KB) %.0f collects "
            "(bound %.0f), status %d, refusals +%.0f; time near/far %.1f",
            cfar, st2, cnear, lim, st, GC_REFUSALS(W) - refu0, tnear / tfar);
    /* The time ratio is PRINTED, not asserted (2026-10-05).  It is two
     * clock() readings of a few milliseconds each at clock()'s 1 ms
     * resolution, so it only takes the values 0.5, 1, 2, 3, 4...; 11 of 75
     * runs read exactly the old bound of 3.0, and two read 4.0 while the
     * efficiency cores were loaded -- one of them inside a negative-control
     * sabotage that W4 has nothing to do with.  The cycle count is the
     * deterministic measure of R2, and the nohyst sabotage still fails it. */
    ok(st == 0 && st2 == 0 && cnear >= 1 && cnear <= lim && cfar <= 2
         && GC_REFUSALS(W) == refu0,
       "W4 near the wall, cycles per bytes allocated, not per checkpoint", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W7: the credit cannot be ratcheted (R5) ---------------------- */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W7: no state\n"); return 1; }
    runstr(W, "jit.off()");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    runstr(W, "__w7 = 0");               /* the result's global exists before the wall */
    lua_settop(W, 0);
    cap = j_used(W, &WS) + 256 * 1024;
    w_setcap(W, &WS, cap, 1);
    refu0 = GC_REFUSALS(W); coll0 = GC_COLLECTS(W);
    st = runstr(W, W7_CHUNK);
    lua_settop(W, 0);
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);   /* nothing below is read at the wall */
    peak = WALL_ODPEAK(W); lim = WALL_ODLIMIT(W);
    {
      double win = WALL_LEND(W), kslice = WALL_KSLICE(W);
      if (win < 0) win = 0;                /* a shim before THE WINDOW */
      lua_getglobal(W, "__w7");
      nrep = (int)lua_tointeger(W, -1);
      lua_pop(W, 1);
      sprintf(d, "4000 caught attempts past the wall, as the sandbox: status %d, caught %d, refusals +%.0f, collects +%.0f; "
              "used %ld vs cap %ld; od_peak %.0f, od_limit %.0f, window %.0f (slice %.0f)",
              st, nrep, GC_REFUSALS(W) - refu0, GC_COLLECTS(W) - coll0, (long)u1, (long)cap, peak, lim, win, kslice);
      /* The sandbox's bound is cap + G + THE WINDOW, and the window must sit
       * inside the kernel's slice, or the bound over every thread moves. */
      /* THE RESERVE'S SIZE (design "lifetime"): the reserve is one window (a
       * FIXED 4096 here, as W19's 11 KB) past the first refusal, sized once,
       * so 4000 caught refusals that keep their data reach at most cap + G/2
       * + 4096 + two windows: the first refusal's window, R, and the reserve
       * top's window.  The shipped shim reads od_peak at G + the window. */
      ok(st == 0 && nrep > 0 && GC_REFUSALS(W) > refu0 && peak >= 0 && lim > 0
           && peak <= lim / 2 + 4096 + 2 * win
           && win <= kslice && u1 <= cap + (long long)(lim + win) + 2048
           && GC_COLLECTS(W) - coll0 <= 2 * (GC_REFUSALS(W) - refu0) + 24,
         "W7 caught refusals cannot push the heap past cap + G/2 + R + two windows", d);
    }
    clear_javastate(W);
    lua_close(W);

    /* ---- W7k: the bound over every thread, as the kernel ---------------- */
    /* W7's attempts made by the kernel (main thread, no resume armed): the
     * kernel has no window -- its slice is past every window -- so its bound
     * stays cap + G + the slice.  Nothing else pinned it past the kernel's
     * first refusal (d2-lend: the kernel-window sabotage passed every case). */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W7k: no state\n"); return 1; }
    runstr(W, "jit.off() __w7k = 0");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    lua_settop(W, 0);
    cap = j_used(W, &WS) + 256 * 1024;
    w_setcap(W, &WS, cap, 1);
    refu0 = GC_REFUSALS(W);
    st = runstr(W, "local h, fails, cur = {}, 0, 0 "
                   "local function add() for k = 1, 64 do h[#h + 1] = {cur, k} end end "
                   "for i = 1, 4000 do cur = i if not pcall(add) then fails = fails + 1 end end "
                   "__w7k = fails");
    lua_settop(W, 0);
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    peak = WALL_ODPEAK(W); lim = WALL_ODLIMIT(W);
    {
      double kslice = WALL_KSLICE(W), win = WALL_LEND(W);
      if (win < 0) win = 0;                /* a shim before THE WINDOW */
      lua_getglobal(W, "__w7k");
      nrep = (int)lua_tointeger(W, -1);
      lua_pop(W, 1);
      sprintf(d, "4000 caught attempts past the wall, as the kernel: status %d, caught %d, refusals +%.0f; "
              "used %ld vs cap %ld; od_peak %.0f, od_limit %.0f, window %.0f, slice %.0f",
              st, nrep, GC_REFUSALS(W) - refu0, (long)u1, (long)cap, peak, lim, win, kslice);
      /* Not vacuous: the kernel went past the sandbox's ceiling (G + the
       * window) into its slice, so this is the kernel's bound being held. */
      ok(st == 0 && nrep > 0 && GC_REFUSALS(W) > refu0 && lim > 0 && kslice > 0
           && peak > lim + win && peak <= lim + kslice && u1 <= cap + (long long)(lim + kslice) + 2048,
         "W7k as the kernel, past the sandbox's ceiling, under cap + G + the slice", d);
    }
    clear_javastate(W);
    lua_close(W);

    /* ---- W17: a live fill is refused past the top, inside half the window */
    /* THE WINDOW (d2-final): a sandbox growth past its tier's top is lent,
     * and the cycle armed for it decides.  A fill of LIVE data survives two
     * consecutive cycles, so the verdict refuses it within a few objects of
     * the top: past it -- stage C refused AT the top with its garbage
     * uncollected (od_peak <= G/2: this case fails first there) -- and well
     * before the window's ceiling (the window is not a third tier).  From
     * d2-verdict's W17 and d2-prevent's W17, with THE WINDOW's bounds. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W17: no state\n"); return 1; }
    runstr(W, "jit.off() __w17 = 0");
    lua_createtable(W, 8192, 0);            /* the holder, pre-sized: 64 KB, never grown */
    lua_setglobal(W, "__w17h");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    lua_settop(W, 0);
    cap = j_used(W, &WS) + 256 * 1024;
    w_setcap(W, &WS, cap, 1);
    refu0 = GC_REFUSALS(W);
    st = runstr(W, W17_CHUNK);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    peak = WALL_ODPEAK(W);
    G = w_odmax(cap);
    {
      double win = WALL_LEND(W);
      if (win < 0) win = 0;                /* a shim before THE WINDOW */
      lua_getglobal(W, "__w17");
      nrep = (int)lua_tointeger(W, -1);
      lua_pop(W, 1);
      sprintf(d, "sandbox fill of live 64 B tables, cap %ld, G %ld: status %d, caught %s, refusals +%.0f; od_peak %.0f "
                 "(the top G/2 = %ld; half the window past it = %.0f)",
              (long)cap, (long)G, st, nrep == 0 ? "yes" : "NO", GC_REFUSALS(W) - refu0, peak,
              (long)(G / 2), (double)(G / 2) + win / 2);
      ok(st == 0 && nrep == 0 && GC_REFUSALS(W) - refu0 == 1
           && peak > (double)(G / 2) && peak <= (double)(G / 2) + win / 2,
         "W17 a live fill is refused past the top, inside half the window", d);
    }
    clear_javastate(W);
    lua_close(W);

    /* ---- W10: the kernel allocates after the sandbox (X9) -------------- */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W10: no state\n"); return 1; }
    runstr(W, "jit.off() __w10 = 0");
    lua_createtable(W, 1 << 16, 0);
    lua_setglobal(W, "__h");
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    lua_settop(W, 0);
    cap = j_used(W, &WS) + 256 * 1024;
    w_setcap(W, &WS, cap, 1);
    st = runstr(W, W10_CHUNK);
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    {
      const char *res;
      if (st != 0) res = errtop(W);
      else { lua_getglobal(W, "__w10"); res = lua_tostring(W, -1); if (!res) res = "(nil)"; }
      sprintf(d, "status %d, '%.40s' (kernel armed|after disarm|sandbox refusals|resume); used %ld vs cap %ld",
              st, res, (long)u1, (long)cap);
      allok = st == 0 && strncmp(res, "true|true|2|true", 16) == 0;
    }
    lua_settop(W, 0);
    ok(allok, "W10 the kernel allocates after the sandbox spent the credit", d);
    clear_javastate(W);
    lua_close(W);

    /* ---- W11: a cap set under the live data (a load, a lowered cap) ---- */
    /* A fresh record -- no refusal and no proven cycle behind it -- as when
     * eris loads a machine that filled into the reserve before it was saved
     * and its cap is restored under the live set.  The live data alone is
     * past total + G/2, so the burst tier is spent before anything is asked
     * of it; a small request is lent from the reserve tier, a 32 KB one past
     * total + G is refused.  Run as the sandbox (a coroutine resumed under
     * the watchdog's arm), so the kernel's slice cannot be what grants it. */
    W = w_newstate(&WS, 64 * 1024 * 1024, 1);
    if (!W) { printf("  FAIL  W11: no state\n"); return 1; }
    runstr(W, "jit.off()");
    lua_createtable(W, 32768, 0);       /* 256 KB live */
    lua_setfield(W, LUA_REGISTRYINDEX, "__live11");
    st = runstr(W, W11_CHUNK);
    lua_getglobal(W, "__co11");
    Wco = lua_tothread(W, -1);
    lua_settop(W, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    lua_gc(W, LUA_GCCOLLECT, 0);
    settle_gc(W);
    u0 = j_used(W, &WS);
    cap = u0 - 24 * 1024;               /* G is the 32 KB floor at this cap: over by 3/4 G */
    w_setcap(W, &WS, cap, 1);
    st2 = Wco ? lua_resume(Wco, W, 0) : -1;
    nreq = Wco && st2 == LUA_YIELD ? lua_toboolean(Wco, 1) * 2 + lua_toboolean(Wco, 2) : -1;
    u1 = j_used(W, &WS);
    w_setcap(W, &WS, 64 * 1024 * 1024, 1);
    runstr(W, "_OCLJ_WATCHDOG.disarm(__t11)");
    sprintf(d, "setup %d; cap %ld under used %ld by 24 KB, G %ld: resume %d (LUA_YIELD=%d), 64 B %s, 32 KB %s; used %ld",
            st, (long)cap, (long)u0, (long)w_odmax(cap), st2, LUA_YIELD,
            nreq < 0 ? "n/a" : nreq >= 2 ? "lent" : "REFUSED", nreq < 0 ? "n/a" : (nreq & 1) == 0 ? "refused" : "LENT", (long)u1);
    ok(st == 0 && st2 == LUA_YIELD && nreq == 2,
       "W11 live data past total + G/2: the reserve tier, not a refusal", d);
    lua_settop(W, 0);
    clear_javastate(W);
    lua_close(W);

    /* ---- W11w: a fresh record's window opens no reserve tier ------------- */
    /* (The code review of THE WINDOW, 2026-10-05.)  W11's rule takes a fresh
     * record -- no cycle proven, as after a load -- whose heap is already past
     * total + G/2 into the RESERVE tier.  THE WINDOW lets the sandbox itself
     * take a fresh record past that line, by its lend; the rule must not then
     * read those bytes as history and open the second tier with no refusal.
     * The sandbox, at S - 1 KB on a fresh record, makes one table whose array
     * part is lent and whose hash part would pass the window's ceiling: it
     * must be REFUSED (refusals +1, the excursion within the window), in C
     * mode and on the legacy path.  Before the fix it was granted at G/2 +
     * 13 KB with no refusal at all. */
    {
      int hm;
      for (hm = 1; hm >= 0; hm--) {
        lua_State *Wco;
        long long u0, T, G11, i11;
        double refu0, refu1, peak, lend;
        int st2, okr = -1;
        W = w_newstate(&WS, 64 * 1024 * 1024, hm);
        if (!W) { printf("  FAIL  W11w: no state\n"); return 1; }
        runstr(W, "jit.off()");
        lua_pushcfunction(W, w11w_mk);
        lua_setglobal(W, "__w11wmk");
        if (runstr(W, W11W_CHUNK) != 0) { printf("  FAIL  W11w: the chunk: %s\n", errtop(W)); return 1; }
        lua_getglobal(W, "__co");
        Wco = lua_tothread(W, -1);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        refu0 = GC_REFUSALS(W);
        lend = WALL_LEND(W);
        if (lend < 0) lend = 0;              /* a shim before THE WINDOW */
        lua_pushinteger(Wco, 256);
        lua_pushinteger(Wco, 512);
        u0 = j_used(W, &WS);
        T = u0;                              /* T + G(T)/2 - 1 KB == u0 */
        for (i11 = 0; i11 < 8; i11++) T = u0 + 1024 - w_odmax(T) / 2;
        G11 = w_odmax(T);
        w_setcap(W, &WS, T, hm);
        st2 = lua_resume(Wco, W, 2);
        if (st2 == LUA_YIELD) okr = lua_toboolean(Wco, -1);
        w_setcap(W, &WS, 64 * 1024 * 1024, hm);
        peak = WALL_ODPEAK(W);
        refu1 = GC_REFUSALS(W);
        sprintf(d, "%s, fresh record at S - 1 KB, cap %lld, G %lld: createtable(256,512) %s, refusals +%.0f, "
                   "od_peak G/2 + %.0f (the window: %.0f)",
                hm ? "C mode" : "legacy", T, G11, okr < 0 ? "did not yield" : okr ? "GRANTED" : "refused",
                refu1 - refu0, peak - (double)(G11 / 2), lend);
        ok(okr == 0 && refu1 - refu0 >= 1 && peak <= (double)(G11 / 2) + lend,
           hm ? "W11w a fresh record's window opens no reserve tier without a refusal"
              : "W11wL the same on the legacy path", d);
        clear_javastate(W);
        lua_close(W);
      }
    }

    /* ---- W16: a refusal at the credit's top lands outside the handler -- */
    w16dmax = 256;
    /* The residual row (docs/roadmap.md, found 2026-10-04): stage B saw 3
     * stalls and a dropin down in 68 capacity runs, stage C one stall in 49,
     * stock none.  Hermetically (wall2/repro, 2026-10-04): with the live data
     * inside the burst tier, the last cycle the cadence arms runs at a
     * checkpoint inside the batch, while the batch's own churn is still in
     * its frame; the batch returns, that churn is garbage, and the next
     * request -- the stage string or event.timer's record (allocate-first:
     * lj_meta_cat, lj_tab_dup's hash part), or the dispatcher's pack on the
     * next resume after the kernel spent its slice -- does not fit under
     * cap + G/2 and is refused before any checkpoint can collect it.  Stock
     * collects at the refusal (lmem.c:85-93) and the request fits.
     *
     * The sweep moves the cap through one step's worth of the fill (100
     * strings of ~60 B: one period of where the top falls in the program).
     * For every run whose refusal landed OUTSIDE the batch's handler (the
     * stall, or the sandbox killed) it collects twice and asks whether the
     * live set, plus the request that was refused (WALLSTATS[13]; on a shim
     * that does not report it, the LARGEST object the program allocates
     * outside a handler, measured, not hardcoded), fits under the sandbox's
     * burst top.  If it does, a collection at the refusal would have made
     * room and the program would have gone on: that is the failure.  The
     * live set is read with the sandbox still suspended where it landed (a
     * stall yields; a killed sandbox is dead), so it counts the sandbox's
     * stack as the program would hold it.  A refusal outside the handler
     * that garbage could NOT have covered is stock's behaviour too and is
     * not counted. */
    {
    int hm16;
    for (hm16 = 1; hm16 >= 0; hm16--) {
      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;
      long long dmax = 0, L16, top16, off;
      char first[200];
      first[0] = 0;
      for (k = 0; k < W16_N; k++) {
        off = (long long)k * W16_STEP;
        W = w_newstate(&WS, 64 * 1024 * 1024, hm16);
        if (!W) { printf("  FAIL  W16: no state\n"); return 1; }
        runstr(W, "jit.off() __w16k = false __w16dmax = 0");
        lua_pushcfunction(W, w16_rec);
        lua_setglobal(W, "__w16rec");
        if (runstr(W, W16_CHUNK) != 0) { printf("  FAIL  W16: the chunk: %s\n", errtop(W)); return 1; }
        lua_getglobal(W, "__w16dmax");
        dmax = (long long)lua_tonumber(W, -1);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        lua_getglobal(W, "__w16k");             /* on the stack while there is room */
        base = j_used(W, &WS);
        cap = base + 384 * 1024 + off;
        W16_CODE = 0; W16_USED = -1; W16_DELTA = -1;
        w_setcap(W, &WS, cap, hm16);
        st = lua_pcall(W, 0, 0, 0);
        w_setcap(W, &WS, 64 * 1024 * 1024, hm16);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        L16 = j_used(W, &WS);                   /* the live set the refusal left */
        top16 = cap + w_odmax(cap) / 2;         /* the sandbox's burst tier: no slice */
        if (st != 0 || W16_CODE == 0) nother++;
        else if (W16_CODE == 1) nin++;
        else {
          if (W16_CODE == 2) nstall++; else ndown++;
          if (L16 + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= top16) {
            if (ncov == 0)
              sprintf(first, "; first at cap = base + 384 KB + %lld: %s, request %.0f, used %lld, live %lld, top %lld",
                      off, W16_CODE == 2 ? "stall" : "sandbox down", W16_DELTA, W16_USED, L16, top16);
            ncov++;
          }
        }
        clear_javastate(W);
        lua_close(W);
      }
      sprintf(d, "%s, %d caps, base + 384 KB + 0..%d B: inside %d, stall %d, sandbox down %d, other %d; "
                 "outside with room after a collection for the refused request (or %lld B): %d%.180s",
              hm16 ? "C mode" : "legacy", W16_N, (W16_N - 1) * W16_STEP, nin, nstall, ndown, nother, dmax, ncov, first);
      /* other: the kernel's own pcall failed or nothing was recorded -- a
       * machine down by the kernel's refusal, which no handler would catch */
      ok(nin > 0 && ncov == 0 && nother == 0,
         hm16 ? "W16 no refusal outside the handler that garbage covers"
              : "W16L the same on the legacy (dropin) path", d);
      if (hm16) w16dmax = dmax;
    }
    }

    /* ---- W16R / W16Rj: the same, carried into the reserve tier -------- */
    /* The in-machine stalls and the dropin's down all came at the RESERVE
     * top (u2-stalls.md).  W16's program, but its handler absorbs the first
     * refusal and the fill goes on, data kept; the second refusal must land
     * inside the handler unless garbage could not have covered it.  Stage C,
     * hermetically (d2-lend, 4096 caps): 169 outside with the JIT off, 1847
     * with it on (all but 43 covered).  A landing is judged against the tier
     * it happened in: cap + G/2 before the first refusal, cap + G after. */
    for (round = 0; round < 4; round++) {
      int k, nin = 0, nstall = 0, ndown = 0, nother = 0, ncov = 0;
      int hmr = round < 2;                     /* rounds 2, 3: the legacy path */
      long long dmax = w16dmax, Lr, topr, off;
      char first[200];
      first[0] = 0;
      for (k = 0; k < W16R_N; k++) {
        off = (long long)k * W16R_STEP;
        W = w_newstate(&WS, 64 * 1024 * 1024, hmr);
        if (!W) { printf("  FAIL  W16R: no state\n"); return 1; }
        runstr(W, (round & 1) == 0 ? "jit.off() __w16k = false" : "jit.on() __w16k = false");
        lua_pushcfunction(W, w16r_rec);
        lua_setglobal(W, "__w16rec");
        if (runstr(W, W16R_CHUNK) != 0) { printf("  FAIL  W16R: the chunk: %s\n", errtop(W)); return 1; }
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        lua_getglobal(W, "__w16k");
        base = j_used(W, &WS);
        cap = base + 384 * 1024 + off;
        W16_CODE = 0; W16_USED = -1; W16_DELTA = -1; W16R_TIER = 0;
        W16R_REF0 = GC_REFUSALS(W);
        w_setcap(W, &WS, cap, hmr);
        st = lua_pcall(W, 0, 0, 0);
        w_setcap(W, &WS, 64 * 1024 * 1024, hmr);
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        Lr = j_used(W, &WS);
        topr = cap + (W16R_TIER ? w_odmax(cap) : w_odmax(cap) / 2);
        if (st != 0 || W16_CODE == 0) nother++;
        else if (W16_CODE == 1) nin++;
        else {
          if (W16_CODE == 2) nstall++; else ndown++;
          if (Lr + (W16_DELTA > 0 ? (long long)W16_DELTA : dmax) <= topr) {
            if (ncov == 0)
              sprintf(first, "; first at cap = base + 384 KB + %lld: %s in the %s tier, request %.0f, used %lld, live %lld, top %lld",
                      off, W16_CODE == 2 ? "stall" : "sandbox down", W16R_TIER ? "reserve" : "burst", W16_DELTA, W16_USED, Lr, topr);
            ncov++;
          }
        }
        clear_javastate(W);
        lua_close(W);
      }
      sprintf(d, "%s, %d caps, base + 384 KB + 0..%d B: second refusal inside %d, stall %d, sandbox down %d, other %d; "
                 "outside with room after a collection for the refused request (or %lld B): %d%.180s",
              hmr ? "C mode" : "legacy", W16R_N, (W16R_N - 1) * W16R_STEP, nin, nstall, ndown, nother, dmax, ncov, first);
      ok(nin > 0 && ncov == 0 && nother == 0,
         round == 0 ? "W16R the reserve tier: no refusal outside the handler that garbage covers"
         : round == 1 ? "W16Rj the same with the JIT on"
         : round == 2 ? "W16RL the reserve tier on the legacy (dropin) path"
         :              "W16RjL the same with the JIT on", d);
    }

    /* ---- W18: the kernel's packs after a sandbox crossing ---------------- */
    /* (j2-safety's K1.)  machine.lua packs every resume's results with no
     * handler: a kernel refusal there is a machine down.  The sandbox fills
     * live data to 1 KB under its burst top and crosses it with one
     * allocation no checkpoint precedes, kept live: an array doubling (+32
     * KB) or a 20 KB concatenation.  At caps of 4 and 10 MB -- G 256 to 512
     * KB, where a window sized by G instead of a constant would pass the
     * kernel's slice (d2-verdict's first FATAL) -- in C mode and legacy.  The
     * kernel is never refused: whatever the sandbox was lent stays under its
     * ceiling, LJ52_GC_KSLICE - LJ52_GC_LEND below the kernel's top. */
    {
      static const long long xkb[4] = { 4096, 4096, 10240, 10240 };
      static const int xmode[4] = { 1, 2, 1, 2 }, xho[4] = { 1, 0, 0, 1 };
      int k, bad = 0;
      char one[160];
      d[0] = 0;
      for (k = 0; k < 4; k++) {
        double r[8];
        long long Nf, S18;
        int i;
        W = w_newstate(&WS, 64 * 1024 * 1024, xho[k]);
        if (!W) { printf("  FAIL  W18: no state\n"); return 1; }
        runstr(W, "jit.off()");
        Nf = 1;
        while (Nf < (xkb[k] * 1024 + 600 * 1024) / 64 + 4096) Nf <<= 1;
        lua_createtable(W, (int)Nf, 0);   /* the fill's holder: never grown */
        lua_setglobal(W, "__f");
        runstr(W, xmode[k] == 1 ? "__k1cat = 10000 __k1mode = 1 __k1target = 0"
                                : "__k1cat = 10000 __k1mode = 2 __k1target = 0");
        if (runstr(W, W18_CHUNK) != 0) { printf("  FAIL  W18: the chunk: %s\n", errtop(W)); return 1; }
        lua_settop(W, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        lua_gc(W, LUA_GCCOLLECT, 0);
        settle_gc(W);
        lua_getglobal(W, "__k1run");
        base = j_used(W, &WS);
        cap = base + xkb[k] * 1024;
        S18 = cap + w_odmax(cap) / 2;
        lua_pushnumber(W, (lua_Number)(S18 - 1024));
        lua_setglobal(W, "__k1target");   /* an existing key: nothing allocated */
        w_setcap(W, &WS, cap, xho[k]);
        st = lua_pcall(W, 0, 0, 0);
        w_setcap(W, &WS, 64 * 1024 * 1024, xho[k]);
        peak = WALL_ODPEAK(W);
        lua_settop(W, 0);
        lua_getglobal(W, "__k1r");
        for (i = 1; i <= 7; i++) { lua_rawgeti(W, -1, i); r[i] = lua_tonumber(W, -1); lua_pop(W, 1); }
        lua_pop(W, 1);
        if (st != 0 || r[7] != 0 || r[1] != 0 || r[2] != 0) bad++;
        sprintf(one, "%s%lld MB %s %s: st %d, kernel refused %.0f/%.0f/%.0f, fill refused %.0f, crossing %s, peak-G/2 %.0f",
                k ? "; " : "", xkb[k] / 1024, xmode[k] == 1 ? "doubling" : "concat", xho[k] ? "C" : "legacy",
                st, r[7], r[1], r[2], r[3], r[4] ? "lent" : "refused", peak - (double)(w_odmax(cap) / 2));
        strncat(d, one, sizeof d - strlen(d) - 1);
        clear_javastate(W);
        lua_close(W);
      }
      ok(bad == 0, "W18 the kernel's packs after a sandbox crossing, 4 and 10 MB", d);
    }

    /* ---- W19: the kernel's room after the sandbox spent its window ------ */
    /* (j2-safety's K8.)  8 000 caught attempts to add one live table leave
     * the sandbox at its reserve tier's ceiling, top plus THE WINDOW (the
     * case asserts it got within 1 KB of it before the kernel allocates);
     * then the kernel, still armed and then at depth 0, makes ONE table of
     * 11 KB of array -- a FIXED size, not one derived from the window, so a
     * wider window that ate into the kernel's room fails here (lj52shim.c
     * also refuses to compile with less than 12 KB of slice past the
     * window).  Stage C, with no window, keeps the whole 16 KB. */
    {
      double r[7], kslice, win, tier19;
      int i, n19;
      W = w_newstate(&WS, 64 * 1024 * 1024, 1);
      if (!W) { printf("  FAIL  W19: no state\n"); return 1; }
      runstr(W, "jit.off()");
      kslice = WALL_KSLICE(W);
      win = WALL_LEND(W);
      if (win < 0) win = 0;                /* a shim before THE WINDOW */
      n19 = 11 * 1024 / 8;
      lua_createtable(W, 8192, 0);
      lua_setglobal(W, "__h");
      lua_pushcfunction(W, w19_mk);
      lua_setglobal(W, "__k8mk");
      lua_pushnumber(W, (lua_Number)n19);
      lua_setglobal(W, "__k8n");
      if (runstr(W, W19_CHUNK) != 0) { printf("  FAIL  W19: the chunk: %s\n", errtop(W)); return 1; }
      lua_settop(W, 0);
      lua_gc(W, LUA_GCCOLLECT, 0);
      lua_gc(W, LUA_GCCOLLECT, 0);
      settle_gc(W);
      lua_getglobal(W, "__k8run");
      base = j_used(W, &WS);
      cap = base + 256 * 1024;
      G = w_odmax(cap);
      w_setcap(W, &WS, cap, 1);
      st = lua_pcall(W, 0, 0, 0);
      w_setcap(W, &WS, 64 * 1024 * 1024, 1);
      lua_settop(W, 0);
      lua_getglobal(W, "__k8r");
      for (i = 1; i <= 6; i++) { lua_rawgeti(W, -1, i); r[i] = lua_tonumber(W, -1); lua_pop(W, 1); }
      tier19 = r[6] > 0 ? r[6] : (double)G;   /* THE RESERVE'S SIZE: the tier as it stands; G on a shim without it */
      lua_pop(W, 1);
      sprintf(d, "slice %.0f, window %.0f, G %ld, tier %.0f: sandbox resumed %.0f, refused %.0f times, reached tier + %.0f; "
                 "the kernel's one %d-slot table: armed %s, at depth 0 %s",
              kslice, win, (long)G, tier19, r[1], r[4], r[5] - tier19, n19,
              r[2] == 1 ? "granted" : "REFUSED", r[3] == 1 ? "granted" : "REFUSED");
      ok(st == 0 && r[1] == 1 && r[4] >= 2 && kslice > 0 && r[5] >= tier19 + win - 1024
           && r[2] == 1 && r[3] == 1,
         "W19 the kernel keeps 11 KB past the sandbox's ceiling", d);
      clear_javastate(W);
      lua_close(W);
    }
  }


  /* ---- W20 / W20L: THE RESERVE'S SIZE (design "lifetime") -------------- */
  /* A refusal the program never saw used to open G/2 more past the cap for
   * it (16 KB at the floor, 256 KB at 8 MB).  Now the reserve is
   * LJ52_GC_RSV past the heap the refusal found, so a fill that goes on
   * after an absorbed refusal is refused again within that plus the window.
   * Fail-first: the shipped shim reads used_2 about G past the cap. */
  {
    int round, k, nsc = 0, nin = 0, nout = 0, nother = 0, nbad = 0, nbought = 0;
    long long creepmax = 0, creepsum = 0, objsum = 0, cap20, base20, S20;
    lua_State *X;
    FakeState XS;
    char dd[600], first20[200];
    for (round = 0; round < 2; round++) {
      int hm20 = round == 0;
      nsc = nin = nout = nother = nbad = nbought = 0; creepmax = creepsum = objsum = 0; first20[0] = 0;
      for (k = 0; k < W20_N_CAPS; k++) {
        long long off = (long long)k * 512;
        X = w_newstate(&XS, 64 * 1024 * 1024, hm20);
        if (!X) { printf("  FAIL  W20: no state\n"); return 1; }
        runstr(X, "jit.off() __w20k = false");
        lua_pushcfunction(X, w20_rec);
        lua_setglobal(X, "__w20rec");
        if (runstr(X, W20_CHUNK) != 0) { printf("  FAIL  W20: the chunk: %s\n", errtop(X)); return 1; }
        lua_settop(X, 0);
        lua_gc(X, LUA_GCCOLLECT, 0);
        lua_gc(X, LUA_GCCOLLECT, 0);
        settle_gc(X);
        lua_getglobal(X, "__w20k");
        base20 = j_used(X, &XS);
        cap20 = base20 + 384 * 1024 + off;
        S20 = cap20 + w_odmax(cap20) / 2;
        memset(W20_N, 0, sizeof W20_N); memset(W20_U, 0, sizeof W20_U); memset(W20_C, 0, sizeof W20_C);
        W20_S = &XS;
        w_setcap(X, &XS, cap20, hm20);
        st = lua_pcall(X, 0, 0, 0);
        w_setcap(X, &XS, 64 * 1024 * 1024, hm20);
        lua_settop(X, 0);
        if (st != 0 || W20_N[10] == 0) nother++;
        else {
          int c2 = W20_N[1] ? 1 : W20_N[2] ? 2 : W20_N[3] ? 3 : 0;
          long long u1 = W20_U[10], u2 = c2 ? W20_U[c2] : -1, lim;
          nsc++;
          if (c2 == 1) nin++; else if (c2) nout++; else nother++;
          if (c2) {
            long long creep = u2 - u1;
            lim = (u1 > S20 ? u1 : S20) + W20_RSV + 4096;
            creepsum += creep; objsum += W20_C[c2] - W20_C[10];
            if (creep > creepmax) creepmax = creep;
            if (creep > 1024) nbought++;
            if (u2 > lim) {
              nbad++;
              if (first20[0] == 0)
                sprintf(first20, "; first over: cap %lld, used %lld at the first refusal, %lld at the second (%+lld, %lld objects), the bound %lld",
                        cap20, u1, u2, creep, W20_C[c2] - W20_C[10], lim);
            }
          }
        }
        clear_javastate(X);
        lua_close(X);
      }
      sprintf(dd, "%s, %d caps: second chance in %d, its end inside %d / outside %d / other %d; what it bought: "
                  "mean %+lld B (%lld objects), max %+lld B; past the bound (max(used_1, cap + G/2) + %d + the window): %d%.190s",
              hm20 ? "C mode" : "legacy", W20_N_CAPS, nsc, nin, nout, nother,
              nsc ? creepsum / (nsc ? nsc : 1) : 0, nsc ? objsum / nsc : 0, creepmax, W20_RSV, nbad, first20);
      ok(nsc == W20_N_CAPS && nother == 0 && nbad == 0 && nbought >= W20_N_CAPS / 2,
         hm20 ? "W20 a refusal the program never saw opens one window of reserve, not G/2"
              : "W20L the same on the legacy (dropin) path", dd);
    }
  }

  /* ---- W21: THE RESERVE'S SIZE is enough for a recovery that holds ----- */
  /* The reserve exists so that "catch, format, drop" works although the
   * cycles between the catch and the drop find the data still held.  A
   * program that formats a 32-line report (2 KB kept, 8 KB granted) while
   * holding, then drops, must carry on.  Fail-first: with no room past the
   * refusal (LJ52_GC_RSV 0) the handler is refused inside its own report;
   * with 1 KB too. */
  {
    lua_State *X;
    FakeState XS;
    long long cap21;
    int r21;
    char dd[400];
    X = w_newstate(&XS, 64 * 1024 * 1024, 1);
    if (!X) { printf("  FAIL  W21: no state\n"); return 1; }
    runstr(X, "jit.off() __w21 = 0");
    lua_createtable(X, 8192, 0);
    lua_setglobal(X, "__w21h");
    lua_gc(X, LUA_GCCOLLECT, 0);
    lua_gc(X, LUA_GCCOLLECT, 0);
    settle_gc(X);
    lua_settop(X, 0);
    cap21 = j_used(X, &XS) + 256 * 1024;
    w_setcap(X, &XS, cap21, 1);
    st = runstr(X, W21_CHUNK);
    w_setcap(X, &XS, 64 * 1024 * 1024, 1);
    lua_getglobal(X, "__w21");
    r21 = (int)lua_tointeger(X, -1);
    lua_pop(X, 1);
    sprintf(dd, "cap %lld, G %lld: status %d, result %d (32 lines, 256 B, 3 slots = 32025603)", cap21, w_odmax(cap21), st, r21);
    ok(st == 0 && r21 == 32025603, "W21 a recovery that holds across the cycles its report costs", dd);
    clear_javastate(X);
    lua_close(X);
  }

  /* M9 -- the M state never handed over, and nothing in the shim does it
   * behind Java's back: its allocations took the JNI path to the end. */
  sprintf(d, "csync=%.0f; allocator calls %.0f, of them through JNI %.0f",
          GC_CSYNC(L), GC_ACALLS(L), GC_AJNI(L));
  ok(GC_CSYNC(L) == 0 && GC_AJNI(L) > 0 && GC_ACALLS(L) > GC_AJNI(L),
     "M9 a state that never hands over stays in legacy mode", d);

  snprintf(d, sizeof d, "_OCLJ_GCSTATS heap=%g after every case above", GC_HEAP(L));
  ok(GC_HEAP(L) == 1, "M0c the first state is still on its arena at the end", d);

  printf("\nchecks=%d failures=%d\n", checks, failures);
  lua_close(L);                           /* -> lj52_close, frees the record */
  return failures ? 1 : 0;
}
