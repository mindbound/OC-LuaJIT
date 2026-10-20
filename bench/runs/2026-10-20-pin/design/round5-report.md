# Round 5 report: pin guards, H1-H5 (the implementer's report, as delivered)

**Result.** final-check2.sh on the final text gives **79 PASS, 0 FAIL in 555 s** [M]. On round 4's text (`7c3c2683`) the same chain gives **65 PASS, 14 FAIL**: all 14 failures are new lines, and every round 4 line passes [M]. The W1 builds are unchanged on both hosts. The AlmaLinux 8 `.so` files match the release (additive `6c88805001bae0cd2b385803f5d857c7`, dropin `6c0715d11344c5fe075cd33f4f93cdbc`). The Windows additive and dropin objects match their references. There was one hygiene slip, described under Hygiene below.

## Files changed (repo; only the five it owned)

All five are LF with CR = 0 by bytes, and `git diff --check` is clean.

| file | lines | md5 |
|---|---|---|
| `native/build-native.sh` | 2732 | `47b9c52eecce550b57871d8448593bc3` (was 7c3c2683) |
| `README.md` | 94 | `8dae818ffcbd2d346dd8095f7890aadf` |
| `docs/jit-guide.md` | 2136 | `036642bd018bba59a6114bfabcdeb4e7` |
| `docs/roadmap.md` | 309 | `31ca738fd93ae7eee05764edbcf9ef2a` |
| `CLAUDE.md` | 20 | `0416090c30d6fa3015e3b0aabd00d357` |

The other 8 modified repo files and `upstream.commit` keep their start md5s (`pin5/before/md5-start.txt`). No other repo file needed a change.

## build-native.sh, against 7c3c2683 (+166 / -81 lines, 22 hunks)

- **H1, one canonicalization block.** THE INPUT DIRECTORIES (:481-571) runs before THE PIN, the first reader of `OCLJ_REPO`. It holds `physpath` (moved there), `winname` (round 4's verifier's, message reworded) and a new `physdir`, which resolves each directory input with `cd -P` and `pwd -P`, then applies `winname`, keeping what was given in `<VAR>_GIVEN` for the messages. Inputs: `SELF_DIR` (`winname` only), `OCLJ_REPO`, `OCLJ_LUAJIT`, `OCLJ_SHIM`, `OCLJ_SER`, `OCLJ_JNLUA` and `OCLJ_JNI` (`physdir`), `OCLJ_BUILD` and `OCLJ_OUT` (`physpath` plus `winname`). `OCLJ_JNI`'s default moved into the block; `LJ_FEATURES_H` is set after it. The guards and every later tool use the canonical values; the `_P` variables are gone and `LJ_CHECKOUT=$OCLJ_LUAJIT`.
- **Round 4's verifier's other fixes.** `MAKEOVERRIDES` is in the drop list; `pathkey` ends with `| tr -c '[:print:][:space:]' '?'`.
- **H2.** `SELF_REPO=$(cd -P "$SELF_DIR/..")` is `OCLJ_REPO`'s default. The G3 check loops over `OCLJ_REPO` and `SELF_REPO`, and the dist guard also covers `$SELF_REPO/build/native/dist`.
- **Comments.** THE BUILD ENVIRONMENT says the list is "measured or read", not "every variable", and notes names that are not shell identifiers; the ~:545-551 comment no longer says "cd -P takes .. where the file system does"; the header documents `OCLJ_SER`, the guarded script repository and the physical-path rule.
- **Against round 4's verifier's `7afa6a31`:** that fix canonicalized three variables after each guard; this one canonicalizes every input once, before anything reads them, and adds H2.

## Checks

- **final-check2.sh** (`pin5/final/final-check2.sh`, md5 `52f404b1513588fce124023f5777f79b`, 534 lines; pin4's `final-check.sh` untouched): round 4's chain plus T1, T2, T4, U2L (three lines), MAKEOVERRIDES (four lines), SHIM-dot (with a decoy `shim` beside it), SER-dot, H2-self-repo, H2-self-repo-dist, `W1-win-dist` by md5, and AlmaLinux 8 replays of U2 (symlink/`..`, non-ASCII case), U3 (symlink/`..`, case), T4, and G3 (in, case, symlink, nothing created, under build/), each in seconds with its exit code read from a file.
- **run-impl** (`pin5/final/run-impl/`): `PASS 79 FAIL 0 secs 555 build-native.sh 47b9c52e`. W1: 77+3 objects equal `build/native`'s; dropin equal to `canon-dropin`; Alma `.so` md5s as above.
- **ff-7c3c** (`pin5/ff-7c3c/`): `PASS 65 FAIL 14 secs 687`. Failures: MO-ignored-line, MO-objects, MO-no-O0, U2L-clone-untouched, U2L-build, U2L-objects, T1, T2, T4, SHIM-dot, SER-dot, H2-self-repo, H2-self-repo-dist, ALMA-T4. T1, T2 and H2-dist each replaced dist's DLL with one stamped `unpinned`; U2L wrote 90 files into the clone and deleted its untracked marker; the SHIM-dot build compiled the decoy.
- **extra.sh** (`pin5/extra-impl2/`): 15/15 PASS (OCLJ_BUILD inside the checkout, `OCLJ_REPO`'s dist directly, a checkout at the export path or inside layoutneg, OCLJ_BUILD equal to OCLJ_REPO, `OCLJ_OUT=dist` pinned and unpinned, x8 `OCLJ_REPO` through a junction, x10 `OCLJ_SHIM=<x>/<junction>/..` with a decoy). On `7c3c2683` (`extra-7c3c2/`) x8 and x10 fail; x10 built with the decoy compiled.
- **fn-test5** (`pin5/fn/`): 21/21 in Git Bash, AlmaLinux 8 sh and Ubuntu dash on the new text; 18/21 on 7c3c.
- **Cites:** `pin5/scripts/remap5.py` moved 39 cites (1 by hand); `pin5/cite-check.txt`: 47 checked, 0 not found or wrong. The same check finds 40 wrong against 7c3c. The guide's header md5 is `47b9c52e`.

## Hygiene

- `build/`: 38985 md5s identical at start and end, no file newer than the start stamp.
- `sh -n` passes in Git Bash, Alma and Ubuntu.
- **Slip:** after the end census the agent ran `git status --short` in `prototype/watchdog/luajit`. It changed the `.git` directory's mtime (1792474468 to 1792495026), almost certainly through git's index lock. The 31 `.git` files' md5s and the file list are unchanged (`pin5/census/after-status-*`).

## Claims table

`pin5/claims.md` (archived as `design/claims.md`): every guarantee sentence with the line or log behind it. README R1-R26, CLAUDE.md C1-C7, guide G1-G61 (header, checklist item 2, 1.1, 7 and 7.2-7.7, P44, OQ13-15), roadmap row 203 M1-M7. Every claim round 4's verifier listed as contradicted is rewritten.

## Deviations

- The dist guard also covers the script's own repository's `build/native/dist` (H2 named only G3); measured by H2-self-repo-dist.
- `physdir` leaves a value that names no directory as given, so the existing messages still fire ("OCLJ_JNLUA is unset", "no .../jnlua.c"); G3-under-build-allowed depends on that.
- The `OCLJ_JNI` default moved into the block verbatim, so an unset `JAVA_HOME` under `set -u` still aborts as before, only earlier.
- extra.sh and fn-test5.sh were added as evidence for claims final-check2 does not cover. extra.sh v1 was an instrument fault (no `OCLJ_REPO`, so the 7c3c copy stopped at its missing pin file); v2 fixed it, v1's directories kept.
- extra.sh ran while run-impl ran (CPU contention only).

## Open questions

1. Other Win32 name forms are untested: reserved device names, `:`, and characters MSYS stores under private-use code points.
2. Make reads environment names that are not shell identifiers, such as `-*-command-variables-*-`; unmeasured.
3. A script copy kept directly in a scratch directory makes that directory's parent a guarded repository.
4. An `OCLJ_OUT` inside the checkout or the repository is not refused, only one inside `dist`.
5. A file in an `OCLJ_BUILD` outside the repositories whose name matches one of the build's products is overwritten (documented, not guarded).
6. Whether the `build.gradle.kts` message should change, and whether the evidence should be archived under `bench/runs/`.
