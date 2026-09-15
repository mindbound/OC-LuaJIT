import java.io.ByteArrayInputStream;

import li.cil.repack.com.naef.jnlua.LuaState;
import li.cil.repack.com.naef.jnlua.LuaStateLuaJIT;

/**
 * Does the ADDITIVE native actually back our fourth LuaState class?
 *
 * WHAT THIS PROVES THAT NOTHING ELSE DOES.  The Java class compiles whether or
 * not the native side has matching symbols -- a `native` declaration is a
 * promise, not a check -- and `objdump` showing the right export names proves
 * only that strings match.  JNI resolution is what actually binds a method, it
 * happens lazily at first invocation, and it fails as an UnsatisfiedLinkError
 * naming the method.  So the only way to know the generator produced a usable
 * class is to load the library and run Lua through it.
 *
 * WHY IT MATTERS HERE PARTICULARLY.  The whole shipping model rests on this
 * one mechanism: OpenComputers runs Lua 5.2, 5.3 and 5.4 side by side because
 * each binds a different class, and OC-LuaJIT is additive rather than a
 * replacement only if our library binds LuaStateLuaJIT and OC's keeps LuaState.
 * Until this runs, that is an argument about macros.
 *
 *     java -cp <OC dev jar>;<our classes>;. LinkProbe <dll>
 */
public final class LinkProbe {

    private static int checks = 0;
    private static int failures = 0;

    /** LuaState.load takes an InputStream, not a String -- the same wrapping
      * OcljSmoke.evalStr does.  Guessing that signature cost a compile. */
    private static void load(LuaState L, String chunk, String name) throws Exception {
        L.load(new ByteArrayInputStream(chunk.getBytes("UTF-8")), name, "t");
    }

    private static void check(String what, boolean ok, String detail) {
        checks++;
        if (!ok) failures++;
        System.out.println((ok ? "  ok   " : "  FAIL ") + what + "   " + detail);
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: LinkProbe <path to libocluajit52-*.dll>");
            System.exit(2);
        }
        System.out.println("LinkProbe: " + args[0]);

        // If the library is missing or its dependencies do not resolve, this
        // throws here rather than confusingly later.
        System.load(args[0]);
        System.out.println("  loaded");

        // The constructor reaches lua_newstate, so an unbound symbol surfaces
        // immediately -- and it is the single most load-bearing native we have.
        LuaState L = new LuaStateLuaJIT();
        check("construct LuaStateLuaJIT", L != null, "lua_newstate bound");

        try {
            L.openLib(LuaState.Library.BASE);
            L.pop(1);
            L.openLib(LuaState.Library.STRING);
            L.pop(1);
            check("openLib BASE+STRING", true, "");

            // Prove it is OUR VM and not something that merely linked: the shim
            // plants _OCLJ_NATIVE at newstate, and no PUC build has it.
            load(L, "return tostring(rawget(_G, '_OCLJ_NATIVE'))", "=probe");
            L.call(0, 1);
            String marker = L.toString(-1);
            L.pop(1);
            check("_OCLJ_NATIVE marker", marker != null && marker.startsWith("luajit"),
                  "marker=" + marker);

            // A real round trip through load/call/toString, which exercises a
            // different group of natives from the constructor.
            load(L, "local t = {} for i = 1, 10 do t[i] = i * i end return t[7]", "=probe2");
            L.call(0, 1);
            String v = L.toString(-1);
            L.pop(1);
            check("run Lua and read a result", "49".equals(v), "7*7=" + v);

            // The version the sandbox would see.  LuaJIT with LUA52COMPAT
            // reports itself through eris as "Lua+Eris 5.2" in this build, so
            // this is recorded rather than asserted -- see the _VERSION trap in
            // the project notes: it does NOT discriminate the two natives.
            load(L, "return _VERSION", "=probe3");
            L.call(0, 1);
            System.out.println("  note  _VERSION = " + L.toString(-1) + "   (not a discriminator)");
            L.pop(1);
        } finally {
            L.close();
        }
        check("close", true, "");

        System.out.println("LinkProbe: " + (checks - failures) + "/" + checks + " checks passed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
