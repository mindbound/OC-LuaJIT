impl-code is done, all in scratch. I changed no file in the real repo [M: `git status` before and after is the same, and neither .git/index was rewritten].

(1) THE SCRATCH REPO. C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/ is `git -C <repo> -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` (1a13bed), unpacked there. The tar is kept as impl-code/head-1a13bed.tar, md5 73b97105. It holds 5221 files, which is ls-tree's count, and no symlinks [M]. It has no .git and no prototype/watchdog/luajit, so builds pass OCLJ_LUAJIT=<real repo>/prototype/watchdog/luajit, which build-native.sh only reads [S: its git calls are archive, cat-file, ls-tree, rev-parse and hash-object without -w]. build-native.sh runs from it: rc 0 in 37 s [M logs/build-build-fix.log]. Against a fresh unpack of the tar, exactly three files differ [M impl-code/repo-vs-head.txt]:
- native/luajit/patch-bitop-fold.sh: 08c242a5 -> d488821b
- native/luajit/oclj_bitop.h: de156ecc -> 8385a4d1
- native/luajit/oclj_bitop_rec.c: ef711189 -> 076c0a1a
All three are LF, with no backslash or NUL. The script has no tab, and the two C files keep their tab counts (1 and 19). `git diff --no-index --check` is clean on all three [M].

(2) HUNK 12, in lj_opt_cse.
- o12 is the pin's lines :2612-2613: `      if (IR(ref)->op12 == op12)` and `@T@return TREF(ref, irt_t(IR(ref)->t));  /* Common subexpression found. */`.
- n12 is a 4-line `OC-LuaJIT:` comment, then `      if (IR(ref)->op12 == op12 &&`, then `@T@  irt_isi64(IR(ref)->t) == irt_isi64(fins->t))`, then the same return line.
- The header now says twelve hunks, has item 12 and names the anchor. NH=12. NMARK stays 1.
- NADD/NDEL are 76/9, taken from the script's own diff count: `76 lines added, 9 removed, of 2720` on the pin's blob 15c7420c [M ff-patch-3]. The success message gains "no CSE of int64 with another type".
- The hunk engine block is unchanged: 99 lines, md5 077d1dbebe05, the same as HEAD's [M].
- The anchor occurs once in the pin's file and once in a4c0645's (impl-code/tip, 0f28177c, equal to the numconv census export). The script applies on the tip: 76/9, of 2730 [M].
- The build copy's patched lj_opt_fold.c is 59778bb6, which equals the script's output on the pin's file [M].

verify_content gains five checks:
- C1: the predicate, leading blanks stripped, is a whole line exactly once.
- C2: `irt_isi64(IR(ref)->t)` is named on exactly 1 line.
- MISS: the definition lines of lj_opt_cse and lj_opt_cselim, and the predicate line, are all present.
- ORD: lj_opt_cse's definition < the predicate < lj_opt_cselim's definition.
- ADJ: the line above is exactly `      if (IR(ref)->op12 == op12 &&` and the line below is the tab plus the return text. This is done in awk with sprintf("%c",9), so the script still has no tab or backslash.

Fail-first [M: impl-code/ff-patch-3/results.txt, PASS=65 FAIL=0, run by scripts/ff-patch.sh]:
- Each of these script mutations is refused, rc 1, with its own message: a stray copy in n12; hunk 12 re-anchored into lj_opt_cselim; CSEFWD's forward-allowing text; the reverse-allowing `|| irt_isi64(IR(ref)->t)`; the predicate dropped; a whole-`t` compare; the predicate after the return; `||` ending the if line.
- In every one of those cases, the script with only hunk 12's checks removed (S0) passes, rc 0. So each refusal is the new check's.
- Also refused: the marker in the comment, the old NADD 70/8, and NH=11.
- Input stray copies are refused. A same-form copy fails C1, and a one-line copy on lj_opt_cselim's if fails C2. HEAD's script and S0 pass both, rc 0. The anchor present twice or missing is refused.
- On the already-patched path, a build copy carrying CSEFWD's text or the reverse form is refused at "hunk 12's patched text occurs 0 times", and a patched file with a one-line copy is refused by C2.

Part B evaluates every check without exiting, on 11 mutations of a patched file plus the file itself. All 12 match the stated expectations:
- C2 fails alone on a one-line copy in cselim.
- ORD fails alone on the test moved, with its two neighbours, into cselim.
- ADJ fails alone on the test after the return, and on an `||`.
- C1 and MISS never fail alone. They are kept for their messages, as the comment above verify_content says.
- Indentation is held by verify_patched's match on the hunk text.
I checked the harness itself: given two deliberately wrong expectations it reports FAIL=2, rc 1 [M ff-instr-1].

(3) THE STALE COMMENTS, fixed with no line count changed.
- oclj_bitop_rec.c :148-149 now says "only the width and FIX-NUMCONV rules remove it, proving res exact" (157 lines before and after).
- oclj_bitop.h :122-123 now says "only the width rule and FIX-NUMCONV's may remove it". I also fixed :120's "(or the width rule proved it)", which was stale the same way, with :120-123 rewrapped (126 lines before and after) [M diff].

(4) THE BUILD. impl-code/build-fix: pinned, additive, Windows, rc 0. Gates OK, no warnings, `ignored from the environment: none`, export verified [M logs/build-build-fix.log].
- Against build/native, the 77 LuaJIT objects and our 3 differ in lj_opt_fold.o alone: f6d916e2 -> a6c5fcc2 [M cmp/fix-vs-buildnative.txt].
- A comment-only build (HEAD plus the two comment files, impl-code/build-commentonly) equals build/native in all 80 objects. So the comment changes move no object [M cmp/commentonly-vs-buildnative.txt].
- Disassembled function by function, lj_opt_fold.o differs in lj_opt_cse alone: 67 -> 83 instructions, out of 155 functions. The new code masks each type with 0x1f and compares it with 0x15 (IRT_I64), and on a mismatch continues to `prev` [M objdiff/].
- Other md5s: fixed luajit.exe 390b2928 (a link-time md5, P13); DLL 1aacec4e (path-dependent, P50; scratch only).

(5) THE RUNNERS on build-fix, unchanged from HEAD, each into a fresh directory, about 71 s in all, with no java.exe or javaw.exe running [M run-fix-1/summary.txt].
- run-bitop.sh: PASS, 12 checks.
- run-bitjit.sh, default parts (gen, floor, fix1, idx, sel, nc): PASS.
- run-bitfuzz.sh: PASS.
- The md5 manifest of round/repo was the same before and after the runs.

Extra smoke check, forward order and values only: run-3's cse-fwd2.lua (the bit library's op first) reads 682 mismatches on build/native and 0 on build-fix under the JIT, and 0 on both with -joff. The pair loops (lines 22 and 33) compile root traces on both builds [M smoke-fwd-1, smoke-fwd-jv-1]. No reverse-order case was written or run.

FILES:
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/native/luajit/patch-bitop-fold.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/native/luajit/oclj_bitop.h
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/native/luajit/oclj_bitop_rec.c
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/repo-vs-head.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/head-1a13bed.tar
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/ff-patch.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/ff-patch-3/results.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/ff-instr-1/results.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/build.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/build-as-run-5cd5428f.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/logs/build-build-fix.log
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/build-fix
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/cmp/fix-vs-buildnative.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/cmp/commentonly-vs-buildnative.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/cmp/key.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/fndiff.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/objdiff/fold-base-vs-fix.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/objdiff/lj_opt_cse-fix.s
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/runners.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/run-fix-1/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/scripts/smoke-fwd.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/smoke-fwd-1/summary.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/impl-code/smoke-fwd-jv-1

REST:
{
 "open_points": [
  "Hunk 12's C comment cites `JIT guide P63`, which does not exist yet. The docs phase must add P63 (design section 7), or the cite points nowhere.",
  "Wording differs from the design on purpose. The design says 'narrower'; I wrote 'of another type' (comment, header item 12) and 'no CSE of int64 with another type' (success message), because irt_isi64(a) == irt_isi64(b) refuses an I64 match against every other type (NUM, P64 and the rest), not only narrower ones [S]. The docs should use the same words.",
  "I changed oclj_bitop.h :120 as well as the :122-123 the task named: its '(or the width rule proved it)' was stale in the same way. :120-123 were rewrapped and the line count is unchanged. The cite of oclj_bitop_rec.c ~:141 in guide 8.8 does not move. oclj_bitop_rec.c's header :36-37 ('the width rule there removes the guard when res provably has 54 bits or fewer') leaves out FIX-NUMCONV but makes no 'only' claim, so I left it; the docs or fix phase can decide.",
  "For integrate and the cserev gate: on the already-patched path, a build copy with CSEFWD's text (or the reverse form) is refused by verify_patched's hunk-text count ('hunk 12's patched text occurs 0 times'), before the new verify_content checks run [M ff-patch-3 P1, P2]. CSEFWD's anchor line occurs exactly once in the patched copy (C1 = 1).",
  "Not done here, by design: the AlmaLinux 8 .so build, negctl CSEFWD, T1-T4 and the gated cserev. The forward smoke on build-fix (cse-fwd2.lua: 0 against 682 on the base) is a smoke reading, not T1 or T2.",
  "Hygiene: impl-code/scripts/build.sh contains four line-continuation backslashes. They were written with the file tool and survived (bytecount bs=4); the as-run copy build-as-run-5cd5428f.sh is kept, and the header now says so. One read-only command I ran contained `tr -d` with a backslash (P8). Its output was correct, and nothing kept depends on it.",
  "build-fix/dist holds the scratch additive DLL, which a pinned build always collects there. It must never be packaged."
 ]
}
