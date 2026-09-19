# Shell-fill: the persistence protocol for `__persist` specials

*Implementation specification. Status: **COMPLETE, 2026-09-17** — all steps done and
verified in the harness and in-game. **Natives must be rebuilt additive
on both platforms after step 4 — the serializer hash moved; `verifyModAssets`
refuses the jar until they are.** Written so that a fresh session can execute it
without the conversation that produced it. The reasoning behind the design is
in [research/persistence-clean-slate.md](research/persistence-clean-slate.md);
this document is the what and the how.*

## 1. The defect this replaces

A table whose metatable carries a `__persist` field is persisted as a *recipe*:
a closure that, called at load time, produces the reconstructed table. Eris —
and Pluto before it, and our fork until now — calls that closure the instant
its record is read (`u_table`, TABLE_SPECIAL arm), i.e. partway through
rebuilding the graph. Anything the recipe reaches that has not been restored
yet reads as nil.

In-game symptom, first in-game persistence test, 2026-09-16:

    machine:1162: attempt to call upvalue 'wrapSingleUserdata' (a nil value)

Three demonstrated ways the graph is incomplete at that moment: thread slots
are written in ascending order (a closure over a higher slot sees nil); literal
tables are pre-registered and built incrementally (a recipe nested in one sees
a truncated container, no coroutine involved); after a thread's span the guard
list is popped. The wire orders only dependencies whose ids appear *inside* the
recipe's record; a dependency reached at load time through shared structure —
the sandbox, a global, an open upvalue — has no ordering on the wire at all.

## 2. The protocol

Reconstruction splits into two phases that need nothing from each other.

**CREATE.** When the reader meets a TABLE_SPECIAL record it does
`lua_newtable` and registers that empty table under the record's reference id
**as the object's final identity**. Every consumer that later meets a reference
to this id — thread slot, literal-table value, upvalue, table key, metatable
slot — stores this table exactly as it would store a literal. Nothing is ever
swapped afterwards. This is *not* a placeholder: the table the recipe fills is
the table the graph already points at.

**FILL.** After `unpersist` has returned and the trailing-bytes check has
passed — so a truncated or crafted blob is refused before any user code runs —
the reader calls each recipe **once**, as `recipe(shell)`, and the recipe
populates the shell in place.

### 2.1 The recipe contract (load side)

A recipe is `function(shell) ... end`. It must:

1. **Fill its argument in place** — `rawset`/assign fields, `setmetatable(shell,
   mt)`, publish it into other structures. **Return nil or the shell.**
   Returning any other value is refused: references to the object were already
   resolved to the argument, so a fresh table cannot be honoured.
2. **Leave the shell with a metatable.** A shell without one after fill is
   refused as inert or legacy.
3. **Read only immediate data captured in the closure, and the *identities* of
   other objects.** Reading another special's *contents* is now safe when the
   walker (§3.6) can see the path — the reader fills in dependency order — but
   a path the walker cannot model (e.g. through `debug.*`) is still the recipe's
   own responsibility.
4. Its environment may be another special: the walker treats the env as an
   edge, so that special is filled first. (The refusal from step 1 is kept as a
   belt-and-braces assert; it can no longer fire.)
5. Not call `eris.persist` on the graph from inside a fill: unfilled shells
   would serialize as empty literal tables, silently.

A recipe of the upstream shape — `function() return {...} end`, ignoring its
argument — is refused at load with a message naming the recipe's ordinal and
byte offset. There is no compatibility path. That is free here: `persistKey`
is absent from the sandbox, so the only recipe authors are the two sites in
`machine.lua` that we patch.

### 2.2 The write side

**Unchanged.** `mt[spkey](obj)` is called at persist time with the object and
must return a closure; that closure is what is persisted (`p_table`,
`persist_keyed`). The wire format is byte-identical. Only `ERIS_LJ_FORMAT`
bumps (2 → 3), so a blob written under the old protocol is refused by the
format/fingerprint check before its old-shape recipes could be reached.

## 3. Serializer changes (`serializer/eris_lj.c`)

The verified prototype diff is preserved at
`serializer/shell-fill/eris_lj_SHELL.diff` (94 changed lines) and the anchored
patcher that produced it at `serializer/shell-fill/mkshell.py`. Line numbers
below are against the file as of 2026-09-17; the patcher asserts each anchor
matches exactly once, so drift fails loudly.

### 3.1 One new fixed stack slot

After `#define UPVLIST 7`:

    #define FILLIDX 8

One table, used two ways: **array part** `FILL[k] = shell` in registration
order; **hash part** `FILL[shell] = {closure, byte_offset}` while the shell is
still unfilled, so membership answers "is this table an unfilled shell?".
Created in `l_unpersist` next to the UPVLIST setup:

    lua_newtable(L);
    lua_insert(L, FILLIDX);

(Bump the `luaL_checkstack` in `l_unpersist` accordingly.)

### 3.2 The TABLE_SPECIAL arm

Replaces the reserve-then-call body. Stack comments as in the prototype.

    if (flag == TABLE_SPECIAL) {
      int shell;
      lua_newtable(L);                    /* shell */
      registerobject(I);                  /* REFTIDX[ref] = shell, same id newref would have reserved */
      shell = lua_gettop(L);
      unpersist(I);                       /* shell closure */
      if (!lua_isfunction(L, -1))
        luaL_error(L, "eris-lj: special-persist record is a %s, expected a function", luaL_typename(L, -1));
      lua_pushvalue(L, shell);            /* shell closure shell */
      lua_createtable(L, 2, 0);           /* shell closure shell rec */
      lua_pushvalue(L, -3); lua_rawseti(L, -2, 1);            /* rec[1] = closure */
      lua_pushinteger(L, (lua_Integer)I->pos); lua_rawseti(L, -2, 2);  /* rec[2] = byte offset */
      lua_rawset(L, FILLIDX);             /* FILL[shell] = rec;  shell closure */
      lua_pop(L, 1);                      /* shell */
      lua_pushvalue(L, shell);
      lua_rawseti(L, FILLIDX, (int)lua_objlen(L, FILLIDX) + 1);
      return;                             /* shell stays on the stack as the value */
    }

Deleted from this site: the `lua_call(L, 0, 1)` and the "returned a %s,
expected a table" check. The `RThread`/`elj_live_top` machinery, the ascending
slot cursor and the guard-list pop are all now irrelevant to specials: no Lua
runs until they are finished.

### 3.3 Refusal: a shell as somebody's metatable

In the literal arm's metatable slot, before `lua_setmetatable`:

    lua_pushvalue(L, -1); lua_rawget(L, FILLIDX);
    if (!lua_isnil(L, -1))
      luaL_error(L, "eris-lj: a special table is the metatable of another object; not supported during restore");
    lua_pop(L, 1);

Rationale: LuaJIT's negative-metamethod cache (`GCtab.nomm`) would be consulted
on the empty shell. Source says the cache *is* invalidated when a key is later
added (`lj_tab_newkey`: `t->nomm = 0`), so this refusal can be relaxed after a
measurement. OC has no such shape (only the registry and the proxies are
special-typed, and neither is anything's metatable), so refusing costs nothing.

### 3.4 The fill loop

`static void elj_fill(Info *I)`, called in `l_unpersist` **immediately after**
the trailing-bytes check and before `return 1`. Since step 4 the order is
computed by the walker (§3.6); the per-recipe body below is `elj_fill_one`
and is unchanged. For each shell, in dependency order:

1. `shell = FILL[k]`; `rec = FILL[shell]`; error "fill record %d is missing" if
   absent.
2. `FILL[shell] = nil` — mark filled. This is a nil-out of a hash *value*, not
   a key removal followed by reinsertion, and nothing later walks FILL by key,
   so no L5 ghost node is ever read.
3. `lua_getfenv(closure)`; if it is an unfilled shell → error
   *"'%s' recipe %d of %d (record at byte %d): its environment is an unfilled
   special table"*.
4. `lua_pcall(closure, shell)`; on error → error *"'%s' recipe %d of %d (record
   at byte %d) failed: %s"*.
5. If the return value is neither nil nor `rawequal` to the shell → error
   *"'%s' recipe %d of %d returned a %s instead of filling its argument
   (references to this object were already resolved to the argument; a fresh
   table cannot be honoured)"*.
6. If the shell has no metatable → error *"'%s' recipe %d of %d left its
   object without a metatable (an inert or legacy recipe)"*.

Tests assert on these strings; keep them stable.

### 3.6 The walker (step 4): fill in dependency order

A recipe can only read what it can reach from its own upvalues and environment.
So, **before any recipe runs**, for each unfilled shell `k` the reader walks the
object graph from its closure — upvalues (open and closed), env, table array
and hash parts, metatables, thread slots and envs — and records every *other*
unfilled shell it reaches as a dependency. Leaves: strings, numbers, C
functions, userdata, cdata, and every **permanent** (`PERMSET`, the inverse of
`UPERMS`, built once per fill). Hash nodes whose value is nil are skipped (the
L5 ghost-key rule). The walk is a worklist with a per-recipe visited stamp —
linear, no C recursion — bounded by `ERIS_LJ_REACH_BUDGET` (10⁶ visits per
restore; exceeding it is a named refusal).

Phase 2 repeatedly fills a shell whose dependencies are all filled, taking the
**highest ordinal among the ready** for determinism. If none is ready while
some remain, it refuses, naming both ordinals and the byte offset. Nothing is
retried.

GC/stack discipline, preserved from D3 and reviewed line by line: every object
is copied to a C local before the first API call; the raw `GCtab*`/`GCfunc*`/
`lua_State*` is read from the anchored stack value once, before the first push
in its branch; no walk call site can trigger a GC step. Measured on the verbatim
kernel block (`machine.lua:709-716` + `:1077-1260`): **20 visits per proxy,
linear in the number of proxies.**

The walker is conservative: it cannot tell identity use from content use, so
mutual *identity* reach (A stores B, B stores A) is refused too. That is the
safe side; `tests/shell-order.lua` case C2 documents the cost.

`ELJ_FILL_TRACE=1` prints each recipe's dependencies and the fill order to
stderr; one `getenv` per fill, nothing otherwise.

### 3.5 Format bump

`serializer/eris_lj.h`: `ERIS_LJ_FORMAT` 2 → 3. The blob fingerprint already
covers the serializer sources (`ERIS_LJ_SERHASH`), so this is belt and braces.

## 4. Kernel changes (`native/kernel/patch-machine-lua.lua`)

Four anchored sites, added as sites 6–9 after the two `_ENV` sites. Each must
match exactly once; `build-kernel.sh` gains a by-name assertion for
`wrapUserdataInto`. Line numbers are in the patched kernel
(`build/native/kernel/machine.lua`).

**Site 6 — the declaration line (`:1075`).**

    local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta

→

    local wrapUserdata, wrapSingleUserdata, unwrapUserdata, wrappedUserdataMeta, wrapUserdataInto

`wrapUserdataInto` becomes an open upvalue of the kernel chunk frame exactly
like `wrapSingleUserdata`; under shell-fill every thread slot is written before
any fill runs, so it is live when a proxy's recipe needs it.

**Site 7 — the registry recipe (`:1083-1088`).**

    return function()
      -- When using special persistence we have to manually reassign the
      -- metatable of the persisted value.
      return setmetatable({}, wrappedUserdataMeta)
    end

→

    return function(self)
      -- SHELL-FILL: the serializer hands us our own final table. Give it its
      -- metatable in place; each proxy's fill repopulates the contents.
      setmetatable(self, wrappedUserdataMeta)
    end

**Site 8 — the proxy recipe (`:1161-1163`).**

    return function()
      return wrapSingleUserdata(userdata.load(className, nbt))
    end

→

    return function(proxy)
      wrapUserdataInto(proxy, userdata.load(className, nbt))
    end

**Site 9 — the helper**, inserted immediately before `function wrapUserdata(values)`:

    -- SHELL-FILL: fill an EXISTING table as a userdata proxy. Fields are
    -- written before setmetatable because userdataWrapper.__newindex routes
    -- writes to udinvoke. The reuse scan in wrapSingleUserdata is not needed
    -- on the restore path: persist-time dedup by the reftable already
    -- collapsed every reference to one record, and a restored Value is a
    -- fresh Java object that can never compare equal to another.
    function wrapUserdataInto(proxy, data)
      proxy.type = "userdata"
      local methods = spcall(userdata.methods, data)
      for method in pairs(methods) do
        proxy[method] = setmetatable({name=method, proxy=proxy}, userdataCallback)
      end
      wrappedUserdata[proxy] = data
      return setmetatable(proxy, userdataWrapper)
    end

`wrappedUserdata[proxy] = data` writes into the registry *shell*, which exists
from the moment its record was read, whether or not its own fill (site 7) has
run yet. If it has not, the key is strong until the `__mode="k"` metatable
lands — a one-cycle delay, not a leak.

The kernel banner and `build-kernel.sh`'s postflight (`_ENV sites=2`) gain a
`wrapUserdataInto` assertion and the site count becomes 9 / three changes.

## 5. Tests

### 5.0 `serializer/tests/shell-order.lua` — the walker's discriminators (step 4)

Eight cases. D1 (closed upvalue), D1n (nested KIND-1 capture, which descending
post-order gets wrong), D2 (open upvalue, the OC shape): recipe A reads B's
contents tolerating nil, container shaped so A has the higher ordinal. **On the
step-3 binary all three come back `ok=true, A.y=nil` — a silent wrong
restore.** With the walker: `A.y=42, order=B A`. C1 (content cycle) and C2
(identity cycle) are refused naming both ordinals. P1: a permanent is a leaf.
B1: a 2000-table chain fills within budget. Negative control: delete the
open-upvalue edge (`if (uv->closed) reach_push(...)`) and D2 alone goes silent
again; delete the env edge and C1/C2/B1 change instead. Each edge is shown to
be load-bearing for exactly the cases its medium predicts.
`shell-fill/walker/order.lua` is the implementer's earlier discriminator, kept
as an artifact; `tests/shell-order.lua` is canonical.

### 5.1 `serializer/tests/shell.lua` — the test that must fail first (LANDED)

Six cases. Against the shipping binary (md5 `16e4f73c`) on 2026-09-17:

    case 1: OC chain on the shell protocol
      FAIL unpersist -- attempt to call upvalue 'wrapInto' (a nil value)
    case 2: legacy recipe (returns a fresh table) is refused    FAIL (accepted today)
    case 3: inert recipe is refused                              FAIL (old message)
    case 4: a special as somebody's metatable is refused         FAIL (generic error)
    case 5: a raising recipe is loud and located                 FAIL (bare "boom")
    case 6: two references, one shell; special nested in a literal container (L2b)   FAIL
    FAILS: 6

Against the prototype `SHELL.exe` (md5 `83763275`): `FAILS: 0`.

Case 1 is `scratchpad/skeptic/poc2.lua` ported to the shell protocol: a
coroutine whose chunk declares, in ascending slot order, a holder containing a
special proxy whose recipe reaches `wrapInto` through an **open upvalue
declared in a higher slot**, then the registry metatable, then `wrapInto`, then
the registry (itself a special). It asserts `registry[proxy] == "data:one"`,
`getmetatable(proxy) == wrapper`, `holder[1] == proxy` (same object), and
load-count == 1 — the last being the control against the retry design's
double `userdata.load`.

Cases 2–5 each prove one refusal is live by asserting its message. Case 6 is
failure mode L2(b): a special nested in a literal container, referenced twice.

`serializer/shell-fill/shell_stress.lua` (9 cases) is the stress companion.

### 5.2 Existing suites

`tests/m2.lua:189-228` (four spkey cases) and `tests/contract.lua`'s one
special-persistence case use the **legacy recipe shape**. After step 1 they go
red at exactly those cases with "instead of filling its argument" — **that red
is the proof the refusal is live in the real suite** and must be observed
before they are rewritten to the shell form (`function(s) setmetatable(s, mt);
... end`). M1 (82), M3 (75) and the for-in suite (19 cases) must not move.

### 5.3 The in-game gate (`test/native/OcljSmoke.scala`)

`f1b-blob-carries-userdata` PASS (the blob contains `HandleValue`) and
`f7-restored-userdata-proxy-live` PASS with its sample sequence number
advanced past the pre-save value. Plus the **negative control**: the new native
with the *unpatched-recipe* kernel must come back Stopped with "instead of
filling its argument" in the log — proving both that the refusal fires in the
real host and that the kernel patch is load-bearing.

### 5.4 Grafts (steps after the core lands)

- **From D3 — the reachability walker** as the fill-order oracle: compute which
  unfilled shells each recipe can reach over built objects, fill in dependency
  order, refuse mutual reach naming both ordinals. Ships with its own negative
  control (delete the open-upvalue edge; the discriminator must go silent
  again). Closes silent mode 1 in §6. Source, if still present:
  `serializer/shell-fill/walker/`.
- **From D4 — the rig** as `serializer/tests/userdata.lua`, ported to the fill
  protocol: `RIG_MODE=orig` stays as the negative control that reproduces the
  in-game error text on the old binary; `RIG_MODE=shell` mirrors the patched
  kernel at `machine.lua`'s slot order including the index-2 sync closure.
  Plus the `udinvoke` nil-guard naming a Value-less proxy.

## 6. Known limits — silent modes, stated so they are not rediscovered

1. ~~Content dependency between specials.~~ **Closed in step 4 by the walker
   (§3.6).** What remains: a dependency reached through an edge the walker
   does not model (`debug.getupvalue`, `debug.getlocal`, a C function's
   captured state). `tests/shell-order.lua` D1/D1n/D2 are the discriminators:
   `ok=true, A.y=nil` on the step-3 binary, `A.y=42` with the walker, silent
   again with the upvalue edge deleted.
2. A recipe that sets a metatable but fills the wrong fields (a future kernel
   edit forgetting `proxy.type = "userdata"`). Contract; `f7`'s live-proxy
   probe is the mitigation.
3. ~~The `_stack` blob is a second kernel universe.~~ **Closed 2026-09-17**: the
   Architecture subclasses persist both roots in one reference space (roadmap
   entry). The dispose caution stands on its own: never dispose a duplicate
   `HandleValue` — `dispose` is `fs.close`, which closes the file the surviving
   proxy still holds.
4. Weak-key timing on the registry (§4, site 9): one GC cycle, not a leak.
5. `u_permanent`'s `lua_gettable` on uperms honours `__index`; OC's uperms is a
   plain table. Flagged, left as is.

**Riskiest assumption:** that OC's proxy reconstruction needs only the
registry's *identity* and never its contents, i.e. that dropping the reuse scan
on the restore path loses nothing. If a Value class's `load()` ever returned a
cached instance, two proxies would persist for one Value where stock's scan
would have merged them, and `h1 == h2` would silently differ from stock;
`unwrapUserdata` would still be correct for both.

## 7. Build discipline

- **The jar ships the ADDITIVE native, and `build-native.sh` does not build it by
  default.** `OCLJ_VARIANT=additive sh native/build-native.sh` (and the WSL wrapper
  for Linux) is what refreshes `dist/`. `verifyModAssets` now refuses a stale one.
- `cd serializer && rm -f erislj_test.exe && make CC=gcc` — **always remove the
  exe first.** `make` will not rebuild if the `.c` and `.exe` land in the same
  second; this produced a "fixed" measurement that was actually the control.
- Keep control and variant binaries under **distinct filenames** and record
  the md5 of every binary a number is attributed to.
- Never rebuild `erislj_test.exe` while `tests/run-forin.sh` is running: it
  uses one binary for save, relay and load, and a swap underneath it produces a
  fingerprint mismatch that looks like a regression.
- The for-in suite writes `forin.blob`/`forin.keys` into the cwd; both are
  gitignored.

## 8. Build order and acceptance

| step | work | accepted when |
|---|---|---|
| **0** ✓ | land `tests/shell.lua` | 6/6 red on the shipping binary, 0/6 on `SHELL.exe` — **done 2026-09-17** |
| **1** ✓ | apply §3 to `eris_lj.c` (start from `mkshell.py`), bump format | `shell.lua` 0/6; M1 82, M3 75, for-in 19 exact; **m2 and contract red only at their legacy recipes** — **done 2026-09-17**, binary `9c64817a`, m2 aborted at :200 and contract failed its one special case, both with "instead of filling its argument" |
| **2** ✓ | rewrite m2's four spkey cases and contract's one to the shell form | all suites green — **done 2026-09-17**: shell 0/6, stress 0/9, M1 82, M2 **56** (one inert-recipe case added), M3 75, contract all-pass, for-in 19 exact; a format-2 blob is refused with `format version mismatch (expected 3)` |
| **3** ✓ | apply §4 to the kernel patcher; by-name assertion; rebuild kernel and native with distinct binaries and md5s | `build-kernel.sh` postflight names `wrapUserdataInto`; `wd_test` 32/0 — **done 2026-09-17**: 9 sites, kernel 48608 bytes with sites at `:1077/:1089/:1164/:1215` and zero legacy shapes; postflight proven to fail (site 8 neutered → exit 1 naming site 8); native serializer hash `25471fb0`; `wd_test` 32/0. **Then the jar shipped the wrong DLL** — `build-native.sh` defaults to the dropin variant, so `dist/` still held the 09-16 additive. Both platforms rebuilt with `OCLJ_VARIANT=additive`: Windows `a3b64511`, Linux `d3768017` (WSL). `verifyModAssets` now refuses a native whose bytes lack the current serializer hash (proven: stale DLL → BUILD FAILED naming it). Jar `ocluajit-0280593-…-dirty.jar` verified: kernel 48608 + `wrapUserdataInto`, DLL `a3b64511`, so `d3768017`, hash embedded |
| **4** ✓ | walker graft (§3.6) with its negative control | new refusal shown to fire; suites green — **done 2026-09-17**: `tests/shell-order.lua` 0/8 on the walker build, 6 red on the step-3 control (D1/D1n/D2 silent-wrong, C1 silently succeeds), D2 alone silent under the open-upvalue negative control; 20 visits/proxy on the verbatim kernel block; all existing suites green; C review: no raw-pointer use after a stack-growing call, no ghost-node read, no C recursion. Three minor fixes applied after review: deterministic blocked-on ordinal (proven 5/5), honest refusal count, env case documented as ordered. The blocked-on fix consumed the `lua_next` key before `continue` — `invalid key to 'next'` on all six walker cases, caught by `shell-order` on the first run and fixed. Final binary `1a9e8e17`, serializer hash `c945e096` |
| **5a** ✓ | harness gate (§5.3) | `f1b` PASS, `f7` PASS with seq advanced; negative control comes back Stopped with the refusal in the log — **done 2026-09-17** on dropin `abc9e41d` (hash `c945e096`): `f1b` PASS (blob 161909 bytes carries `HandleValue`), **`f7` PASS `before=…/8/71 after=…/8/86`** (a live post-restore sample, not a repaint), 38 checks / 0 failures. Negative control (stock kernel = OC's unpatched recipes, same serializer): `'__persist78b9…' recipe 2 of 2 returned a table instead of filling its argument` in ocelot-brain's log, machine dead, `f7` FAIL STALE 25→25 — the refusal fires in a real host and the kernel patch is load-bearing |
| **5b** ✓ | in-game gate | the same shape in Minecraft: `lua` open with an explicit `io.open` handle, save-and-quit, reload; REPL resumes, marker survives, `f:read` continues at the saved position — **done 2026-09-17** on OC 1.12.61-GTNH with jar `cefe308` (dll `49ead6cc`, so `6659e5bb`): REPL resumed at `lua>`, `persist_marker` = `shell-fill-1`, **`f:read(20)` returned bytes 21–40 of `bench2.lua`** (`"local computer = req"` before, `"uire(\"computer\")\nloc"` after — the host-side file position survived), `f:close()` clean, and `fml-client-latest.log` carries zero `eris-lj` lines and no state-load error |
| **—** ✓ | `_stack` universe fix (§6.3) | scheduled separately, before any dispose work — **done 2026-09-17**, in the Architecture subclasses (no serializer change): both roots in one reference space; harness `stk-1..4` 42/0 on, 42/3 off; see roadmap |

## 9. File inventory

| path | what |
|---|---|
| `docs/shell-fill.md` | this specification |
| `docs/research/persistence-clean-slate.md` | why this design; requirements; prior art; the four designs and judgments |
| `serializer/shell-fill/eris_lj_SHELL.diff` | the verified prototype as a diff against `eris_lj.c` (94 lines) |
| `serializer/shell-fill/mkshell.py` | the anchored patcher that produced it — apply to a copy of `eris_lj.c` |
| `serializer/shell-fill/shell.lua`, `shell_stress.lua` | the prototype's tests (6 + 9 cases) |
| `serializer/tests/shell.lua` | the landed failing-first test (= `shell-fill/shell.lua`) |
| `native/kernel/patch-machine-lua.lua` | receives sites 6–9 (§4) |
| `native/kernel/build-kernel.sh` | receives the `wrapUserdataInto` assertion |
| `test/native/OcljSmoke.scala` | `f1b`/`f7`, the in-game gate |
