import os, sys

repo = "C:/Users/astro/Downloads/OC-LuaJIT"
out = "C:/Users/astro/claude-tmp/oclj/sabotage"
os.makedirs(out + "/countafter", exist_ok=True)

def sab(src, dst, old, new):
    s = open(src, "r", encoding="utf-8", newline="").read()
    n = s.count(old)
    if n != 1:
        sys.exit("anchor found %d times in %s" % (n, src))
    t = s.replace(old, new)
    open(dst, "w", encoding="utf-8", newline="").write(t)
    print("%s: %d -> %d bytes, CR %d" % (dst, len(s), len(t), t.count(chr(13))))

# (a) the save boundary: the second COLLECT removed from the harness adapter's save()
sab(repo + "/test/native/OcljArch.scala", out + "/OcljArch-onecollect.scala",
    "        // machine is its whole cost.\n        lua.gc(LuaState.GcAction.COLLECT, 0)\n      } catch {",
    "        // machine is its whole cost.\n      } catch {")

# (b) count AFTER the push: the ordering review C3/OC-3/J2 converged on, undone
old = ("        final int[] n = ocljCountPush(object);\n"
       "        final boolean created = n != null && n[0] == 1;\n"
       "        try {\n"
       "            super.pushJavaObjectRaw(object);\n"
       "        } catch (final Throwable t) {\n"
       "            ocljUncountPush(object, n, created);\n"
       "            throw t;\n"
       "        }\n")
new = ("        super.pushJavaObjectRaw(object);\n"
       "        final int[] n = ocljCountPush(object);\n")
sab(repo + "/src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java",
    out + "/countafter/LuaStateLuaJIT.java", old, new)
