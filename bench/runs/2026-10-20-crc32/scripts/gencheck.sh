#!/bin/sh
# gencheck.sh <fresh outdir> -- the combined gen.lua generates, mode by mode,
# byte for byte what that mode's own gen.lua generated: HEAD's for the
# default and phi modes, proto-folda's for idx, proto-rg2's for rg2.  Run
# with the shipped luajit.exe (only gen.lua runs; it compiles nothing that
# matters).  Prints one line per (mode, seed) and a final verdict.
set -u
OUT=$1
[ -e "$OUT" ] && { echo "REFUSING: $OUT exists"; exit 99; }
mkdir -p "$OUT" || exit 98
unset LUA_INIT LUA_INIT_5_3
C=/c/Users/astro/claude-tmp/oclj/crc
LJ=/c/Users/astro/Downloads/OC-LuaJIT/build/native/luajit-windows-x86_64/src/luajit.exe
NEW=$C/combine/repo/test/native/bitop/gen.lua
bad=0; n=0
one() {  # one <mode> <seed> <reference gen.lua>
  m=$1; s=$2; ref=$3; tag=${m:-default}-$s
  mkdir -p "$OUT/$tag/ref" "$OUT/$tag/new"
  "$LJ" -joff "$ref" "$s" 500 "$OUT/$tag/ref" $m > "$OUT/$tag/ref.log" 2>&1
  r1=$?
  "$LJ" -joff "$NEW" "$s" 500 "$OUT/$tag/new" $m > "$OUT/$tag/new.log" 2>&1
  r2=$?
  v=same
  for f in cases_lj.lua cases_puc.lua; do
    [ -s "$OUT/$tag/ref/$f" ] && [ -s "$OUT/$tag/new/$f" ] || v=missing
    cmp -s "$OUT/$tag/ref/$f" "$OUT/$tag/new/$f" || { [ "$v" = same ] && v=DIFFER; }
  done
  [ "$r1" = 0 ] && [ "$r2" = 0 ] || v="$v(exit $r1/$r2)"
  echo "$tag: $v ($(md5sum < "$OUT/$tag/new/cases_lj.lua" | cut -c1-8))"
  n=$((n + 1))
  [ "$v" = same ] || bad=1
}
for s in 1 2 3 4 57 301; do one "" $s $C/combine/head/test/native/bitop/gen.lua; done
for s in 1 2 3 4 57 301; do one phi $s $C/combine/head/test/native/bitop/gen.lua; done
for s in 1 2 3 4 5 777; do one idx $s $C/folda/repo/test/native/bitop/gen.lua; done
for s in 1 2 3 4 501 777; do one rg2 $s $C/rg2/repo/test/native/bitop/gen.lua; done
# the control: the modes must differ from each other (a mode flag that read
# nothing would make idx or rg2 equal the default)
for m in idx rg2; do
  cmp -s "$OUT/default-1/new/cases_lj.lua" "$OUT/$m-1/new/cases_lj.lua" && { echo "CONTROL FAIL: $m-1 equals default-1"; bad=1; }
done
md5sum "$LJ" "$NEW" $C/combine/head/test/native/bitop/gen.lua $C/folda/repo/test/native/bitop/gen.lua $C/rg2/repo/test/native/bitop/gen.lua > "$OUT/inputs.md5"
if [ "$bad" = 0 ]; then echo "GENCHECK: PASS ($n mode-seed pairs byte-identical; idx and rg2 differ from default)"; else echo "GENCHECK: FAIL"; fi
