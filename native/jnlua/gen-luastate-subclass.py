#!/usr/bin/env python3
"""Generate LuaStateLuaJIT.java -- our fourth JNLua LuaState class.

WHY A FOURTH CLASS AT ALL.  An OpenComputers Architecture needs a Java LuaState
to drive, and ours cannot be OC's own.  native/lj52shim.h forces
LUA_VERSION_NUM to 502, which makes jnlua.c emit the
`Java_li_cil_repack_com_naef_jnlua_LuaState_*` symbol family -- i.e. our native
is built as a REPLACEMENT for OC's 5.2 native.  That is right for the benchmark
harness, which substitutes the DLL wholesale, and impossible for the shipped
mod: OC loads its own 5.2 native in preInit and binds that class to it, and two
libraries cannot back one class.  See docs/research/shipping-model.md.

OC solves the identical problem for itself by giving each VM its own class --
LuaState (5.2), LuaStateFiveThree, LuaStateFiveFour -- because JNI derives
symbol names from the DECLARING class.  Redeclaring the inherited natives is
the whole mechanism; it is what mints the distinct family.

WHY GENERATED.  There are 85.  Hand-copying 85 signatures is 85 chances at a
wrong arity or type that compiles, links and misbehaves, and the list changes
when OC-JNLua is bumped.  Generated from the source of truth, it can be
regenerated and diffed -- but ONLY because the extraction is reconciled below.
The first version of this script silently emitted 84, having missed lua_load's
wrapped signature, which would have left that one method bound to
OpenComputers' library.

THE NESTED LuaDebug IS EMITTED TOO, AND IS MANDATORY.  LuaState carries a
`protected static class LuaDebug` with three natives.  jnlua.c's JNI_OnLoad
does referenceclass(JNI_LUASTATE_CLASS "$LuaDebug") at :1741 and FAILS THE
WHOLE LIBRARY LOAD without it -- measured: System.load threw
NoClassDefFoundError naming LuaStateLuaJIT$LuaDebug before a single Lua call.
It needs a (JZ)V constructor and a `long luaDebug` field (:1742-1743).
Emitting it as a SUBCLASS of LuaState.LuaDebug also fixes a hazard rather than
merely satisfying the loader: the base's getName()/getNameWhat() dispatch
virtually to the overridden natives, so a handle from our lua_getstack is read
by OUR library instead of OpenComputers' PUC code.

WHAT IT DOES NOT NEED.  Enum renumbering.  LuaStateFiveThree overrides
arith_operator_id and gc_action_id because 5.3 renumbered those enums; the base
carries the 5.2 numbering (LuaState.java:141, :154) and we ARE 5.2-class --
LuaJIT is 5.1 plus partial 5.2 compat.  Inheriting is correct.

WHAT IT DOES CARRY: THE MEMORY ACCOUNTING'S JAVA BOUNDARY.  Three overrides and
two natives of our own (docs/accounting-sync.md): the capped constructor and
setTotalMemory(int) hand the cap to the native side, and getFreeMemory() reads
the used figure back from it, so that an allocation never crosses JNI to
account for itself -- which it did on every call until 2026-10-03, and which
cost binarytrees 0.39 s against 0.21 s without the accounting.  jnlua's own
private fields stay the figures for a state that has not handed over: the
uncapped no-argument constructor, and the window inside super(memory).
`synchronized` is not inherited, so it is emitted on both overrides; jnlua's
exactness argument rests on every allocation and every read happening under
the LuaState's monitor.

AND VALUE DISPOSAL'S JAVA HALF.  Three more overrides (pushJavaObjectRaw,
pushJavaFunction, close), two more natives (ocljInstallValueFinalizer,
ocljValueGcCounters) and one callback, ocljValueFinalized, which nothing but
native/lj52shim.c's wrapper around the jnlua.Object metatable's __gc calls
(docs/research/gc-dispose-leak.md).  OpenComputers disposes a host Value
from the __gc of the TABLE proxy its kernel wraps it in (OC's machine.lua
:1124-1128), and LuaJIT finalizes no table, so on this VM Value.dispose was
never called: dropped file handles kept filesystem.open refusing until the
computer stopped, and every AE2 allItems() iterator kept its ME-grid
listener.  The wrapper finalizes the Value's USERDATA instead, and the count
kept here is what makes that safe:

- COUNTED, BECAUSE EVERY PUSH MINTS A NEW USERDATA.  jnlua.c's
  pushjavaobject interns nothing (OC-JNLua native/src/jnlua.c:2068-2080), and
  the kernel merges a re-pushed Value onto its EXISTING proxy through JNLua's
  __eq (`v == data`, machine.lua wrapSingleUserdata; DefaultJavaReflector.java
  :487-496), orphaning the new userdata while the Value lives on.  Disposing
  per userdata would close live handles.  So: dispose when the LAST userdata
  of that object dies.
- BY IDENTITY.  An equals-keyed map would run third-party hashCode/equals on
  every push, where stock runs none, and a mutable or contract-breaking one
  could file a re-push apart from its live proxy and dispose it underneath.
  The kernel merges on identity-or-existing.equals(new), so for the classes
  that override equals a count reaching zero disposes only when no OTHER live
  counted object o has o.equals(v); when one does, or equals throws, the
  Value leaks as on HEAD.  No in-tree Value overrides equals, so in-tree this
  check never runs.
- COUNTED BEFORE THE PUSH.  jnlua's push runs a GC checkpoint, so the dying
  previous userdata of the very object being re-pushed can be finalized
  inside super.pushJavaObjectRaw; counted first, its count stays above zero.
  A raw push that throws made no userdata with the metatable, and is rolled
  back; a function push that throws may have made one, and is not.
- THE CALLBACK IS NOT synchronized.  The GC step that runs it was started by
  a synchronized LuaState method, so its thread holds the monitor already.
  Were that ever false, blocking inside a GC step would wait on a thread that
  waits on this one; it checks Thread.holdsLock and leaks instead.
- A DISPOSE MAY NOT PUSH.  The upcall does not pass through jnlua's
  calljavafunction, so jnlua's luaThread is whatever coroutine ran the GC
  step; both pushes are refused while the disposer runs.
- close() DROPS IT ALL.  Nothing is disposed at lua_close, exactly as stock
  (the wrapper skips there), and the count, the class and the disposer --
  which holds the machine -- go with the state.

The generator also REFUSES if OC-JNLua grows another route into the two
natives that mint a jnlua.Object userdata, or if the methods overridden
here change shape: a Value pushed through a new route would not be counted,
and its userdata's death would take one off a count other pushes added.

    python3 native/jnlua/gen-luastate-subclass.py <OC-JNLua> [out.java]
"""

import re
import sys
from pathlib import Path

CLASS = "LuaStateLuaJIT"
PKG = "li.cil.repack.com.naef.jnlua"

NATIVE = re.compile(
    r"^(?P<mods>(?:public|protected|private)\s+"
    r"(?:synchronized\s+)?)native\s+(?P<rest>.+);$"
)


def native_decls(text):
    """Return (own, nested) declarations as [(modifiers, rest), ...].

    Signatures WRAP -- lua_load spans two physical lines -- so declarations are
    joined to their semicolon before matching.  Brace depth separates the outer
    class body (depth 1) from nested classes (deeper).
    """
    own, nested, buf, depth = [], [], "", 0
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith(("//", "*", "/*")):
            depth += raw.count("{") - raw.count("}")
            continue
        here = depth
        buf = (buf + " " + line).strip() if buf else line
        if buf.endswith(";"):
            m = NATIVE.match(" ".join(buf.split()))
            if m:
                (own if here <= 1 else nested).append(
                    (m.group("mods").strip(), m.group("rest").strip()))
            buf = ""
        elif "native " not in buf and not buf.endswith(","):
            buf = ""
        depth += raw.count("{") - raw.count("}")
    return own, nested


def qualify_params(rest):
    """Qualify LuaDebug in PARAMETER position as LuaState.LuaDebug.

    Java parameter types are INVARIANT.  Inside our class the bare name
    LuaDebug binds to our nested subclass, so `lua_getinfo(String, LuaDebug)`
    declares a NEW method instead of overriding the base one -- javac says
    "method does not override or implement a method from a supertype".  The
    RETURN type is left alone on purpose: covariant returns are legal, and
    lua_getstack returning our LuaDebug is exactly what we want, because that
    is how a handle we produce carries our natives with it.

    At runtime the distinction costs nothing: our instance IS-A
    LuaState.LuaDebug, and jnlua.c reads its luaDebug field through the field
    id it took from OUR class at JNI_OnLoad.
    """
    head, sep, tail = rest.partition("(")
    if not sep:
        return rest
    params, close, after = tail.partition(")")
    params = re.sub(r"(?<![.\w])LuaDebug", "LuaState.LuaDebug", params)
    return head + "(" + params + ")" + after


# VALUE DISPOSAL COUNTS WHAT THESE METHODS PUSH, AND NOTHING ELSE.  The two
# natives that mint a jnlua.Object userdata, and how many call sites each
# has in LuaState.java: lua_pushjavaobject only in pushJavaObjectRaw (:826),
# lua_pushjavafunction in pushJavaFunction (:788) and in the constructor's
# metamethod loop (:315), whose anonymous JavaFunctions are never a Value.
# Every other path in OC-JNLua -- the converter, the reflector, register() --
# goes through those two public methods.  A new call site is a route the
# count cannot see; a changed signature or finality is an override that
# would no longer override.  Either way: refuse, and let a human look.
MINT_CALLS = {"lua_pushjavaobject": 1, "lua_pushjavafunction": 2}
OVERRIDDEN = (
    "public synchronized void pushJavaObjectRaw(Object object) {",
    "public synchronized void pushJavaFunction(JavaFunction javaFunction) {",
    "public synchronized void close() {",
)


def value_routes(text):
    """Return a list of refusal reasons; empty when the routes are as above."""
    code = [raw.strip() for raw in text.splitlines()
            if not raw.strip().startswith(("//", "*", "/*"))]
    why = []
    for name, want in sorted(MINT_CALLS.items()):
        got = sum(line.count(name + "(") for line in code if "native " not in line)
        if got != want:
            why.append("%s( is called %d times outside its declaration, not %d"
                       % (name, got, want))
    for sig in OVERRIDDEN:
        if sum(1 for line in code if " ".join(line.split()) == sig) != 1:
            why.append("no single `%s` declaration" % sig[:-2])
    return why


def expand_leading_tabs(line, width=4):
    """Leading tabs -> spaces.  Only LEADING: a tab inside a string literal
    would be content, not indentation, and there are none today."""
    n = len(line) - len(line.lstrip("\t"))
    return " " * (width * n) + line[n:]


def value_disposal(w):
    """Emit Value disposal's Java half (see the docstring's last section).

    The names, the stats layout and the native signatures are a contract with
    native/lj52shim.c (the JNI entries and GetMethodID's name and signature
    for ocljValueFinalized), with LuaJITArchitecture.initialize(), and with
    the harness (test/native/OcljArch.scala, OcljSmoke.scala), which reaches
    them reflectively.  Rename nothing here without all of those.
    """
    w("\t/* ---- Value disposal: the Java half of lj52shim.c's jnlua.Object __gc wrapper ---- */")
    w("")
    w("\t/**")
    w("\t * Live userdata per counted object, by IDENTITY: [0] is the count, [1] is 1")
    w("\t * when the object's class overrides Object.equals. An IdentityHashMap calls")
    w("\t * neither hashCode nor equals, so no Value code runs when a Value is pushed.")
    w("\t */")
    w("\tprivate final IdentityHashMap<Object, int[]> ocljLive = new IdentityHashMap<Object, int[]>();")
    w("")
    w("\t/** Per class: does it override Object.equals? Reflection on the class, never a call. */")
    w("\tprivate final IdentityHashMap<Class<?>, Boolean> ocljEqualsClasses = new IdentityHashMap<Class<?>, Boolean>();")
    w("")
    w("\t/** How many entries of ocljLive have [1] == 1. While it is 0, a zero disposes. */")
    w("\tprivate int ocljEqLive;")
    w("")
    w("\t/** Set together by ocljSetValueDisposer, dropped together by close(). */")
    w("\tprivate Class<?> ocljValueClass;")
    w("")
    w("\tprivate Consumer<Object> ocljValueDisposer;")
    w("")
    w("\t/** True while the disposer, or an equals the merge check calls, runs. */")
    w("\tprivate boolean ocljInDispose;")
    w("")
    w("\t/**")
    w("\t * Sticky: a bookkeeping step failed (only an allocation can), so no NEW")
    w("\t * entry is made from then on. An object whose userdata went uncounted must")
    w("\t * never get an entry later, or a counted userdata of it could reach zero")
    w("\t * while the uncounted one's proxy is live. Existing entries keep counting.")
    w("\t */")
    w("\tprivate boolean ocljCountBroken;")
    w("")
    w("\t/* ocljValueStats(), in its order. Every one but ocljVsUnlocked under the monitor. */")
    w("\tprivate long ocljVsCounted;")
    w("\tprivate long ocljVsFinalized;")
    w("\tprivate long ocljVsDisposed;")
    w("\tprivate long ocljVsMissing;")
    w("\tprivate long ocljVsMergedSkips;")
    w("\tprivate final AtomicLong ocljVsUnlocked = new AtomicLong();")
    w("\tprivate long ocljVsDisposeErrors;")
    w("\tprivate long ocljVsRefused;")
    w("\tprivate long ocljVsBookkeepingFailures;")
    w("")
    w("\t/**")
    w("\t * Installs Value disposal: from here on every userdata of an instance of")
    w("\t * valueClass is counted, by identity, as it is pushed, and when the last one")
    w("\t * is finalized the object is handed to the disposer.")
    w("\t *")
    w("\t * THE DISPOSER'S CONTRACT. It runs inside a LuaJIT finalizer -- lj52shim.c's")
    w("\t * wrapper around the jnlua.Object __gc -- on the thread that holds this")
    w("\t * LuaState's monitor, with no Lua hooks, in the middle of whichever Lua API")
    w("\t * call ran the GC step. It must not touch this LuaState: pushJavaObjectRaw")
    w("\t * and pushJavaFunction throw IllegalStateException while it runs, and any")
    w("\t * other call would land on the stack of whatever coroutine was running. What")
    w("\t * it throws is counted (ocljValueStats) and dropped; it should log its own.")
    w("\t * Nothing is disposed at close(), exactly as stock OpenComputers.")
    w("\t *")
    w("\t * Call it once, before the first Value is pushed (LuaJITArchitecture does, in")
    w("\t * initialize()). A userdata pushed earlier is not counted, and if its object")
    w("\t * is pushed again after the install, that earlier userdata's death takes one")
    w("\t * off the new count and can dispose the object under a live proxy. A second")
    w("\t * call replaces the class and the disposer. Throws IllegalStateException when")
    w("\t * the state is closed or the native side refuses -- the message names the")
    w("\t * code, and nothing is installed -- and NullPointerException for a null")
    w("\t * argument.")
    w("\t */")
    w("\tpublic synchronized void ocljSetValueDisposer(Class<?> valueClass, Consumer<Object> disposer) {")
    w("\t\t// isOpen(), not check(): check() is package-private in OC's jar, and every")
    w("\t\t// other member this class uses is public or protected.")
    w("\t\tif (!isOpen()) {")
    w('\t\t\tthrow new IllegalStateException("Lua state is closed");')
    w("\t\t}")
    w("\t\tif (valueClass == null || disposer == null) {")
    w('\t\t\tthrow new NullPointerException(valueClass == null ? "valueClass" : "disposer");')
    w("\t\t}")
    w("\t\tfinal int rc = ocljInstallValueFinalizer(valueClass);")
    w("\t\tif (rc != 0) {")
    w("\t\t\tthrow new IllegalStateException(")
    w('\t\t\t\t"Value disposal not installed: lj52_vgc_install returned code " + rc + " (" + ocljVgcCode(rc) + ")");')
    w("\t\t}")
    w("\t\tocljValueClass = valueClass;")
    w("\t\tocljValueDisposer = disposer;")
    w("\t}")
    w("")
    w("\t/** Whether ocljSetValueDisposer succeeded on this state and it is not closed. */")
    w("\tpublic synchronized boolean ocljValueDisposalInstalled() {")
    w("\t\treturn ocljValueDisposer != null;")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * The Java side's counters: [0] Value userdata counted at a push, [1]")
    w("\t * finalizations seen under the monitor, [2] disposes that returned, [3]")
    w("\t * finalizations with no entry (pushed before the install, or uncounted),")
    w("\t * [4] zeros not disposed because a live equal object may share the proxy,")
    w("\t * [5] finalizations on a thread without the monitor (leaked), [6] disposes")
    w("\t * that threw, [7] pushes refused inside a dispose, [8] live entries now,")
    w("\t * [9] bookkeeping steps that threw (one at a push stops new entries).")
    w("\t */")
    w("\tpublic synchronized long[] ocljValueStats() {")
    w("\t\tfinal long[] s = new long[10];")
    w("\t\ts[0] = ocljVsCounted;")
    w("\t\ts[1] = ocljVsFinalized;")
    w("\t\ts[2] = ocljVsDisposed;")
    w("\t\ts[3] = ocljVsMissing;")
    w("\t\ts[4] = ocljVsMergedSkips;")
    w("\t\ts[5] = ocljVsUnlocked.get();")
    w("\t\ts[6] = ocljVsDisposeErrors;")
    w("\t\ts[7] = ocljVsRefused;")
    w("\t\ts[8] = ocljLive.size();")
    w("\t\ts[9] = ocljVsBookkeepingFailures;")
    w("\t\treturn s;")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * The native side's counters (lj52_vgc_counters): [0] wrapper callbacks")
    w("\t * made, [1] callbacks that left a Java exception, [2] finalizations skipped")
    w("\t * at close, [3] skipped for want of a JNIEnv, [4] 1 if the wrapper is")
    w("\t * installed. All zero on a closed state, whose record is gone.")
    w("\t */")
    w("\tpublic synchronized long[] ocljValueGcCounters() {")
    w("\t\tfinal long[] out = new long[5];")
    w("\t\tif (isOpen()) {")
    w("\t\t\tocljValueGcCounters(out);")
    w("\t\t}")
    w("\t\treturn out;")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * Counted BEFORE the native push: jnlua's push runs a GC checkpoint, which")
    w("\t * can finalize the dying previous userdata of this very object; counted")
    w("\t * first, its count stays above zero there. A push that throws made no")
    w("\t * userdata with the jnlua.Object metatable -- lua_setmetatable is the last")
    w("\t * step of jnlua.c's pushjavaobject (OC-JNLua native/src/jnlua.c:2068-2080)")
    w("\t * -- so the count is rolled back.")
    w("\t */")
    w("\t@Override")
    w("\tpublic synchronized void pushJavaObjectRaw(Object object) {")
    w("\t\tfinal int[] n = ocljCountPush(object);")
    w("\t\tfinal boolean created = n != null && n[0] == 1;")
    w("\t\ttry {")
    w("\t\t\tsuper.pushJavaObjectRaw(object);")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\tocljUncountPush(object, n, created);")
    w("\t\t\tthrow t;")
    w("\t\t}")
    w("\t\tif (n != null) {")
    w("\t\t\tocljVsCounted++;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * The second route to a jnlua.Object userdata: an object that is both a")
    w("\t * Value and a JavaFunction would otherwise have its function userdata's")
    w("\t * death take one off a count only raw pushes added.")
    w("\t *")
    w("\t * NOT rolled back when it throws, unlike pushJavaObjectRaw. jnlua's")
    w("\t * pushjavafunction_protected gives the userdata its metatable FIRST and")
    w("\t * then allocates the closure (OC-JNLua native/src/jnlua.c:656-660), so a")
    w("\t * push that fails there -- out of memory, on a capped machine -- leaves a")
    w("\t * userdata that will be finalized. Keeping its count costs a leak when")
    w("\t * no userdata was made; dropping it could dispose a live Value.")
    w("\t */")
    w("\t@Override")
    w("\tpublic synchronized void pushJavaFunction(JavaFunction javaFunction) {")
    w("\t\tfinal int[] n = ocljCountPush(javaFunction);")
    w("\t\tsuper.pushJavaFunction(javaFunction);")
    w("\t\tif (n != null) {")
    w("\t\t\tocljVsCounted++;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * Nothing is disposed at lua_close (the wrapper skips there, as stock")
    w("\t * OpenComputers disposes nothing at close), so the entries left are only")
    w("\t * references: drop them, and the disposer, which holds the machine.")
    w("\t */")
    w("\t@Override")
    w("\tpublic synchronized void close() {")
    w("\t\tsuper.close();")
    w("\t\tif (!isOpen()) {")
    w("\t\t\tocljLive.clear();")
    w("\t\t\tocljEqualsClasses.clear();")
    w("\t\t\tocljEqLive = 0;")
    w("\t\t\tocljValueClass = null;")
    w("\t\t\tocljValueDisposer = null;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/** Pre-counts o if it is to be counted: its entry, or null. */")
    w("\tprivate int[] ocljCountPush(final Object o) {")
    w("\t\tif (ocljInDispose) {")
    w("\t\t\tocljVsRefused++;")
    w('\t\t\tthrow new IllegalStateException("a Value\'s dispose may not push into Lua");')
    w("\t\t}")
    w("\t\tfinal Class<?> c = ocljValueClass;")
    w("\t\tif (c == null || !c.isInstance(o)) {")
    w("\t\t\treturn null;")
    w("\t\t}")
    w("\t\ttry {")
    w("\t\t\tint[] n = ocljLive.get(o);")
    w("\t\t\tif (n == null) {")
    w("\t\t\t\tif (ocljCountBroken) {")
    w("\t\t\t\t\treturn null;")
    w("\t\t\t\t}")
    w("\t\t\t\tfinal int eq = ocljOverridesEquals(o.getClass()) ? 1 : 0;")
    w("\t\t\t\tn = new int[2];")
    w("\t\t\t\tn[1] = eq;")
    w("\t\t\t\tocljLive.put(o, n);")
    w("\t\t\t\tocljEqLive += eq;")
    w("\t\t\t}")
    w("\t\t\tn[0]++;")
    w("\t\t\treturn n;")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\tocljCountBroken = true;")
    w("\t\t\tocljVsBookkeepingFailures++;")
    w("\t\t\treturn null;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * Rolls back a pre-count whose push threw. If the entry existed before and")
    w("\t * reaches zero here, every other userdata of the object died during the")
    w("\t * failed push: it is unreachable, and goes the way of any zero.")
    w("\t */")
    w("\tprivate void ocljUncountPush(final Object o, final int[] n, final boolean created) {")
    w("\t\tif (n == null) {")
    w("\t\t\treturn;")
    w("\t\t}")
    w("\t\ttry {")
    w("\t\t\tif (ocljLive.get(o) != n || --n[0] > 0) {")
    w("\t\t\t\treturn;")
    w("\t\t\t}")
    w("\t\t\tocljLive.remove(o);")
    w("\t\t\tocljEqLive -= n[1];")
    w("\t\t\tif (!created) {")
    w("\t\t\t\tocljAtZero(o);")
    w("\t\t\t}")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\tocljVsBookkeepingFailures++;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * Called ONLY by lj52shim.c's wrapper around the jnlua.Object __gc, inside a")
    w("\t * LuaJIT finalizer, when a userdata whose object is an instance of the")
    w("\t * installed class dies -- never at lua_close, where the wrapper skips. The")
    w("\t * native side looks it up by name and signature (GetMethodID")
    w('\t * "ocljValueFinalized", "(Ljava/lang/Object;)V"): rename neither alone.')
    w("\t *")
    w("\t * NOT synchronized, deliberately. The GC step that runs the finalizer was")
    w("\t * started by a synchronized LuaState method, so this thread holds the")
    w("\t * monitor already. Were that ever false, blocking here would wait on a")
    w("\t * thread that may be waiting on this one; a leak is the safe failure, so it")
    w("\t * counts and returns. Nothing may escape into the wrapper.")
    w("\t */")
    w("\tprivate void ocljValueFinalized(final Object value) {")
    w("\t\tif (!Thread.holdsLock(this)) {")
    w("\t\t\tocljVsUnlocked.incrementAndGet();")
    w("\t\t\treturn;")
    w("\t\t}")
    w("\t\ttry {")
    w("\t\t\tocljVsFinalized++;")
    w("\t\t\tfinal int[] n = ocljLive.get(value);")
    w("\t\t\tif (n == null) {")
    w("\t\t\t\tocljVsMissing++;")
    w("\t\t\t\treturn;")
    w("\t\t\t}")
    w("\t\t\tif (--n[0] > 0) {")
    w("\t\t\t\treturn;")
    w("\t\t\t}")
    w("\t\t\tocljLive.remove(value);")
    w("\t\t\tocljEqLive -= n[1];")
    w("\t\t\tocljAtZero(value);")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\tocljVsBookkeepingFailures++;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * The last counted userdata of value is gone. The kernel merges a push onto")
    w("\t * a live proxy when existing.equals(new), so while any object of a class")
    w("\t * that overrides equals is live, a zero disposes only if none of them")
    w("\t * equals this one; otherwise, or if equals throws, the object leaks as on")
    w("\t * HEAD, never disposed under a live proxy. The gate is the EXISTING")
    w("\t * object's class: an overriding equals may accept a value whose own class")
    w("\t * does not override it.")
    w("\t */")
    w("\tprivate void ocljAtZero(final Object value) {")
    w("\t\tif (!isOpen()) {")
    w("\t\t\treturn;")
    w("\t\t}")
    w("\t\tif (ocljEqLive > 0 && ocljMayBeMerged(value)) {")
    w("\t\t\tocljVsMergedSkips++;")
    w("\t\t\treturn;")
    w("\t\t}")
    w("\t\tocljDispose(value);")
    w("\t}")
    w("")
    w("\t/** Whether a live counted object of an equals-overriding class equals value. */")
    w("\tprivate boolean ocljMayBeMerged(final Object value) {")
    w("\t\tfinal boolean was = ocljInDispose;")
    w("\t\tocljInDispose = true;")
    w("\t\ttry {")
    w("\t\t\tfor (final Map.Entry<Object, int[]> e : ocljLive.entrySet()) {")
    w("\t\t\t\tfinal Object o = e.getKey();")
    w("\t\t\t\tif (e.getValue()[1] != 0 && o.equals(value)) {")
    w("\t\t\t\t\treturn true;")
    w("\t\t\t\t}")
    w("\t\t\t}")
    w("\t\t\treturn false;")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\treturn true;")
    w("\t\t} finally {")
    w("\t\t\tocljInDispose = was;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/** Hands value to the disposer, refusing pushes while it runs. */")
    w("\tprivate void ocljDispose(final Object value) {")
    w("\t\tfinal Consumer<Object> disposer = ocljValueDisposer;")
    w("\t\tif (disposer == null) {")
    w("\t\t\treturn;")
    w("\t\t}")
    w("\t\tfinal boolean was = ocljInDispose;")
    w("\t\tocljInDispose = true;")
    w("\t\ttry {")
    w("\t\t\tdisposer.accept(value);")
    w("\t\t\tocljVsDisposed++;")
    w("\t\t} catch (final Throwable t) {")
    w("\t\t\tocljVsDisposeErrors++;")
    w("\t\t} finally {")
    w("\t\t\tocljInDispose = was;")
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/** Cached per class. When the reflection fails, assume it does: that only skips. */")
    w("\tprivate boolean ocljOverridesEquals(final Class<?> c) {")
    w("\t\tBoolean b = ocljEqualsClasses.get(c);")
    w("\t\tif (b == null) {")
    w("\t\t\tboolean overrides;")
    w("\t\t\ttry {")
    w('\t\t\t\toverrides = c.getMethod("equals", Object.class)')
    w("\t\t\t\t\t.getDeclaringClass() != Object.class;")
    w("\t\t\t} catch (final Throwable t) {")
    w("\t\t\t\toverrides = true;")
    w("\t\t\t}")
    w("\t\t\tb = Boolean.valueOf(overrides);")
    w("\t\t\tocljEqualsClasses.put(c, b);")
    w("\t\t}")
    w("\t\treturn b.booleanValue();")
    w("\t}")
    w("")
    w("\t/** lj52_vgc_install's codes (LJ52_VGC_* in native/lj52shim.h). */")
    w("\tprivate static String ocljVgcCode(int rc) {")
    w("\t\tswitch (rc) {")
    w("\t\t\tcase 1:")
    w('\t\t\t\treturn "ENORECORD: no lua_State, or no lj52 record for it";')
    w("\t\t\tcase 2:")
    w('\t\t\t\treturn "EJVM: GetJavaVM failed";')
    w("\t\t\tcase 3:")
    w('\t\t\t\treturn "EREF: a global or weak global reference could not be made";')
    w("\t\t\tcase 4:")
    w('\t\t\t\treturn "EMETHOD: no ocljValueFinalized(Object) on this class";')
    w("\t\t\tcase 5:")
    w('\t\t\t\treturn "ENOMT: the registry\'s jnlua.Object metatable is not a table";')
    w("\t\t\tcase 6:")
    w('\t\t\t\treturn "ENOGC: the jnlua.Object __gc is not a C function";')
    w("\t\t\tcase 7:")
    w('\t\t\t\treturn "ELUA: the protected install failed in Lua";')
    w("\t\t\tdefault:")
    w('\t\t\t\treturn "unknown code";')
    w("\t\t}")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * lj52_vgc_install through the additive JNI entry: 0, or the code of the")
    w("\t * step that refused. It never leaves a Java exception pending, so the code")
    w("\t * always arrives.")
    w("\t */")
    w("\tprivate native int ocljInstallValueFinalizer(Class<?> valueClass);")
    w("")
    w("\t/** lj52_vgc_counters into out[0..4]; see ocljValueGcCounters(). */")
    w("\tprivate native void ocljValueGcCounters(long[] out);")
    w("")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = (Path(sys.argv[1]) / "src/main/java/li/cil/repack/com/naef/jnlua/LuaState.java")
    if not src.is_file():
        print("no LuaState.java at %s" % src, file=sys.stderr)
        return 2

    text = src.read_text(encoding="utf-8", errors="replace")
    own, nested = native_decls(text)

    # RECONCILE AND REFUSE.  Every uncommented `native` line must be accounted
    # for, as either emitted or explicitly excluded as nested.  A shortfall
    # means a method stays inherited and binds to OpenComputers' library --
    # discovered, if at all, as an UnsatisfiedLinkError at class load or as
    # silent cross-library execution.  Counting is cheap.
    seen = sum(1 for raw in text.splitlines()
               if "native " in raw and not raw.strip().startswith(("//", "*", "/*")))
    if not own:
        print("no native declarations found -- has LuaState.java changed shape?", file=sys.stderr)
        return 1
    if len(own) + len(nested) != seen:
        print("REFUSING: %d uncommented 'native' lines, but %d own + %d nested = %d "
              "accounted for.  A wrapped or reshaped signature is being missed, and the "
              "missing method would silently bind to OpenComputers' library."
              % (seen, len(own), len(nested), len(own) + len(nested)), file=sys.stderr)
        return 1
    why = value_routes(text)
    if why:
        print("REFUSING: LuaState.java's routes into a jnlua.Object userdata have changed "
              "shape, and Value disposal's count would no longer see every Value pushed:\n  "
              + "\n  ".join(why), file=sys.stderr)
        return 1

    nested_names = sorted({d[1].split("(")[0].split()[-1] for d in nested})
    L = []
    w = L.append
    w("package %s;" % PKG)
    w("")
    w("import java.io.IOException;")
    w("import java.io.InputStream;")
    w("import java.io.OutputStream;")
    w("import java.util.IdentityHashMap;")
    w("import java.util.Map;")
    w("import java.util.concurrent.atomic.AtomicLong;")
    w("import java.util.function.Consumer;")
    w("")
    w("/**")
    w(" * The OC-LuaJIT LuaState: a fourth JNLua binding class alongside OC's own.")
    w(" *")
    w(" * GENERATED by native/jnlua/gen-luastate-subclass.py from OC-JNLua's")
    w(" * LuaState.java. Do not edit; edit the generator and regenerate.")
    w(" *")
    w(" * JNI resolves a native to Java_<package>_<declaring class>_<method>, so")
    w(" * redeclaring the inherited natives here -- and only that -- gives our library")
    w(" * its own symbol family, Java_li_cil_repack_com_naef_jnlua_%s_*." % CLASS)
    w(" * That is how OpenComputers runs 5.2, 5.3 and 5.4 side by side in one JVM, and")
    w(" * it is what lets OC-LuaJIT be ADDITIVE rather than a replacement.")
    w(" *")
    w(" * Six behavioural overrides, and only these. The capped constructor,")
    w(" * getFreeMemory() and setTotalMemory(int) keep the memory accounting's figures")
    w(" * on the native side, so an allocation never crosses JNI to account for itself")
    w(" * (docs/accounting-sync.md). pushJavaObjectRaw(Object),")
    w(" * pushJavaFunction(JavaFunction) and close() keep Value disposal's count of")
    w(" * live userdata per Value, which native/lj52shim.c's jnlua.Object __gc wrapper")
    w(" * takes back down through ocljValueFinalized (docs/research/gc-dispose-leak.md).")
    w(" * Nothing else is overridden: we are 5.2-class, so the base class's arith/gc")
    w(" * enum numbering is already correct.")
    if nested:
        w(" *")
        w(" * The nested LuaDebug is MANDATORY: jnlua.c JNI_OnLoad does")
        w(" * referenceclass(JNI_LUASTATE_CLASS \"$LuaDebug\") at :1741 and fails the")
        w(" * entire library load without it. Emitting it as a SUBCLASS also makes")
        w(" * the base getName()/getNameWhat() dispatch to OUR natives.")
    w(" */")
    w("public class %s extends LuaState {" % CLASS)
    w("")
    w("\tpublic %s() {" % CLASS)
    w("\t\tsuper();")
    w("\t}")
    w("")
    w("\tpublic %s(int memory) {" % CLASS)
    w("\t\tsuper(memory);")
    w("\t\t// Hand the cap to the native side: from here on an allocation does not")
    w("\t\t// cross JNI to account for itself. Outside the monitor, and safely so:")
    w("\t\t// this object has not yet escaped its constructor.")
    w("\t\tocljSetTotalMemory(memory);")
    w("\t}")
    w("")
    w("\t/* ---- the memory accounting's Java boundary: docs/accounting-sync.md ---- */")
    w("")
    w("\t/**")
    w("\t * The native side's figure once the state has handed over, which every")
    w("\t * allocation keeps exact; jnlua's own before that and after close, where")
    w("\t * the native side answers -1. An uncapped state never hands over, so it")
    w("\t * asks no native at all: exactly jnlua's behaviour, and a library built")
    w("\t * before these natives still serves it (computer.lua.limitMemory=false).")
    w("\t */")
    w("\t@Override")
    w("\tpublic synchronized int getFreeMemory() {")
    w("\t\tif (super.getTotalMemory() < 1) {")
    w("\t\t\treturn super.getFreeMemory();")
    w("\t\t}")
    w("\t\tlong used = ocljUsedMemory();")
    w("\t\tif (used < 0) {")
    w("\t\t\treturn super.getFreeMemory();")
    w("\t\t}")
    w("\t\treturn (int) Math.max(0L, (long) super.getTotalMemory() - used);")
    w("\t}")
    w("")
    w("\t/**")
    w("\t * jnlua's validation and its refusal on an uncapped state run first; the")
    w("\t * native side then holds the new cap for the very next allocation.")
    w("\t */")
    w("\t@Override")
    w("\tpublic synchronized void setTotalMemory(int value) {")
    w("\t\tsuper.setTotalMemory(value);")
    w("\t\tocljSetTotalMemory(super.getTotalMemory());")
    w("\t}")
    w("")
    w("\t/** The native side's used figure; -1 before the handover, after close. */")
    w("\tprivate native long ocljUsedMemory();")
    w("")
    w("\t/** Hands the cap to the native side, switching it to native accounting. */")
    w("\tprivate native void ocljSetTotalMemory(int total);")
    w("")
    value_disposal(w)
    w("\t/* ---- the %d inherited natives, redeclared so they bind to OUR library ---- */" % len(own))
    w("")
    for mods, rest in own:
        w("\t@Override")
        w("\t%s native %s;" % (mods, qualify_params(rest)))
        w("")
    if nested:
        w("\t/**")
        w("\t * Our own activation record, REQUIRED by jnlua.c's JNI_OnLoad.")
        w("\t *")
        w("\t * It extends LuaState.LuaDebug for two reasons. Covariance: our")
        w("\t * lua_getstack returns LuaDebug, which only overrides the base method if")
        w("\t * this is a subtype of the base return type. And DISPATCH: the base's")
        w("\t * getName()/getNameWhat() call lua_debugname()/lua_debugnamewhat()")
        w("\t * virtually, so they land on the overrides below and therefore on OUR")
        w("\t * library -- without which a handle from our lua_getstack would be read")
        w("\t * by OpenComputers PUC code, i.e. type confusion across two VMs.")
        w("\t *")
        w("\t * super(_, false) deliberately: the base constructor guardian calls ITS")
        w("\t * OWN lua_debugfree, which binds to OpenComputers library. We own it here.")
        w("\t */")
        w("\tprotected static class LuaDebug extends LuaState.LuaDebug {")
        w("")
        w("\t\t/**")
        w("\t\t * jnlua.c looks this up BY NAME on THIS class (GetFieldID, :1743); the")
        w("\t\t * base field of the same name is private and therefore not ours.")
        w("\t\t */")
        w("\t\tprivate long luaDebug;")
        w("")
        w("\t\tprivate Object finalizeGuardian;")
        w("")
        w("\t\tprotected LuaDebug(long luaDebug, boolean ownDebug) {")
        w("\t\t\tsuper(luaDebug, false);")
        w("\t\t\tthis.luaDebug = luaDebug;")
        w("\t\t\tif (ownDebug) {")
        w("\t\t\t\tfinalizeGuardian = new Object() {")
        w("")
        w("\t\t\t\t\t@Override")
        w("\t\t\t\t\tprotected void finalize() {")
        w("\t\t\t\t\t\tsynchronized (LuaDebug.this) {")
        w("\t\t\t\t\t\t\tlua_debugfree();")
        w("\t\t\t\t\t\t}")
        w("\t\t\t\t\t}")
        w("\t\t\t\t};")
        w("\t\t\t}")
        w("\t\t}")
        w("")
        for mods, rest in nested:
            w("		@Override")
            w("		%s native %s;" % (mods, qualify_params(rest)))
            w("")
        w("\t}")
    w("}")

    # SPOTLESS OWNS THE FORMATTING OF THIS FILE, so emit what spotless wants
    # rather than what OC-JNLua's own source uses.  It uses tabs; the GTNH
    # build runs spotlessJavaCheck over src/main/java and fails on them, which
    # is exactly how CI broke on the commit that first added this class --
    # "Compile the mod" passed and "Run post-build checks" did not.  Expanding
    # here rather than post-processing keeps the generator the single source of
    # truth: regenerate, and the result is already committable.
    out = "\n".join(expand_leading_tabs(x) for x in L) + "\n"
    if len(sys.argv) > 2:
        dest = Path(sys.argv[2])
        dest.parent.mkdir(parents=True, exist_ok=True)
        # open(), not Path.write_text(newline=): that keyword is Python 3.10+,
        # and build-native.sh runs this with whatever Python 3 it finds.
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        print("wrote %s  (%d redeclared, %d nested excluded: %s)"
              % (dest, len(own), len(nested), ", ".join(nested_names) or "-"))
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
