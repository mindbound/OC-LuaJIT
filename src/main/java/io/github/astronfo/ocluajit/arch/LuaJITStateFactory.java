package io.github.astronfo.ocluajit.arch;

import li.cil.oc.server.machine.luac.LuaStateFactory;
import li.cil.repack.com.naef.jnlua.LuaState;
import li.cil.repack.com.naef.jnlua.LuaStateLuaJIT;
import scala.Option;

/**
 * The fourth LuaStateFactory: OpenComputers' loader, pointed at our library and
 * our LuaState class.
 *
 * `version()` IS THE WHOLE HOOK. LuaStateFactory computes
 *
 * libraryName = "libjnlua" + version() + "-" + platform + extension
 *
 * as a PRIVATE field, resolves and System.loads it in init(), and records the
 * outcome in private state that createState() reads. A subclass may override
 * version(), create() and openLibs(); it can touch none of the rest. So
 * declaring "jit52" sends OpenComputers' own loader hunting for
 * libjnluajit52-<platform><ext> -- the name native/build-native.sh gives the
 * additive variant -- and on finding it, everything downstream is inherited.
 *
 * WHAT IS INHERITED IS NOT INCIDENTAL. createState() is where OpenComputers
 * shapes the sandbox: os.setlocale("C"), the removal of the Lua 5.1 compat
 * entries (unpack, loadstring, math.log10, table.maxn), dropping dofile and
 * loadfile, and giving each state its own RNG instead of C rand(). A copy of
 * that in our source would be a second definition of OpenComputers' sandbox
 * shape, and the first upstream change to it would make our architecture
 * quietly different from the other three in a security-relevant way.
 *
 * WHERE THE LIBRARY HAS TO LIVE, and it is not where you would expect. When
 * debug.forceNativeLibPathFirst is unset -- i.e. always, for a player -- init()
 * resolves the library as a CLASSPATH RESOURCE at
 * /assets/opencomputers/lib/<libraryName>. That path is built from
 * OpenComputers' own resource domain, and we cannot change it without
 * overriding init(), which would strand us on the wrong side of those private
 * fields again. Minecraft gives every mod one shared classloader, so a
 * resource shipped in OUR jar under assets/opencomputers/lib/ is found by that
 * lookup. It is another mod's asset namespace and we are a guest in it; what
 * makes it safe is that the FILENAME is ours alone -- libjnluajit52-* collides
 * with nothing OpenComputers ships, and build-native.sh fails the build if our
 * library exports a single symbol in OpenComputers' LuaState family.
 *
 * NOT YET RUN. Compiled, and structurally identical to the ocelot-brain
 * adapter in test/native/OcljArch.scala which boots a real machine today.
 * Exercising THIS file needs a Minecraft instance.
 */
public final class LuaJITStateFactory extends LuaStateFactory {

    /**
     * OpenComputers' own factories are Scala objects; this is the equivalent.
     * One instance, because the base class caches the loaded library in
     * instance state and a second instance would redo the whole resolution.
     */
    public static final LuaJITStateFactory INSTANCE = new LuaJITStateFactory();

    private LuaJITStateFactory() {}

    /**
     * Chosen so libraryName() comes out as libjnluajit52-<platform><ext>.
     *
     * "jit52" and not "jit": the 52 is a claim about the LANGUAGE surface, not
     * about LuaJIT's own version, and it is the claim openLibs() below makes
     * good on. Changing this string renames the file OpenComputers hunts for,
     * so build-native.sh's DLL_NAME must change with it.
     */
    @Override
    public String version() {
        return "jit52";
    }

    /**
     * @param maxMemory Scala's Option[Int], erased; empty means no ceiling.
     *
     *                  The ceiling must be passed to the CONSTRUCTOR rather than set afterwards:
     *                  the counting allocator has to be installed at lua_newstate time on a GC64
     *                  build, and installing it on a running state is unsafe on LuaJIT. That is
     *                  also why LuaStateLuaJIT keeps the two-constructor shape it inherits.
     */
    @Override
    public LuaState create(final Option<Object> maxMemory) {
        if (maxMemory.isDefined()) {
            return new LuaStateLuaJIT(((Number) maxMemory.get()).intValue());
        }
        return new LuaStateLuaJIT();
    }

    /**
     * OpenComputers' 5.2 library set, exactly.
     *
     * BIT32 and not UTF8. We are a 5.2-class VM -- LuaJIT is 5.1 plus partial
     * 5.2 compat -- machine.lua is written against that surface, and the split
     * is not cosmetic: it is why QuickOS boots on neither us nor OpenComputers'
     * own 5.2 native (docs/research/os-shape-census.md). Adding UTF8 here to
     * look more capable would make us a fourth dialect that no OS targets.
     */
    @Override
    public void openLibs(final LuaState state) {
        state.openLib(LuaState.Library.BASE);
        state.openLib(LuaState.Library.BIT32);
        state.openLib(LuaState.Library.COROUTINE);
        state.openLib(LuaState.Library.DEBUG);
        state.openLib(LuaState.Library.ERIS);
        state.openLib(LuaState.Library.MATH);
        state.openLib(LuaState.Library.STRING);
        state.openLib(LuaState.Library.TABLE);
        state.pop(8);
    }
}
