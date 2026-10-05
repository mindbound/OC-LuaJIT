#!/bin/sh
# chainE2.sh -- the two-site lj_err.c patch (lj_err_mem + lj_err_err): rebuild both Windows
# variants and the Linux additive, freeze them in E2/, run the native gates (E-cores), the
# Linux gates (WSL), the shipped-archive census identity check (E-cores), then the five full
# harness suites (P-cores).  Serial.  Everything into fresh dirs under E2/ and runsE2/.
set -u
. /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/chainlib2.sh
. $W/env.sh
E2=$W2/E2
[ -e "$E2" ] && { echo "REFUSING: $E2 exists"; exit 99; }
mkdir -p "$E2/libdir-additive" "$E2/libdir-dropin"
say() { echo "== $(date -u '+%H:%M:%S') $*" >> $E2/chain.log; }
cd "$REPO" || exit 97
say "chainE2 start; java procs: $(tasklist 2>/dev/null | grep -ciE '^javaw?\.exe')"
md5sum build/native/luajit-windows-x86_64/src/libluajit.a build/native/libdir-additive/*.dll build/native/libdir/*.dll build/native/dist/* > $E2/before.md5
OCLJ_VARIANT=additive sh native/build-native.sh > $E2/build-additive.log 2>&1; say "additive build exit $?"
OCLJ_VARIANT=dropin sh native/build-native.sh > $E2/build-dropin.log 2>&1; say "dropin build exit $?"
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash /mnt/c/Users/astro/Downloads/OC-LuaJIT/build/wsl-build-native.sh > $E2/wsl-build.out 2>&1; say "wsl build exit $?"
cp build/wsl-native.log $E2/wsl-native.log
md5sum build/native/luajit-windows-x86_64/src/libluajit.a build/native/libdir-additive/*.dll build/native/libdir/*.dll build/native/dist/* build/native/obj-windows-x86_64/lj52shim.o > $E2/after.md5
cp build/native/libdir-additive/libjnluajit52-windows-x86_64.dll $E2/libdir-additive/
cp build/native/libdir/libjnlua52-windows-x86_64.dll $E2/libdir-dropin/
# lj_err_mem and lj_err_err as compiled into the shipped archive
mkdir -p $E2/arx && (cd $E2/arx && ar x "$REPO/build/native/luajit-windows-x86_64/src/libluajit.a" lj_err.o \
  && objdump -d --no-show-raw-insn lj_err.o | awk '/<lj_err_mem>:/,/^$/' > ../lj_err_mem.dis \
  && objdump -d --no-show-raw-insn lj_err.o | awk '/<lj_err_err>:/,/^$/' > ../lj_err_err.dis)
say "clamp cmp in lj_err_mem: $(grep -c 'cmp    %rdx,0x28(%rbx)' $E2/lj_err_mem.dis); lines in lj_err_err: $(wc -l < $E2/lj_err_err.dis)"
# the gates, pinned to the E-cores
"$A" 3FC3FC default "$SH" "$(cygpath -m $W/gates.sh)" "$(cygpath -m $E2/gatesE2)" > $E2/gatesE2.out 2>&1
say "gates: $(tr '\n' ';' < $E2/gatesE2/summary.txt)"
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- bash /mnt/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/E/wsl-gates.sh /mnt/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/E2/wslgates > $E2/wslgates.out 2>&1
say "wsl gates: $(tr '\n' ';' < $E2/wslgates/summary.txt)"
# the census's patched side on the shipped archive: the verdict shim, string, seed 1, no ASLR
C=$W2/errmem/census; LJ=$REPO/build/native/luajit-windows-x86_64/src; OBJ=$REPO/build/native/obj-windows-x86_64
gcc -g -O2 -Wall -Wextra -I$LJ -I$REPO/native -I"$OCLJ_JNI" -I"$OCLJ_JNI/win32" -include $REPO/native/lj52shim.h \
  -DFIXSEED -Wl,--wrap=lj_prng_seed_secure -Wl,--disable-dynamicbase,--disable-high-entropy-va \
  $W2/repro/lj_repro.c $W2/j2s/obj/verdict.o $OBJ/eris_lj.o $LJ/libluajit.a -lm -o $C/bin/verdict_ship2nf.exe > $E2/ship2-build.log 2>&1
say "ship2 driver built: exit $?; clamp cmps in its lj_err_mem: $(objdump -d --no-show-raw-insn $C/bin/verdict_ship2nf.exe | awk '/<lj_err_mem>:/,/^$/' | grep -c 'cmp    %rdx,0x28(%rbx)')"
(cd $C && sh census.sh verdict_ship2nf.exe string 2048 verdict_ship2nf_string > $E2/ship2-census.out 2>&1)
say "ship2 census: $(cat $E2/ship2-census.out | tr '\n' ' ')"
sh $C/ident.sh $C/out/verdict_fixnf_string.tsv $C/out/verdict_ship2nf_string.tsv > $E2/ship2-ident.txt; say "ship2 ident: $(head -1 $E2/ship2-ident.txt)"
# the full suites, pinned to the P-cores
EADD=$(cygpath -m $E2/libdir-additive); EDROP=$(cygpath -m $E2/libdir-dropin)
ROOT=$W2/runsE2; mkdir -p $ROOT; RUNS=$ROOT/full; LOG=$ROOT/full.log; mkdir -p $RUNS
for spec in "fullE2-additive-on additive $EADD on UNSET" "fullE2-dropin-on luajit $EDROP on UNSET" \
            "fullE2-additive-off additive $EADD off UNSET" "fullE2-additive-sieve additive $EADD on sieve" \
            "fullE2-stock stock - on UNSET"; do
  set -- $spec; D=$RUNS/$1
  "$A" C03C03 default "$SH" "$FULL" "$(cygpath -m $D)" $2 "$3" $4 $5 > /dev/null 2>&1
  echo "$1 exit=$(cat $D/exit.txt 2>/dev/null)" >> $LOG
  grep -E 'SMOKE\| (CHECKS|VERDICT|MILESTONE [^ ]+: (FAIL|SKIP)|MILESTONE (km-1|b2|mem-2|acc-4|j0)[^ ]*:)|^SMOKE (PASS|FAIL)' $D/run.log | cut -c1-260 | sed 's/^/    /' >> $LOG
done
say "full suites done: $(grep -c 'VERDICT: PASS' $LOG) of 5 PASS"
say "chainE2 done"
