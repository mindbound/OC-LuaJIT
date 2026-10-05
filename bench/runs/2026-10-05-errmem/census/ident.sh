#!/bin/sh
# ident.sh <A.tsv> <B.tsv>: join two censuses by offset and compare the driver's whole TSV data line.
# Prints: caps in both, both rc 0, identical lines, differing lines, A-crash caps and B's outcome there.
A=$1; B=$2
awk -F'\t' '
  NR == FNR { rcA[$1] = $2; lnA[$1] = $0; sub(/^[^\t]*\t[^\t]*\t/, "", lnA[$1]); next }
  {
    off = $1; rcB = $2; ln = $0; sub(/^[^\t]*\t[^\t]*\t/, "", ln)
    if (!(off in rcA)) { onlyB++; next }
    both++
    if (rcA[off] == 0 && rcB == 0) {
      ok++
      if (lnA[off] == ln) same++
      else { diff++; if (shown < 3) { print "  DIFF off " off; print "    A: " lnA[off]; print "    B: " ln; shown++ } }
    } else if (rcA[off] != 0 && rcB == 0) {
      split(ln, f, "\t"); key = "status=" f[6] " term=" f[7] " events=" f[9]; acrash[key]++; nacrash++
    } else if (rcA[off] == 0 && rcB != 0) { bcrash++ }
    else { bothcrash++ }
  }
  END {
    printf "caps_in_both=%d  both_rc0=%d  identical=%d  differ=%d  A_crash_B_ok=%d  A_ok_B_crash=%d  both_crash=%d\n", both, ok, same, diff, nacrash, bcrash, bothcrash
    for (k in acrash) printf "  B outcome where A crashed: %s x%d\n", k, acrash[k]
  }' "$A" "$B"
