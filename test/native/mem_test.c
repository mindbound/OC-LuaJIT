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

static JNIEnv *getthreadenv(void) { return &FAKE_ENV; }

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

/* Two distinct C functions to push.  Only their identity matters. */
static int a_cfunc(lua_State *L) { lua_pushinteger(L, 7); return 1; }
static int b_cfunc(lua_State *L) { lua_pushinteger(L, 8); return 1; }

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

  printf("\nchecks=%d failures=%d\n", checks, failures);
  lua_close(L);                           /* -> lj52_close, frees the record */
  return failures ? 1 : 0;
}
