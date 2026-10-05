#!/bin/sh
# census-M1.sh -- M1 (d3-final.txt section 6): the hermetic census of the FINAL
# instrumented driver (bin/lref_F.exe: the final native/lj52shim.c, md5
# 28a8f091, instrumented by tools/mkref.py; OCLJ_REFLOG=1) through lifetime's
# eight cells at seed 1 and oe-string plus the two census string cells at
# seeds 2 and 3, then tools/compare_F.py against the baselines.
#   seed 1   string/record x JIT on/off, probe2.lua, 4 096 caps each (the forensics'
#            baselines L4_* are 4 096); oe string/record, probe2oe.lua, 2 048;
#            k2048 string AND record, probe2k_2048.lua, 2 048 (baselines X_*)
#   seeds 2, 3   oe_string_j1, string_j1, string_j0 at SEEDCAPS caps (default 2 048,
#            lifetime's seed-run size; env SEEDCAPS overrides).  No baseline exists
#            for the string cells at these seeds (lifetime ran only oe-string, as
#            BASEs2/BASEs3), so each is run here too with the forensics' own
#            instrumented shipped-shim driver (bin/lref_ref.exe, a copy of
#            sc/forensics/bin/lref_ref.exe, 83a4f083) as B_<cell>_s<seed>; the
#            oe-string re-run is then also a determinism check against lifetime's.
# Tags: F_<cell>_j<jit>[_s<seed>] for the final, B_... for the baselines run here.
# 12 processes at a time, each pinned (census.sh/job.sh: affrun 3FC3FC default).
# Resumable: a tag whose .tsv already has its full line count is skipped; a
# partial one stops the chain (move it aside; nothing is ever deleted here).
# Launch from the main session (Git Bash), and Monitor logs/census-M1.log for
# "census-M1 done":
#   cd /c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/finst && nohup sh census-M1.sh > logs/census-M1.log 2>&1 &
# Expected: 24 576 runs at seed 1 + 6 x 2 x SEEDCAPS for the seeds (36 864 at
# the default); lifetime's rate was ~1 000 caps/min at P=12 on a quiet machine.
set -u
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/finst
LT=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/design/lifetime
SEEDCAPS=${SEEDCAPS:-2048}
P=12
cd $WD || exit 99
say() { echo "== $(date -u '+%H:%M:%S') $*"; }
for x in bin/lref_F.exe bin/lref_ref.exe census.sh job.sh ident.sh tools/compare_F.py; do
  [ -e "$x" ] || { say "missing $x: run build.sh first"; exit 98; }
done
[ "$(md5sum < bin/lref_ref.exe | cut -c1-8)" = 83a4f083 ] || { say "bin/lref_ref.exe is not the forensics' (83a4f083)"; exit 97; }
export OCLJ_REFLOG=1
# cell <exe> <shape> <jit> <ncaps> <tag> <probe> <seed>
cell() {
  if [ -e "out/$5.tsv" ]; then
    have=$(wc -l < "out/$5.tsv")
    if [ "$have" = "$4" ]; then say "$5: done already ($have lines), skipped"; return 0; fi
    say "$5: PARTIAL ($have of $4 lines) -- move out/$5.tsv and out/$5.err aside and relaunch"; exit 96
  fi
  say "$5: start ($1 $2 jit=$3 caps=$4 $6 seed=$7)"
  sh census.sh "$1" "$2" "$3" "$4" "$5" "$6" 0 $P "$7" || { say "$5: census.sh failed"; exit 95; }
  say "$5: rc!=0 $(awk -F'\t' '$2 != 0' "out/$5.tsv" | wc -l), NOLINE $(grep -c 'NOLINE' "out/$5.tsv")"
}
say "census-M1 start: lref_F $(md5sum < bin/lref_F.exe | cut -c1-8), lref_ref $(md5sum < bin/lref_ref.exe | cut -c1-8), SEEDCAPS=$SEEDCAPS"
# seed 1: the eight cells
cell lref_F.exe string 1 4096 F_string_j1       probe2.lua       1
cell lref_F.exe record 1 4096 F_record_j1       probe2.lua       1
cell lref_F.exe string 0 4096 F_string_j0       probe2.lua       1
cell lref_F.exe record 0 4096 F_record_j0       probe2.lua       1
cell lref_F.exe string 1 2048 F_oe_string_j1    probe2oe.lua     1
cell lref_F.exe record 1 2048 F_oe_record_j1    probe2oe.lua     1
cell lref_F.exe string 1 2048 F_k2048_string_j1 probe2k_2048.lua 1
cell lref_F.exe record 1 2048 F_k2048_record_j1 probe2k_2048.lua 1
# seeds 2 and 3: the final, and the baseline run here with the forensics' driver
for s in 2 3; do
  cell lref_F.exe   string 1 $SEEDCAPS F_oe_string_j1_s$s probe2oe.lua $s
  cell lref_ref.exe string 1 $SEEDCAPS B_oe_string_j1_s$s probe2oe.lua $s
  cell lref_F.exe   string 1 $SEEDCAPS F_string_j1_s$s    probe2.lua   $s
  cell lref_ref.exe string 1 $SEEDCAPS B_string_j1_s$s    probe2.lua   $s
  cell lref_F.exe   string 0 $SEEDCAPS F_string_j0_s$s    probe2.lua   $s
  cell lref_ref.exe string 0 $SEEDCAPS B_string_j0_s$s    probe2.lua   $s
done
say "determinism: B_oe_string_j1_s2/s3 (lref_ref.exe here) against lifetime's BASEs2/BASEs3 (the same binary there):"
sh ident.sh $LT/out/BASEs2_oe_string_j1.tsv out/B_oe_string_j1_s2.tsv
sh ident.sh $LT/out/BASEs3_oe_string_j1.tsv out/B_oe_string_j1_s3.tsv
say "determinism: F_string_j1 (4 096) against identity.sh's I_string_j1 / I_record_j1 (the same binary, 1 024):"
[ -e out/I_string_j1.tsv ] && sh ident.sh out/I_string_j1.tsv out/F_string_j1.tsv
[ -e out/I_record_j1.tsv ] && sh ident.sh out/I_record_j1.tsv out/F_record_j1.tsv
say "compare_F.py F -> out/compare-F.txt"
python tools/compare_F.py F > out/compare-F.txt 2>&1
tail -n 25 out/compare-F.txt
say "census-M1 done"
