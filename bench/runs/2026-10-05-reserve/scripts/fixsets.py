import re
p = "C:/Users/astro/Downloads/OC-LuaJIT/test/native/negative-control.sh"
s = open(p, encoding="utf-8", newline="").read()
got = {
 "stopgap": "M3 M3b M3c M4 M4c M5 M6b M7 M9 P1a P2a P2b P2c P2e P2f P2g P2h C0b C0d C3a C4b C5a C5b C6 C6b W1 W1L W1j W2b W2d W3 W4 W5a W5b W5c W7 W7k W7m W8 W10 W11 W11w W11wL W12 W13 W14 W15 W16 W16L W16R W16RL W16Rj W16RjL W17 W19 W20 W20L W21 W22",
 "nocredit": "W1 W10 W11 W16 W16L W16R W16RL W16Rj W16RjL W17 W18 W19 W1L W1j W20 W20L W21 W22 W2d W3 W7k W7m W8",
 "unbounded": "C3a C6b M5 W1 W11 W12 W16R W16RL W16Rj W16RjL W17 W1L W1j W20 W20L W22 W2b W7 W7k W7m",
 "nokslice": "W10 W16 W16L W16R W16RL W16Rj W16RjL W19 W20 W20L W7k W7m W8",
 "closereserve": "W11 W16Rj W16RjL W19 W20 W20L W21 W7k W7m W8",
 "noceiling": "W11 W11w W11wL W18 W19 W22 W7",
 "slicewindow": "W11w W11wL W19 W22 W7",
 "rawverdict": "W16 W16L W16R W16RL W16Rj W16RjL W20 W20L",
 "kernelwindow": "C6b W7k W7m",
 "noarm": "W16Rj W16RjL W17",
 "noverdict": "W17 W20 W20L",
 "nogrownreset": "W17 W20 W20L",
}
def wrap(ids):
    toks = ids.split()
    if len(toks) <= 24:
        return " " + " ".join(toks)
    out, line = [], []
    for t in toks:
        line.append(t)
        if len(" ".join(line)) > 80:
            out.append(" ".join(line)); line = []
    if line: out.append(" ".join(line))
    return " \\\n  " + " \\\n  ".join(out)
n = 0
for name, ids in got.items():
    m = re.search(r'^(expect_mem %s "[^"]*" 1)((?:(?: \\\n)?(?: +[A-Za-z0-9]+)+)+)[ \t]*$' % re.escape(name), s, re.M)
    assert m, name
    s = s.replace(m.group(0), m.group(1) + wrap(ids), 1)
    n += 1
hdr = "# --- 4.25-4.30: THE RESERVE'S SIZE (2026-10-05).  The reserve a refusal\n"
assert s.count(hdr) == 1
s = s.replace(hdr, "# The expected sets of 4.1-4.24 were re-measured on the final source when THE\n"
                   "# RESERVE'S SIZE landed (2026-10-05; bench/runs/2026-10-05-reserve/): W20,\n"
                   "# W20L, W21, W22 and W7m join the sets where the credit, its bound or the\n"
                   "# reserve is involved, and noarm now also stalls W16Rj/W16RjL -- the reserve\n"
                   "# top is closer, so a window whose cycle nothing arms is met with the JIT on.\n" + hdr, 1)
open(p, "w", encoding="utf-8", newline="").write(s)
print("updated", n, "sets; CRs:", s.count("\r"))
