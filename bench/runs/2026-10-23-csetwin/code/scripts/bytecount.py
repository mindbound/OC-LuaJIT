import sys, hashlib
# bytecount.py <file>...: per file, its md5, size, CR, tab, backslash and NUL byte counts.
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    print("%s md5=%s size=%d cr=%d tab=%d bs=%d nul=%d lines=%d" % (
        p, hashlib.md5(b).hexdigest(), len(b), b.count(13), b.count(9),
        b.count(92), b.count(0), b.count(10)))
