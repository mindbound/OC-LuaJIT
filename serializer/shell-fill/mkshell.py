import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
def once(old, new):
    global s
    n = s.count(old)
    assert n == 1, (n, old[:60])
    s = s.replace(old, new)

# 1. FILLIDX slot
once("#define UPVLIST 7\n", "#define UPVLIST 7\n/* Restoring only (SHELL-FILL judge prototype): array part = shells in\n * registration order; hash part shell -> {closure, byte offset} while the\n * shell is still UNFILLED. */\n#define FILLIDX 8\n")

# 2. u_table TABLE_SPECIAL arm
old_arm = """  if (flag == TABLE_SPECIAL) {
    /* Reserve the id before reading the closure, mirroring persist_keyed;
     * the table itself only exists once the closure has been called. */
    lua_Integer ref = newref(I);
    unpersist(I);                       /* closure */
    if (!lua_isfunction(L, -1))
      luaL_error(L, "eris-lj: special-persist record is a %s, expected a "
                    "function", luaL_typename(L, -1));
    lua_call(L, 0, 1);                  /* result */
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: special-persist function returned a %s, "
                    "expected a table", luaL_typename(L, -1));
    lua_pushvalue(L, -1);
    lua_rawseti(L, REFTIDX, (int)ref);
    return;
  }
"""
new_arm = """  if (flag == TABLE_SPECIAL) {
    /* SHELL-FILL: allocate the object's FINAL identity now, under the same
     * id the old arm reserved, and defer the recipe until the whole graph
     * exists. Nothing is ever swapped: every consumer stores this table. */
    int shell;
    lua_newtable(L);                    /* shell */
    registerobject(I);
    shell = lua_gettop(L);
    unpersist(I);                       /* shell closure */
    if (!lua_isfunction(L, -1))
      luaL_error(L, "eris-lj: special-persist record is a %s, expected a "
                    "function", luaL_typename(L, -1));
    lua_pushvalue(L, shell);            /* shell closure shell */
    lua_createtable(L, 2, 0);           /* shell closure shell rec */
    lua_pushvalue(L, -3);
    lua_rawseti(L, -2, 1);              /* rec[1] = closure */
    lua_pushinteger(L, (lua_Integer)I->pos);
    lua_rawseti(L, -2, 2);              /* rec[2] = byte offset */
    lua_rawset(L, FILLIDX);             /* FILL[shell] = rec; shell closure */
    lua_pop(L, 1);                      /* shell */
    lua_pushvalue(L, shell);
    lua_rawseti(L, FILLIDX, (int)lua_objlen(L, FILLIDX) + 1);
    return;
  }
"""
once(old_arm, new_arm)

# 3. literal arm: refuse an unfilled shell as a metatable
old_mt = """    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: metatable slot holds a %s", luaL_typename(L, -1));
    lua_setmetatable(L, -2);
  }
}
"""
new_mt = """    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: metatable slot holds a %s", luaL_typename(L, -1));
    lua_pushvalue(L, -1);
    lua_rawget(L, FILLIDX);
    if (!lua_isnil(L, -1))
      luaL_error(L, "eris-lj: a special table is the metatable of another "
                    "object; not supported during restore");
    lua_pop(L, 1);
    lua_setmetatable(L, -2);
  }
}

/* SHELL-FILL drain: after the whole graph exists, call recipe(shell) once per
 * special, descending id, each under pcall; refuse loudly on any deviation. */
static void elj_fill(Info *I)
{
  lua_State *L = I->L;
  int n = (int)lua_objlen(L, FILLIDX);
  int k;
  luaL_checkstack(L, 8, "eris-lj fill");
  for (k = n; k >= 1; k--) {
    int shell, ofs;
    lua_rawgeti(L, FILLIDX, k);         /* shell */
    shell = lua_gettop(L);
    lua_pushvalue(L, shell);
    lua_rawget(L, FILLIDX);             /* shell rec */
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: fill record %d is missing", k);
    lua_rawgeti(L, -1, 1);              /* shell rec closure */
    lua_rawgeti(L, -2, 2);              /* shell rec closure ofs */
    ofs = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_remove(L, -2);                  /* shell closure */
    lua_pushvalue(L, shell);
    lua_pushnil(L);
    lua_rawset(L, FILLIDX);             /* mark filled: FILL[shell] = nil */
    lua_getfenv(L, -1);                 /* shell closure fenv */
    lua_rawget(L, FILLIDX);
    if (!lua_isnil(L, -1))
      luaL_error(L, "eris-lj: '%s' recipe %d of %d (record at byte %d): its "
                    "environment is an unfilled special table",
                 lua_tostring(L, SPKIDX), k, n, ofs);
    lua_pop(L, 1);                      /* shell closure */
    lua_pushvalue(L, shell);            /* shell closure shell */
    if (lua_pcall(L, 1, 1, 0) != 0) {
      const char *msg = lua_tostring(L, -1);
      luaL_error(L, "eris-lj: '%s' recipe %d of %d (record at byte %d) "
                    "failed: %s", lua_tostring(L, SPKIDX), k, n, ofs,
                 msg ? msg : "(non-string error)");
    }
    if (!lua_isnil(L, -1) && !lua_rawequal(L, -1, shell))
      luaL_error(L, "eris-lj: '%s' recipe %d of %d returned a %s instead of "
                    "filling its argument (references to this object were "
                    "already resolved to the argument; a fresh table cannot "
                    "be honoured)", lua_tostring(L, SPKIDX), k, n,
                 luaL_typename(L, -1));
    lua_pop(L, 1);                      /* shell */
    if (!lua_getmetatable(L, shell))
      luaL_error(L, "eris-lj: '%s' recipe %d of %d left its object without a "
                    "metatable (an inert or legacy recipe)",
                 lua_tostring(L, SPKIDX), k, n);
    lua_pop(L, 2);                      /* mt shell */
  }
}
"""
once(old_mt, new_mt)

# 4. l_unpersist: create FILL table, drain after the trailing-bytes check
once("""  lua_newtable(L);
  lua_insert(L, UPVLIST);

  if (inlen < sizeof(MAGIC) + 2 + 4)""",
"""  lua_newtable(L);
  lua_insert(L, UPVLIST);
  lua_newtable(L);
  lua_insert(L, FILLIDX);

  if (inlen < sizeof(MAGIC) + 2 + 4)""")
once("""  unpersist(&I);                        /* ... value */
  if (I.pos != I.inlen)
    return luaL_error(L, "eris-lj: %d trailing bytes after the value",
                      (int)(I.inlen - I.pos));
  return 1;
}""",
"""  unpersist(&I);                        /* ... value */
  if (I.pos != I.inlen)
    return luaL_error(L, "eris-lj: %d trailing bytes after the value",
                      (int)(I.inlen - I.pos));
  elj_fill(&I);                         /* recipes run only now */
  return 1;
}""")
open(p, 'w', encoding='utf-8', newline='').write(s)
print("patched ok")
