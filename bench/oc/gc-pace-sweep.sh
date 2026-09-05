#!/bin/sh
# bench/oc/gc-pace-sweep.sh -- how much margin does collector pacing buy, and
# where does it stop buying any?
#
#     sh bench/oc/gc-pace-sweep.sh              # phase A, the stepmul sweep
#     PACE_BENCH=sieve PACE_REPLICATES=2 sh bench/oc/gc-pace-sweep.sh
#
# THE QUESTION THIS DOES *NOT* ANSWER.  It cannot decide whether the emergency
# collector is needed, and must not be read as if it could.  Pacing changes the
# PROBABILITY of reaching the wall; only collect-and-retry changes what happens
# AT the wall.  For any pacing setting there is an allocation rate above it, and
# in OpenComputers the player picks the rate AND the wall -- ramScaleFor64Bit
# and the memory tiers are both mod settings.  So the output here is a MARGIN
# FIGURE and a BREAKING POINT, never a retirement of the roadmap item.  See
# docs/research/memory-accounting.md section 11, "Pacing is a mitigation, not a
# candidate".
#
# WHY stepmul IS THE ONLY KNOB SWEPT.  lj_gc_step takes a fixed budget
# lim = (GCSTEPSIZE/100)*stepmul (lj_gc.c:734) = 2000 at the defaults, while
# lj_gc.c:737-738 charges it everything allocated since the last step and :752
# repays only GCSTEPSIZE = 1024 bytes.  Work per byte allocated is therefore
# ~stepmul/100.  GCSTEPSIZE CANCELS out of that ratio -- it sets granularity,
# not rate.  And gc.pause is read at only two sites (lj_gc.c:742, :801), both
# setting the START threshold of the NEXT cycle, so under sustained churn --
# where the collector never reaches GCSpause -- it is inert.
#
# The pause arm is run anyway, at the value prior art used, to DEMONSTRATE that
# inertness rather than assert it.  A doc claim that no run has ever exercised
# is a doc claim waiting to be wrong.
#
# PREDICTION, RECORDED BEFORE THE RUN.  sieve allocates ~64 KB per repetition
# against a 52.4 KB live set and a 3072 real KB budget, and dies 6 of 6 at the
# default stepmul of 200.  If the rate model in section 8 is right, survival
# should appear at whatever stepmul first lifts the collector's throughput above
# the loop's allocation rate, and 6400 is 32x the default.  If NOTHING in this
# range survives, pacing is not even a mitigation for this shape of workload,
# which is a stronger result than a survivor would be.
#
# THE CONTROL IS BUILT IN.  The harness prints the PREVIOUS value returned by
# collectgarbage('setstepmul', n) and fails milestone gc-pace-stepmul-took
# unless it reads 200.  Without it, "pacing did not help" and "the knob never
# took" are the same row.  Any run whose milestone failed is reported and NOT
# tabulated.
#
# SERIAL, because these are timings and survival under a memory cap.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)

[ -f "$REPO/test/native/smoke-test.sh" ] || {
  echo "gc-pace-sweep.sh: $REPO is not the repo root; this script must stay in bench/oc/" >&2
  exit 1; }

: "${PACE_BENCH:=sieve}"
: "${PACE_BENCHES:=$PACE_BENCH}"   # PHASE B: several workload sizes at a fixed stepmul
: "${PACE_REPLICATES:=2}"
: "${PACE_STEPMULS:=200 400 800 1600 3200 6400}"
: "${PACE_PAUSES:=110}"
: "${PACE_CELLS:=B}"
: "${PACE_NAME:=gcpace}"
: "${MATRIX_OUT_BASE:=${TMPDIR:-/tmp}/ocljit-runs}"
: "${OCLJ_BRAIN:=C:/Users/astro/Downloads/ocelot-brain}"

STAMP=$(date +%Y-%m-%d-%H%M%S)
OUT="$MATRIX_OUT_BASE/$STAMP-$PACE_NAME"
if [ -e "$OUT/rows.tsv" ]; then
  echo "gc-pace-sweep.sh: $OUT already holds results -- refusing to overwrite." >&2
  exit 1
fi
mkdir -p "$OUT" || exit 1
: > "$OUT/rows.tsv"
: > "$OUT/progress.txt"

export OCLJ_LIBDIR="${OCLJ_LIBDIR:-$REPO/build/native/libdir}"
export OCLJ_BRAIN
export OCLJ_LIBS="${OCLJ_LIBS:-${TMPDIR:-/tmp}/ocljit-libs}"
export OCLJ_SUITE_WAIT="${OCLJ_SUITE_WAIT:-60}"
mkdir -p "$OCLJ_LIBS"

cellenv() {
  case $1 in
    A) echo "OCLJ_NATIVE=stock" ;;
    B) echo "OCLJ_NATIVE=luajit OCLJ_KERNEL=watchdog OCLJ_JIT=off" ;;
    C) echo "OCLJ_NATIVE=luajit OCLJ_KERNEL=watchdog OCLJ_JIT=on" ;;
  esac
}

run() {                      # run <cell> <stepmul> <pause> <rep> <bench>
  cell=$1; sm=$2; pz=$3; rep=$4; bench=$5
  tag="$cell-$bench-sm$sm-pz$pz-r$rep"
  wd="${TMPDIR:-/tmp}/ocljit-pace-$cell"
  mkdir -p "$wd"
  t0=$(date +%s)
  # shellcheck disable=SC2046
  env $(cellenv "$cell") OCLJ_REPS=1 OCLJ_BENCH_ONLY="$bench" \
      OCLJ_GCSTEPMUL="$sm" OCLJ_GCPAUSE="$pz" OCLJ_WORK="$wd" \
    sh "$REPO/test/native/smoke-test.sh" > "$OUT/$tag.log" 2>&1
  el=$(( $(date +%s) - t0 ))
  sl="$wd/smoke.log"
  if [ ! -f "$sl" ]; then
    printf '%-24s %3ss  NO LOG\n' "$tag" "$el" >> "$OUT/progress.txt"; return
  fi
  cp "$sl" "$OUT/$tag.smoke.log"

  # THE KNOB CONTROL.  A run whose injection did not take measures nothing, and
  # must never reach the table.
  took=ok
  if [ "$sm" -gt 0 ]; then
    grep -q 'MILESTONE gc-pace-stepmul-took: PASS' "$sl" || took=STEPMUL_NOT_APPLIED
  fi
  if [ "$pz" -gt 0 ] && [ "$took" = ok ]; then
    grep -q 'MILESTONE gc-pace-pause-took: PASS' "$sl" || took=PAUSE_NOT_APPLIED
  fi
  if [ "$took" != ok ]; then
    printf '%-24s %3ss  %s -- NOT TABULATED\n' "$tag" "$el" "$took" >> "$OUT/progress.txt"; return
  fi

  meter=$(sed -n 's/.*sandbox-bench(min-s\/iters\/reps)=\([0-9.]*\).*/\1/p' "$sl" | head -1)
  row=$(sed -n 's/.*PHASE1 ROW: .*jit=[a-z]*  //p' "$sl" | head -1)
  died=$(grep -c 'MACHINE STOPPED' "$sl" 2>/dev/null); [ -n "$died" ] || died=0
  status=$(printf '%s' "${row:-<no row>}" | cut -d/ -f2)
  case "$status" in ok) verdict=SURVIVED ;; *) verdict=DIED ;; esac
  [ "$died" -gt 0 ] && verdict=DIED

  # TWO BOUNDARIES, NOT ONE.  The validation run for this sweep found stepmul
  # 800 letting sieve COMPLETE (4626000, 233 KB free) and the machine then
  # dying on the post-restore encore -- section 8d's persistence-path failure,
  # in the same run.  Pacing moved the boundary; it did not remove it.  The
  # benchmark verdict alone would have read as a clean win and hidden the more
  # interesting half, so the encore is recorded separately.
  if grep -q 'MILESTONE f4-restore-no-error: PASS' "$sl"; then
    encore=ENCORE_OK
  elif grep -q 'MILESTONE f4-restore-no-error: FAIL' "$sl"; then
    encore=ENCORE_OOM
  else
    encore=ENCORE_ABSENT
  fi
  freekb=$(printf '%s' "${row:-/////}" | cut -d/ -f6)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cell" "$bench" "$sm" "$pz" "$rep" "${meter:--}" "$verdict" "$encore" "${freekb:--}" "${row:-<no row>}" >> "$OUT/rows.tsv"
  printf '%-32s %3ss meter=%-8s %-8s %-13s free=%-5s %s\n' \
    "$tag" "$el" "${meter:--}" "$verdict" "$encore" "${freekb:--}" "${row:-<no row>}" >> "$OUT/progress.txt"
}

{
  echo "gc-pace-sweep $STAMP"
  echo "  benches:    $PACE_BENCHES"
  echo "  cells:      $PACE_CELLS"
  echo "  stepmuls:   $PACE_STEPMULS   (200 = the VM default, i.e. the control arm)"
  echo "  pauses:     $PACE_PAUSES     (expected inert; run to demonstrate it)"
  echo "  replicates: $PACE_REPLICATES"
  echo ""
} >> "$OUT/progress.txt"

r=1
while [ "$r" -le "$PACE_REPLICATES" ]; do
  for c in $PACE_CELLS; do
    for b in $PACE_BENCHES; do
      for sm in $PACE_STEPMULS; do run "$c" "$sm" 0 "$r" "$b"; done
      for pz in $PACE_PAUSES; do run "$c" 0 "$pz" "$r" "$b"; done
    done
  done
  echo "--- replicate $r done $(date +%H:%M:%S) ---" >> "$OUT/progress.txt"
  r=$(( r + 1 ))
done

echo "SWEEP COMPLETE $(date +%H:%M:%S)" >> "$OUT/progress.txt"

ARCH="$REPO/bench/runs/$STAMP-$PACE_NAME"
if mkdir -p "$ARCH" 2>/dev/null; then
  cp "$OUT/rows.tsv" "$OUT/progress.txt" "$ARCH/" 2>/dev/null
  echo "archived to bench/runs/$STAMP-$PACE_NAME" >> "$OUT/progress.txt"
  echo "gc-pace-sweep.sh: full logs in $OUT"
  echo "gc-pace-sweep.sh: archived   bench/runs/$STAMP-$PACE_NAME"
else
  echo "gc-pace-sweep.sh: WARNING could not archive -- results exist ONLY at $OUT" >&2
fi
