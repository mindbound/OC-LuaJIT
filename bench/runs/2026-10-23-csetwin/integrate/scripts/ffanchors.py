"""ffanchors.py <negctl-bitop.sh> <fresh outdir>: four mutated copies of
negctl-bitop.sh whose CSEFWD arm the anchor counter (anchors.sh) must
refuse: m1 the anchor altered (== to !=), m2 the anchor set to a line that
occurs many times ('  }'), m3 the marker dropped (SABOTAGE CSEFWX:), m4 a
two-line new text.  Each mutation must change exactly one place.  Writes
bytes (LF kept).  No backslashes in this file: chr(92) and chr(10)."""
import os
import sys

src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    sys.exit("REFUSING: " + out + " exists")
os.makedirs(out)
t = open(src, "rb").read().decode("utf-8")
BS = chr(92)
NL = chr(10)
anchor = "  '@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))' " + BS + NL
assert t.count(anchor) == 1, "anchor line count"
muts = {
    "m1-altered": (anchor, anchor.replace("==", "!=")),
    "m2-common": (anchor, "  '  }' " + BS + NL),
    "m3-nomarker": ("SABOTAGE CSEFWD:", "SABOTAGE CSEFWX:"),
    "m4-twoline": ("the reverse stays refused */'", "the reverse stays refused */" + NL + "/* a second line */'"),
}
for name, (old, new) in muts.items():
    assert t.count(old) == 1, name + ": old text count " + str(t.count(old))
    m = t.replace(old, new)
    with open(os.path.join(out, name + ".sh"), "wb") as f:
        f.write(m.encode("utf-8"))
    print(name, "written")
