/* ANALYSIS-ORDERED SINGLE PASS (design prototype, replaces the retry drain).
 *
 * When the drain starts the whole graph is in memory and FINAL except for the
 * nil holes where deferred special tables go. A recipe can only read what it
 * can reach from its own upvalues and environment, so the set of holes
 * reachable from a parked recipe closure -- computed on the LOAD-TIME heap,
 * before any recipe has run -- is a sound over-approximation of the holes it
 * could observe. Run the recipes in an order where every reachable hole is
 * already filled; refuse loudly if no such order exists. Every recipe body
 * runs exactly once, or the restore aborts. Nothing is retried. */

typedef struct {
  Info *I;
  lua_Integer self;     /* the recipe being analysed: its own hole is not a dep */
  int serial;           /* visited stamp for this recipe's walk */
  int deps, visited, holeby, slothole, work;   /* absolute stack indices */
  int nwork;
  long visits;
} Reach;

static void reach_dep(Reach *R, lua_Integer id)
{
  lua_State *L = R->I->L;
  if (id == R->self) return;
  lua_pushinteger(L, id);
  lua_pushboolean(L, 1);
  lua_rawset(L, R->deps);
}

/* Push a BUILT, not-yet-visited object onto the worklist. Strings, numbers,
 * C functions, userdata and every host object (permanents) are leaves: no
 * hole can sit inside anything the reader did not build. */
static void reach_push(Reach *R, const TValue *tv)
{
  lua_State *L = R->I->L;
  if (!tvisgcv(tv)) return;
  if (!(tvistab(tv) || tvisthread(tv) || (tvisfunc(tv) && isluafunc(funcV(tv)))))
    return;
  luaL_checkstack(L, 4, "eris-lj reach");
  copyTV(L, L->top, tv);
  L->top++;                                     /* obj */
  lua_pushvalue(L, -1);
  lua_rawget(L, BUILTIDX);                      /* obj id? */
  if (lua_isnil(L, -1)) { lua_pop(L, 2); return; }
  lua_pop(L, 1);
  lua_pushvalue(L, -1);
  lua_rawget(L, R->visited);                    /* obj stamp? */
  if (lua_isnumber(L, -1) && lua_tointeger(L, -1) == R->serial) {
    lua_pop(L, 2);
    return;
  }
  lua_pop(L, 1);
  lua_pushvalue(L, -1);
  lua_pushinteger(L, R->serial);
  lua_rawset(L, R->visited);
  lua_rawseti(L, R->work, ++R->nwork);          /* pops obj */
}

/* A stack slot pointer p: if it lies inside a thread that has slot holes,
 * the hole at that slot is a dependency. Pointers are computed fresh here,
 * never stored, so a stack move between calls cannot stale them. */
static void reach_slotptr(Reach *R, const TValue *p)
{
  lua_State *L = R->I->L;
  luaL_checkstack(L, 4, "eris-lj reach slot");
  lua_pushnil(L);
  while (lua_next(L, R->slothole)) {            /* thread map */
    lua_State *co = lua_tothread(L, -2);
    if (co) {
      TValue *st = tvref(co->stack);
      if (p >= st && p < mref(co->maxstack, TValue)) {
        lua_rawgeti(L, -1, (int)(p - st));      /* thread map id? */
        if (lua_isnumber(L, -1)) reach_dep(R, (lua_Integer)lua_tointeger(L, -1));
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);                              /* thread */
  }
}

static void reach_visit(Reach *R)               /* ... obj */
{
  lua_State *L = R->I->L;
  const TValue *o = L->top - 1;
  int k, n;
  if (++R->visits > ERIS_LJ_REACH_BUDGET)
    luaL_error(L, "eris-lj: '%s' recipe dependency analysis exceeded its budget "
                  "(%ld objects visited)", lua_tostring(L, SPKIDX), R->visits);
  /* holes recorded ON this object (table value/key/metatable, env, ...) */
  lua_pushvalue(L, -1);
  lua_rawget(L, R->holeby);                     /* obj list? */
  if (lua_istable(L, -1)) {
    n = (int)lua_objlen(L, -1);
    for (k = 1; k <= n; k++) {
      lua_rawgeti(L, -1, k);
      reach_dep(R, (lua_Integer)lua_tointeger(L, -1));
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  if (tvistab(o)) {
    GCtab *t = tabV(o);
    uint32_t i;
    if (tabref(t->metatable)) {
      TValue tmp;
      settabV(L, &tmp, tabref(t->metatable));
      reach_push(R, &tmp);
    }
    for (i = 0; i < t->asize; i++) reach_push(R, arrayslot(t, i));
    if (t->hmask != ~0u) {
      Node *node = noderef(t->node);
      for (i = 0; i <= t->hmask; i++) {
        /* A node whose value is nil may hold a dangling key (the ghost-node
         * hazard, L5): the key is only marked when the value is non-nil. */
        if (tvisnil(&node[i].val)) continue;
        reach_push(R, &node[i].key);
        reach_push(R, &node[i].val);
      }
    }
  } else if (tvisfunc(o)) {
    GCfunc *fn = funcV(o);
    uint32_t i;
    TValue tmp;
    for (i = 0; i < fn->l.nupvalues; i++) {
      GCupval *uv = &gcref(fn->l.uvptr[i])->uv;
      if (uv->closed) {
        lua_pushlightuserdata(L, uv);
        lua_rawget(L, R->holeby);               /* id? (D_UPV keyed by upvalue) */
        if (lua_isnumber(L, -1)) reach_dep(R, (lua_Integer)lua_tointeger(L, -1));
        lua_pop(L, 1);
        reach_push(R, uvval(uv));
      } else {
        const TValue *p = uvval(uv);
        reach_slotptr(R, p);
        reach_push(R, p);
      }
    }
    settabV(L, &tmp, tabref(fn->l.env));
    reach_push(R, &tmp);
  } else if (tvisthread(o)) {
    lua_State *co = threadV(o);
    TValue *st = tvref(co->stack);
    ptrdiff_t i, top = co->top - st;
    TValue tmp;
    lua_pushvalue(L, -1);
    lua_rawget(L, R->slothole);                 /* map? every slot hole is a dep */
    if (lua_istable(L, -1)) {
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        reach_dep(R, (lua_Integer)lua_tointeger(L, -1));
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    for (i = 1 + LJ_FR2; i < top; i++) reach_push(R, st + i);
    settabV(L, &tmp, tabref(co->env));
    reach_push(R, &tmp);
  }
}

/* deps <- ids of every hole reachable from the closure at PENDIDX[id]. */
static void reach_from(Reach *R, lua_Integer id)
{
  lua_State *L = R->I->L;
  R->self = id;
  R->serial++;
  R->nwork = 0;
  lua_rawgeti(L, PENDIDX, (int)id);             /* closure */
  reach_push(R, L->top - 1);
  lua_pop(L, 1);
  while (R->nwork > 0) {
    luaL_checkstack(L, 4, "eris-lj reach work");
    lua_rawgeti(L, R->work, R->nwork);          /* obj */
    lua_pushnil(L);
    lua_rawseti(L, R->work, R->nwork);
    R->nwork--;
    reach_visit(R);
    lua_pop(L, 1);
  }
}

/* Build HOLEBY (container -> {ids}; closed upvalue -> id) and SLOTHOLE
 * (thread -> {slot -> id}) from the flat HOLEIDX destination list. */
static void elj_index_holes(Info *I, int holeby, int slothole)
{
  lua_State *L = I->L;
  int k;
  for (k = 0; k < I->nholes; k++) {
    int base = k * 4, kind;
    lua_Integer id;
    luaL_checkstack(L, 6, "eris-lj index holes");
    lua_rawgeti(L, HOLEIDX, base + 4);
    id = (lua_Integer)lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (id == 0) continue;
    lua_rawgeti(L, HOLEIDX, base + 1);
    kind = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_rawgeti(L, HOLEIDX, base + 2);          /* container */
    if (kind == D_SLOT) {
      lua_rawgeti(L, HOLEIDX, base + 3);        /* container slot */
      lua_pushvalue(L, -2);
      lua_rawget(L, slothole);                  /* container slot map? */
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -3);
        lua_pushvalue(L, -2);
        lua_rawset(L, slothole);                /* slothole[container] = map */
      }
      lua_pushvalue(L, -2);                     /* container slot map slot */
      lua_pushinteger(L, id);
      lua_rawset(L, -3);                        /* map[slot] = id */
      lua_pop(L, 3);
    } else if (kind == D_UPV) {
      GCupval *uv;
      lua_rawgeti(L, HOLEIDX, base + 3);        /* container n */
      uv = &gcref(funcV(L->top - 2)->l.uvptr[lua_tointeger(L, -1) - 1])->uv;
      lua_pop(L, 1);
      lua_pushlightuserdata(L, uv);
      lua_pushinteger(L, id);
      lua_rawset(L, holeby);                    /* holeby[uv] = id */
      lua_pop(L, 1);
    } else {
      lua_pushvalue(L, -1);
      lua_rawget(L, holeby);                    /* container list? */
      if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -2);
        lua_pushvalue(L, -2);
        lua_rawset(L, holeby);
      }
      lua_pushinteger(L, id);
      lua_rawseti(L, -2, (int)lua_objlen(L, -2) + 1);
      lua_pop(L, 2);
    }
  }
}

static void elj_drain(Info *I)
{
  lua_State *L = I->L;
  lua_Integer id;
  int holeby, slothole, visited, work, deps, npending = 0, resolved = 0;
  Reach R;

  luaL_checkstack(L, 12, "eris-lj drain");
  lua_newtable(L); holeby = lua_gettop(L);
  lua_newtable(L); slothole = lua_gettop(L);
  lua_newtable(L); visited = lua_gettop(L);
  lua_newtable(L); work = lua_gettop(L);
  lua_newtable(L); deps = lua_gettop(L);        /* id -> set of ids */
  elj_index_holes(I, holeby, slothole);

  memset(&R, 0, sizeof(R));
  R.I = I; R.visited = visited; R.holeby = holeby; R.slothole = slothole;
  R.work = work;

  /* Phase 1: dependencies, on the load-time heap, before any recipe runs. */
  for (id = 1; id <= I->refcount; id++) {
    lua_rawgeti(L, PENDIDX, (int)id);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); continue; }
    lua_pop(L, 1);
    npending++;
    lua_newtable(L);
    R.deps = lua_gettop(L);
    reach_from(&R, id);
    lua_rawseti(L, deps, (int)id);              /* deps[id] = set (pops) */
    if (I->dtrace) {
      fprintf(stderr, "[once] id %d reaches holes:", (int)id);
      lua_rawgeti(L, deps, (int)id);
      lua_pushnil(L);
      while (lua_next(L, -2)) { fprintf(stderr, " %d", (int)lua_tointeger(L, -2)); lua_pop(L, 1); }
      lua_pop(L, 1);
      fprintf(stderr, "  (%ld visits)\n", R.visits);
    }
  }

  /* Phase 2: one pass in dependency order; lowest id first among the ready. */
  while (resolved < npending) {
    lua_Integer pick = 0, blocked_on = 0, first_blocked = 0;
    for (id = 1; id <= I->refcount && pick == 0; id++) {
      int ready = 1;
      lua_rawgeti(L, PENDIDX, (int)id);
      if (lua_isnil(L, -1)) { lua_pop(L, 1); continue; }
      lua_pop(L, 1);
      lua_rawgeti(L, deps, (int)id);
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        lua_Integer d = (lua_Integer)lua_tointeger(L, -2);
        lua_pop(L, 1);
        lua_rawgeti(L, PENDIDX, (int)d);        /* still pending -> not ready */
        if (!lua_isnil(L, -1)) {
          ready = 0;
          if (first_blocked == 0) { first_blocked = id; blocked_on = d; }
        }
        lua_pop(L, 1);
      }
      lua_pop(L, 1);                            /* deps set */
      if (ready) pick = id;
    }
    if (pick == 0)
      luaL_error(L, "eris-lj: %d deferred '%s' recipe(s) depend on each other "
                    "through shared structure (object %d reaches object %d's "
                    "unfinished record) and no order can run them all first",
                 npending - resolved, lua_tostring(L, SPKIDX),
                 (int)first_blocked, (int)blocked_on);

    lua_rawgeti(L, PENDIDX, (int)pick);
    if (lua_pcall(L, 0, 1, 0) != 0)             /* no retry, ever */
      luaL_error(L, "eris-lj: the '%s' recipe for object %d failed: %s",
                 lua_tostring(L, SPKIDX), (int)pick,
                 lua_tostring(L, -1) ? lua_tostring(L, -1) : "(non-string error)");
    if (!lua_istable(L, -1))
      luaL_error(L, "eris-lj: special-persist function returned a %s, "
                    "expected a table", luaL_typename(L, -1));
    lua_pushvalue(L, -1);
    lua_rawget(L, BUILTIDX);
    if (!lua_isnil(L, -1))
      luaL_error(L, "eris-lj: the '%s' recipe for object %d returned an object "
                    "that already exists in the graph (object %d); two "
                    "persisted objects cannot restore as one",
                 lua_tostring(L, SPKIDX), (int)pick, (int)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_pushvalue(L, -1);
    lua_rawseti(L, REFTIDX, (int)pick);         /* the id now resolves */
    lua_pushvalue(L, -1);
    lua_pushinteger(L, pick);
    lua_rawset(L, BUILTIDX);
    lua_pushnil(L);
    lua_rawseti(L, PENDIDX, (int)pick);         /* no longer pending */
    elj_apply_holes(I, pick, lua_gettop(L));
    lua_pop(L, 1);
    resolved++;
    if (I->dtrace) fprintf(stderr, "[once] ran id %d (%d/%d)\n", (int)pick, resolved, npending);
  }

  /* Every recorded destination must have been written: a hole left behind
   * is exactly the silent nil the whole design exists to prevent. */
  {
    int k, left = 0;
    for (k = 0; k < I->nholes; k++) {
      lua_rawgeti(L, HOLEIDX, k * 4 + 4);
      if (lua_tointeger(L, -1) != 0) left++;
      lua_pop(L, 1);
    }
    if (left)
      luaL_error(L, "eris-lj: %d destination(s) of deferred tables were never "
                    "back-patched", left);
  }
  lua_pop(L, 5);
}
