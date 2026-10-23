I applied the verifier's five findings in the scratch copy only (round/repo), with two changes and one rejection. I also wrote final-check.sh, commit-facts.md and code.patch. I never wrote to the real repo. During the round its HEAD moved from 60a24ec to 2ea33dd, a commit someone else made that touches only docs/ and bench/runs. native/ and test/ are the same as before, so the patch's base did not change. build/native is unchanged: luajit.exe f4038cd6, lj_opt_fold.o f6d916e2. No java.exe or javaw.exe ran during any timing-relevant run.

**The findings**
1. **verify_content (medium): applied, and made a little stricter.** Between lj_opt_cse's definition line and lj_opt_cselim's, exactly one line may name `op12 == op12` and exactly two may name `return`. The verifier proposed counting only the one return text; counting every `return` also catches an extra match spelled without op12 (my m5). [M fix/runs/ffpatch-1, ffpatch-2, fc-ffpatch-1]:
   - The old script passes m1-m6 with rc 0. The new one refuses each with rc 1 and its own message.
   - c5 and c6 are still refused.
   - With a fail() that does not exit, the match count fails alone on m6 and the return count alone on m5.
   - The patch still adds 76 lines and removes 9: 2720 lines on the pin's blob, 2730 on a4c0645's. It is idempotent, and its output is the build copy (59778bb6).
   - The fresh Windows build fix/b1 differs from build/native only in lj_opt_fold.o (a6c5fcc2). The AlmaLinux build fix/alma1 differs only in lj_opt_fold.o too (1b4a7c13).
2. **The copy and side cases (low): applied.** t_csefwd gains the cases copy and side plus two controls, so it now has 32 cases. Its producer-first check also covers the two new shapes.
   - cseir judges copy only with loop optimisation on, and side only where a trace compiled our operator.
   - The verifier's implied precondition, "a side trace exists", failed on the fixed build under -Omaxside=0, where the side trace is a stub [M fix/runs/cse-fix-1, probes/onecase.lua].
   - Fixed build: everything passes, 20 of 20 pairs formed in the default set [M cse-fix-2, cse-fix-3, bitjit-all-fix-1, alma1/cse].
   - build/native FAILs as it should [M cse-base-1..6, alma1/base-cse]. The side case's value varies with trace formation in a few option sets (details in commit-facts 3.1).
   - CSEFWD is caught by both catchers [M runs/negctl-cse-1, -2].
3. **In-game reach (low): docs phase.** Now I only fixed t_cserev's sentence "the copy emits no new pair". I also corrected its TYPEINS cite to :334 and :352.
4. **"12 option sets" (low): applied**, then rewritten with the new numbers.
5. **t_cserev's text check (low): the check is applied**, refusing any text that contains `bit` or more than one `for `. **I rejected its proposed fail-first.** It is exactly the slot shape D2 forbids writing on any build [code redacted in the public archive]. I proved the check with Lua comments (`-- for `, `-- bit`) instead, run under PUC and -joff only: the new check exits 2 with INSTRUMENT, the old one passes [M runs/fftests-1, -2].

**final-check.sh** builds round/repo on Windows and in AlmaLinux 8 and covers every part the task asked for: run-bitop, run-bitjit with all seven parts and PUC on both platforms, run-bitfuzz, the generator's modes, the base fail-first, the 37-arm negctl sweep in one call, hygiene and a timing smoke. It ends with a VERDICT line in ALL.done.
- **What it refuses:** an existing, wrongly placed or unreachable outdir; scratch files whose md5s differ from the eight it pins; a scratch tree that differs from HEAD's other than by those eight files; and a running Java when timing is wanted.
- **No forbidden case:** t_cserev is the only reverse-order file and holds only the two no-slot shapes (R5, R6); its md5 is pinned, so nothing unreviewed can run.
- **Proved to fail:** each refusal (smoke/g1-g7) and both readers (smoke/s1, s2, s3, s7, raw-doctored).
- **Every part passed separately** in smoke/s1-s8, run with knobs.
- The whole check takes about 30-35 minutes, so it is for the main session.

**code.patch** (md5 8a126631410b25784b4cdb8d46992eb0) is a unified diff of the eight files against HEAD, three of them new. With `git -c core.autocrlf=false apply` on a fresh export of HEAD it reproduces all eight byte for byte [M fix/patchtest-2].

My own slip: once I ran `python -I -` (stdin from /dev/null) by mistake. It hung, I stopped it, and it touched nothing.

FILES:
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/final-check.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/commit-facts.md
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/code.patch
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/code.patch.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/code-files.txt
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/repo-eight-end.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/scripts-and-helpers.md5
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-cites.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-basecse.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-ffpatch.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-fftests.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-anchors.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-timing-summ.py
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-a4c0645-lj_opt_fold.c
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/fc-bench
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/native/luajit/patch-bitop-fold.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/t_csefwd.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/cseir.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/bitop/t_cserev.lua
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/run-bitjit.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/repo/test/native/negctl-bitop.sh
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/runs
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/smoke
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/alma1
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/b1
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/start
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/scripts
C:/Users/astro/claude-tmp/oclj/csetwin/round/fix/probes/onecase.lua

REST:
{
 "open_points": [
  "The full final check has not run end to end. The main session runs it (nohup plus a monitor on <outdir>/ALL.done, about 30-35 min, with Minecraft closed and the real repo left alone during the run). Every part passed separately in smoke/s1-s8; negctl ran only canon plus CSEFWD.",
  "The side case's value on an unfixed build depends on whether a trace compiles its branch, which varied between runs. Under -Ohotloop=1 -Ohotexit=1 it was wrong in 6 of 7 runs; under the two -Omaxside=0 sets it was wrong in 1 of 14 readings; on CSEFWD under -Ohotexit=1 it read right once in 2 runs. So the per-set counts the docs quote for t_csefwd need to be ranges. cseir's counts were stable in every run.",
  "In the default set every pair must be judged. If side's side trace ever failed to form there, the run would read PROVED NOTHING, not PASS. That has not happened in 10 runs on fixed builds.",
  "Docs phase: finding 3's in-game reach sentence (G3 can also arise from a pair formed only in the loop copy), and the new numbers: 32 cases, 13 wrong-when-served, 20 pairs, the base and CSEFWD per-set counts, canon 110-112 s, and the verify_content counts with fail-firsts m1-m6. All are in commit-facts.md sections 3 and 6.",
  "Real-repo HEAD moved from 60a24ec to 2ea33dd during the round (docs and bench/runs only). The code base is unchanged, and the final check archives whatever HEAD is current when it runs.",
  "To apply code.patch in the real repo, use git apply there (.gitattributes sets eol=lf) or `git -c core.autocrlf=false apply`, then check the eight md5s in fix/repo-eight-end.md5. Outside a repo, Git's global core.autocrlf=true writes the files with CRLF line endings.",
  "fc-timing-summ.py is integrate's timing-summ.py plus a guard for rows with no ratio: it crashed at FC_NDIV=10 on rows reading 0 ns. With the guard it still reproduces integrate/timing/run-1/summary.txt byte for byte.",
  "fc-anchors.sh (integrate's anchors.sh, unchanged) contains one backslash, the newline escape in a printf format, although its header says it has none. It is harmless.",
  "Residual gap: a macro that redefines irt_isi64 inside n12 would still pass verify_content. The patch script's comment says so.",
  "My slip: I once ran `python -I -` (stdin from /dev/null). It hung, I stopped it (task bcqv14z26), and nothing was changed.",
  "The negctl work directories from my runs (each FIX-NUMCONV run left about 157 MB) are in fix/b1/negctl-bitop and fix/smoke/s5/b/win/negctl-bitop. They are scratch and can be deleted at the main session's discretion."
 ]
}
