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

patch(R + "README.md", [
("with Lua 5.3.6's whole format language and, apart from two decided deviations and what the VM decides, 5.3.6's results and errors, checked against PUC Lua 5.3.6 by a conformance suite and a differential fuzzer. The deviations: every number is still a double, so an unpacked integer that needs more than 53 bits comes back as the nearest double of the 64-bit integer 5.3.6 computes, never refused (Plan9k's GPT scan reads such fields from every drive); unsigned 8-byte formats (`I8`, `J`, `L`, `T`) wrap to a negative integer exactly as in 5.3.6 before that rounding, so eight `ff` bytes unpack as -1. And `l`/`L` are 8 bytes on every platform, so a format means the same bytes on every server (PUC uses the C `long`, 4 bytes on 64-bit Windows).",
 "with Lua 5.3.6's whole format language and 5.3.6's results and errors, checked against PUC Lua 5.3.6 by a conformance suite and a differential fuzzer, apart from two decided deviations, one choice of the port and what the VM decides. The deviations: every number is still a double, so an unpacked integer that needs more than 53 bits comes back as the nearest double of the 64-bit integer 5.3.6 computes (unsigned 8-byte formats, `I8`, `J`, `L` and `T`, wrap to negative first, as in 5.3.6: eight `ff` bytes are -1), and it is refused only where 5.3.6 refuses, a field wider than 8 bytes that does not fit in 64 bits (Plan9k's GPT scan reads such fields from every drive). And `l`/`L` are 8 bytes on every platform, so a format means the same bytes on every server (PUC uses the C `long`, 4 bytes on 64-bit Windows). The port's choice: a string given to a numeric option converts by 5.3.6's rules, but through LuaJIT's numeral scanner, so a numeral with 2^20 or more digits after the point (trailing zeros aside) or an exponent of 2^20 or more is refused where 5.3.6 reads it."),
("numbers given to `c`/`s`/`z`, which LuaJIT formats (`string.pack('z', 100000000000000)` gives `1e+14` here, `100000000000000` in 5.3.6); numerals with 2^20 or more digits after the point (trailing zeros aside) or an exponent of 2^20 or more, which pack refuses because its converter uses LuaJIT's numeral scanner; a result over the RAM cap, refused as `not enough memory`, after every argument check; and function names and method argument numbers in error messages, which are LuaJIT's for every library function. [test/native/pack/deviations.txt](test/native/pack/deviations.txt) lists the cases that show them, apart from the over-cap refusal, which `test/native/pack_test.c` checks.",
 "numbers given to `c`/`s`/`z`, which LuaJIT formats (`string.pack('z', 100000000000000)` gives `1e+14` here, `100000000000000` in 5.3.6); a result over the RAM cap, refused as `not enough memory`, after every argument check; and function names, positions and method argument numbers in error messages, which are LuaJIT's for every library function (through a tail call the name and the position are lost and a method's argument number shifts). [test/native/pack/deviations.txt](test/native/pack/deviations.txt) lists the cases that show them and the scanner's, apart from the over-cap refusal, which `test/native/pack_test.c` checks, and the function names, which the suites normalise away."),
])

patch(R + "docs/roadmap.md", [
("is the nearest double of 5.3.6's exact 64-bit value, never refused (Plan9k's GPT scan",
 "is the nearest double of 5.3.6's exact 64-bit value, refused only where 5.3.6 refuses (Plan9k's GPT scan"),
("pack's time is linear in the format, the output and the string arguments it converts, which it reads in both walks (the sandbox-constraints row; [research/wd-blind-spots.md](research/wd-blind-spots.md) 1g). What the VM decides stays LuaJIT's: NaN payloads are canonicalized; one call returns at most 8000 stack slots; numbers given to `c`/`s`/`z` are formatted by LuaJIT (`string.pack('z', 100000000000000)` gives `1e+14`, 5.3.6 `100000000000000`); pack's converter uses LuaJIT's numeral scanner after its own 5.3 refusals (decided D5), so",
 "pack's time is linear in the format, the output and the string arguments it converts, which it reads in both walks (the sandbox-constraints row; [research/wd-blind-spots.md](research/wd-blind-spots.md) 1g). One choice of the port: its converter uses LuaJIT's numeral scanner after its own 5.3 refusals (decided D5), so"),
(" or with an exponent of 2^20 or more (`:468`) is refused, where 5.3.6's `strtod` reads the first as its value and the second as inf or 0 (the `RESID-scan` lines of `test/native/pack/deviations.txt`); a result over the RAM cap",
 " or with an exponent of 2^20 or more (`:468`) is refused, where 5.3.6's `strtod` reads the first as its value and the second as inf or 0 (the `RESID-scan` lines of `test/native/pack/deviations.txt`). What the VM decides stays LuaJIT's: NaN payloads are canonicalized; one call returns at most 8000 stack slots; numbers given to `c`/`s`/`z` are formatted by LuaJIT (`string.pack('z', 100000000000000)` gives `1e+14`, 5.3.6 `100000000000000`); a result over the RAM cap"),
("and function names and method argument numbers in error messages are LuaJIT's, as for every library function (a function called straight from `pcall` is `?`, and a tail-called one loses its name and its method's argument shift).",
 "and function names, positions and method argument numbers in error messages are LuaJIT's, as for every library function (a function called straight from `pcall` is `?`, and a tail-called one loses its name and its position, and its method's argument number shifts)."),
("measured by round 2's consumer run (r2 `synth/consumers/final.out:40`, against the fallback path at `:57`).",
 "measured by round 2's consumer run (`bench/runs/2026-10-17-strpack/logs/consumers/final.out:40`, against the fallback path at `:57`; PUC 5.3.6 at `ref536-win64.out:40` and `ref536-lp64.out:40`)."),
("the cap's charge and refusal, the C-stack limit), `test/native/run-packfuzz.sh`",
 "the cap's charge and refusal, the argument checks before that refusal, D4's text at `LJ_MAX_STR`, the C-stack limit), `test/native/run-packfuzz.sh`"),
])

patch(R + "docs/research/wd-blind-spots.md", [
("### 1c. `string.format` \u2014 memory/bitfield-bounded\n",
 "### 1c. `string.format` \u2014 memory/bitfield-bounded; time grows with numeric string arguments\n"),
("It is the VM-wide class of 1c (the same 7999 integer arguments cost `string.format('%d')` 1.7-2.1 s), read twice.",
 "It is the VM-wide class of 1c (the same 7999 integer arguments cost `string.format('%d')` 1.7-2.1 s). Pack's two walks explain only half of the gap to PUC's 0.16 s at 1000 arguments; the rest is in the scans themselves (not profiled)."),
])
