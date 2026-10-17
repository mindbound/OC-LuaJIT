import sys
# Compare two eris-lj blobs' bodies (header and CRC stripped) and classify each differing byte.
def body(p):
    b = open(p, "rb").read()
    assert b[:3] == b"ELJ"
    fplen = b[4]
    return b[5 + fplen:-4]
a, r = body(sys.argv[1]), body(sys.argv[2])
print("lengths", len(a), len(r))
diffs = [i for i in range(min(len(a), len(r))) if a[i] != r[i]]
ver = [i for i in diffs if i >= 3 and a[i-3:i] == b"\x1bLJ" and r[i-3:i] == b"\x1bLJ"]
other = [i for i in diffs if i not in ver]
print("differing bytes", len(diffs), "; at a dump's version byte (after ESC L J):", len(ver),
      "values", sorted(set((a[i], r[i]) for i in ver)))
print("other differing offsets (1-based):", [i + 1 for i in other])
print("dump headers in fixture body:", r.count(b"\x1bLJ"))
