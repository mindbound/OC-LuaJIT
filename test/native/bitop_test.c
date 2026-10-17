/* =====================================================================
 * bitop_test.c -- Lua 5.3's bitwise operators (round 3, U1-B) through the
 * SHIM, as a machine's state has them: a state from lj52_newstate on the
 * shim's own allocator in C mode with a real RAM cap, its libraries opened the
 * way OC-JNLua opens them (luaL_requiref, never luaL_openlibs), the JIT on
 * (lj52_newstate opens it: _OCLJ_JIT).
 *
 * The operators are LuaJIT bytecodes of our fork (native/luajit/patch-bitop-*,
 * oclj_bitop*.{h,c}), so luajit.exe has the same code, and test/native/
 * run-bitop.sh checks their results there against PUC Lua 5.3.6 (parts 1-2).
 * What only a shim state, or only the C API, can show is checked here:
 *
 *   BT1  results reach C through lua_tonumber as the exact double of 5.3.6's
 *        integer, runtime and folded, up to 2^53-1 and down to -2^63, and
 *        `~>>` as well; the reference is computed here, in C, on int64
 *   BT2  lua_tointeger / lua_tointegerx of a 2^40 result is 1099511627776,
 *        not a 32-bit wrap; of 2^53-1 and of -2^63 the same integers
 *   BT3  the new error, "result of '>>' has more than 53 significant bits
 *        (mask each operand to 32 bits first)" (the hint decided 2026-10-17),
 *        its whole text, through lua_pcall as LUA_ERRRUN with its
 *        chunk:line: prefix: from a
 *        runtime operand, from literals (the parser does not fold an inexact
 *        result), from a string operand (the C path), and from a loop that is
 *        compiled when the inexact result first appears (the trace's guard
 *        exits and the interpreter raises); then the state carries on
 *   BT4  the RAM cap: the operators' C path, string operands and counts
 *        outside 0..63 included, charges the cap nothing -- 100000 iterations
 *        with the collector stopped and the function's JIT off cost +0 bytes;
 *        a control loop that allocates is charged in the same run, so the
 *        instrument can see an allocation
 *   BT5  the count hook (CHECKHOOK, set with lua_sethook as the watchdog
 *        does) fires inside a compiled 64-bit bit loop: more than 100 ticks
 *        over 20M iterations, the build gate's bound (build-native.sh
 *        checkhook.lua), traces compiled, and the loop's result PUC 5.3.6's
 *   BT6  bit32 (the shim's real 5.2 library, luaopen_bit32) is untouched by
 *        the operators beside it (U10): one line of results, PUC 5.3.6's
 *        bit32 output (measured 2026-10-17), with 1 << 32 between them
 *
 * Build and run: sh test/native/run-bitop.sh (its part 3).
 * Output: one "PASS <id>" / "FAIL <id>" line per check.  Exit 0 iff every
 * check passed, 1 if one failed, 2 if the test proved nothing.
 * ===================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* ---- we are pretending to be jnlua (as mem_test.c and pack_test.c do) -----
 * lj52shim.h's lua_setallocf macro names four things out of jnlua.c. */
#define JNLUA_JAVASTATE "jnlua.JavaState"
typedef struct { jint total; jint used; } FakeState;
static FakeState FS;
static JNIEnv FAKE_ENV = NULL;
static JNIEnv *getthreadenv(void) { return &FAKE_ENV; }
static void getluamemory(JNIEnv *env, jobject obj, jint *total, jint *used) {
  FakeState *s = (FakeState *)(void *)obj;
  (void)env;
  *total = s->total;
  *used = s->used;
}
static void setluamemory(JNIEnv *env, jobject obj, jint used) {
  FakeState *s = (FakeState *)(void *)obj;
  (void)env;
  s->used = used;
}
static void bind_javastate(lua_State *L, void *obj) {
  void **ref = (void **)lua_newuserdata(L, sizeof(void *));
  *ref = obj;
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
}

/* ---- reporting ----------------------------------------------------------- */
static int checks = 0, failures = 0;
static void check(const char *id, int cond, const char *what, const char *detail) {
  checks++;
  if (!cond) failures++;
  printf("%s %-5s %-62s %s\n", cond ? "PASS" : "FAIL", id, what, detail ? detail : "");
  fflush(stdout);
}
static void fatal(const char *msg, const char *detail) {
  printf("SETUP FAILURE: %s%s%s\n", msg, detail ? ": " : "", detail ? detail : "");
  printf("BITOP TESTS: VACUOUS (exit 2)\n");
  exit(2);
}

/* Load and run src protected, leaving its results (or the error) on the stack
 * above base; returns the status. */
static int runsrc(lua_State *L, const char *src, int nres) {
  int st = luaL_loadstring(L, src);
  if (st == 0) st = lua_pcall(L, 0, nres, 0);
  return st;
}

/* Run src (which returns one string) protected; copy the result or the error. */
static int evalstr(lua_State *L, const char *src, char *out, size_t outn) {
  int base = lua_gettop(L), okv = 0;
  out[0] = 0;
  if (runsrc(L, src, 1) != 0) {
    const char *e = lua_tostring(L, -1);
    snprintf(out, outn, "ERR %s", e ? e : "?");
  } else {
    const char *s = lua_tostring(L, -1);
    snprintf(out, outn, "%s", s ? s : "<nil>");
    okv = 1;
  }
  lua_settop(L, base);
  return okv;
}

/* The double of an int64 result, and whether it is exactly that int64 (the
 * reference for BT1; every value used has at most 53 significant bits, so the
 * second must hold -- checked, not assumed). */
static int exactd(int64_t i, double *d) {
  *d = (double)i;
  return *d >= -9223372036854775808.0 && *d < 9223372036854775808.0 && (int64_t)*d == i;
}

/* The count hook of BT5. */
static long hook_ticks = 0;
static void count_hook(lua_State *L, lua_Debug *ar) { (void)L; (void)ar; hook_ticks++; }

/* jit.off(f) on the function at idx, from C, protected: BT4 measures the
 * interpreter's C path, not the recorder's buffers. */
static int jit_off_fn(lua_State *L, int idx) {
  int base = lua_gettop(L), st;
  idx = lua_absindex(L, idx);
  lua_getglobal(L, "jit");
  if (!lua_istable(L, -1)) { lua_settop(L, base); return -1; }
  lua_getfield(L, -1, "off");
  lua_pushvalue(L, idx);
  st = lua_pcall(L, 1, 0, 0);
  lua_settop(L, base);
  return st;
}

/* The heap charge of one call of src (a chunk returning one number), with the
 * collector stopped and the chunk's JIT off; *res gets its result. */
static long long charge_of(lua_State *L, const char *src, double *res, int *st) {
  long long u0, u1;
  int base = lua_gettop(L);
  *res = 0;
  *st = luaL_loadstring(L, src);
  if (*st != 0) { lua_settop(L, base); return -1; }
  if (jit_off_fn(L, -1) != 0) { *st = -1; lua_settop(L, base); return -1; }
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCCOLLECT, 0);
  lua_gc(L, LUA_GCSTOP, 0);
  u0 = lj52_mem_used(L);
  *st = lua_pcall(L, 0, 1, 0);
  u1 = lj52_mem_used(L);
  if (*st == 0) *res = lua_tonumber(L, -1);
  lua_settop(L, base);
  lua_gc(L, LUA_GCRESTART, 0);
  return u1 - u0;
}

int main(void) {
  lua_State *L;
  char buf[512], detail[1024];
  int st, i;

  /* ---------------------------------------------------------------- setup
   * A state as LuaStateLuaJIT makes one: lj52_newstate, jnlua's capped form,
   * the JavaState bound, the cap handed to the native side (C mode).  Then
   * the libraries the kernel needs here, each the way jnlua opens it. */
  L = luaL_newstate();                         /* == lj52_newstate() via the shim */
  if (!L) fatal("luaL_newstate returned NULL", NULL);
  FS.total = 64 * 1024 * 1024;
  lua_setallocf(L, NULL, L);
  bind_javastate(L, (void *)&FS);
  lj52_mem_settotal(L, 64LL * 1024 * 1024);
  if (lj52_mem_used(L) < 0) fatal("the state did not hand over to C mode (lj52_mem_used < 0)", NULL);
  luaL_requiref(L, "_G", luaopen_base, 1);             lua_pop(L, 1);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(L, 1);
  luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);  lua_pop(L, 1);
  luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);  lua_pop(L, 1);
  luaL_requiref(L, LUA_DBLIBNAME, luaopen_debug, 1);   lua_pop(L, 1);
  luaL_requiref(L, LUA_BITLIBNAME, luaopen_bit32, 1);  lua_pop(L, 1);
  lua_getglobal(L, "_OCLJ_NATIVE");
  if (!lua_isstring(L, -1) || strncmp(lua_tostring(L, -1), "luajit/", 7) != 0)
    fatal("no _OCLJ_NATIVE marker -- lj52shim.o is not linked into this test", NULL);
  lua_pop(L, 1);
  lua_getglobal(L, "jit");
  if (!lua_istable(L, -1)) fatal("no global jit table -- lj52_newstate did not open the JIT", NULL);
  lua_pop(L, 1);
  if (!evalstr(L, "return tostring(jit.status())", buf, sizeof buf) || strcmp(buf, "true") != 0)
    fatal("the JIT is not on in this state", buf);

  /* ---------------------------------------------------------------- BT1 */
  printf("\n== BT1  results through lua_tonumber: 5.3.6's integer, exactly ==\n");
  {
    /* 1 << 40, (1 << 52) | 1, 1 << 63, ~(1 << 52), -1 >> 11 (5.3's >> is
     * logical: 2^53 - 1), (1 << 62) ~>> 61 */
    static const char *SRC[2] = {
      "local o = tonumber('1') return o << 40, (o << 52) | o, o << 63, ~(o << 52), -o >> 11, (o << 62) ~>> 61",
      "return 1 << 40, (1 << 52) | 1, 1 << 63, ~(1 << 52), -1 >> 11, (1 << 62) ~>> 61",
    };
    static const char *ID[2] = { "BT1a", "BT1b" };
    static const char *WHAT[2] = { "runtime operands: six results equal C's int64, exactly",
                                   "literal operands (folded): the same six" };
    int64_t want[6];
    want[0] = (int64_t)1 << 40;
    want[1] = ((int64_t)1 << 52) | 1;
    want[2] = INT64_MIN;
    want[3] = ~((int64_t)1 << 52);
    want[4] = (int64_t)(UINT64_MAX >> 11);
    want[5] = 2;
    for (i = 0; i < 2; i++) {
      int k, good = 0, exact = 0, base = lua_gettop(L);
      st = runsrc(L, SRC[i], 6);
      if (st != 0) {
        snprintf(detail, sizeof detail, "status %d: %s", st, lua_tostring(L, -1));
      } else {
        char *p = detail;
        size_t left = sizeof detail;
        for (k = 0; k < 6; k++) {
          double d, got = lua_tonumber(L, base + 1 + k);
          int n;
          if (exactd(want[k], &d)) exact++;
          if (got == d) good++;
          n = snprintf(p, left, "%s%.17g", k ? " " : "", got);
          if (n < 0 || (size_t)n >= left) break;
          p += n; left -= (size_t)n;
        }
      }
      check(ID[i], st == 0 && good == 6 && exact == 6, WHAT[i], detail);
      lua_settop(L, base);
    }
  }

  /* ---------------------------------------------------------------- BT2 */
  printf("\n== BT2  lua_tointeger / lua_tointegerx: 64-bit integers, not a 32-bit wrap ==\n");
  {
    int base = lua_gettop(L), isnum1 = 0, isnum2 = 0;
    lua_Integer a = 0, b = 0, c = 0;
    st = runsrc(L, "local o = tonumber('1') return o << 40, -o >> 11, o << 63", 3);
    if (st == 0) {
      a = lua_tointeger(L, base + 1);
      b = lua_tointegerx(L, base + 2, &isnum1);
      c = lua_tointegerx(L, base + 3, &isnum2);
    }
    snprintf(detail, sizeof detail, "status %d: %lld, %lld (isnum %d), %lld (isnum %d)", st,
             (long long)a, (long long)b, isnum1, (long long)c, isnum2);
    check("BT2", st == 0 && sizeof(lua_Integer) == 8 && (long long)a == 1099511627776LL
                 && (long long)b == 9007199254740991LL && isnum1
                 && (long long)c == (long long)INT64_MIN && isnum2,
          "1 << 40, -1 >> 11, 1 << 63 read back as integers", detail);
    lua_settop(L, base);
  }

  /* ---------------------------------------------------------------- BT3 */
  printf("\n== BT3  the new error through lua_pcall: LUA_ERRRUN, positioned ==\n");
  {
    static const char *SRC[3] = {
      "local a = tonumber('-1') return a >> 1",
      "return -1 >> 1",
      "return '-1' >> 1",
    };
    static const char *ID[3] = { "BT3a", "BT3b", "BT3c" };
    static const char *WHAT[3] = { "a runtime operand: -1 >> 1 raises",
                                   "literals: not folded, raised at run time",
                                   "a string operand (the C path)" };
    static const char *MSG = ":1: result of '>>' has more than 53 significant bits"
                             " (mask each operand to 32 bits first)";
    for (i = 0; i < 3; i++) {
      int base = lua_gettop(L);
      const char *m;
      size_t ml, wl = strlen(MSG);
      st = runsrc(L, SRC[i], 1);
      m = lua_tostring(L, -1);
      ml = m ? strlen(m) : 0;
      snprintf(detail, sizeof detail, "status %d (LUA_ERRRUN %d) '%s'", st, LUA_ERRRUN, m ? m : "?");
      check(ID[i], st == LUA_ERRRUN && m && ml > wl && strcmp(m + ml - wl, MSG) == 0, WHAT[i], detail);
      lua_settop(L, base);
    }
    /* A loop that compiles at about iteration 56 and meets an inexact result
     * at 150: (2^60 + 1024) << 3 | 1 has 63 significant bits.  The loop's
     * traces are counted from Lua (jit.attach), so "compiled" is measured. */
    {
      int base = lua_gettop(L);
      const char *m;
      st = runsrc(L,
        "local stops = 0 "
        "local function cb(what) if what == 'stop' then stops = stops + 1 end end "
        "jit.attach(cb, 'trace') "
        "local o = tonumber('1') "
        "local function hot(k) local acc = 0 "
        "  for i = 1, 300 do local x = (i == k) and (o << 60) + 1024 or i acc = acc ~ ((x << 3) | 1) end "
        "  return acc end "
        "local ok1, r1 = pcall(hot, -1) "
        "local ok2, r2 = pcall(hot, 150) "
        "jit.attach(cb) "
        "return tostring(ok1) .. '/' .. tostring(r1) .. '|' .. tostring(ok2) .. '/' .. tostring(r2) .. '|' .. stops",
        1);
      m = lua_tostring(L, -1);
      snprintf(detail, sizeof detail, "status %d '%s'", st, m ? m : "?");
      check("BT3d", st == 0 && m && strncmp(m, "true/2400|false/", 16) == 0
                    && strstr(m, ":1: result of '|' has more than 53 significant bits"
                                 " (mask each operand to 32 bits first)|") != NULL
                    && atoi(strrchr(m, '|') + 1) >= 1,
            "a compiled loop: the inexact result at iteration 150 raises", detail);
      lua_settop(L, base);
    }
    evalstr(L, "return string.format('%.17g', (tonumber('1') << 52) | 1)", buf, sizeof buf);
    check("BT3e", strcmp(buf, "4503599627370497") == 0, "after the errors the state computes on", buf);
  }

  /* ---------------------------------------------------------------- BT4 */
  printf("\n== BT4  the RAM cap: the C path charges nothing ==\n");
  {
    double res = 0, cres = 0;
    int st2;
    long long ch, cch;
    /* Every operation here takes the C path (oclj_bitop_meta.c): a string
     * operand never takes the fast path, nor does a count outside 0..63. */
    ch = charge_of(L,
      "local s = 0 "
      "for i = 1, 100000 do s = s ~ ('3' & i) ~ (i | ' 7 ') ~ ('0x10' << 1) ~ (i << 64) ~ (i >> -2) end "
      "return s", &res, &st);
    /* The reference, in C: the same loop on int64. */
    {
      int64_t s = 0, k;
      for (k = 1; k <= 100000; k++) s = s ^ (3 & k) ^ (k | 7) ^ (16 << 1) ^ 0 ^ (k << 2);
      snprintf(detail, sizeof detail, "status %d, result %.17g (C: %lld), charged %+lld bytes", st, res,
               (long long)s, ch);
      check("BT4a", st == 0 && res == (double)s && ch == 0,
            "100000 iterations of C-path operations: +0 bytes", detail);
    }
    cch = charge_of(L, "local s = 0 for i = 1, 2000 do s = s + #tostring(i) end return s", &cres, &st2);
    snprintf(detail, sizeof detail, "status %d, result %.17g, charged %+lld bytes", st2, cres, cch);
    check("BT4b", st2 == 0 && cres == 6893.0 && cch > 0,
          "control: 2000 tostring() calls ARE charged (the instrument sees)", detail);
    lua_gc(L, LUA_GCCOLLECT, 0);
  }

  /* ---------------------------------------------------------------- BT5 */
  printf("\n== BT5  the count hook fires inside a compiled 64-bit bit loop ==\n");
  {
    int base = lua_gettop(L);
    const char *trs;
    double s = 0;
    long ticks;
    st = runsrc(L, "TRSTOP = 0 TRCB = function(what) if what == 'stop' then TRSTOP = TRSTOP + 1 end end "
                   "jit.attach(TRCB, 'trace')", 0);
    if (st != 0) fatal("jit.attach failed", lua_tostring(L, -1));
    hook_ticks = 0;
    lua_sethook(L, count_hook, LUA_MASKCOUNT, 500);
    st = runsrc(L, "local s = 0 for i = 1, 20000000 do s = (s ~ ((i << 28) & 0x1FFFFFFFFFFFFF)) >> 1 end return s", 1);
    lua_sethook(L, NULL, 0, 0);
    ticks = hook_ticks;
    if (st == 0) s = lua_tonumber(L, -1);
    lua_settop(L, base);
    evalstr(L, "jit.attach(TRCB) return tostring(TRSTOP)", buf, sizeof buf);
    trs = buf;
    snprintf(detail, sizeof detail, "status %d, %ld ticks, %s traces, s = %.17g (PUC 5.3.6: 4206410837014599)",
             st, ticks, trs, s);
    check("BT5", st == 0 && ticks > 100 && atoi(trs) >= 1 && s == 4206410837014599.0,
          "20M iterations, hook every 500: ticks > 100, compiled, 5.3's s", detail);
  }

  /* ---------------------------------------------------------------- BT6 */
  printf("\n== BT6  bit32 beside the operators: untouched ==\n");
  {
    static const char *WANT = "0 4294967296 1073741823 5 4294967295 -1 4294967292 2 15 2147483648 2147483649 0 0 1";
    evalstr(L,
      "local b = bit32 "
      "local r = { b.lshift(1, 32), 1 << 32, b.rshift(-1, 2), b.band(2^32 + 5, 7), b.bnot(0), ~0, b.arshift(-8, 1), "
      "  b.lrotate(1, 33), b.extract(0xF0, 4, 4), b.replace(0, 1, 31), b.bxor(2^31, 1), b.btest(1, 2) and 1 or 0, "
      "  b.lshift(1, -1), b.rshift(2^32 - 1, 31) } "
      "for i = 1, #r do r[i] = string.format('%.17g', r[i]) end "
      "return table.concat(r, ' ')", buf, sizeof buf);
    snprintf(detail, sizeof detail, "'%s'", buf);
    check("BT6", strcmp(buf, WANT) == 0, "bit32's 5.2 results, and 1 << 32 == 2^32 between them", detail);
  }

  lua_close(L);
  printf("\nBITOP TESTS: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
