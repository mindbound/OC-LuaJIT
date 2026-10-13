# Value disposal: jnlua.Object's `__gc`, wrapped and counted per object, disposes dropped Values on LuaJIT (2026-10-13)

**A host Value whose proxy the kernel drops is disposed again on the LuaJIT architecture. The
shim replaces one field, the `__gc` of jnlua's shared Java-object metatable, with a wrapper that
reports each finalized Value userdata to the generated `LuaStateLuaJIT`; Java counts every
Value's live userdata by identity and, when the last one is finalized, hands the object to a
disposer that runs OC's own dispose binding's body; `LuaJITArchitecture.save` runs a second
full collect so that a Value dead at a save is disposed by it.** On HEAD nothing was ever
disposed: 15 dropped file handles stayed owned and a fresh `open` was refused
`too_many_open_handles`. On this build the owners fall 16 → 1 → 0 and the open succeeds, on a
live machine and on a restored one, and a save disposes the 4 handles dropped just before it.
Implemented in the working tree on aa12418, uncommitted, and verified in a JVM on Windows only:
nothing here has run in the game, and no JVM has loaded the Linux .so.

- **What was broken.** LuaJIT finalizes no table, so OC's only route to `Value.dispose` -- the
  `__gc` of the TABLE proxy in machine.lua's `userdataWrapper` -- never ran: on the LuaJIT
  architecture nothing was disposed, ever. The new milestones show it on HEAD: 16 handles held
  on a dedicated disk, 15 dropped, the owners stay 16 and a fresh open is refused (gc-1 live,
  gc-2 after a restore); at the save boundary (gc-3) owners 4 stay 4.
- **The facts that shaped the fix** (`design/design.md` F1-F11 in the archive, each verified
  in source):
  - **F1** jnlua recognises a Java object only by `rawequal(metatable, registry["jnlua.Object"])`,
    so the roadmap row's Value-specific metatable would break `toJavaObjectRaw`. Replacing a
    FIELD of the shared table keeps recognition.
  - **F3** every push mints a NEW userdata and global ref; the kernel merges a re-pushed Value
    onto its EXISTING proxy through jnlua's `__eq` (`v == data` in `wrapSingleUserdata`), and the
    new userdata is orphaned and dies while the Value lives. Disposing per userdata would
    dispose live Values: the count is per object. Stock therefore does not dispose a re-pushed
    Value while its proxy lives, so the row's push-site interning answered a defect that does
    not exist.
  - **F5** stock OC does not dispose at `lua_close`, so neither does this.
  - **F6** on the pinned LuaJIT a weak-KEY table is not an ephemeron: the raw userdata is
    finalized one full cycle AFTER its proxy dies. Disposal lands one cycle later than stock;
    the save's second collect restores "dead at the save is disposed".
  - **F10** OC's two-call save (the dropin; the harness with `OCLJ_PERSIST_BUNDLE=off`) mints a
    second `HandleValue`, with the same handle id, for every proxy its second blob reaches
    (every proxy, when the save lands mid-sync-call); disposing that copy would close the live
    file. Disposal is never active there.
- **The mechanism.** C: THE VALUE FINALIZER in `native/lj52shim.c` -- one `rawset` of the
  `__gc` field, a wrapper that filters by the Value class, upcalls Java on a weak ref of the
  state and ALWAYS chains to jnlua's original `gcjavaobject`, no JNI at all during close. Java
  (generated): `ocljSetValueDisposer`, an identity count taken BEFORE the native push,
  dispose at zero, a check that skips a dispose where the kernel could have merged an equal
  live object. The architecture: install right after `applyForinMode()`, OC's own dispose body
  as the disposer, start anyway on any install failure; the second `COLLECT` in `save()`.
- **The tests.** `vgc_test.c`, 47 checks against a strict fake JNIEnv, no JVM; the negative
  control's section 7, ten sabotages, each failing exactly its predicted set; the harness's
  gc-0..3 and vd-1..9: +13 checks on the additive arms, +3 on the dropin and stock.
- **The results.** On HEAD's natives and class the new harness fails exactly its 13 new checks
  on the additive arm and nothing else; on this build all five arms pass (79, 77, 73, 66, 50
  checks); the `OCLJ_DISPOSE=off` negative control shows the leak and passes as one; two
  harness sabotages each fail exactly their one milestone; the native gates pass on Windows
  and, as C hosts in WSL, on Linux; the build gates were shown failing on HEAD's DLL and .so,
  and `vgc_test` does not link against HEAD's shim object; the jar builds. Every harness run
  loaded the Windows DLLs: no JVM has loaded the Linux .so.

All harness runs: ocelot-brain on Windows 11 with the Windows DLLs, JDK 8 (1.8.0_504), NOT
core-pinned -- these are functional runs, three JVMs at a time (the last three one at a time,
after the incident below); the watchdog kernel on ours and OC's own on stock, tier `threehalf`
at OC's ramScale 1.8. No time in this note is a measurement. Archive:
[runs/2026-10-13-dispose/](runs/2026-10-13-dispose/). The defect's first write-up:
[../docs/research/gc-dispose-leak.md](../docs/research/gc-dispose-leak.md), whose own
"Corrections 2026-10-13" (C1-C6) list where this round found it wrong; the three that shaped
the build are below.

## What was wrong

OpenComputers wraps each host Value -- a Java object pushed as a jnlua userdata whose metatable
is `registry["jnlua.Object"]` -- in a TABLE proxy (machine.lua's `wrapSingleUserdata`); the
proxy's `__gc` calls OC's `userdata.dispose(raw)`, which calls `Value.dispose(machine)`. That
`__gc` is the only route to `Value.dispose`. LuaJIT finalizes userdata and cdata, never tables,
so on this architecture no Value was ever disposed. A file handle opened through
`component.filesystem.open` and dropped held one of the filesystem's handle slots until
reboot (16 by default), and every AE2 `allItems()` iterator kept its ME-grid listener.

On HEAD (the new harness on HEAD's natives and class, `logs/failfirst/`; its one edit after
these runs is the wording of stock's gc-0 SKIP line, message text only):

- **gc-1 (live) and gc-2 (restored).** The sandbox opens `probe.txt` on a dedicated disk,
  hdd2, until refused (16 of `maxHandles` 16, `too_many_open_handles`), keeps the handles
  across the first save, then drops 15 of them on each machine and keeps one bystander. Both
  read: owners 16 → min 16 → 16 at done → 15 after the bystander's close; "owners==1 never";
  fresh open `too_many_open_handles`; disposer calls +0 -- "the witness cleared and the kernel
  collected, but no dropped handle was disposed"
  (`runs/2026-10-13-dispose/logs/failfirst/ff-head-additive/run.log`).
- **gc-3, the save boundary.** 4 handles opened and dropped on hdd3 in one resume and saved at
  once: owners 0 → 4 before the save → 4 right after it.
- **The dropin** (OC's own `NativeLua52Architecture` over our dropin native) leaks the same
  way by construction, on HEAD and after the fix. **Stock PUC** disposes: owners 16 → min 1 → 0,
  the fresh open succeeds, and gc-3 reads 0 → 4 → 0 with OC's single collect.

## The design

Six investigators and a critic read the sources (their notes are not archived); a design
(`design/design.md`) went through a four-lens review -- the C/JNI side, OC's semantics, Java
monitors, the tests -- with skeptic checks of its findings, some run as probes on the pinned
LuaJIT (`design/review/`); the second design (`design/design-v2.md`) was the contract four
implementers built in disjoint file sets, and two cross-checks read the result
(`design/implement-and-crosscheck.json`).

### The facts

- **F1.** `tojavaobject` recognises a Java object only by `rawequal(metatable,
  registry["jnlua.Object"])`. A Value-specific metatable would break `toJavaObjectRaw`;
  replacing a FIELD (`__gc`) of the shared table keeps recognition.
- **F2.** jnlua.Object's `__gc` is `gcjavaobject`, a C closure that deletes the global ref.
  The same metatable carries JavaFunction and LuaError userdata.
- **F3.** Every push mints a NEW userdata and global ref. The kernel dedups a re-pushed Value
  onto its EXISTING proxy through jnlua's Java `__eq` (identity-or-equals) in
  `wrapSingleUserdata` (`v == data`); the new userdata is orphaned and dies while the Value
  lives. Per-userdata disposal would dispose LIVE Values: count per object.
- **F4.** `LuaState.pushJavaObjectRaw` is public synchronized, NOT final, and the only Java
  route into `lua_pushjavaobject`.
- **F5.** Stock OC does NOT dispose at `lua_close`: jnlua zeroes the Java `luaState` before
  `lua_close` (OC-JNLua `jnlua.c:358-364`), OC's dispose binding calls `toJavaObjectRaw`
  outside its `try` (`UserdataAPI.scala:81-88`, the raw read at `:82`), `check()` throws, and
  PUC drops the error.
- **F6.** The pinned LuaJIT runs finalizers on a Lua thread of their own (`vmthread`), on
  whichever OS thread is inside the GC step, under `pcall`, hooks off, the GC threshold frozen,
  errors silent; deferred while on a trace; at `lua_close` newest first. Weak-KEY tables are
  not ephemerons: their values are marked strongly (`lj_gc.c:214-217`), so the raw userdata
  is finalized one full cycle AFTER its proxy dies.
- **F7-F9** (`design/design.md`): the shim's per-state record is reachable from every thread of
  the state, the finalizer's included, and outlives `lua_close`; a direct upcall from the
  finalizer does not go through `calljavafunction`, so the Java side must take the object as
  an argument and touch no LuaState API; a Java exception can be pending when a GC checkpoint
  runs, so the wrapper saves, clears and re-throws it.
- **F10.** OC's two-call save (the dropin; `OcljArch` with `OCLJ_PERSIST_BUNDLE=off`) mints a
  second `HandleValue`, with the same handle id, for every proxy its second blob reaches (every
  proxy, when the save lands mid-sync-call); disposing that copy would close the live file.
  Disposal must never be active there.
- **F11.** Only the additive variant ships.

### What was not built, and why

- **A Value-specific metatable** -- the roadmap row's plan and gc-dispose-leak.md's mechanism
  (g): F1. The wrapper goes on the shared metatable's `__gc` field, with a class filter,
  because that metatable also carries every JavaFunction and LuaError (F2).
- **Push-site interning** -- the row's "Intern Values at the push site (JNLua does not, so
  stock OC can double-dispose today)". The premise is wrong: `__eq` is on the shared
  metatable and the kernel merges a re-push onto its existing proxy (F3), so stock does not
  dispose a re-pushed Value twice. gc-dispose-leak.md's detail 3 ("machine.lua:1174 compares
  by pointer with no `__eq`"; `:71` at aa12418; its correction C2) and row 200 say otherwise;
  the source says this. What a re-push does leave is an orphaned userdata that dies while its
  Value lives, which is why the count is per object.
- **A dispose at close.** gc-dispose-leak.md's (E) ("stock OC disposes everything at close";
  `:55` at aa12418; its correction C1) is wrong (F5); this build disposes nothing at close
  either, for parity. The review's optional `close()` that would collect twice first was left
  out for the same reason: it goes beyond stock (`design/review/findings.md`, OC-1).
- **An equals-keyed count** (the first design). The review (J1, OC-2) found that a `HashMap`
  keyed by equals runs third-party `hashCode`/`equals` at every push and finalization, where
  stock runs no Value code at push time, and does not match the relation the kernel merges by
  (`existing.equals(new)`, never `hashCode`); when the two diverge it can dispose a live
  Value. No OC Value overrides `equals`. The contract counts by identity and checks `equals`
  only at a zero (below).
- **Counting after the push** (the first design). jnlua's push runs a GC checkpoint, which can
  finalize the dying earlier userdata of the very object being pushed; counted after, its
  count reaches zero inside its own push (review C3, OC-3, J2). The count is taken before the
  native push; vd-9 tests the order and its sabotage fails it.

## What was built

### C: `native/lj52shim.c`, `native/lj52shim.h`

- **THE VALUE FINALIZER** (`lj52shim.c:616` on; its comment carries the facts with file:line).
  `lj52_vgc_gc` (`:743`) is the new `__gc`. Per finalized userdata: during close, count a
  closing skip and make no JNI call; otherwise `GetEnv(JNI_VERSION_1_6)` (refused: count a
  noenv skip); save and clear a pending exception; `IsInstanceOf` the Value class; call Java
  `ocljValueFinalized(Object)` on a WEAK global ref of the `LuaStateLuaJIT`; clear and count an
  exception the callback leaves; re-throw the saved one; then ALWAYS chain jnlua's original
  `gcjavaobject` (a `lua_call` of upvalue 1).
- **The install**, `lj52_vgc_install` (`:815`): the JNI part first (`GetJavaVM`, the class's
  global ref, the state's weak ref, the method lookup; every failure clears the exception,
  releases what it made and returns its code); then a stack-neutral `lua_cpcall` of
  `lj52_vgc_install_p` (`:786`) that validates and does the one `rawset` -- the field is never
  nil in between. Codes `OK 0, ENORECORD 1, EJVM 2, EREF 3, EMETHOD 4, ENOMT 5, ENOGC 6,
  ELUA 7` (`lj52shim.h:273-276`; the registry key `LJ52_JNLUA_OBJECT` at `:272`, the two
  prototypes at `:277-278`). A second install keeps one wrapper level and replaces the refs.
- **The close.** `lj52_close` sets `vgc_closing` before `lua_close` (`:2527`) and releases the
  class and state refs after it.
- **The counters** calls, jerr, closing, noenv, installed: `lj52_vgc_counters` (`:876`), the
  JNI `ocljValueGcCounters`, and a new raw global `_OCLJ_VGCSTATS()` (`:2459-2505`; -1 each for
  a state with no record).
- **Two new additive-only JNI exports**, `ocljInstallValueFinalizer(Class) -> int` and
  `ocljValueGcCounters(long[])`: the additive exports 91 `Java_*` / 93 PE names (was 89/91);
  the dropin is unchanged at 87/89.

### Java: the generated `LuaStateLuaJIT`

`native/jnlua/gen-luastate-subclass.py`'s `value_disposal()` (`:208`) emits it into
`src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java` -- regenerated, byte-identical
on a re-run, and re-checked by every additive build ("LuaStateLuaJIT.java == the generator's
output").

- `ocljSetValueDisposer(Class, Consumer)` (`LuaStateLuaJIT.java:154`, public synchronized):
  installs, or throws `IllegalStateException` naming the native's code;
  `ocljValueDisposalInstalled()`; `ocljValueStats()`, `long[10]`: counted, finalized,
  disposed, missing, mergedSkips, unlocked, disposeErrors, refusedInDispose, live,
  bookkeepingFailures; `ocljValueGcCounters()`, `long[5]`.
- Overrides: `pushJavaObjectRaw` counts BEFORE the native push and rolls the count back if the
  push throws; `pushJavaFunction` is counted, when its function is also a Value, and NOT
  rolled back (jnlua sets the metatable before it allocates the closure, `jnlua.c:656-660`, so
  a failed push can leave a userdata that will be finalized); `close()` drops the count map,
  the class and the disposer (the stats stay) and disposes nothing.
- `ocljValueFinalized(Object)` (`:343`), private and NOT synchronized: a `Thread.holdsLock`
  guard, so a callback without the monitor is counted "unlocked" and leaks instead of
  blocking; an `IdentityHashMap` count; dispose when the last userdata of the object is
  finalized.
- At a zero, if a LIVE entry whose class overrides `equals` equals the object (or `equals`
  throws), the dispose is skipped -- a leak, never premature. A bookkeeping step that fails at
  a push stops new entries (`ocljCountBroken`); one that fails at a finalization or a rollback
  is counted only. A dispose may not push (`IllegalStateException`, counted).
- A new refusal gate, `value_routes()` (generator `:185`): the generator refuses if
  `LuaState.java` grows another `lua_pushjavaobject` or `lua_pushjavafunction` call site, or the
  overridden signatures change shape.

### The architecture: `LuaJITArchitecture.java`

- `installValueDisposal()` (`:242`), called at `:159`, right after `applyForinMode()` (`:154`)
  and before the kernel swap, so the fallback branch has it too and a restore's pushes are
  counted. The disposer is OC's own binding body: `((Value) v).dispose(machine())`, a throw
  logged with OC's message "Error in dispose method of userdata of type ..." and dropped. Any
  install failure (`Throwable`) is logged as an error and the machine STARTS ANYWAY, as it did
  before disposal existed.
- `save()`: a SECOND `lua.gc(COLLECT)` (`:636`) after the first (`:618`), in the same `try`.
  Without it a Value whose proxy died since the kernel's last collect is never disposed at an
  unload save, because nothing is disposed at close (F5, F6). It runs whether or not disposal
  installed.
- The harness's twin, `test/native/OcljArch.scala`, installs the same way by reflection (so
  the harness compiles against HEAD's class too), only with its bundle on and `OCLJ_DISPOSE`
  not `off`, and its `save()` carries the same second collect (`:444`, `:461`).

### Build gates

- `native/build-native.sh` preflight: OC-JNLua's `jnlua.c` must still define `JNLUA_OBJECT`
  as `"jnlua.Object"` (`:399-404`) and `lj52shim.h`'s `LJ52_JNLUA_OBJECT` must be the same
  key (`:405-409`); the section's comment at `:390-398`.
- The object gate: `nm` must find `lj52_vgc_install` and `lj52_vgc_counters` in every build
  (`:651`); the oclj natives counted on the object, 4 additive / 0 dropin (`:655`).
- The export gates: the four oclj names counted in the export table, 4 additive / 0 dropin
  (`:902`), and `WANT_J`/`WANT_PE` 91/93 on the additive (`:904`), 87/89 on the dropin
  (`:910`).
- `build.gradle.kts` `verifyModAssets`: `need` (`:163`) lists all four oclj natives.
- `docs/accounting-sync.md`: brought up to date where Value disposal touches it (the export
  counts, the override list, line cites), each change dated 2026-10-13.

## The tests

**`test/native/vgc_test.c`** (1 388 lines) and `run-vgc.sh`: no JVM; the shim object and
`libluajit.a` against a strict fake JNIEnv/JavaVM -- unlisted slots trap, objects come from a
never-reused pool, the pending-exception discipline is enforced, `GetEnv` refuses versions past
1.8. 47 checks, V0a..V12f: the constants (V0); one callback per Value, before its original,
through a live ref (V1); non-Values get no callback (V2); `lj52_close` makes no callback and no
JNI call but the release, runs each original once, and counts every finalization at close as
a closing skip -- 8 of 8, read inside the last finalizer (V3, V3e); a pending exception (V4);
a callback's exception (V5); a second install (V6); refused installs, `ENOMT`, `ENOGC`, `ELUA`,
stack and refs untouched (V7); `GetEnv` refused (V8); each JNI step failing (V9); 2 000
finalizations in one armed checkpoint with no local-ref growth (V10); the counters against
`_OCLJ_VGCSTATS` (V11); whole-run invariants (V12).

**`test/native/negative-control.sh` section 7** (`:737`): the canonical shim, then ten
sabotages, each of which must fail EXACTLY its predicted set:

| sabotage | the defect | fails exactly |
|---|---|---|
| `vgcnochain` | the wrapper never chains to `gcjavaobject` | V10a V12f V1d V2b V3b V4d V5c V6b V8b |
| `vgcnoclosing` | the wrapper calls Java during `lua_close` | V3a V3c V3e |
| `vgcnosave` | a pending exception not saved and re-thrown | V12c V4a V4c |
| `vgcnofilter` | no class filter | V11a V2a |
| `vgcnosettop` | the install leaves the cpcall's error on the stack | V7c |
| `vgcnoinstclear` | an install failure leaves its exception pending | V9a V9b V9c |
| `vgcnodeljs` | a local ref leaked per finalizer | V10b V12e |
| `vgcswapchain` | the callback after the original released the ref | V12b V1c |
| `vgcnorelease` | class and state refs never released after close | V12f V3d |
| `vgcnopostclear` | the callback's exception left pending | V5a |

**The harness** (`test/native/OcljSmoke.scala`, `OcljArch.scala`, `smoke-test.sh`):

- **gc-0**: installed exactly when configured -- keyed on the configuration, never on the
  outcome, so an install failure cannot turn into a passing leak.
- **gc-1 (live) and gc-2 (restored)** on the dedicated hdd2: one hold of 16 = `maxHandles`
  until refused (bounded), two drops of 15 with a bystander kept, then closed; a
  registry-shaped witness that clears only when a full cycle passes, plus a plain twin; the
  owners polled from Java; the fresh open must work.
- **gc-3**, the save boundary on hdd3: 4 handles dropped in one resume and saved at once; the
  owners must be 0 right after the save. That no cycle ran between the drop and the save is
  checked (the tagged proxies still registered when the save began), with up to 3 attempts.
- **vd-1..vd-9** on private states of the arm's own factory, with Value classes that count
  their own disposes:
  - vd-1 the kernel's merge (a copy of its `wrapSingleUserdata`) keeps a Value alive: echoed
    3x, 3 orphans finalized, 0 disposes while the proxy lives, 1 after;
  - vd-2 N distinct Values → N disposes; non-Values (a String, a LuaError, a JavaFunction
    userdata) → no callback;
  - vd-3 equal Values: never while live, at most one; the sequential case RECORDED, a2=0 b2=1,
    where stock disposes both;
  - vd-4 close disposes nothing, no Java callback during close;
  - vd-5 a refused install (`__gc` swapped for a Lua function) → code 6 `ENOGC`, stack
    untouched, nothing counted, and it works once restored;
  - vd-6 the lock guard; vd-7 a dispose may not push; vd-8 the members' modifiers;
  - vd-9 count BEFORE push: a full GC cycle forced INSIDE the push finalizes the object's
    earlier userdata and must not dispose it. Added by the main session after the cross-check
    found that no permanent check could fail if the count moved after the push.
- **The arms.** `OCLJ_DISPOSE=on|off` (validated, exported) and `OCLJ_PERSIST_BUNDLE=off`: the
  gc-* milestones expect the LEAK, with the id suffix `-NEGATIVE-CONTROL`; the dropin's ids
  are `gc-N-dropin-control-...-leaks`; stock keeps the product ids. gc-0 and vd-* are SKIP, not
  counted, on the dropin and stock.
- **f1b**, an existing milestone, now also requires a `HandleValue` recipe owned by the boot
  disk in the f1 blob (the 16 held hdd2 handles alone would satisfy its old needle).
- The harness reaches every new `LuaStateLuaJIT` member by reflection, so the same harness
  compiles and runs against HEAD's class.

## The results

| arm | before (the harness at HEAD, 2026-10-05) | new harness, HEAD's natives + class | new harness, this build | the reading |
|---|---|---|---|---|
| additive, JIT on | 66 / 0 | 79 / 13, FAIL | 79 / 0 | the 13 are gc-0..3 and vd-1..9, nothing else (vd-* on HEAD: `NoSuchMethodException`). gc-0: HEAD `NoSuchMethodException ocljSetValueDisposer`, now installed=true. gc-1/gc-2: HEAD owners 16 → min 16, fresh open `too_many_open_handles`; now 16 → min 1 → 0 after the bystander's close, disposer calls +15, fresh open ok. gc-3: HEAD hdd3 owners 0 → 4 → 4 right after the save; now 0 → 4 → 0 (5 ms) |
| additive, JIT off | 64 / 0 | not run | 77 / 0 | |
| sieve only | 60 / 0 | not run | 73 / 0 | |
| dropin | 63 / 0 | 66 / 0 | 66 / 0 | gc-1..3 as dropin controls: the leak, on both |
| stock | 47 / 0 | 50 / 0 | 50 / 0 | stock disposes: owners 16 → min 1 → 0; gc-3 0 → 4 → 0 with ONE collect |
| additive, `OCLJ_DISPOSE=off` | -- | not run | 79 / 0, the NEGATIVE CONTROL | installed=false; owners 16 → 16, fresh open refused; gc-3 4 → 4; banner "SMOKE PASS (NEGATIVE CONTROL, OCLJ_DISPOSE=off)" |
| additive, `OCLJ_PERSIST_BUNDLE=off` | -- | not run | 79 / 3 | the three are stk-2/3/4, the failures that control exists to show; the gc-* run as `-NEGATIVE-CONTROL` (never installed with the bundle off) and pass; vd-1..9 pass |

CHECKS / FAILURES. The "before" column is the five suites of
[results-reserve-2026-10-05.md](results-reserve-2026-10-05.md) (item 5), on natives
byte-identical to HEAD's. The new counts are +13 on the additive arms (gc-0..3, vd-1..9) and +3
on the dropin and stock (gc-1..3). HEAD's natives: additive `45eb443b`, dropin `8f9bc419`;
HEAD's `LuaStateLuaJIT.java` `82a7918d` (`logs/failfirst/`). This build: additive DLL `6445f2e4`
(sha256 `73941e09...`), dropin `60a8a522` (sha256 `886406fc...`), the two DLLs the post-fix
runs loaded, stock aside (`logs/suite/*/native.md5`, `logs/sabotage/*/native.md5`). The jar also carries this build's Linux additive .so
`0deb53ab` (sha256 `c4574720...`), which no run loaded (`logs/builds/natives.md5`; the sha256s
from `logs/builds/build-*.log`).

- **The dispose follows the witness.** In every LuaJIT run, both drops, before and after the
  fix, the registry-shaped witness cleared exactly ten steps after its plain twin (15 and 5,
  19 and 9, 12 and 2 ...); on stock both cleared at the same step (6 and 6, 7 and 7). That is
  F6's extra cycle, seen in the machine. On this build the owners reached 1 within a tick of
  the witness clearing ("owners==1 at tick 9 (0 ticks after the row showed the witness
  clear)").
- **The fixed arms agree.** JIT on, JIT off and sieve each read gc-1 and gc-2 16 → min 1 → 0
  after the bystander's close, disposer calls +15, dispose errors 0, and gc-3 0 → 4 → 0 at
  attempt 1 with every tagged proxy still registered when the save began (4 of 4).

**The sabotages** (`logs/sabotage/`, the sources as diffs in `sabotage/`), on this build's
natives:

- **`OcljArch.save` with ONE collect** (the second removed): 79 / 1. Exactly gc-3 fails --
  hdd3 owners 0 → 4 → 4 right after the save, "LEAK AT THE SAVE BOUNDARY"; gc-1 and gc-2
  pass. The kernel's own collects still dispose; only the save boundary needs the second one.
- **`LuaStateLuaJIT` counting AFTER `super.pushJavaObjectRaw`**: 79 / 1. Exactly vd-9 fails --
  "DISPOSED BY ITS OWN PUSH": callbacks during the push +1, disposes during it 1, and 2 in all
  once the new userdata is dropped.

**The controls.** `OCLJ_DISPOSE=off` (`logs/suite/fix-disposeoff-a/`): installed=false, the
native's counters 0/0/0/0/0, gc-1 and gc-2 owners 16 → 16 → 15 after the bystander's close,
fresh open refused, gc-3 4 → 4 -- the HEAD leak on this build's natives, with the same
milestones passing as the negative control. The dropin, on HEAD's natives and on this build's,
shows the same leak as its permanent same-DLL control.

**The native gates** (`logs/native/`). Windows, in place: vgc 47/0, mem 86/0 (C0c:
`_OCLJ_GCSTATS` still returns 20 values), wd 35/0, penalty 6/0, the negative control PASS (52
"RESULT: PASS" lines, every section); against a layout mirror: shim 57/0, security 37/0, race
2/0. Linux (WSL): vgc 47/0, mem 86/0, wd 35/0, penalty 6/0 -- C hosts linked against the Linux
`libluajit.a` and shim object (`logs/native/wsl/host.txt`), `vgc_test` against its fake
JNIEnv; the .so itself is only hashed there, and no JVM loaded it. `run-race.sh`,
`run-security.sh` and `run.sh` still name the pre-per-platform layout (`luajit/src`, `obj/`):
in place the first two stop at setup (`logs/native/win/race-layout.log`,
`security-layout.log`; `run.sh` was not tried), so all three ran against a mirror of that
layout built from the current Windows objects (`logs/native/win-mirror/`), as on 2026-10-05.

**The build gates, shown failing on HEAD** (`logs/builds/exportgate-proof.txt`, the three
count gates of `build-native.sh` evaluated each on its own). HEAD's additive DLL `45eb443b`:
oclj natives 2 (want 4), `Java_*` 89 (want 91), PE names 91 (want 93) -- each FAIL; neither
`ocljInstallValueFinalizer` nor `ocljValueGcCounters` occurs in its bytes (0 matches each), so
gradle's `need` refuses it. This build's additive DLL passes all three; both dropins pass at
0/87/89. That file's `.so` check pointed at a wrong path for HEAD's .so and printed nothing
for it; the .so proof is `logs/builds/exportgate-proof-so.txt` (`scripts/so-exports.sh`, run
in WSL with `nm -D`, the reader `build-native.sh` uses on ELF). HEAD's Linux .so `45b25422`:
oclj natives 2 (want 4), `Java_*` 89 (want 91) -- each FAIL -- and 0 matches of either new
name; this build's `0deb53ab`: 4 and 91, PASS, 2 matches each.

The cross-check (`design/implement-and-crosscheck.json`) showed the two `JNLUA_OBJECT` greps
failing on altered copies and the object gates failing on the `build/native` object that
predated the change (NOCLJ=2, no `lj52_vgc_*`; not hashed). `vgc_test` does not link against
HEAD's shim object (`logs/native/win/vgc-failfirst/`, `scripts/vgc-failfirst.sh`): HEAD
aa12418's `lj52shim.c` and `.h` from git, compiled with `build-native.sh` step 2's dropin line,
give object `79f19c63` -- byte-identical to the 2026-10-05 reserve round's dropin shim object
-- which defines 0 `lj52_vgc_*` symbols, and the link stops at "undefined reference to
`lj52_vgc_counters'" ("TEST FAIL: test did not build", exit 1). Against this build's dropin object
(`ace486b4`, the one every Windows native gate linked), the same script reads 47/0.

**The jar** (`logs/builds/gradle-build.log`): `gradlew build` BUILD SUCCESSFUL; `spotlessCheck`
passes on the Java changes; `verifyModAssets` packages both natives and reads "native exports
the four oclj natives LuaStateLuaJIT declares". `build/libs/ocluajit-aa12418-master+aa124186c8-dirty.jar`,
md5 `c1569833` -- a dirty-tree build, NOT installed in the game.

**An instrument incident** (`logs/incident/`). The first attempt at the bundle-off control and
both sabotages (chain a's third batch) ran as three JVMs started in the same second
(16:26:39Z). All three stopped at +12 s on the harness's guard, "LuaStateFactory.isAvailable
== false: no native loaded", after the first two boot milestones and before anything under
test ran -- no gc-* or vd-* milestone, no CHECKS line. OC's bundled 5.2 native is extracted
into the shared working directory by each JVM (the `Ocelot-0.24.2-5x-*.dll` files in the repo
root), and two of the three logs read "Could not update native library
'Ocelot-0.24.2-52-libjnlua52-windows-x86_64.dll'!": the likely cause is that extraction
racing. It is not proven: chain a's first two batches also started three JVMs in the same
second (16:22:47Z, 16:24:42Z) and ran. Rerun one at a time (chain b, `scripts/chain-seq.sh`),
all three ran; the bundle-off and sabotage results above are chain b's
(`logs/suite/fix-bundleoff-b/`, `logs/sabotage/`).

## Deviations from the design contract

`design/design-v2.md` is the contract; the code differs from it in eight places, each
deliberate. They are recorded so that nobody "fixes" the code back to the contract.

1. `_OCLJ_GCSTATS` stays at 20 values (= `LUA_MINSTACK`; pinned by mem_test C0c and the
   harness's acc-1/acc-1r); the five new counters are a separate global, `_OCLJ_VGCSTATS`.
   The contract (section 1) appended the five to `_OCLJ_GCSTATS`.
2. The native closing-skip counter cannot be read after close: the record is freed in
   `lj52_close`, and a closed state reads zeros. vd-4 instead asserts zero Java callbacks
   during `close()`; the counter itself is asserted only by `vgc_test` V3e, from inside the
   last finalizer. The contract (section 5, vd-4) said "counters show closing skips".
3. `ocljValueStats` has a 10th element, [9] bookkeeping failures.
4. `pushJavaFunction` is not rolled back on a throw (jnlua sets the metatable before it
   allocates the closure, `jnlua.c:656-660`).
5. The equals-merge check keys on the EXISTING live object's class, for any new object: an
   overriding `equals` may accept a value whose own class does not override it.
6. gc-3 uses its own disk, hdd3 (4 handles), so it does not depend on gc-1's outcome; its "no
   cycle between the drop and the save" is CHECKED (the tagged proxies still in
   `wrappedUserdata` under the machine's monitor), with up to 3 attempts.
7. The harness's hold bound is `max(64, 2*maxHandles+1)`, so a raised `maxHandles` still ends
   on the refusal.
8. f1b, an existing milestone, now also requires a `HandleValue` recipe owned by the boot disk
   in the f1 blob.

## Differences from stock, and what is not covered

- **The product's `LuaJITArchitecture.java` is exercised only by its compile and spotless.**
  The harness runs its Scala twin, `OcljArch.scala`, as for every earlier row. Its install and
  its second COLLECT have no in-game run: T10.
- **No in-game test yet.** The user's GTNH pack sets `maxHandles=64` (OC's default is 16):
  there it takes 64 drops to break `open` on HEAD. A T10 disposal item: open and drop more
  than 64 handles through `component.filesystem.open`, then open again.
- **No JVM has loaded the Linux .so.** Every harness run used the Windows DLLs on Windows 11
  (each `run.log`: "os=Windows 11"). The Linux additive .so `0deb53ab` the jar ships was built
  in WSL; its LuaJIT and shim objects pass vgc, mem, wd and penalty there as C hosts
  (`vgc_test` against its fake JNIEnv), and its exports were counted
  (`logs/builds/exportgate-proof-so.txt`). The finalizer's upcall into a real JVM is untested
  on Linux: the roadmap row "The Linux native has never been loaded by a JVM" stands.
- **Only filesystem `HandleValue`s and the harness's own counting Values are exercised.** AE2
  `NetworkControl` iterators (no AE2 in the harness) and internet sockets and requests are
  not; the mechanism is the same `Value.dispose`.
- **Nothing is disposed at `lua_close`**: stock parity (F5). A Value alive at shutdown or
  unload leaks on stock too.
- **Disposal lands one GC cycle later than stock** (F6); the save's second COLLECT restores
  "dead at the save is disposed". The cost is one more full GC per machine per save -- not
  measured beyond gc-3's 3-7 ms saves (unpinned) of a 186-241 KB `_kernel`. Neither the push
  path's cost (an identity-map step per Value push, an `isInstance` per other push) nor the
  finalize path's is measured: a `GetEnv`, `ExceptionOccurred`, `IsInstanceOf` and a chained
  `lua_call` on every finalized jnlua.Object userdata, Value or not, plus a JNI upcall and an
  identity-map step per Value userdata.
- **A Value pushed but never wrapped** (an error between the push and the wrap) IS disposed;
  stock leaks it.
- **A raw userdata left in a user table** by the kernel's `unwrapUserdata` in-place rewrite
  keeps its Value alive until that table dies.
- **Third-party Values that override `equals`**: at a zero, an equal LIVE Value means the
  dispose is skipped (a leak, never premature); the sequential equal case can leak where
  stock disposes both (vd-3 records a2=0 b2=1).
- **A user-defined table `__gc`** (`allowGC=true` packs; the user's pack sets it) stays
  unsupported: LuaJIT finalizes no table.
- **The dropin arm keeps the leak** (it never ships); `OCLJ_PERSIST_BUNDLE=off` never installs
  disposal (F10).
- **`_OCLJ_VGCSTATS` is a new C function among the state's raw globals**, reachable from `_G`,
  so it is a new eris permanent outside the blob fingerprint (the serializer hash is still
  `8c5a1168`): the cross-build blob compatibility row's class of change, the same as
  `_OCLJ_WALLSTATS` (d705515), recorded there. Not tested across builds.
