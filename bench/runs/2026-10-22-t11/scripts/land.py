import subprocess, sys
# land.py: docs/in-game-tests.md = HEAD's blob (LF) + a blank line + the T11
# section; the working copy was CRLF from an old checkout (the index is LF).
repo = "C:/Users/astro/Downloads/OC-LuaJIT"
sec = open("C:/Users/astro/claude-tmp/oclj/t10/v2/t11-section.md", "rb").read()
head = subprocess.run(["git", "-C", repo, "show", "HEAD:docs/in-game-tests.md"],
                      capture_output=True, check=True).stdout
work = open(repo + "/docs/in-game-tests.md", "rb").read()
assert work.replace(b"\r\n", b"\n") == head, "working copy differs from HEAD beyond line ends"
assert b"\r" not in head and b"\r" not in sec and head.endswith(b"\n")
out = head + b"\n" + sec
with open(repo + "/docs/in-game-tests.md", "wb") as fh:
    fh.write(out)
print("lines", out.count(b"\n"), "CR", out.count(b"\r"))
