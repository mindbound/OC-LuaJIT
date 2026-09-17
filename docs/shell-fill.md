# Shell-fill: the persistence protocol for `__persist` specials

*Implementation specification. Status: steps 0–3 done (serializer converted,
kernel patched, both natives rebuilt additive — DLL `a3b64511`, so `d3768017` — and
the jar build now refuses a native from a different serializer), steps 4–5 pending. Written so that a fresh session can execute it
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
   other objects.** Do not read another special's *contents*: fill order is
   descending reference id, which is a hint, not a guarantee (§6).
4. Not have an unfilled special as its environment — refused.
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
the trailing-bytes check and before `return 1`. For `k = #FILL down to 1`:

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

1. **Content dependency between specials.** Recipe A reads shell B's *fields*
   and tolerates nil → A completes wrong, no error. Descending id order handles
   the nested KIND-1 capture only. OC: impossible (the registry is written
   into, never read; a proxy reads only `className`/`nbt`). Closed by the
   walker graft; until then, an OC-kernel invariant.
2. A recipe that sets a metatable but fills the wrong fields (a future kernel
   edit forgetting `proxy.type = "userdata"`). Contract; `f7`'s live-proxy
   probe is the mitigation.
3. **The `_stack` blob is a second kernel universe** (pre-existing, every
   design): the sync-call closure at `machine.lua:1116-1122` captures
   `args`/`target` as open upvalues of `invoke`'s frame, so `persist(2)` pulls
   the whole kernel thread — measured stack blob == kernel blob and two extra
   `userdata.load` per restore whenever a save lands mid-sync-call (routine
   under `cat`; `FileSystem.read` yields a SynchronizedCall on the 16th read).
   **Own fix, scheduled before any dispose mechanism.** And: never dispose a
   duplicate `HandleValue` — `dispose` is `fs.close`, which closes the file the
   surviving proxy still holds. Drop duplicates, never dispose them.
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
| 4 | walker graft (§5.4) with its negative control | new refusal shown to fire; suites green |
| 5 | in-game gate (§5.3) | `f1b` PASS, `f7` PASS with seq advanced; negative control comes back Stopped with the refusal in the log |
| — | `_stack` universe fix (§6.3) | scheduled separately, before any dispose work |

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
