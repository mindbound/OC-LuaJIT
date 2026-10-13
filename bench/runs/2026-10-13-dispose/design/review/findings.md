# LENS: C side and JNI correctness: the wrapper's JNI sequence, the install's lua_cpcall, lj52_close ordering, the original-__gc chain on VL, the shim's GC/accounting/w

## C1 [major] When the install's lua_cpcall fails, it leaves its error object on the main thread's stack. Under the design's 'START ANYWAY', the kernel swap then pops that object instead of OC's kernel thread. The machine runs OC's stock kernel or dies on an assertion, which contradicts 'no worse than HEAD'.

SCENARIO: The install runs after super.initialize() has left OC's kernel thread at index 1. Its protected function fails in one of three ways: the design's own 'jnlua.Object not a table / __gc not a C function' check raises via lua_error (exactly the V7 path), lj_func_newC or lua_pushcclosure hits ERRMEM, or a non-NULL ud overflows GC64 lightud segments (BADLU). LuaJIT unwinds the FRAME_CP, copies the error to the old top and sets top+1, so the stack is [OC kernel thread, err]. Java sees rc != 0, logs, and starts anyway. LuaJITArchitecture.initialize's lua().pop(1) then removes err, and load+newThread put the patched thread at index 2. runThreaded resumes index 1, i.e. OC's stock kernel, which the code's own comment says fails after one tick. The first synchronized call then trips assert(lua.getTop == 2) on [thread, thread, fn]. In the no-patched-kernel fallback, the stack [thread, err] hits the same assertion. The harness swap is identical. Likelihood: ERRMEM is near-impossible at initialize (OC creates the state with cap Int.MaxValue), so the realistic triggers are a changed JNLua or a pointer ud. V7 exercises the failure path but does not check the stack.

CHANGE: Make the core stack-neutral on every path: `int top = lua_gettop(L); st = lua_cpcall(L, lj52_vgc_install_p, NULL); lua_settop(L, top);`. Pass ud = NULL: the protected function needs no JNI data and can reach M through lj52_memof(L). Have the protected function report validation failures with a normal return plus a code in M (or a static), never lua_error. Extend V7, and add a forced-refusal install case, to assert lua_gettop is unchanged. Add 'drop the settop' to negative-control.sh.

CHECK: real=False sev=not-real
  reasoning: The mechanism C1 describes is correct, but nothing on this codebase can trigger it.

WHAT HOLDS:
- A failed lua_cpcall does leave its error object on the stack.
  - If the protected function raises, err_unwind hits FRAME_CP and unwindstack copies the error to the old top, then sets top+1 (prototype/watchdog/luajit/src/lj_err.c:98-105, :161-165).
  - If the cp helper raises first (lj_func_newC, or lj_lightud_intern at lj_api.c:1142/1148), vm_cpcall's negative SAVE_NRES (vm_x64.dasc:663-667) takes the nres<0 branch (lj_err.c:115-122). The error lands in the same place.
- The design never says the error object is popped: design.md:51-55 covers only releasing the refs, and V7 (design.md:106) does not check gettop.
- C1 traces the consequences correctly:
  - The install runs after applyForinMode (design.md:83; LuaJITArchitecture.java:151).
  - lua().pop(1) at :170 would then drop the error, not OC's thread, leaving [OC thread, patched thread].
  - runThreaded resumes index 1 (NativeLuaArchitecture.scala:197,209), and runSynchronized asserts getTop==2 (:174).
  - The fallback return at :166 and the harness swap at OcljArch.scala:116-118 behave the same way.

WHY IT CANNOT OCCUR. The only path that leaves an error on the stack is a failure inside the cpcall, and none of the three triggers is reachable:
1. **Validation failure (the V7 path).**
   - newstate_protected creates registry["jnlua.Object"] and sets its __gc to the C closure gcjavaobject (build/native/jnlua-luajit.c:222-227) before any other code runs.
   - F2 (design.md:16-18) finds nothing else that writes it.
   - Each initialize() works on a fresh state from factory.createState (NativeLuaArchitecture.scala:310-314), so even restores reach the install with an untouched table.
   - A future JNLua change would not ship silently: the design's grep gate (design.md:95-96) and the OcljSmoke probe would both catch it. The probe expects disposes (design.md:109-111) and would get an IllegalStateException instead.
2. **ERRMEM.**
   - At initialize the cap is Int.MaxValue: LuaStateFactory.scala:353 -> LuaJITStateFactory.java:83 -> LuaStateLuaJIT.java:36-41.
   - The protected function allocates a few dozen bytes, so only a failure of the OS malloc could raise ERRMEM, and then the JVM is already failing.
3. **BADLU.**
   - The segment table holds at most 254 segments (lj_udata.c:49-50).
   - Each segment covers 2^39 bytes (lj_obj.h:296-297).
   - A fresh state cannot fill 254 of those, so any ud pointer is safe.

The install failures that can actually happen leave the stack unchanged, so 'START ANYWAY, no worse than HEAD' holds for them:
- UnsatisfiedLinkError: the native never runs.
- JNI-part failures: the design does those first, before the cpcall (design.md:51-52).

Severity: no shipped or harness scenario corrupts the stack, so this is not real. It does point at a cheap hardening that matches the standard lua_cpcall contract.

ON THE PROPOSED CHANGE: the settop is the right core and is enough on its own; the rest is redundant or contradictory.
- With settop in place, 'ud = NULL' and 'never lua_error' are redundant.
- Worse, 'never lua_error' combined with the 'drop the settop' negative control produces a check that cannot fail:
  - If validation returns normally, V7 never leaves an error object.
  - So a V7 that checks gettop would still pass with the settop removed.
  - That is exactly what the project's prove-it-can-fail rule forbids.

Side note, outside C1: if GetMethodID fails, the NoSuchMethodError it leaves pending reaches Java as an Error. The call-site catch (design.md:87) names only UnsatisfiedLinkError and IllegalStateException, so it would not catch it. This is also unreachable, because the generator emits the method and the native together.
  better: This is optional hardening, not a fix for a reachable bug. In the core, record the stack top before the cpcall and restore it after: `int top = lua_gettop(L); int st = lua_cpcall(L, lj52_vgc_install_p, ud); lua_settop(L, top);`. Map st, or a code the protected function left, to the return value.

Keep raising validation failures with lua_error inside the protected function. Then V7 really leaves an error object, and V7 can assert that lua_gettop is unchanged.

Add 'drop the settop' to negative-control.sh with expected failing set {V7}. That sabotage can fail only because V7 raises.

Do not adopt 'ud = NULL' or 'never lua_error'. They add nothing once the settop is there, and 'never lua_error' makes the proposed negative control impossible to fail.

## C2 [minor] A failure in the install's JNI part leaves a pending Java exception, so Java never sees the return code. A NoSuchMethodError then escapes the planned catch list (UnsatisfiedLinkError | IllegalStateException), and the machine fails to start instead of starting anyway. No gate ties the C method-name and signature literals to the generated Java.

SCENARIO: GetMethodID(ocljValueFinalized, (Ljava/lang/Object;)V) fails, e.g. after a rename in gen-luastate-subclass.py without a matching edit in lj52shim.c, or a stale DLL against a newer jar that still declares the native. The JNI spec leaves NoSuchMethodError pending (NewGlobalRef/NewWeakGlobalRef likewise leave OutOfMemoryError). The native returns its code, the JVM throws the pending Error at the native's return, and ocljSetValueDisposer never reaches its rc check. NoSuchMethodError is a LinkageError but not an UnsatisfiedLinkError, so LuaJITArchitecture.initialize() propagates it.

CHANGE: In the core, call ExceptionClear before returning each nonzero code, with a distinct code per step, so Java always sees rc. At the call site, catch LinkageError | RuntimeException. Add a build-native.sh grep, or extend the OcljSmoke reflection check, asserting that the generated class declares `private synchronized void ocljValueFinalized(Object)` and that the shim carries the same name and signature literals.

CHECK: (minor, not checked)

## C3 [minor] jnlua's push runs a GC checkpoint, and with it finalizers, INSIDE super.pushJavaObjectRaw, before the design's count++. A re-push of a Value whose last userdata is dead but not yet finalized can therefore dispose it and then count it live again.

SCENARIO: Value v's proxy has died and its userdata u1 is awaiting its second-cycle finalization. A driver returns the cached v again. The override calls super.pushJavaObjectRaw(v). pushjavaobject_protected -> lua_newuserdata runs lj_gc_check first, which can finalize u1: ocljValueFinalized drops the count 1 -> 0, disposes v and removes the entry. The push then completes and count++ creates a fresh entry {first=v, n=1} for a disposed v that now has a live userdata and proxy. This is no worse than stock, which disposed v when the proxy died, but it is avoidable, and the design's invariant 'count = live userdata' does not hold across the push.

CHANGE: Pre-count: increment the entry before super.pushJavaObjectRaw. If super throws, decrement, dispose at zero if isOpen(), and rethrow. This is correct because a throw means no userdata got the jnlua.Object metatable (setmetatable is pushjavaobject's last step), given C's V4/V5 guarantee that the wrapper never leaks an exception into the outer native.

CHECK: (minor, not checked)

## C4 [minor] The design does not fix the JNI version passed to GetEnv. Any constant above what the running JVM supports makes the wrapper skip every callback silently, and the fake-JNIEnv tests cannot notice.

SCENARIO: An implementer writes GetEnv(vgc_vm, &env, JNI_VERSION_10), or any 9+ constant. Minecraft 1.12.2 runs on Java 8, where GetEnv returns JNI_EVERSION. Every finalizer then takes the V8 'GetEnv fails' path: the original still runs, no Value is ever disposed, and the leak looks like HEAD. lj52_close's after-close release likewise leaks both refs per machine.

CHANGE: Specify JNI_VERSION_1_6, the same as jnlua's JNLUA_JNIVERSION, for every GetEnv in the wrapper and in lj52_close. Have the JVM private-state probe also assert that vgc_calls > 0 after a disposal, so a silent always-skip fails the run.

CHECK: (minor, not checked)

## C5 [minor] The prove-it-can-fail set misses the two most dangerous C-side mistakes, and the fake JNIEnv as described cannot catch reference misuse. An armed shim collection runs whole cycles at one checkpoint, so many wrapper calls share ONE outer native frame.

SCENARIO: (a) Calling the original BEFORE the callback makes IsInstanceOf and CallVoidMethod use an obj that was just passed to DeleteGlobalRef. This is a JVM crash in production, but it passes with a fake env that does not track ref liveness. (b) Dropping the re-throw is asserted by V4 but has no sabotage. (c) A per-call local-ref leak from ExceptionOccurred or NewLocalRef accumulates across thousands of finalizers in one jnlua native frame while the collection is armed (stepmul 0), and no test counts locals.

CHANGE: Have the fake env track the liveness of each obj's global ref, failing any JNI use of a deleted ref, and keep a live-local-ref counter that must return to its baseline after every finalizer and after the install. Add the sabotages 'original before callback' and 'drop the re-throw', each with its exact expected failing-id set.

CHECK: (minor, not checked)

# LENS: OpenComputers semantics, persistence and the kernel: premature dispose and leaks of a Value's userdata count across wrap/dedup/unwrap, unpersist, save-time coll

## OC-1 [major] At the save-then-close boundary, the one-cycle lag turns into never disposing. A Value whose proxy dies shortly before an unload save is never disposed, although stock disposes it in that save's COLLECT. The design accepts 'one GC cycle later than stock' (design.md:123), but the close guards (design.md:62 vgc_closing; :77-78 isOpen) mean that a cycle which never runs never disposes.

SCENARIO: 1. An OpenOS program polls an ME controller (for each pass: iterate me.allItems(), then os.sleep(1)), so each NetworkContents proxy dies right after use. The kernel collects every 10 resumes (build/native/kernel/machine.lua:1631-1636).
2. The player walks away and the chunk unloads. Computer.writeToNBTForServer calls machine.save (Computer.scala:168-172), which reaches LuaJITArchitecture.save's single lua.gc(COLLECT) (:536). In the same tick, onChunkUnload closes the state (understand/lifecycle.md:45-55).
3. Stock PUC: luaC_fullgc separates the dead proxies in that cycle and runs their __gc at lgc.c:1215, so NetworkContents.dispose sets valid=false.
4. Pinned LuaJIT: weak-key values are marked (lj_gc.c:214-217). That COLLECT therefore only clears the wrappedUserdata entries. The raw userdata are still pending at lua_close, where vgc_closing skips them, and they are never disposed.
5. Every unload therefore leaks the ~10 iterators dropped since the previous kernel collect. Each one is an AE2 listener that re-sorts the full item list on every grid change and has no backstop (NetworkControl.scala:307-311, :634-640). Stock leaks none of them.
6. Block break, shutdown, reboot and crash also lose one more kernel cycle's worth of Values than stock.

CHANGE: - Add a second lua.gc(COLLECT, 0) right after LuaJITArchitecture.java:536, and after OcljArch.scala:353, inside the same try. This restores stock's 'everything dead at the save is disposed' for the cost of one more full GC per machine per autosave.
- Optional, and goes beyond stock: a close() override that lifts the cap and runs COLLECT twice before super.close(). It costs nothing on autosaves and also covers shutdown, reboot, crash and block break.
- List the boundary in the design's non-goals.
- Must-fail check: drop N handles, save at once with no kernel resumes in between, and assert that the live FS's owners for that machine are 0 BEFORE stop or close (the stop and disconnect backstops would mask it afterwards). This fails on the single-COLLECT build.

CHECK: real=True sev=major
  reasoning: I tried to refute this from source and could not.

**The chain holds.**
1. Chunk unload saves before it closes, and no Lua runs in between. The order is Chunk.onChunkUnload, then safeSaveChunk, then a later updateEntities, then TE.onChunkUnload, dispose, node.remove and Machine.close. Machine.save pushes Paused. See understand/lifecycle.md:45-58.
2. Our save does one full cycle. persist() stops the GC and restarts it (oc-1.12.58-src/.../PersistenceAPI.scala:125,148), so no cycle completes during the persist. Then a single `lua.gc(COLLECT)` runs (LuaJITArchitecture.java:536; OcljArch.scala:353).
3. That COLLECT is exactly one mark cycle. lj_gc_fullgc either finishes the in-flight sweep or discards a partial mark, then runs one cycle and its finalizers (prototype/watchdog/luajit/src/lj_gc.c:781-803).
4. Weak-key values are marked strongly (lj_gc.c:214-216). So the cycle in which a proxy dies only clears the wrappedUserdata entry, and the raw udata survives it.
5. Close runs every finalizer, and the design skips them. jnlua's lua_close is lj52_close (native/lj52shim.h:252). The design sets vgc_closing there (design.md:62) and also checks isOpen() (design.md:77-78).
6. Stock disposes these Values in that same save. The proxy is a table with `__gc` (oc-1.12.58-src/assets/opencomputers/lua/machine.lua:1124-1128). The save's COLLECT comes after the persist (NativeLuaArchitecture.scala:421), and PUC fullgc runs pending finalizers.

**Probes on the pinned luajit.**
- The reviewer's boundary2.lua prints `SKIPPED-at-close:A-one-collect`.
- My review-skeptic/twocollect.lua shows that two save collects dispose in every case: GC idle, mid-propagate and late-cycle. One collect taken mid-cycle is still skipped at close.

**The finding overstates one part.** The internal-HDD file-handle part is parity with stock. Computer.writeToNBTForServer calls super first (traits/Computer.scala:168-172). That super is Inventory.writeToNBTForServer, then save(nbt) (traits/Inventory.scala:23-25), then ComponentInventory.save, then saveComponents (inventory/ComponentInventory.scala:102-105). So the FS writes its owners (FileSystem.scala:321-336) before machine.save's COLLECT. Stock also persists a dropped-but-unfinalized handle as open.

**What genuinely diverges** is the live Java side effects. The clearest one is AE2 NetworkContents:
- `addListener` at :611
- `toSorted` on every change at :605, :642-648
- the only off-switch is `valid` at :634-640

The finding's `NetworkControl.scala:307-311` cites the subscription onDisconnect, which is the wrong code.

**Scale.** Each unload loses the Values dropped since the last completed cycle (the kernel collects every 10 resumes: build/native/kernel/machine.lua:1631-1636). Stock loses none of these. design.md:123 ("one GC cycle later") is therefore false at this boundary. It is not a regression against HEAD, which leaks everything, but it is a cheap gap against the design's own goal (design.md:10-11). So major stands.

**The proposed change is right and minimal.**
- A second COLLECT inside the same try in both save paths restores stock's "dead at the save means disposed".
- The close() override goes beyond stock and is not needed. At unload the machine node has already lost its network (lifecycle.md:52-53), so it would only help AE2. Leave it out.

**The must-fail check can pass on the old build.** If any incremental cycle completes between the drop and the save, the single-COLLECT build disposes too, and the check passes there.
  better: - **The fix.** After LuaJITArchitecture.java:536 and OcljArch.scala:353, inside the same try, add a second `lua.gc(COLLECT, 0)`. Run it only when the value finalizer actually installed, so the dropin arm and the OCLJ_DISPOSE=off negative-control arm keep HEAD's GC cadence and cost. An optional further gate: skip it when the Java count map is empty, because then no Value userdata exists. Add a comment: LuaJIT weak keys are not ephemerons (lj_gc.c:214-216), so a proxy that died since the last cycle needs a second cycle before close, and close skips it (design.md:62).
- **Drop the close() override.** It goes beyond stock.
- **Amend design.md:123.** The lag is closed at save. Shutdown, reboot, crash and block break, which have no save, still lose one more cycle's worth of Values than stock; document that.
- **Scope note.** The internal-HDD file-handle effect is parity, because ComponentInventory.save runs before machine.save (Inventory.scala:23-25, Computer.scala:168-172). The real divergence is live side effects such as AE2 NetworkContents.valid (NetworkControl.scala:611, :634-648).
- **Must-fail test.**
  - Drop N handles, then save with no resume in between.
  - Before stop or close, assert that the live FS owners for this machine are 0.
  - Also prove that no GC cycle completed between the drop and the save, for example with the weak-value witness or a cycle counter read just before the save. Without that proof the single-COLLECT build can pass.

## OC-2 [major] The pushJavaObjectRaw override runs third-party hashCode/equals after the native push, with no guard (design.md:72-75; only ocljValueFinalized catches Throwable, :78-79). The HashMap's hashCode-then-equals contract also differs from what JNLua's __eq merges (equals only).

SCENARIO: (a) A third-party Value whose hashCode throws on a reloaded instance. For example, `hashCode = ref.hashCode` where the no-arg constructor leaves ref null. On restore, UserdataAPI.load's push throws after the userdata exists. load logs and RETHROWS (UserdataAPI.scala:49-52), so eris unpersist fails and LuaJITArchitecture.load throws (:630-636). Machine.load's catch then closes the machine (Machine.scala:811-814), and the computer's saved state is lost where stock loads fine. On the live path, the same throw turns a successful component call into a Lua error.
(b) A class that overrides equals but not hashCode. The kernel merges B into A's proxy through __eq (DefaultJavaReflector.java:487-496 calls equals only). The HashMap, keyed by identity hash, files B separately with n=1. When B's orphan dies, B is disposed while A's proxy is live, which is premature if A and B share a resource.
(c) A mutable hashCode. If A's hash changes after the push, the lookup at finalization misses, and the stale entry pins A forever. If A is re-pushed after the change, a second bucket gets n=1, and the orphan's death disposes A under its live proxy.

CHANGE: - Decide per class, and cache the decision. If the class does not override Object.equals (getMethod("equals",Object.class).getDeclaringClass()==Object.class), count by identity with an IdentityHashMap. No third-party code then runs at push, and every in-tree Value takes this path.
- Only for classes that do override equals, use the equals bucket. Its lookup should mirror JNLua's Equal: identity first, then an equals scan over that class's live entries, never hashCode. The kernel already pays an O(n) __eq scan on every wrap.
- Wrap all bookkeeping in both overrides in try/catch(Throwable). On failure, mark the object as untracked, so it is never disposed (a leak like stock's). Nothing may escape after super.pushJavaObjectRaw has returned.

CHECK: real=True sev=major
  reasoning: I could not refute this. Every link in the chain exists in source. The trigger is third-party only, but (c) does not require a contract violation.

1. The design runs third-party code where stock runs none. design.md:72-75 counts in an equals-keyed HashMap after super.pushJavaObjectRaw, with no catch; only ocljValueFinalized catches Throwable (:78-79). The override is possible because JNLua's pushJavaObjectRaw is not final (OC-JNLua LuaState.java:824). Stock never calls hashCode on a Value anywhere on the push, wrap or restore path:
   - ExtendedLuaState.pushValue memoizes with an IdentityHashMap (ExtendedLuaState.scala:27,30) before the push at :52.
   - Registry.convert uses an IdentityHashMap (Registry.scala:165-175).
   - machine.methods goes through Callbacks.apply, whose cache is keyed by getClass (Callbacks.scala:22-26; Machine.scala:380).
   - The kernel's dedup `v == data` (build/native/kernel/machine.lua:1217-1223) reaches JNLua's Equal, which is `o1 == o2 || o1.equals(o2)` and never calls hashCode (DefaultJavaReflector.java:487-496).

2. Scenario (a), the restore path, is real. The chain:
   - The persist closure calls `wrapUserdataInto(proxy, userdata.load(className, nbt))` inside eris (machine.lua:1185-1187).
   - UserdataAPI.load runs persistable.load(nbt), then pushJavaObjectRaw, and rethrows anything thrown (UserdataAPI.scala:45-52).
   - PersistenceAPI.unpersist runs eris with lua.call and has no catch (PersistenceAPI.scala:157-173).
   - LuaJITArchitecture.load converts the LuaRuntimeException to a RuntimeException (src/main/java/io/github/astronfo/ocluajit/arch/LuaJITArchitecture.java:584-635).
   - Machine.load catches it and calls close() (Machine.scala:775, :807-813).
   - On the live path, the throw escapes the Scala JavaFunction as a Lua error.

   Caveat: load(nbt) runs before the push (UserdataAPI.scala:45-46). So the trigger must be a hashCode that throws on a loaded instance, for example over a transient field re-resolved lazily. It is not simply a no-arg-constructor null.

3. Scenario (b) is real, but only for a class that violates the equals/hashCode contract. B's identity hash gives it its own entry with n=1, so B's orphan dispose fires while A's proxy is live. Stock never disposes B.

4. Scenario (c) is real for a LEGAL class, one whose equals/hashCode cover mutable fields (Java allows this; it is our design that puts the object in a hash collection). A is pushed, then mutated through userdata.unapply/call (machine.lua:1164-1169), then re-pushed. The HashMap misses the old entry and files a second one for A with n=1. The kernel merges by identity (machine.lua:1221). The orphan's finalize finds the new entry, n goes to 0, and A is disposed under its live proxy. The stale old entry pins A.

5. Nothing in-tree triggers any of the three:
   - No OC 1.12.58 Value overrides equals or hashCode, and none is a case class (understand/values.md:36). I confirmed this by grepping every AbstractValue subclass: FileSystem.scala:370, InternetCard.scala:244/406, NetworkControl.scala:339/447/534/592/714, DataCard.scala:346, DebugCard.scala:358/429/744, Trade.scala:24, ConverterLuaObject.java:19, ItemStackArrayValue.java:12, DriverPartInterfaceTerminal.scala:204.
   - The same grep finds no case class and no equals/hashCode among ocelot-brain's Values.
   - So the harness cannot catch any of this, and the in-tree path gains nothing from hashing.

6. The proposed change is right in direction:
   - Deciding per class through `getMethod("equals",Object.class).getDeclaringClass()==Object.class` is exactly right. The kernel's merge depends only on equals (DefaultJavaReflector.java:493-494), so identity counting is exact for those classes. All in-tree Values take that path, with zero third-party calls.
   - Keying on equals rather than hashCode also covers a class that overrides only a mutable hashCode.
   - The try/catch(Throwable) plus untracked marking is needed.

   It needs three tightenings (see better_change):
   - (i) If the equals scan is repeated at finalization, a mutation after the push can still misroute a decrement. In the worst case B comes to equal C, and C is disposed early. Assign the group once at push and look it up by identity at finalization. Then no third-party code runs on the finalizer at all.
   - (ii) Mirror the direction of `v == data`. Equal's object1 is the EXISTING wrapped value (machine.lua:1221 into DefaultJavaReflector.java:491-494), so call existing.equals(new), not new.equals(existing), which is what HashMap does.
   - (iii) "Untracked" must be identity-keyed and sticky. Otherwise a push that failed to count, plus a later counted push of the same object, lets that object's orphan drive n to 0 under the live proxy.

Residual, not covered by the design or the proposal: for equals-overriding classes, the count groups B with A while A's raw userdata is only pending finalization (the second cycle, design.md:30-31). By then the kernel has already given B its own proxy, because it compares only against live proxies (machine.lua:1217). The result is that A is disposed late and B is never disposed, where stock disposes both. This is low impact and third-party only.
  better: Keep the finding's three parts, tightened.

(1) Choose a class's tracking mode once and cache it (in a ClassValue or an IdentityHashMap<Class,Boolean>).
- If getMethod("equals",Object.class).getDeclaringClass()==Object.class, the class uses identity mode.
- Otherwise it uses equals mode.
- If the reflective check throws, the class uses equals mode.

(2) Two identity-keyed maps hold the bookkeeping:
- `IdentityHashMap<Object, Member{Group g; int n}> live`
- `Group{Object first; int n; boolean noDispose}`

Push (after super.pushJavaObjectRaw):
1. Look up m = live.get(o), by identity.
2. If m is null:
   - Identity mode: create a new Group(o).
   - Equals mode: scan the existing equals-mode groups and pick the first whose g.first.equals(o) is true. Call existing.equals(new), the same direction as the kernel's `v == data`. If none matches, create a new Group(o).
   - Put the new Member in live.
3. Increment m.n and g.n.

Finalize: look up m = live.get(v), by identity only, so no third-party code runs. If m is null, return. Otherwise:
1. Decrement m.n; at 0, remove v from live.
2. Decrement g.n; at 0, if !g.noDispose && isOpen(), call disposer.accept(g.first).

(3) Wrap each override's bookkeeping in try/catch(Throwable). If anything throws after the native push, put o in live under a fresh Group with noDispose=true (or set noDispose on its existing group), so no later push or finalize of that object can drive a dispose. Nothing may escape the override.

Add to the OcljSmoke probe:
- a Value whose hashCode throws: the push succeeds and it is never disposed;
- equals overridden without hashCode: one dispose, of the first;
- a mutable equals/hashCode Value mutated between two pushes: no dispose while its proxy is live.

## OC-3 [minor] Incrementing the count after super.pushJavaObjectRaw leaves a race: a GC step inside the native push can finalize the old userdata of the object being re-pushed. The count goes from 1 to 0 and the Value is disposed before the new userdata is counted.

SCENARIO: 1. A third-party driver returns a cached Value A. A's previous proxy is gone and its wrappedUserdata entry has been cleared, so A's only userdata is pending finalization (n=1).
2. The driver returns A again, and super.pushJavaObjectRaw starts. jnlua's lua_pushcfunction and lua_newuserdata run lj_gc_check before the new userdata exists. A GCSfinalize step there finalizes the old userdata: ocljValueFinalized(A), n 1->0, dispose(A).
3. Only then does count++ run, and the new proxy wraps a disposed A.
The outcome equals stock's (stock disposed A when its proxy died). But it depends on timing, and it contradicts the design's 'duplicate push keeps the Value alive'.

CHANGE: Increment before calling super.pushJavaObjectRaw. If super throws, roll the count back, and dispose if that reaches zero: the failed push left no finalizable userdata, so every counted userdata is already dead. A re-push then always resurrects cleanly.

CHECK: (minor, not checked)

## OC-4 [minor] Disposing only `first` when an equals-bucket reaches zero can skip an object that stock disposes. It also disposes `first` late, when its userdata never shared a proxy with the others.

SCENARIO: For a third-party Value class with value equality:
1. B is pushed and gets its own proxy P_B (bucket key B, n=1).
2. P_B is dropped. Its entry is cleared, but B's userdata is still pending because of the LuaJIT lag.
3. An equal A is pushed. The bucket goes to n=2, and A gets a NEW proxy P_A, since no live entry matches.
4. B's userdata is finalized (n=1). P_A dies later (n=0), and dispose(first=B) runs.
A is never disposed. If A registered a listener in its constructor, as NetworkContents does (NetworkControl.scala:610-611), that listener leaks. Stock disposes B when P_B dies and A when P_A dies.

CHANGE: Keep each bucket's members as an identity set, and when the bucket total reaches zero, dispose each distinct member once. This is safe: at zero no counted userdata of any member is alive, so Lua cannot reach any of them. Alternatively, record the difference in the non-goals.

CHECK: (minor, not checked)

## OC-5 [minor] The lag widens the window in which a handle comes back orphaned after a restore, and no change to the architecture's save can close it. The design's list of differences from stock omits this.

SCENARIO: 1. The components' NBT, including FileSystem owners, is written before machine.save (Computer.scala:168-172).
2. On stock, a handle whose proxy died after the last kernel collect is disposed only in the save's COLLECT, so it is restored as an owner with no Value and counts against maxHandles until reboot.
3. On the design, the window covers proxies dead since the second-to-last kernel collect, about 10 more resumes.
A second COLLECT in save (OC-1) neither helps nor hurts this, because it also runs after the FS NBT.

CHANGE: Add the widened window to the 'Deliberate non-goals / differences from stock' list. In gc-2 and in any harness fixture, never drop handles shortly before the save they are restored from.

CHECK: (minor, not checked)

# LENS: Java semantics, monitors, threads and locks

## J1 [major] The equals-keyed HashMap runs third-party hashCode and equals on every Value push and every finalization. It does not match the merge relation the kernel actually uses. When it diverges, it can dispose a LIVE Value, which stock never does. In-tree it buys nothing, because no in-tree Value overrides equals.

SCENARIO: Three cases, all with a third-party Value class. (a) Mutable hashCode, e.g. Lombok @Data or a case class with var fields. Push v while its hash is h0: entry E1 is {v,1} and proxy P1 wraps U1. A method call mutates v, so its hash becomes h1. A getter returns the cached v, and the second push misses E1 in the HashMap (hash compared first), creating E2 {v,1}. The kernel's `v == data` is an identity hit through JNLua's Equal (K:1217-1222; DefaultJavaReflector.java:487-495), so U2 is orphaned. U2 dies, E2 drops to 0, and dispose(v) runs while P1 is live: a live file handle is closed, or a live socket is killed. (b) equals is overridden but hashCode is not, which breaks the contract. The kernel merges B onto A because A.equals(B), but the map does not, so B's orphan is disposed. That is exactly the shared-resource case the equals key was meant to protect. (c) A hashCode that throws. The override counts AFTER super.pushJavaObjectRaw (design.md:72-75), so the userdata already exists, yet the exception fails every call that returns that Value. Stock runs no Value code at push time. Also, JNLua's __eq evaluates existing.equals(new), while HashMap evaluates new.equals(existing) gated on equal hashes, so an asymmetric equals diverges as well.

CHANGE: Count by identity with IdentityHashMap<Object,int[]>, so no Value code runs at push time. When a count reaches zero, decide whether to dispose. If v's class does not override Object.equals (cache per class: getMethod("equals", Object.class).getDeclaringClass() != Object.class), dispose. Otherwise skip the dispose if any other live counted object o of an equals-overriding class satisfies o.equals(v), the kernel's merge direction, and also skip if equals throws. A failure then degrades to stock's leak and never to a premature dispose. Drop `first`. The JVM probe's EqValue expectation becomes 'exactly one dispose' (of whichever dies last). In-tree cost is zero, since no in-tree class overrides equals.

CHECK: real=True sev=major
  reasoning: I could not refute it. The mechanism is real, but only a third-party Value can trigger it. No Value in OC 1.12.58 or ocelot-brain can.

How the kernel merges pushes:
- wrapSingleUserdata does `if v == data then return k` with v as the EXISTING raw userdata (build/native/kernel/machine.lua:1213-1222).
- LuaJIT invokes __eq with o1 = the left operand (prototype/watchdog/luajit/src/lj_meta.c:404-424).
- jnlua.Object's __eq is the dispatcher from LuaState.java:311-329 (OC-JNLua). It resolves to DefaultJavaReflector.Equal: `object1 == object2 || object1.equals(object2)` (DefaultJavaReflector.java:487-495).
- No code in OC, ocelot-brain or this repo replaces the reflector (grep for JavaReflector found nothing).
- So the kernel's merge relation is identity-or-existing.equals(new).

How the design counts:
- It counts in an equals-keyed HashMap after super.pushJavaObjectRaw (design.md:72-75).
- HashMap looks up by comparing the stored hash first, then calls new.equals(existing).

Case (a) holds. Push v at hash h0 gives E1 {v,1}. v's hash then changes to h1. A re-push misses E1 and creates E2 {v,1}. The kernel merges by identity, so U2 is orphaned. U2's finalizer finds E2, the count reaches 0, and the design disposes v while P1 is live. Stock never disposes an orphan, because only the proxy's __gc disposes. Extra effect: E1 can then never be removed. Its `first` keeps v strongly reachable until close, which is a Java-heap leak stock does not have.

Case (b) holds. If equals is overridden without hashCode, the two objects get different identity hashes and separate entries. B's orphan is then disposed, which is exactly the shared-resource hazard the equals key was meant to prevent (design.md:74-75).

Case (c) holds. Stock's push path hashes nothing: pushValue's memo is an IdentityHashMap (oc-1.12.58-src li/cil/oc/util/ExtendedLuaState.scala:27-31). Registry.convert's memo is also identity (Registry.scala:164-165). Only design.md:79 catches Throwable, and only on the finalize side. A throwing hashCode would therefore escape pushJavaObjectRaw after the userdata is already on the stack.

The asymmetric-equals point holds as well.

In-tree, the claim also holds:
- Every OC Value extends AbstractValue (AbstractValue.java:11-33, no equals/hashCode).
- None is a case class (my grep of Value implementors).
- The extra supertypes are all interfaces, which cannot override Object methods.
- values.md:36 and kernel.md:109 agree.

So an identity map costs nothing in-tree. The equals key was chosen only to protect hypothetical third-party classes (critic.md:134 originally proposed IdentityHashMap). Counter-cases built from the same third-party premise are just as valid, which is why I rate it major (should change) and not blocker: it needs a third-party Value with a mutable, contract-breaking or throwing hashCode/equals. The change is still worth making because it is cheap, and the design stated invariant ("never a premature dispose", design.md:77-78) is false without it.

The proposed change is right in direction, but its gate looks at the wrong object:
- The merge test is o.equals(v), where o is the EXISTING wrapped object (lj_meta.c:421-423; DefaultJavaReflector.java:492-493).
- Whether a merge can happen therefore depends on o's class, not on v's.
- The proposal says to dispose straight away when v's class does not override equals. That reopens the same contract-violation hole as (b): an overriding X whose equals accepts a non-overriding Y. The kernel merges Y onto X's proxy, and Y's orphan is disposed.

Smaller point: when both objects got their own proxies, both versions dispose only one of an equal pair where stock disposes both. That is a leak, never a premature dispose, so it is acceptable, but it should be documented. Everything else in the proposal (identity counting, no Value code at push time, dropping `first`, catching Throwable around equals) is sound.
  better: In LuaStateLuaJIT, count by identity in an IdentityHashMap<Object,int[]> (no hashCode/equals at push time) and drop `first`. Keep a second identity set `eqLive`: the live counted objects whose class overrides equals, with the check cached per class as getMethod("equals", Object.class).getDeclaringClass() != Object.class. Add on the 0->1 transition and remove on 1->0.

When v's count reaches 0, remove v from both maps first. Then:
- If eqLive is empty, dispose v. This is always the case in-tree, so in-tree cost is zero.
- Otherwise, skip the dispose if any o in eqLive gives o.equals(v) == true. This is the kernel's existing.equals(new) direction, gated on the EXISTING object's class and not on v's.
- Also skip if equals throws (catch Throwable).
- Otherwise dispose v.

A failure can then only leak and can never close a live resource. Document as a non-goal that an equal pair which got two separate proxies disposes only one of the two. Change the EqValue JVM probe from 'one dispose, of the first' to 'exactly one dispose, never while any equal object's userdata is live'. Add a MutableHashValue probe: push, mutate the hash, re-push, collect twice, and expect the surviving proxy to be still usable with zero disposes. Run it against the HashMap version to show it fails there before trusting a pass.

## J2 [minor] Counting AFTER super.pushJavaObjectRaw lets the GC step inside the push finalize the Value's last pending userdata. The Value being re-pushed is then disposed, wrapped in a new proxy, and disposed again when that proxy's userdata dies. Counting first closes the window.

SCENARIO: A driver returns a cached Value v. v's proxy died one cycle earlier, so U1 is separated and pending. The re-push's checkpoint (lua_pushcfunction or lua_newuserdata inside lua_1pushjavaobject) runs GCSfinalize. Under the shim's armed collector (stepmul 0, so whole cycles run at one checkpoint) this is the common case. U1's callback drops the count from 1 to 0 and disposes v, then count++ starts a fresh entry, and U2 wraps a disposed v. A HandleValue disposed twice can close a REUSED handle id belonging to another live file. Stock double-disposes in the same pattern, so this is parity, not a regression.

CHANGE: Increment before super.pushJavaObjectRaw(o). If super throws, decrement in a catch. If this push created the entry, remove it without disposing; if a pre-existing entry reaches 0 there, its other userdata all died during the failed push, so dispose it.

CHECK: (minor, not checked)

## J3 [minor] The design assumes, rather than checks, that ocljValueFinalized runs only on a thread that holds the monitor. If that is ever false, the synchronized callback BLOCKS inside a GC step, which can deadlock a server thread. A leak would be the safe failure.

SCENARIO: Any future path that runs a GC step on the lua_State outside a synchronized LuaState method. Examples: a new unsynchronized native in the generator, a harness probe calling a protected native reflectively, or a JNLua update. The finalizer's upcall waits on the monitor while the holder waits on this thread. Today no such path exists (see the sound list).

CHANGE: Make ocljValueFinalized non-synchronized, with first statement `if (!Thread.holdsLock(this)) { ocljValueUnlocked++; return; }`. That turns a block into a leak plus a counter. Expose the counter to the OcljSmoke probe and assert it is 0, and show that the assertion fails by calling the method from a thread that does not hold the lock.

CHECK: (minor, not checked)

## J4 [minor] The 'start anyway' catch (UnsatisfiedLinkError | IllegalStateException) is too narrow. Several install failures escape initialize(), and Machine.init then refuses to start the computer, the opposite of the stated policy.

SCENARIO: (a) The JNI core fails at NewWeakGlobalRef, which leaves an OutOfMemoryError pending, or at GetMethodID, which leaves NoSuchMethodError pending. It 'releases and returns a code', but Java sees the pending Throwable, not the code. (b) check() is package-private (LuaState.java:2437). Today LuaStateLuaJIT uses only public and protected members, so calling check() adds a new requirement: the class must share a runtime package, i.e. a defining class loader, with OC's LuaState, or it gets IllegalAccessError. (c) A NullPointerException or IllegalArgumentException from the argument checks. Each of these reaches Machine.init's catch, which logs 'Failed initializing computer.' and closes the machine.

CHANGE: In LuaJITArchitecture and OcljArch, catch LinkageError | RuntimeException | OutOfMemoryError (or Throwable) around the install. In the JNI entry, call ExceptionClear before returning a nonzero code. In ocljSetValueDisposer, use `if (!isOpen()) throw new IllegalStateException(...)` (public final, LuaState.java:521) instead of check().

CHECK: (minor, not checked)

## J5 [minor] pushJavaFunction is a second Java route that mints a jnlua.Object userdata, and it is not counted. If an object is both a Value and a JavaFunction, the finalization of its function userdata passes the C IsInstanceOf filter and decrements a count that was added by a raw push.

SCENARIO: A third-party Value that also implements JavaFunction is pushed through the converter (DefaultConverter.java:474-476) or register(). The function closure's upvalue userdata dies while the raw-pushed proxy is live. The callback finds the raw entry, the count reaches 0, and the live Value is disposed. No in-tree Value implements JavaFunction.

CHANGE: Override pushJavaFunction in the generator with the same identity count when valueClass.isInstance(f).

CHECK: (minor, not checked)

## J6 [minor] After close, the map still holds strong references to every Value counted at close, and the disposer still holds the architecture and Machine. They stay alive for as long as the closed LuaStateLuaJIT is referenced.

SCENARIO: vgc_closing suppresses every callback at close, so entries are never removed. OC nulls `lua` (NativeLuaArchitecture.scala:337), so this is bounded in game. Harness code that keeps an old state, or the architecture swap at Machine.scala:151-154, keeps the Values reachable.

CHANGE: Override close() (public synchronized, non-final, LuaState.java:533) to call super.close(), then clear the map and set ocljValueDisposer to null.

CHECK: (minor, not checked)

## J7 [minor] F8's contract (dispose must touch no LuaState API) is not enforced. In stock, calljavafunction pointed luaThread at the finalizer's thread. In the direct upcall, luaThread is whatever coroutine was mid-operation, so a dispose that pushes or reads writes onto that coroutine's stack.

SCENARIO: A third-party Value.dispose holds a LuaValueProxy, or calls lua.push*, which is legal under stock's Lua-path dispose. Under the design it writes onto the stack of the coroutine whose allocation triggered the GC, between that coroutine's own API steps. The result is silent stack corruption, not an exception. In-tree dispose bodies never do this (see the sound list).

CHANGE: Set an ocljInDispose flag around disposer.accept, and have the pushJavaObjectRaw and pushJavaFunction overrides throw IllegalStateException while it is set, so the disposer's catch logs it. Document the contract in the generated Javadoc.

CHECK: (minor, not checked)

# LENS: tests and gates: C fake-JNIEnv test, negative controls, JVM private-state probe, machine milestones gc-1/gc-2, per-arm expectations, build gates, fail-first pla

## T1 [blocker] Keying the milestone expectation on 'whether it installed' turns every install failure into a passing LEAK expectation. With the planned fail-first run it also either does not compile or passes.

SCENARIO: (a) The DLL is stale (UnsatisfiedLinkError), or GetMethodID's name or signature is mistyped (rc!=0, IllegalStateException). The mod logs and starts anyway (design.md:87-88), and OcljArch 'records whether it installed so milestones can key their expectation' (design.md:89-91). So installed=false, gc-1/gc-2 expect LEAK, see LEAK, and print PASS. The shell gate checks only VERDICT and FAIL lines, not CHECKS (smoke-test.sh:639-657), so SMOKE PASS ships a build that disposes nothing. (b) Fail-first on HEAD: smoke-test.sh compiles the tree's LuaStateLuaJIT.java with OcljArch on every run (smoke-test.sh:258, :376-380). A static call to ocljSetValueDisposer does not compile against HEAD's class. If it is made reflective and recorded as not installed, (a) applies and HEAD's leak PASSes.

CHANGE: Key gc-1/gc-2 only on the configuration inputs (nativeMode, OCLJ_DISPOSE, BundleRoots), never on the outcome. Add a gc-0 milestone in additive arms: installed == expected for this config. In OcljArch, either let install failure propagate or record it so that gc-0 FAILs. Do the harness's install and probe lookup reflectively (getMethod), so the same harness runs on HEAD. There gc-0 FAILs and gc-1/gc-2 FAIL with the LEAK reason. Running new Java plus harness against HEAD's DLL is a second fail-first that also exercises the start-anyway path.

CHECK: real=True sev=major
  reasoning: The flaw in the design is real. The headline consequence is overstated for the two causes the finding names.

REAL: design.md:89-91 does say OcljArch "records whether it installed so milestones can key their expectation". That keys gc-1/gc-2 on the outcome instead of on the configuration. The harness does it the other way everywhere else: k2/k3/k5/m1 key on nativeMode/kernelMode/jitMode (OcljSmoke.scala:4385-4404, :4593-4602, :4949-4955). With an outcome key, any OcljArch install that throws or returns rc!=0 becomes "expect LEAK", which sees LEAK and prints PASS. A SKIP is never counted (OcljSmoke.scala:458-497). The shell gate only looks at VERDICT, the fingerprint and MILESTONE FAIL lines (smoke-test.sh:639, :645, :657).

The fail-first plan (design.md:118) clashes with this. On HEAD nothing installs, so an outcome-keyed gc-1/gc-2 expects LEAK and PASSes. The "fail-first" log can therefore never fail, which breaks the prove-a-new-check-can-fail rule. smoke-test.sh compiles the tree's LuaStateLuaJIT.java and OcljArch.scala with the harness on every run (smoke-test.sh:257-258, :365-380). So a harness with static calls to ocljSetValueDisposer cannot be run against HEAD without changes the design does not mention. That branch fails loudly (javac or scalac stops the run, :368, :380), so it is not a false pass. It does mean the plan is underspecified.

OVERSTATED: the claim that "SMOKE PASS ships a build that disposes nothing" when the DLL is stale or GetMethodID has a typo is refuted by the design itself. Its JVM private-state probe (design.md:109-111) is keyed on the arm ("additive arm"), not on install. It calls the same ocljSetValueDisposer, through the same generated LuaStateLuaJIT, against the same staged DLL. Both named causes are independent of state:
- A stale DLL gives UnsatisfiedLinkError, which JNI binds lazily (LinkProbe.java:11-14).
- A mistyped GetMethodID gives rc!=0, then IllegalStateException.

Either way the probe cannot report "N distinct -> N disposes". Acc-style probes catch Throwable as a FAIL milestone (OcljSmoke.scala:2057, :1966-1970). accountingProbes runs on every additive run, at the end of main (OcljSmoke.scala:5538). So SMOKE FAILs in every additive arm. M exists for every shim state, capped or not (lj52shim.c:312-316, :2279-2286), so install does not fail in one context and pass in the other.

What the outcome key still hides:
- failures specific to OcljArch's call site in the machine context (OcljArch.scala:84-121 after applyForinMode at :102);
- the fail-first.

Both are real but cheap to fix in the design text. Hence major, not blocker.

THE PROPOSED CHANGE: its core is right and enough. Key gc-1/gc-2 only on nativeMode, OCLJ_DISPOSE and BundleRoots. Then an OcljArch install failure in the shipping configuration gives gc-1 FAIL with LEAK, and HEAD's additive arm FAILs. The rest is surplus:
- gc-0 duplicates what gc-1 (keyed on configuration) and the private probe already catch.
- Making OcljArch propagate the failure is unnecessary.
- Reflective getMethod lookups, so one harness runs on HEAD, are not needed if the milestones come first: add config-keyed gc-1/gc-2 to HEAD's harness with no probe and no OcljArch change, run the additive arm, keep the FAIL log, then implement.
- The "new Java on HEAD's DLL" run is already covered by the private probe failing.
  better: In design.md:91, replace "records whether it installed so milestones can key their expectation" with: gc-1/gc-2 expectations are a function of configuration only. Expect PASS when nativeMode=additive, BundleRoots is on and OCLJ_DISPOSE is not off. Expect PASS on stock. Expect LEAK on dropin. Expect LEAK as -NEGATIVE-CONTROL when OCLJ_DISPOSE=off, and with a SKIP-free LEAK expectation when BundleRoots is off. OcljArch may still record the install result and print it in the gc-1 detail line ("installed=false <- install threw: ..."), but it never selects the expectation. Rewrite design.md:118 as: add the config-keyed gc-1/gc-2 to HEAD's harness first, with no private probe and no OcljArch change. Run the additive arm and keep its log, where gc-1/gc-2 must FAIL with LEAK. Only then add the fix and the private probe. Drop gc-0 and the reflective lookups; they are not needed.

## T2 [blocker] As written, gc-1 and gc-2 each open their own handles on the same disk for the same machine address. On every LEAK arm the second hold is refused outright (n=0), so the permanent dropin and DISPOSE=off controls can never pass, and the HEAD fail-first fails gc-2 for the wrong reason.

SCENARIO: design.md:113-116 has gc-1 'open until refused ... drop' and gc-2 'hold the handles across f1'. owners is keyed by the machine's address (FileSystem.scala:152-153, :159), persists across save/load (:306-336) and is cleared only by computer.started/stopped or a disconnect (:259-272, :288-297). Say gc-1 runs first on dropin, DISPOSE=off or HEAD: it leaks 16 owner entries. gc-2's hold then gets 'too many open handles' on its first open, n=0, and the expectation 'owners stays n == maxHandles' FAILs. The reverse order fails the same way, because gc-2's 16 are still held on the original when gc-1 opens.

CHANGE: Use one hold and two drops. Hold before f1 on the original. gc-2 drops ws2's copy inside the restore block, while ws2 is still ticked. gc-1 drops the original's copy after the restore block and before fi (:5467). Each milestone asserts its own precondition (owners == maxHandles and refusal text) on its own FileSystem instance. Assert that ws2's hdd2 is not the same object as ws's, so a wrong-disk read can only fail. The alternative is a separate dedicated disk per milestone.

CHECK: real=True sev=major
  reasoning: I could not refute it. Read literally, the design describes two separate holds on one disk.

**What the design says.** design.md:112 names a single "dedicated second HDD". gc-1 at :113-115 does its own "open until refused (expect maxHandles=16), drop ... reopen". gc-2 at :115-116 says "hold the handles across f1's save, drop on the restored machine". Nothing says gc-1's drop waits until after the restore. So gc-1, listed first and "live", opens and drops before f1, and gc-2 needs a fresh hold.

**Why the second hold is refused.**
- `owners` is per FileSystem object and keyed by the machine's address (ocelot-brain FileSystem.scala:30, :152-153, :159).
- `owners` shrinks only through close (:246-255), the computer.started/stopped messages (:259-272) or a disconnect (:285-298).
- Between f1 and the restore block, nothing stops or starts the original machine. OcljSmoke.scala:4992-5235 only ticks `ws`.

**Forward order (gc-1, then gc-2's hold).** On the LEAK arms (dropin, DISPOSE=off, HEAD fail-first), gc-1 leaves 16 entries. gc-2's first open throws "too many open handles" (:152-153), so n=0. The outcome depends on what gc-2 checks:
- If it checks held==owners==16 (harness.md:164), it fails on the precondition. The controls can never pass, and HEAD fails gc-2 for the wrong reason.
- If it checks only "owners 16 -> 0", the check passes silently and proves nothing. owners already reads 16 from gc-1's leak, and those ids persist into ws2's copy through save/load (:329-336, :309-314). The LEAK verdict then has nothing to do with whether restored Values are disposed.

**Reverse order.** gc-2's 16 are still held on the original when gc-1 opens, so gc-1 fails on every arm, PASS arms included.

**Severity: major, not blocker.**
- The C/Java fix is untouched.
- In the natural forward order, the additive and stock PASS arms are unaffected, because gc-1 cleans up first.
- The evidence the design cites already gives the right sequence (understand/harness.md:186-193): one `ocljgchold` before f1, gc-2 drops on ws2, gc-1 drops on the original "after the restore block and before fi". design.md lost that sequence when it was condensed.
- It must still be written into the design before the milestones are coded, or the negative controls are born broken.

**The proposed change is right and essentially minimal.**
- The two FileSystem objects are separate. ws2.load builds fresh entities (OcljSmoke.scala:5242-5243). HandleValue.dispose resolves the disk through the disposing machine's own network (HandleValue.scala:19-23). So a drop on ws2 touches only ws2's hdd2, and a drop on the original touches only the original's.
- ws2 is not ticked after the restore block (OcljSmoke.scala:5476-5478), so gc-2 must drop inside the block.
- fi starts at :5467, after the block ends at :5462. gc-1 fits between them, and stk and mem-2 do not use hdd2.
  better: Adopt the finding's sequence as harness.md:186-193 already words it, and state it in design.md:
1. One hold: `ocljgchold` on the original before f1. The precondition is held == owners == maxHandles plus the refusal text, read on the original's hdd2.
2. gc-2: inside the restore block, after f4 (OcljSmoke.scala:5460-5461), while ws2 is still ticked. Its own precondition on ws2's hdd2 (looked up through computer2's inventory) is owners == 16 and one refused open. It also needs the liveness read from harness.md:190, because FileSystem.close removes an owner entry only when the restored handle actually reopened (FileSystem.scala:247-253, swallowed at HandleValue.scala:23-24). Without that read, a dead restored id gives a false gc-2 FAIL even with the fix. Then drop and expect owners 16 -> 0.
3. gc-1: drop on the original after the restore block and before fi (:5467). Expect owners 16 -> 0, a successful reopen, the same nonce, and the machine still running.

The assert that ws2's hdd2 is not ws's is harmless but optional: ws2.load always creates new entities. A separate disk per milestone also works, but it costs a third disk and a second saturation for no gain.

## T3 [major] Nothing at machine level can detect a premature dispose, yet that is F3, the design's correctness blocker. The only F3 test is a bare-state probe that never runs the kernel's merge or a sabotage that disables counting.

SCENARIO: A Java side that disposes per userdata (no counting), or keys on identity, still passes gc-1/gc-2: no Value is ever pushed twice there. ocelot-brain has no Value echo path (its Values are HandleValue, DataCard and InternetCard only; there is no TestValue), and HandleValue uses identity equality. The design's probe pushes twice by hand (design.md:109-111), so it never executes wrapSingleUserdata's `v == data` through JNLua's __eq (ocelot-brain machine.lua:1171-1175; DefaultJavaReflector.java:486-496), which is what actually orphans the second userdata. None of the four sabotages touches the Java side (design.md:107-108).

CHANGE: (1) In the probe, load the kernel's shape on the private state: a weak-key `wrapped` table, wrap() with the `v == data` scan, and a JavaFunction that returns its argument (an echo). Echo a held Value through it, keep the proxy across 3 collects and assert 0 disposes. Then drop it and assert exactly 1. (2) Add OCLJ_JAVA_SRC sabotages of LuaStateLuaJIT (no counting; IdentityHashMap). Each must fail exactly its probe id. (3) Add a bystander to gc-1/gc-2: drop all handles but one, and assert the kept handle still seeks and reads after the collects and that owners == 1. Then close it and assert owners == baseline.

CHECK: real=True sev=major
  reasoning: Part of T3 holds and part does not. The headline holds: nothing at machine level can see F3. The implied conclusion, that a Java side with no counting or with identity keys would ship undetected, is refuted by the design's own probe. What is left is a narrower gap: the probe is never shown to fail.

CONFIRMED (the machine-level blindness):
- ocelot-brain's only Values are DataCard.ECUserdata (entity/DataCard.scala:281), InternetCard TCPSocket/HTTPRequest (entity/InternetCard.scala:231, :393) and HandleValue (entity/fs/HandleValue.scala). AbstractValue and HandleValue define no equals or hashCode (grep found nothing).
- A signal cannot carry a Value. convertArg's default case logs a warning and returns null (ocelot-brain entity/machine/Machine.scala:285-300). OC behaves the same (critic.md:79).
- No ocelot-brain callback returns a Value it was given or holds, and there is no TestValue (lifecycle.md:143).
- So in gc-1/gc-2 every HandleValue is pushed exactly once, and finalized once. A LuaStateLuaJIT that disposes on every finalize, or keys an IdentityHashMap, disposes the same objects at the same times as the counting design. gc-1/gc-2 pass either way.
- The four sabotages in design.md:107-108 are all in lj52shim.c. The fail-first step (design.md:118) covers only gc-1/gc-2 on HEAD. On HEAD the probe cannot even compile, because ocljSetValueDisposer does not exist yet.

REFUTED (the claim that only the kernel's merge exposes the bug):
- The Java counter's inputs are pushJavaObjectRaw calls and ocljValueFinalized calls (design.md:72-79). Two pushes and one finalize look exactly the same whether the second userdata was orphaned by wrapSingleUserdata's `v == data` (ocelot-brain machine.lua:1171-1176) or popped by hand.
- JNLua's __eq only pushes a boolean (OC-JNLua DefaultJavaReflector.java:487-495). It never calls pushJavaObjectRaw, so running the merge adds no counter event.
- The probe as specified (design.md:109-111) already fails both broken Java sides:
  - With no counting, "duplicate push keeps the Value alive" fails, and so does "equal-but-distinct -> one dispose" (it gets two).
  - With identity keys, "equal-but-distinct -> one dispose, of the first" fails (two disposes, or the wrong object).
- So change (1), loading the kernel's shape into the probe, adds no power to catch these bugs. At most it re-checks F3's premise with the real JNLua __eq. That premise was checked only with eqprobe.lua (c-side.md:277), and counting is correct whether or not the merge happens. It is optional.
- Change (3), the bystander, does not address the scenario at all. With no re-push in gc-1, a kept handle survives under both sabotages, so it cannot fail there. It is an optional cheap check against over-disposing, nothing more.

WHAT IS REAL (why this stays major):
- F3 is the design's correctness blocker, and its only test has never been shown to fail.
- "Keeps alive" is a negative assertion. It passes vacuously if the dropped duplicate is never finalized: still referenced on the stack, popped in the wrong slot, or collected too few times.
- The project's own convention for additive-only JVM probes of LuaStateLuaJIT is a sabotaged LuaStateLuaJIT.java for each probe, injected through OCLJ_JAVA_SRC. See OcljSmoke.scala:1900-1901 (acc-3..7, "see the change's gate log") and smoke-test.sh:258 and :376-380.
- The design calls its probe "acc-6 style" but leaves out that sabotage step. It also departs from the user's prove-a-new-check-can-fail rule.
- The harness report suggested only C sabotages plus an OCLJ_DISPOSE switch (harness.md:236), which is how the gap arose.
  better: Keep part (2), slightly tightened, and make (1) and (3) optional:

(a) Two OCLJ_JAVA_SRC sabotages of the generated LuaStateLuaJIT.java, run like acc-3..7 (OcljSmoke.scala:1900-1901) and recorded in the gate log:
- S1: ocljValueFinalized disposes on every call, with no count.
- S2: HashMap replaced by IdentityHashMap.
Expected results:
- S1 fails the duplicate-push check and the equal-but-distinct check.
- S2 fails the equal-but-distinct check.
- Both pass N-distinct, non-Values and close.

(b) Give each "keeps alive" case its own positive witness in the same case:
- Push v twice and pop one. Run 2 full collects and assert 0 disposes.
- Pop the other, run 2 more full collects, and assert exactly 1 dispose, of v (for EqValue, of the first object).
- If the first drop's finalizer never ran, this end count still separates counting (1) from no counting (2).
- Optionally also assert that vgc_calls rose by 2 (the _OCLJ_GCSTATS counter, design.md:66).

(c) Optional:
- The kernel-shape echo, which checks F3's premise with the real JNLua __eq.
- A bystander handle in gc-1, as an over-dispose check. It cannot detect T3's scenario.

## T4 [major] The negative controls prove only 4 of roughly 10 guards can fail, and the 'exact expected failing-id set' is never written down. With compound V-checks and teardown closes, the sets are not precise.

SCENARIO: No sabotage covers: V5 (drop the post-call ExceptionClear, which would leak a Java exception into a random Java frame after the GC), V8 (drop the GetEnv check, which segfaults), V6 (drop the already-wrapped test), V3's ref release, V7's rollback, Java counting, or Java isOpen. Dropping the chain fails V1, V2, V3, V5 and V8, and also V4 and V6 if those assert original-once. Any test whose teardown closes a state holding a live Value also picks up 'drop the closing check'. A fake JNI table with NULL slots turns an unanticipated call into a crash, which changes the exit status rather than adding a FAIL id.

CHANGE: Split each V into atomic ids (e.g. V1a callback-count, V1b order, V1c original-count). Make ref balance its own id. Take every tally before teardown, or tear down with no live Values. Fill every JNINativeInterface_ slot with a trap that prints FAIL Vtrap <slot>. Add sabotages for V3-release, V5, V6, V7 and V8, plus the two Java ones from T3. Write each sabotage's expected id set into the design.

CHECK: real=True sev=minor
  reasoning: The core of the finding is true, but most of its supporting claims do not hold up, and the guards it wants sabotaged mostly protect paths that never run in production. I rate it minor, not major.

What is true:
- design.md:107-108 lists four sabotages (chain, closing check, exception save, class filter) against eight V-checks plus the Java counting. It says "each with its exact expected failing-id set" but never writes a set down.
- No sabotage proves that these can fail: V3's ref release, V5's post-call clear, V6, V7, V8, or V1's "BEFORE the original" ordering. The user's standing rule (memory prove-a-new-check-can-fail) asks for exactly that proof.

What does not hold up:
1. "The sets are not precise." expect and expect_mem require an exact status and an exact id set (negative-control.sh:112-140, :289-308). That works for any deterministic set, and a compound or teardown-inflated set is still deterministic. "Drop the chain" failing V1, V2, V3, V5, V8 (and V6 if it counts originals) is the correct consequence, because each of those asserts original-once. Compound ids only lower diagnostic resolution. Neither causes a false pass or a false fail. Atomic sub-ids are house style (W16/W16L/W16R..., negative-control.sh:474) and nice to have, nothing more.
2. Teardown: a test that closes a live Value under "drop the closing check" adds ids to a deterministic set. That is not a failure scenario.
3. NULL-slot crash: the evidence is misapplied. mem_test.c:139 has FAKE_ENV = NULL only because the shim never dereferences env on that path; it injects getthreadenv/getluamemory/setluamemory (mem_test.c:145-155). harness.md:244 and :260 say the same, and the latter already prescribes a populated JNINativeInterface_ for this test. None of the four designed sabotages calls a JNI slot the canonical path does not call. In any case a crash gives a status mismatch, so the control reports FAIL loudly; it never passes falsely. negative-control.sh:312-337 already has expect_death for sabotages that crash.
4. The scale is in line with house practice. security_test's ER1-4, FX1-2, SB0-5 and LE5-8, and many mem_test ids (P*, M0*), have no sabotage at all (sets at negative-control.sh:178, :237, :269).
5. V6, V7 and V8 guard paths production never reaches:
   - V6: every initialize() makes a fresh state (NativeLuaArchitecture.scala:310; LuaJITArchitecture.java:143-151 calls super.initialize() first), so nothing installs twice on one state.
   - V7: registry["jnlua.Object"] always exists once jnlua has opened.
   - V8: finalizers run on the JNI-calling thread, which is already attached to the JVM.
   - V5: both Java layers catch Throwable (design.md:76-79, :85).

The guards that are worth a proven failure:
- V1 ordering (the finding does not propose this one). If the order is reversed, gcjavaobject deletes the global ref and then IsInstanceOf/CallVoidMethod use a deleted ref, which crashes the JVM.
- V3's release. Dropping it leaks two JNI global refs per machine boot.
- The Java no-count case (T3's territory). "Duplicate push keeps the Value alive" passes trivially on HEAD and under per-userdata disposal if the orphan is never finalized. A sabotaged LuaStateLuaJIT.java can already go in through OCLJ_JAVA_SRC (harness.md:233).
  better: The change is narrower than the finding's. Add three C sabotages to negative-control.sh, each with its predicted id set written into the design before implementation and then checked against the measured set:

1. "swapchain": call the original before the callback. The fake original poisons its jobject, and the fake IsInstanceOf and CallVoidMethod print FAIL when they receive a poisoned ref. This fails V1's order part.
2. "norelease": drop the post-close DeleteGlobalRef/DeleteWeakGlobalRef. This fails V3's release.
3. "nopostclear": drop the ExceptionClear after the callback. This fails V5.

Also split V1 into count, order and original sub-ids, and V3 into close-callback, original and release sub-ids, so each sabotage's set is diagnostic. Fill the fake JNINativeInterface_ with a trap that prints "FAIL Vtrap" for any slot the test does not use (harness.md:260); this is hygiene, not a fix. Prove V6, V7 and V8 can fail once by hand during development rather than with permanent sabotages, since their paths are unreachable in production. The Java no-count sabotage, injected via OCLJ_JAVA_SRC, belongs with T3 and is the most valuable addition of all.

## T5 [major] The fake JNIEnv cannot see several real defects unless it is built to.

SCENARIO: (a) A single env pointer for both install and finalize hides a wrapper that caches env in M. In the JVM, install runs on the harness thread but the kernel collect finalizes on the executor thread, and using one thread's env on another is illegal. (b) A fake GetMethodID that accepts any name hides a typo in 'ocljValueFinalized' or '(Ljava/lang/Object;)V'. In the JVM that becomes rc!=0, which T1 then turns into a PASS. (c) Local-ref balance per finalize is not asserted, yet an armed collect runs many finalizers in one native frame (lj52shim.c:1184-1196). (d) The real order creates jnlua.Object userdata (API JavaFunctions) BEFORE the install; V1 does not cover a Value created before install.

CHANGE: Give the fake two env tables. GetEnv returns the 'finalize' one, and every finalize-time call must arrive on it. Make GetMethodID assert the exact name and signature strings. Count NewLocalRef/DeleteLocalRef and require a net of 0 after each finalize. Create one Value userdata before lj52_vgc_install in V1. Optionally run the private probe once under -Xcheck:jni and grep for 'exception pending' and 'wrong thread' warnings.

CHECK: real=True sev=minor
  reasoning: This is partly real, but only as test hardening. None of the four parts is a defect in the design itself. Part by part:

(a) Env cached across threads: a real test gap, minor. The design already says the wrapper gets its env from GetEnv(vgc_vm) on every finalize and again at close (design.md:57, :63). That matches jnlua, whose own __gc calls getthreadenv() each time (build/native/jnlua-luajit.c:2120-2121). The threads really do differ:
- OC: initialize() runs in Machine.init (OC Machine.scala:917).
- ocelot-brain: initialize() runs at Machine.scala:851, while the slices run in run() on MachineAPI.threadPool (:899, :907).

So an implementation that broke the design by caching the install env in M would pass a single-env fake. It would also pass the JVM probe, which installs and collects on one thread. Only the milestones would catch it, and only by luck. A two-env fake costs almost nothing.

(b) Typo in the method name or signature: refuted as "hidden". The JVM private-state probe is "acc-6 style" (design.md:109). That style wraps the whole check in catch Throwable and records ok=false (OcljSmoke.scala:2038-2057). An install failure inside ocljSetValueDisposer would therefore fail the probe, not pass it. Whatever T1 says about the milestones, the suite as a whole would not report a PASS. A fake that asserts the exact strings only compares the C literal with a third copy in the test. The JVM probe is the real cross-check.

The scenario does point at a real issue, though: "becomes rc!=0" is wrong. On failure, the JNI part of the core only releases what it made and returns (design.md:51-52). It never clears the exception. A failed GetMethodID leaves NoSuchMethodError pending, so Java throws that when the native returns. The rc is never seen, and no IllegalStateException is raised. The call site catches only UnsatisfiedLinkError and IllegalStateException (design.md:87). OC's Machine.init catches Throwable from initialize() and logs "Failed initializing computer" (OC Machine.scala:917-922). The machine would then fail to start, which breaks the design's "START ANYWAY, no worse than HEAD" promise. This only happens with a jar and DLL from different builds, or with a typo, so it is minor. V1-V8 never test the JNI part failing.

(c) Local-ref balance: a real test gap, minor. The premise holds: an armed step uses stepmul 0 and finalizes the whole mmudata list in one native frame (lj52shim.c:1184-1196), and the kernel's full collect does the same. But the design's wrapper is balanced by construction: NewLocalRef/DeleteLocalRef for jstate, and DeleteLocalRef for the saved exception (design.md:58-60). IsInstanceOf and CallVoidMethod leave no locals behind. If an implementation leaked anyway, HotSpot would just grow its handle blocks until the frame returns. That is bounded memory, not a crash. A counter in the fake is cheap insurance.

(d) Value created before install: refuted.
- LuaJIT looks up __gc on the userdata's CURRENT metatable both when it separates the userdata (lj_gc.c:150) and when it runs the finalizer (lj_gc.c:573). Nothing is recorded per object when the userdata is created. A pre-install userdata takes exactly the same C path as V1 (Value) or V2 (non-Value).
- I checked this with the pinned luajit: review-skeptic/preinstall.lua creates a userdata, collects it once while it is alive, swaps __gc, then drops it. Output: "wrap,orig,wrap,orig".
- No Value is pushed before the install point anyway. NativeLuaArchitecture.initialize only creates the state, runs apis.initialize and loads the kernel thread (NativeLuaArchitecture.scala:306-325). All Value pushes happen inside runtime closures (:63, :232; UserdataAPI.scala:46). The only userdata that exist before install are the API JavaFunctions, which are not Values, so V2 already covers them.
- If a Value were somehow pushed before install, the Java side treats a missing entry as "do nothing" (design.md:77).

Severity: minor. Nothing in the design changes. Two of the four parts are refuted, and the other two guard against implementations that would break the design's own text.
  better: Keep (a): give the fake two env tables. Install gets env A; GetEnv returns env B. Assert that every JNI call made during a finalize or at close arrives on env B.

Keep (c): count NewLocalRef/ExceptionOccurred against DeleteLocalRef in the fake, and require a net of 0 after each finalize.

Drop (d): it is not a defect, because LuaJIT resolves __gc at finalize time (lj_gc.c:573). Optionally create one userdata before the install in V1/V2 as a free regression check.

Replace (b)'s exact-string assertion with a test of the JNI failure path. Add V7b: the fake GetMethodID (and, separately, NewGlobalRef or NewWeakGlobalRef) returns NULL and leaves a pending exception. Require the core to call ExceptionClear, return a nonzero rc, leave the metatable untouched and leak no refs.

Make the design match: the core clears any exception pending from a JNI-part failure before returning rc (design.md:51-52). Also, or instead, widen the LuaJITArchitecture/OcljArch catch from UnsatisfiedLinkError|IllegalStateException to LinkageError|RuntimeException (design.md:87), so a NoSuchMethodError still starts the machine. The JVM probe (catch Throwable -> FAIL) remains the authoritative check of the method name and signature. A single run under -Xcheck:jni is a fine optional extra.

## T6 [major] The private-state probe as specified is blind to the failure path, to the close guards and to ref release. It is also uncapped, unlike machine states.

SCENARIO: (a) Nothing calls ocljSetValueDisposer on a state where it must fail. A bug that sets ocljValueClass before checking rc would count pushes with no wrapper, so the HashMap pins every Value forever, and no test would see it. (b) 'K live at close() -> none' cannot fail in the JVM: the C closing flag and Java's isOpen() mask each other. (c) Whether jnlua's DeleteGlobalRef ran at close cannot be seen, and the Count map keeps `first` strongly after close, so even a WeakReference check would read 'leaked'. (d) Machines use new LuaStateLuaJIT(cap) (LuaJITStateFactory.java:83); the design says a bare new LuaStateLuaJIT(). (e) Main-machine close is not guaranteed in the suite: Machine.stop -> tryClose returns false while executing (ocelot-brain Machine.scala:861-862), so this probe is the only deterministic close test.

CHANGE: Add a refusal case: delete registry['jnlua.Object'] on a private state and assert IllegalStateException and that later pushes are not counted (a map-size accessor or reflection). Add a Java counter of callbacks received while !isOpen() and assert 0 at close, which makes the C flag observable. Clear the map in a close() override. Then assert, via WeakReference plus System.gc() polling, that every pushed CountingValue becomes collectable after close, which proves the chain. Use the capped constructor. Extend acc-7 to cover the pushJavaObjectRaw override and ocljValueFinalized (synchronized) and ocljInstallValueFinalizer (private native).

CHECK: real=True sev=minor
  reasoning: Only part (a) holds, and only as a small gap in test coverage. Parts (b) to (e) are refuted or describe no failure.

(d) REFUTED. The design never says "bare new LuaStateLuaJIT()". It says "acc-6 style" (design.md:109). acc-6 gets its state from armFactory.createState() (OcljSmoke.scala:2040). In the additive arm that is OCLuaJITStateFactory (OcljSmoke.scala:1819-1820), which inherits ocelot-brain's createState(). createState calls create(Some(Int.MaxValue)) when limitMemory is set (ocelot-brain LuaStateFactory.scala:356). limitMemory is true by default (Settings.scala:173, application.conf:1536). The override then builds new LuaStateLuaJIT(_) (OcljArch.scala:613-614), so the state is already capped. An uncapped state would also work: jnlua builds every state through luaL_newstate (jnlua-luajit.c:290), which becomes lj52_newstate (lj52shim.h:161), and that callocs M for every state (lj52shim.c:2279-2285). The vgc fields do not use javaref or envfn (F7).

(b) TRUE BUT NOT A FAILURE. jnlua clears luaState before lua_close (jnlua-luajit.c:357-364), and isOpen() reads that field (LuaState.java:521-522, :2418-2420). The Java isOpen() check in ocljValueFinalized is therefore redundant with vgc_closing, and the JVM probe cannot fail on just one of them. Behaviour stays correct either way. The C flag is tested on its own by V3 plus the "drop the closing check" sabotage (design.md:103, :107-108). Two layered guards hiding each other is not a defect.

(c) MOSTLY WRONG. The C test V3 checks "original runs for each" at close (design.md:103). The real gcjavaobject reads only lua_touserdata(L,1) and its own upvalue (jnlua-luajit.c:2120-2134), and the wrapper's lua_call(1,0) keeps both. The map holding `first` after close is not a production leak. NativeLuaArchitecture.close sets lua = null after lua.close() (ocelot-brain NativeLuaArchitecture.scala:328-336; OC 1.12.58 :330-338), so the closed state and its map become unreachable. Only a WeakReference test that holds the state would see them. The design proposes no such test, and polling System.gc() would add a timing-dependent instrument for no product gain.

(e) Context, not a failure. tryClose() does return false while the machine is executing (ocelot-brain Machine.scala:861-862). The design already has the private probe's "close -> no crash" (design.md:111) and V3.

(a) REAL GAP, LOW STAKES. No JVM test covers a refused ocljSetValueDisposer. Only C V7 does (design.md:106). Suppose an implementation set ocljValueClass before checking rc. With no wrapper installed, no ocljValueFinalized call ever comes, so every counted Value would stay in the map. No planned test would catch that. The design text has the right order (design.md:70-71). Refusal is also almost unreachable on real states: jnlua always creates registry["jnlua.Object"] with a C __gc (jnlua-luajit.c:222). M is missing only on the luaL_newstate fallback (lj52shim.c:2288-2300). The gap is real, but minor.

Of the proposed changes, these are not needed: the capped constructor (already capped), a close() override that clears the map (the state is dropped), and the WeakReference + System.gc() polling. The counter of callbacks while !isOpen() is optional, since V3 already isolates the C flag. Extending acc-7 is cheap and follows precedent (OcljSmoke.scala:2059-2077 pins the monitor on the existing overrides), so it is worth taking.
  better: Make two small additions to the private-state probe and leave the rest of the design's probe as written.

(1) Refusal case. On the probe's own state, read registry["jnlua.Object"].__gc with getField(REGISTRYINDEX, ...) and keep it. Set __gc to false with setField, which is non-raw, so LuaJIT clears its negative metamethod cache (lj_meta.c:176-180). Call ocljSetValueDisposer and expect IllegalStateException. Restore the original __gc right away. Then use reflection to assert that ocljValueClass is still null and the count map is empty after one CountingValue push and two collects.

(2) Extend acc-7 with modifier checks: the pushJavaObjectRaw override is synchronized, ocljValueFinalized is synchronized, and ocljInstallValueFinalizer is private native.

Drop the other proposals. The probe is already capped because createState gives a capped state (OcljArch.scala:613-614 via LuaStateFactory.scala:356). No close() override is needed to clear the map, because NativeLuaArchitecture.close drops the state. Skip the WeakReference/System.gc() polling. Keep the counter of callbacks while !isOpen() only if it costs one field, since V3 plus its sabotage already test the C closing flag on its own.

## T7 [major] The per-arm expectation table and the new CHECKS baselines are incomplete. Because the shell gate does not count, a mis-keyed arm or a silent SKIP passes.

SCENARIO: OCLJ_PERSIST_BUNDLE=off skips the install (design.md:90) but has no row. If keyed on 'additive -> PASS', that negative-control run gains two unexplained gc failures beside its intended stk ones. If keyed on outcome, see T1. Additive with OCLJ_KERNEL=stock (the fallback branch) should be PASS and is unstated. design.md:119 says '66/63/64/60/47 (+ the new checks)', which leaves the new totals open. A gc milestone that SKIPs (hdd2 not found, the owners field renamed) is uncounted and invisible.

CHANGE: Write the table: additive (JIT on, JIT off, sieve) PASS; additive with stock kernel PASS; stock PASS; dropin LEAK; DISPOSE=off LEAK -NEGATIVE-CONTROL; BUNDLE=off LEAK -NEGATIVE-CONTROL. Pin the totals. gc-1 and gc-2 add +2 in all five arms; gc-0 and the probe's P ids apply to the three additive arms only. That gives 66+3+P, 63+2, 64+3+P, 60+3+P and 47+2. In applicable arms gc milestones must FAIL, never SKIP, on a missing disk or field. Optionally add OCLJ_EXPECT_CHECKS to smoke-test.sh.

CHECK: real=True sev=minor
  reasoning: Only a narrow part survives: an unspecified SKIP path. The rest is refuted or wrong.

CONFIRMED
- The shell gate does not count checks. It requires only `^SMOKE| VERDICT: PASS` and no `MILESTONE .*: FAIL` lines (test/native/smoke-test.sh:639, :657).
- The harness tallies only checks that go through milestone() (OcljSmoke.scala:49-53). A SKIP is a bare p() line, "not counted".
- The harness already uses that shape for failed preconditions that could really be bugs. mem-2 SKIPs on "no native architecture" (OcljSmoke.scala:484) and on "the raw state could not be read" (:497).
- So if gc-1/gc-2 are modelled on mem-2, a missing hdd2, owners field or witness would SKIP, and smoke-test.sh would still print SMOKE PASS.
- The design never says whether gc-1/gc-2 may SKIP (design.md:112-119). design.md:119 also leaves the new totals open ("+ the new checks").

REFUTED OR OVERSTATED
1. "A mis-keyed arm passes." A wrong expectation produces a FAIL line, and smoke-test.sh:657 catches it. Only keying on the install OUTCOME could hide a failure, and that is T1's finding, not this one.
2. The BUNDLE=off row.
   - design.md:90 already has OcljArch record whether it installed so the milestones can key on it. Under BundleRoots OFF the install is skipped, so gc expects LEAK. The missing row is a documentation gap only.
   - That run is a manual negative control (the switch exists only at OcljArch.scala:463-483). No script asserts its exact failing set.
   - It already fails stk, because stk's expectation is keyed on nativeMode alone ("additive" -> "bundle", OcljSmoke.scala:5480).
   - Two extra FAILs there would be noise, not a false pass.
3. "Additive with OCLJ_KERNEL=stock should be PASS" is wrong.
   - docs/roadmap.md:142 records that OCLJ_KERNEL=stock cannot run under the additive architecture. The bundled save/load asserts the patched kernel's shape, and OC's machine.lua dies after one tick with Error.InternalError. The standing-hook control therefore exists only on the dropin native.
   - No log under bench/runs contains "PHASE0 ROW: native=additive kernel=stock" or the fallback's "no patched kernel at".
   - A PASS row for an arm that never boots tests nothing. The design's placement before the kernel swap (design.md:83-84) still matters for the mod. It is not a harness row.
4. "Uncounted and invisible." Uncounted, yes; invisible, no. Every suite chain script copies `CHECKS` and `MILESTONE [^ ]+: (FAIL|SKIP)` lines into its summary (bench/runs/2026-10-05-window/scripts/chainG.sh:32; bench/runs/2026-10-05-reserve/scripts/chainF.sh:91). design.md:119 already asks for a CHECKS comparison.
5. The totals are off by one per additive arm.
   - There is no gc-0 in the design. The finding's "+3+P" counts a milestone that does not exist.
   - The design names only gc-1 and gc-2, expected in all five arms: additive PASS, stock PASS, dropin LEAK.
   - The private-state probe runs in the additive arms only, like acc-4/5/7 (SKIP in dropin, OcljSmoke.scala:1961; SKIP in stock, :1905).
   - Baselines by arm (harness.md:276): additive JIT on 66, dropin 63, additive JIT off 64, sieve 60, stock 47.
   - New totals: 68+P / 65 / 66+P / 62+P / 49.

SEVERITY: minor. The gap is a missing sentence and a missing number in the design, not a scenario the design forces. OCLJ_EXPECT_CHECKS is not needed: the run's CHECKS line plus pinned totals is enough.
  better: Add three lines to design.md's Tests section; leave out the additive+stock-kernel row and gc-0.
(1) In every arm where they run, gc-1/gc-2 never SKIP. A missing second HDD, a missing owners field or reflection failure, or a witness that never cleared is milestone(id, ok=false, reason). Use the acc-2 shape (OcljSmoke.scala:5492), not mem-2's SKIP shape (:484, :497).
(2) Pin the totals per arm: additive JIT on 68+P, dropin 65, additive JIT off 66+P, sieve 62+P, stock 49, where P is the number of private-state-probe ids, which run in the additive arms only.
(3) One line for OCLJ_PERSIST_BUNDLE=off: the harness skips the install, so gc-1/gc-2 expect LEAK through the install record (design.md:90). That run is already a failing negative control for stk.
To avoid T1's hole, the expectation should come from the configuration (nativeMode, OCLJ_DISPOSE, BundleRoots), not from the install outcome. A separate check that "installed == intended" makes an install failure in the additive arm a FAIL instead of a silent switch to LEAK. No OCLJ_EXPECT_CHECKS gate is needed.

## T8 [major] The witness proves two cycles only if its weak-key table stays alive. Built naively in the drop handler, it clears after ONE cycle, and only the fixed +12-step margin hides the gap.

SCENARIO: I measured this on the pinned luajit.exe (review-tests/witness.lua). With reg kept alive, the witness clears at collect 2, the same collect that finalizes the 16 userdata. If reg is a local of the drop handler that the step chain does not capture, the witness clears at collect 1 while 0/16 are finalized. A reopen keyed tightly to the witness then false-FAILs, and the witness no longer measures what design.md:114 says.

CHANGE: Capture reg in the step closure as an upvalue. Add a plain one-cycle twin witness and record both clear steps. On LuaJIT arms require the registry-shaped witness to clear strictly after the twin; on stock the same step is allowed. Replace the fixed '+12 steps then one reopen' with a bounded Java poll for owners == baseline after the witness clears, and report the lag in steps.

CHECK: real=True sev=major
  reasoning: I could not refute this finding. It is also worse than the finding says: the +12-step margin does NOT always hide the gap.

1. The mechanism is real. In LuaJIT, a table with weak keys still marks its values strongly (prototype/watchdog/luajit/src/lj_gc.c:216-217). Stack slots of a function that has returned are never marked (lj_gc.c:311-318). The harness plan creates `reg` as a LOCAL of the ocljgcdrop handler (understand/harness.md:155-156). The step chain only needs `wit` (harness.md:157). The house style also puts step functions at top level, like stkBurst (test/native/OcljSmoke.scala:2260-2283). So once the handler returns, `reg` is dead, and the witness behaves like a plain weak-value table. That is also the literal reading of design.md:114 ("a weak-value witness proves cycles ran"). I re-ran review-tests/witness.lua on the pinned luajit.exe, with the JIT on and with -joff. With `reg` alive the witness clears at collect 2. With `reg` dead it clears at collect 1, while 0 of 16 userdata are finalized. This matches the finding.

2. The finding says the +12-step margin hides the gap. It does not always. The margin guarantees exactly one more forced collect, for three reasons:
- The kernel runs collectgarbage("collect") once every 10 resumes (build/native/kernel/machine.lua:1623-1636).
- The kernel's pullSignal yields on every pass (ocelot-brain machine.lua:1413-1421).
- OpenOS copies its handler list before dispatching, so a timer(0) that re-arms itself fires at the earliest one pass later (ocelot-brain .../openos/lib/event.lua:54-60). So 12 steps are at least 12 resumes, which contain at least 1 forced collect.

One forced collect is not enough when the drop lands in the middle of an incremental cycle that has already marked gcHeld and its proxies. The proxies then survive that cycle as floating garbage, while the freshly made witness value does not. I tested this in review-skeptic/floating.lua on the pinned luajit.exe: step the incremental GC k times, drop, build both witnesses, finish the cycle, then run full collects.
- k=0 (drop before marking): 'inc-end fin=0 A=present B=cleared | full1 fin=16'.
- k=10 (drop after the proxies were marked): 'inc-end fin=0 A=present B=cleared | full1 fin=0 A=cleared | full2 fin=16'.

So with the dead-`reg` witness (B), the witness clears and one more full collect still leaves 0 of 16 finalized. The reopen at +12 is refused, and the milestone falsely FAILS on the FIXED build. The live-`reg` witness (A) clears at full1, and the next forced collect, which +12 guarantees, finalizes all 16. lj_gc_fullgc starts a fresh cycle and carries any pending mmudata into its own finalize phase (lj_gc.c:786-800, :706-716), so A + 12 is sound in both orderings.

How likely is the floating case? It needs an incremental cycle to complete between two forced collects. With the default pause of 200 this is rare. The harness's own -Docljit.gcpause knob (OcljSmoke.scala:4188-4205, and :5319-5336 for the restored machine) or heavy concurrent allocation makes it routine. The result is an intermittent false FAIL that points at the fix instead of at the instrument. Major is justified.

3. The proposed change. Capturing `reg` is right and is the minimal fix. The rest is excess:
- The twin witness gated as "strictly after" is flaky on LuaJIT. The twin clears at the first atomic phase and the registry witness at the second. If an incremental atomic phase in a resume's tail and the next forced collect both fall between two step checks, one check sees both clear at the same step, a false FAIL. That happens under exactly the pacing that makes the floating case matter.
- Replacing +12 and the reopen with a Java poll is unnecessary. With `reg` kept alive, +12 is sufficient by construction. The reopen is also the user-visible symptom, and the plan already checks owners == 0 from Java after "done" (harness.md:162-169).
  better: Keep the witness's weak-keyed `reg` strongly reachable for the chain's whole life. Hold it, with `wit`, in file-level upvalues next to gcHeld (for example gcWitReg and gcWit), and nil both when the chain paints done or nogc. Build it in the drop handler, in the same resume as gcHeld = nil. Amend design.md:114 to say "registry-shaped weak-value witness whose weak-keyed table stays reachable (a plain weak-value witness clears one cycle early)". Correct harness.md:182: the +12 margin is sound only with that shape. With it, at most one more atomic is needed after the witness clears, and 12 steps contain at least 1 forced full collect, which also runs pending finalizers. Keep '+12 steps then one reopen' and the Java owners==0 check unchanged. Optionally record a plain twin witness's clear step in the painted row as a diagnostic. If it is gated at all, assert twinAt <= witnessAt, never strictly before, because both can clear between the same two step checks.

## T9 [major] The fail-first plan names no arms and no expected reasons, and it has no Java-side or stock leg.

SCENARIO: Running only the additive arm on HEAD shows that the milestone fails, not that its PASS branch is reachable. The stock PASS rests on PUC 5.2 ephemerons and table __gc, read from lgc.c but never run in a machine. A milestone whose PASS can never happen (a stray holder, a wrong owners key) would first show up after the fix, and the fix would be blamed.

CHANGE: Fail-first on HEAD, into a fresh run dir. Additive must FAIL gc-0 and gc-1/gc-2 with 'witness cleared, owners 16, reopen too_many_open_handles'. Stock must PASS gc-1/gc-2. Dropin must PASS as LEAK. After the fix, the OCLJ_JAVA_SRC sabotages (T3) must fail exactly their probe ids, and DISPOSE=off must show LEAK on the fixed DLL.

CHECK: real=True sev=major
  reasoning: I could not refute the facts in the finding. I could only partly confirm the failure scenario it gives, and a stronger failure scenario sits right next to it.

The facts hold:
- design.md:118 says only "run gc-1/gc-2 on HEAD's build before the fix and keep the log". It names no arm and no expected outcome. The per-arm expectations at design.md:116-117 are the post-fix ones. The HEAD outcome is spelled out only in the evidence, at harness.md:177 ("additive and dropin: witness cleared, owners still 16, reopen too_many_open_handles... Stock should pass").
- No one has ever seen stock dispose in a machine:
  - harness.md:141 marks PUC's single cycle as "inferred... not measured".
  - critic.md:105-113 is a reading of lgc.c only.
  - docs/research/gc-dispose-leak.md:16-21 measured LuaJIT only.
  - test/native/OcljSmoke.scala has no dispose, owners or maxHandles check at all (grep finds none).
- Nothing proves the Java side can fail. negative-control.sh is C-only (harness.md:221-229), and the JVM private-state probe (design.md:109-111) has no sabotage.
- A stock leg is feasible:
  - The stock arm runs the restore block (OcljSmoke.scala:5450-5466; f4 and f5 are not stock-gated).
  - ocelot-brain's kernel keeps the proxy `__gc` (ocelot-brain machine.lua:1124-1127).
  - HandleValue.dispose reaches FileSystem.close (HandleValue.scala:17-29).
  - The filesystem node's host is the FileSystem itself (FileSystem.scala:26-28), so close removes the owner (:246-252).
  - So the PASS branch can be reached in principle. That is exactly what has never been run.

Where the stated scenario is weaker than claimed: "the fix would be blamed" is mostly prevented already. The post-fix 5-arm suite (design.md:119) includes stock. Stock never runs OcljArch or LuaStateLuaJIT (expectedArch at OcljSmoke.scala:1587-1589; harness.md:96-97). So if gc-1 fails in stock after the fix, that points at the milestone, not the fix. And LuaJIT-only ways for PASS to be unreachable (two cycles, a JIT trace holding a closure: critic.md:64, :198) cannot show before the fix in any arm. On its own reasoning the finding is minor.

Why it is still major: design.md:91 keys the milestone's expectation on a runtime "records whether it installed" flag. design.md:87-88 also tolerates a failed install ("START ANYWAY"), and design.md:89 has OcljArch make "the same call". Two concrete false passes follow:
1. On HEAD nothing installs. The additive arm therefore picks the LEAK expectation for itself, and gc-1/gc-2 PASS as -NEGATIVE-CONTROL. The "fail-first" log then shows no failure. Because design.md:118 writes no expected outcome, nobody would notice.
2. After the fix, a stale libdir-additive DLL behaves the same way. ocljInstallValueFinalizer is missing, which raises UnsatisfiedLinkError; the error is caught, installed=false is recorded, and the arm expects LEAK and PASSes.

The stk precedent keys its expectation on configuration (`nativeMode match`, OcljSmoke.scala:5479-5480), never on what happened at runtime. Writing "additive must FAIL on HEAD with <reason>" is what exposes this, so the finding's demand to name the arms and reasons is needed.

Problems with the proposed change:
- "gc-0" does not exist in this design.
- "DISPOSE=off must show LEAK" is already in design.md:117.
- It ignores staging. smoke-test.sh compiles LuaStateLuaJIT.java with javac and OcljArch.scala with scalac in EVERY arm, stock included (smoke-test.sh:257-258, :375-382, :394-397). A harness that calls ocljSetValueDisposer (the OcljArch install or the JVM probe) cannot compile against HEAD. The fail-first harness must therefore contain the milestones only.

Sound as written: the dropin arm as a permanent same-DLL control, and the DISPOSE=off negative control.
  better: Replace design.md:118 with a fail-first that is staged and has its outcomes written down, and fix the keying at design.md:91.

(1) Stage it. Add a milestone-only harness change first:
- the hdd2 disk;
- gc-1/gc-2;
- expectations keyed on configuration only.
It must not reference ocljSetValueDisposer, because smoke-test.sh compiles LuaStateLuaJIT.java and OcljArch.scala in every arm (smoke-test.sh:375-397). Land the OcljArch install and the JVM probe together with the fix.

(2) Key the expectation like stk does (OcljSmoke.scala:5479-5480):
- PASS is expected iff nativeMode=="additive" && BundleRoots && OCLJ_DISPOSE!="off".
- dropin, or additive with DISPOSE=off, expects LEAK and gets a -NEGATIVE-CONTROL id.
- stock expects PASS.
- If the install is configured on but did not happen, that is itself a FAIL that names the install error. It is never a quiet switch to the LEAK expectation. This removes design.md:91's runtime "installed" keying.

(3) Run on HEAD, into a fresh OCLJ_WORK, from the main session. Three arms, with these written expectations:
- additive JIT-on: gc-1 and gc-2 FAIL, reading "witness cleared, owners 16 -> 16, reopen too_many_open_handles";
- dropin: gc-1 and gc-2 PASS as LEAK;
- stock: gc-1 and gc-2 PASS, with owners 16 -> 0 and reopen ok. This is the only proof before the fix that the PASS branch can be reached.

(4) After the fix, prove the JVM probe can fail with OCLJ_JAVA_SRC sabotages, for example an identity-keyed map, or one dispose per finalized userdata with no counting. Each sabotage must fail exactly its own probe ids.

Drop "gc-0", which does not exist in this design. Drop the DISPOSE=off item, which is already at design.md:117.

## T10 [minor] f1b's anti-vacuity becomes non-specific: the 16 held hdd2 HandleValues alone satisfy its 'HandleValue' needle.

SCENARIO: f1b passes because of gc-2's hold even if udh were not on the persisted path. Its stated purpose is to guard f7 against vacuity (OcljSmoke.scala:5071-5081).

CHANGE: Count RecipeNeedle occurrences (as stk does, :834-843) and require at least 1 + n_gc. This doubles as gc-2's anti-vacuity: the restore minted the Values it disposes.

CHECK: (minor, not checked)

## T11 [minor] Instrument details that can mislead the owners read.

SCENARIO: (a) Hardcoding maxHandles=16 breaks when OCLJ_CONF_EXTRA mirrors the user's 64: the loop's bound ends it without a refusal. (b) The dispose path's FileSystem.close(context, handle) takes no lock, so reading under fileSystem.synchronized does not exclude the executor's set.remove. (c) owners.get(addr) == None, e.g. after onDisconnect's owners.remove, would read as 0. (d) The baseline is assumed to be 0 rather than measured.

CHANGE: Read Settings.get.maxHandles, pass the bound (2*max+1) in the signal, and measure baseline owners before the hold. Read owners under the LuaState monitor, which every disposal holds, or after the done row with the machine not executing. Require Some(set) and reopen=ok.

CHECK: (minor, not checked)

## T12 [minor] The probe's equal-but-distinct case locks in only the simultaneous case. The sequential case differs from stock and appears neither in the tests nor in the non-goals.

SCENARIO: a's proxy dies, and cycle 1 clears its registry entry. Before cycle 2, b (equal to a) is pushed. The kernel makes a new proxy, because the entry is gone, and the count goes to 2 with first=a. a's dispose then fires only when b's proxy dies, and b is never disposed. Stock disposes both.

CHANGE: Add the sequential case to the probe with its expected outcome, and list it in the non-goals.

CHECK: (minor, not checked)

## T13 [minor] Build-gate and banner nits.

SCENARIO: build-native.sh has two name regexes, NOCLJ at object level (:628) and OCLJN at export level (:871); the design names only the object-level one. 'Each changed gate shown failing on the old object' cannot apply to the JNLUA_OBJECT grep, since jnlua.c is unchanged: it needs a sabotaged copy, and should grep the compiled build/native/jnlua-luajit.c. A DISPOSE=off run prints 'SMOKE PASS -- OpenOS booted on LuaJIT' (smoke-test.sh:667-674).

CHANGE: Extend both regexes to 3 additive and 0 dropin. Prove the grep fails on a copy with the define altered. Add a NEGATIVE CONTROL banner for OCLJ_DISPOSE=off, as allowBytecode has.

CHECK: (minor, not checked)

## T14 [minor] Estimated suite cost of the new tests.

SCENARIO: Hold: 17 opens at limit 4 against a 1.5 budget, so about 11 or more sync calls at one tick each. Drop: 2 kernel collects (20 iterations or fewer) plus a 12-step margin. The ticks-per-sync rate comes from p0: 120 sync calls in 6.05 s of uptime. Measured: p0 = 120 sync calls in 6.05 s uptime (= 1 tick each). Estimated, not measured: ~30 ms of wall time per harness tick, and the resulting ~3-5 s per arm for gc-1 + gc-2 + probe. That gives ~15-25 s on an ~8 min 5-arm suite, plus one extra DISPOSE=off run (~96 s full) and BUNDLE=off if it is run. C side: vgc_test under 5 s, and one shim build per sabotage (a few seconds each) in negative-control.sh.

CHANGE: None needed. Record the measured WALL delta against the baselines in the gate log.

CHECK: (minor, not checked)

