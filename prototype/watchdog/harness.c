/*
 * harness.c -- Standalone watchdog prototype for a LuaJIT-based CPU
 *              architecture (OpenComputers GTNH fork).
 *
 * PURPOSE
 * -------
 * Validate, with NO JNI and NO Minecraft, the async one-shot count-hook
 * watchdog design that must interrupt runaway sandbox code *while the JIT
 * is on and traces are running*. This is the mechanism OC's stock
 * machine.lua watchdog cannot use (a standing count hook aborts trace
 * recording and forces slow interpreter dispatch), and the mechanism
 * CCLuaJIT shipped but never exercised against compiled traces (it ran
 * with the jit library never opened).
 *
 * DESIGN UNDER TEST
 * -----------------
 *   1. Open base/math/string/table/bit AND jit, then delete the 'jit' and
 *      'debug' globals from the sandbox _G. The JIT *engine* stays ON
 *      (JIT_F_ON lives in jit_State, set by jit_init() during luaopen_jit;
 *      removing the global table does not touch it -- verified in
 *      lib_jit.c:737 jit_init and lib_jit.c:101 jit_status).
 *   2. Run the target script on a coroutine (lua_newthread + lua_resume)
 *      on a dedicated WORKER OS thread.
 *   3. The main thread is the WATCHDOG. After SOFT_MS of wall-clock it
 *      asynchronously injects:
 *          lua_sethook(co, watchdog_hook,
 *                      LUA_MASKCOUNT|LUA_MASKCALL|LUA_MASKRET|LUA_MASKLINE, 1)
 *      lua_sethook is explicitly documented async-safe:
 *      "This function can be called asynchronously (e.g. during a signal)."
 *      (lj_dispatch.c:336). It writes only global_State fields, aborts any
 *      in-progress trace, and rewrites the dispatch table -- it never
 *      touches the running thread's Lua stack.
 *   4. watchdog_hook raises a CATCHABLE error *object* (a table tagged
 *      {watchdog=true}). count==1 means the hook re-fires on every
 *      bytecode instruction, so even pcall-swallowing code cannot make
 *      forward progress past one instruction before being hit again.
 *   5. If the resume has still not returned HARD_MS after the hook was
 *      armed, record HARD-ABORT-NEEDED and demonstrate the only two safe
 *      options from another thread: abandon the worker thread, or exit the
 *      process. You must NOT lua_close() a state whose thread is still
 *      executing.
 *   6. Between soft and hard deadlines the watchdog RE-ARMS the hook every
 *      REARM_MS (escalation path), in case the mask was cleared.
 *
 * WHAT THIS BINARY MEASURES (printed per run)
 * -------------------------------------------
 *   - jit.status() at start (engine ON/OFF) -- proves the sandbox kept the
 *     JIT even after the 'jit' global was removed.
 *   - time-to-interrupt latency: (hook first fired) - (deadline expiry).
 *   - total soft-abort time: (resume returned) - (deadline expiry).
 *   - hook fire count, whether the error object propagated out, and
 *     pass/fail vs. the expected outcome for the script.
 *   - counting-allocator peak / cap-hit for the alloc-bomb.
 *
 * WHAT THIS BINARY CANNOT DECIDE WITHOUT A BUILD
 * ----------------------------------------------
 *   - Whether a *compiled trace* actually takes the hook exit. That is the
 *     whole point of LUAJIT_ENABLE_CHECKHOOK (lj_record.c:2953: it emits a
 *     volatile XLOAD of g->hookmask + guard on every loop, so a live trace
 *     bails to the interpreter when a hook is set). Build WITH the flag and
 *     run attack_tight_loop.lua: the interrupt must fire. Build WITHOUT it
 *     and run the same: the interrupt is expected to NEVER fire (the loop
 *     trace is self-contained and polls nothing) -> HARD-ABORT-NEEDED.
 *     That A/B is the load-bearing experiment; the numbers are TBD until
 *     someone compiles both.
 *   - The real CHECKHOOK tax: run bench_*.lua on a CHECKHOOK build vs a
 *     stock build vs jit.off (this harness gives you the --jitoff knob and
 *     the wall-clock; the build.bat / Makefile give you the two binaries).
 *   - Cross-thread memory-ordering safety of async lua_sethook on real
 *     hardware (documented for signals = same thread; cross-thread is the
 *     established CCLuaJIT/OC pattern but should be checked under TSan).
 *
 * BUILD: see build.bat (MSVC) / Makefile (gcc, mingw-w64, Linux). Link
 * against a STATIC LuaJIT v2.1 built with
 *   XCFLAGS='-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK'
 * (GC64 left at its x64 default -- required, see note at counting_alloc).
 *
 * C11, single file. No dependency beyond LuaJIT + the platform threads.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "luajit.h"

/* ---- platform: threads, mutex/condvar, monotonic clock, sleep -------- */

#if defined(_WIN32)
  #define WIN32_LEAN_AND_MEAN
  /* CONDITION_VARIABLE / SleepConditionVariableCS need Vista+ (0x0600). */
  #if !defined(_WIN32_WINNT) || (_WIN32_WINNT < 0x0600)
    #undef  _WIN32_WINNT
    #define _WIN32_WINNT 0x0600
  #endif
  #include <windows.h>

  typedef HANDLE            thread_t;
  typedef CRITICAL_SECTION  mtx_t_;
  typedef CONDITION_VARIABLE cnd_t_;

  static void mtx_init_(mtx_t_ *m)   { InitializeCriticalSection(m); }
  static void mtx_lock_(mtx_t_ *m)   { EnterCriticalSection(m); }
  static void mtx_unlock_(mtx_t_ *m) { LeaveCriticalSection(m); }
  static void cnd_init_(cnd_t_ *c)   { InitializeConditionVariable(c); }
  static void cnd_signal_(cnd_t_ *c) { WakeConditionVariable(c); }
  /* wait up to ms; returns 1 if signalled, 0 on timeout */
  static int  cnd_timedwait_(cnd_t_ *c, mtx_t_ *m, unsigned ms) {
    return SleepConditionVariableCS(c, m, ms) ? 1 : 0;
  }
  static void sleep_ms_(unsigned ms) { Sleep(ms); }

  static double now_ms(void) {
    static LARGE_INTEGER freq; static int have = 0;
    LARGE_INTEGER t;
    if (!have) { QueryPerformanceFrequency(&freq); have = 1; }
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * 1000.0 / (double)freq.QuadPart;
  }

  typedef DWORD thread_ret_t;
  #define THREAD_CALL WINAPI
  static int thread_start_(thread_t *th, thread_ret_t (THREAD_CALL *fn)(void*), void *arg) {
    *th = CreateThread(NULL, 0, fn, arg, 0, NULL);
    return *th != NULL ? 0 : -1;
  }
  static void thread_join_(thread_t th) { WaitForSingleObject(th, INFINITE); CloseHandle(th); }
  static void thread_abandon_(thread_t th) { CloseHandle(th); /* leak the running thread */ }

#else
  #include <pthread.h>
  #include <time.h>
  #include <unistd.h>
  #include <errno.h>

  typedef pthread_t        thread_t;
  typedef pthread_mutex_t  mtx_t_;
  typedef pthread_cond_t   cnd_t_;

  static void mtx_init_(mtx_t_ *m)   { pthread_mutex_init(m, NULL); }
  static void mtx_lock_(mtx_t_ *m)   { pthread_mutex_lock(m); }
  static void mtx_unlock_(mtx_t_ *m) { pthread_mutex_unlock(m); }
  static void cnd_init_(cnd_t_ *c)   { pthread_cond_init(c, NULL); }
  static void cnd_signal_(cnd_t_ *c) { pthread_cond_signal(c); }
  static int  cnd_timedwait_(cnd_t_ *c, mtx_t_ *m, unsigned ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);              /* pthread_cond uses REALTIME */
    ts.tv_sec  += ms / 1000u;
    ts.tv_nsec += (long)(ms % 1000u) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    int rc = pthread_cond_timedwait(c, m, &ts);
    return rc == 0 ? 1 : 0;                           /* 0 => timeout (ETIMEDOUT) */
  }
  static void sleep_ms_(unsigned ms) {
    struct timespec ts = { ms / 1000u, (long)(ms % 1000u) * 1000000L };
    nanosleep(&ts, NULL);
  }
  static double now_ms(void) {                         /* MONOTONIC for measurement */
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
  }

  typedef void *thread_ret_t;
  #define THREAD_CALL
  static int thread_start_(thread_t *th, thread_ret_t (THREAD_CALL *fn)(void*), void *arg) {
    return pthread_create(th, NULL, fn, arg);
  }
  static void thread_join_(thread_t th) { pthread_join(th, NULL); }
  static void thread_abandon_(thread_t th) { pthread_detach(th); /* leak it */ }
#endif

/* ---- config --------------------------------------------------------- */

typedef struct {
  unsigned soft_ms;   /* deadline: inject hook after this */
  unsigned hard_ms;   /* after hook armed, escalate to hard abort after this */
  unsigned rearm_ms;  /* re-arm interval between soft and hard */
  size_t   mem_cap;   /* counting allocator cap, bytes */
  int      jitoff;    /* force JIT engine off (for A/B benchmarking) */
  int      hard_exit; /* on hard abort: 1 = _exit(process), 0 = abandon thread */
  const char *script_path;
  const char *expect;  /* "interrupt" | "complete" | "memcap" | "hard" | NULL */
} config_t;

/* ---- counting allocator (GC64 only; see note) ----------------------- */
/*
 * Under x64 GC64 (LuaJIT's default on 64-bit, LJ_GC64=1 -- lj_arch.h:216),
 * lua_newstate(lua_Alloc, ud) is the REAL allocator entry (lj_state.c:249)
 * and a custom allocf is fully supported. Only the *non*-GC64 x64 build
 * disables lua_newstate and forces the internal allocator
 * (lib_aux.c:391-398). So this counting allocator, installed via
 * lua_newstate, works precisely because we keep GC64 on. On 32-bit it also
 * works. Do NOT pass -DLUAJIT_DISABLE_GC64.
 *
 * LuaJIT passes the true old size in osize (0 for fresh allocations), not
 * the Lua 5.1 type-tag convention, so byte accounting is exact.
 */
typedef struct {
  size_t used, peak, cap;
  unsigned long cap_hits;
} memstate_t;

static void *counting_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  memstate_t *m = (memstate_t *)ud;
  if (nsize == 0) {                 /* free */
    if (ptr) m->used -= osize;
    free(ptr);
    return NULL;
  }
  if (nsize > osize) {              /* growth: enforce cap */
    size_t add = nsize - osize;
    if (m->used + add > m->cap) { m->cap_hits++; return NULL; }
  }
  void *np = realloc(ptr, nsize);
  if (np) {
    m->used = m->used - osize + nsize;
    if (m->used > m->peak) m->peak = m->used;
  }
  return np;
}

/* ---- shared watchdog state ------------------------------------------ */

typedef struct {
  lua_State *co;          /* the coroutine running the script */
  mtx_t_ mtx;
  cnd_t_ cnd;
  int    done;            /* worker finished lua_resume */
  int    resume_rc;       /* lua_resume return code */
  double t_resume_done;   /* now_ms() when resume returned */
} shared_t;

/* Hook-side telemetry. Written by the Lua worker thread (in the hook),
 * read by the watchdog. volatile + plain double: single writer for the
 * "first fire" value (guarded by g_hook_fired flag), coarse-grained. */
static volatile int    g_hook_armed   = 0;   /* watchdog set the hook */
static volatile int    g_hook_fired   = 0;   /* hook ran at least once */
static volatile double g_hook_fire_ms = 0.0; /* first-fire timestamp */
static volatile long   g_hook_count   = 0;   /* number of hook invocations */

/* The async hook: raise a catchable error OBJECT (a tagged table). */
static void watchdog_hook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  if (!g_hook_fired) {                 /* record first-fire latency point */
    g_hook_fire_ms = now_ms();
    g_hook_fired = 1;
  }
  g_hook_count++;
  /* Build {watchdog=true, kind="soft-timeout"} and raise it. callhook()
   * already reserved 1+LUA_MINSTACK slots before calling us
   * (lj_dispatch.c:377), so this is safe. lua_error does a longjmp to the
   * nearest protected frame (an intervening pcall) or out through
   * lua_resume; it never returns. */
  lua_createtable(L, 0, 2);
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "watchdog");
  lua_pushstring(L, "soft-timeout");
  lua_setfield(L, -2, "kind");
  lua_error(L);   /* no return */
}

/* ---- sandbox setup -------------------------------------------------- */

static void open_one(lua_State *L, lua_CFunction opener, const char *name) {
  lua_pushcfunction(L, opener);
  lua_pushstring(L, name);
  lua_call(L, 1, 0);
}

static int g_jit_status_ref = LUA_NOREF;   /* stashed jit.status */

/* Open the real sandbox library set, capture jit.status, then delete the
 * 'jit' and 'debug' globals -- exactly the shape of the real OC sandbox,
 * while the JIT engine stays ON. */
static void setup_sandbox(lua_State *L) {
  open_one(L, luaopen_base,   "");
  open_one(L, luaopen_math,   LUA_MATHLIBNAME);
  open_one(L, luaopen_string, LUA_STRLIBNAME);
  open_one(L, luaopen_table,  LUA_TABLIBNAME);
  open_one(L, luaopen_bit,    LUA_BITLIBNAME);
  open_one(L, luaopen_jit,    LUA_JITLIBNAME);   /* this arms JIT_F_ON */

  /* stash jit.status so C can query engine state after we nuke the global */
  lua_getglobal(L, "jit");
  lua_getfield(L, -1, "status");
  g_jit_status_ref = luaL_ref(L, LUA_REGISTRYINDEX);   /* pops the function */
  lua_pop(L, 1);                                         /* pop jit table   */

  /* mimic the sandbox: no jit/debug reachable from Lua */
  lua_pushnil(L); lua_setglobal(L, "jit");
  lua_pushnil(L); lua_setglobal(L, "debug");
}

static int jit_engine_on(lua_State *L) {
  if (g_jit_status_ref == LUA_NOREF) return -1;
  lua_rawgeti(L, LUA_REGISTRYINDEX, g_jit_status_ref);
  if (lua_pcall(L, 0, 1, 0) != 0) { lua_pop(L, 1); return -1; }
  int on = lua_toboolean(L, -1);
  lua_pop(L, 1);
  return on;
}

/* ---- worker thread: runs the script on the coroutine ---------------- */

static thread_ret_t THREAD_CALL worker_main(void *arg) {
  shared_t *sh = (shared_t *)arg;
  int rc = lua_resume(sh->co, 0);       /* Lua 5.1 / LuaJIT 2-arg form */
  mtx_lock_(&sh->mtx);
  sh->resume_rc = rc;
  sh->t_resume_done = now_ms();
  sh->done = 1;
  cnd_signal_(&sh->cnd);
  mtx_unlock_(&sh->mtx);
  return (thread_ret_t)0;
}

/* wait up to timeout_ms for the worker to finish; 1 if done, 0 if timeout */
static int wait_done(shared_t *sh, unsigned timeout_ms) {
  int done = 0;
  double deadline = now_ms() + (double)timeout_ms;
  mtx_lock_(&sh->mtx);
  while (!sh->done) {
    double remain = deadline - now_ms();
    if (remain <= 0) break;
    cnd_timedwait_(&sh->cnd, &sh->mtx, (unsigned)remain);
  }
  done = sh->done;
  mtx_unlock_(&sh->mtx);
  return done;
}

/* ---- result reporting ----------------------------------------------- */

typedef enum { R_COMPLETE, R_INTERRUPT, R_MEMCAP, R_ERROR, R_HARD } result_kind;

static const char *rk_name(result_kind k) {
  switch (k) {
    case R_COMPLETE:  return "complete";
    case R_INTERRUPT: return "interrupt";
    case R_MEMCAP:    return "memcap";
    case R_ERROR:     return "error";
    case R_HARD:      return "hard-abort-needed";
  }
  return "?";
}

/* Classify how the resume ended by inspecting the coroutine's error value. */
static result_kind classify(lua_State *co, int rc, memstate_t *mem, const char **msg) {
  *msg = NULL;
  if (rc == 0 || rc == LUA_YIELD) return R_COMPLETE;
  /* error is on top of co's stack */
  if (lua_type(co, -1) == LUA_TTABLE) {
    lua_getfield(co, -1, "watchdog");
    int wd = lua_toboolean(co, -1);
    lua_pop(co, 1);
    if (wd) { *msg = "watchdog error object caught"; return R_INTERRUPT; }
  }
  if (lua_type(co, -1) == LUA_TSTRING) {
    const char *s = lua_tostring(co, -1);
    *msg = s;
    if (mem->cap_hits && s && strstr(s, "memory")) return R_MEMCAP;
  }
  if (mem->cap_hits) return R_MEMCAP;
  return R_ERROR;
}

/* ---- main ----------------------------------------------------------- */

static char *read_file(const char *path, size_t *len_out) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) { fclose(f); return NULL; }
  char *buf = (char *)malloc((size_t)n + 1);
  if (!buf) { fclose(f); return NULL; }
  size_t rd = fread(buf, 1, (size_t)n, f);
  fclose(f);
  buf[rd] = '\0';
  *len_out = rd;
  return buf;
}

static void usage(const char *argv0) {
  fprintf(stderr,
    "usage: %s [options] <script.lua>\n"
    "  --soft-ms N     inject hook after N ms wall-clock   (default 200)\n"
    "  --hard-ms N     escalate to hard abort N ms after arming (default 500)\n"
    "  --rearm-ms N    re-arm hook every N ms in soft..hard window (default 50)\n"
    "  --mem-mb N      counting allocator cap in MB         (default 64)\n"
    "  --jitoff        force JIT engine OFF (A/B benchmarking)\n"
    "  --hard-exit     on hard abort, _exit the process (default: abandon thread)\n"
    "  --expect K      expected result: complete|interrupt|memcap|hard (pass/fail)\n",
    argv0);
}

int main(int argc, char **argv) {
  config_t cfg;
  cfg.soft_ms = 200; cfg.hard_ms = 500; cfg.rearm_ms = 50;
  cfg.mem_cap = (size_t)64 * 1024 * 1024;
  cfg.jitoff = 0; cfg.hard_exit = 0;
  cfg.script_path = NULL; cfg.expect = NULL;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if      (!strcmp(a, "--soft-ms")  && i+1 < argc) cfg.soft_ms  = (unsigned)strtoul(argv[++i], 0, 10);
    else if (!strcmp(a, "--hard-ms")  && i+1 < argc) cfg.hard_ms  = (unsigned)strtoul(argv[++i], 0, 10);
    else if (!strcmp(a, "--rearm-ms") && i+1 < argc) cfg.rearm_ms = (unsigned)strtoul(argv[++i], 0, 10);
    else if (!strcmp(a, "--mem-mb")   && i+1 < argc) cfg.mem_cap  = (size_t)strtoul(argv[++i], 0, 10) * 1024 * 1024;
    else if (!strcmp(a, "--jitoff"))   cfg.jitoff = 1;
    else if (!strcmp(a, "--hard-exit")) cfg.hard_exit = 1;
    else if (!strcmp(a, "--expect")   && i+1 < argc) cfg.expect = argv[++i];
    else if (a[0] == '-') { usage(argv[0]); return 2; }
    else cfg.script_path = a;
  }
  if (!cfg.script_path) { usage(argv[0]); return 2; }

  size_t src_len = 0;
  char *src = read_file(cfg.script_path, &src_len);
  if (!src) { fprintf(stderr, "cannot read %s\n", cfg.script_path); return 2; }

  /* create the state with the counting allocator (GC64) */
  memstate_t mem = { 0, 0, cfg.mem_cap, 0 };
  lua_State *L = lua_newstate(counting_alloc, &mem);
  if (!L) { fprintf(stderr, "lua_newstate failed (GC64 required for custom allocf)\n"); free(src); return 3; }

  setup_sandbox(L);

  if (cfg.jitoff) {
    /* engine off from C -- 'jit' global is gone, so we can't use jit.off() */
    luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);
  }
  int jit_on = jit_engine_on(L);

  /* load the chunk onto a fresh coroutine */
  lua_State *co = lua_newthread(L);
  if (luaL_loadbuffer(co, src, src_len, cfg.script_path) != 0) {
    fprintf(stderr, "compile error: %s\n", lua_tostring(co, -1));
    lua_close(L); free(src); return 3;
  }
  free(src);

  shared_t sh;
  sh.co = co; sh.done = 0; sh.resume_rc = 0; sh.t_resume_done = 0.0;
  mtx_init_(&sh.mtx); cnd_init_(&sh.cnd);

  printf("== watchdog prototype ==\n");
  printf("script      : %s\n", cfg.script_path);
  printf("jit.status(): %s\n", jit_on < 0 ? "unknown" : (jit_on ? "ON" : "off"));
  printf("soft/hard/rearm ms: %u / %u / %u\n", cfg.soft_ms, cfg.hard_ms, cfg.rearm_ms);
  printf("mem cap     : %zu bytes\n", cfg.mem_cap);
  fflush(stdout);

  double t0 = now_ms();
  thread_t worker;
  if (thread_start_(&worker, worker_main, &sh) != 0) {
    fprintf(stderr, "thread start failed\n"); lua_close(L); return 3;
  }

  /* --- phase 1: wait up to SOFT_MS for a benign completion --- */
  int done = wait_done(&sh, cfg.soft_ms);

  double t_deadline = 0.0, latency = -1.0, soft_total = -1.0;
  result_kind rk = R_ERROR;
  const char *msg = NULL;
  int hard = 0;

  if (done) {
    /* finished before the deadline -- benchmark / quick error path */
    thread_join_(worker);
    rk = classify(co, sh.resume_rc, &mem, &msg);
  } else {
    /* --- phase 2: deadline expired: arm the hook asynchronously --- */
    t_deadline = now_ms();
    g_hook_armed = 1;
    lua_sethook(co, watchdog_hook,
                LUA_MASKCOUNT | LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 1);

    /* --- phase 3: wait up to HARD_MS, re-arming every rearm_ms --- */
    double hard_deadline = t_deadline + (double)cfg.hard_ms;
    int wdone = 0;
    while (!wdone && now_ms() < hard_deadline) {
      wdone = wait_done(&sh, cfg.rearm_ms);   /* lock-protected read */
      if (!wdone) {
        /* escalation: re-arm in case the mask was cleared or a C call
         * swallowed everything. Still async-safe. Harmless if the
         * coroutine has just finished. */
        lua_sethook(co, watchdog_hook,
                    LUA_MASKCOUNT | LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 1);
      }
    }

    if (wdone) {
      thread_join_(worker);
      lua_sethook(co, NULL, 0, 0);     /* disarm */
      rk = classify(co, sh.resume_rc, &mem, &msg);
      if (g_hook_fired) {
        latency    = g_hook_fire_ms   - t_deadline;
        soft_total = sh.t_resume_done - t_deadline;
      }
    } else {
      /* --- HARD ABORT NEEDED --- resume never returned. --- */
      hard = 1;
      rk = R_HARD;
    }
  }

  /* ---- report ---- */
  printf("\n-- result --\n");
  printf("outcome     : %s%s%s\n", rk_name(rk), msg ? " : " : "", msg ? msg : "");
  printf("hook armed  : %s\n", g_hook_armed ? "yes" : "no");
  printf("hook fired  : %s (count=%ld)\n", g_hook_fired ? "yes" : "no", g_hook_count);
  if (latency >= 0)
    printf("interrupt latency (deadline->first hook): %.3f ms\n", latency);
  if (soft_total >= 0)
    printf("soft-abort total (deadline->resume ret) : %.3f ms\n", soft_total);
  printf("mem peak    : %zu bytes  cap_hits=%lu\n", mem.peak, mem.cap_hits);
  printf("wall (start->now): %.3f ms\n", now_ms() - t0);

  int pass = 1;
  if (cfg.expect) {
    pass = (strcmp(cfg.expect, rk_name(rk)) == 0);
    /* memcap scripts may also surface as R_ERROR text; accept either */
    if (!pass && !strcmp(cfg.expect, "memcap") && rk == R_ERROR && mem.cap_hits) pass = 1;
    printf("expect=%s -> %s\n", cfg.expect, pass ? "PASS" : "FAIL");
  }

  if (hard) {
    printf("\n!! HARD-ABORT-NEEDED: the coroutine thread is still running the\n"
           "   VM. It is UNSAFE to lua_close(L) now (its thread owns the state).\n");
    if (cfg.hard_exit) {
      printf("   demonstrating: process exit.\n");
      fflush(stdout);
      /* exit hard: avoid atexit/CRT teardown touching the live state */
#if defined(_WIN32)
      ExitProcess(42);
#else
      _exit(42);
#endif
    } else {
      printf("   demonstrating: abandon the worker thread (leak it), skip\n"
             "   lua_close, and let this harness process return. In the real\n"
             "   addon the Java side would drop its reference to the state and\n"
             "   let the whole computer be torn down.\n");
      thread_abandon_(worker);
      fflush(stdout);
      /* deliberately DO NOT lua_close(L) */
      return cfg.expect ? (pass ? 0 : 1) : 40;
    }
  }

  lua_close(L);
  return cfg.expect ? (pass ? 0 : 1) : 0;
}
