#!/bin/sh
# t4build.sh <fresh name> -- verify-code: the refusal-count instrument (the
# design's T4), my own, by the one-file method (JIT guide 7.4) on a copy of
# verify-code/bfix: lj_opt_fold.c gains #include <stdio.h> and, right after
# hunk 12's return, one line printing "VCREFUSE fwd|rev" to stderr when
# op12 matched and the predicate refused.  Never shipped.  No backslashes.
set -u
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/verify-code
N=${1:?usage}
S=$I/$N
[ -e "$S" ] && { echo "REFUSING: $S exists"; exit 99; }
mkdir -p "$S/luajit-windows-x86_64" || exit 98
cp -rp "$I/bfix/luajit-windows-x86_64/." "$S/luajit-windows-x86_64/" || exit 97
cp -rp "$I/bfix/obj-windows-x86_64" "$S/" || exit 97
W=$S/luajit-windows-x86_64/src
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' > "$S/base-obj.md5"
cp -p "$W/lj_opt_fold.c" "$S/lj_opt_fold.c.orig"
python -I "$I/scripts/oneline.py" "$W/lj_opt_fold.c" "$I/scripts/t4-ret-old.txt" "$I/scripts/t4-ret-new.txt" > "$S/oneline.txt" 2>&1 || { cat "$S/oneline.txt"; exit 96; }
python -I "$I/scripts/oneline.py" "$W/lj_opt_fold.c" "$I/scripts/t4-inc-old.txt" "$I/scripts/t4-inc-new.txt" >> "$S/oneline.txt" 2>&1 || { cat "$S/oneline.txt"; exit 96; }
diff "$S/lj_opt_fold.c.orig" "$W/lj_opt_fold.c" > "$S/fold-c.diff"
rm -f "$W/lj_opt_fold.o"
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDLIBS LIBS MAKEFLAGS MAKEFILES GNUMAKEFLAGS MFLAGS MAKEOVERRIDES CPATH C_INCLUDE_PATH TARGET_CFLAGS HOST_CFLAGS
mingw32-make -C "$W" BUILDMODE=static XCFLAGS= "Q=" -j4 > "$S/build.log" 2>&1
echo $? > "$S/make.rc"
( cd "$W" && md5sum *.o host/*.o ) | tr -d '*' > "$S/new-obj.md5"
diff "$S/base-obj.md5" "$S/new-obj.md5" > "$S/obj.diff"
echo "make rc=$(cat "$S/make.rc"); $(awk '{ printf "%s ", $0 }' "$S/oneline.txt"); warnings: $(grep -c -i 'warning' "$S/build.log")"
cat "$S/fold-c.diff"; cat "$S/obj.diff"
