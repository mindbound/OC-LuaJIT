sabotage() {
  OLD=$2 NEW=$3 awk '
    BEGIN {
      NL = sprintf("%c", 10); TAB = sprintf("%c", 9)
      no = split(ENVIRON["OLD"], O, NL); nn = split(ENVIRON["NEW"], N, NL)
      for (k = 1; k <= no; k++) gsub(/@T@/, TAB, O[k])
      for (k = 1; k <= nn; k++) gsub(/@T@/, TAB, N[k])
    }
    { L[++nl] = $0 }
    END {
      c = 0
      for (i = 1; i + no - 1 <= nl; i++) {
        for (j = 1; j <= no; j++) if (L[i + j - 1] != O[j]) break
        if (j > no) { c++; at = i }
      }
      if (no < 1 || c != 1) exit 1
      for (i = 1; i < at; i++) print L[i]
      for (k = 1; k <= nn; k++) print N[k]
      for (i = at + no; i <= nl; i++) print L[i]
    }' "$1" > "$4"
}
