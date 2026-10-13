# Value disposal on OC-LuaJIT -- design v2 (2026-10-13), the implementation contract

v1 is design.md (same dir). The four-lens review and its skeptic checks are in review/findings.md; v2 adopts
C1-C5, OC-1..OC-4, J1-J7, T1-T13 as stated below. Facts F1-F11 of v1 still hold; read v1's "Facts" section first.

## Summary of the mechanism (unchanged in shape)
The shim replaces the `__gc` field of JNLua's shared Java-object metatable (registry["jnlua.Object"]) with a C wrapper
that, for a finalized userdata whose Java object is an instance of a Java-supplied Value class, calls back into the
generated LuaStateLuaJIT; Java counts live userdata per Value (by IDENTITY) and disposes at zero. The wrapper always
chains to JNLua's original gcjavaobject. No dispose during lua_close (stock parity). Additive variant only.

## 1. C -- native/lj52shim.c / lj52shim.h  (owner: implementer A)
Header additions (lj52shim.h, near the accounting cores' declarations, jni.h is already included there):
```c
#define LJ52_JNLUA_OBJECT "jnlua.Object"   /* must equal jnlua.c's JNLUA_OBJECT; build-native.sh asserts it */
enum {                                    /* lj52_vgc_install's codes; 0 = installed */
  LJ52_VGC_OK = 0, LJ52_VGC_ENORECORD = 1, LJ52_VGC_EJVM = 2, LJ52_VGC_EREF = 3, LJ52_VGC_EMETHOD = 4,
  LJ52_VGC_ENOMT = 5, LJ52_VGC_ENOGC = 6, LJ52_VGC_ELUA = 7
};
int  lj52_vgc_install(lua_State *L, JNIEnv *env, jobject jstate, jclass vclass);
void lj52_vgc_counters(lua_State *L, long long out[5]); /* calls, jerr, closing, noenv, installed(0/1); zeros if no record */
```
- lj52_mem gains: `JavaVM *vgc_vm; jclass vgc_class; jobject vgc_jstate; jmethodID vgc_mid; int vgc_closing;`
  and counters `long long vgc_calls, vgc_jerr, vgc_skip_closing, vgc_skip_noenv;`.
- lj52_vgc_install: M = lj52_memof(L) (ENORECORD if NULL). JNI part FIRST: GetJavaVM; NewGlobalRef(vclass);
  NewWeakGlobalRef(jstate); c = GetObjectClass(jstate); GetMethodID(c, "ocljValueFinalized", "(Ljava/lang/Object;)V");
  DeleteLocalRef(c). On any failure: ExceptionClear(), release what was made, return the step's code (C2) -- Java
  must always see the code, never a pending exception. Then the Lua part, STACK-NEUTRAL (C1):
  `int top = lua_gettop(L); int st = lua_cpcall(L, lj52_vgc_install_p, NULL); lua_settop(L, top);`
  The protected function NEVER raises for a validation failure: it rawgets registry[LJ52_JNLUA_OBJECT] (not a table ->
  stores ENOMT in a static/M field and returns 0), rawgets its "__gc" (not a C function -> ENOGC); if
  lua_tocfunction(__gc) == lj52_vgc_gc it is already installed (keep it); else pushes lua_pushcclosure(lj52_vgc_gc, 1)
  with upvalue 1 = the original and does ONE lua_rawset of "__gc" (never nil in between). cpcall failing (memory) ->
  ELUA. On ELUA/ENOMT/ENOGC release the new refs. On success swap the new refs into M, releasing previous ones (a
  second install replaces the class/state refs; the wrapper level stays one).
- lj52_vgc_gc (the new __gc): if M && M->vgc_class && !M->vgc_closing: GetEnv(M->vgc_vm, &env, JNI_VERSION_1_6)
  (!= JNI_OK -> vgc_skip_noenv++, skip); jthrowable pend = ExceptionOccurred; if pend ExceptionClear;
  obj = *(jobject *)lua_touserdata(L, 1); if obj && IsInstanceOf(obj, vgc_class): js = NewLocalRef(vgc_jstate);
  if js: CallVoidMethod(js, vgc_mid, obj); if ExceptionCheck -> ExceptionClear, vgc_jerr++; DeleteLocalRef(js);
  vgc_calls++. Then if pend: Throw(pend); DeleteLocalRef(pend). If closing: vgc_skip_closing++ (only for Values:
  do the IsInstanceOf? NO -- at close do no JNI at all; count every jnlua.Object finalization skipped).
  THEN ALWAYS: lua_pushvalue(L, lua_upvalueindex(1)); lua_pushvalue(L, 1); lua_call(L, 1, 0); return 0.
  No Lua allocation before the chain. Hooks/threshold are LuaJIT's business (finalizers run hook-free).
- lj52_close: if M: `M->vgc_closing = 1;` BEFORE lua_close (with the existing watchdog stop / accounting off); AFTER
  lua_close, if M->vgc_vm: GetEnv; if JNI_OK DeleteGlobalRef(vgc_class), DeleteWeakGlobalRef(vgc_jstate).
- JNI entry inside `#ifdef LJ52_ADDITIVE`:
  `JNIEXPORT jint JNICALL Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljInstallValueFinalizer(JNIEnv *env,
   jobject obj, jclass vclass)` -> L = lj52_jstate(env, obj); L NULL -> ENORECORD; else lj52_vgc_install(L, env, obj,
  vclass). And `JNIEXPORT void JNICALL ..._ocljValueGcCounters(JNIEnv*, jobject, jlongArray out)` filling 5 longs
  from lj52_vgc_counters (for the harness). So the additive build exports FOUR oclj natives (2 old + 2 new).
- _OCLJ_GCSTATS gains `vgc_calls`, `vgc_jerr`, `vgc_closing`, `vgc_noenv`, `vgc_installed` (append; do not reorder).
- Long WHY comment in the house style (CAPS heads), citing the facts (F1-F10) with file:line, the stock-parity close
  decision, and docs/research/gc-dispose-leak.md.

## 2. Build gates -- native/build-native.sh, build.gradle.kts, docs/accounting-sync.md  (owner: implementer A)
- build-native.sh: assert `#define JNLUA_OBJECT "jnlua.Object"` in the jnlua checkout (fail message in house style);
  object-level exact-name regex adds ocljInstallValueFinalizer|ocljValueGcCounters (additive 4, dropin 0); export pins
  WANT_J/WANT_PE 89/91 -> 91/93 (additive), dropin unchanged; update every comment that states counts.
  Also nm must find the cores lj52_vgc_install/lj52_vgc_counters in every build (like the accounting cores).
- build.gradle.kts verifyModAssets `need`: add the two names; generalise messages ("the four oclj exports").
- docs/accounting-sync.md: the export counts.

## 3. Java -- native/jnlua/gen-luastate-subclass.py -> LuaStateLuaJIT.java  (owner: implementer C)
Never hand-edit LuaStateLuaJIT.java; edit the generator, run it (`python3 native/jnlua/gen-luastate-subclass.py
C:/Users/astro/Downloads/OC-JNLua src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java`), and confirm the
build's regen byte-identity would pass (re-run into a temp file and cmp). Members (all emitted by the generator):
```java
// public API
public synchronized void ocljSetValueDisposer(Class<?> valueClass, java.util.function.Consumer<Object> disposer)
    // !isOpen() -> IllegalStateException (use isOpen(), NOT the package-private check(): J4); null args -> NPE;
    // rc = ocljInstallValueFinalizer(valueClass); rc != 0 -> IllegalStateException("... code " + rc + " (<name>)");
    // only then set ocljValueClass / ocljValueDisposer.
public synchronized boolean ocljValueDisposalInstalled()
public synchronized long[] ocljValueStats()   // Java side: {counted, finalized, disposed, missing, mergedSkips,
                                              //  unlocked, disposeErrors, refusedInDispose, live entries}
public synchronized long[] ocljValueGcCounters()  // native side via ocljValueGcCounters(long[5])
// overrides
@Override public synchronized void pushJavaObjectRaw(Object object)
@Override public synchronized void pushJavaFunction(JavaFunction f)   // J5 (check JNLua's exact signature/finality)
@Override public synchronized void close()   // super.close(); if !isOpen(): clear the map, drop disposer/class (J6)
// callback, called ONLY by the native __gc wrapper
private void ocljValueFinalized(Object value)  // NOT synchronized (J3)
private native int ocljInstallValueFinalizer(Class<?> valueClass);
private native void ocljValueGcCounters(long[] out);
```
Counting (J1/OC-2/OC-3/J2/C3/J7):
- `IdentityHashMap<Object,int[]> ocljLive` -- identity only; no Value code (hashCode/equals) ever runs at push.
- push override (both): if ocljInDispose -> throw IllegalStateException("a Value's dispose may not push into Lua")
  (J7). If ocljValueClass != null && isInstance(o): PRE-increment (created = entry was absent); then
  `try { super.push...(o); } catch (Throwable t) { roll back: --n; if n==0 { remove; if (!created && isOpen())
  dispose(o); } throw t; }`. Bookkeeping itself inside try/catch(Throwable): on failure leave the object uncounted
  (its finalization then finds no entry -> no dispose: a stock-like leak, never premature).
- ocljValueFinalized(v): `if (!Thread.holdsLock(this)) { unlocked++; return; }` (J3: a leak, never a deadlock);
  look up; missing -> missing++, return; --n > 0 -> return; remove; if !isOpen() return; if v's class overrides
  Object.equals (per-class cache: getMethod("equals", Object.class).getDeclaringClass() != Object.class) and any
  OTHER live counted object o whose class overrides equals satisfies o.equals(v) (kernel's merge direction:
  existing.equals(new)) or equals throws -> mergedSkips++, return (degrade to leak, never premature: J1/OC-4/T12).
  Else dispose(v). Everything in try/catch(Throwable).
- dispose(v): ocljInDispose = true; try { disposer.accept(v); disposed++; } catch (Throwable t) { disposeErrors++; }
  finally { ocljInDispose = false; }  (the disposer passed by the architecture logs; LuaStateLuaJIT has no logger).
- Generated Javadoc states the contract: the disposer runs inside a LuaJIT finalizer on the thread that holds this
  monitor, with no Lua hooks, and must not touch this LuaState (pushes are refused while it runs).

## 4. Java call sites -- LuaJITArchitecture.java  (owner: implementer C)
- initialize(): right after applyForinMode(), before the kernel swap:
  ```java
  try {
      ((LuaStateLuaJIT) lua()).ocljSetValueDisposer(Value.class, v -> {
          try { ((Value) v).dispose(machine()); }
          catch (final Throwable t) { LOG.warn("Error in dispose method of userdata of type " + v.getClass().getName(), t); }
      });
  } catch (final Throwable t) {   // C2/J4: LinkageError, IllegalStateException, OOM ... -- START ANYWAY, loudly
      LOG.error("Value disposal could not be installed ... dropped file handles and AE2 iterators will leak until reboot ...", t);
  }
  ```
  (exact names/types: Value = li.cil.oc.api.machine.Value; Context = machine(); check what `machine()` returns.)
- save(): OC-1 -- after the existing single `lua.gc(COLLECT, 0)` (LuaJITArchitecture.java ~:536) add a SECOND
  COLLECT inside the same try, with a comment: LuaJIT's weak-key tables are not ephemerons, so a proxy that died
  before the save frees its Value userdata only in the NEXT full cycle; without the second collect a Value dead at an
  unload save is never disposed (no dispose at close), where stock disposes it in that save's collect.
- Long WHY Javadoc in house style.

## 5. Harness -- test/native/OcljArch.scala, OcljSmoke.scala, smoke-test.sh  (owner: implementer D)
- OcljArch.initialize: after applyForinMode, before the swap: decide `disposeExpected = bundleRoots ON &&
  env OCLJ_DISPOSE != "off"`. If expected, call ocljSetValueDisposer REFLECTIVELY (getMethod on the LuaState's class)
  with classOf[totoro.ocelot.brain.entity.machine.Value] and a disposer calling `v.asInstanceOf[Value].dispose(machine)`
  inside try/catch that prints a SMOKE-visible warning. Record `disposeInstalled` (true only on success) and
  `disposeError` (the throwable's class+message). Reflection so the SAME harness compiles and runs against HEAD's
  LuaStateLuaJIT (T1). OcljArch.save: the same second COLLECT as the mod (OC-1).
- Milestones -- expectations keyed on CONFIG (nativeMode, OCLJ_DISPOSE, BundleRoots), NEVER on the outcome (T1):
  * gc-0-value-disposer-installed (additive): installed == expected; detail names disposeError on failure.
  * vd-* private-state probe (additive; acc-6 style, `new LuaStateLuaJIT(cap)` CAPPED like a machine, real DLL),
    installed reflectively; CountingValue (counts dispose) and EqValue (overrides equals by id). Cases, each its own
    milestone id or one composite with per-case reasons:
    vd-1 kernel-shape merge (T3): on the private state run Lua that mirrors the kernel: a weak-key `wrapped` table,
      wrap(data) scanning `v == data` (JNLua __eq) and returning the existing proxy, and an echo JavaFunction (pushes
      its argument back via pushJavaObjectRaw). Wrap a CountingValue, echo it 3x through wrap(), keep the proxy,
      collect x3 -> 0 disposes; drop the proxy, collect x3 -> exactly 1 dispose.
    vd-2 N distinct dropped -> N disposes; non-Values (a String pushed raw, LuaErrors from a throwing JavaFunction,
      JavaFunctions) -> 0 disposes.
    vd-3 equals-overriding EqValue a, b (a.equals(b)): simultaneous (b merged onto a's proxy) -> at most ONE dispose
      total when everything dies, never while a's proxy lives; sequential case recorded with its outcome (T12).
    vd-4 close: K live CountingValues, then close() -> 0 disposes, no crash; vgc counters show closing skips.
    vd-5 failure path (T6): install on a state whose registry["jnlua.Object"].__gc was replaced by a Lua function
      via the C API? If not reachable from Java, cover in the C test only and say so.
    vd-6 lock guard (J3): call ocljValueFinalized reflectively from a thread NOT holding the monitor -> no dispose,
      unlocked counter 1.
  * gc-1 / gc-2 machine milestones on a DEDICATED second HDD (hdd2: fresh temp dir with one probe.txt, no autorun),
    ONE hold, TWO drops (T2): before f1, sandbox opens hdd2's probe.txt until refused (bounded 64) and keeps the
    handles; assert held == owners(hdd2, machine) == maxHandles and the refusal text. f1 persists them.
    gc-2 (restored): inside the restore block, while ws2 ticks, drop ws2's copy; gc-1 (live): after the restore
    block and before fi, drop the original's copy. Each asserts its own precondition on ITS OWN FileSystem instance
    (assert ws2's hdd2 FileSystem is not ws's). Bystander (T3): drop all but ONE handle; after the drop/collect window
    the kept handle must still read (seek 0 + read) and owners == 1; then close it -> owners == baseline (0).
    Witness (T8): registry-shaped weak-key table captured as an UPVALUE of the step closure plus a plain one-cycle
    twin; record both clear steps; then a bounded JAVA poll (ticks) for owners == 1 (bystander) after the witness
    clears, reporting the lag; forced GC never from Scala on the asserted path. Same nonce, running, no lastError.
    Expectations: additive (dispose on, bundle on) DISPOSED; stock DISPOSED; dropin LEAK (permanent same-DLL control,
    id suffix per the stk convention); additive OCLJ_DISPOSE=off -> id "-NEGATIVE-CONTROL", LEAK; additive with
    OCLJ_PERSIST_BUNDLE=off -> LEAK (not installed by config).
    OC-1 check gc-3 (save boundary): drop N handles and save at once with no kernel resume in between; assert owners
    for the machine reach baseline AFTER ws.save and BEFORE any stop (fails on a single-COLLECT save).
- smoke-test.sh: pass OCLJ_DISPOSE through; document it next to OCLJ_PERSIST_BUNDLE.
- Keep existing milestones' expectations unless the hdd2 addition forces a change; f1b's needle note (T10).
- New CHECKS baselines per arm must be stated in the final report (T7).

## 6. C test -- test/native/vgc_test.c, run-vgc.sh, negative-control.sh  (owner: implementer B)
JVM-free; links lj52shim.o + libluajit.a like mem_test/wd_test (see run-mem.sh/run-wd.sh for the per-platform layout).
A fake JNIEnv/JavaVM (a filled `struct JNINativeInterface_` / `JNIInvokeInterface_`) with: GetEnv, GetJavaVM,
NewGlobalRef/DeleteGlobalRef, NewWeakGlobalRef/DeleteWeakGlobalRef, NewLocalRef/DeleteLocalRef, GetObjectClass,
GetMethodID, IsInstanceOf, CallVoidMethod (variadic/V/A as the shim uses), ExceptionOccurred/ExceptionCheck/
ExceptionClear/Throw -- each RECORDING calls into a log with a "pending exception" state, and FAILING the test if any
non-whitelisted JNI function is called while an exception is pending (T5), and tracking live global/weak/local refs
(leak = failure). Fake jobjects are tagged pointers (Value / non-Value). The test builds jnlua's setup itself:
registry[LJ52_JNLUA_OBJECT] = { __metatable=false, __gc = counting fake gcjavaobject C closure with upvalue false },
and a JAVASTATE-like holder if the shim needs it.
Checks (ids stable, each one assertion family): V1 Value -> one callback BEFORE the original gc, original once;
V2 non-Value -> no callback, original once; V3 lj52_close -> no JNI call during close for live Values, original runs for
each, class/state refs released exactly once after close; V4 pending exception at finalize -> no illegal call while
pending, callback made, the SAME exception re-thrown; V5 callback leaves an exception -> cleared, jerr++, original
still runs; V6 install twice -> one wrapper level; V7 no jnlua.Object / __gc not a C function -> right code, metatable
untouched, refs released, lua_gettop unchanged (C1), no pending exception; V8 GetEnv fails -> no callback, original
runs; V9 JNI step failures (GetMethodID NULL with pending NoSuchMethodError; NewWeakGlobalRef NULL) -> right code,
exception cleared, refs released; V10 under the shim's armed emergency collector, many finalizations in one checkpoint
-> no local-ref growth (C5); V11 dispose counter == finalized Values.
negative-control.sh: one sabotage per guard (T4), each with its EXACT expected failing id set written down: drop the
chain; drop the closing check; drop the exception save/rethrow; drop the class filter; drop the settop; drop the
ExceptionClear on install failure; drop DeleteLocalRef(js). Positive control first, as the file already does.

## Deliberate non-goals / differences from stock (to document in the roadmap row and the results note)
- No dispose at lua_close (parity, F5). AE2 iterators alive at shutdown/unload leak on stock too.
- Disposal lands one GC cycle later than stock; the save's second COLLECT restores "dead at the save is disposed".
- A Value pushed but never wrapped (error between push and wrap) is disposed; stock leaks it.
- A raw userdata left in a user table by unwrapUserdata's in-place rewrite keeps its Value alive until that table dies.
- Third-party Values overriding equals: when an equal live Value exists at zero, dispose is skipped (leak, never
  premature); the sequential equal case can therefore leak where stock disposes.
- User-defined table __gc (allowGC=true packs) stays unsupported. Dropin arm keeps the leak (never ships).
