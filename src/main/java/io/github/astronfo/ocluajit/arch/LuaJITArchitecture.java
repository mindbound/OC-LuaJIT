package io.github.astronfo.ocluajit.arch;

import java.io.IOException;
import java.io.InputStream;

import li.cil.oc.api.machine.Architecture;
import li.cil.oc.api.machine.Machine;
import li.cil.oc.server.machine.luac.LuaStateFactory;
import li.cil.oc.server.machine.luac.NativeLuaArchitecture;

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
}
