# OC-LuaJIT: notes for agents

OC-LuaJIT is a LuaJIT-based CPU architecture for GTNH OpenComputers (Minecraft 1.7.10). It runs machines on our fork of LuaJIT 2.1, pinned at upstream `1ee778a4` (x64, GC64, no FFI, Lua 5.2 compatibility, CHECKHOOK, plus Lua 5.3's `string.pack` and bitwise operators), driven through OpenComputers' own JNLua by a native that `native/build-native.sh` builds, with a full-state serializer for persistence (`serializer/eris_lj.c`) and a timeout watchdog. The authoritative documents are [README.md](README.md) (what the mod is, the Lua dialect, building), [docs/roadmap.md](docs/roadmap.md) (every open and closed row, and the decisions), [docs/jit-guide.md](docs/jit-guide.md) (JIT, DynASM and VM engineering on the fork), [serializer/README.md](serializer/README.md) (the serializer) and [docs/watchdog.md](docs/watchdog.md) (the watchdog). Where this file and they disagree, they win.

Before touching native/luajit/, native/build-native.sh's LuaJIT steps, or anything that changes what the parser, the interpreter or the JIT computes, read docs/jit-guide.md, starting with its Agent checklist.

## Conventions for any agent

- Repo files are LF. On Windows, Python writes need `newline=""` (it writes CRLF otherwise), and CR counts are checked by bytes (a Python byte count, `grep -c -U` or `od -c`), never with plain grep or awk, which drop a line-end CR in Git Bash.
- Do not write scripts through shell heredocs that contain backslashes: they collapse silently. Write files with a file tool; patch scripts contain no backslashes at all.
- Prove every new check can fail, on a case that must fail it, before trusting a pass.
- Never write a test that forces a native crash. A crash fix is proved by a black-box census A/B (the same unmodified workload before and after, abnormal exits counted) plus build assertions that the fix is present (JIT guide 11.10).
- Never clear or reuse a results directory: write a fresh one, or move the old one aside.
- Measurement chains longer than a minute run from the main session (nohup plus a monitor); agents get bounded work. Never edit a script that a running chain executes.
- Evidence archives (`bench/runs/<date>-<name>/`) keep md5s of binaries, not the binaries.
- Mark claims [M] measured, [S] read in source, or [I] inferred, and name the run, file or function behind each.
- Never hand-edit files under `build/`: build-native.sh re-takes only the files it patches, so an edit there survives silently (P44 in the JIT guide). Experiment in scratch copies.
