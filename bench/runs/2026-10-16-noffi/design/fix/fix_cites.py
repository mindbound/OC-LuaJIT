import sys

def patch(path, pairs):
    s = open(path, "r", encoding="utf-8", newline="").read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit("%s: anchor found %d times: %r" % (path, n, old[:90]))
        s = s.replace(old, new)
    if "\r" in s:
        sys.exit("%s: CR present" % path)
    open(path, "w", encoding="utf-8", newline="").write(s)
    print("patched", path, len(pairs))

R = "C:/Users/astro/Downloads/OC-LuaJIT/"
patch(R + "docs/roadmap.md", [
("must also set `BCDUMP_VERSION` to 0x80 or above, as `lj_bcdump.h:36-37` asks, and add a token to the word.",
 "must also set `BCDUMP_VERSION` to 0x80 or above, as `lj_bcdump.h:36-37` asks, and add a token to the word. The `eris_lj.c` cites above moved with the word: `:101` is now `:165`, `:2857-2861` is `:2931-2935`, `:3171-3176` is `:3297-3302`."),
("`string.buffer` and `newproxy` remain closed by construction and untested.",
 "`string.buffer` and `newproxy` remain closed by construction and untested. The `eris_lj.c:1697` above is now `:1771`."),
("and PREREQUISITES 4 no longer claims a CHECKHOOK patch.",
 "and PREREQUISITES 4 no longer claims a CHECKHOOK patch, nor that the preflight rejects a stock clone (it rejects only a tree without `LUAJIT_ENABLE_CHECKHOOK`; the patch scripts' anchors refuse a tree that changed shape). The `eris_lj.c:101` above is now `:165`, and `LJ_FLAGS` is `build-native.sh:264`."),
("the `eris_lj.c` line cites above moved with the word's insertion.",
 "the `eris_lj.c` line cites above moved with the word's insertion (`:3165-3183` is now `:3291-3309`, `:2276-2281` is `:2350-2355`)."),
])
