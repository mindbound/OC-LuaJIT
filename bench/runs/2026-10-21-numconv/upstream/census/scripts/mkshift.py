import sys
# mkshift.py <in> <out> <line>: <out> is <in> with one extra line (a copy of
# a placeholder row) inserted before line <line>, for rowmap.py's fail-first.
# Binary in, binary out; no backslashes.
NL = chr(10).encode()
src = open(sys.argv[1], "rb").read().split(NL)
k = int(sys.argv[3]) - 1
src.insert(k, b"- [ ] **placeholder row for the fail-first**")
open(sys.argv[2], "wb").write(NL.join(src))
