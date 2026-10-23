#!/bin/sh
# final-check.sh <fresh outdir> -- the final check of the CSE type twin round
# (patch-bitop-fold.sh hunk 12: lj_opt_cse never commons an int64
# instruction with one of another type; the user's decisions D1-D3 of
# 2026-10-23) on the round's SCRATCH repo, claude-tmp/oclj/csetwin/round/repo
# (HEAD's tree, git archive, plus the round's eight files: native/luajit/
# patch-bitop-fold.sh, oclj_bitop.h, oclj_bitop_rec.c; test/native/
# negctl-bitop.sh, run-bitjit.sh, bitop/t_csefwd.lua, cseir.lua,
# t_cserev.lua).  The real repo is only read: its HEAD (the tree the scratch
# repo must equal outside those eight files), its pristine LuaJIT checkout
# (the pinned builds read it), and build/native (the unfixed base, luajit.exe
# f4038cd6, lj_opt_fold.o f6d916e2; its Linux tree luajit cb68e454,
# lj_opt_fold.o 57970a51).  The docs are a later phase and not checked here.
# For the MAIN SESSION, from Git Bash, on a quiet machine (its last part
# times):
#
#   nohup sh /c/Users/astro/claude-tmp/oclj/csetwin/round/fix/final-check.sh <outdir> > <outdir>.log 2>&1 &
#
# and a monitor on <outdir>/ALL.done.  About 30-35 minutes [I]: the negctl
# sweep about 15 (FIX-NUMCONV's 36 arms took about 14; with the cse part
# canon took 110-112 s and CSEFWD 12 s, the fixer's runs/negctl-cse-1 and
# -2); the rest from the fixer's runs, 2026-10-23 [M]: the Windows build 30
# s (logs/build-b1), the AlmaLinux 8 build 14 s and its two cse parts 4 s
# (alma1), run-bitjit.sh's seven parts 74 s (runs/bitjit-all-fix-1), a cse
# part 10 s; FIX-NUMCONV's final check measured the md5 census of build/
# at 164-219 s each, the generator's three modes 112 s, the runners 37 s;
# timing about 4 s a round (integrate/timing/run-1).
#
# Modelled on FIX-NUMCONV's numconv/fix/final-check.sh (md5 in
# <outdir>/model.md5): the same refusals (by identity, before anything is
# created), census, md5s at start and end, one PASS, FAIL or SKIP line per
# check in <outdir>/summary.txt, and ALL.done last with the VERDICT.
# Written by the round's fixer (claude-tmp/oclj/csetwin/round/fix),
# 2026-10-23.
#
# REFUSALS, before anything runs: an outdir that exists, a parent that does
# not, an outdir or FC_USE_BUILD inside the real repo or the scratch repo,
# an outdir not on a drive (exit 97); any of the scratch repo's eight files
# not the md5 this script names (exit 95, before the outdir is made); then,
# with the outdir made, the scratch repo's tree outside docs/ and
# bench/runs/ unequal to HEAD's but for those eight (exit 95); with the
# timing part wanted, a running java or javaw (exit 96, Minecraft), and the
# timing part stops between rounds if one appears.  Everything it writes is
# under <outdir> (fresh OCLJ_BUILDs <outdir>/b/win and <outdir>/alma/b; or
# into FC_USE_BUILD), every exit code in <outdir>/rc/ (and alma/rc/).  It
# runs its Linux parts by invoking itself in WSL (MSYS_NO_PATHCONV=1
# wsl.exe -d AlmaLinux-8 -- env ... sh /mnt/c/.../final-check.sh --alma
# ...), reading their exit codes from files they write.
#
# SAFETY.  Value-level runs and IR reads only; FFI is off and nothing reads
# or writes through a pointer; no run forces a crash (CLAUDE.md, JIT guide
# 11.10).  The only reverse-order test is bitop/t_cserev.lua, in the two
# shapes whose 32-bit consumer stores nothing in a Lua slot (select beyond
# its varargs, a narrowed string.byte or string.sub argument: the user's
# decision D2), which are safe on any build; its md5 is pinned below, so no
# unreviewed case can run, and its own text check refuses any text naming
# "bit" or holding a second "for ".  Every other test is forward order and
# value-only.  The base runs send the cse part to build/native's natives
# (read only), as the test implementer and both verifiers did.  The text
# fail-firsts (fc-fftests.py) write no reverse case: they mutate the checks'
# search strings, or add a Lua comment to a case's text, and run t_cserev
# under PUC 5.3.6 or -joff only.  negctl's one CSE arm, CSEFWD, lets only
# the forward merge back in.
#
# PARTS (FC_PARTS, default all, in this order; the census, the md5s at
# start and end and the tree check always run):
#   build    Windows build-native.sh (the scratch repo's) into <outdir>/b/win,
#            OCLJ_REPO the scratch repo, additive: rc 0, the pin met, the
#            export verified, nothing ignored from the environment, the fold
#            patch line (76 added, 9 removed, of 2720, "no CSE of int64 with
#            another type"), round 3's C files at 0 warnings; 77 LuaJIT
#            objects of which only lj_opt_fold.o differs from build/native's,
#            ours (3) equal; that lj_opt_fold.o a6c5fcc2..., the build
#            copy's lj_opt_fold.c 59778bb6...
#   alma     AlmaLinux 8, OCLJ_GLIBC_MAX=2.28: the same against build/native's
#            Linux tree (lj_opt_fold.o 1b4a7c13..., the same build copy),
#            GLIBC needed <= 2.28; run-bitjit.sh, all seven parts, the Linux
#            PUC; the generator's idx, rg2 and phi modes; the cse part on
#            build/native's Linux luajit, which must FAIL as fc-basecse.py's
#            base reading says (the fail-first); sh -n of the changed shell
#            scripts, this one and fc-anchors.sh there, and in Ubuntu's dash
#   bitjit   run-bitjit.sh, all seven parts (gen, floor, fix1, idx, sel, nc,
#            cse), PUC set: PASS, every part's lines; the cse part read by
#            fc-basecse.py as the fixed build must read; the generator's
#            idx, rg2 and phi modes (seeds 1-4, 1-4, 201-204)
#   base     the fail-first on build/native: the cse part FAILs there as
#            fc-basecse.py's base reading says (t_csefwd's and cseir's
#            forward pairs served, t_cserev's four reverse cases merged with
#            no int64 ref in a snapshot, every value of t_cserev right); the
#            reader's own fail-first: each build's output read as the
#            other's must fail
#   suites   run-bitop.sh and run-bitfuzz.sh
#   negctl   the FULL negctl-bitop.sh sweep, one call: canon (with the cse
#            part), 37 arms (CSEFWD the 37th, caught by cse:t_csefwd and
#            cse:cseir), restore
#   runners  the other native runners that link libluajit.a: run.sh,
#            run-mem.sh, run-vgc.sh, run-wd.sh, run-penalty.sh, run-race.sh,
#            run-security.sh, run-pack.sh, run-packfuzz.sh (FIX-NUMCONV's
#            list; smoke-test.sh starts a JVM, which the timing part forbids)
#   hygiene  the eight files' md5s; the changed set (from the tree check);
#            0 CR bytes in the eight; git diff --no-index --check of each
#            against HEAD's copy (or /dev/null); sh -n in Git Bash (and the
#            alma part's results); the hunk engine of all seven
#            patch-bitop-*.sh unchanged (077d1dbe...); patch-bitop-fold.sh
#            without tabs or backslashes, the three Lua files without
#            backslashes; the patch on the pin's pristine blob (git
#            cat-file): 76/9 of 2720, the build copy's bytes, idempotent;
#            on a4c0645's lj_opt_fold.c (fc-a4c0645-lj_opt_fold.c, blob
#            9d48aaa2): 76/9 of 2730; hunk 12's two-line anchor once in each;
#            verify_content's fail-firsts (fc-ffpatch.py: m1-m6 refused with
#            their own messages, c5 and c6 refused, each new count failing
#            alone); the test files' text and gate fail-firsts
#            (fc-fftests.py); negctl's 37 anchors in three copies
#            (fc-anchors.sh); the line cites of the round's files by content
#            (fc-cites.py, and every cite moved one line down or up fails);
#            no private path and no email address in the round's added
#            lines; the bit library called only by the three files that did
#            at HEAD, two of them with no 5.3 operator; the helpers' md5s
#   timing   LAST: base (build/native's luajit.exe) against new
#            (<outdir>/b/win), FC_ROUNDS rounds (default 8), the order
#            alternating, on bench_bit.lua 2e7, bench_bit2.lua 1e7,
#            ident.lua 1e7 time and bench_numconv.lua 2e7 (fc-bench/,
#            md5-pinned; integrate/timing/bench); fc-timing-summ.py: every
#            result equal, and at full N each row's median new/base within
#            [0.5, 2.0] (a smoke bound against a gross change, not a speed
#            claim)
#
# KNOBS, for smoke runs and fail-firsts only (ALL.done names them, and any
# of them makes the verdict INCOMPLETE at best):
#   FC_PARTS=<list>       the parts to run
#   FC_USE_BUILD=<dir>    skip the Windows build and use this OCLJ_BUILD (the
#                         runners and negctl write into it: never one in the
#                         real repo or the scratch repo)
#   FC_BASE_BUILD=<dir>   the base build for the base and timing parts
#                         instead of build/native (and its Linux tree, if
#                         any, for the alma part's fail-first)
#   FC_RP=<dir>           the scratch repo instead of round/repo (its eight
#                         files must still have the md5s below)
#   FC_TASKLIST=<cmd>     the process lister instead of tasklist
#   FC_ROUNDS=<n>         timing rounds (default 8)
#   FC_NDIV=<n>           divide the benches' N (default 1; otherwise the
#                         gross-change check says SKIP)
#   FC_NEGCTL_ARMS=<list> negctl with OCLJ_NEGCTL_ARMS=<list>: then the
#                         NEGCTL-rc and NEGCTL-37-arms checks FAIL by design
#   FC_CENSUS=stat|none   the census of build/ and of the scratch repo
#                         compares find's mtime and size list instead of
#                         md5s, or is skipped (smoke runs only: in stat mode
#                         it took 186 s before the fixer's smoke/g7 tree
#                         check; the git state and the pristine checkout are
#                         always compared)
# Written with a file tool; no heredocs, and no backslashes at all.
set -u
R=/c/Users/astro/Downloads/OC-LuaJIT
RW=C:/Users/astro/Downloads/OC-LuaJIT
WSL_REAL=/mnt/c/Users/astro/Downloads/OC-LuaJIT
PL=$R/prototype/watchdog/luajit
PLW=C:/Users/astro/Downloads/OC-LuaJIT/prototype/watchdog/luajit
BN=$R/build/native
PUCW=C:/Users/astro/Downloads/OC-LuaJIT/bench/vendor/lua-5.3.6/src/lua.exe
PUCL=/mnt/c/Users/astro/claude-tmp/oclj/puc536-alma/lua
TOOLS=/c/Users/astro/claude-tmp/oclj/bin
JNIW="C:/Program Files/Eclipse Adoptium/jdk-8.0.504.1-hotspot/include"
JNLUAW=C:/Users/astro/Downloads/OC-JNLua
MODEL=/c/Users/astro/claude-tmp/oclj/numconv/fix/final-check.sh
FOLD_O_WIN=a6c5fcc2a56698ed1313f25c0a298719
FOLD_O_LINUX=1b4a7c131b89917051aaf03af9cf6093
BASE_FOLD_O_WIN=f6d916e29cf8e05cd951d220ba8abcd9
BASE_FOLD_O_LINUX=57970a518831675ec90e3124850e50d7
BASE_LJ_WIN=f4038cd62af3a12985868cea77cc1518
BASE_LJ_LINUX=cb68e4547f36ab5da17f2def2cbcbfd4
FOLD_C_MD5=59778bb698247b3e3f0392fdf92def70
PIN_FOLD_C=15c7420ce76537c52775f439b955564c
TIP_FOLD_C=0f28177caa5a6749754b514cc0f8462d
TIP_BLOB=9d48aaa2ce616b32f6bd02bdcc0786206864f2c0
ENGINE_MD5=077d1dbebe056d59691d7f7f93307b2d
PATCHLINE="the table-index fold, no CSE of int64 with another type (76 lines added, 9 removed, of 2720); verified by content, diff and reversal"
TIPLINE="no CSE of int64 with another type (76 lines added, 9 removed, of 2730); verified by content, diff and reversal"
IDEMLINE="already folds the 64-bit bit operators without FFI (verified) -- unchanged"
WGATELINE="oclj_bitop.h, oclj_bitop_meta.c, oclj_bitop_rec.c, oclj_bitop_fold.c, oclj_num53.h -Wall -Wextra warnings = 0"
ARMS37='BCDUMP CSEFWD ERROPERAND FIX1 INEXACT-BNOT INEXACT-FOLD INEXACT-INTERP INEXACT-JIT INEXACT-SLOW KFOLD64 NARROW NEGSHIFT NOINT-FOLD NOINT-JIT NOLOOPFOLD NUMCONVNOOP NUMCONVOFF NUMCONVOP1 NUMCONVW PHIIDX RANGE-HI SARCONST SARSHR SELFGUARD SELGUARD SELRECK SHIFTMASK STRCOERCE WADD0 WBAND WIDTH55 WIDTHIDX33 WORDTOKEN WRAP32-FOLD WRAP32-INTERP WSHL0 WSHR'
# The round's eight files and the md5s this check was written for.
FILES8='native/luajit/patch-bitop-fold.sh:cfa5a3db5f1f92145cfdbe9074b46958
native/luajit/oclj_bitop.h:8385a4d11f06384835c61d41cf08325c
native/luajit/oclj_bitop_rec.c:076c0a1a78e14dd740b7f8fc069b47e1
test/native/negctl-bitop.sh:52ccbc5917395c467c5ead813027b61d
test/native/run-bitjit.sh:cab65ddf9fd2c34122f34bdabe6f706b
test/native/bitop/t_csefwd.lua:2c73c0f6c3ad7e77714cb8d629818ef9
test/native/bitop/cseir.lua:98f5c64974b4b3f3a056f7664a1ebbca
test/native/bitop/t_cserev.lua:2d3615057941c38f569856729d114d08'
NEW3='test/native/bitop/cseir.lua test/native/bitop/t_csefwd.lua test/native/bitop/t_cserev.lua'
HELPERS='fc-cites.py:573a623baa5686b7d878342b120b0046
fc-basecse.py:5e32aadeb602b4aab99dfd56749d2410
fc-ffpatch.py:1b5698157e9fe5606f964bb86b68788d
fc-fftests.py:d879060f97e86833133b7b26e794c0c5
fc-anchors.sh:948d06989c0e0fd0d9a130ea12c7e37d
fc-timing-summ.py:2e3113f6c745055b216a68725e542af0
fc-a4c0645-lj_opt_fold.c:0f28177caa5a6749754b514cc0f8462d
fc-bench/bench_bit.lua:2c6a60e0bb01756be2fc2b1767166b43
fc-bench/bench_bit2.lua:7bb3ab87a8e0c3d9fbe618875e680f56
fc-bench/bench_numconv.lua:c15c325eb474b7458a753a637335ecae
fc-bench/ident.lua:5a0429552f6a808731b13a57bf10cce7'
# Nothing from the caller's environment steers a runner.
unset LUA_INIT LUA_INIT_5_3 LUA_INIT_5_2 LUA_PATH LUA_CPATH OCLJ_REPO OCLJ_LUA53 OCLJ_OUT
unset OCLJ_BITJIT_PARTS OCLJ_BITJIT_SEED OCLJ_BITJIT_SEEDS OCLJ_BITJIT_CASES OCLJ_BITJIT_GENMODE OCLJ_BITJIT_HOTMIN OCLJ_BITJIT_OUT
unset OCLJ_NEGCTL_ARMS NEGCTL_GEN_SEEDS NEGCTL_FUZZ_CASES OCLJ_BITOP_OUT OCLJ_BITFUZZ_OUT OCLJ_LUAJIT_UNPINNED

# objcmp <build A> <build B> <platform> <out prefix>: 0 iff both hold 77
# LuaJIT objects of the same names, only lj_opt_fold.o differs, and our 3
# objects (obj-<platform>) are equal.
objcmp() {
  ( cd "$1/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.A-lj.md5"
  ( cd "$2/luajit-$3/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.B-lj.md5"
  ( cd "$1/obj-$3" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.A-obj.md5"
  ( cd "$2/obj-$3" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$4.B-obj.md5"
  diff "$4.A-lj.md5" "$4.B-lj.md5" > "$4.lj.diff"
  oc_a=$(grep -c '^<' "$4.lj.diff"); oc_b=$(grep -c '^>' "$4.lj.diff")
  oc_n=$(grep '^[<>]' "$4.lj.diff" | awk '{ print $3 }' | LC_ALL=C sort -u | awk '{ printf "%s ", $0 }')
  echo "LuaJIT objects $(wc -l < "$4.A-lj.md5" | tr -d ' ')/$(wc -l < "$4.B-lj.md5" | tr -d ' '); differing: $oc_n($oc_a/$oc_b lines); ours $(wc -l < "$4.A-obj.md5" | tr -d ' ')" > "$4.txt"
  [ "$(wc -l < "$4.A-lj.md5" | tr -d ' ')" = 77 ] && [ "$(wc -l < "$4.B-lj.md5" | tr -d ' ')" = 77 ] &&
    [ "$oc_a" = 1 ] && [ "$oc_b" = 1 ] && [ "$oc_n" = "lj_opt_fold.o " ] &&
    cmp -s "$4.A-obj.md5" "$4.B-obj.md5" && [ "$(wc -l < "$4.A-obj.md5" | tr -d ' ')" = 3 ]
}
# crcount <file>: its CR bytes; bytecount <hex> <file> (od, no backslash).
crcount() { od -An -tx1 -v "$1" | tr ' ' '|' | grep -o '|0d' | wc -l | tr -d ' '; }
bytecount() { od -An -tx1 -v "$2" | tr ' ' '|' | grep -o "|$1" | wc -l | tr -d ' '; }
engine() { sed -n '/^# --- THE HUNK ENGINE/,/^# --- end of the hunk engine/p' "$1" | md5sum | cut -c1-32; }
glibcmax() { awk '{ if (match($0, /highest version needed GLIBC_2[.][0-9]+/)) { print substr($0, RSTART + 31, RLENGTH - 31); exit } }' "$1" 2>/dev/null; }
md5of() { md5sum < "$1" 2>/dev/null | cut -c1-32; }
# bitjitall <log>: run-bitjit.sh, all seven parts, passed with every part's lines.
bitjitall() {
  bj=$1
  grep -q "^RUN-BITJIT: PASS (results" "$bj" || { echo "no full PASS line (or a parts-run note)"; return 1; }
  [ "$(grep -c "^seed [0-9]*: PASS" "$bj")" = 4 ] || { echo "not 4 generator seeds PASS"; return 1; }
  for l in "PASS t_rg2 (" "PASS fix1" "PASS t_idx (" "PASS t_cnt33 (" "PASS t_idx2 (" "PASS phiidx" "PASS t_select (" "PASS t_select-kmax" "PASS t_numconv (75 cases" "PASS ncir (29 cases)" "PASS t_csefwd (32 cases)" "PASS t_cserev (8 cases)" "PASS t_cserev: PUC 5.3.6 equals -joff in all 8 cases" "PASS cseir (32 cases)"; do
    grep -q -F "$l" "$bj" || { echo "no line starting $l"; return 1; }
  done
  grep -q -F "20 of 20 pairs formed, served 0" "$bj" || { echo "t_csefwd's coverage is not 20 of 20 pairs formed, served 0"; return 1; }
}
# basecheck <rc file> <log> <reader rc file>: the base cse part exited 1
# with its three FAIL lines and PUC's PASS, and fc-basecse.py's base
# reading of it passed.
basecheck() {
  [ "$(cat "$1" 2>/dev/null)" = 1 ] && grep -q '^RUN-BITJIT: FAIL' "$2" && grep -q -F 'FAIL t_csefwd (32 cases)' "$2" &&
    grep -q -F 'FAIL cseir (32 cases)' "$2" && grep -q -F 'FAIL t_cserev (8 cases)' "$2" &&
    grep -q -F 'PASS t_cserev: PUC 5.3.6 equals -joff in all 8 cases' "$2" && [ "$(cat "$3" 2>/dev/null)" = 0 ]
}
# bitjitrc <rc file> <log>: run-bitjit.sh, all seven parts, exited 0 and passed.
bitjitrc() { [ "$(cat "$1" 2>/dev/null)" = 0 ] && bitjitall "$2"; }

# --------------------------------------------------------------- the Linux parts (in WSL)
alma_part() {  # alma_part <outdir> <this script> <base build> <scratch repo>, all WSL paths
  A=$1/alma
  RPL=$4
  mkdir "$A" || exit 98
  mkdir -p "$A/rc" || exit 98
  { uname -a; gcc --version | head -1; readlink -f /bin/sh; ldd --version 2>&1 | head -1; cat /etc/redhat-release; "$PUCL" -v; md5sum "$PUCL"; } > "$A/host.txt" 2>&1
  : > "$A/shn.txt"
  for f in "$RPL/native/luajit/patch-bitop-fold.sh" "$RPL/test/native/negctl-bitop.sh" "$RPL/test/native/run-bitjit.sh" "$2" "$(dirname "$2")/fc-anchors.sh"; do
    sh -n "$f" > /dev/null 2>&1; echo "$? $f" >> "$A/shn.txt"
  done
  date -u +%H:%M:%S > "$A/t-start.txt"
  env OCLJ_REPO="$RPL" OCLJ_JNI=/usr/lib/jvm/java-1.8.0-openjdk/include OCLJ_JNLUA=/mnt/c/Users/astro/Downloads/OC-JNLua CC=gcc OCLJ_LUAJIT="$WSL_REAL/prototype/watchdog/luajit" OCLJ_BUILD="$A/b" OCLJ_VARIANT=additive OCLJ_GLIBC_MAX=2.28 sh "$RPL/native/build-native.sh" > "$A/build.log" 2>&1
  echo $? > "$A/rc/build.rc"
  date -u +%H:%M:%S > "$A/t-built.txt"
  if [ "$(cat "$A/rc/build.rc")" = 0 ]; then
    objcmp "$A/b" "$WSL_REAL/build/native" linux-x86_64 "$A/cmp-vs-buildnative"; echo $? > "$A/rc/objcmp.rc"
    md5sum < "$A/b/luajit-linux-x86_64/src/lj_opt_fold.o" | cut -c1-32 > "$A/fold-o.md5"
    md5sum < "$A/b/luajit-linux-x86_64/src/lj_opt_fold.c" | cut -c1-32 > "$A/fold-c.md5"
    grep -h 'glibc: highest version needed' "$A/build.log" > "$A/glibc.txt"
    env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_OUT="$A/bitjit-all" sh "$RPL/test/native/run-bitjit.sh" > "$A/bitjit-all.log" 2>&1
    echo $? > "$A/rc/bitjit-all.rc"
    for ms in idx:1 rg2:1 phi:201; do
      m=${ms%%:*}; s=${ms#*:}
      env OCLJ_BUILD="$A/b" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=$s OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$A/gen-$m" sh "$RPL/test/native/run-bitjit.sh" > "$A/gen-$m.log" 2>&1
      echo $? > "$A/rc/gen-$m.rc"
    done
  fi
  # The fail-first: the cse part on the base build's Linux luajit (read
  # only; its results go to the outdir).
  if [ -x "$3/luajit-linux-x86_64/src/luajit" ]; then
    md5sum "$3/luajit-linux-x86_64/src/luajit" "$3/luajit-linux-x86_64/src/lj_opt_fold.o" > "$A/base.md5" 2>&1
    env OCLJ_BUILD="$3" OCLJ_LUA53="$PUCL" OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT="$A/base-cse" sh "$RPL/test/native/run-bitjit.sh" > "$A/base-cse.log" 2>&1
    echo $? > "$A/rc/base-cse.rc"
  else
    echo "no $3/luajit-linux-x86_64/src/luajit" > "$A/base-cse.skip"
  fi
  date -u +%H:%M:%S > "$A/t-end.txt"
  echo done > "$A/part.done"
}
ubuntu_part() {  # ubuntu_part <outdir> <this script> <scratch repo>, WSL paths
  U=$1/ubuntu
  mkdir "$U" || exit 98
  { readlink -f /bin/sh; uname -a; } > "$U/host.txt" 2>&1
  : > "$U/shn.txt"
  for f in "$3/native/luajit/patch-bitop-fold.sh" "$3/test/native/negctl-bitop.sh" "$3/test/native/run-bitjit.sh" "$2" "$(dirname "$2")/fc-anchors.sh"; do
    sh -n "$f" > /dev/null 2>&1; echo "$? $f" >> "$U/shn.txt"
  done
  echo done > "$U/part.done"
}
case ${1:-} in
  --alma) alma_part "$2" "$3" "$4" "$5"; exit 0 ;;
  --ubuntu) ubuntu_part "$2" "$3" "$4"; exit 0 ;;
esac

# --------------------------------------------------------------- Windows: refusals
O=${1:-}
[ -n "$O" ] || { echo "usage: sh final-check.sh <fresh outdir>"; exit 2; }
[ -e "$O" ] && { echo "REFUSING: $O exists (never reuse a results directory)"; exit 97; }
OP=$(CDPATH= cd -P -- "$(dirname -- "$O")" 2>/dev/null && pwd -P) || { echo "REFUSING: the parent of $O does not exist; make it first"; exit 97; }
O=$OP/$(basename -- "$O")
RP=/c/Users/astro/claude-tmp/oclj/csetwin/round/repo
if [ -n "${FC_RP:-}" ]; then
  RP=$(CDPATH= cd -P -- "$FC_RP" 2>/dev/null && pwd -P) || { echo "no FC_RP $FC_RP"; exit 2; }
fi
[ -d "$RP" ] || { echo "no scratch repo $RP"; exit 2; }
# inside <existing dir> <root>: 0 when the dir is the root or lies under it.
# Windows ignores case, and Git Bash's pwd -P keeps the case it was given,
# so every ancestor is compared with the root by identity ([ -ef ], which
# also sees through an 8.3 name or a junction), and the lower-cased
# spellings are compared too (the CRC32 round's verify-code F1).
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
inside() {
  in_d=$1
  case $(lc "$in_d") in "$(lc "$2")"|"$(lc "$2")"/*) return 0 ;; esac
  while :; do
    [ "$in_d" -ef "$2" ] && return 0
    in_n=$(dirname -- "$in_d")
    [ "$in_n" = "$in_d" ] && return 1
    in_d=$in_n
  done
}
for root in "$R" "$RP"; do
  inside "$OP" "$root" && { echo "REFUSING: $O is inside $root"; exit 97; }
  case $O in "$root"|"$root"/*) echo "REFUSING: $O is inside $root"; exit 97 ;; esac
done
case $O in /[A-Za-z]/?*) ;; *) echo "REFUSING: $O is not on a drive (/<letter>/...), which the WSL parts need"; exit 97 ;; esac
WB=$O/b/win
if [ -n "${FC_USE_BUILD:-}" ]; then
  WB=$(CDPATH= cd -P -- "$FC_USE_BUILD" 2>/dev/null && pwd -P) || { echo "no FC_USE_BUILD $FC_USE_BUILD"; exit 2; }
  for root in "$R" "$RP"; do
    inside "$WB" "$root" && { echo "REFUSING: FC_USE_BUILD $WB is inside $root (the runners and negctl write into it)"; exit 97; }
  done
fi
BASEB=$BN
if [ -n "${FC_BASE_BUILD:-}" ]; then
  BASEB=$(CDPATH= cd -P -- "$FC_BASE_BUILD" 2>/dev/null && pwd -P) || { echo "no FC_BASE_BUILD $FC_BASE_BUILD"; exit 2; }
fi
case $BASEB in /[A-Za-z]/?*) ;; *) echo "REFUSING: the base build $BASEB is not on a drive (/<letter>/...)"; exit 97 ;; esac
# The eight files must be the reviewed ones before anything runs: no
# unreviewed case, reverse or forward, can be run by this check.
f8bad=
for e in $FILES8; do
  [ "$(md5of "$RP/${e%%:*}")" = "${e#*:}" ] || f8bad="$f8bad ${e%%:*}"
done
[ -z "$f8bad" ] || { echo "REFUSING: these files of $RP are not the ones this check was written for (md5):$f8bad"; exit 95; }
FC_PARTS=${FC_PARTS:-build alma bitjit base suites negctl runners hygiene timing}
FC_ROUNDS=${FC_ROUNDS:-8}
FC_NDIV=${FC_NDIV:-1}
FC_CENSUS=${FC_CENSUS:-md5}
case "$FC_ROUNDS$FC_NDIV" in *[!0-9]*) echo "FC_ROUNDS and FC_NDIV are whole numbers"; exit 2 ;; esac
[ "$FC_ROUNDS" -ge 1 ] && [ "$FC_NDIV" -ge 1 ] || { echo "FC_ROUNDS and FC_NDIV are at least 1"; exit 2; }
case $FC_CENSUS in md5|stat|none) ;; *) echo "FC_CENSUS is md5, stat or none"; exit 2 ;; esac
for p in $FC_PARTS; do
  case " build alma bitjit base suites negctl runners hygiene timing " in *" $p "*) ;; *) echo "unknown part $p"; exit 2 ;; esac
done
wanted() { case " $FC_PARTS " in *" $1 "*) return 0 ;; esac; return 1; }
SELF=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd -P)/$(basename -- "$0")
HERE=$(dirname -- "$SELF")
for e in $HELPERS; do
  [ -f "$HERE/${e%%:*}" ] || { echo "no $HERE/${e%%:*} (it lives beside this script)"; exit 2; }
done
mkdir "$O" || exit 98
TASKLIST=${FC_TASKLIST:-tasklist}
javacheck() {  # 0 when a java or javaw process runs; writes <file>
  $TASKLIST > "$1.all" 2>/dev/null
  grep -iE '^(java|javaw)[.]exe' "$1.all" > "$1"
  [ -s "$1" ]
}
if javacheck "$O/jvms-start.txt"; then
  if wanted timing; then
    echo "REFUSING: a Java process is running (Minecraft?); close it and start again:"
    cat "$O/jvms-start.txt"
    exit 96
  fi
  echo "NOTE: a Java process is running; no timing part was asked for, so the correctness parts run (jvms-start.txt)"
fi
wslpath_of() { printf '/mnt/%s%s' "$(printf '%s' "$1" | cut -c2 | tr 'A-Z' 'a-z')" "$(printf '%s' "$1" | cut -c3-)"; }
winpath_of() { printf '%s:%s' "$(printf '%s' "$1" | cut -c2 | tr 'a-z' 'A-Z')" "$(printf '%s' "$1" | cut -c3-)"; }
WO=$(wslpath_of "$O"); SELF_L=$(wslpath_of "$SELF"); WBASE=$(wslpath_of "$BASEB"); WRP=$(wslpath_of "$RP")
OW=$(winpath_of "$O"); HEREW=$(winpath_of "$HERE"); RPW=$(winpath_of "$RP")
mkdir -p "$O/logs" "$O/rc" "$O/b" "$O/cmp" "$O/census" "$O/runs" || exit 98
SUM=$O/summary.txt
: > "$SUM"
T0=$(date +%s)
date -u +%Y-%m-%dT%H:%M:%SZ > "$O/start-time.txt"
KNOBS="FC_PARTS=$FC_PARTS FC_USE_BUILD=${FC_USE_BUILD:-unset} FC_BASE_BUILD=${FC_BASE_BUILD:-unset} FC_RP=${FC_RP:-unset} FC_TASKLIST=${FC_TASKLIST:-unset} FC_ROUNDS=$FC_ROUNDS FC_NDIV=$FC_NDIV FC_NEGCTL_ARMS=${FC_NEGCTL_ARMS:-unset} FC_CENSUS=$FC_CENSUS"
echo "$KNOBS" > "$O/knobs.txt"
[ -f "$MODEL" ] && md5sum "$MODEL" > "$O/model.md5"
res() { echo "$1 $2: $3" >> "$SUM"; echo "$1 $2: $3"; }
check() {  # check <id> <text> <command...>: PASS when the command succeeds
  ck_i=$1; ck_t=$2; shift 2
  echo "== $ck_i: $*" >> "$O/logs/checks.log"
  if "$@" >> "$O/logs/checks.log" 2>&1; then res PASS "$ck_i" "$ck_t"; else res FAIL "$ck_i" "$ck_t"; fi
}
skip() { res SKIP "$1" "$2"; }
rcis() { [ "$(cat "$O/rc/$1.rc" 2>/dev/null)" = "$2" ]; }
stamp() { echo "$1 secs=$(( $(date +%s) - $2 ))" >> "$O/logs/timing.txt"; }
census() {  # census <prefix>: the real repo's build/ and pristine checkout, its git state, and the scratch repo
  if [ "$FC_CENSUS" = none ]; then
    echo "skipped (FC_CENSUS=none)" > "$1-build.md5"
    echo "skipped (FC_CENSUS=none)" > "$1-rp.md5"
  elif [ "$FC_CENSUS" = stat ]; then
    ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-build.md5"
    ( cd "$RP" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-rp.md5"
  else
    ( cd "$R" && find build -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-build.md5"
    ( cd "$RP" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-rp.md5"
  fi
  ( cd "$PL" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -c '%Y %s %n' ) > "$1-pristine-stat.txt"
  ( cd "$PL" && find .git -type f -print0 | LC_ALL=C sort -z | xargs -0 md5sum ) > "$1-pristine-git.md5"
  git -C "$PL" rev-parse HEAD > "$1-pristine-head.txt" 2>&1
  { git -C "$R" rev-parse HEAD; git -C "$R" status --porcelain; } > "$1-real-git.txt" 2>&1
  ( cd "$R" && git status --porcelain | awk '{ print $NF }' | while read -r f; do [ -f "$f" ] && md5sum "$f"; done ) > "$1-real-changed.md5" 2>&1
}
mdstate() {  # mdstate <out>: md5 of the eight files, this script and its helpers
  { for e in $FILES8; do md5sum "$RP/${e%%:*}"; done
    md5sum "$SELF"
    for e in $HELPERS; do md5sum "$HERE/${e%%:*}"; done; } > "$1" 2>&1
}
mdstate "$O/md5-start.txt"
git -C "$R" rev-parse HEAD > "$O/repo-head.txt"
echo "== census before"
t=$(date +%s); census "$O/census/before"; stamp census-before "$t"

# --------------------------------------------------------------- the tree check (always; refuses)
# The scratch repo outside docs/ and bench/runs/ must be HEAD's tree but for
# the eight files (three of them new), or nothing below runs.
echo "== tree"
HT=$O/headtree; mkdir -p "$HT"
git -C "$R" archive --format=tar HEAD -- . ':(exclude)docs' ':(exclude)bench/runs' > "$O/head.tar" 2> "$O/logs/head-archive.err"
tar -x -f "$O/head.tar" -C "$HT" 2>> "$O/logs/head-archive.err"
rm -f "$O/head.tar"
( cd "$HT" && find . -type f | sed 's|^[.]/||' | LC_ALL=C sort ) > "$O/cmp/head-files.txt"
( cd "$RP" && find . -type f | sed 's|^[.]/||' | grep -v -e '^docs/' -e '^bench/runs/' | LC_ALL=C sort ) > "$O/cmp/rp-files.txt"
: > "$O/cmp/changed.txt"
while read -r f; do
  if [ ! -f "$RP/$f" ]; then echo "missing $f" >> "$O/cmp/changed.txt"
  elif ! cmp -s "$HT/$f" "$RP/$f"; then echo "$f" >> "$O/cmp/changed.txt"; fi
done < "$O/cmp/head-files.txt"
LC_ALL=C comm -13 "$O/cmp/head-files.txt" "$O/cmp/rp-files.txt" >> "$O/cmp/changed.txt"
LC_ALL=C sort -o "$O/cmp/changed.txt" "$O/cmp/changed.txt"
for e in $FILES8; do echo "${e%%:*}"; done | LC_ALL=C sort > "$O/cmp/changed-want.txt"
if cmp -s "$O/cmp/changed.txt" "$O/cmp/changed-want.txt" && [ "$(wc -l < "$O/cmp/head-files.txt" | tr -d ' ')" -gt 200 ]; then
  res PASS CHANGED-SET "the scratch repo is HEAD's tree outside docs/ and bench/runs/ ($(wc -l < "$O/cmp/head-files.txt" | tr -d ' ') files) but for the round's eight files (cmp/changed.txt)"
else
  res FAIL CHANGED-SET "the scratch repo differs from HEAD's tree otherwise than by the eight files (cmp/changed.txt): nothing runs"
  echo "PASS 0 FAIL 1 SKIP 0 VERDICT: REFUSED (the tree check) final-check.sh $(md5of "$SELF")" > "$O/ALL.done"
  cat "$O/ALL.done"
  exit 95
fi

# --------------------------------------------------------------- build (Windows)
LJW=$WB/luajit-windows-x86_64/src/luajit.exe
if wanted build; then
  echo "== build"
  if [ -n "${FC_USE_BUILD:-}" ]; then
    skip W-rc "the Windows build and its log's checks (FC_USE_BUILD=$WB: not built here)"
  else
    t=$(date +%s)
    env PATH="$TOOLS:$PATH" OCLJ_REPO="$RP" OCLJ_JNI="$JNIW" OCLJ_JNLUA="$JNLUAW" OCLJ_LUAJIT="$PLW" OCLJ_VARIANT=additive OCLJ_BUILD="$WB" sh "$RP/native/build-native.sh" > "$O/logs/build-win.log" 2>&1
    echo $? > "$O/rc/build-win.rc"; stamp build-win "$t"
    BL=$O/logs/build-win.log
    check W-rc "build-native.sh (additive) into a fresh OCLJ_BUILD succeeds" rcis build-win 0
    check W-pin "the pin is met and the export verified (8 trees, 232 files)" sh -c 'grep -q "pin     = met" "$1" && grep -q -F "8 trees to their names, 232 files to the pin" "$1"' x "$BL"
    check W-ignored-none "nothing ignored from the environment" grep -q "ignored from the environment: none " "$BL"
    check W-patch "patch-bitop-fold.sh: no CSE of int64 with another type, 76 added and 9 removed of 2720, verified" grep -q -F "$PATCHLINE" "$BL"
    check W-wgate "round 3's C files compile with 0 warnings under -Wall -Wextra (bitop_wgate.c)" grep -q -F "$WGATELINE" "$BL"
  fi
  check W-objects "77 LuaJIT objects, only lj_opt_fold.o differs from build/native's; our 3 objects equal" objcmp "$WB" "$BN" windows-x86_64 "$O/cmp/win-vs-buildnative"
  check W-fold-object "lj_opt_fold.o is the round's ($FOLD_O_WIN)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$WB/luajit-windows-x86_64/src/lj_opt_fold.o" "$FOLD_O_WIN"
  check W-build-copy "the build copy's lj_opt_fold.c is the patched one ($FOLD_C_MD5)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$WB/luajit-windows-x86_64/src/lj_opt_fold.c" "$FOLD_C_MD5"
fi
[ -x "$LJW" ] || res FAIL W-exists "no $LJW: nothing below that needs the new build can run"

# --------------------------------------------------------------- alma (AlmaLinux 8 and Ubuntu, in WSL)
if wanted alma; then
  echo "== AlmaLinux 8 (WSL)"
  t=$(date +%s)
  MSYS_NO_PATHCONV=1 wsl.exe -d AlmaLinux-8 -- env FC_MODE=alma sh "$SELF_L" --alma "$WO" "$SELF_L" "$WBASE" "$WRP" > "$O/logs/wsl-alma.log" 2>&1
  stamp wsl-alma "$t"
  MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- env FC_MODE=ubuntu sh "$SELF_L" --ubuntu "$WO" "$SELF_L" "$WRP" > "$O/logs/wsl-ubuntu.log" 2>&1
  A=$O/alma
  check ALMA-ran "the AlmaLinux 8 part ran to its end" [ -f "$A/part.done" ]
  check ALMA-rc "build-native.sh (additive, OCLJ_GLIBC_MAX=2.28) succeeds" [ "$(cat "$A/rc/build.rc" 2>/dev/null)" = 0 ]
  check ALMA-ignored-none "nothing ignored from the environment" grep -q "ignored from the environment: none " "$A/build.log"
  check ALMA-patch "patch-bitop-fold.sh: no CSE of int64 with another type, 76 added and 9 removed of 2720, verified" grep -q -F "$PATCHLINE" "$A/build.log"
  check ALMA-wgate "round 3's C files compile with 0 warnings under -Wall -Wextra" grep -q -F "$WGATELINE" "$A/build.log"
  check ALMA-glibc "the library needs GLIBC 2.28 at most (needs 2.$(glibcmax "$A/glibc.txt"))" sh -c '[ -n "$1" ] && [ "$1" -le 28 ]' x "$(glibcmax "$A/glibc.txt")"
  check ALMA-objects "77 LuaJIT objects, only lj_opt_fold.o differs from build/native's Linux tree (lj_opt_fold.o $BASE_FOLD_O_LINUX); our 3 objects equal" [ "$(cat "$A/rc/objcmp.rc" 2>/dev/null)" = 0 ]
  check ALMA-fold-object "lj_opt_fold.o is the round's AlmaLinux 8 one ($FOLD_O_LINUX)" [ "$(cat "$A/fold-o.md5" 2>/dev/null)" = "$FOLD_O_LINUX" ]
  check ALMA-build-copy "the build copy's lj_opt_fold.c is the Windows one's ($FOLD_C_MD5)" [ "$(cat "$A/fold-c.md5" 2>/dev/null)" = "$FOLD_C_MD5" ]
  check ALMA-bitjit "run-bitjit.sh, all seven parts, the Linux PUC: PASS, every part's lines" bitjitrc "$A/rc/bitjit-all.rc" "$A/bitjit-all.log"
  python -I "$HERE/fc-basecse.py" "$OW/alma/bitjit-all" new > "$O/cmp/alma-cse-new.txt" 2>&1; echo $? > "$O/rc/alma-cse-new.rc"
  check ALMA-cse "the cse part read as the fixed build must read (fc-basecse.py new: $(tail -1 "$O/cmp/alma-cse-new.txt"))" rcis alma-cse-new 0
  for m in idx rg2 phi; do
    check ALMA-gen-$m "the generator in its $m mode, 4 seeds: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc" 2>/dev/null)" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/gen-$2.log")" = 4 ]' x "$A" "$m"
  done
  if [ -f "$A/base-cse.skip" ]; then
    skip ALMA-base-cse "the base build has no Linux luajit ($(cat "$A/base-cse.skip"))"
  else
    python -I "$HERE/fc-basecse.py" "$OW/alma/base-cse" base > "$O/cmp/alma-cse-base.txt" 2>&1; echo $? > "$O/rc/alma-cse-base.rc"
    check ALMA-base-cse "fail-first: the cse part on the base build's Linux luajit FAILs as an unfixed build must (fc-basecse.py base: $(tail -1 "$O/cmp/alma-cse-base.txt"))" basecheck "$A/rc/base-cse.rc" "$A/base-cse.log" "$O/rc/alma-cse-base.rc"
    check ALMA-base-md5 "the base build's Linux tree is build/native's (luajit $BASE_LJ_LINUX, lj_opt_fold.o $BASE_FOLD_O_LINUX)" sh -c '[ "$(sed -n 1p "$1" | cut -c1-32)" = "$2" ] && [ "$(sed -n 2p "$1" | cut -c1-32)" = "$3" ]' x "$A/base.md5" "$BASE_LJ_LINUX" "$BASE_FOLD_O_LINUX"
  fi
fi

# --------------------------------------------------------------- bitjit (Windows)
if wanted bitjit; then
  echo "== bitjit"
  t=$(date +%s)
  env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_OUT="$O/runs/bitjit-all" sh "$RP/test/native/run-bitjit.sh" > "$O/logs/bitjit-all.log" 2>&1
  echo $? > "$O/rc/bitjit-all.rc"; stamp bitjit-all "$t"
  check BITJIT-all "run-bitjit.sh, all seven parts (gen, floor, fix1, idx, sel, nc, cse), PUC set: PASS, every part's lines, 20 of 20 pairs formed" bitjitrc "$O/rc/bitjit-all.rc" "$O/logs/bitjit-all.log"
  python -I "$HERE/fc-basecse.py" "$OW/runs/bitjit-all" new > "$O/cmp/cse-new.txt" 2>&1; echo $? > "$O/rc/cse-new.rc"
  check BITJIT-cse "the cse part read as the fixed build must read (fc-basecse.py new: $(tail -1 "$O/cmp/cse-new.txt"))" rcis cse-new 0
  for ms in idx:1 rg2:1 phi:201; do
    m=${ms%%:*}; s=${ms#*:}
    t=$(date +%s)
    env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_PARTS=gen OCLJ_BITJIT_GENMODE=$m OCLJ_BITJIT_SEED=$s OCLJ_BITJIT_SEEDS=4 OCLJ_BITJIT_OUT="$O/runs/gen-$m" sh "$RP/test/native/run-bitjit.sh" > "$O/logs/gen-$m.log" 2>&1
    echo $? > "$O/rc/gen-$m.rc"; stamp "gen-$m" "$t"
    check BITJIT-gen-$m "the generator in its $m mode, seeds $s-$((s + 3)), PUC set: PASS" sh -c '[ "$(cat "$1/rc/gen-$2.rc")" = 0 ] && [ "$(grep -c "^seed [0-9]*: PASS" "$1/logs/gen-$2.log")" = 4 ]' x "$O" "$m"
  done
fi

# --------------------------------------------------------------- base (the fail-first on the base build)
BLJ=$BASEB/luajit-windows-x86_64/src/luajit.exe
if wanted base; then
  echo "== base"
  md5sum "$BLJ" "$BASEB/luajit-windows-x86_64/src/lj_opt_fold.o" > "$O/cmp/base.md5" 2>&1
  t=$(date +%s)
  env OCLJ_BUILD="$BASEB" OCLJ_LUA53="$PUCW" OCLJ_BITJIT_PARTS=cse OCLJ_BITJIT_OUT="$O/runs/base-cse" sh "$RP/test/native/run-bitjit.sh" > "$O/logs/base-cse.log" 2>&1
  echo $? > "$O/rc/base-cse.rc"; stamp base-cse "$t"
  python -I "$HERE/fc-basecse.py" "$OW/runs/base-cse" base > "$O/cmp/cse-base.txt" 2>&1; echo $? > "$O/rc/cse-base.rc"
  check BASE-cse "fail-first: the cse part on the base build FAILs as an unfixed build must: forward pairs served, the reverse pairs merged, no int64 ref in a snapshot (fc-basecse.py base: $(tail -1 "$O/cmp/cse-base.txt"))" basecheck "$O/rc/base-cse.rc" "$O/logs/base-cse.log" "$O/rc/cse-base.rc"
  check BASE-base-md5 "the base build is build/native's (luajit.exe $BASE_LJ_WIN, lj_opt_fold.o $BASE_FOLD_O_WIN)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ] && [ "$(md5sum < "$3" | cut -c1-32)" = "$4" ]' x "$BLJ" "$BASE_LJ_WIN" "$BASEB/luajit-windows-x86_64/src/lj_opt_fold.o" "$BASE_FOLD_O_WIN"
  python -I "$HERE/fc-basecse.py" "$OW/runs/base-cse" new > "$O/cmp/cse-base-as-new.txt" 2>&1; echo $? > "$O/rc/cse-base-as-new.rc"
  check BASE-reader-ff1 "fail-first of the reader: the base build's output read as the fixed build's fails ($(tail -1 "$O/cmp/cse-base-as-new.txt"))" rcis cse-base-as-new 1
  if [ -d "$O/runs/bitjit-all/cse" ]; then
    python -I "$HERE/fc-basecse.py" "$OW/runs/bitjit-all" base > "$O/cmp/cse-new-as-base.txt" 2>&1; echo $? > "$O/rc/cse-new-as-base.rc"
    check BASE-reader-ff2 "fail-first of the reader: the fixed build's output read as the base build's fails ($(tail -1 "$O/cmp/cse-new-as-base.txt"))" rcis cse-new-as-base 1
  else
    skip BASE-reader-ff2 "the bitjit part did not run, so there is no fixed build's output to read"
  fi
fi

# --------------------------------------------------------------- suites
if wanted suites; then
  echo "== suites"
  t=$(date +%s)
  env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" OCLJ_BITOP_OUT="$O/runs/bitop" sh "$RP/test/native/run-bitop.sh" > "$O/logs/bitop.log" 2>&1
  echo $? > "$O/rc/bitop.rc"; stamp bitop "$t"
  check BITOP "run-bitop.sh: PASS" sh -c '[ "$(cat "$1/rc/bitop.rc")" = 0 ] && grep -q "^RUN-BITOP: PASS" "$1/logs/bitop.log"' x "$O"
  t=$(date +%s)
  env OCLJ_BUILD="$WB" OCLJ_LUA53="$PUCW" OCLJ_BITFUZZ_OUT="$O/runs/bitfuzz" sh "$RP/test/native/run-bitfuzz.sh" > "$O/logs/bitfuzz.log" 2>&1
  echo $? > "$O/rc/bitfuzz.rc"; stamp bitfuzz "$t"
  check BITFUZZ "run-bitfuzz.sh: PASS" sh -c '[ "$(cat "$1/rc/bitfuzz.rc")" = 0 ] && grep -q "^BITFUZZ PASS" "$1/logs/bitfuzz.log"' x "$O"
fi

# --------------------------------------------------------------- negctl (the full sweep, one call)
if wanted negctl; then
  echo "== negctl-bitop (full sweep)"
  grep -E '^arm [A-Z0-9-]+ ' "$RP/test/native/negctl-bitop.sh" | awk '{ print $2 }' | LC_ALL=C sort > "$O/cmp/negctl-script-arms.txt"
  for a in $ARMS37; do echo "$a"; done | LC_ALL=C sort > "$O/cmp/negctl-want.txt"
  check NEGCTL-arm-list "negctl-bitop.sh's arm calls are exactly the 37 arms this check expects" cmp -s "$O/cmp/negctl-script-arms.txt" "$O/cmp/negctl-want.txt"
  check NEGCTL-canon-list "canon's catcher list holds the cse part" grep -q -F "arm canon - 'bitop fuzz gen genrg2 floor fix1 idx sel nc cse security gate stage4'" "$RP/test/native/negctl-bitop.sh"
  t=$(date +%s)
  if [ -n "${FC_NEGCTL_ARMS:-}" ]; then
    env PATH="$TOOLS:$PATH" OCLJ_REPO="$RP" OCLJ_BUILD="$WB" OCLJ_LUAJIT="$PLW" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" CC=gcc OCLJ_NEGCTL_ARMS="$FC_NEGCTL_ARMS" sh "$RP/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
  else
    env PATH="$TOOLS:$PATH" OCLJ_REPO="$RP" OCLJ_BUILD="$WB" OCLJ_LUAJIT="$PLW" OCLJ_LUA53="$PUCW" OCLJ_JNI="$JNIW" CC=gcc sh "$RP/test/native/negctl-bitop.sh" > "$O/logs/negctl-bitop.log" 2>&1
  fi
  echo $? > "$O/rc/negctl-bitop.rc"; stamp negctl-bitop "$t"
  NL=$O/logs/negctl-bitop.log
  grep -E '^.negctl-bitop. [A-Z0-9-]+ [(].*: PASS [(]caught by' "$NL" | awk '{ print $2 }' | LC_ALL=C sort > "$O/cmp/negctl-caught.txt"
  check NEGCTL-rc "negctl-bitop.sh, every arm: exit 0 and the full-sweep PASS line" sh -c '[ "$(cat "$1/rc/negctl-bitop.rc")" = 0 ] && grep -q "^NEGCTL-BITOP: PASS (canon passes; every sabotage is caught" "$2"' x "$O" "$NL"
  check NEGCTL-canon "canon passes, every object reproduced, pristine files from the build's export, the cse part among its catchers" sh -c 'grep -q "^.negctl-bitop. canon (-, .*: PASS (every catcher passes; every object reproduced)" "$1" && grep -q "pristine files from .*luajit-export-windows-x86_64/src" "$1" && grep -q -F "bitjit[gen floor fix1 idx sel nc cse] 0" "$1"' x "$NL"
  check NEGCTL-37-arms "exactly the 37 arms, each caught by its catchers (CSEFWD by cse:t_csefwd cse:cseir)" sh -c 'cmp -s "$1" "$2" && grep -q "^.negctl-bitop. CSEFWD (.*: PASS (caught by cse:t_csefwd cse:cseir)" "$3"' x "$O/cmp/negctl-caught.txt" "$O/cmp/negctl-want.txt" "$NL"
  check NEGCTL-restore "restore: every file put back, every object as shipped" grep -q "^.negctl-bitop. restore: PASS" "$NL"
fi

# --------------------------------------------------------------- runners
if wanted runners; then
  echo "== runners"
  for r in run.sh run-mem.sh run-vgc.sh run-wd.sh run-penalty.sh run-race.sh run-security.sh run-pack.sh run-packfuzz.sh; do
    t=$(date +%s)
    env PATH="$TOOLS:$PATH" OCLJ_BUILD="$WB" OCLJ_JNI="$JNIW" OCLJ_LUA53="$PUCW" CC=gcc sh "$RP/test/native/$r" > "$O/logs/runner-$r.log" 2>&1
    echo $? > "$O/rc/runner-$r.rc"; stamp "runner-$r" "$t"
    check "RUNNER-$r" "$r on the new build: exit 0" rcis "runner-$r" 0
  done
fi

# --------------------------------------------------------------- hygiene
if wanted hygiene; then
  echo "== hygiene"
  : > "$O/cmp/pinned.txt"; pbad=0
  for e in $FILES8; do
    m=$(md5of "$RP/${e%%:*}"); echo "$m ${e%%:*}" >> "$O/cmp/pinned.txt"; [ "$m" = "${e#*:}" ] || pbad=1
  done
  check FILES8-PINNED "the eight files are the md5s this check names (cmp/pinned.txt)" [ "$pbad" = 0 ]
  : > "$O/cmp/cr.txt"; crbad=0
  for e in $FILES8; do
    n=$(crcount "$RP/${e%%:*}"); echo "$n ${e%%:*}" >> "$O/cmp/cr.txt"; [ "$n" = 0 ] || crbad=1
  done
  check CR0 "0 CR bytes in each of the eight files (cmp/cr.txt)" [ "$crbad" = 0 ]
  : > "$O/logs/git-diff-check.log"; gbad=0
  for e in $FILES8; do
    f=${e%%:*}
    case " $NEW3 " in *" $f "*) a=/dev/null ;; *) a=$HT/$f ;; esac
    git diff --no-index --check "$a" "$RP/$f" >> "$O/logs/git-diff-check.log" 2>&1; rc=$?
    echo "rc=$rc $f" >> "$O/logs/git-diff-check.log"
    [ "$rc" -le 1 ] || gbad=1
  done
  check GIT-DIFF-CHECK "git diff --no-index --check finds no whitespace error in the eight files against HEAD's copies (or /dev/null for the three new)" [ "$gbad" = 0 ]
  : > "$O/cmp/shn-gitbash.txt"; sbad=0
  for f in "$RP/native/luajit/patch-bitop-fold.sh" "$RP/test/native/negctl-bitop.sh" "$RP/test/native/run-bitjit.sh" "$SELF" "$HERE/fc-anchors.sh"; do
    sh -n "$f" > /dev/null 2>&1; rc=$?; echo "$rc $f" >> "$O/cmp/shn-gitbash.txt"; [ "$rc" = 0 ] || sbad=1
  done
  check SHN-gitbash "sh -n of the three changed shell scripts, this one and fc-anchors.sh (Git Bash)" [ "$sbad" = 0 ]
  if wanted alma; then
    check SHN-alma "sh -n of the same (AlmaLinux 8's sh)" sh -c '[ -s "$1" ] && ! grep -v "^0 " "$1"' x "$O/alma/shn.txt"
    check SHN-ubuntu "sh -n of the same (Ubuntu's dash)" sh -c '[ -s "$1" ] && ! grep -v "^0 " "$1"' x "$O/ubuntu/shn.txt"
  else
    skip SHN-alma "the alma part did not run"
    skip SHN-ubuntu "the alma part did not run"
  fi
  : > "$O/cmp/engine.txt"; ebad=0
  for s in "$RP"/native/luajit/patch-bitop-*.sh; do
    e=$(engine "$s"); echo "$e $s" >> "$O/cmp/engine.txt"; [ "$e" = "$ENGINE_MD5" ] || ebad=1
  done
  check ENGINE "the hunk engine of all seven patch-bitop-*.sh is unchanged ($ENGINE_MD5)" sh -c '[ "$1" = 0 ] && [ "$(wc -l < "$2" | tr -d " ")" = 7 ]' x "$ebad" "$O/cmp/engine.txt"
  P=$RP/native/luajit/patch-bitop-fold.sh
  check PATCH-NO-TAB-BS "patch-bitop-fold.sh holds no tab and no backslash" sh -c '[ "$1" = 0 ] && [ "$2" = 0 ]' x "$(bytecount 09 "$P")" "$(bytecount 5c "$P")"
  check LUA-NO-BS "t_csefwd.lua, cseir.lua and t_cserev.lua hold no backslash" sh -c '[ "$1" = 0 ] && [ "$2" = 0 ] && [ "$3" = 0 ]' x "$(bytecount 5c "$RP/test/native/bitop/t_csefwd.lua")" "$(bytecount 5c "$RP/test/native/bitop/cseir.lua")" "$(bytecount 5c "$RP/test/native/bitop/t_cserev.lua")"
  PS=$O/ps; mkdir -p "$PS"
  PSW=$(winpath_of "$PS")
  PIN=$(cat "$RP/native/luajit/upstream.commit")
  git --no-replace-objects -C "$PL" cat-file blob "$PIN:src/lj_opt_fold.c" > "$PS/pristine.c"
  cp "$HERE/fc-a4c0645-lj_opt_fold.c" "$PS/tip.c"
  check PATCH-INPUTS "the pin's pristine blob ($PIN_FOLD_C) and a4c0645's lj_opt_fold.c (blob $TIP_BLOB, md5 $TIP_FOLD_C)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ] && [ "$(md5sum < "$3" | cut -c1-32)" = "$4" ] && [ "$(git hash-object --no-filters "$3")" = "$5" ]' x "$PS/pristine.c" "$PIN_FOLD_C" "$PS/tip.c" "$TIP_FOLD_C" "$TIP_BLOB"
  TMPDIR=$PS sh "$P" "$PS/pristine.c" "$PS/out1.c" > "$PS/run1.log" 2>&1; echo $? > "$O/rc/ps-run1.rc"
  TMPDIR=$PS sh "$P" "$PS/out1.c" "$PS/out2.c" > "$PS/run2.log" 2>&1; echo $? > "$O/rc/ps-run2.rc"
  TMPDIR=$PS sh "$P" "$PS/tip.c" "$PS/tip-out.c" > "$PS/tip.log" 2>&1; echo $? > "$O/rc/ps-tip.rc"
  check PATCH-PRISTINE "on the pin's pristine blob: 76 added, 9 removed of 2720, verified by content, diff and reversal" sh -c '[ "$(cat "$1/rc/ps-run1.rc")" = 0 ] && grep -q -F "$2" "$1/ps/run1.log"' x "$O" "$PATCHLINE"
  check PATCH-IDEMPOTENT "on its own output: verified, unchanged, the same bytes" sh -c '[ "$(cat "$1/rc/ps-run2.rc")" = 0 ] && grep -q -F "$2" "$1/ps/run2.log" && cmp -s "$1/ps/out1.c" "$1/ps/out2.c"' x "$O" "$IDEMLINE"
  if [ -f "$WB/luajit-windows-x86_64/src/lj_opt_fold.c" ]; then
    check PATCH-IS-BUILD-COPY "its output is the build copy's lj_opt_fold.c, byte for byte ($FOLD_C_MD5)" sh -c 'cmp -s "$1" "$2" && [ "$(md5sum < "$1" | cut -c1-32)" = "$3" ]' x "$PS/out1.c" "$WB/luajit-windows-x86_64/src/lj_opt_fold.c" "$FOLD_C_MD5"
  else
    check PATCH-IS-BUILD-COPY "its output is the patched lj_opt_fold.c ($FOLD_C_MD5; no build to compare with)" sh -c '[ "$(md5sum < "$1" | cut -c1-32)" = "$2" ]' x "$PS/out1.c" "$FOLD_C_MD5"
  fi
  check PATCH-TIP "on a4c0645's lj_opt_fold.c: 76 added, 9 removed of 2730, verified" sh -c '[ "$(cat "$1/rc/ps-tip.rc")" = 0 ] && grep -q -F "$2" "$1/ps/tip.log"' x "$O" "$TIPLINE"
  anchor12() {  # the two lines hunk 12 replaces, as consecutive lines, once
    awk 'BEGIN { T = sprintf("%c", 9) }
      { sub(sprintf("%c$", 13), "") }
      prev == "      if (IR(ref)->op12 == op12)" && $0 == T "return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */" { n++ }
      { prev = $0 }
      END { print n + 0 }' "$1"
  }
  check HUNK12-ANCHOR "hunk 12's anchor (lj_opt_cse's if and return lines) once in the pin's file and once in a4c0645's" sh -c '[ "$1" = 1 ] && [ "$2" = 1 ]' x "$(anchor12 "$PS/pristine.c")" "$(anchor12 "$PS/tip.c")"
  python -I "$HERE/fc-ffpatch.py" "$OW/ps/ffpatch" "$RPW/native/luajit/patch-bitop-fold.sh" "$PSW/pristine.c" "$PSW/tip.c" > "$O/cmp/ffpatch.txt" 2>&1; echo $? > "$O/rc/ffpatch.rc"
  check PATCH-FAILFIRST "verify_content's fail-firsts: m1-m6 refused with their own messages, c5 and c6 refused, each lj_opt_cse count failing alone, the controls passing ($(tail -1 "$O/cmp/ffpatch.txt"))" sh -c '[ "$(cat "$1/rc/ffpatch.rc")" = 0 ] && grep -q "^FFPATCH: PASS (0 wrong)" "$1/cmp/ffpatch.txt" && [ "$(grep -c "^ok " "$1/cmp/ffpatch.txt")" = 17 ]' x "$O"
  if [ -x "$LJW" ]; then
    python -I "$HERE/fc-fftests.py" "$OW/runs/fftests" "$RPW/test/native/bitop" "$PUCW" "$(winpath_of "$BASEB")/luajit-windows-x86_64/src" "$(winpath_of "$WB")/luajit-windows-x86_64/src" > "$O/cmp/fftests.txt" 2>&1; echo $? > "$O/rc/fftests.rc"
    check TEXT-FAILFIRST "the test files' fail-firsts: t_cserev's text check refuses a second for and any bit (as comments), t_csefwd's copy and side checks fire, cseir's copy and side gates matter ($(tail -1 "$O/cmp/fftests.txt"))" sh -c '[ "$(cat "$1/rc/fftests.rc")" = 0 ] && grep -q "^FFTESTS: PASS (0 wrong)" "$1/cmp/fftests.txt" && [ "$(grep -c "^ok " "$1/cmp/fftests.txt")" = 12 ]' x "$O"
  else
    skip TEXT-FAILFIRST "no new build's luajit"
  fi
  if [ -d "$WB/luajit-export-windows-x86_64/src" ]; then
    sh "$HERE/fc-anchors.sh" "$RP/test/native/negctl-bitop.sh" "$WB" "$RP" "$O/anchors" > "$O/cmp/anchors.txt" 2>&1; echo $? > "$O/rc/anchors.rc"
    check NEGCTL-ANCHORS "negctl's 37 arms: each OLD text once in each copy (build, repo or patched), and its sabotage one changed line ($(tail -1 "$O/cmp/anchors.txt"))" sh -c 'grep -q "^arms: 37$" "$1" && grep -q "^verdict: ALL-OK$" "$1" && [ "$(grep -c "patched .* equals the build copy" "$2/anchors/patched.txt")" = 7 ]' x "$O/cmp/anchors.txt" "$O"
  else
    skip NEGCTL-ANCHORS "no build export in $WB"
  fi
  BCW=$(winpath_of "$BN")/luajit-windows-x86_64/src
  for s in 0 1 -1; do
    python -I "$HERE/fc-cites.py" "$RPW" "$BCW" "$PSW/pristine.c" "$s" > "$O/cmp/cites-shift$s.txt" 2>&1; echo $? > "$O/rc/cites-shift$s.rc"
  done
  check CITES "the round's line cites hold by content, and every cite moved one line down or up fails ($(tail -1 "$O/cmp/cites-shift0.txt"); $(tail -1 "$O/cmp/cites-shift1.txt"); $(tail -1 "$O/cmp/cites-shift-1.txt"))" sh -c '[ "$(cat "$1/rc/cites-shift0.rc")" = 0 ] && [ "$(cat "$1/rc/cites-shift1.rc")" = 0 ] && [ "$(cat "$1/rc/cites-shift-1.rc")" = 0 ] && grep -q "^cites: rows=46 ok=46 bad=0 shift=0" "$1/cmp/cites-shift0.txt" && grep -q "^cites: rows=46 ok=0 bad=46 shift=1" "$1/cmp/cites-shift1.txt" && grep -q "^cites: rows=46 ok=0 bad=46 shift=-1" "$1/cmp/cites-shift-1.txt"' x "$O"
  # The round's added lines: the diff of each changed file against HEAD's, and the new files whole.
  : > "$O/cmp/added-lines.txt"
  for e in $FILES8; do
    f=${e%%:*}
    case " $NEW3 " in *" $f "*) cat "$RP/$f" >> "$O/cmp/added-lines.txt" ;; *) diff "$HT/$f" "$RP/$f" | grep '^>' >> "$O/cmp/added-lines.txt" ;; esac
  done
  check NO-PRIVATE "no path of the private scratch directory in the round's added lines" sh -c '! grep -n -i -E "PRIVATE-SCRATCH-PATHS" "$1"' x "$O/cmp/added-lines.txt"
  check NO-EMAIL "no email address in the round's added lines" sh -c '! grep -n -E "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+" "$1"' x "$O/cmp/added-lines.txt"
  ( cd "$RP/test/native" && grep -r -l -E 'bit[.](lshift|rshift|arshift|bnot|band|bor|bxor|tobit|rol|ror|bswap)' --include='*.lua' . | sed 's|^[.]/||' | LC_ALL=C sort ) > "$O/cmp/bitlib-callers.txt"
  for f in bitop/t_bit.lua bitop/t_csefwd.lua penalty_test.lua; do echo "$f"; done > "$O/cmp/bitlib-want.txt"
  nop53() {  # no 5.3 bitwise operator outside comment lines
    awk '$0 !~ /^[ ]*--/' "$1" | grep -c -E '<<|>>|[^~=<>]~[^=]| & | [|] '
  }
  check BITLIB-CALLERS "the bit library is called only by bitop/t_bit.lua, bitop/t_csefwd.lua (forward only, its own check) and penalty_test.lua, and the first and last use no 5.3 operator" sh -c 'cmp -s "$1" "$2" && [ "$3" = 0 ] && [ "$4" = 0 ]' x "$O/cmp/bitlib-callers.txt" "$O/cmp/bitlib-want.txt" "$(nop53 "$RP/test/native/bitop/t_bit.lua")" "$(nop53 "$RP/test/native/penalty_test.lua")"
  : > "$O/cmp/helpers.txt"; hbad=0
  for e in $HELPERS; do
    m=$(md5of "$HERE/${e%%:*}"); echo "$m ${e%%:*}" >> "$O/cmp/helpers.txt"
    [ "$m" = "${e#*:}" ] || hbad=1
  done
  check HELPERS "every helper beside this script has the md5 it names (fc-anchors.sh and fc-bench from integrate, fc-timing-summ.py integrate's with a guard for rows with no ratio, fc-a4c0645-lj_opt_fold.c from csetwin/upstream, the rest the fixer's; cmp/helpers.txt)" [ "$hbad" = 0 ]
fi

# --------------------------------------------------------------- timing (last)
if wanted timing; then
  echo "== timing"
  T=$O/timing; mkdir -p "$T"
  cp "$HERE/fc-bench/bench_bit.lua" "$HERE/fc-bench/bench_bit2.lua" "$HERE/fc-bench/ident.lua" "$HERE/fc-bench/bench_numconv.lua" "$T/"
  md5sum "$T"/*.lua "$BLJ" "$LJW" "$BASEB/luajit-windows-x86_64/src/lj_opt_fold.o" "$WB/luajit-windows-x86_64/src/lj_opt_fold.o" > "$T/inputs.md5" 2>&1
  check TIMING-inputs "the benches are integrate/timing/bench's (fc-bench, md5s pinned); base is build/native's luajit.exe ($BASE_LJ_WIN, lj_opt_fold.o $BASE_FOLD_O_WIN), new's lj_opt_fold.o the round's ($FOLD_O_WIN)" sh -c '[ "$(md5sum < "$1/bench_bit.lua" | cut -c1-32)" = 2c6a60e0bb01756be2fc2b1767166b43 ] && [ "$(md5sum < "$1/bench_bit2.lua" | cut -c1-32)" = 7bb3ab87a8e0c3d9fbe618875e680f56 ] && [ "$(md5sum < "$1/ident.lua" | cut -c1-32)" = 5a0429552f6a808731b13a57bf10cce7 ] && [ "$(md5sum < "$1/bench_numconv.lua" | cut -c1-32)" = c15c325eb474b7458a753a637335ecae ] && [ "$(md5sum < "$2" | cut -c1-32)" = "$3" ] && [ "$(md5sum < "$4" | cut -c1-32)" = "$5" ] && [ "$(md5sum < "$6" | cut -c1-32)" = "$7" ]' x "$T" "$BLJ" "$BASE_LJ_WIN" "$BASEB/luajit-windows-x86_64/src/lj_opt_fold.o" "$BASE_FOLD_O_WIN" "$WB/luajit-windows-x86_64/src/lj_opt_fold.o" "$FOLD_O_WIN"
  NB=$(awk -v n=2e7 -v d="$FC_NDIV" 'BEGIN { printf "%d", n / d }')
  NB2=$(awk -v n=1e7 -v d="$FC_NDIV" 'BEGIN { printf "%d", n / d }')
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-before.txt" 2>/dev/null
  $TASKLIST > "$T/procs-before.txt" 2>/dev/null
  r=1; stopped=0
  while [ "$r" -le "$FC_ROUNDS" ]; do
    if javacheck "$T/jvms-round-$r.txt"; then
      { echo "STOPPED before round $r: a Java process started"; cat "$T/jvms-round-$r.txt"; } > "$T/STOPPED"
      stopped=1; break
    fi
    if [ $((r % 2)) = 1 ]; then ORDER="base new"; else ORDER="new base"; fi
    p=1
    for v in $ORDER; do
      if [ "$v" = base ]; then E=$BLJ; else E=$LJW; fi
      for b in "bench_bit.lua $NB" "bench_bit2.lua $NB2" "ident.lua $NB2 time" "bench_numconv.lua $NB"; do
        n=${b%%.lua*}
        ( cd "$T" && "$E" $b 2>&1 ) | awk -v r="$r" -v p="$p" -v v="$v" -v n="$n" '{ sub(/[[:cntrl:]]+$/, ""); print "round=" r " pos=" p " vm=" v " bench=" n ": " $0 }' >> "$T/raw.txt"
      done
      p=$((p + 1))
    done
    echo "round $r done $(date -u +%H:%M:%SZ) order: $ORDER" >> "$T/progress.txt"
    r=$((r + 1))
  done
  powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).LoadPercentage" > "$T/cpuload-after.txt" 2>/dev/null
  $TASKLIST > "$T/procs-after.txt" 2>/dev/null
  python -I "$HERE/fc-timing-summ.py" "$(winpath_of "$T")/raw.txt" "$((r - 1))" > "$T/summary.txt" 2>&1; echo $? > "$O/rc/timing-summary.rc"
  check TIMING-complete "all $FC_ROUNDS rounds ran (no Java process appeared)" sh -c '[ "$1" = 0 ] && [ "$(grep -c "^round [0-9]* done" "$2")" = "$3" ]' x "$stopped" "$T/progress.txt" "$FC_ROUNDS"
  check TIMING-results-equal "every result of the new build equals base's, in every round, all 21 rows (timing/summary.txt)" sh -c 'grep -q "^RESULTS: EQUAL" "$1" && grep -q "^SUMMARY: OK" "$1"' x "$T/summary.txt"
  if [ "$FC_NDIV" = 1 ]; then
    check TIMING-no-gross-change "each row's median new/base within [0.5, 2.0] (a smoke bound; the ratios are in timing/summary.txt)" grep -q "^GROSS: OK" "$T/summary.txt"
  else
    skip TIMING-no-gross-change "FC_NDIV=$FC_NDIV: a smoke reading, too short to time"
  fi
fi

# --------------------------------------------------------------- census and md5s after
echo "== census after"
t=$(date +%s); census "$O/census/after"; stamp census-after "$t"
if [ "$FC_CENSUS" = none ]; then
  skip CENSUS-build "FC_CENSUS=none: the real repo's build/ was not listed"
else
  check CENSUS-build "every file under the real repo's build/ has its $FC_CENSUS entry of the start, none added or removed ($(wc -l < "$O/census/before-build.md5" | tr -d ' ') files)" cmp -s "$O/census/before-build.md5" "$O/census/after-build.md5"
fi
check CENSUS-pristine "the pristine checkout's stat list (mtimes included), its .git md5 list and HEAD are unchanged" sh -c 'cmp -s "$1-pristine-stat.txt" "$2-pristine-stat.txt" && cmp -s "$1-pristine-git.md5" "$2-pristine-git.md5" && cmp -s "$1-pristine-head.txt" "$2-pristine-head.txt"' x "$O/census/before" "$O/census/after"
check CENSUS-real-repo "the real repo's HEAD, git status and its changed files' md5s are unchanged (nothing here writes there)" sh -c 'cmp -s "$1-real-git.txt" "$2-real-git.txt" && cmp -s "$1-real-changed.md5" "$2-real-changed.md5"' x "$O/census/before" "$O/census/after"
if [ "$FC_CENSUS" = none ]; then
  skip CENSUS-scratch-repo "FC_CENSUS=none: the scratch repo was not listed"
else
  check CENSUS-scratch-repo "every file of the scratch repo has its $FC_CENSUS entry of the start, none added or removed ($(wc -l < "$O/census/before-rp.md5" | tr -d ' ') files)" cmp -s "$O/census/before-rp.md5" "$O/census/after-rp.md5"
fi
mdstate "$O/md5-end.txt"
check FILES-unchanged "the eight files, this script and its helpers are unchanged since the start; the real repo's HEAD too" sh -c 'cmp -s "$1/md5-start.txt" "$1/md5-end.txt" && [ "$(git -C "$2" rev-parse HEAD)" = "$(cat "$1/repo-head.txt")" ]' x "$O" "$R"
NF=$(grep -c '^FAIL ' "$SUM"); NP=$(grep -c '^PASS ' "$SUM"); NS=$(grep -c '^SKIP ' "$SUM")
if [ "$NF" != 0 ]; then V=FAIL
elif [ "$NS" != 0 ] || [ "$KNOBS" != "FC_PARTS=build alma bitjit base suites negctl runners hygiene timing FC_USE_BUILD=unset FC_BASE_BUILD=unset FC_RP=unset FC_TASKLIST=unset FC_ROUNDS=8 FC_NDIV=1 FC_NEGCTL_ARMS=unset FC_CENSUS=md5" ]; then V=INCOMPLETE
else V=PASS; fi
echo "PASS $NP FAIL $NF SKIP $NS VERDICT: $V secs $(( $(date +%s) - T0 )) $KNOBS final-check.sh $(md5of "$SELF")" > "$O/ALL.done"
cat "$O/ALL.done"
