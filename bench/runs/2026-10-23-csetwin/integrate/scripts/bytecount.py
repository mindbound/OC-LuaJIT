"""bytecount.py <file>...: per file, its size, CR, tab, NUL and backslash
byte counts, line count (LF), whether it ends in LF, and how many lines end
in a backslash (line continuations).  Read as bytes.  No backslashes in this
file (chr() is used instead)."""
import sys

BS = 92
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    lines = b.split(bytes([10]))
    cont = sum(1 for ln in lines if ln.endswith(bytes([BS])))
    print("%s size=%d cr=%d tab=%d nul=%d bs=%d lf=%d endlf=%s cont=%d" % (
        p, len(b), b.count(bytes([13])), b.count(bytes([9])), b.count(bytes([0])),
        b.count(bytes([BS])), b.count(bytes([10])), b.endswith(bytes([10])), cont))
