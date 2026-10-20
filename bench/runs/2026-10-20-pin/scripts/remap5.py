#!/usr/bin/env python3
# remap5.py <old bn> <new bn> <jit-guide.md> [--write]
#
# Moves docs/jit-guide.md's line cites of build-native.sh from round 4's text (7c3c2683) to
# round 5's.  The inventory is round 4's (pin4/impl/scripts/cite-check4.py's WANT list: a
# distinctive text on the guide line, the cite token; build-native.sh's only).  negctl-bitop.sh
# did not change (bb16f824), so its cites stay.  The line map comes from difflib over the two
# texts (equal blocks only).  A cite whose ends both map is rewritten; one whose end falls in
# an edit is listed as HAND and given the value in the HAND table, derived by content in the
# new text.  Prints every move with the old and new first and last lines, so a reader can
# check them.  Without --write it only reports.  Writes with newline="".  Run with python -I.
import difflib, re, sys
NL = chr(10)
def rd(p):
    return open(p, encoding="utf-8", newline="").read().split(NL)
old, new, gpath = rd(sys.argv[1]), rd(sys.argv[2]), sys.argv[3]
write = "--write" in sys.argv[4:]
guide = rd(gpath)
m = {}
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
    if tag == "equal":
        for k in range(i2 - i1):
            m[i1 + k + 1] = j1 + k + 1
WANT = [
    ("the `-dM` gate (build-native.sh", "~:1501"),
    ("re-copy and re-patch the .dasc **before** `make clean`", ":1336-1375"),
    ("The build copy is remade on every run", ":957-1111"),
    ("`LJ_FLAGS=", ":429-432"),
    ("passes `Q=` so its log gates", ":1375"),
    ("**Preflight: the pin**", ":208-271"),
    ("**Preflight: the pin**", ":466-513"),
    ("**Preflight: the pin**", ":514-639"),
    ("**Preflight: the pin**", ":784-841"),
    ("**Preflight: the pin**", ":842-937"),
    ("- **The build environment** (THE BUILD ENVIRONMENT", ":208-271"),
    ("- **The directories this script removes", ":514-639"),
    ("**Stage 1: the copy and the twelve changes**", ":947-1377"),
    ("**The build copy is made afresh on every run**", ":957-1111"),
    ("**The CHECKHOOK option**", ":1112-1121"),
    ("collector-state enum is checked on the build copy", ":1122-1141"),
    ("Stage 1 refuses any architecture but x86_64", ":1333-1335"),
    ("Then `make -C $LJ clean`", ":1372-1377"),
    ("EXTERNAL INPUTS and USAGE", "~:112-177"),
    ("**Freshness gates**", ":1380-1478"),
    ("because `[ a -nt b ]` is true when b is missing", ":1443"),
    ("**Feature-channel gates**", ":1480-1516"),
    ("`OCLJ_LIB_STRPACK 1` and `OCLJ_OPS_BIT64 1` (", "~:1501"),
    ("**luajit.exe gates**", ":1593-1975"),
    ("**Stage 1b**", ":1977-2073"),
    ("COLLECT ADDITIVE ARTIFACTS", ":2547-2573"),
    ("LINK_EXTRA=", ":406"),
    ("LINK_EXTRA=", ":367-390"),
    ("# END ELF IMPORT GATE", ":2438-2539"),
    ("`GLIBC_FLOOR=2.28`", ":454"),
    ("**The commit in the blob fingerprint**", ":842-937"),
    ("**The commit in the blob fingerprint**", ":784-841"),
    ("`BITOP_PATCHES` and its loop", "~:1338-1364"),
    ("**P15.", "~:1443"),
    ("**P43.", ":1336-1375"),
    ("**P44.", ":957-1111"),
    ("its include assertions and its freshness map", "~:1337-1370"),
    ("its include assertions and its freshness map", "~:1434-1439"),
    ("goes into `BITOP_PATCHES` (build-native.sh", "~:1338"),
]
# HAND: old token -> new range, by content in the new text (each printed below).
HAND = {
    ":514-639": (620, 729),   # "# THE DIRECTORIES THIS SCRIPT REMOVES" .. the OCLJ_OUT loop's done
}
pat = re.compile("(~?:)([0-9]+)(?:-([0-9]+))?")
bad = 0
out = list(guide)
for text, tok in WANT:
    lines = [i for i, l in enumerate(out, 1) if text in l and tok in l]
    if len(lines) != 1:
        print("SKIP (%d lines carry the old token): %r %r" % (len(lines), text, tok))
        bad += 1
        continue
    ln = lines[0]
    if out[ln - 1].count(tok) != 1:
        print("LINE %d: %r occurs %d times" % (ln, tok, out[ln - 1].count(tok))); bad += 1; continue
    mt = pat.search(tok)
    a = int(mt.group(2)); b = int(mt.group(3)) if mt.group(3) else a
    if tok in HAND:
        na, nb = HAND[tok]; how = "HAND"
    elif a in m and b in m:
        na, nb = m[a], m[b]; how = "map"
    else:
        print("UNMAPPED %d %r (old %d-%d: %s)" % (ln, tok, a, b, "first unmapped" if a not in m else "last unmapped")); bad += 1; continue
    ntok = tok[: mt.start()] + mt.group(1) + str(na) + ("-" + str(nb) if mt.group(3) else "") + tok[mt.end():]
    print("guide %4d %-12s -> %-12s %s" % (ln, tok, ntok, how))
    print("     old first %5d: %s" % (a, old[a - 1].strip()[:72]))
    print("     new first %5d: %s" % (na, new[na - 1].strip()[:72]))
    if b != a:
        print("     old last  %5d: %s" % (b, old[b - 1].strip()[:72]))
        print("     new last  %5d: %s" % (nb, new[nb - 1].strip()[:72]))
    out[ln - 1] = out[ln - 1].replace(tok, ntok, 1)
print("bad: %d" % bad)
if write and bad == 0:
    open(gpath, "w", encoding="utf-8", newline="").write(NL.join(out))
    print("written")
