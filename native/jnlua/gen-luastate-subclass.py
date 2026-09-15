#!/usr/bin/env python3
"""Generate LuaStateLuaJIT.java -- our fourth JNLua LuaState class.

WHY A FOURTH CLASS AT ALL.  An OpenComputers Architecture needs a Java LuaState
to drive, and ours cannot be OC's own.  native/lj52shim.h forces
LUA_VERSION_NUM to 502, which makes jnlua.c emit the
`Java_li_cil_repack_com_naef_jnlua_LuaState_*` symbol family -- i.e. our native
is built as a REPLACEMENT for OC's 5.2 native.  That is fine for the benchmark
harness, which substitutes it wholesale, and impossible for the shipped mod:
OpenComputers loads its own 5.2 native in preInit and binds that class to it,
and two libraries cannot back one class.

OC solves the identical problem for itself by giving each VM its own class --
LuaState (5.2), LuaStateFiveThree, LuaStateFiveFour -- because JNI symbol names
derive from the DECLARING class.  A version subclass is thin (332 and 290 lines
against LuaState.java's 3145) and consists almost entirely of redeclaring the
native methods with @Override.  That redeclaration IS the mechanism: it is what
mints the distinct symbol family.

WHY GENERATED RATHER THAN WRITTEN.  There are 87 of them.  Hand-copying 87
signatures is a transcription exercise with 87 chances to introduce a subtly
wrong arity or type, and the failure would surface as an UnsatisfiedLinkError at
runtime or, worse, as a mismatched signature that links and misbehaves.  The
list also changes when OC-JNLua is bumped.  So it is derived from the source of
truth and can be regenerated and diffed.

WHAT IT DOES NOT NEED.  Nothing behavioural.  LuaStateFiveThree overrides
arith_operator_id and gc_action_id because 5.3 renumbered those enums; the base
class already carries the 5.2 numbering (LuaState.java:141, :154) and we ARE
5.2-class -- LuaJIT is 5.1 plus partial 5.2 compat.  Inheriting is correct, and
an override here would be a bug waiting to happen.

    python3 native/jnlua/gen-luastate-subclass.py <OC-JNLua> [out.java]
"""

import re
import sys
from pathlib import Path

CLASS = "LuaStateLuaJIT"
PKG = "li.cil.repack.com.naef.jnlua"

# A native declaration in LuaState.java, e.g.
#     protected native void lua_newstate(int apiversion, long luaState);
#
# SIGNATURES WRAP.  lua_load spans two physical lines, and a line-at-a-time
# regex silently skipped it -- yielding 84 of 85 methods, with the missing one
# left inherited and therefore bound to OpenComputers' library rather than ours.
# That is the precise failure this class exists to prevent, so declarations are
# joined to their semicolon before matching, and the count is reconciled below.
NATIVE = re.compile(
    r"^(?P<mods>(?:public|protected|private)\s+"
    r"(?:synchronized\s+)?)native\s+(?P<rest>.+);$"
)


def native_decls(text):
    """Yield (modifiers, rest) for every UNCOMMENTED native declaration."""
    joined, buf = [], ""
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("//") or line.startswith("*") or line.startswith("/*"):
            continue
        buf = (buf + " " + line).strip() if buf else line
        if buf.endswith(";"):
            joined.append(" ".join(buf.split()))
            buf = ""
        elif "native " not in buf and not buf.endswith(","):
            buf = ""                      # not a declaration in progress
    out = []
    for d in joined:
        m = NATIVE.match(d)
        if m:
            out.append((m.group("mods").strip(), m.group("rest").strip()))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    jnlua = Path(sys.argv[1])
    src = jnlua / "src" / "main" / "java" / "li" / "cil" / "repack" / "com" / "naef" / "jnlua" / "LuaState.java"
    if not src.is_file():
        print("no LuaState.java at %s" % src, file=sys.stderr)
        return 2

    text = src.read_text(encoding="utf-8", errors="replace")
    decls = native_decls(text)

    # RECONCILE, AND REFUSE ON A MISMATCH.  Every uncommented line carrying the
    # `native` keyword must end up as exactly one emitted declaration.  A
    # shortfall means a method stays inherited and binds to OC's library; the
    # symptom would be an UnsatisfiedLinkError at class load, or worse, silent
    # cross-library binding.  Counting is cheap; discovering it at runtime is
    # not.
    expected = sum(
        1 for raw in text.splitlines()
        if "native " in raw and not raw.strip().startswith(("//", "*", "/*"))
    )
    if not decls:
        print("no native declarations found -- has LuaState.java changed shape?", file=sys.stderr)
        return 1
    if len(decls) != expected:
        print("REFUSING: found %d uncommented 'native' lines but extracted %d "
              "declarations.  A wrapped or reshaped signature is being missed, and "
              "the missing method would silently bind to OpenComputers' library."
              % (expected, len(decls)), file=sys.stderr)
        got = {d[1].split("(")[0].split()[-1] for d in decls}
        for raw in text.splitlines():
            if "native " in raw and not raw.strip().startswith(("//", "*", "/*")):
                if not any(n in raw for n in got):
                    print("  missed: " + raw.strip(), file=sys.stderr)
        return 1

    out = []
    w = out.append
    w("package %s;" % PKG)
    w("")
    w("/**")
    w(" * The OC-LuaJIT LuaState: a fourth JNLua binding class alongside OC's own.")
    w(" *")
    w(" * GENERATED by native/jnlua/gen-luastate-subclass.py from OC-JNLua's")
    w(" * LuaState.java.  Do not edit; edit the generator and regenerate.")
    w(" *")
    w(" * WHAT THIS CLASS IS FOR.  JNI resolves a native method to")
    w(" * Java_<package>_<declaring class>_<method>, so redeclaring the inherited")
    w(" * natives here -- and ONLY that -- gives our native library its own symbol")
    w(" * family, %s_*." % ("Java_li_cil_repack_com_naef_jnlua_" + CLASS))
    w(" * That is how OpenComputers runs Lua 5.2, 5.3 and 5.4 side by side in one")
    w(" * JVM without collision, and it is why OC-LuaJIT can be ADDITIVE: OC keeps")
    w(" * its own three natives and its own three classes, and we are a fourth.")
    w(" *")
    w(" * NO BEHAVIOURAL OVERRIDES, DELIBERATELY.  LuaStateFiveThree overrides")
    w(" * arith_operator_id and gc_action_id because 5.3 renumbered those enums.")
    w(" * We are 5.2-class -- LuaJIT is 5.1 plus partial 5.2 compatibility -- so the")
    w(" * base class's numbering is already correct and inheriting it is the point.")
    w(" *")
    w(" * The native side must be built with a matching JNLUA_SUFFIX; see")
    w(" * native/jnlua/repack.sh.  A mismatch does not fail the build -- it fails at")
    w(" * class load, as an UnsatisfiedLinkError naming the first missing method.")
    w(" */")
    w("public class %s extends LuaState {" % CLASS)
    w("\tpublic %s() {" % CLASS)
    w("\t\tsuper();")
    w("\t}")
    w("")
    w("\tpublic %s(int memory) {" % CLASS)
    w("\t\tsuper(memory);")
    w("\t}")
    w("")
    w("\t/* ---- the %d inherited natives, redeclared so they bind to OUR library ---- */" % len(decls))
    w("")
    for mods, rest in decls:
        w("\t@Override")
        w("\t%s native %s;" % (mods, rest))
        w("")
    w("}")

    text = "\n".join(out) + "\n"
    dest = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if dest:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8", newline="\n")
        print("wrote %s  (%d natives redeclared)" % (dest, len(decls)))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
