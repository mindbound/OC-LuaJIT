/* =====================================================================
 * pack_test.c -- string.pack, string.packsize and string.unpack through the
 * SHIM, as a machine's state has them: a state from lj52_newstate on the
 * shim's own allocator in C mode with a real RAM cap, its string library
 * opened the way OC-JNLua opens it (jnlua.c:440, :469:
 * luaL_requiref(L, "string", luaopen_string, 1), and never luaL_openlibs).
 *
 * The functions are LuaJIT library functions of our fork (lib_string.c,
 * native/luajit/patch-strpack-register.sh; the code is
 * native/luajit/oclj_strpack.c), so luajit.exe has the same code, and
 * test/native/run-pack.sh checks the whole format language there
 * (pack/conformance.lua, pack/conf-extra.lua).  What only a shim state can
 * show is checked here:
 *
 *   PT1  jnlua's opener reaches them, and so does the string metatable
 *   PT2  a Plan9k GPT header (17_gpt.lua:12) unpacked from a sector of TEXT:
 *        every I8 field needs more than 53 bits, and each comes back as the
 *        nearest double of the exact 64-bit value, never as a refusal (the
 *        decided rounding; the reference is computed here, in C)
 *   PT3  a 1 MiB pack with the collector stopped charges the cap 2x the
 *        output, within 5%: its scratch block and its result, both through
 *        lj52_alloc -- the accounting sees it, and nothing builds the
 *        output in a growing buffer (LuaJIT's luaL_Buffer peaked at 3.8-4.6x)
 *   PT4  past the cap, pack is refused as LUA_ERRMEM "not enough memory":
 *        not D4's text, and not a crash.  PT4b: only after every argument
 *        check -- pack('c16777216 j', '', 'x') under the same margin is the
 *        arg #3 error (LUA_ERRRUN), not LUA_ERRMEM.  That nothing is written
 *        before the refusal cannot be seen from here: PT3's 2x charge and
 *        the code (pass 1, D4, then one allocation) carry that.  PT5: the
 *        state carries on
 *   PT6  unpack's result count stops at LuaJIT's C-stack limit
 *        (LUAI_MAXCSTACK, 8000) with "stack overflow (too many results)",
 *        a clean refusal; 7990 results still come back
 *   PT7  D4: a result of LJ_MAX_STR (0x7fffff00) bytes or more is refused,
 *        after every argument check and before anything is allocated, with
 *        the text 5.3.6's luaL_Buffer raises when its allocation fails,
 *        "not enough memory for buffer allocation" (LUA_ERRRUN).
 *        pack('c2147483392', '') is that total, and so is
 *        pack('c2147483391c1', '', ''), from two options: an off-by-one
 *        (> for >=) lets both through to the allocator.  One byte less,
 *        pack('c2147483391', ''), passes D4 and is refused by the cap as
 *        LUA_ERRMEM "not enough memory".  pack('c2000000000c2000000000', '',
 *        {}) is the arg #3 error: the checks come before D4.  Nothing large
 *        is ever allocated: D4 and the argument check raise before the one
 *        allocation, and lj52_alloc refuses the c2147483391 block (past the
 *        64 MiB cap and its credit) before it calls the system allocator.
 *        Only here, never under PUC, which would allocate 2-4 GB for these.
 *
 * Build and run: sh test/native/run-pack.sh (its part 3).
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

/* ---- we are pretending to be jnlua (as mem_test.c does) ------------------
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
  printf("%s %-5s %-60s %s\n", cond ? "PASS" : "FAIL", id, what, detail ? detail : "");
  fflush(stdout);
}
static void fatal(const char *msg, const char *detail) {
  printf("SETUP FAILURE: %s%s%s\n", msg, detail ? ": " : "", detail ? detail : "");
  printf("PACK TESTS: VACUOUS (exit 2)\n");
  exit(2);
}

/* string.<name> on top of the stack, or nil. */
static void getstrfn(lua_State *L, const char *name) {
  lua_getglobal(L, "string");
  if (lua_istable(L, -1)) lua_getfield(L, -1, name); else lua_pushnil(L);
  lua_remove(L, -2);
}

/* Run src (which returns one string) protected; copy the result or the error. */
static int evalstr(lua_State *L, const char *src, char *out, size_t outn) {
  int base = lua_gettop(L), okv = 0;
  out[0] = 0;
  if (luaL_loadstring(L, src) != 0 || lua_pcall(L, 0, 1, 0) != 0) {
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

/* pack(fmt, '' [, third]) protected, called from C as PT4 calls it; third is
 * 0 (none), 1 ('') or 2 ({}).  Returns the status; copies the error text, or
 * "<no error, N bytes>". */
static int packst(lua_State *L, const char *fmt, int third, char *out, size_t outn) {
  int base = lua_gettop(L), st;
  getstrfn(L, "pack");
  lua_pushstring(L, fmt);
  lua_pushliteral(L, "");
  if (third == 1) lua_pushliteral(L, "");
  else if (third == 2) lua_newtable(L);
  st = lua_pcall(L, third ? 3 : 2, 1, 0);
  if (st == 0) {
    snprintf(out, outn, "<no error, %lu bytes>", (unsigned long)lua_objlen(L, -1));
  } else {
    const char *e = lua_tostring(L, -1);
    snprintf(out, outn, "%s", e ? e : "?");
  }
  lua_settop(L, base);
  return st;
}

#define MiB (1024.0 * 1024.0)

int main(void) {
  lua_State *L;
  char buf[512], detail[1024];
  int st, i;
  long long u0, u1;

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
  lua_getglobal(L, "_OCLJ_NATIVE");
  if (!lua_isstring(L, -1) || strncmp(lua_tostring(L, -1), "luajit/", 7) != 0)
    fatal("no _OCLJ_NATIVE marker -- lj52shim.o is not linked into this test", NULL);
  lua_pop(L, 1);

  /* ---------------------------------------------------------------- PT1 */
  printf("\n== PT1  jnlua's opener and the string metatable ==\n");
  {
    const char *names[3] = { "pack", "packsize", "unpack" };
    int nfn = 0;
    for (i = 0; i < 3; i++) {
      getstrfn(L, names[i]);
      if (lua_type(L, -1) == LUA_TFUNCTION) nfn++;
      lua_pop(L, 1);
    }
    snprintf(detail, sizeof detail, "%d of 3 are functions", nfn);
    check("PT1", nfn == 3, "string.pack/packsize/unpack after luaL_requiref(\"string\")", detail);
    if (nfn != 3) {
      printf("\nPACK TESTS: %d checks, %d failures (string.pack missing: nothing else to test)\n",
             checks, failures);
      return 1;
    }
  }
  evalstr(L, "local b = ('<i4'):pack(-2) "
             "return (b == string.pack('<i4', -2) and '1' or '0') .. string.format('/%d/', #b) .. "
             "string.format('%02x%02x%02x%02x', b:byte(1, 4))", buf, sizeof buf);
  check("PT1m", strcmp(buf, "1/4/feffffff") == 0, "(\"<i4\"):pack(-2) through the string metatable", buf);

  /* ---------------------------------------------------------------- PT2 */
  printf("\n== PT2  Plan9k's GPT header on a sector of text: rounded, never refused ==\n");
  {
    static const char *GPT = "<c8c4I4I4xxxxI8I8I8I8c16I8I4I4I4";   /* 17_gpt.lua:12 */
    static const int I8OFF[5] = { 24, 32, 40, 48, 72 };              /* the I8 fields */
    char sector[512];
    int nres, good = 0, big = 0;
    const char *text = "Plan9k reads a GPT header from sector 1 of every drive, text or not. ";
    for (i = 0; i < 512; i++) sector[i] = text[i % (int)strlen(text)];
    getstrfn(L, "unpack");
    lua_pushstring(L, GPT);
    lua_pushlstring(L, sector, 92);                                  /* device.read(h, 92) */
    st = lua_pcall(L, 2, LUA_MULTRET, 0);
    nres = lua_gettop(L);
    if (st != 0) {
      snprintf(detail, sizeof detail, "REFUSED: %s", lua_tostring(L, -1));
    } else {
      /* results: c8 c4 I4 I4 I8 I8 I8 I8 c16 I8 I4 I4 I4 next = 14 values */
      static const int I8IDX[5] = { 5, 6, 7, 8, 10 };
      for (i = 0; i < 5; i++) {
        uint64_t u = 0;
        int64_t s;
        int k;
        double want, got;
        for (k = 7; k >= 0; k--) u = (u << 8) | (unsigned char)sector[I8OFF[i] + k];
        /* the exact two's-complement int64 5.3.6 computes, then the nearest double */
        s = (u <= (uint64_t)INT64_MAX) ? (int64_t)u : -(int64_t)(~u) - 1;
        want = (double)s;
        got = lua_tonumber(L, I8IDX[i]);
        if (got == want) good++;
        if (u > ((uint64_t)1 << 53)) big++;
      }
      snprintf(detail, sizeof detail, "%d values; %d of 5 I8 fields equal the nearest double (%d need > 53 bits); next=%g",
               nres, good, big, lua_tonumber(L, nres));
    }
    check("PT2", st == 0 && nres == 14 && good == 5 && big == 5 && lua_tonumber(L, 14) == 93.0,
          "unpack(GPT header, text sector) rounds every I8 field", detail);
    lua_settop(L, 0);
  }

  /* ---------------------------------------------------------------- PT3 */
  printf("\n== PT3  the RAM cap is charged 2x the output, no more ==\n");
  {
    double d;
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCSTOP, 0);
    getstrfn(L, "pack");
    lua_pushliteral(L, "c1048576");
    lua_pushliteral(L, "");
    u0 = lj52_mem_used(L);
    st = lua_pcall(L, 2, 1, 0);
    u1 = lj52_mem_used(L);
    d = (double)(u1 - u0) / MiB;
    snprintf(detail, sizeof detail, "status %d, result %d bytes, charged +%.4f MiB", st,
             st == 0 ? (int)lua_objlen(L, -1) : -1, d);
    check("PT3", st == 0 && lua_objlen(L, -1) == 1048576 && d >= 1.95 && d <= 2.05,
          "a 1 MiB pack with the GC stopped charges 2x (+-2.5%)", detail);
    lua_settop(L, 0);
    lua_gc(L, LUA_GCRESTART, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
  }

  /* ---------------------------------------------------------------- PT4 */
  printf("\n== PT4  past the cap: LUA_ERRMEM, and only after every argument check ==\n");
  {
    long long base = lj52_mem_used(L);
    const char *msg;
    lj52_mem_settotal(L, base + 4LL * 1024 * 1024);
    getstrfn(L, "pack");
    lua_pushliteral(L, "c16777216");
    lua_pushliteral(L, "");
    st = lua_pcall(L, 2, 1, 0);
    msg = lua_tostring(L, -1);
    snprintf(detail, sizeof detail, "cap = heap + 4 MiB; status %d (LUA_ERRMEM %d) '%s'; used %.2f MiB",
             st, LUA_ERRMEM, msg ? msg : "?", (double)lj52_mem_used(L) / MiB);
    check("PT4", st == LUA_ERRMEM && msg && strcmp(msg, "not enough memory") == 0,
          "pack('c16777216', '') under a 4 MiB margin: LUA_ERRMEM", detail);
    lua_settop(L, 0);
    /* The same 16 MiB, but arg #3 is bad: pass 1 reaches it before anything
     * is allocated, so the argument error wins over the cap. */
    getstrfn(L, "pack");
    lua_pushliteral(L, "c16777216 j");
    lua_pushliteral(L, "");
    lua_pushliteral(L, "x");
    st = lua_pcall(L, 3, 1, 0);
    msg = lua_tostring(L, -1);
    snprintf(detail, sizeof detail, "status %d (LUA_ERRRUN %d) '%s'", st, LUA_ERRRUN, msg ? msg : "?");
    check("PT4b", st == LUA_ERRRUN && msg && strncmp(msg, "bad argument #3 ", 16) == 0
                  && strstr(msg, "(number expected, got string)") != NULL,
          "pack('c16777216 j', '', 'x'), same margin: arg #3 first", detail);
    lua_settop(L, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    evalstr(L, "local b = string.pack('>I2 s1 z', 258, 'ok', 'still') "
               "local a, s, z, nx = string.unpack('>I2 s1 z', b) "
               "return a .. '/' .. s .. '/' .. z .. '/' .. nx .. '/' .. #string.pack('c1000000', '')",
            buf, sizeof buf);
    snprintf(detail, sizeof detail, "%s; used %.2f MiB of a %.2f MiB cap", buf,
             (double)lj52_mem_used(L) / MiB, (double)(base + 4LL * 1024 * 1024) / MiB);
    check("PT5", strcmp(buf, "258/ok/still/12/1000000") == 0,
          "after the refusal the state packs and unpacks (1 MB still fits)", detail);
    lj52_mem_settotal(L, 64LL * 1024 * 1024);
    lua_gc(L, LUA_GCCOLLECT, 0);
  }

  /* ---------------------------------------------------------------- PT6 */
  printf("\n== PT6  unpack's results stop at the C stack's 8000 slots, cleanly ==\n");
  {
    evalstr(L, "return tostring(select('#', string.unpack(('b'):rep(7990), ('a'):rep(7990))))",
            buf, sizeof buf);
    check("PT6a", strcmp(buf, "7991") == 0, "7990 bytes unpack into 7990 values and a position", buf);
    evalstr(L, "local ok, e = pcall(string.unpack, ('b'):rep(9000), ('a'):rep(9000)) "
               "return tostring(ok) .. '|' .. tostring(e)", buf, sizeof buf);
    check("PT6b", strstr(buf, "false|") == buf && strstr(buf, "stack overflow (too many results)") != NULL,
          "9000 values are refused with 5.3.6's text", buf);
  }

  /* ---------------------------------------------------------------- PT7 */
  printf("\n== PT7  D4: LJ_MAX_STR bytes or more, refused before any allocation ==\n");
  {
    static const char *D4TEXT = "not enough memory for buffer allocation";
    lj52_mem_settotal(L, 64LL * 1024 * 1024);     /* the cap refuses, so nothing large is allocated */
    st = packst(L, "c2147483392", 0, buf, sizeof buf);
    snprintf(detail, sizeof detail, "status %d (LUA_ERRRUN %d) '%s'", st, LUA_ERRRUN, buf);
    check("PT7a", st == LUA_ERRRUN && strcmp(buf, D4TEXT) == 0,
          "pack('c2147483392', ''): total 0x7fffff00, D4's text", detail);
    st = packst(L, "c2147483391c1", 1, buf, sizeof buf);
    snprintf(detail, sizeof detail, "status %d (LUA_ERRRUN %d) '%s'", st, LUA_ERRRUN, buf);
    check("PT7b", st == LUA_ERRRUN && strcmp(buf, D4TEXT) == 0,
          "pack('c2147483391c1', '', ''): the same total, D4's text", detail);
    st = packst(L, "c2147483391", 0, buf, sizeof buf);
    snprintf(detail, sizeof detail, "status %d (LUA_ERRMEM %d) '%s'; used %.2f MiB of a 64 MiB cap",
             st, LUA_ERRMEM, buf, (double)lj52_mem_used(L) / MiB);
    check("PT7c", st == LUA_ERRMEM && strcmp(buf, "not enough memory") == 0,
          "pack('c2147483391', ''): one byte less, refused by the cap", detail);
    st = packst(L, "c2000000000c2000000000", 2, buf, sizeof buf);
    snprintf(detail, sizeof detail, "status %d (LUA_ERRRUN %d) '%s'", st, LUA_ERRRUN, buf);
    check("PT7d", st == LUA_ERRRUN && strncmp(buf, "bad argument #3 ", 16) == 0
                  && strstr(buf, "(string expected, got table)") != NULL,
          "pack('c2000000000c2000000000', '', {}): arg #3 before D4", detail);
    lua_gc(L, LUA_GCCOLLECT, 0);
  }

  lua_close(L);
  printf("\nPACK TESTS: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
