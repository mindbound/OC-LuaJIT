#!/bin/sh
# Build the LuaJIT variants for the %x-without-FFI study, each in its own copy
# of the pinned tree.  Never touches the repo or its checkout: the repo's two
# existing patch scripts are RUN (read) with the copy as both input and output.
#   ffi    HEAD's flags (LUA52COMPAT CHECKHOOK)              -- today's archive
#   noffi  + LUAJIT_DISABLE_FFI, unpatched                   -- the regression
#   fmtx   + LUAJIT_DISABLE_FFI + the draft patch            -- the proposal
#   fmtxa  fmtx + LUA_USE_ASSERT (putfxint's size assertion) -- assertion build
#   alt    + LUAJIT_DISABLE_FFI, "#if LJ_HASFFI" at :1104 widened to "|| LJ_64"
#          (the FFI branch's U64 IR without FFI)              -- rejected candidate
set -u
S=/c/Users/astro/claude-tmp/oclj/r1/fmtx
REPO=/c/Users/astro/Downloads/OC-LuaJIT
PRISTINE=$REPO/prototype/watchdog/luajit
export PATH=/c/Users/astro/claude-tmp/oclj/bin:$PATH
export TMPDIR=$S/tmp
mkdir -p "$TMPDIR"
BASE="-DLUAJIT_ENABLE_LUA52COMPAT -DLUAJIT_ENABLE_CHECKHOOK"

prep() {
  V=$1
  D=$S/lj-$V
  [ -e "$D" ] && { echo "$D exists: refusing to reuse a build dir" >&2; return 1; }
  cp -r "$PRISTINE" "$D" || return 1
  rm -rf "$D/.git"
  sh "$REPO/native/luajit/patch-penalty-scrub.sh" "$D/src/lj_func.c" "$D/src/lj_func.c" || return 1
  sh "$REPO/native/luajit/patch-fastfunc-errmem-top.sh" "$D/src/lj_err.c" "$D/src/lj_err.c" || return 1
}

build() {
  V=$1; FLAGS=$2
  D=$S/lj-$V
  make -C "$D/src" clean > /dev/null 2>&1
  make -C "$D/src" BUILDMODE=static XCFLAGS="$FLAGS" Q= -j4 > "$S/build-$V.log" 2>&1
  echo "$V exit=$? flags=[$FLAGS]"
}

for V in ffi noffi fmtx fmtxa alt; do prep $V || exit 1; done
sh "$S/patch-strfmt-xint-noffi.sh" "$S/lj-fmtx/src/lj_ffrecord.c" "$S/lj-fmtx/src/lj_ffrecord.c" || exit 1
sh "$S/patch-strfmt-xint-noffi.sh" "$S/lj-fmtxa/src/lj_ffrecord.c" "$S/lj-fmtxa/src/lj_ffrecord.c" || exit 1
# alt: widen the one #if at line 1104, asserted by line number and content.
python -c "
import sys
p = sys.argv[1]
L = open(p, 'rb').read().split(bytes([10]))
cr = bytes([13])
assert L[1103].rstrip(cr) == b'#if LJ_HASFFI', L[1103]
assert L[1104].lstrip().startswith(b'tra = emitir(IRT(IR_CONV, IRT_U64), tra,'), L[1104]
L[1103] = b'#if LJ_HASFFI || LJ_64' + (cr if L[1103].endswith(cr) else b'')
open(p, 'wb').write(bytes([10]).join(L))
print('alt: line 1104 widened')
" "$S/lj-alt/src/lj_ffrecord.c" || exit 1

build ffi   "$BASE" &
build noffi "$BASE -DLUAJIT_DISABLE_FFI" &
build fmtx  "$BASE -DLUAJIT_DISABLE_FFI" &
build fmtxa "$BASE -DLUAJIT_DISABLE_FFI -DLUA_USE_ASSERT" &
build alt   "$BASE -DLUAJIT_DISABLE_FFI" &
wait
for V in ffi noffi fmtx fmtxa alt; do
  ls -la "$S/lj-$V/src/luajit.exe" "$S/lj-$V/src/libluajit.a" 2>&1 | sed "s|^|$V: |"
done
