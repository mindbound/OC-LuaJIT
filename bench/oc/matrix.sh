#!/bin/sh
# bench/oc/matrix.sh -- the in-machine benchmark matrix.
#
# Runs every benchmark in references.txt across the three cells, replicated,
# one benchmark per freshly booted machine, and writes a tabulated rows.tsv
# plus a human-readable progress.txt.
#
#     sh bench/oc/matrix.sh                  # the full matrix
#     sh bench/oc/matrix.sh sieve            # one benchmark, all three cells
#     MATRIX_REPLICATES=1 sh bench/oc/matrix.sh mandelbrot sha256
#
# THE CELLS.  A is ocelot-brain's bundled PUC Lua 5.2 -- what players run
# today.  B and C are our native with the watchdog kernel, differing ONLY in
# jit.off(), which makes B/C the clean compiler experiment: same binary, same
# kernel, same source, same machine.
#
# EVERYTHING BELOW IS A RESPONSE TO A WAY AN EARLIER VERSION PRODUCED A WRONG
# NUMBER.  They are commented because the wrong numbers were plausible.
#
# OUTPUT GOES TO A FRESH TIMESTAMPED DIRECTORY, ALWAYS.  The previous version
# used a fixed path, so starting a run began by clearing the last one -- and on
# 2026-09-04 that `rm -rf` destroyed the six logs behind a claim this repository
# had already committed ("sieve fails on our native 6 of 6").  The claim
# survived only because it could be re-measured.  There is now no path by which
# a run destroys an earlier one: the directory name carries a timestamp, and if
# it somehow already holds results this script REFUSES rather than overwriting.
#
# AND IT ARCHIVES ITSELF ON COMPLETION into bench/runs/, which is in the
# repository.  A run under /tmp outlives nothing; documents were citing paths
# that had already evaporated.  See bench/runs/README.md for what is kept and
# what is not.
#
# THE BENCHMARK LIST IS DERIVED FROM references.txt, not written here.  That
# file is the suite definition -- the Java harness builds its manifest from it
# -- and a second hardcoded list in this script is a drift source that has bitten
# before.  A `!` prefix there means QUARANTINED: observed to kill a machine, so
# it runs alone, after everything else, with reps=1, where losing the machine
# costs one row instead of the run.
#
# ONE WORK DIR PER CELL, not per run and not shared.  Shared caused
# misattribution: a run that dies early leaves the previous run's smoke.log in
# place and it gets filed under the wrong cell -- that is how a "C-sieve" row
# once came back reading kernel=stock.  Per-run meant an rm -rf and a scalac
# rebuild every time, which is disk-heavy on Windows and was itself a source of
# timing drift.  Per-cell gets both.
#
# ATTRIBUTION IS CHECKED ON TWO KEYS.  Each log must name the kernel we asked
# for AND the benchmark we asked for.  A row that cannot prove which cell and
# which benchmark produced it is reported MISATTRIBUTED and never tabulated.
#
# INTERLEAVED BY CELL, replicates spread across time.  The loop is
# replicate -> benchmark -> cell, so A, B and C for one benchmark land within
# ~2 minutes of each other.  Box speed on this machine drifts by up to 2x, and
# an early matrix quoted a mandelbrot A/C of 28x that was really 13.6x purely
# because two cells fell in a fast window.  Interleaving makes drift hit all
# three cells together, so ratios survive even when absolutes wander.
#
# THE BOX-SPEED METER IS RECORDED PER RUN.  Every boot runs a fixed
# 2M-iteration sandbox loop before any benchmark.  It is identical work in
# every run of a cell, so it calibrates that boot against its cell's median.
# No ratio should be quoted from a run whose meter is off -- and check the
# intra-run spread too (max/min of the reps inside one boot); nqueens cell C
# varies 2.05x within a single boot and its ratio is therefore not quotable.
#
# SERIAL, because these are timings.

set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)   # bench/oc/ -> repo root
REFS="$SELF_DIR/references.txt"

[ -f "$REFS" ] || { echo "matrix.sh: no references.txt at $REFS" >&2; exit 1; }
[ -f "$REPO/test/native/smoke-test.sh" ] || {
  echo "matrix.sh: $REPO does not look like the repo root (no test/native/smoke-test.sh)" >&2
  echo "matrix.sh: this script derives the root as its own dir/../.. and must stay in bench/oc/" >&2
  exit 1; }

: "${MATRIX_NAME:=matrix}"
: "${MATRIX_REPLICATES:=3}"
: "${MATRIX_REPS:=3}"
: "${MATRIX_OUT_BASE:=${TMPDIR:-/tmp}/ocljit-runs}"
: "${OCLJ_BRAIN:=C:/Users/astro/Downloads/ocelot-brain}"

STAMP=$(date +%Y-%m-%d-%H%M%S)
OUT="$MATRIX_OUT_BASE/$STAMP-$MATRIX_NAME"

# A fresh timestamped path cannot collide in practice.  If it somehow does,
# REFUSE -- never clear.  Losing a measurement is not recoverable the way
# losing a build is.
if [ -e "$OUT/rows.tsv" ] || [ -e "$OUT/progress.txt" ]; then
  echo "matrix.sh: $OUT already holds results -- refusing to overwrite." >&2
  echo "matrix.sh: move it aside if you really mean to reuse the path." >&2
  exit 1
fi
mkdir -p "$OUT" || exit 1
: > "$OUT/rows.tsv"
: > "$OUT/progress.txt"

export OCLJ_LIBDIR="${OCLJ_LIBDIR:-$REPO/build/native/libdir}"
export OCLJ_BRAIN
export OCLJ_LIBS="${OCLJ_LIBS:-${TMPDIR:-/tmp}/ocljit-libs}"
export OCLJ_SUITE_WAIT="${OCLJ_SUITE_WAIT:-60}"   # stall detector ends a dead run in ~10 s
mkdir -p "$OCLJ_LIBS"

# --- the suite, read from references.txt -------------------------------------
# Format there is  [!]<name>  <CHECK>  [<peakKB>].  Skip comments and blanks.
MAIN=$(sed -n 's/^\([A-Za-z0-9_][A-Za-z0-9_]*\)[[:space:]].*/\1/p' "$REFS" | tr '\n' ' ')
QUAR=$(sed -n 's/^![[:space:]]*\([A-Za-z0-9_][A-Za-z0-9_]*\)[[:space:]].*/\1/p' "$REFS" | tr '\n' ' ')

if [ $# -gt 0 ]; then           # explicit list: run exactly what was asked
  MAIN="$*"; QUAR=""
fi

[ -n "$(printf %s "$MAIN$QUAR" | tr -d ' ')" ] || {
  echo "matrix.sh: no benchmarks parsed from references.txt" >&2; exit 1; }

cellenv() {
  case $1 in
    A) echo "OCLJ_NATIVE=stock" ;;
    B) echo "OCLJ_NATIVE=luajit OCLJ_KERNEL=watchdog OCLJ_JIT=off" ;;
    C) echo "OCLJ_NATIVE=luajit OCLJ_KERNEL=watchdog OCLJ_JIT=on" ;;
  esac
}
wantkernel() { case $1 in A) echo stock ;; *) echo watchdog ;; esac; }

run() {                        # run <cell> <bench> <rep> <reps>
  cell=$1; bench=$2; rep=$3; reps=$4
  tag="$cell-$bench-r$rep"
  wd="${TMPDIR:-/tmp}/ocljit-mx-$cell"
  mkdir -p "$wd"
  t0=$(date +%s)
  # shellcheck disable=SC2046
  env $(cellenv "$cell") OCLJ_REPS="$reps" OCLJ_BENCH_ONLY="$bench" OCLJ_WORK="$wd" \
    sh "$REPO/test/native/smoke-test.sh" > "$OUT/$tag.log" 2>&1
  el=$(( $(date +%s) - t0 ))
  sl="$wd/smoke.log"
  if [ ! -f "$sl" ]; then
    printf '%-22s %3ss  NO LOG\n' "$tag" "$el" >> "$OUT/progress.txt"; return
  fi
  cp "$sl" "$OUT/$tag.smoke.log"
  gotk=$(sed -n 's/.*JIT PROBE: kernel=\([a-z]*\).*/\1/p' "$sl" | head -1)
  gotb=$(sed -n 's/.*OCLJ_BENCH_ONLY=\([A-Za-z0-9_]*\).*/\1/p' "$sl" | head -1)
  wk=$(wantkernel "$cell")
  if { [ -n "$gotk" ] && [ "$gotk" != "$wk" ]; } || { [ -n "$gotb" ] && [ "$gotb" != "$bench" ]; }; then
    printf '%-22s %3ss  MISATTRIBUTED kernel=%s want=%s bench=%s want=%s\n' \
      "$tag" "$el" "$gotk" "$wk" "$gotb" "$bench" >> "$OUT/progress.txt"; return
  fi
  meter=$(sed -n 's/.*sandbox-bench(min-s\/iters\/reps)=\([0-9.]*\).*/\1/p' "$sl" | head -1)
  row=$(sed -n 's/.*PHASE1 ROW: .*jit=[a-z]*  //p' "$sl" | head -1)
  died=$(grep -c 'MACHINE STOPPED' "$sl" 2>/dev/null); [ -n "$died" ] || died=0
  f=$(grep -c 'MILESTONE.*FAIL' "$sl" 2>/dev/null); [ -n "$f" ] || f=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cell" "$bench" "$rep" "${meter:--}" "$f" "$died" "${row:-<no row>}" >> "$OUT/rows.tsv"
  printf '%-22s %3ss meter=%-8s fails=%-2s %s\n' \
    "$tag" "$el" "${meter:--}" "$f" "${row:-<no row>}" >> "$OUT/progress.txt"
}

echo "matrix.sh: $STAMP-$MATRIX_NAME" >> "$OUT/progress.txt"
echo "  suite:       ${MAIN:-<none>}" >> "$OUT/progress.txt"
echo "  quarantined: ${QUAR:-<none>}" >> "$OUT/progress.txt"
echo "  replicates:  $MATRIX_REPLICATES x $MATRIX_REPS reps" >> "$OUT/progress.txt"
echo "" >> "$OUT/progress.txt"

r=1
while [ "$r" -le "$MATRIX_REPLICATES" ]; do
  for b in $MAIN; do
    for c in A B C; do run "$c" "$b" "$r" "$MATRIX_REPS"; done
  done
  echo "--- replicate $r done $(date +%H:%M:%S) ---" >> "$OUT/progress.txt"
  r=$(( r + 1 ))
done

# The quarantined pathologies, LAST and with reps=1.  Each is expected to kill
# a machine in at least one cell, and the persist/restore milestones run after
# the suite, so a death costs them.  Running these at the end means it costs
# only their own rows.
for b in $QUAR; do
  q=1
  while [ "$q" -le 2 ]; do
    for c in A B C; do run "$c" "$b" "$q" 1; done
    q=$(( q + 1 ))
  done
done

echo "MATRIX COMPLETE $(date +%H:%M:%S)" >> "$OUT/progress.txt"

# --- archive into the repository ---------------------------------------------
# rows.tsv and progress.txt always; the individual smoke logs are 12 KB each and
# a full matrix is ~1 MB, so they stay out unless a document quotes one -- in
# which case copy it in BY HAND, in the same change as the claim.  See
# bench/runs/README.md.
ARCH="$REPO/bench/runs/$STAMP-$MATRIX_NAME"
if mkdir -p "$ARCH" 2>/dev/null; then
  cp "$OUT/rows.tsv" "$OUT/progress.txt" "$ARCH/" 2>/dev/null
  echo "archived to bench/runs/$STAMP-$MATRIX_NAME" >> "$OUT/progress.txt"
  echo "matrix.sh: full logs in $OUT"
  echo "matrix.sh: archived   bench/runs/$STAMP-$MATRIX_NAME  (rows.tsv, progress.txt)"
  echo "matrix.sh: if a document quotes one run, commit that run's .smoke.log too"
else
  echo "matrix.sh: WARNING could not archive into $ARCH -- results exist ONLY at $OUT" >&2
fi
