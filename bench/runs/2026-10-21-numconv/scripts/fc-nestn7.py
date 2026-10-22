# nestn7.py <patch script in> <fresh patch script out> -- numconv/fix: a
# scratch copy of patch-bitop-fold.sh whose n7 puts FIX-NUMCONV's call
# directly under the width rule's unbraced if (the code verifier's m11, as an
# edit of the script's own hunk text).  The line count is unchanged, so NADD
# still holds.  LF kept; no backslashes in this file.
import os, sys

src, dst = sys.argv[1], sys.argv[2]
if os.path.exists(dst):
    sys.exit("REFUSING: %s exists" % dst)
NL = chr(10)
with open(src, "r", newline="") as f:
    L = f.read().split(NL)
CALL = "    if (oclj_isnumconv(J, fleft->op1))"
WIDTH = "    if (oclj_bitwidth(J, fleft->op1, 0) <= 54)"
assert L.count(CALL) == 1, L.count(CALL)
assert L.count(WIDTH) == 1, L.count(WIDTH)
L.remove(CALL)
i = L.index(WIDTH)
L.insert(i + 1, CALL)
with open(dst, "w", newline="") as f:
    f.write(NL.join(L))
print("wrote " + dst)
