# analyze.py <tag> [<tag> ...]
# Classify every run of a census made with lref_*.exe and OCLJ_REFLOG set:
# out/<tag>.tsv (the driver's line per cap) + out/<tag>.err/<off>.err (the
# ordered stderr stream: OCLJREF| from the shim, OCLJCP| from wrapcp.c,
# OCLJEV| from the driver).
#
# THE ABSORBER of a refusal is the first thing in the stream after it that
# caught an error:
#   OCLJCP| st=4 recorder=1   the JIT recorder's protected call (trace_abort drops it)
#   OCLJEV| code=1            the batch's pcall: the PROGRAM's handler
#   OCLJEV| code=3            the probe's pcall(paint)
#   OCLJEV| code=2            the dispatcher's pcall(h.callback): outside, the stall
#   OCLJEV| code=7            the heartbeat's pcall
#   OCLJEV| code=4            the kernel's coroutine.resume: the sandbox down
#   OCLJEV| code=5            the driver's lua_pcall: the kernel down
# A refusal followed by another refusal with none of these between is
# "unseen" (nothing observed caught it); OCLJCP st=4 recorder=0 (another
# protected call, e.g. a trace exit, which rethrows) is noted, not taken.
# Nested recorder cpcalls rethrow to the outer one, so the 2nd..nth OCLJCP
# recorder=1 lines of one refusal are ignored.  st=2 (LUA_ERRRUN) cpcall
# lines are ordinary trace aborts, not refusals.
import os
import re
import sys
from collections import Counter, defaultdict

WD = os.path.dirname(os.path.abspath(__file__))
KV = re.compile(r"(\w+)=(\S*)")
EVNAME = {1: "batch", 2: "dispatcher", 3: "paint", 4: "resume", 5: "kernel", 7: "hb"}
OUTSIDE = {2, 4, 5, 7}


def parse_err(path):
    out = []
    try:
        f = open(path, "r", newline="")
    except OSError:
        return None
    with f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("OCLJREF|"):
                out.append(("REF", dict(KV.findall(line[8:]))))
            elif line.startswith("OCLJCP|"):
                out.append(("CP", dict(KV.findall(line[7:]))))
            elif line.startswith("OCLJEV|"):
                out.append(("EV", dict(KV.findall(line[7:]))))
            elif line.startswith("OCLJRING|"):
                out.append(("RING", dict(KV.findall(line[9:]))))
    return out


def classify(stream):
    refs = []          # dicts with an added "absorber"
    pending = None
    anomalies = []
    cp_other = 0
    for kind, d in stream:
        if kind == "REF":
            if pending is not None:
                pending["absorber"] = "unseen"
            d = dict(d)
            d["absorber"] = None
            d["cpother"] = 0
            refs.append(d)
            pending = d
        elif kind == "CP":
            if d.get("st") != "4":
                continue
            if d.get("recorder") == "1":
                if pending is not None:
                    pending["absorber"] = "recorder"
                    pending = None
            else:
                cp_other += 1
                if pending is not None:
                    pending["cpother"] += 1
        elif kind == "EV":
            code = int(d["code"])
            if code in EVNAME:
                if pending is not None:
                    pending["absorber"] = EVNAME[code]
                    pending = None
                else:
                    anomalies.append("event %d with no refusal pending" % code)
    if pending is not None:
        pending["absorber"] = "unseen-end"
    return refs, anomalies, cp_other


def main(tags):
    for tag in tags:
        tsv = os.path.join(WD, "out", tag + ".tsv")
        ed = os.path.join(WD, "out", tag + ".err")
        runs = []
        with open(tsv, "r", newline="") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                runs.append(c)
        runs.sort(key=lambda c: int(c[0]))
        n = len(runs)
        rc_bad = sum(1 for c in runs if c[1] != "0")
        noline = sum(1 for c in runs if len(c) < 30)
        term = Counter()
        nref_hist = Counter()
        absorbers = Counter()
        absorbers_extra = Counter()       # refusals after a run's first
        opener_abs = Counter()
        sc_runs = []                      # second-chance runs
        sc_term = Counter()
        nonsc_term = Counter()
        outside_runs = []
        mismatch_count = 0
        pred_vs_truth = Counter()
        anomalies = Counter()
        ring_bad = 0
        opened_multi = 0
        rec_detail = Counter()
        rows = []
        for c in runs:
            off = int(c[0])
            if len(c) < 30:
                term["NOLINE rc=" + c[1]] += 1
                continue
            t = int(c[8])
            nref_tsv = int(float(c[25]))
            stream = parse_err(os.path.join(ed, "%d.err" % off))
            if stream is None:
                anomalies["no err file"] += 1
                continue
            refs, anom, cpo = classify(stream)
            for a in anom:
                anomalies[a] += 1
            ring = [d for k, d in stream if k == "RING"]
            if not ring or int(ring[-1]["n"]) != len(refs):
                ring_bad += 1
            if len(refs) != nref_tsv:
                mismatch_count += 1
            term[t] += 1
            nref_hist[len(refs)] += 1
            for i, r in enumerate(refs):
                absorbers[r["absorber"]] += 1
                if i > 0:
                    absorbers_extra[r["absorber"]] += 1
                truth = r["absorber"] == "recorder"
                pred = r.get("recorder") == "1"
                pred_vs_truth[(pred, truth)] += 1
                if truth:
                    rec_detail[(r.get("vm"), r.get("jst"), r.get("tier0"), r.get("opened"))] += 1
            openers = [r for r in refs if r.get("opened") == "1"]
            if len(openers) > 1:
                opened_multi += 1
            op = openers[0] if openers else None
            if op is not None:
                opener_abs[op["absorber"]] += 1
            sc = op is not None and op["absorber"] in ("paint", "recorder", "unseen", "unseen-end", "hb")
            if sc:
                sc_runs.append(off)
                sc_term[t] += 1
            else:
                nonsc_term[t] += 1
            if t in OUTSIDE:
                outside_runs.append((off, t, sc, [r["absorber"] for r in refs],
                                     op["absorber"] if op else None,
                                     refs[-1] if refs else None))
            rows.append((off, t, len(refs), ",".join(r["absorber"] for r in refs),
                         op["absorber"] if op else "-", int(sc)))
        print("=" * 78)
        print("%s: %d runs, rc!=0 %d, NOLINE %d" % (tag, n, rc_bad, noline))
        print("  term: " + ", ".join("%s=%d" % (k, v) for k, v in sorted(term.items(), key=lambda kv: str(kv[0]))))
        print("  refusals per run: " + ", ".join("%d:%d" % (k, v) for k, v in sorted(nref_hist.items())))
        tot = sum(absorbers.values())
        print("  absorbers, all %d refusals: " % tot + ", ".join(
            "%s=%d (%.1f%%)" % (k, v, 100.0 * v / tot) for k, v in absorbers.most_common()))
        tot2 = sum(absorbers_extra.values())
        if tot2:
            print("  absorbers, the %d refusals after a run's first: " % tot2 + ", ".join(
                "%s=%d (%.1f%%)" % (k, v, 100.0 * v / tot2) for k, v in absorbers_extra.most_common()))
        print("  the refusal that opened the reserve tier, its absorber: " + ", ".join(
            "%s=%d" % (k, v) for k, v in opener_abs.most_common()) + "  (runs where the tier opened more than once: %d)" % opened_multi)
        print("  SECOND-CHANCE runs (the opener absorbed by paint/recorder/unseen): %d; their term: %s" % (
            len(sc_runs), ", ".join("%s=%d" % kv for kv in sorted(sc_term.items()))))
        sco = sum(v for k, v in sc_term.items() if k in OUTSIDE)
        print("    ... ending outside the handler (term 2/4/5/7): %d of %d" % (sco, len(sc_runs)))
        print("  other runs' term: %s" % ", ".join("%s=%d" % kv for kv in sorted(nonsc_term.items())))
        print("  outside-handler landings: %d" % len(outside_runs))
        for off, t, sc, abl, opa, last in outside_runs[:40]:
            print("    off %5d term %d second-chance %d absorbers [%s] opener %s; last refusal: delta=%s tier0=%s win0=%s vm=%s jst=%s fk=%s ffid=%s at=%s over=%s" % (
                off, t, int(sc), ",".join(abl), opa, last.get("delta") if last else "-",
                last.get("tier0") if last else "-", last.get("win0") if last else "-",
                last.get("vm") if last else "-", last.get("jst") if last else "-",
                last.get("fk") if last else "-", last.get("ffid") if last else "-",
                last.get("at") if last else "-", last.get("over") if last else "-"))
        print("  shim-side recorder flag vs the wrap's ground truth (pred, truth): " + ", ".join(
            "%s=%d" % (k, v) for k, v in sorted(pred_vs_truth.items())))
        if rec_detail:
            print("  recorder-absorbed refusals by (vm, J->state, tier0, opened): " + ", ".join(
                "%s=%d" % (k, v) for k, v in rec_detail.most_common()))
        print("  checks: refusal lines != the driver's refusal count in %d runs; ring count != lines in %d; anomalies %s" % (
            mismatch_count, ring_bad, dict(anomalies)))
        with open(os.path.join(WD, "out", tag + ".class.tsv"), "w", newline="") as f:
            f.write("off\tterm\tnref\tabsorbers\topener\tsecond_chance\n")
            for r in rows:
                f.write("%d\t%d\t%d\t%s\t%s\t%d\n" % r)


if __name__ == "__main__":
    main(sys.argv[1:])
