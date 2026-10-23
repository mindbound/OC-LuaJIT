#!/bin/sh
# anchors.sh <negctl-bitop.sh> <build dir> <repo> <fresh outdir> -- for every
# arm in <negctl-bitop.sh>'s armlist, count its OLD text (whole consecutive
# lines, as negctl's sabotage() matches it) in each copy of the arm's file:
#   build    <build dir>/luajit-windows-x86_64/src/<file>
#   repo     <repo>/native/luajit/<file> (native files), or
#            <repo>/serializer/eris_lj.c
#   patched  <repo>/native/luajit/patch-bitop-<x>.sh's output on the pin's
#            pristine file from <build dir>'s export (patched files)
# and apply negctl's own sabotage() (extracted from the script) to each,
# requiring exactly one line changed and that line to say SABOTAGE <NAME>:.
# Prints one row per arm and copy; exit 0 iff every row is OK.  Adapted
# from numconv/integrate/scripts/anchors.sh (the repo is an argument).
# Written with a file tool; no backslashes.
set -u
NC=${1:?usage: anchors.sh <negctl-bitop.sh> <build dir> <repo> <fresh outdir>}
B=${2:?usage}
R=${3:?usage}
O=${4:?usage}
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O/patched" "$O/tmp" "$O/sab" || exit 98
SRC=$B/luajit-windows-x86_64/src
EXP=$B/luajit-export-windows-x86_64/src
[ -d "$EXP" ] || { echo "no $EXP"; exit 98; }
awk '$0 == "sabotage() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$NC" > "$O/sabotage.sh"
awk '$0 == "armlist() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$NC" > "$O/armlist.sh"
[ -s "$O/sabotage.sh" ] && [ -s "$O/armlist.sh" ] || { echo "cannot extract sabotage() or armlist()"; exit 98; }
for p in lj_parse.c:parse vm_x64.dasc:vm lj_meta.c:meta lj_record.c:record lj_opt_fold.c:fold lj_bcdump.h:bcdump lib_jit.c:jitlib; do
  f=${p%%:*}; s=patch-bitop-${p#*:}.sh
  TMPDIR=$O/tmp sh "$R/native/luajit/$s" "$EXP/$f" "$O/patched/$f" > "$O/tmp/$s.log" 2>&1 || { echo "$s refused $EXP/$f"; exit 98; }
  if cmp -s "$O/patched/$f" "$SRC/$f"; then echo "patched $f equals the build copy" >> "$O/patched.txt"; else echo "patched $f DIFFERS from the build copy" >> "$O/patched.txt"; fi
done
md5sum "$NC" "$O/patched/"* "$SRC/lj_opt_fold.c" > "$O/inputs.md5"
. "$O/sabotage.sh"
countold() {  # countold <file> <old>: how many times <old> occurs, as sabotage() matches
  OLD=$2 awk '
    BEGIN { NL = sprintf("%c", 10); TAB = sprintf("%c", 9)
      no = split(ENVIRON["OLD"], O, NL); for (k = 1; k <= no; k++) gsub(/@T@/, TAB, O[k]) }
    { L[++nl] = $0 }
    END { c = 0
      for (i = 1; i + no - 1 <= nl; i++) {
        for (j = 1; j <= no; j++) if (L[i + j - 1] != O[j]) break
        if (j > no) c++
      }
      print c }' "$1"
}
copies() {
  case $1 in
    eris_lj.c) echo "repo:$R/serializer/eris_lj.c" ;;
    oclj_*) echo "build:$SRC/$1 repo:$R/native/luajit/$1" ;;
    *) echo "build:$SRC/$1 patched:$O/patched/$1" ;;
  esac
}
bad=0
narms=0
arm() {
  name=$1 file=$2
  [ "$name" = canon ] && return 0
  narms=$((narms + 1))
  for c in $(copies "$file"); do
    kind=${c%%:*} path=${c#*:}
    n=$(countold "$path" "$4")
    out=$O/sab/$name.$kind.$file
    v=OK
    if [ "$n" != 1 ]; then v="ANCHOR x$n"
    elif ! sabotage "$path" "$4" "$5" "$out"; then v="SABOTAGE REFUSED"
    else
      nold=$(diff "$path" "$out" | grep -c '^<')
      nnew=$(diff "$path" "$out" | grep -c '^>')
      nmark=$(grep -c -F "SABOTAGE $name:" "$out")
      [ "$nold" = 1 ] && [ "$nnew" = 1 ] && [ "$nmark" = 1 ] || v="DIFF $nold/$nnew mark $nmark"
    fi
    [ "$v" = OK ] || bad=1
    printf '%-13s %-18s %-8s count=%s %s\n' "$name" "$file" "$kind" "$n" "$v"
  done
}
. "$O/armlist.sh"
armlist
echo "arms: $narms"
echo "verdict: $([ "$bad" = 0 ] && echo ALL-OK || echo SOME-BAD)"
exit $bad
