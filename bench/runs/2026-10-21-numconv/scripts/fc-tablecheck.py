#!/usr/bin/env python3
# tablecheck.py <md>: for every Markdown table (consecutive lines starting
# with "|"), check each row has the header's cell count, counting "|" not
# preceded by a backslash and not inside a code span.  Prints mismatches.
import sys

BS = chr(92)
lines = open(sys.argv[1], "rb").read().decode("utf-8").split(chr(10))


def cells(l):
    n, code, prev = 0, False, ""
    for ch in l:
        if ch == "`":
            code = not code
        elif ch == "|" and prev != BS and not code:
            n += 1
        prev = ch
    return n


bad = 0
i = 0
tables = 0
while i < len(lines):
    if lines[i].startswith("|"):
        j = i
        while j < len(lines) and lines[j].startswith("|"):
            j += 1
        tables += 1
        want = cells(lines[i])
        for k in range(i, j):
            c = cells(lines[k])
            if c != want:
                bad += 1
                print("line %d: %d bars, header %d" % (k + 1, c, want))
        i = j
    else:
        i += 1
print("tables=%d bad=%d" % (tables, bad))
sys.exit(1 if bad else 0)
