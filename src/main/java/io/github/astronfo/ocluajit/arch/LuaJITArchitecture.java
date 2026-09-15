package io.github.astronfo.ocluajit.arch;

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

    /** The only member we override. */
    @Override
    public LuaStateFactory factory() {
        return LuaJITStateFactory.INSTANCE;
    }
}
