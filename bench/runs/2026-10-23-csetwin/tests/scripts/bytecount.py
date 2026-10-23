# bytecount.py <file>... -- per file: bytes, CR, TAB and backslash counts,
# lines, and the lines that hold a backslash (numbered).  Read only.
import sys
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    lines = b.split(b"\n")
    bs = [i + 1 for i, l in enumerate(lines) if 92 in l]
    print("%s bytes=%d cr=%d tab=%d backslash=%d lines=%d bslines=%d" %
          (p, len(b), b.count(13), b.count(9), b.count(92), b.count(10), len(bs)))
    if len(sys.argv) > 2 and "-v" in sys.argv[1:2]:
        pass
