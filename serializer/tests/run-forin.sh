#!/bin/sh
# run-forin.sh — the cross-process half of the for-in replay suite.
#
# The bug this suite exists for is invisible inside one process: a table
# rebuilt in the saving VM lands its string keys on the same nodes, because
# the strings are already interned and carry their sids. So every case saves
# in one process and restores in a FRESH one, and each restore first interns
# ELJ_PAD throwaway strings to rotate the hash part by a known amount. That
# turns an intermittent failure (the keyindex design was correct in 4 runs
# out of 20) into a deterministic matrix: every pad must pass.
#
#   sh tests/run-forin.sh            # 15 cases x pads 0..19
#   PADS="$(seq 0 63)" sh tests/run-forin.sh   # the deep sweep
#
# Exit status is the number of failing cases.

set -u
BIN=${BIN:-./erislj_test.exe}
DIR=${DIR:-./.forin}
PADS=${PADS:-"0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19"}
CASES=${CASES:-"strings mixed array big falsevals nested sequential delcurrent nextlocal nextdel despec foreach jitwarm deep perms permsfn control_naive"}
# Cases that additionally go through a middle process which loads and re-saves,
# so the third process restores a loop that is ALREADY in replay form. Without
# this the suite round-trips once and cannot see a defect that only appears on
# the second save -- which is exactly how one got through.
RELAY=${RELAY:-"strings mixed big nextlocal despec foreach perms permsfn deep"}

mkdir -p "$DIR"
fails=0

for case in $CASES; do
  blob="$DIR/$case"
  if ! ELJ_MODE=save ELJ_CASE="$case" ELJ_BLOB="$blob" "$BIN" tests/forin.lua \
       > "$DIR/$case.save.log" 2>&1; then
    echo "FAIL $case: save failed"
    sed -n '5,12p' "$DIR/$case.save.log" | sed 's/^/     /'
    fails=$((fails + 1))
    continue
  fi
  bytes=$(sed -n 's/^SAVED .*bytes=\([0-9]*\) .*/\1/p' "$DIR/$case.save.log")

  relayed=""
  if echo " $RELAY " | grep -q " $case "; then
    if ! ELJ_MODE=relay ELJ_CASE="$case" ELJ_BLOB="$blob" ELJ_PAD=7 \
         "$BIN" tests/forin.lua > "$DIR/$case.relay.log" 2>&1; then
      echo "FAIL $case: the second save (relay) failed"
      sed -n '5,14p' "$DIR/$case.relay.log" | sed 's/^/     /'
      fails=$((fails + 1))
      continue
    fi
    bytes=$(sed -n 's/^RELAYED .*bytes=\([0-9]*\) .*/\1/p' "$DIR/$case.relay.log")
    relayed=" via relay"
  fi

  ok=0; bad=0; firstbad=""
  for pad in $PADS; do
    if ELJ_MODE=load ELJ_CASE="$case" ELJ_BLOB="$blob" ELJ_PAD="$pad" \
       "$BIN" tests/forin.lua > "$DIR/$case.$pad.log" 2>&1; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      [ -z "$firstbad" ] && firstbad=$(grep -E '^(FAIL|error)' "$DIR/$case.$pad.log" | head -1)
    fi
  done

  total=$((ok + bad))
  if [ "$case" = "control_naive" ]; then
    # NEGATIVE CONTROL: this case deliberately does NOT go through the replay
    # path -- it resumes `next` from a saved key, which is what the code did
    # before A'. If it passes every pad, the harness cannot see the defect it
    # was built to catch, and every green result above is meaningless.
    if [ "$bad" -gt 0 ]; then
      echo "OK   $case: $bad/$total pads diverge as they must (${bytes}B)"
    else
      echo "FAIL $case: the negative control passed $ok/$total pads --"
      echo "     the harness has no power to detect layout divergence"
      fails=$((fails + 1))
    fi
  elif [ "$bad" -eq 0 ]; then
    echo "OK   $case: $ok/$total pads exact (${bytes}B)$relayed"
  else
    echo "FAIL $case: $bad/$total pads wrong -- $firstbad"
    fails=$((fails + 1))
  fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo "FOR-IN RESULT: all cases exact across every pad"
else
  echo "FOR-IN RESULT: $fails case(s) FAILED"
fi
exit "$fails"
