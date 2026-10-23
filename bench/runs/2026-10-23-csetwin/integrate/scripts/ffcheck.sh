#!/bin/sh
# ffcheck.sh <negctl-bitop.sh> <fresh outdir> -- the fail-first of negctl's
# cse catcher checks, on their own text: rcof() and check() are extracted
# from <negctl-bitop.sh> and run on known run-bitjit.sh logs and on
# synthetic ones, each case with the verdict it must give (0 caught, 1 not
# caught, 2 proved nothing).  Prints one row per case and "ffcheck: N of M
# as wanted"; exit 0 iff all are.  No backslashes.
set -u
NC=${1:?usage: ffcheck.sh <negctl-bitop.sh> <fresh outdir>}
O=${2:?usage: ffcheck.sh <negctl-bitop.sh> <fresh outdir>}
I=/c/Users/astro/claude-tmp/oclj/csetwin/round/integrate
[ -e "$O" ] && { echo "REFUSING: $O exists"; exit 99; }
mkdir -p "$O" || exit 98
awk '$0 == "rcof() {" { on = 1 } on { print } on && $0 == "}" { on = 0 }
  $0 == "check() {" { on2 = 1 } on2 { print } on2 && $0 == "}" { on2 = 0 }' "$NC" > "$O/funcs.sh"
[ "$(grep -c -E '^(rcof|check)[(][)] [{]$' "$O/funcs.sh")" = 2 ] || { echo "cannot extract rcof() and check()"; exit 98; }
. "$O/funcs.sh"
# The logs: CSEFWD's negctl run (caught), the fixed build's cse part (PASS),
# build/native's cse part from impl-tests (FAIL), and synthetic ones.
W=$I/b1/negctl-bitop/20261023T113715Z-1926
mk() { mkdir -p "$O/$1"; cp "$2" "$O/$1/bitjit.log"; }
mk sab "$W/CSEFWD/bitjit.log"
mk fix "$I/runs/cse-b1-1.log"
mk base /c/Users/astro/claude-tmp/oclj/csetwin/round/impl-tests/runs/cse-base-2.log
mkdir -p "$O/onlyrev" "$O/onlyir" "$O/joffonly"
printf '%s\n' 'FAIL t_cserev (8 cases): jon=4 O0=0' 'PASS t_csefwd (28 cases): jon=0' 'PASS cseir (28 cases): jon=0' > "$O/onlyrev/bitjit.log"
printf '%s\n' 'PASS t_csefwd (28 cases): jon=0' 'FAIL cseir (28 cases): jon=18' > "$O/onlyir/bitjit.log"
printf '%s\n' 'FAIL t_csefwd: -joff exited 1 with 28 lines, 1 of them with a result unlike the file' 'FAIL cseir: -joff exited 1 with 0 results' > "$O/joffonly/bitjit.log"
n=0; ok=0
case_() {  # case_ <dir> <R_bitjit> <catcher> <wanted>
  R_bitjit=$2
  check "$O/$1" "$3"; got=$?
  n=$((n + 1))
  if [ "$got" = "$4" ]; then ok=$((ok + 1)); v=ok; else v=WRONG; fi
  printf '%-9s R_bitjit=%s %-13s got %s want %s %s\n' "$1" "$2" "$3" "$got" "$4" "$v"
}
case_ sab 1 cse:t_csefwd 0
case_ sab 1 cse:cseir 0
case_ base 1 cse:t_csefwd 0
case_ base 1 cse:cseir 0
case_ fix 0 cse:t_csefwd 1
case_ fix 0 cse:cseir 1
case_ sab 0 cse:t_csefwd 1
case_ sab 2 cse:cseir 2
case_ onlyrev 1 cse:t_csefwd 1
case_ onlyrev 1 cse:cseir 1
case_ onlyir 1 cse:t_csefwd 1
case_ onlyir 1 cse:cseir 0
case_ joffonly 1 cse:t_csefwd 1
case_ joffonly 1 cse:cseir 1
case_ sab 1 nc:t_numconv 1
case_ sab 1 nc:ncir 1
echo "ffcheck: $ok of $n as wanted"
[ "$ok" = "$n" ]
