import sys
# mdmut.py <in.md> <out.md>: a copy of the guide with one broken in-page
# link and one CR, for mdcheck.py's fail-first.  No backslashes.
b = open(sys.argv[1], "rb").read()
b = b.replace(b"([8.2a](#82a-bumping-the-pin); roadmap row 270)", b"([8.2a](#82a-bumping-the-pinx); roadmap row 270)", 1)
b = b.replace(chr(10).encode(), (chr(13) + chr(10)).encode(), 1)
open(sys.argv[2], "wb").write(b)
