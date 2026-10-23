"""ffsumm.py <raw.txt> <fresh outdir>: the fail-first of timing-summ.py.
Writes doctored copies of a one-round raw.txt and runs the summarizer on
each (python -I, rounds 1), with the verdict each must give:
  ok        the file itself                      SUMMARY: OK, exit 0
  differ    one new result changed (crc-table)   RESULTS: DIFFER, exit 1
  missing   new's ident lines dropped            SUMMARY: FAIL missing, exit 1
  malformed a line with a broken ident field     SUMMARY: FAIL malformed, exit 1
  gross     new's bench_bit ref read 3x slower   GROSS: FAIL, exit 0
Prints one row per case and 'ffsumm: N of 5 as wanted'.  No backslashes."""
import os
import subprocess
import sys

raw, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    sys.exit("REFUSING: " + out + " exists")
os.makedirs(out)
S = os.path.join(os.path.dirname(os.path.abspath(__file__)), "timing-summ.py")
NL = chr(10)
lines = open(raw, "rb").read().decode("utf-8").split(NL)
cases = {}
cases["ok"] = lines
cases["differ"] = [ln.replace("crc-table 3.600 ns/byte (r=1136067215)", "X").replace("(r=1136067215)", "(r=1136067216)") if (" vm=new " in ln and "bench=bench_bit2:" in ln) else ln for ln in lines]
cases["missing"] = [ln for ln in lines if not (" vm=new " in ln and "bench=ident:" in ln)]
cases["malformed"] = lines + ["round=1 pos=2 vm=new bench=ident: or0-big 25000000 0.9 ns/it"]
cases["gross"] = [ln.replace("ref 3.65 ns/it", "ref 10.95 ns/it") if (" vm=new " in ln and "bench=bench_bit:" in ln) else ln for ln in lines]
want = {"ok": ("SUMMARY: OK", 0), "differ": ("RESULTS: DIFFER", 1), "missing": ("SUMMARY: FAIL missing", 1),
        "malformed": ("malformed", 1), "gross": ("GROSS: FAIL", 0)}
ok = 0
for name, ls in cases.items():
    p = os.path.join(out, name + ".txt")
    open(p, "wb").write(NL.join(ls).encode("utf-8"))
    r = subprocess.run([sys.executable, "-I", S, p, "1"], capture_output=True, text=True)
    open(os.path.join(out, name + ".summary"), "w", newline="").write(r.stdout + r.stderr)
    text, code = want[name]
    good = (text in r.stdout) and r.returncode == code
    ok += good
    print("%-10s exit %d, %s: %s" % (name, r.returncode, "has '" + text + "'" if text in r.stdout else "LACKS '" + text + "'", "as wanted" if good else "WRONG"))
print("ffsumm: %d of %d as wanted" % (ok, len(cases)))
sys.exit(0 if ok == len(cases) else 1)
