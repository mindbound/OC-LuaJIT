#!/bin/sh
# Two deliberately WRONG versions of the patch, to prove probe-diff.lua can
# fail.  Neither touches memory unsafely; both only compute a wrong number:
#   sab1  the int operand is incremented before handle_num (every value wrong)
#   sab2  the int operand is ZERO-extended to a double instead of converted
#         as signed (only negative values wrong: -1 -> 4294967295)
set -u
S=/c/Users/astro/claude-tmp/oclj/r1/fmtx
REPO=/c/Users/astro/Downloads/OC-LuaJIT
PRISTINE=$REPO/prototype/watchdog/luajit
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export TMPDIR=$S/tmp
FLAGS="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK -DLUAJIT_DISABLE_FFI"
for V in sab1 sab2; do
  D=$S/lj-$V
  [ -e "$D" ] && { echo "$D exists: refusing to reuse a build dir" >&2; exit 1; }
  cp -r "$PRISTINE" "$D" && rm -rf "$D/.git" || exit 1
  sh "$REPO/native/luajit/patch-penalty-scrub.sh" "$D/src/lj_func.c" "$D/src/lj_func.c" || exit 1
  sh "$REPO/native/luajit/patch-fastfunc-errmem-top.sh" "$D/src/lj_err.c" "$D/src/lj_err.c" || exit 1
  sh "$S/patch-strfmt-xint-noffi.sh" "$D/src/lj_ffrecord.c" "$D/src/lj_ffrecord.c" || exit 1
done
python - "$S/lj-sab1/src/lj_ffrecord.c" "$S/lj-sab2/src/lj_ffrecord.c" <<'EOF'
import sys
GOTO = "        goto handle_num;"
SAB = {
  1: "        tra = emitir(IRTI(IR_ADD), tra, lj_ir_kint(J, 1));  /* SABOTAGE sab1 */",
  2: "        tra = emitir(IRTN(IR_CONV), tra, (IRT_NUM<<IRCONV_DSH)|IRT_U32);  /* SABOTAGE sab2 */",
}
for n, p in ((1, sys.argv[1]), (2, sys.argv[2])):
    s = open(p, newline="").read()
    assert s.count(GOTO) == 1, p
    s = s.replace(GOTO, SAB[n] + chr(10) + GOTO)
    open(p, "w", newline="").write(s)
    print("sab%d: inserted before the patched goto in %s" % (n, p))
EOF
for V in sab1 sab2; do
  D=$S/lj-$V
  make -C "$D/src" clean > /dev/null 2>&1
  make -C "$D/src" BUILDMODE=static XCFLAGS="$FLAGS" Q= -j8 > "$S/build-$V.log" 2>&1
  echo "$V exit=$?"
done
