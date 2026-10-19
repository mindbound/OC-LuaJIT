# 2026-10-19 -- the glibc round: a Linux .so that loads on glibc 2.28 and newer, gates that keep it so, and the JVM harness on Linux

The evidence behind the roadmap row "The Linux .so loads on glibc 2.28 and newer, and the jar build refuses one
that would not" (directly after row 216), and behind row 216's harness half.

- **The problem.** The Linux .so built in Ubuntu 26.04 (glibc 2.43) needed GLIBC_2.38 (`fmod`,
  `__isoc23_strtoul`), so it would not load on Ubuntu 22.04, Debian 12 or RHEL 9. A trial build in AlmaLinux 8
  (glibc 2.28) needed only 2.17, but left six pthread imports undefined with no version and no `libpthread`
  NEEDED. And the test runners failed to link there, because LuaJIT's `lib_package` needs `-ldl` before glibc
  2.34.
- **The floor, decided by the user (2026-10-19):** GLIBC_2.28, the glibc of AlmaLinux/RHEL 8, the oldest
  system we can build on, load and harness-test.
- **What changed:**
  - **Linking:** Linux links with `-static-libgcc -pthread -Wl,--no-undefined`, and every Linux test link
    with `-pthread -ldl`.
  - **The ELF import gate:** `native/build-native.sh` refuses any non-weak import without a version,
    reports the highest GLIBC need, and enforces `OCLJ_GLIBC_MAX` when it is set.
  - **The commit, with or without git:** `git_head` reads the LuaJIT commit for the blob fingerprint from
    git, pointed at the checkout's own `.git`, or from `.git/HEAD`. A build that cannot read it is refused.
    The AlmaLinux 8 host had no git, and its builds stamped `unknown` where the Windows DLL stamps
    `1ee778a4`.
  - **The gradle gate:** `build.gradle.kts`'s `verifyModAssets` parses each packaged .so's
    `.gnu.version_r` itself and refuses any need above GLIBC_2.28 or outside GLIBC_x.y.
  - **The harness:** `test/native/smoke-test.sh` is host-aware, and the round's Linux launchers
    (`scripts/full-linux.sh`, `chain-linux.sh`) run it in WSL.
  - **The release build** is made in AlmaLinux 8, into `build/native`.
- **Found on the way, all in the tests:**
  - `negative-control.sh`'s first full Linux run failed 5 arms. One was a Windows-only sabotage. The other
    four came from AlmaLinux 8's bash 4.4 keeping a prefix assignment past a function call.
  - The serializer's for-in identity check was flaky, at the same rate on every platform.

Implemented in the working tree on 3adfeaf (the JIT guide, committed), uncommitted.

How it was run:

- **Hosts.**
  - Windows 11: MinGW-w64, gcc 16.2.
  - AlmaLinux 8.10 under WSL: glibc 2.28, gcc 8.5.0, binutils 2.30, JDK 8u504. The user installed git
    2.43.7 there on 2026-10-19.
  - Ubuntu 26.04.1 under WSL: glibc 2.43, gcc 15.2.0, binutils 2.46, JDK 17.
- **Harness:** on ocelot-brain, one JVM at a time, not core-pinned: functional runs. JDK 8u504 on Windows and
  in AlmaLinux 8, JDK 17 in Ubuntu.
- **The chain** (`scripts/all.sh`) ran the fail-firsts, then every build, every suite, the harness and gradle,
  one step at a time. Its step log is `logs/all.txt`. The final verification, after the follow-up's fixes,
  is `scripts/final.sh` (`logs/final/`).

## The builds

| native | md5 | built |
|---|---|---|
| Linux additive .so (release) | `6c888050` | AlmaLinux 8, `OCLJ_GLIBC_MAX=2.28`, into `build/native` |
| Linux dropin .so (release) | `6c0715d1` | the same |
| Windows additive DLL | `3174ef37` | Windows, into `build/native` |
| Windows dropin DLL | `1e9f4ac4` | the same |

- **The release .so** (`logs/build-alma/`):
  - It needs at most GLIBC_2.17. Its needs are 2.2.5, 2.3, 2.3.2, 2.3.3, 2.12, 2.14 and 2.17.
  - It imports 110 symbols, every non-weak one versioned. NEEDED is `libm.so.6 libpthread.so.0 libc.so.6
    ld-linux-x86-64.so.2`.
  - Its fingerprint is `1ee778a4|LuaJIT 2.1.ROLLING|412be694|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64`,
    the Windows DLL's.
  - Every existing gate reads as on Windows: the bitwise and jit tools gates, GG_State 6376, the word, and
    ABI 87/91.
  - It is reproducible across build paths. A scratch rebuild with the final `build-native.sh`
    (`logs/build-alma-fixed/`) and the fail-first's own release build (`failfirst/ff-alma/`) both give
    `6c888050` and `6c0715d1`.
- **The Windows natives are unchanged in content** (`logs/build-win/`):
  - All 80 objects (77 LuaJIT plus the shim's 3) are byte-identical to round 3's final build.
  - The DLLs differ from round 3's `9ae455ce`/`2c37a7a1` in 8 bytes, all link time stamps: the COFF
    header's TimeDateStamp, the PE checksum and the export directory's stamp. Size and ImageBase are the
    same.
  - A Windows rebuild with the final script gives the same `eris_lj.o`, `jnlua.o` and `lj52shim.o`
    (`logs/build-win-fixed/`).
- **A development build in Ubuntu** (`logs/build-ubuntu/`), in scratch, never `build/native`. It reports
  `GLIBC_2.38, NOT within the release floor` and finishes, because `OCLJ_GLIBC_MAX` is unset.
- **The jar:** `build/libs/ocluajit-3adfeaf-master+3adfeaf74b-dirty.jar`, md5 `0c675a02` (`logs/gradle/`),
  packaging the Alma .so and the Windows DLL. A dirty-tree build, not installed in the game.

## Fail-firsts

Run before the release build replaced `build/native`'s round-3 .so (`failfirst/`):

| check | the case that must fail | result |
|---|---|---|
| gradle's glibc gate | today's `build/native/dist` (round 3's Ubuntu .so `7e8b8b89`) | refused: `needs GLIBC_2.38, above the glibc floor GLIBC_2.28` (`gradle-dist.log`) |
| the ELF import gate | the final `build-native.sh` with only its Linux `LINK_EXTRA` put back to `-static-libgcc`, in AlmaLinux 8 | BUILD FAIL naming `pthread_attr_setstacksize pthread_condattr_setclock pthread_create pthread_join pthread_setname_np pthread_sigmask` |
| the floor | the final script with `OCLJ_GLIBC_MAX=2.28` in Ubuntu | BUILD FAIL: `needs more than OCLJ_GLIBC_MAX=2.28 allows` (GLIBC_2.38) |
| the commit | HEAD's script with git failing (`GIT_DIR=/nonexistent`) | builds, and stamps `unknown\|LuaJIT 2.1.ROLLING\|...` (the .so is `bf0d0916`, the trial's) |
| the commit refusal | the final script on a LuaJIT tree without `.git`, git failing | BUILD FAIL: `cannot read the LuaJIT checkout's commit` |
| the two commit paths | the release built with git, and with git failing (`.git/HEAD`) | byte-identical `.so` (`6c888050`), both stamping `1ee778a4` |
| git's walk-up (after the review) | a tree with no `.git` inside another git work tree; an exported `GIT_DIR` | the first `git_head` stamped the outer repository's commit for both; the final one refuses the first and reads `1ee778a4` for the second, on Windows and in AlmaLinux 8 (the review's measurements and the main session's: `claude-tmp/oclj/glibc/githead3/`) |

The implementers' own fail-firsts are in `design/impl-reports/`. They cover:

- the gate text over 22 cases under binutils 2.30 and 2.46;
- 32 gradle cases, among them 16 malformed ELF files;
- HEAD's runners failing to link in AlmaLinux 8;
- HEAD's `smoke-test.sh` refusing or mis-staging on Linux.

## Results

**Native suites** (`logs/suite-win`, `suite-alma`, `suite-ubuntu`; AlmaLinux 8 against the release
`build/native`, Ubuntu against the development build):

| suite | Windows | AlmaLinux 8 | Ubuntu |
|---|---|---|---|
| shim, security | PASS, PASS | PASS, PASS | PASS, PASS |
| race | 2/0 | exit 2 (Win32 only, as designed) | exit 2 |
| mem, vgc, wd, penalty | 86/0, 47/0, 35/0, 6/0 | the same | the same |
| run-pack, the pack fuzz | PASS | PASS | PASS |
| run-bitop, run-bitjit, run-bitfuzz | PASS (12/0) | PASS, with PUC 5.3.6 built in AlmaLinux 8 | PASS |
| serializer `make test`, `make negctl` | PASS, PASS | the for-in check failed once (below); `make negctl` PASS | PASS, PASS |
| negctl-pack, negctl-bitop | PASS, PASS | PASS, PASS (both first runs on gcc 8.5) | not run |
| `negative-control.sh` | PASS | 51 PASS, 5 FAIL (below) | not run |

**Final verification**, after the follow-up's fixes (`logs/final/`): `negative-control.sh` passed 57 of 57
on Windows, AlmaLinux 8 (the release `build/native`) and Ubuntu (the development build). The serializer suite
passed in full on all three, the fixed for-in test included.

**The harness** (`logs/harness-win`, `harness-alma`, `harness-ubuntu`; the natives frozen at
`claude-tmp/oclj/new-gl-3174ef37` and `new-gl-linux-6c888050`):

| arm | Windows (JDK 8) | AlmaLinux 8 (JDK 8), the release .so | Ubuntu (JDK 17), the release .so |
|---|---|---|---|
| additive, JIT on | 82 / 0 | 82 / 0 | 82 / 0 |
| dropin | 69 / 0 | 69 / 0 | |
| additive, JIT off | 80 / 0 | 80 / 0 | |
| sieve | 76 / 0 | 76 / 0 | |
| stock | 53 / 0 | 53 / 0 | |
| disposeoff | 82 / 0 | 82 / 0 | |
| bundleoff | 82 / 3: stk-2, stk-3, stk-4 | 82 / 3: stk-2, stk-3, stk-4 | |

- These are the first JVM runs of a Linux native, roadmap row 216.
- They load the release .so itself, and the stock arm loads OC's own Linux PUC 5.2 native from its jar.
- The Windows arms equal round 3's, so the host-aware `smoke-test.sh` changed nothing on Windows.
- A Linux arm takes about 72-86 s of wall time, against 83-103 s on Windows.

**gradle** (`logs/gradle/`):

- `verifyModAssets` accepts `build/native/dist`, logging that the .so needs at most GLIBC_2.17.
- `./gradlew build` builds the jar.

## What the first Linux runs found, and the fixes

1. **`negative-control.sh`, first full Linux run** (AlmaLinux 8, `logs/suite-alma/negctl.log`): 51 PASS,
   5 FAIL, where Windows passes 56 of 56. Both causes were in the test (`design/followup-reports/`).
   - **notimer** sabotaged `lj52_wd_fire`, the Win32 timer callback, which Linux compiles out. The
     "sabotaged" Linux build was the canonical one, and it fired the deadline correctly.
     - The arm now picks its sabotage per host. On Linux it removes `lj52_wd_inject(M);` from
       `lj52_wd_thread`.
     - A preprocessor guard refuses a sabotage the host compiles out. It was fail-firsted with the two
       hosts' texts swapped.
   - **The four allocator arms** (`rawverdict`, `nolook`, `refusalkeeps`, `noarm`):
     - The cause: AlmaLinux 8's `/bin/sh` is bash 4.4.20 in POSIX mode, which keeps `MEMTEST_CFLAGS=...`,
       written before a shell function call, after the call returns. So 23 mem arms swept 8 caps instead
       of 96.
     - The allocator was never the cause. At 96 caps every arm fails exactly its expected checks on all
       three hosts, at the same offsets. At 8 caps Windows misses them exactly as AlmaLinux 8 did.
     - The fix sets and clears the variable on lines of its own.
     - A new check, 4.31, reads each arm's cap count from its own output. It fails on the chain's AlmaLinux
       8 artifacts.
     - **No product issue:** the RAM-cap machinery behaves the same on Linux, and charges LuaJIT's requested
       sizes, never OS pages.
2. **The for-in identity check** failed once in AlmaLinux 8 (`logs/suite-alma/ser-test.log`).
   - The unmodified test fails about 1% of fresh processes on every platform: 20 of 2000 in AlmaLinux 8,
     18 of 2000 in Ubuntu, 26 of 2000 on Windows.
   - It had two causes, both in the test. A JIT trace sometimes stitches across the identity shape's
     `coroutine.yield`, giving a different but faithfully written VM state. And the pointer-window locator
     was ambiguous.
   - The fix turns the JIT off for that shape and makes the locator require a GC64 address. It then passed
     1000 of 1000 runs in AlmaLinux 8 and 500 of 500 each in Ubuntu and on Windows.
   - The serializer and the fixture are unchanged.
3. **The review** (`design/review-results.json`): four dimensions, each with an adversarial verifier. 14
   findings, all confirmed, none high. Applied:
   - `git_head` pointed at the checkout's own `.git` (it could take an enclosing repository's commit);
   - the docs' stale "Alma stamps unknown" text, the md5s and the line references;
   - the floor wording;
   - the `dl_iterate_phdr` wording;
   - the launchers' path, rerun and environment handling.

   The launcher fixes in `scripts/full-linux.sh` and `chain-linux.sh` were made after the chain ran. Their
   headers give the md5 of the text the chain ran.

## Not done

- **No Minecraft client or server has loaded the Linux .so,** and its extraction from the jar on Linux has
  not run (row 216's remaining half).
- **gradle does not refuse unversioned imports**; `build-native.sh` does (the glibc row's open item 3).
- **The commit is read, not checked against the pin:** nothing compares it with `1ee778a4`.
- **busybox awk** is untested for the ELF gate (gawk and mawk are measured).
- **`all.sh` reuses an existing freeze directory.** That rule is round 3's (refuse instead). In this run both
  freeze directories were fresh, and `scripts/all.sh` is kept as it ran.

| path | what |
|---|---|
| `failfirst/` | `gradle-dist.log` (today's dist refused); `ff-alma/` and `ff-ubuntu/` (`summary.txt`, `host.txt`, each case's build log); `dist-before.md5`; `alma.out`, `ubuntu.out` |
| `logs/all.txt` | the chain's step log; `diffstat.txt`, `status.txt`, `sources.md5` at its start |
| `logs/build-win/`, `build-alma/`, `build-ubuntu/` | each build's logs, `natives.md5` (objects and libraries), and for Linux `glibc.txt` (needs, NEEDED, fingerprint) and `host.txt` |
| `logs/build-alma-fixed/`, `build-win-fixed/` | the final `build-native.sh`'s rebuilds, proving the release and the Windows objects unchanged |
| `logs/suite-win/`, `suite-alma/`, `suite-ubuntu/` | every native suite per host: `.log`, `.rc`, `.start`, `.end` |
| `logs/harness-win/`, `harness-alma/`, `harness-ubuntu/` | the harness arms: `run.log`, `args.txt`, `native.md5`, Linux `native.glibc` and `host.txt`, `exit.txt`, `started.txt`, `finished.txt`; the chain logs |
| `logs/gradle/` | `verify.log`, `build.log`, `dist.md5` (with the jar) |
| `logs/final/` | the final verification: `negative-control.sh` and the serializer suite on all three hosts |
| `design/` | `impl-reports/` (two investigations, three implementations, docs), `review-results.json`, `followup-reports/` (the negctl and for-in investigations and fixes, docs) |
| `scripts/` | `all.sh` (the chain), `ff-linux.sh`, `build-win.sh`, `build-linux.sh`, `native-tests-win.sh`, `suites-linux.sh`, `full.sh`, `chain-win.sh`, `full-linux.sh`, `chain-linux.sh`, `final.sh`, `final-linux.sh` |

The scripts hard-code local paths: the work tree under `C:/Users/astro/claude-tmp/oclj`, the repo, OC-JNLua,
ocelot-brain, the JDKs and the WSL distros. Windows logs are CRLF in the working tree; `.gitattributes`
normalizes them on commit. The binaries are not archived; their md5s are.
