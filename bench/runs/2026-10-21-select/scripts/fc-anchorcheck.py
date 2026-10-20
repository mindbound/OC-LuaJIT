#!/usr/bin/env python3
# anchorcheck.py <md>: every "](#anchor)" link must name a heading's GitHub
# slug (lowercase; keep letters, digits, spaces, "-" and "_"; spaces to "-").
import re
import sys

text = open(sys.argv[1], "rb").read().decode("utf-8")
slugs = set()
for l in text.split(chr(10)):
    m = re.match(r"^#{1,6} (.*)$", l)
    if m:
        h = m.group(1).strip().lower()
        h = "".join(c for c in h if c.isalnum() or c in " -_")
        slugs.add(h.replace(" ", "-"))
links = re.findall(r"\]\(#([^)]+)\)", text)
bad = sorted(set(a for a in links if a not in slugs))
for a in bad:
    print("missing anchor:", a)
print("links=%d distinct=%d bad=%d" % (len(links), len(set(links)), len(bad)))
sys.exit(1 if bad else 0)
