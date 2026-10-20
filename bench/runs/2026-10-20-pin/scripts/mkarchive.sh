#!/bin/sh
# mkarchive.sh <archive dir> -- fills bench/runs/2026-10-20-pin/ from scratch: the main session's
# final-check2 run (text only: summaries, logs, rc files, md5 lists and diffs; never a binary or a
# build tree), the fail-first run on 7c3c2683 (its summary and the dist/clone evidence lists), the
# chain scripts, the five rounds' reports and the claims table.  Refuses an archive dir that exists.
set -u
A=$1
P=/c/Users/astro/claude-tmp/oclj
[ -e "$A" ] && { echo "REFUSING: $A exists"; exit 99; }
mkdir -p "$A/logs" "$A/scripts" "$A/design" || exit 98
# textcopy <src dir> <dst dir>: the text files of <src>, skipping the build trees b/, t/, alma/b-*,
# alma/t and any binary by extension.
textcopy() {
  ( cd "$1" && find . -type f \
      -not -path './b/*' -not -path './t/*' -not -path './alma/b-*' -not -path './alma/t/*' \
      -not -path './gradle/*/natives/*' \
      \( -name '*.txt' -o -name '*.log' -o -name '*.md5' -o -name '*.rc' -o -name '*.diff' -o -name '*.done' -o -name '*.err' -o -name 'ALL.done' \) \
      -print ) | while IFS= read -r f; do
    mkdir -p "$2/$(dirname "$f")" && cp "$1/$f" "$2/$f"
  done
}
textcopy "$P/pin5/final/run-main" "$A/logs/final-main"
textcopy "$P/pin5/ff-7c3c" "$A/logs/fail-first-7c3c2683"
cp "$P/pin5/final/final-check2.sh" "$P/pin4/final/final-check.sh" "$P/pin5/scripts/extra.sh" \
   "$P/pin5/scripts/fn-test5.sh" "$P/pin5/scripts/remap5.py" "$P/pin5/archive/mkreports.py" \
   "$P/pin5/archive/mkarchive.sh" "$A/scripts/" || exit 97
cp "$P/pin5/archive/reports-r1-r4.json" "$P/pin5/archive/round5-report.md" "$A/design/" || exit 96
cp "$P/pin5/claims.md" "$A/design/claims.md" || exit 95
find "$A" -type f | sed "s|^$A/||" | LC_ALL=C sort > "$A/MANIFEST.txt"
du -sh "$A"
find "$A" -type f | wc -l
