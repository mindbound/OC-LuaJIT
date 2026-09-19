package io.github.astronfo.ocluajit.arch;

import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Field;

import net.minecraft.nbt.NBTTagCompound;

import li.cil.oc.OpenComputers;
import li.cil.oc.Settings;
import li.cil.oc.api.machine.Architecture;
import li.cil.oc.api.machine.Machine;
import li.cil.oc.common.SaveHandler;
import li.cil.oc.server.machine.luac.LuaStateFactory;
import li.cil.oc.server.machine.luac.NativeLuaAPI;
import li.cil.oc.server.machine.luac.NativeLuaArchitecture;
import li.cil.oc.server.machine.luac.PersistenceAPI;
import li.cil.repack.com.naef.jnlua.LuaGcMetamethodException;
import li.cil.repack.com.naef.jnlua.LuaRuntimeException;
import li.cil.repack.com.naef.jnlua.LuaStackTraceElement;
import li.cil.repack.com.naef.jnlua.LuaState;
import scala.Enumeration;

/**
 * LuaJIT-backed OpenComputers architecture: OpenComputers' own machine, running
 * our VM.
 *
 * THIS CLASS USED TO IMPLEMENT Architecture FROM SCRATCH, and the stub that did
 * was on its way to roughly a thousand lines: the component/computer/os/system/
 * unicode/userdata API bindings, the closure-yield protocol between
 * runThreaded and runSynchronized, the RAM cap arithmetic, and eris persistence.
 * All of that already exists in OpenComputers, it is identical for Lua 5.2, 5.3
 * and 5.4, and OpenComputers factored it exactly the way a fourth VM would need:
 *
 * public abstract class NativeLuaArchitecture implements Architecture {
 * public abstract LuaStateFactory factory();
 * ...
 * }
 *
 * `factory()` is the ONLY abstract member, and OpenComputers' own three VMs are
 * one-line subclasses of this same class. So is ours. A survey of the
 * equivalent class in ocelot-brain found one single reference to `factory` in
 * its whole body -- `factory.createState()` inside initialize() -- and no
 * version-conditional logic anywhere in it: nothing branches on 5.2 versus 5.3,
 * nothing special-cases bit32 or utf8, nothing reads factory.version. Every
 * difference between the three VMs lives in LuaStateFactory. That is the right
 * shape and we should not fight it: the VM is what we are replacing, and the
 * machine around it is not.
 *
 * WHAT THIS COSTS: a dependency on li.cil.oc.server.*, which is
 * OpenComputers' implementation rather than its published li.cil.oc.api.
 * Deliberate, and the alternative is worse. Reimplementing against the public
 * API alone would mean maintaining our own copy of the sandbox setup and the
 * persistence protocol -- both security-relevant, both changing when
 * OpenComputers changes -- and a divergence there is a silent behavioural
 * difference between architectures, not a compile error. Inheriting means a
 * breaking change upstream is a BUILD failure, which is the failure mode to
 * prefer.
 *
 * BUT ONLY AT BUILD TIME, and the distinction is not academic. We compile
 * against a version pinned in dependencies.gradle; the @Mod dependency in
 * OCLuaJIT.java carries NO version bound, so a player may load this jar beside
 * an OpenComputers whose NativeLuaArchitecture has changed shape. That is a
 * NoSuchMethodError or AbstractMethodError at class load -- a startup crash,
 * not the compile error above. Bounding the dependency is on the roadmap; it is
 * left undone rather than guessed at, because a malformed FML version range
 * stops the mod loading at all and nothing in this repository can run FML to
 * check one.
 *
 * PROVEN, THOUGH NOT HERE. The identical construction runs today against
 * ocelot-brain -- see test/native/OcljArch.scala -- where a real machine boots
 * AxisOS on our LuaState while OpenComputers' own PUC-Lua 5.2 native is loaded
 * in the same JVM and reports itself as a different VM. ocelot-brain is a port
 * of this code and its class is if anything MORE restrictive than this one
 * (there, lua/kernelMemory/ramScale are private[machine]; here they are public),
 * so what compiles against it compiles against this. What has NOT been run is
 * this file, because running it needs a Minecraft instance.
 */
@Architecture.Name("LuaJIT")
public class LuaJITArchitecture extends NativeLuaArchitecture {

    /**
     * OpenComputers instantiates architectures reflectively through this exact
     * constructor; Machine.add refuses a class that lacks it.
     */
    public LuaJITArchitecture(final Machine machine) {
        super(machine);
        // Resolve the private 'apis' field NOW, not on the first save: if
        // OpenComputers ever renames it, the failure must be a machine that
        // refuses to start, not a world that cannot be saved.
        resolveApis();
    }

    /** Which VM backs this architecture. */
    @Override
    public LuaStateFactory factory() {
        return LuaJITStateFactory.INSTANCE;
    }

    /**
     * OUR resource domain, deliberately not OpenComputers'. See initialize().
     */
    private static final String KERNEL_RESOURCE = "/assets/ocluajit/lua/machine.lua";

    /**
     * Swap in OC-LuaJIT's patched kernel after the inherited initialize() runs.
     *
     * WHY THIS IS NEEDED AT ALL. NativeLuaArchitecture.initialize() loads the
     * kernel with classOf[Machine].getResourceAsStream(scriptPath +
     * "machine.lua") -- a fixed path in OPENCOMPUTERS' resource domain. The
     * benchmark harness gets its patched kernel in by putting it first on the
     * classpath so it shadows OC's, which works only because the harness builds
     * that classpath. A mod cannot: FML loads mod jars in an order we do not
     * choose, and OpenComputers' own jar holds that exact resource. Unlike the
     * native, where the FILENAME is ours alone and collision is impossible by
     * construction, here the path is byte-identical -- so "ours wins" would be
     * a coin flip, and every deadline and JIT result depends on the answer.
     *
     * WHY NOT REPLACE initialize() OUTRIGHT. It is sixteen lines, but four of
     * them are `apis.foreach(_.initialize())`, and `apis` is private with no
     * accessor -- those four lines cannot be reproduced from outside the
     * package at all. super.initialize() is the only way to get the APIs
     * installed, so we let it run and then change the one thing we need.
     *
     * THE STACK CONTRACT. initialize() leaves the kernel thread as the first
     * stack value and runThreaded resumes exactly that. So: drop it, load ours,
     * make a thread again. If the load throws after the pop, the stack no
     * longer holds a thread and the machine must NOT start -- hence false
     * rather than a swallowed exception.
     *
     * PROVEN IN THE HARNESS, where the same sequence runs against ocelot-brain
     * (test/native/OcljArch.scala; ocelot-brain hides `lua` behind
     * private[machine], so it reaches the field reflectively while this reads
     * the public accessor). With the patched kernel present ONLY at our path
     * and nothing at OpenComputers', that run reports _OCLJ_KERNEL=watchdog,
     * 147 traces where the standing hook gives ~2500, and a sandbox loop at
     * 0.0047 s where the standing hook gives 0.47 s.
     */
    @Override
    public boolean initialize() {
        if (!super.initialize()) return false;

        final InputStream patched = LuaJITArchitecture.class.getResourceAsStream(KERNEL_RESOURCE);
        if (patched == null) {
            // NOT silent, and not fatal. OpenComputers' own kernel runs fine on
            // our VM -- that is the harness's stock-kernel arm -- but it
            // reinstates the standing count hook, which is what stops traces
            // being entered at all. A hundredfold slowdown is not something a
            // server operator should have to discover from a benchmark.
            io.github.astronfo.ocluajit.OCLuaJIT.LOG.warn(
                "No patched kernel at " + KERNEL_RESOURCE
                    + " in this jar: falling back to "
                    + "OpenComputers' own machine.lua and its standing deadline hook. Computers "
                    + "will run, but the JIT will thrash. This is a packaging fault, not a "
                    + "configuration one.");
            return true;
        }

        try {
            lua().pop(1);
            lua().load(patched, "=machine", "t");
            lua().newThread();
        } catch (final IOException e) {
            io.github.astronfo.ocluajit.OCLuaJIT.LOG.error(
                "The patched kernel at " + KERNEL_RESOURCE
                    + " failed to load; refusing to start "
                    + "this machine, because the stack no longer holds a kernel thread.",
                e);
            return false;
        } finally {
            try {
                patched.close();
            } catch (final IOException ignored) {}
        }
        return true;
    }

    // ------------------------------------------------------------------ //
    // Persistence: ONE blob, not two.
    // ------------------------------------------------------------------ //

    /**
     * WHY save() AND load() ARE OVERRIDDEN WHOLESALE.
     *
     * NativeLuaArchitecture.save persists a running computer as TWO roots in
     * TWO eris.persist calls (NativeLuaArchitecture.scala:396-437; load
     * :349-394): persist(1), the kernel coroutine, into "<address>_kernel",
     * and, while the machine's state stack holds SynchronizedCall or
     * SynchronizedReturn, persist(2) -- the closure the kernel yielded for the
     * driver call, or the result table -- into "<address>_stack". Each call
     * is its own reference space. The closure (machine.lua:1116-1124) holds
     * four OPEN upvalues into the kernel coroutine's stack: args, target,
     * unwrapUserdata, wrapUserdata. Under our serializer an open upvalue whose
     * owning thread is not already in the reference table makes p_function
     * chase the owner (eris_lj.c:543, elj_find_owner_any) and write the WHOLE
     * kernel thread into the stack blob.
     *
     * THAT IS A SECOND KERNEL UNIVERSE. Measured on binary 1a9e8e17
     * (serializer/tests/stack-universe.lua, U1): the stack blob is 11640 bytes
     * against a kernel of 11377; two persisted proxies cost FOUR userdata.load
     * calls; the restored closure's upvalue-id / args-slot / registry all point
     * at the second kernel; and a sync call whose result is a host Value comes
     * back NOT-UNWRAPPED -- a plain table the live kernel's registry has never
     * seen. Nothing raises. That is the silent mode.
     *
     * THE FIX NEEDS NO SERIALIZER CHANGE (U2/U2r/U3 pass on the shipping
     * binary): persist ONE table {[1]=kernel thread, [2]=closure-or-table} in
     * ONE call. The closure's upvalues then find the thread already in the
     * reference table and go out as TAG_UPVALOPEN into the same blob: 11650
     * bytes = kernel + 273, one load per proxy, upvalue-id / args-slot /
     * registry identical to a never-saved machine. On load, unpersist once
     * and push t[1] to index 1 and t[2] (when present) to index 2 -- the exact
     * stack shape runThreaded and runSynchronized assert (:174-176, :202-203).
     *
     * WHOLESALE, NOT WRAPPED: super.save/super.load do their persists
     * unconditionally with no hook between, so both are reproduced here line
     * by line against :349-437 -- every side effect, in order, including the
     * failure protocol (nbt.removeTag("state")) that Machine relies on. Each
     * line below carries the source line it reproduces.
     *
     * THE ONE REFLECTIVE READ. The PersistenceAPI instance lives in the private
     * 'apis' array, as its LAST element ("Persistence has to go last",
     * :49-57). It must be THAT instance and not a fresh one: it owns the
     * persistKey the kernel's shell-fill recipes were keyed with at load
     * (machine.lua:1085, :1158), and its load(nbt) restores that key from NBT
     * exactly as stock does. A fresh PersistenceAPI mints a new random key,
     * and every recipe keyed with the old one is silently missed.
     *
     * NO MIGRATION PATH, deliberately. A blob written in the old two-call
     * shape has a bare THREAD as its "_kernel" root, not a table, and load()
     * below refuses that shape by name ("Invalid kernel.") before anything is
     * pushed: the computer comes back stopped, loudly. (The build fingerprint
     * is NOT what protects us here -- a two-call blob written by this same
     * native would pass it. The shape check is.) The bundle reuses the
     * "_kernel" tag and writes no "_stack"; a stale "_stack" from an older
     * save is inert (SaveHandler.cleanSaveData removes only empty
     * directories).
     *
     * NO SWITCH, deliberately. The harness adapter (test/native/OcljArch.scala)
     * carries an OFF switch so its gate can be shown to FAIL on the two-call
     * shape; this class does not, because a switch here would be readable
     * from a server's environment and would silently reinstate the defect.
     * The release jar always bundles.
     */

    private static final Enumeration.Value SYNCHRONIZED_CALL = li.cil.oc.server.machine.Machine.State$.MODULE$
        .SynchronizedCall();
    private static final Enumeration.Value SYNCHRONIZED_RETURN = li.cil.oc.server.machine.Machine.State$.MODULE$
        .SynchronizedReturn();

    /** The original's `state.contains(...)`, on the same Stack (:347). */
    private boolean inState(final Enumeration.Value s) {
        return ((li.cil.oc.server.machine.Machine) machine()).state()
            .contains(s);
    }

    /** Scala's assert is always on; Java's is not. This is the Scala one. */
    private static void check(final boolean condition, final String what) {
        if (!condition) throw new AssertionError("assertion failed: " + what);
    }

    /** `"\tat " + e.getLuaStackTrace.mkString("\n\tat ")`, or "" when empty (:389, :428). */
    private static String luaTrace(final LuaRuntimeException e) {
        final LuaStackTraceElement[] st = e.getLuaStackTrace();
        if (st == null || st.length == 0) return "";
        final StringBuilder sb = new StringBuilder("\tat ");
        for (int i = 0; i < st.length; i++) {
            if (i > 0) sb.append("\n\tat ");
            sb.append(st[i]);
        }
        return sb.toString();
    }

    /** Resolved once per instance from the private 'apis' field; see resolveApis(). */
    private NativeLuaAPI[] apis;
    private PersistenceAPI persistence;

    private void resolveApis() {
        if (persistence != null) return;
        final NativeLuaAPI[] found;
        try {
            final Field f = NativeLuaArchitecture.class.getDeclaredField("apis");
            f.setAccessible(true);
            found = (NativeLuaAPI[]) f.get(this);
        } catch (final ReflectiveOperationException e) {
            throw new IllegalStateException(
                "NativeLuaArchitecture has no readable private field 'apis' (NativeLuaAPI[]): this "
                    + "OpenComputers build has changed shape and OC-LuaJIT cannot persist against it",
                e);
        }
        if (found == null || found.length == 0 || !(found[found.length - 1] instanceof PersistenceAPI)) {
            throw new IllegalStateException(
                "NativeLuaArchitecture.apis does not end in a PersistenceAPI ("
                    + (found == null ? "null"
                        : found.length + " entries, last "
                            + (found.length == 0 ? "none"
                                : found[found.length - 1].getClass()
                                    .getName()))
                    + "): 'Persistence has to go last' no longer holds and OC-LuaJIT cannot persist "
                    + "against this OpenComputers build");
        }
        apis = found;
        persistence = (PersistenceAPI) found[found.length - 1];
    }

    /**
     * Build {[1]=the thread at index 1, [2]=the value at index 2 when withStack}
     * above the live stack, persist it through the ONE PersistenceAPI, and take
     * it down again -- also when persist throws, so a failed world save leaves
     * the running machine's stack exactly as it found it.
     */
    private byte[] persistBundle(final LuaState lua, final boolean withStack) {
        final int top = lua.getTop();
        try {
            lua.newTable(); // ... t
            lua.pushValue(1); // ... t thread
            lua.rawSet(-2, 1); // ... t t[1] = kernel thread
            if (withStack) {
                lua.pushValue(2); // ... t v
                lua.rawSet(-2, 2); // ... t t[2] = closure | result table
            }
            return persistence.persist(top + 1);
        } finally {
            lua.setTop(top);
        }
    }

    @Override
    public void save(final NBTTagCompound nbt) {
        resolveApis(); // no-op after the constructor; kept as a guard
        final LuaState lua = lua();

        // Unlimit memory while persisting. (:398-400)
        if (Settings.get()
            .limitMemory()) {
            lua.setTotalMemory(Integer.MAX_VALUE);
        }

        try {
            // Save the kernel state (which is always at stack index one). (:405)
            check(lua.isThread(1), "lua.isThread(1)");
            // While in a driver call we have one object on the global stack: either
            // the function to call the driver with, or the result of the call. (:408-411)
            // The bundle takes index 1 ALWAYS and index 2 ONLY in the two sync
            // states: save also runs in Restarting/Stopping, where index 2 may be a
            // boolean or an error string, and the original does not persist it.
            final boolean inCall = inState(SYNCHRONIZED_CALL);
            final boolean withStack = inCall || inState(SYNCHRONIZED_RETURN);
            if (withStack) {
                check(inCall ? lua.isFunction(2) : lua.isTable(2), inCall ? "lua.isFunction(2)" : "lua.isTable(2)");
            }
            // ONE persist of {[1]=kernel, [2]=closure|table} under the "_kernel"
            // tag -- was persist(1) to "_kernel" and persist(2) to "_stack". (:407, :412)
            SaveHandler.scheduleSave(
                machine().host(),
                nbt,
                machine().node()
                    .address() + "_kernel",
                persistBundle(lua, withStack));

            nbt.setInteger("kernelMemory", (int) Math.ceil(kernelMemory() / ramScale())); // (:415)

            for (final NativeLuaAPI api : apis) { // (:417-419)
                api.save(nbt);
            }

            try { // (:421-425)
                lua.gc(LuaState.GcAction.COLLECT, 0);
            } catch (final Throwable t) {
                OpenComputers.log()
                    .warn(
                        "Error cleaning up loaded computer @ " + machine().host()
                            .machinePosition()
                            + ". This either means the server is badly overloaded or a user created an evil __gc method, accidentally or not.");
                machine().crash("error in garbage collector, most likely __gc method timed out");
            }
        } catch (final LuaRuntimeException e) { // (:427-429)
            OpenComputers.log()
                .warn(
                    "Could not persist computer @ " + machine().host()
                        .machinePosition() + ".\n" + e.toString() + luaTrace(e));
            nbt.removeTag("state");
        } catch (final LuaGcMetamethodException e) { // (:430-432)
            OpenComputers.log()
                .warn(
                    "Could not persist computer @ " + machine().host()
                        .machinePosition() + ".\n" + e.toString());
            nbt.removeTag("state");
        }

        // Limit memory again. (:436)
        recomputeMemory(
            machine().host()
                .internalComponents());
    }

    @Override
    public void load(final NBTTagCompound nbt) {
        if (!machine().isRunning()) return; // (:350)
        resolveApis(); // no-op after the constructor; kept as a guard
        final LuaState lua = lua();

        // Unlimit memory use while unpersisting. (:353-355)
        if (Settings.get()
            .limitMemory()) {
            lua.setTotalMemory(Integer.MAX_VALUE);
        }

        try {
            // Try unpersisting Lua, because that's what all of the rest depends
            // on. First, clear the stack, meaning the current kernel. (:360)
            lua.setTop(0);

            // ONE unpersist of the bundle -- was "_kernel" and then, in the sync
            // states, "_stack". (:362, :369)
            persistence.unpersist(
                SaveHandler.load(
                    nbt,
                    machine().node()
                        .address() + "_kernel"));
            // The bundle is a table. Anything else -- nothing at all because
            // allowPersistence is off, or a bare thread because the blob was written
            // in the old shape (which the fingerprint gate refuses before this) -- is
            // the corrupt-save case the original answers with this same message.
            if (lua.getTop() != 1 || !lua.isTable(1)) {
                throw new LuaRuntimeException("Invalid kernel.");
            }
            final boolean inCall = inState(SYNCHRONIZED_CALL);
            final boolean withStack = inCall || inState(SYNCHRONIZED_RETURN);
            lua.rawGet(1, 1); // bundle thread
            if (withStack) lua.rawGet(1, 2); // bundle thread v
            lua.remove(1); // thread [v] -- what runThreaded/runSynchronized assert
            if (!lua.isThread(1)) { // (:363-367)
                // This shouldn't really happen, but there's a chance it does if
                // the save was corrupt (maybe someone modified the Lua files).
                throw new LuaRuntimeException("Invalid kernel.");
            }
            if (withStack) { // (:368-375)
                if (!(inCall ? lua.isFunction(2) : lua.isTable(2))) {
                    // Same as with the above, should not really happen normally, but
                    // could for the same reasons.
                    throw new LuaRuntimeException("Invalid stack.");
                }
            }

            kernelMemory_$eq((int) (nbt.getInteger("kernelMemory") * ramScale())); // (:377)

            for (final NativeLuaAPI api : apis) { // (:379-381)
                api.load(nbt);
            }

            try { // (:383-387)
                lua.gc(LuaState.GcAction.COLLECT, 0);
            } catch (final Throwable t) {
                OpenComputers.log()
                    .warn(
                        "Error cleaning up loaded computer @ " + machine().host()
                            .machinePosition()
                            + ". This either means the server is badly overloaded or a user created an evil __gc method, accidentally or not.");
                machine().crash("error in garbage collector, most likely __gc method timed out");
            }
        } catch (final LuaRuntimeException e) { // (:389)
            // The original throws a checked java.lang.Exception here, which a Java
            // override of an interface method with no throws clause cannot.
            // Machine.load catches Throwable, logs it and closes the machine either
            // way; the wrapper's class is the only difference.
            throw new RuntimeException(e.toString() + luaTrace(e), e);
        }

        // Limit memory again. (:393)
        recomputeMemory(
            machine().host()
                .internalComponents());
    }
}
