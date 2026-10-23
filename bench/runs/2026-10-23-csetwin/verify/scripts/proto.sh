#!/bin/sh
# proto.sh <fresh name> <old line file> <new line file> -- verify-code: a
# scratch prototype by the JIT guide's one-file method (7.4): a copy of
# verify-code/bfix's build tree (mtimes kept), one line of src/lj_opt_fold.c
# replaced (scripts/oneline.py), lj_opt_fold.o deleted and make run with
# build-native.sh's flags; the object md5s compared.  Never shipped.
# No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
N=${1:?usage}; OLD=${2:?usage}; NEW=${3:?usage}
S=$I/$N
[ -e "$S" ] && { echo "REFUSING: $S exists"; exit 99; }
mkdir -p "$S/luajit-windows-x86_64" || exit 98
cp -rp "$I/bfix/luajit-windows-x86_64/." "$S/luajit-windows-x86_64/" || exit 97
cp -rp "$I/bfix/obj-windows-x86_64" "$S/" || exit 97
W=$S/luajit-windows-x86_64/src
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' > "$S/base-obj.md5"
cp -p "$W/lj_opt_fold.c" "$S/lj_opt_fold.c.orig"
python "$I/scripts/oneline.py" "$W/lj_opt_fold.c" "$OLD" "$NEW" > "$S/oneline.txt" 2>&1 || { cat "$S/oneline.txt"; exit 96; }
diff "$S/lj_opt_fold.c.orig" "$W/lj_opt_fold.c" > "$S/fold-c.diff"
rm -f "$W/lj_opt_fold.o"
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDLIBS LIBS MAKEFLAGS MAKEFILES GNUMAKEFLAGS MFLAGS MAKEOVERRIDES CPATH C_INCLUDE_PATH TARGET_CFLAGS HOST_CFLAGS
mingw32-make -C "$W" BUILDMODE=static XCFLAGS= "Q=" -j4 > "$S/build.log" 2>&1
echo $? > "$S/make.rc"
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' > "$S/new-obj.md5"
diff "$S/base-obj.md5" "$S/new-obj.md5" > "$S/obj.diff"
echo "make rc=$(cat "$S/make.rc"); $(cat "$S/oneline.txt"); fold-c diff lines: $(grep -c '^[<>]' "$S/fold-c.diff"); warnings: $(grep -c -i 'warning' "$S/build.log")"
cat "$S/obj.diff"
md5sum "$W/luajit.exe" "$W/lj_opt_fold.o"
