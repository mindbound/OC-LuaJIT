#!/bin/sh
# proto-build.sh <fresh dir> <fix|fwd> -- a PROTOTYPE build, not the shipped
# object (guide 7.4's one-file method): copy build/native's Windows LuaJIT
# tree (read only) into <dir> with mtimes kept, hand-apply the variant to
# the copy's lj_opt_fold.c (proto-apply.py), delete lj_opt_fold.o, rebuild
# with build-native.sh's flags (BUILDMODE=static, XCFLAGS empty, Q= empty),
# and compare every object with the base: only lj_opt_fold.o may differ.
# Exit codes in <dir>/rc.txt lines; refuses an existing <dir>.
set -u
S=${1:?usage: proto-build.sh <fresh dir> <fix|fwd>}
V=${2:?usage: proto-build.sh <fresh dir> <fix|fwd>}
R=/c/Users/astro/Downloads/OC-LuaJIT
T=/c/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests
[ -e "$S" ] && { echo "REFUSING: $S exists"; exit 99; }
mkdir -p "$S/luajit-windows-x86_64" || exit 98
cp -rp "$R/build/native/luajit-windows-x86_64/." "$S/luajit-windows-x86_64/" || exit 98
W=$S/luajit-windows-x86_64/src
( cd "$W" && md5sum *.o host/*.o luajit.exe libluajit.a ) | tr -d '*' > "$S/base-obj.md5"
md5sum "$W/lj_opt_fold.c" > "$S/fold-c-before.md5"
python "$T/scripts/proto-apply.py" "$W/lj_opt_fold.c" "$V" > "$S/apply.log" 2>&1
echo "apply $?" > "$S/rc.txt"
md5sum "$W/lj_opt_fold.c" > "$S/fold-c-after.md5"
diff "$R/build/native/luajit-windows-x86_64/src/lj_opt_fold.c" "$W/lj_opt_fold.c" > "$S/fold-c.diff"
rm -f "$W/lj_opt_fold.o"
mingw32-make -C "$W" BUILDMODE=static XCFLAGS= "Q=" -j4 > "$S/build.log" 2>&1
echo "make $?" >> "$S/rc.txt"
( cd "$W" && md5sum *.o host/*.o luajit.exe libluajit.a ) | tr -d '*' > "$S/new-obj.md5"
diff "$S/base-obj.md5" "$S/new-obj.md5" > "$S/obj.diff"
grep '^>' "$S/obj.diff" | awk '{ print $3 }' > "$S/obj-changed.txt"
grep -v -x -E 'lj_opt_fold.o|luajit.exe|libluajit.a' "$S/obj-changed.txt" > "$S/obj-other.txt"
echo "others $(grep -c . "$S/obj-other.txt")" >> "$S/rc.txt"
cat "$S/rc.txt"
cat "$S/obj-changed.txt"
