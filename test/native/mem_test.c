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

int main(void) {
  lua_State *L;
  jint used0, used1, used2, usedBeforePush, usedAfterPush;
  long long gc0, gc1, gc2;
  int st, pushedMemo, rawStatus;
  char d[192];

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

  printf("\nchecks=%d failures=%d\n", checks, failures);
  lua_close(L);                           /* -> lj52_close, frees the record */
  return failures ? 1 : 0;
}
