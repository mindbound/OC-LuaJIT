# The __gc / Value.dispose gap on a LuaJIT architecture

LuaJIT finalizes userdata and cdata, never tables. OpenComputers reaches
`Value.dispose()` through exactly one route -- a `__gc` on a TABLE
(`machine.lua` userdataWrapper) -- so that route is severed on our
architecture, with no replacement anywhere in the mod. [2026-10-13: there is one now — Corrections below.]

This started as an unverified aside in a report about something else. It was
directionally right and wrong in three specifics, and the investigation found a
worse problem the aside never named. 2026-09-01.

**Corrections 2026-10-13.** The fix is BUILT — what was built and how it was
measured is in [../../bench/results-dispose-2026-10-13.md](../../bench/results-dispose-2026-10-13.md)
(evidence in `bench/runs/2026-10-13-dispose/`; the roadmap row "Value disposal
(`__gc`)") — and building it proved this report wrong in the places below.
The original text is left as written; each wrong passage carries a bracketed
pointer to its correction here. Each correction was established in source on
2026-10-13, C4 by `git diff --numstat`. The harness also shows C2 (vd-1), C5
(gc-3, and its sabotage with one collect) and C6's duplicate (the
`OCLJ_PERSIST_BUNDLE=off` control's stk-3: 14 recipes for 7 proxies); C1 it
shows for this build only (vd-4: no Java call during close), and stock's close
was read in source, not run.

C1 — STOCK DOES NOT DISPOSE AT CLOSE EITHER. (E), "including at lua_close"
under WHY IT WORKS and "(g) restores that for free" under REJECTED ALTERNATIVES
are wrong. JNLua zeroes the Java state's `luaState` before it calls
`lua_close` (OC-JNLua jnlua.c:358-364); OC's `userdata.dispose` binding reads
`toJavaObjectRaw(1)` outside its `try` (UserdataAPI.scala:81-88, the read at
:82), that read throws on the zeroed state, and PUC 5.2 drops a finalizer's
error at close. So stock disposes nothing at close, and "nothing disposes at
close either" is parity, not a regression. The build keeps that parity on
purpose: `lj52_close` sets a closing flag just before `lua_close`, and from
then on the new `__gc` makes no call into Java. A
Value still alive at shutdown or unload leaks, on stock and on ours.

C2 — TWO USERDATA, ONE PROXY. Detail 3 and the matching sentence under
USERDATA REFUSAL are right that a Value pushed twice yields two userdata, and
wrong about what follows. `machine.lua:1174`'s `v == data` is not a pointer
compare: both userdata carry JNLua's shared `jnlua.Object` metatable, whose
`__eq` (identity, or `equals`) makes `wrapSingleUserdata` return the EXISTING
proxy. The second userdata is orphaned and finalized while the Value lives. So
stock does NOT dispose a Value twice for being pushed twice while its proxy
lives — and (g) as written, one dispose per finalized userdata, WOULD dispose
live Values. What was built counts the live userdata of each Value by
identity, in Java, at the push (`pushJavaObjectRaw`, the one Java route into
jnlua's `lua_pushjavaobject`), and disposes only when the last of them is
finalized.
Measured (harness vd-1, on a private state through a reduced copy of the
kernel's `wrapSingleUserdata`): a Value echoed back three times merged onto
its live proxy 3 of 3, its three orphans finalized, 0 disposes while the proxy
lived, 1 after.

C3 — NOT A VALUE-SPECIFIC METATABLE. Detail 2 and the "our native/Java arch"
line of LAYER AND COST are wrong. JNLua recognises a Java object only when its
metatable is `rawequal` to `registry["jnlua.Object"]` (jnlua.c:2093-2094), so
a Value under any other metatable no longer reads back through
`toJavaObjectRaw` — which OC's own dispose binding calls. What was built
replaces one FIELD of the shared table: its `__gc` becomes a C closure holding
jnlua's own `gcjavaobject` as its upvalue, which calls Java only for an
instance of the Value class (the same metatable carries JavaFunction and
LuaError userdata) and ALWAYS chains to the original, so the global ref is
released as before. "Other pushed Java objects are unaffected" holds through
that class filter instead.

C4 — NOT FIFTEEN LINES. Against aa12418, comments included (`git diff
--numstat`): `native/lj52shim.c` +365, `lj52shim.h` +19, the generator
+493/-3 (emitting +394/-3 into `LuaStateLuaJIT.java`),
`LuaJITArchitecture.java` +100, `build-native.sh` +62/-29, `build.gradle.kts`
+20/-11; and tests, `vgc_test.c` 1 388 lines new and `run-vgc.sh`,
`OcljSmoke.scala` +1 276/-3, `OcljArch.scala` +160/-2, `negative-control.sh`
+137, `smoke-test.sh` +43. Serializer and machine.lua: zero, as predicted.

C5 — ONE GC CYCLE LATER THAN STOCK, SO A SECOND COLLECT AT SAVE. "restores
exactly the lifetime PUC Lua gave us" is one cycle off. LuaJIT's weak-KEY
tables are not ephemerons: the values of a weak-keyed table are marked
strongly (lj_gc.c:214-217), so the cycle in which a proxy dies only clears its
`wrappedUserdata` entry, and the raw userdata is finalized in the NEXT full
cycle (stock disposes in the same cycle, through the proxy's own `__gc`). So
`LuaJITArchitecture.save` runs a second full collect after OC's one, whether
or not disposal installed; without it a Value whose proxy died since the
kernel's last collect is never disposed at an unload save, because nothing is
disposed at close (C1). Harness gc-3 fails with one collect and passes with
two.

C6 — THE TWO-CALL SAVE. (g)'s third reason ("the HOST mints a FRESH Value")
holds for the save we ship, which is one blob. OC's own two-call save (the
dropin arm; the harness with `OCLJ_PERSIST_BUNDLE=off`) mints a second
`HandleValue`, with the SAME handle id, for every proxy its second blob
reaches (every proxy, when the save lands mid-sync-call), and disposing that
copy would close the live file (docs/shell-fill.md:381-383). Disposal is never
installed there.

NOT YET COVERED: no in-game run (the roadmap's T10 row). The product's
`LuaJITArchitecture.java` is exercised only by compile and spotless; the
harness runs its twin, `OcljArch.scala`. Every harness run was on Windows:
the Linux additive `.so` has been loaded by no JVM, and on Linux the
finalizer's JNI upcall has run only against `vgc_test`'s fake JNIEnv. Only
filesystem `HandleValue`s and the harness's own counting Values are exercised:
AE2's `NetworkContents` iterators (no AE2 in the harness) and internet sockets
and requests are not, though they go through the same `Value.dispose`.
User-defined table `__gc` (`allowGC=true` packs) stays unsupported, since
LuaJIT finalizes no table. Not measured: the cost of the save's second
collect, of the count at each push, and of the new `__gc` on every finalized
Java-object userdata, Value or not. The new raw global `_OCLJ_VGCSTATS` is a
new eris permanent outside the blob fingerprint (the roadmap's cross-build
blob compatibility row). The other differences from stock are in the
roadmap's Value disposal row.

## Is it real?

YES — the mechanism is real, and I re-measured it myself rather than taking any arm's word for it.

MEASUREMENT (my own, pinned LuaJIT 2.1.1787165859, C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit/src/luajit.exe; probe at .../scratchpad/verdict/probe.lua):
  table __gc, machine.lua's exact construction order (populate, then setmetatable): 0/200
  table __gc, metatable-first order (the PUC-5.2 "mark finalizable" order):        0/200
  userdata __gc via newproxy(true) — the control:                                200/200
  getmetatable(t).__gc still reads back as `function` — it is stored, never called.
The luajit arm additionally measured cdata 200/200, both build variants, and 0/200 for tables even at lua_close; and established that -DLUAJIT_ENABLE_LUA52COMPAT cannot change this (LJ_52 has zero use sites in lj_gc.c/lj_api.c). It also found the earlier agent's A/B was not an A/B at all: the repo's libluajit_stock.a is itself a LUA52COMPAT build.

THE OC SIDE, from source I read directly (scratchpad/ocgtnh, GTNH fork):
  machine.lua:1178,1184 — the component "userdata" handed to sandboxed Lua is a TABLE proxy.
  machine.lua:1124-1128 — userdataWrapper.__gc is the only caller of userdata.dispose.
  machine.lua:1057 — wrappedUserdata is __mode="k", so when the proxy dies the host-handle mapping vanishes silently.
  Value.dispose(machine) has exactly two call sites in the whole mod — luac/UserdataAPI.scala:83 and luaj/UserdataAPI.scala:40 — both the `userdata.dispose` binding fed by that one __gc. Confirmed by exhaustive grep for `.dispose(` across src/.
So on our architecture the single route to Value.dispose() is severed, with no replacement anywhere in the mod. [2026-10-13: there is one now — Corrections above.]

WHERE THE FINDING WAS WRONG (it was an unverified aside, and it overreaches in three places):
1. "machine.lua's entire sgc/sgcco apparatus is dead code" — true but NOT a regression. sgc/sgcco is not a disposal path; it is a deadline sandbox for USER-written __gc callbacks (machine.lua:794, inside the sandboxed setmetatable). It is already unreachable on stock OC: application.conf:224 ships `allowGC: false` (verified), in which case machine.lua:797-805 strips __gc from user metatables outright. Losing it on LuaJIT costs zero.
2. "every component userdata leaks host-side" — no. Of 15 Value classes only 5 have a non-trivial dispose; AbstractValue.dispose is a no-op.
3. "until the machine closes" — wrong in both directions, see severity.

## How bad

MODERATE, and it is two different problems that the finding merged into one. Report it as quota exhaustion plus one unbounded CPU leak — not as "userdata leaks".

(A) FILE HANDLES — a CORRECTNESS BUG, bounded by one power-on cycle, and the thing most likely to bite a player.
Settings.maxHandles = 16 (application.conf:926, verified), enforced at FileSystem.scala:159 against a per-computer `owners` set. Sixteen handles opened and dropped without close make every subsequent open() throw "too many open handles" until reboot. That is a functional failure of the OS's file API, not memory pressure. Blast radius is narrow: OpenOS never relied on __gc (boot/01_process.lua routes every fs.open through process.addHandle), so this only hits code calling component.filesystem.open directly and dropping the handle.

(B) INTERNET SOCKETS — a resource leak, bounded by one power-on cycle. Real sockets/channels/futures, but reclaimed wholesale on power transition.

The backstop for both, verified in source: FileSystem.scala:272-286 (onMessage) and 287-300 (onDisconnect), InternetCard.scala:139-146 and 128-137 close everything on BOTH "computer.stopped" AND "computer.started". So exposure is one uptime window, never cumulative across reboots.

(C) AE2 NetworkControl.NetworkContents — the genuinely UNBOUNDED leak, with no backstop of any kind, and it is a compounding CPU leak on the server thread, not merely memory. Verified line by line in src/main/scala/li/cil/oc/integration/appeng/NetworkControl.scala:
  line 611  — the iterator self-registers as an ME grid listener: getMonitor.foreach(_.addListener(this, null))
  line 634-640 — its ONLY unregistration is `valid = false`, set in dispose(), read back via isValid()
  line 646-648 — postChange → updateItems → line 605 `items.toSorted.iterator`, a full re-sort of the ME item list
  lines 589-591 — OC's own comment already flags toSorted as a performance problem on large networks
With dispose() unreachable, valid stays true forever, AE2 never drops the listener, and every leaked instance re-sorts the whole ME item list on every network change. One is minted per allItems() call (line 201), which GTNH automation scripts poll in loops. The same shape exists in integration/ec/NetworkControl.scala and integration/thaumicenergistics/NetworkControl.scala. This is GTNH-fork-specific and it is the finding's real severity — the finding did not name it.

(D) JAVA HEAP — largely fine, and this is why "leak" is the wrong word. Our userdata __gc still fires (200/200), so JNLua's DeleteGlobalRef still runs and most Values become JVM garbage normally. The exception is precisely (C): AE2 holds the Value strongly through its listener map, so there the Java object is immortal too.

(E) MACHINE CLOSE DOES NOT SAVE US, and this is a real regression against stock. On PUC 5.2, lua_close finalizes tables, so stock OC disposes everything at close. On LuaJIT tables are never finalized, at close or otherwise (0/200 including the lua_close case). So "leaks until the machine closes" understates it: nothing disposes at close either. [WRONG, 2026-10-13: stock does not dispose at close either — Corrections C1.]

## The fix

MECHANISM (g), from the fix arm — put Value.dispose() in the C __gc of the Value userdata that ALREADY EXISTS, inside our own native binding. Adopt it. It is not any of the enumerated (a)-(f), and it is not "hand the sandbox a newproxy".

WHY IT WORKS. The Java Value is already a real userdata on the Lua stack, sitting behind machine.lua's table proxy and held as a strong VALUE in the weak-KEYED wrappedUserdata table (machine.lua:1057, 1183). When the table proxy dies — which LuaJIT does collect normally — the weak-key entry clears, the userdata becomes unreachable, and userdata __gc DOES fire on LuaJIT (my own 200/200). So attaching disposal to the object LuaJIT actually finalizes restores exactly the lifetime PUC Lua gave us, including at lua_close. [WRONG, 2026-10-13: nothing is disposed at lua_close on stock or here, and disposal lands one GC cycle later than on PUC — Corrections C1, C5.]

LAYER AND COST — about fifteen lines, all in code we have not written yet: [WRONG, 2026-10-13: far more — Corrections C4.]
  serializer: ZERO. No new shape, no tag 14, the userdata refusal at eris_lj.c:1491 stays verbatim.
  machine.lua fork: ZERO. Leave userdataWrapper.__gc (1124-1128) in place — it is inert on this VM, costs nothing, and keeps our fork byte-identical to upstream. Same for the sgc/sgcco block: its else branch (797-805) strips __gc, which is harmless on LuaJIT and preserves identical observable behaviour. Deleting either is optional cleanup, not part of this fix.
  our native/Java arch: the single site where we push a Value gets a Value-SPECIFIC metatable whose __gc calls Value.dispose(machine) before releasing the global ref. Stock has two push sites (ExtendedLuaState.scala:52, UserdataAPI.scala:46, both pushJavaObjectRaw); our src/ is still a two-file skeleton, so this is marginal cost on planned work. [WRONG, 2026-10-13: a Value-specific metatable would break toJavaObjectRaw; the `__gc` field of the shared jnlua.Object metatable was wrapped instead — Corrections C3.]

FOUR DETAILS TO GET RIGHT:
  1. Wrap the dispose in a catch, mirroring UserdataAPI.scala:83-85 which already swallows Throwable from dispose.
  2. Use a Value-specific metatable so other pushed Java objects are unaffected. [WRONG, 2026-10-13 — Corrections C3.]
  3. Intern Values in a host-side identity map at the push site. JNLua's pushjavaobject calls lua_newuserdata unconditionally with no interning, so one Value pushed twice yields two userdata and — because machine.lua:1174 compares by pointer with no __eq — two proxies and two disposes. That double-dispose hazard exists in STOCK OC today; (g) inherits it unchanged, but since we own the push path, interning makes us strictly safer than stock. Recommended, not required. [WRONG, 2026-10-13: the kernel merges a Value re-pushed while its proxy lives onto that proxy through JNLua's __eq, so stock does not dispose it twice for being pushed twice, and a dispose per userdata would dispose live Values; disposal is counted per Value instead — Corrections C2.]
  4. GC re-entrancy during persist is already closed by OC itself: PersistenceAPI.scala wraps persist and unpersist in lua.gc(STOP)/gc(RESTART) (125/148, 158/172); the fix arm measured 0 re-entrant firings.

ALSO DO, INDEPENDENTLY OF (g): close the AE2 iterator explicitly. (g) fixes the general case, but NetworkContents is the one leak with permanent consequences and it deserves a belt-and-braces path — dispose it when the owning machine stops, the same power-cycle hook FileSystem and InternetCard already use.

REJECTED ALTERNATIVES, with reasons: (a)/(b)/(c) all hand the sandbox a NEW finalizable userdata and hit the serializer collision head-on. (d) the weak sweep is strictly WORSE than the disease — it needs a second STRONG list of every Value handed out to diff against the weak one, pinning alive exactly the Java objects the finalizer would have released. (e) an explicit close() changes the OS-visible API. (f) dispose-at-close is not the safe fallback it looks like, since nothing disposes at close today anyway; (g) restores that for free. [WRONG, 2026-10-13: stock disposes nothing at close, and (g) as built does not either — Corrections C1.]

## The collision with persistence

RESOLVABLE — and with (g) it is not survived, it is never entered.

The collision is real and now confirmed in source, not just by experiment. p_table (eris_lj.c:1415) is the ONLY spkey call site in the serializer; case LUA_TUSERDATA (eris_lj.c:1491-1493) calls luaL_error("cannot persist userdata yet (M3)") UNCONDITIONALLY, with no metatable lookup of any kind. So __persist on a userdata's metatable is simply ignored — the fix arm verified this against a metatable demonstrably carrying it. Any mechanism that puts a NEW finalizable userdata into the sandbox's reachable graph therefore makes previously-saveable machines unsaveable. That kills (a) newproxy in userdataWrapper, (b) a newproxy sentinel field, and (c) ffi.metatype — all three.

(g) sidesteps it structurally, for three independent reasons:
  1. It introduces NO new object. The Value userdata already exists on every machine today and is already unpersistable; we attach behaviour to it, nothing more. [2026-10-13: true of the mechanism; the build also adds a raw global, `_OCLJ_VGCSTATS`, which is a new eris permanent outside the blob fingerprint — NOT YET COVERED under Corrections.]
  2. It is already hidden from the walker, twice over. The table proxy carries spkey (machine.lua:1134-1142) so p_table takes the special path and serializes the returned closure instead of walking the table's contents; and the registry itself carries spkey (machine.lua:1055-1067). The fix arm measured that spkey hides an embedded userdata as a field, as a key, and inside the metatable. The walker never reaches the userdata, so it never reaches line 1491.
  3. The round trip works structurally rather than luckily. Restore runs wrapSingleUserdata(userdata.load(className, nbt)) (machine.lua:1139-1141): the HOST mints a FRESH Value, which gets a fresh userdata and therefore a fresh C __gc. There is no disposal "record" that has to survive the blob — disposal is a property of the object the host re-creates. Measured across a full save/load with OC's real perms flattening modelled: 3 Values opened, 3 disposed, 0 live. Without the fix, the same cycle leaks one more Value per world save. [2026-10-13: true of the one-blob save we ship, not of OC's two-call save — Corrections C6.]

So the general statement "every mechanism that restores real finalization produces an object the serializer refuses" is true of every mechanism that adds an object to the SANDBOX. It is false for the one mechanism that attaches to an object living below the sandbox, in the layer we own.

## Does it change anything already decided?

NO. All three standing decisions hold, and two of them are reinforced.

USERDATA REFUSAL (eris_lj.c:1491) — UNCHANGED, and this finding is now a positive argument for keeping it. The fix costs the serializer exactly zero lines; there is no tag 14, no new shape, no persistable-userdata story. If anything the refusal is now better supported: the fix arm settled a question the census had flagged for a Java check — JNLua's pushjavaobject (jnlua.c:2076) calls lua_newuserdata unconditionally with no interning, so the same Value pushed twice yields two distinct userdata. [2026-10-13: two userdata, but one proxy — the kernel merges them through JNLua's __eq — Corrections C2.] Perms are therefore useless for Values, exactly as they are for gmatch iterators. machine.lua's table-proxy wrapping is load-bearing with no fallback beneath it — which is precisely why the fix belongs under the proxy rather than in the serializer.

"DO NOT EXPOSE newproxy" SANDBOX CONSTRAINT — UNCHANGED. This is the point where the temptation was real: newproxy(true) is the one mechanism that both works at scale (1,000,000/1,000,000 under the JIT) and cannot be detached by sandboxed code, since base setmetatable refuses userdata. We are declining it anyway, because it collides with the serializer and because (g) gets the same lifetime without exposing anything. Keep newproxy out of the sandbox. Note for the record that it remains available to US inside the host layer if a future need arises.

FFI RECOMMENDATION — UNCHANGED, with one warning worth propagating into the roadmap. ffi.metatype's __gc is reliable (1,000,000/1,000,000 under the JIT), but ffi.gc is NOT: the luajit arm measured 77 firings out of 1,000,000 with the heap flat — the cdata were freed, the finalizers silently dropped — and 1,000,000/1,000,000 with jit.off(). Anyone reaching for ffi.gc as a finalization carrier on this VM will get a mechanism that works in testing and evaporates under load. That belongs in the docs regardless of this fix.

ONE THING THAT DOES CHANGE, and it is a documentation change rather than a design change: the roadmap should stop describing sgc/sgcco (machine.lua:699-729, 776-808) as something LuaJIT breaks. It is dead on stock OC too, by shipped default (application.conf:224 allowGC:false, verified). And the finding's headline should be restated: not "every component userdata leaks host-side until the machine closes", but "sixteen dropped file handles break the file API until reboot, and AE2's ME iterator leaks a listener into the world permanently".
