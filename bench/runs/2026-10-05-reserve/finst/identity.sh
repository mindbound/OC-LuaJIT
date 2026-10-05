#!/bin/sh
# identity.sh -- INERTNESS 2 (the forensics' 2.3 method) on the final source: the plain
# driver (bin/orig_plain.exe = lj_repro.c + the plain additive object, log off) against the
# instrumented driver (bin/lref_F.exe = lj_ref.c + the instrumented object + the cpcall wrap,
# OCLJ_REFLOG=1) on 1 024 caps of string JIT on and 1 024 of record JIT on (seed 1, the census
# probe probe2.lua, batch 10, junk 24, pinned): every driver line identical.  Also:
#   - bin/lref_E.exe (THE WINDOW's instrumented shim relinked against the CURRENT libluajit.a)
#     on 1 024 caps of string JIT on against the forensics' L4_string_j1 (their lref_ref.exe,
#     linked against a93f546e): does the lib change alone move any line?
#   - lref_F against the forensics' L4 baselines (a preview of M1: differences are expected on
#     second-chance caps only).
set -u
WD=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/finst
FO=/c/Users/astro/AppData/Local/Temp/claude/C--Users-astro-Downloads-OC-LuaJIT/b3c2bf14-9324-494a-a9cb-2700e7c43afc/scratchpad/wall2/sc/forensics
cd $WD || exit 99
say() { echo "== $(date -u '+%H:%M:%S') $*"; }
say "identity start"
unset OCLJ_REFLOG
sh census.sh orig_plain.exe string 1 1024 P_string_j1 probe2.lua 0 12 1
sh census.sh orig_plain.exe record 1 1024 P_record_j1 probe2.lua 0 12 1
export OCLJ_REFLOG=1
sh census.sh lref_F.exe string 1 1024 I_string_j1 probe2.lua 0 12 1
sh census.sh lref_F.exe record 1 1024 I_record_j1 probe2.lua 0 12 1
sh census.sh lref_E.exe string 1 1024 E_string_j1 probe2.lua 0 12 1
say "IDENTITY plain vs instrumented, string j1:"; sh ident.sh out/P_string_j1.tsv out/I_string_j1.tsv
say "IDENTITY plain vs instrumented, record j1:"; sh ident.sh out/P_record_j1.tsv out/I_record_j1.tsv
say "lib confound: forensics L4_string_j1 (shipped shim, lib a93f546e) vs lref_E (shipped shim, current lib):"; sh ident.sh $FO/out/L4_string_j1.tsv out/E_string_j1.tsv
say "preview: forensics L4_string_j1 vs lref_F:"; sh ident.sh $FO/out/L4_string_j1.tsv out/I_string_j1.tsv
say "preview: forensics L4_record_j1 vs lref_F:"; sh ident.sh $FO/out/L4_record_j1.tsv out/I_record_j1.tsv
say "fingerprints in I_string_j1: OCLJREFINIT in $(grep -l 'OCLJREFINIT|' out/I_string_j1.err/*.err | wc -l) of 1024 err files; OCLJXP lines $(cat out/I_string_j1.err/*.err | grep -c 'OCLJXP|'); OCLJREF lines $(cat out/I_string_j1.err/*.err | grep -c 'OCLJREF|'); AFFRUN applied=1 in $(grep -l 'applied=1' out/I_string_j1.err/*.err | wc -l)"
say "identity done"
