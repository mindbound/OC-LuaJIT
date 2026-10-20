#!/bin/sh
# extra.sh <fresh outdir> <script>: guard cases the docs claim that final-check2.sh does not run,
# plus one full build (X10) where the shell and Windows' programs would read OCLJ_SHIM apart.
# Every guard case points OCLJ_JNLUA nowhere, so a run the guards let through stops at
# "no .../jnlua.c" before anything is created.  Every run gets OCLJ_REPO=<the repo> (a case may
# override it), so that a copy of the script outside the repository runs too (v2; v1, extra-v1.sh,
# left it out, and a copy then stopped at its own missing pin file).  summary.txt: one line per case, PASS when the
# wanted outcome holds.  Written with a file tool: no heredocs, no backslashes.
set -u
O=$1; S=$2
[ -e "$O" ] && { echo "refusing: $O exists"; exit 97; }
mkdir -p "$O" || exit 98
O=$(CDPATH= cd -P -- "$O" && pwd -P)
R=/c/Users/astro/Downloads/OC-LuaJIT
C=/c/Users/astro/claude-tmp/oclj/pin3/impl/clones
NJ=$O/no-jnlua-here
SUM=$O/summary.txt
: > "$SUM"
junction() { MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null; }
treemd5() { if [ -d "$1" ]; then ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum; find . | LC_ALL=C sort ); else echo "ABSENT $1"; fi; }
mkthrow() {
  mkdir -p "$1/.git" "$1/src" || return 1
  echo 'ref: refs/heads/master' > "$1/.git/HEAD"
  echo "throwaway marker: must survive" > "$1/MARKER.txt"
  echo '/* LUAJIT_ENABLE_CHECKHOOK */' > "$1/src/lj_record.c"
}
run() { # run <label> [VAR=value...]
  l=$1; shift
  env PATH="/c/Users/astro/claude-tmp/oclj/bin:$PATH" OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" \
    OCLJ_JNLUA="$NJ" OCLJ_REPO="$R" "$@" sh "$S" > "$O/$l.log" 2>&1
  echo $? > "$O/$l.rc"
}
ok() { # ok <label> <text>: PASS when <label> failed with <text> in its log
  if [ "$(cat "$O/$1.rc")" != 0 ] && grep -q -F -- "$2" "$O/$1.log"; then echo "PASS $1: $3" >> "$SUM"; else echo "FAIL $1: $3" >> "$SUM"; fi
}
same() { if cmp -s "$1" "$2"; then echo "PASS $3: $4" >> "$SUM"; else echo "FAIL $3: $4" >> "$SUM"; fi; }
# X1: OCLJ_BUILD inside the (throwaway) checkout
TW=$O/x1/clone; mkthrow "$TW"; treemd5 "$TW" > "$O/x1.before"
run x1 OCLJ_BUILD="$TW/sub" OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
treemd5 "$TW" > "$O/x1.after"
ok x1 "lies inside, the LuaJIT" "OCLJ_BUILD inside the checkout: refused"
same "$O/x1.before" "$O/x1.after" x1-intact "the checkout unchanged"
# X2: OCLJ_OUT in a scratch OCLJ_REPO's build/native/dist, directly
FR=$O/x2/repo; mkdir -p "$FR/native/luajit" "$FR/build/native/dist"
cp "$R/native/luajit/upstream.commit" "$R/native/luajit/oclj_features.h" "$FR/native/luajit/"
echo 'release library: must survive' > "$FR/build/native/dist/libjnluajit52-windows-x86_64.dll"
treemd5 "$FR" > "$O/x2.before"
run x2 OCLJ_BUILD="$O/x2/b" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$FR/build/native/dist"
treemd5 "$FR" > "$O/x2.after"
ok x2 "the collection point" "OCLJ_OUT in OCLJ_REPO's build/native/dist: refused"
same "$O/x2.before" "$O/x2.after" x2-intact "that repository unchanged"
# X3, X4: the checkout at the export's path, and inside layoutneg-<platform>
B=$O/x3/B; TW=$B/luajit-export-windows-x86_64; mkthrow "$TW"; treemd5 "$TW" > "$O/x3.before"
run x3 OCLJ_BUILD="$B" OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
treemd5 "$TW" > "$O/x3.after"
ok x3 "a directory this script" "checkout at \$OCLJ_BUILD/luajit-export-<platform>: refused"
same "$O/x3.before" "$O/x3.after" x3-intact "the throwaway unchanged"
B=$O/x4/B; TW=$B/layoutneg-windows-x86_64/sub; mkthrow "$TW"; treemd5 "$TW" > "$O/x4.before"
run x4 OCLJ_BUILD="$B" OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT="$TW"
treemd5 "$TW" > "$O/x4.after"
ok x4 "a directory this script" "checkout inside \$OCLJ_BUILD/layoutneg-<platform>: refused"
same "$O/x4.before" "$O/x4.after" x4-intact "the throwaway unchanged"
# X5: OCLJ_BUILD equal to a scratch OCLJ_REPO
FR=$O/x5/repo; mkdir -p "$FR/native/luajit"
cp "$R/native/luajit/upstream.commit" "$R/native/luajit/oclj_features.h" "$FR/native/luajit/"
treemd5 "$FR" > "$O/x5.before"
run x5 OCLJ_BUILD="$FR" OCLJ_REPO="$FR" OCLJ_SHIM=$R/native OCLJ_SER=$R/serializer OCLJ_LUAJIT=$C/lj-clean
treemd5 "$FR" > "$O/x5.after"
ok x5 "lies inside, the repository" "OCLJ_BUILD equal to OCLJ_REPO: refused"
same "$O/x5.before" "$O/x5.after" x5-intact "that repository unchanged"
# X6: OCLJ_OUT = $OCLJ_BUILD/dist, pinned and unpinned
B=$O/x6/B; mkdir -p "$B/dist"; echo 'release library: must survive' > "$B/dist/libjnluajit52-windows-x86_64.dll"
treemd5 "$B/dist" > "$O/x6.before"
run x6p OCLJ_BUILD="$B" OCLJ_VARIANT=additive OCLJ_OUT="$B/dist"
run x6u OCLJ_BUILD="$B" OCLJ_VARIANT=additive OCLJ_LUAJIT_UNPINNED=1 OCLJ_LUAJIT=$C/lj-clean OCLJ_OUT="$B/dist"
treemd5 "$B/dist" > "$O/x6.after"
ok x6p "the collection point" "OCLJ_OUT=\$OCLJ_BUILD/dist, pinned: refused"
ok x6u "the collection point" "OCLJ_OUT=\$OCLJ_BUILD/dist, unpinned: refused"
same "$O/x6.before" "$O/x6.after" x6-intact "dist unchanged"
# X8: OCLJ_REPO given through a junction: taken at its physical path
junction "$O/x8-repo-link" "$R"
run x8 OCLJ_BUILD="$O/x8/b" OCLJ_REPO="$O/x8-repo-link"
ok x8 "pin     = 1ee778a4e37122d8ca7d5733c590a47dafd6b15c (/c/Users/astro/Downloads/OC-LuaJIT/native/luajit/upstream.commit)" "OCLJ_REPO through a junction: the pin file read at the repository's physical path (and the run stops at OCLJ_JNLUA)"
# X10: OCLJ_SHIM=<E>/x/link/.., link a junction to <E>/real/sub: this shell reads <E>/real (the
# real shim), Windows' programs the spelling, <E>/x (a decoy whose lj52shim.c adds a marker).
# A full pinned additive build; PASS when it succeeds and lj52shim.o carries no decoy marker.
E=$O/x10; mkdir -p "$E/real/sub" "$E/x"; junction "$E/x/link" "$E/real/sub"
cp "$R/native/lj52shim.c" "$R/native/lj52shim.h" "$E/real/"
cp "$R/native/lj52shim.h" "$E/x/"
{ cat "$R/native/lj52shim.c"; echo 'static const char oclj_shim_decoy[] __attribute__((used)) = "OCLJ-SHIM-DECOY";'; } > "$E/x/lj52shim.c"
env PATH="/c/Users/astro/claude-tmp/oclj/bin:$PATH" OCLJ_JNI="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include" \
  OCLJ_JNLUA=C:/Users/astro/Downloads/OC-JNLua OCLJ_REPO="$R" OCLJ_BUILD="$O/x10/b" OCLJ_VARIANT=additive OCLJ_SHIM="$E/x/link/.." sh "$S" > "$O/x10.log" 2>&1
echo $? > "$O/x10.rc"
n=$(grep -a -c OCLJ-SHIM-DECOY "$O/x10/b/obj-windows-x86_64/lj52shim.o" 2>/dev/null)
echo "x10 rc=$(cat "$O/x10.rc") decoy-marker-lines-in-lj52shim.o=${n:-no object}" > "$O/x10.txt"
if [ "$(cat "$O/x10.rc")" = 0 ] && [ "$n" = 0 ]; then echo "PASS x10: OCLJ_SHIM <x>/<junction>/..: the build compiles the shim this shell read (no decoy marker in lj52shim.o)" >> "$SUM"
else echo "FAIL x10: OCLJ_SHIM <x>/<junction>/..: the build compiles the shim this shell read (no decoy marker in lj52shim.o)" >> "$SUM"; fi
cat "$SUM" "$O/x10.txt"
