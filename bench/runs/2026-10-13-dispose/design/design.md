# Value disposal on OC-LuaJIT -- design for review (2026-10-13)

Roadmap row: "Value disposal (`__gc`)" (docs/roadmap.md, search "Value disposal").
Evidence for every fact below: scratchpad/dispose/understand/*.md (six investigators + a critic, 2026-10-13).

## The defect
OC wraps each host Value (a Java object pushed as a JNLua userdata, metatable registry["jnlua.Object"]) in a TABLE
proxy (machine.lua wrapSingleUserdata); the proxy's `__gc` calls OC's `userdata.dispose(raw)` -> `Value.dispose(machine)`.
LuaJIT never finalizes tables, so on our architecture `Value.dispose` is never called. Consequences: 16 (OC default;
64 in the user's pack) file handles opened through `component.filesystem.open` directly and dropped break `open`
until reboot; AE2 `NetworkContents` iterators (one per `allItems()`) leak an ME-grid listener forever.

## Facts that shape the fix (all verified in source; see the reports)
F1. tojavaobject recognises a Java object only by rawequal(metatable, registry["jnlua.Object"]) -> a Value-specific
    metatable would break toJavaObjectRaw. Replacing a FIELD (`__gc`) of the shared table keeps recognition.
F2. JNLua's `__gc` on that table is `gcjavaobject` (C closure, upvalue false -> DeleteGlobalRef). Nothing else ever
    reads or writes that `__gc`. The same metatable also carries JavaFunction userdata (upvalues of every API
    function) and LuaError userdata (one per Java exception crossing into Lua).
F3. Every push mints a NEW userdata + global ref (no interning). The kernel dedups a re-pushed Value onto its EXISTING
    proxy through JNLua's Java `__eq` (identity-or-equals): `v == data` in wrapSingleUserdata. The new userdata is
    orphaned and dies while the Value is still live. => per-userdata disposal would dispose LIVE Values. Disposal must
    be counted: dispose only when no userdata of that Value is alive.
F4. LuaState.pushJavaObjectRaw is public synchronized, NOT final, and is the ONLY Java route into the native
    lua_pushjavaobject. OC (ExtendedLuaState.pushValue, UserdataAPI.load) and ocelot-brain push Values only through it.
F5. Stock OC does NOT dispose at lua_close: jnlua zeroes the Java luaState before lua_close, OC's dispose lambda calls
    toJavaObjectRaw outside its try, check() throws, PUC drops the error. (docs/research/gc-dispose-leak.md:55 is wrong.)
F6. Pinned LuaJIT: finalizers run on a dedicated thread VL=vmthread(g), under lj_vm_pcall, hooks off, GC threshold
    frozen; errors go to the ERRFIN vmevent (never rethrown; silent on our states); finalizers are deferred while on a
    trace. At lua_close, userdata are finalized newest-first, so every Value userdata is finalized before the API
    JavaFunctions and before the JNLUA_JAVASTATE holder. LuaJIT weak-key tables are not ephemerons: the raw userdata
    (the value in the weak-keyed wrappedUserdata) is finalized in the SECOND full cycle after its proxy dies (stock: first).
F7. The shim's per-state record M (lj52_memof(L), via lua_getallocf) is reachable from every thread of the state
    including VL, and outlives lua_close (lj52_close frees it after). M->javaref / M->envfn are set ONLY on capped
    states (limitMemory=true) -> do not rely on them.
F8. A direct JNI call from the finalizer does NOT go through calljavafunction, so jnlua's luaThread is not adjusted:
    the Java callback must take the object as an argument and touch no LuaState API.
F9. A Java exception can be pending when a GC checkpoint runs (lua_loadx's reader path); IsInstanceOf/Call* are illegal
    then. Save, clear, do the work, re-throw.
F10. Shipped save is ONE blob (LuaJITArchitecture): one userdata.load per proxy, so no two Value objects share a handle.
    OC's two-call save (dropin arm; OcljArch with OCLJ_PERSIST_BUNDLE=off) mints a second HandleValue per proxy with the
    SAME handle id; disposing that copy closes the live file (docs/shell-fill.md:381-383). The hook must never be
    active there.
F11. Only the additive variant ships; the dropin backs OC's own LuaState class and cannot carry LuaStateLuaJIT natives.

## The design
### C (native/lj52shim.c / .h), additive JNI entry, testable core
- New fields in lj52_mem: `JavaVM *vgc_vm; jclass vgc_class (global ref); jobject vgc_jstate (WEAK global ref to the
  Java LuaStateLuaJIT); jmethodID vgc_mid; int vgc_closing;` plus counters `vgc_calls, vgc_java_errors, vgc_skipped`.
- Core `int lj52_vgc_install(lua_State *L, JNIEnv *env, jobject jstate, jclass vclass)` (outside #ifdef, declared in
  lj52shim.h so a C test can drive it with a fake JNIEnv). Returns 0 or a nonzero reason code. Steps: M must exist;
  JNI part first (GetJavaVM, NewGlobalRef(vclass), NewWeakGlobalRef(jstate), GetObjectClass+GetMethodID
  "ocljValueFinalized" "(Ljava/lang/Object;)V"; on any failure release what was made and return); then the Lua part
  under lua_cpcall: rawget registry["jnlua.Object"] (must be a table), rawget its "__gc" (must be a C function); if it
  is already our wrapper, keep it; else rawset "__gc" = C closure lj52_vgc_gc with upvalue 1 = the original. One rawset,
  so `__gc` is never nil. On success, swap the new refs into M (releasing any old ones from a previous install).
  The registry key is the literal "jnlua.Object"; build-native.sh asserts jnlua.c still defines JNLUA_OBJECT so.
- Wrapper `lj52_vgc_gc(L)` (the new `__gc`): if M && M->vgc_class && !M->vgc_closing && GetEnv(vgc_vm) == JNI_OK:
  save+clear any pending exception; if IsInstanceOf(obj, vgc_class): NewLocalRef(vgc_jstate) -> if non-null,
  CallVoidMethod(jstate, vgc_mid, obj), clear (and count) any exception it leaves, DeleteLocalRef; re-throw the saved
  exception and DeleteLocalRef it. THEN ALWAYS call the original closure (upvalue 1) with the userdata (lua_call 1,0),
  which releases jnlua's global ref. Allocates nothing on the Lua side before the chain.
- lj52_close: set M->vgc_closing = 1 before lua_close (stock parity: no dispose at close); after lua_close, release
  vgc_class / vgc_jstate through GetEnv(vgc_vm) if it succeeds.
- JNI entry (additive only): `jint Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljInstallValueFinalizer(JNIEnv*,
  jobject, jclass)` -> lj52_jstate(env,obj) then the core; returns the code.
- Optional: the counters in _OCLJ_GCSTATS (vgc_calls etc.) for the harness.

### Java (native/jnlua/gen-luastate-subclass.py -> LuaStateLuaJIT.java; never hand-edited)
- `public synchronized void ocljSetValueDisposer(Class<?> valueClass, java.util.function.Consumer<Object> disposer)`:
  check(); non-null args; rc = ocljInstallValueFinalizer(valueClass); rc != 0 -> IllegalStateException naming rc;
  on success set ocljValueClass / ocljValueDisposer.
- `@Override public synchronized void pushJavaObjectRaw(Object o)`: super.pushJavaObjectRaw(o) first (if it throws,
  no userdata exists and nothing is counted); then, if ocljValueClass != null && ocljValueClass.isInstance(o): count++
  in an EQUALS-keyed HashMap<Object, Count{Object first; int n}> -- equals, not identity, because the kernel merges
  re-pushes by JNLua's identity-or-equals `__eq`; at zero we dispose `first`, the object stock would have disposed.
- `private synchronized void ocljValueFinalized(Object v)` (called only by the native wrapper, from a finalizer, on a
  thread that already holds this monitor): look up; missing -> do nothing (stock-like leak, never a premature dispose);
  decrement; at zero remove and, if isOpen(), disposer.accept(first). Catch Throwable (hashCode/equals of third-party
  classes run here).
- `private native int ocljInstallValueFinalizer(Class<?> valueClass);`

### Call sites
- LuaJITArchitecture.initialize(): right after applyForinMode(), BEFORE the kernel swap (so the stock-kernel fallback
  branch gets it too; and Machine.load runs initialize() before architecture.load, so restores are covered).
  Disposer: `v -> { try { ((Value) v).dispose(machine()); } catch (Throwable t) { LOG.warn("Error in dispose method of
  userdata of type " + v.getClass().getName(), t); } }` -- OC's own message (UserdataAPI.scala:83-85).
  Install failure (UnsatisfiedLinkError from a mismatched native, IllegalStateException): LOG.error once naming the
  consequence (dropped handles / AE2 iterators leak until reboot) and START ANYWAY -- the machine is no worse than HEAD.
- test/native/OcljArch.scala: same call after applyForinMode with classOf[totoro.ocelot.brain.entity.machine.Value] and
  ocelot-brain's machine as the Context; skipped when BundleRoots is OFF (F10) and when OCLJ_DISPOSE=off (the harness's
  negative-control switch); records whether it installed so milestones can key their expectation.

### Build gates
- build-native.sh: object-level exact-name regex + count (2 -> 3 additive, 0 dropin); export pins WANT_J/WANT_PE 89/91 ->
  90/92 (additive), dropin unchanged; regen byte-identity (automatic); a grep gate that jnlua.c defines
  JNLUA_OBJECT "jnlua.Object". Comments updated. Each changed gate shown failing on the old object (prove-it-can-fail).
- build.gradle.kts verifyModAssets: add the export name to `need`; generalise messages.
- docs/accounting-sync.md: the export counts.

### Tests
- C, JVM-free: test/native/vgc_test.c + run-vgc.sh (fake JNIEnv/JavaVM tables), checks:
  V1 Value finalized -> one callback, BEFORE the original gc, original once; V2 non-Value -> no callback, original once;
  V3 lj52_close -> no callback for live Values, original runs for each, refs released once after close;
  V4 pending exception at finalize -> no JNI call while pending, callback made, same exception re-thrown;
  V5 callback leaves an exception -> cleared, counted, original still runs; V6 install twice -> one wrapper level;
  V7 no jnlua.Object -> error code, metatable untouched, no refs leaked; V8 GetEnv fails -> no callback, original runs.
  negative-control.sh sabotages: drop the chain; drop the closing check; drop the exception save; drop the class filter
  -- each with its exact expected failing-id set.
- JVM private-state probe in OcljSmoke (additive arm, acc-6 style, real jnlua + our DLL): CountingValue / EqValue
  classes; duplicate push keeps the Value alive; N distinct -> N disposes; equal-but-distinct -> one dispose, of the
  first; non-Values and LuaErrors -> none; K live at close() -> none, no crash.
- Machine milestones (ocelot-brain, dedicated second HDD so a HEAD failure cannot cascade into stk):
  gc-1 live: open until refused (expect maxHandles=16), drop, let the kernel's own every-10th-iteration full collects
  run (two needed on LuaJIT; a weak-value witness proves cycles ran), reopen must succeed and the filesystem's owners
  set must return to 0; same nonce, machine running. gc-2 restored: hold the handles across f1's save, drop on the
  restored machine, owners 16 -> 0. Expectations two-sided per arm: additive PASS; stock PASS; dropin LEAK (permanent
  same-DLL control); additive with OCLJ_DISPOSE=off -> "-NEGATIVE-CONTROL", LEAK.
  Fail-first: run gc-1/gc-2 on HEAD's build before the fix and keep the log.
- Full 5-arm suite after: no regression against 66/63/64/60/47 (+ the new checks).

## Deliberate non-goals / differences from stock (to document)
- No dispose at lua_close (parity). AE2 iterators alive at shutdown/unload leak on stock too.
- Disposal lands one GC cycle later than stock (F6).
- A Value pushed but never wrapped (error between push and wrap) is disposed; stock leaks it.
- A raw userdata left in a user table by unwrapUserdata's in-place rewrite keeps its Value alive until that table dies
  (stock disposes when the proxy dies, under the user's feet).
- User-defined table __gc (allowGC=true packs) stays unsupported: LuaJIT finalizes no table.
- Dropin arm keeps the leak (it never ships).
