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
 * RUN IN GAME since 2026-09-16: OpenComputers' loader found our library under
 * that path and logged it (docs/roadmap.md, THE FIRST IN-GAME RUN). Same shape
 * as the ocelot-brain adapter in test/native/OcljArch.scala, which the harness runs.
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
     * OpenComputers' 5.2 LIST of libraries, opened as its 5.2 factory opens
     * them, over a LuaJIT that is our own fork.
     *
     * The list is OpenComputers': BIT32 and not UTF8. machine.lua builds the
     * sandbox from whichever of these tables exist (`utf8 = utf8 and {...}`),
     * so opening UTF8 here would change the sandbox's shape, not only add to
     * it. The split is also why QuickOS boots on neither us nor OpenComputers'
     * own 5.2 native (docs/research/os-shape-census.md); whether to add utf8
     * is a separate decision (docs/roadmap.md, the 5.2-class row).
     *
     * What a library CONTAINS is ours to decide: since 2026-10-13 our LuaJIT is
     * a fork that may take Lua 5.3 functions (docs/roadmap.md, the 5.2-class
     * row). STRING carries Lua 5.3.6's string.pack, string.unpack and
     * string.packsize, which the LuaJIT build registers in lib_string.c
     * (native/luajit/patch-strpack-register.sh, native/luajit/oclj_strpack.c)
     * and machine.lua already copies into the sandbox; TABLE and COROUTINE
     * carry LuaJIT's own table.move and coroutine.isyieldable. The language is
     * the fork's too, whatever the list: its {@code & | ~ << >>} and unary
     * {@code ~} compute Lua 5.3.6's 64-bit integer results, and raise where a
     * result has more than 53 significant bits, which no double holds
     * (native/luajit/oclj_bitop.h; README.md, "Lua dialect"). There is still
     * no integer subtype, no // and no bitwise metamethod. A program that
     * tests for string.pack (or table.move, coroutine.isyieldable) finds it
     * (Plan9k takes string.pack as its 5.3 test); one that tests for
     * math.type, math.tointeger or utf8 does not, and one that tests _VERSION
     * finds 5.2.
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
