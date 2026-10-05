#!/bin/sh
# ident.sh <A.tsv> <B.tsv>: join two censuses by offset and compare the
# driver's whole TSV data line (everything after "off<TAB>rc<TAB>").
# Prints: caps in both, both rc 0, identical, differing (first 3 shown).
awk -F'\t' '
  NR == FNR { rcA[$1] = $2; lnA[$1] = $0; sub(/^[^\t]*\t[^\t]*\t/, "", lnA[$1]); next }
  {
    off = $1; ln = $0; sub(/^[^\t]*\t[^\t]*\t/, "", ln)
    if (!(off in rcA)) { onlyB++; next }
    both++
    if (rcA[off] == 0 && $2 == 0) {
      ok++
      if (lnA[off] == ln) same++
      else { diff++; if (shown < 3) { print "  DIFF off " off; print "    A: " lnA[off]; print "    B: " ln; shown++ } }
    } else nz++
  }
  END { printf "caps_in_both=%d both_rc0=%d identical=%d differ=%d rc_nonzero=%d onlyB=%d\n", both, ok, same, diff, nz, onlyB }' "$1" "$2"
