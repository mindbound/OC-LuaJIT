#!/bin/sh
# objcmp.sh <build A> <build B> <platform> <fresh out prefix> -- the 77 LuaJIT
# objects (src/*.o, src/host/*.o) and our 3 (obj-<platform>/*.o) of two
# builds: md5 lists, their diff, and a one-line summary <prefix>.txt.
# Exit 0 iff both hold 77 + 3 objects of the same names, our 3 are equal, and
# the LuaJIT objects differ in lj_opt_fold.o alone (or in none, with ALLOW0=1).
# Modelled on the select round's final-check.sh objcmp.  No backslashes.
set -u
A=$1; B=$2; PL=$3; O=$4
[ -e "$O.txt" ] && { echo "REFUSING: $O.txt exists"; exit 99; }
( cd "$A/luajit-$PL/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$O.A-lj.md5"
( cd "$B/luajit-$PL/src" && md5sum *.o host/*.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$O.B-lj.md5"
( cd "$A/obj-$PL" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$O.A-obj.md5"
( cd "$B/obj-$PL" && md5sum *.o ) | tr -d '*' | LC_ALL=C sort -k2 > "$O.B-obj.md5"
diff "$O.A-lj.md5" "$O.B-lj.md5" > "$O.lj.diff"
na=$(grep -c '^<' "$O.lj.diff"); nb=$(grep -c '^>' "$O.lj.diff")
names=$(grep '^[<>]' "$O.lj.diff" | awk '{ print $3 }' | LC_ALL=C sort -u | awk '{ printf "%s ", $0 }')
cmp -s "$O.A-obj.md5" "$O.B-obj.md5"; ours=$?
la=$(wc -l < "$O.A-lj.md5" | tr -d ' '); lb=$(wc -l < "$O.B-lj.md5" | tr -d ' ')
oa=$(wc -l < "$O.A-obj.md5" | tr -d ' ')
echo "A=$A B=$B: LuaJIT objects $la/$lb; differing: ${names:-none} ($na/$nb lines); ours $oa, equal=$([ $ours = 0 ] && echo yes || echo no)" > "$O.txt"
cat "$O.txt"
[ "$la" = 77 ] && [ "$lb" = 77 ] && [ "$oa" = 3 ] && [ "$ours" = 0 ] || exit 1
if [ "${ALLOW0:-0}" = 1 ] && [ "$na" = 0 ] && [ "$nb" = 0 ]; then exit 0; fi
[ "$na" = 1 ] && [ "$nb" = 1 ] && [ "$names" = "lj_opt_fold.o " ]
