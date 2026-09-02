/* shim_test.c -- differential regression test for the canonical lj52 shim.
 *
 * Compiled the way jnlua.c is compiled -- with -include lj52shim.h -- so it
 * exercises the MACROS as OC's own code sees them, not just the functions.
 * Linked against the same lj52shim.o and libluajit.a the DLL links.
 *
 * It covers exactly the properties no surviving run log from the spike covers:
 *   A  lua_compare(LUA_OPLE) against an __le-only metatable, both polarities,
 *      an __lt/__le disagreement, and which metamethod actually fires
 *   B  lua_load's chunk-mode gate, all four (mode x form) combinations, plus
 *      the +1 stack delta 5.2 promises on BOTH the accept and the reject path
 *   C  the serializer's internal bytecode route staying open (lua_loadx "b")
 *   D  bit32's unsigned/floor-modulo semantics vs LuaJIT's signed BitOp
 *   E  lua_arith / lua_len firing the right metamethods
 *   F  lua_pushcfunction identity and warm-path allocation
 *   G  the 5.2 registry layout and the _OCLJ_NATIVE fingerprint
 *
 * Build:  see run.sh next to this file.   Exit status 0 iff every case passes.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include "lj52shim.h"

static int failures = 0;
static int checks   = 0;

static void ok(int cond, const char *what, const char *detail) {
  checks++;
  if (cond) {
    printf("  PASS  %-52s %s\n", what, detail ? detail : "");
  } else {
    failures++;
    printf("  FAIL  %-52s %s\n", what, detail ? detail : "");
  }
}

static void section(const char *s) { printf("\n== %s ==\n", s); }

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static void dostr(lua_State *L, const char *src) {
  if (luaL_loadstring(L, src) != 0 || lua_pcall(L, 0, 0, 0) != 0) {
    fprintf(stderr, "FATAL: setup chunk failed: %s\n", lua_tostring(L, -1));
    exit(2);
  }
}

/* reader over a fixed buffer, handed out in one go */
typedef struct { const char *p; size_t n; int done; } BufReader;
static const char *bufread(lua_State *L, void *ud, size_t *size) {
  BufReader *b = (BufReader *)ud;
  (void)L;
  if (b->done) { *size = 0; return NULL; }
  b->done = 1;
  *size = b->n;
  return b->p;
}

/* writer for lua_dump */
typedef struct { char *p; size_t n; } Buf;
static int bufwrite(lua_State *L, const void *p, size_t sz, void *ud) {
  Buf *b = (Buf *)ud;
  (void)L;
  b->p = (char *)realloc(b->p, b->n + sz);
  memcpy(b->p + b->n, p, sz);
  b->n += sz;
  return 0;
}

/* ================================================================== */
int main(void) {
  lua_State *L = luaL_newstate();     /* == lj52_newstate() via the shim */
  const char *TEXT = "return 'HELLO-FROM-TEXT'";
  Buf bc = { NULL, 0 };
  int i;

  if (!L) { fprintf(stderr, "FATAL: luaL_newstate returned NULL\n"); return 2; }
  luaL_openlibs(L);

  /* ---------------------------------------------------------------- G */
  section("G  state shape (5.2 registry layout, JIT, fingerprint)");
  lua_getglobal(L, "_OCLJ_NATIVE");
  ok(lua_isstring(L, -1) && strncmp(lua_tostring(L, -1), "luajit/", 7) == 0,
     "_OCLJ_NATIVE fingerprint present", lua_tostring(L, -1));
  lua_pop(L, 1);
  lua_getglobal(L, "_OCLJ_JIT");
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "ok") == 0,
     "_OCLJ_JIT records a successful luaopen_jit", lua_tostring(L, -1));
  lua_pop(L, 1);
  /* The base variant clobbered this table with luaopen_jit's leftover stack
   * value (a string), which made jit.on/jit.off/jit.status unreachable. */
  lua_getglobal(L, "jit");
  ok(lua_istable(L, -1), "global `jit` is the jit TABLE, not a leftover string",
     lua_typename(L, lua_type(L, -1)));
  lua_getfield(L, -1, "status");
  ok(lua_isfunction(L, -1), "  ... and jit.status is callable", NULL);
  if (lua_isfunction(L, -1) && lua_pcall(L, 0, 1, 0) == 0) {
    ok(lua_toboolean(L, -1) == 1, "  ... and the JIT is actually ON", NULL);
  } else {
    ok(0, "  ... and the JIT is actually ON", "jit.status() failed");
  }
  lua_pop(L, 2);
  lua_rawgeti(L, LUA_REGISTRYINDEX, 1);
  ok(lua_isthread(L, -1), "registry[LUA_RIDX_MAINTHREAD] == main thread", NULL);
  lua_pop(L, 1);
  lua_rawgeti(L, LUA_REGISTRYINDEX, 2);
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  ok(lua_rawequal(L, -1, -2), "registry[LUA_RIDX_GLOBALS] == _G", NULL);
  lua_pop(L, 2);

  /* ---------------------------------------------------------------- A */
  section("A  lua_compare LUA_OPLE (the __le fix)");

  /* A1/A2: a metatable defining ONLY __le.  The 5.1 fallback
   * `!lua_lessthan(b,a)` looks up a __lt that is not there and RAISES. */
  dostr(L, "leTrue  = setmetatable({}, {__le = function(a,b) return true  end})\n"
           "leFalse = setmetatable({}, {__le = function(a,b) return false end})\n");
  lua_getglobal(L, "leTrue");
  lua_pushvalue(L, -1);
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 1,
     "__le-only metatable, __le returns true  -> true", NULL);
  lua_pop(L, 2);
  lua_getglobal(L, "leFalse");
  lua_pushvalue(L, -1);
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 0,
     "__le-only metatable, __le returns false -> false", NULL);
  lua_pop(L, 2);

  /* A3: __lt and __le disagree.  5.2 must consult __le.  The 5.1 fallback
   * consults __lt and returns the wrong boolean. */
  dostr(L, "dis = setmetatable({}, {__le = function() return true end,\n"
           "                        __lt = function() return true end})\n");
  lua_getglobal(L, "dis");
  lua_pushvalue(L, -1);
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 1,
     "__lt=true and __le=true -> true (5.1 fallback says false)", NULL);
  lua_pop(L, 2);

  /* A4: which metamethod actually fires. */
  dostr(L, "ltCalls, leCalls = 0, 0\n"
           "cnt = setmetatable({}, {\n"
           "  __le = function() leCalls = leCalls + 1 return true end,\n"
           "  __lt = function() ltCalls = ltCalls + 1 return true end})\n");
  lua_getglobal(L, "cnt");
  lua_pushvalue(L, -1);
  lua_compare(L, -2, -1, LUA_OPLE);
  lua_pop(L, 2);
  lua_getglobal(L, "leCalls");
  lua_getglobal(L, "ltCalls");
  ok(lua_tointeger(L, -2) == 1 && lua_tointeger(L, -1) == 0,
     "LUA_OPLE fires __le once and __lt never", NULL);
  lua_pop(L, 2);

  /* A5/A6: EQ and LT are unchanged. */
  lua_pushnumber(L, 1);
  lua_pushnumber(L, 2);
  ok(lua_compare(L, -2, -1, LUA_OPLT) == 1, "LUA_OPLT 1 < 2", NULL);
  ok(lua_compare(L, -2, -1, LUA_OPEQ) == 0, "LUA_OPEQ 1 == 2 is false", NULL);
  ok(lua_compare(L, -2, -1, LUA_OPLE) == 1, "LUA_OPLE 1 <= 2 on plain numbers", NULL);
  lua_pop(L, 2);

  /* ---------------------------------------------------------------- E */
  section("E  lua_arith / lua_len metamethods");
  dostr(L, "adder = setmetatable({}, {__add = function(a,b) return 'ADDED' end,\n"
           "                          __len = function(a)   return 42      end,\n"
           "                          __unm = function(a)   return 'NEG'   end})\n");
  lua_getglobal(L, "adder");
  lua_pushnumber(L, 1);
  lua_arith(L, LUA_OPADD);
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "ADDED") == 0,
     "lua_arith LUA_OPADD fires __add", NULL);
  lua_pop(L, 1);
  lua_getglobal(L, "adder");
  lua_arith(L, LUA_OPUNM);
  ok(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "NEG") == 0,
     "lua_arith LUA_OPUNM fires __unm (1 operand)", NULL);
  lua_pop(L, 1);
  lua_getglobal(L, "adder");
  lua_len(L, -1);
  ok(lua_tointeger(L, -1) == 42, "lua_len fires __len (5.2; lua_objlen does not)", NULL);
  lua_pop(L, 2);
  lua_newtable(L);
  lua_pushnumber(L, 7); lua_rawseti(L, -2, 1);
  lua_pushnumber(L, 8); lua_rawseti(L, -2, 2);
  ok(lua_rawlen(L, -1) == 2, "lua_rawlen ignores __len", NULL);
  lua_pop(L, 1);

  /* ---------------------------------------------------------------- B */
  section("B  lua_load chunk-mode gate (allowBytecode)");

  /* Produce genuine LuaJIT bytecode for the same chunk. */
  if (luaL_loadstring(L, TEXT) != 0) { fprintf(stderr, "FATAL: loadstring\n"); return 2; }
  if (lua_dump(L, bufwrite, &bc) != 0) { fprintf(stderr, "FATAL: lua_dump\n"); return 2; }
  lua_pop(L, 1);
  ok(bc.n > 0 && (unsigned char)bc.p[0] == 0x1B,
     "fixture: lua_dump produced a bytecode chunk", NULL);

  {
    struct { const char *mode; int binary; int want_ok; const char *label; } cases[] = {
      { "t",  0, 1, "mode \"t\" + text     -> ACCEPT" },
      { "t",  1, 0, "mode \"t\" + bytecode -> REJECT  (allowBytecode=false)" },
      { "b",  0, 0, "mode \"b\" + text     -> REJECT  (the direction the sniffer missed)" },
      { "b",  1, 1, "mode \"b\" + bytecode -> ACCEPT" },
      { "bt", 0, 1, "mode \"bt\" + text     -> ACCEPT" },
      { "bt", 1, 1, "mode \"bt\" + bytecode -> ACCEPT" },
      { NULL, 0, 1, "mode NULL + text      -> ACCEPT (5.2: NULL disables the check)" },
      { NULL, 1, 1, "mode NULL + bytecode  -> ACCEPT (5.2: NULL disables the check)" }
    };
    for (i = 0; i < (int)(sizeof(cases) / sizeof(cases[0])); i++) {
      BufReader r;
      int top0, status, delta;
      char detail[160];
      r.p = cases[i].binary ? bc.p : TEXT;
      r.n = cases[i].binary ? bc.n : strlen(TEXT);
      r.done = 0;
      top0 = lua_gettop(L);
      status = lua_load(L, bufread, &r, "=modetest", cases[i].mode);
      delta = lua_gettop(L) - top0;
      sprintf(detail, "status=%d delta=%+d", status, delta);
      ok((status == 0) == cases[i].want_ok, cases[i].label, detail);
      /* 5.2 leaves exactly one value on the stack either way: the compiled
       * function on success, the error message on failure.  The sniffer this
       * replaced left +2 on the reject path and leaked a slot per refused
       * chunk into the state shared with OC's kernel. */
      ok(delta == 1, "  ... stack delta is exactly +1 (5.2 contract)", detail);
      lua_settop(L, top0);
    }
  }

  /* ---------------------------------------------------------------- C */
  section("C  the serializer's internal bytecode route stays OPEN");
  {
    /* eris_lj.c calls lua_loadx(..., \"b\") directly and is compiled WITHOUT
     * the shim header, so no macro here can reach it.  Prove the underlying
     * entry point still loads and runs our own bytecode. */
    BufReader r;
    r.p = bc.p; r.n = bc.n; r.done = 0;
    ok(lua_loadx(L, bufread, &r, "=erisroute", "b") == 0,
       "lua_loadx(..., \"b\") accepts LuaJIT bytecode", NULL);
    ok(lua_pcall(L, 0, 1, 0) == 0 && lua_isstring(L, -1) &&
       strcmp(lua_tostring(L, -1), "HELLO-FROM-TEXT") == 0,
       "  ... and the loaded bytecode runs", lua_tostring(L, -1));
    lua_pop(L, 1);
  }

  /* ---------------------------------------------------------------- D */
  section("D  bit32 is 5.2's unsigned bit32, not LuaJIT's signed BitOp");
  luaL_requiref(L, LUA_BITLIBNAME, luaopen_bit32, 1);
  lua_pop(L, 1);
  {
    struct { const char *expr; const char *want; } cases[] = {
      { "bit32.bnot(0)",                "4294967295" },  /* bit.bnot(0) == -1 */
      { "bit32.band(0xFFFFFFFF, 0xF0)", "240"        },
      { "bit32.bor(0x0F, 0xF0)",        "255"        },
      { "bit32.bxor(0xFF, 0x0F)",       "240"        },
      { "bit32.lshift(1, 31)",          "2147483648" },  /* signed would be -2^31 */
      { "bit32.rshift(0x80000000, 31)", "1"          },
      { "bit32.arshift(0x80000000, 31)","4294967295" },
      { "bit32.lshift(1, 32)",          "0"          },  /* saturates, not mod 32 */
      { "bit32.rshift(1, -1)",          "2"          },  /* negative disp = other way */
      { "bit32.extract(0xF0, 4, 4)",    "15"         },
      { "bit32.replace(0, 5, 4, 4)",    "80"         },
      { "bit32.bnot(-1)",               "0"          },  /* operand mod 2^32 */
      { "bit32.band(-1.0)",             "4294967295" },
      { "bit32.band(2^32 + 7)",         "7"          },  /* wraps, does not saturate */
      { "tostring(bit32.btest(1, 3))",  "true"       }
    };
    for (i = 0; i < (int)(sizeof(cases) / sizeof(cases[0])); i++) {
      char src[128], got[64];
      sprintf(src, "return tostring(%s)", cases[i].expr);
      if (luaL_loadstring(L, src) != 0 || lua_pcall(L, 0, 1, 0) != 0) {
        ok(0, cases[i].expr, lua_tostring(L, -1));
      } else {
        strncpy(got, lua_tostring(L, -1) ? lua_tostring(L, -1) : "?", 63);
        got[63] = 0;
        ok(strcmp(got, cases[i].want) == 0, cases[i].expr, got);
      }
      lua_pop(L, 1);
    }
    /* 5.2's exact field-error messages. */
    ok(luaL_loadstring(L, "return bit32.extract(0, -1)") == 0 &&
       lua_pcall(L, 0, 1, 0) != 0 &&
       strstr(lua_tostring(L, -1), "field cannot be negative") != NULL,
       "extract(-1) raises 5.2's 'field cannot be negative'", lua_tostring(L, -1));
    lua_pop(L, 1);
    ok(luaL_loadstring(L, "return bit32.extract(0, 30, 8)") == 0 &&
       lua_pcall(L, 0, 1, 0) != 0 &&
       strstr(lua_tostring(L, -1), "trying to access non-existent bits") != NULL,
       "extract(30,8) raises 'trying to access non-existent bits'", lua_tostring(L, -1));
    lua_pop(L, 1);
  }

  /* ---------------------------------------------------------------- F */
  section("F  lua_pushcfunction memo (5.2 light-C-function identity)");
  {
    int top0 = lua_gettop(L);
    lua_pushcfunction(L, luaopen_bit32);
    lua_pushcfunction(L, luaopen_bit32);
    ok(lua_rawequal(L, -1, -2),
       "pushing the same C function twice yields EQUAL values", NULL);
    lua_pushcfunction(L, luaopen_coroutine);
    ok(!lua_rawequal(L, -1, -2),
       "pushing a DIFFERENT C function yields a different value", NULL);
    lua_settop(L, top0);

    /* Warm path must not allocate: push the same function many times and
     * watch the GC total.  (Approximate but sufficient -- an allocating push
     * moves the counter by kilobytes over 20000 iterations.) */
    lua_gc(L, LUA_GCCOLLECT, 0);
    {
      int before = lua_gc(L, LUA_GCCOUNT, 0) * 1024 + lua_gc(L, LUA_GCCOUNTB, 0);
      int after, grew;
      for (i = 0; i < 20000; i++) { lua_pushcfunction(L, luaopen_bit32); lua_pop(L, 1); }
      after = lua_gc(L, LUA_GCCOUNT, 0) * 1024 + lua_gc(L, LUA_GCCOUNTB, 0);
      grew = after - before;
      { char d[64]; sprintf(d, "heap grew %d bytes over 20000 pushes", grew);
        ok(grew < 4096, "warm lua_pushcfunction allocates nothing", d); }
    }
    lua_settop(L, top0);
  }

  /* ---------------------------------------------------------------- */
  printf("\n%d checks, %d failures\n", checks, failures);
  free(bc.p);
  lua_close(L);
  printf(failures == 0 ? "SHIM TESTS: PASS\n" : "SHIM TESTS: FAIL\n");
  return failures == 0 ? 0 : 1;
}
