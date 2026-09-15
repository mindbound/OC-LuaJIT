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

WHAT IT DOES NOT NEED.  Behavioural overrides.  LuaStateFiveThree overrides
arith_operator_id and gc_action_id because 5.3 renumbered those enums; the base
carries the 5.2 numbering (LuaState.java:141, :154) and we ARE 5.2-class --
LuaJIT is 5.1 plus partial 5.2 compat.  Inheriting is correct.

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


def expand_leading_tabs(line, width=4):
    """Leading tabs -> spaces.  Only LEADING: a tab inside a string literal
    would be content, not indentation, and there are none today."""
    n = len(line) - len(line.lstrip("\t"))
    return " " * (width * n) + line[n:]


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

    nested_names = sorted({d[1].split("(")[0].split()[-1] for d in nested})
    L = []
    w = L.append
    w("package %s;" % PKG)
    w("")
    w("import java.io.IOException;")
    w("import java.io.InputStream;")
    w("import java.io.OutputStream;")
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
    w(" * No behavioural overrides, deliberately: we are 5.2-class, so the base class's")
    w(" * arith/gc enum numbering is already correct and inheriting it is the point.")
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
    w("\t}")
    w("")
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
        dest.write_text(out, encoding="utf-8", newline="\n")
        print("wrote %s  (%d redeclared, %d nested excluded: %s)"
              % (dest, len(own), len(nested), ", ".join(nested_names) or "-"))
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
