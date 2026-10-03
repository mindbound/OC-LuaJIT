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
 * Build: see run-mem.sh next to this file.  Exit status 0 iff every case passes.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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
    if (GC_COLLECTS(L) > a->until) { a->steps = i; return 0; }
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

int main(void) {
  lua_State *L;
  jint used0, used1, used2, usedBeforePush, usedAfterPush;
  long long gc0, gc1, gc2;
  int st, pushedMemo, rawStatus;
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
  st = alloc_tables(L, 10000000L);
  sprintf(d, "pcall status=%d (LUA_ERRMEM=%d)  used=%ld cap=%ld",
          st, LUA_ERRMEM, (long)FS.used, (long)FS.total);
  ok(st == LUA_ERRMEM && FS.used <= FS.total, "M5 the cap refuses", d);
  lua_settop(L, 0);

  /* ---- M6 / M7: the coupling ---------------------------------------
   * Stage the raw-push wrapper and the stack slack WHILE there is still
   * room, so that what the cap refuses below is the pushcclosure under
   * test and not the machinery around it. */
  lua_pushcfunction(L, raw_push);         /* memo now warm for raw_push */
  lua_checkstack(L, 20);

  FS.total = FS.used;                     /* not one byte to spare */

  rawStatus = lua_pcall(L, 0, 1, 0);      /* runs raw_push -> lua_pushcclosure */
  lua_settop(L, 0);

  usedBeforePush = FS.used;
  lua_pushcfunction(L, a_cfunc);          /* -> lj52_pushcfunction, cold */
  pushedMemo = lua_isfunction(L, -1);
  usedAfterPush = FS.used;
  lua_settop(L, 0);

  sprintf(d, "used == total == %ld; pushed=%s", (long)usedBeforePush,
          pushedMemo ? "yes" : "NO");
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
    /* 256 KB of headroom, then a 160 KB LIVE table parked in the registry:
     * headroom 96 KB is under the 128 KB floor, and no cycle can free it. */
    PS.total = base2 + 256 * 1024;
    lua_createtable(P, 20480, 0);
    lua_setfield(P, LUA_REGISTRYINDEX, "__live");
    armedB = GC_ARMED(P);
    sprintf(d, "used=%ld of %ld (headroom %ld), armed=%.0f", (long)PS.used,
            (long)PS.total, (long)(PS.total - PS.used), armedB);
    ok(armedB == 1, "P2a the live allocation armed the emergency cycle", d);
    steps = churn(P, 0, coll0, 10000, &st);
    collB = GC_COLLECTS(P); wantB = GC_FLUSHWANT(P); liveB = JIT_LIVE(P);
    sprintf(d, "%.0f steps (status %d): collects %.0f -> %.0f, headroom now %ld "
            "(watermark %ld), flush_wanted=%.0f, traces_live=%.0f",
            steps, st, coll0, collB, (long)(PS.total - PS.used), wmark(PS.total),
            wantB, liveB);
    ok(st == 0 && collB > coll0 && (long)(PS.total - PS.used) < wmark(PS.total),
       "P2b the cycle completed and headroom is STILL under the watermark", d);
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
    st = alloc_tables(C, 10000000L);
    lua_settop(C, 0);
    u1 = j_used(C, &CS);
    sprintf(d, "cap lowered to used+192 KB = %ld: status %d (LUA_ERRMEM=%d), used %ld, native cap %.0f",
            (long)cap, st, LUA_ERRMEM, (long)u1, GC_CTOTAL(C));
    ok(st == LUA_ERRMEM && u1 <= cap, "C3a a lowered cap refuses on the next allocations", d);
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
    lua_createtable(C, 20480, 0);       /* 160 KB LIVE: headroom under the floor */
    lua_setfield(C, LUA_REGISTRYINDEX, "__live");
    armedC = GC_ARMED(C);
    steps = churn(C, 0, coll0, 10000, &st);
    wantC = GC_FLUSHWANT(C);
    sprintf(d, "before: armed %.0f, flush_wanted %.0f; 160 KB live under used+256 KB: armed=%.0f, %.0f steps (status %d), "
            "collects %.0f -> %.0f, headroom %ld (watermark %ld), flush_wanted=%.0f",
            armed0, want0, armedC, steps, st, coll0, GC_COLLECTS(C),
            (long)((long long)CS.total - j_used(C, &CS)), wmark(CS.total), wantC);
    ok(armed0 == 0 && want0 == 0 && armedC == 1 && st == 0 && GC_COLLECTS(C) > coll0 && wantC == 1,
       "C5b live data under the watermark: armed, proven, flush wanted", d);
    lua_pushnil(C);
    lua_setfield(C, LUA_REGISTRYINDEX, "__live");
    st = runstr(C, ARM_DISARM);
    lua_settop(C, 0);

    /* ---- C6: the coupling, at an exhausted native cap ----------------- */
    lua_gc(C, LUA_GCCOLLECT, 0);
    lua_gc(C, LUA_GCCOLLECT, 0);
    j_settotal(C, &CS, 64 * 1024 * 1024);
    lua_settop(C, 0);
    lua_pushcfunction(C, raw_push);     /* memo warm for raw_push on this state */
    lua_checkstack(C, 20);
    u0 = j_used(C, &CS);
    j_settotal(C, &CS, (jint)u0);       /* not one byte to spare */
    rawStatus = lua_pcall(C, 0, 1, 0);  /* raw_push -> lua_pushcclosure */
    lua_settop(C, 0);
    u1 = j_used(C, &CS);
    lua_pushcfunction(C, c_cfunc);      /* -> lj52_pushcfunction, cold */
    pushed = lua_isfunction(C, -1);
    u2 = j_used(C, &CS);
    lua_settop(C, 0);
    sprintf(d, "native cap == used == %ld: raw push status %d (LUA_ERRMEM=%d); memo push %s, used %ld -> %ld",
            (long)u0, rawStatus, LUA_ERRMEM, pushed ? "succeeded" : "REFUSED", (long)u1, (long)u2);
    ok(rawStatus == LUA_ERRMEM && pushed && u2 > u1,
       "C6 exhausted cap: raw push refused, memo push succeeds, charged", d);

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
