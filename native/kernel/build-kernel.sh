#!/bin/sh
# =====================================================================
# build-kernel.sh -- OpenComputers' machine.lua -> the OC-LuaJIT variant,
# staged where build.gradle.kts will package it into the mod jar.
#
#     sh native/kernel/build-kernel.sh
#
# WHY THIS EXISTS SEPARATELY FROM THE HARNESS. test/native/smoke-test.sh also
# runs patch-machine-lua.lua, but against OCELOT-BRAIN's copy of the kernel,
# because that is the kernel the harness's machines will load. The MOD must ship
# the patched form of the kernel GTNH OpenComputers actually has, and the two
# are not the same file: 46483 bytes in the pinned 1.12.58 dev jar against
# 47998 in ocelot-brain. They differ by one line of content (GTNH adds
# `realTime = computer.realTime` to the sandbox `computer` table) and by line
# endings. Patching the wrong one and shipping it would put ocelot-brain's
# kernel into a Minecraft instance.
#
# WHERE IT GOES, AND WHY NOT OPENCOMPUTERS' OWN PATH.
# OCLuaJITArchitecture.initialize() loads /assets/ocluajit/lua/machine.lua --
# OUR resource domain -- after super.initialize() has run, and swaps it for what
# OpenComputers loaded. It cannot be delivered at OC's own path, because a mod
# cannot win a classpath race against OpenComputers for OpenComputers' own
# resource. See docs/research/shipping-model.md.
#
# WHEN IT IS ABSENT. The build stays green and the jar ships without it; the
# architecture then logs a warning and runs on OpenComputers' kernel with its
# standing deadline hook. Computers work; the JIT thrashes (measured 0.47 s for
# a sandbox loop against 0.0047 s). That is the right failure for CI, which has
# no Lua interpreter to run the patcher, and the wrong one for a release.
#
# INPUTS
#   OCLJ_OC_JAR      the OpenComputers jar to take machine.lua from
#                    [default: the newest -dev jar in the Gradle cache]
#   OCLJ_LUAJIT_EXE  a luajit that can run the patcher
#                    [default: the first $OCLJ_BUILD/luajit*/src/luajit.exe --
#                     the LuaJIT build tree is per-platform]
#   OCLJ_BUILD       build root  [default: <repo>/build/native]
# =====================================================================
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() { echo "KERNEL BUILD FAIL: $*" >&2; exit 1; }
say()  { echo "[kernel] $*"; }

: "${OCLJ_REPO:=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)}"
: "${OCLJ_BUILD:=$OCLJ_REPO/build/native}"
: "${OCLJ_LUAJIT_EXE:=$(ls "$OCLJ_BUILD"/luajit*/src/luajit.exe 2>/dev/null | head -1)}"
: "${OCLJ_OC_JAR:=}"

OUT_DIR="$OCLJ_BUILD/kernel"
OUT="$OUT_DIR/machine.lua"
RAW="$OCLJ_BUILD/kernel-src/machine.lua"

# --------------------------------------------------------------- 0
# THE JAR IS PINNED BY dependencies.gradle AND WE MUST USE THAT ONE. Taking
# "whatever OpenComputers jar is lying around" would silently patch a kernel the
# mod is not built against, and patch-machine-lua.lua's anchors are the only
# thing that would notice -- loudly, but only if they happened to miss.
if [ -z "$OCLJ_OC_JAR" ]; then
  PIN=$(grep -oE 'OpenComputers:[0-9][^:]*:dev' "$OCLJ_REPO/dependencies.gradle" 2>/dev/null \
        | head -1 | cut -d: -f2)
  [ -n "$PIN" ] || fail "cannot read the pinned OpenComputers version from dependencies.gradle; set OCLJ_OC_JAR"
  say "pinned OpenComputers = $PIN"
  OCLJ_OC_JAR=$(find "$HOME/.gradle/caches/modules-2/files-2.1/com.github.GTNewHorizons/OpenComputers/$PIN" \
                  -name '*-dev.jar' 2>/dev/null | head -1)
  [ -n "$OCLJ_OC_JAR" ] || fail "no OpenComputers $PIN dev jar in the Gradle cache.
       Run './gradlew build' once to populate it, or set OCLJ_OC_JAR."
fi
[ -f "$OCLJ_OC_JAR" ] || fail "no such jar: $OCLJ_OC_JAR"
say "jar     = $OCLJ_OC_JAR"

[ -x "$OCLJ_LUAJIT_EXE" ] || command -v "$OCLJ_LUAJIT_EXE" >/dev/null 2>&1 \
  || fail "no luajit at $OCLJ_LUAJIT_EXE (set OCLJ_LUAJIT_EXE; build-native.sh builds one)"

# --------------------------------------------------------------- 1
say "=============== 1. extract OpenComputers' kernel ==============="
mkdir -p "$(dirname "$RAW")" "$OUT_DIR" || fail "cannot create $OUT_DIR"
rm -f "$RAW"
( cd "$(dirname "$RAW")" && unzip -o -q -j "$OCLJ_OC_JAR" 'assets/opencomputers/lua/machine.lua' ) \
  || fail "could not extract assets/opencomputers/lua/machine.lua from the jar"
[ -s "$RAW" ] || fail "extracted machine.lua is empty"
say "    stock kernel = $(wc -c < "$RAW") bytes"

# --------------------------------------------------------------- 2
say "=============== 2. patch ==============="
# patch-machine-lua.lua refuses rather than guessing when an anchor misses, and
# that refusal is the entire safety property here: a kernel that silently lost
# one of its three arm sites would arm the watchdog in two places and leave the
# third on OpenComputers' standing hook, which is not a state anything else
# would detect.
"$OCLJ_LUAJIT_EXE" "$SELF_DIR/patch-machine-lua.lua" "$RAW" "$OUT" \
  || fail "the patcher refused OpenComputers' machine.lua -- an anchor no longer matches.
       This is the expected result of an OpenComputers update; the anchors in
       native/kernel/patch-machine-lua.lua need review against the new kernel."

# --------------------------------------------------------------- 3
say "=============== 3. postflight ==============="
# Assert the OUTPUT, not just the patcher's exit status. Each of these is a
# thing that would otherwise be discovered by a machine failing to boot.
grep -q '_OCLJ_KERNEL = "watchdog"' "$OUT" \
  || fail "patched kernel carries no _OCLJ_KERNEL marker: the harness and the census could not
       tell this kernel from OpenComputers' own, and neither could anyone reading a log"
grep -q '_OCLJ_WATCHDOG' "$OUT" \
  || fail "patched kernel never reads _OCLJ_WATCHDOG: the capture site did not apply"
ARMS=$(grep -c 'watchdog.arm(' "$OUT")
[ "$ARMS" = "3" ] || fail "expected exactly 3 watchdog.arm sites, found $ARMS"
LEFT=$(grep -c 'debug.sethook' "$OUT")
[ "$LEFT" = "3" ] || fail "expected exactly 3 surviving debug.sethook calls (bogomips x2 and the
       immediate-fire arm at machine.lua:47), found $LEFT"

# _ENV, and BOTH sites named separately on purpose.  A single grep for _ENV
# would pass on the one-site fix that was tried first and is WRONG: setting
# only sandbox._ENV = sandbox resolves the name everywhere (every OpenOS env
# chains to _G) while answering with the sandbox instead of the chunk's own
# environment -- silently breaking .install floppies, shell containment and the
# lua REPL's require cache.  So the per-chunk site is asserted on its own, and
# a kernel carrying only the base case must fail this build.
grep -q 'rawset(env, "_ENV", env)' "$OUT"   || fail "patched kernel does not bind _ENV PER CHUNK: only the base case applied, which hands
       every chunk the sandbox rather than its own environment.  That is the wrong fix; see
       THE SECOND CHANGE in patch-machine-lua.lua."
grep -q '^sandbox._ENV = sandbox$' "$OUT"   || fail "patched kernel has no sandbox._ENV base case: chunks the kernel loads directly (the
       BIOS) would see no _ENV at all"
ENVS=$(grep -c '_ENV' "$OUT")
[ "$ENVS" = "4" ] || fail "expected exactly 4 _ENV mentions (1 banner, 2 per-chunk, 1 base case),
       found $ENVS -- OpenComputers may have grown an _ENV of its own"

# SHELL-FILL (docs/shell-fill.md): all three recipe sites, each by name.  A
# kernel that declares the helper but still ships a legacy recipe would be
# refused at LOAD by the serializer ("instead of filling its argument") with
# the computer coming back Stopped -- correct, but this is the cheaper place
# to catch it.
grep -q '^function wrapUserdataInto(proxy, data)$' "$OUT"   || fail "patched kernel has no wrapUserdataInto helper: shell-fill site 9 did not apply"
grep -q 'wrapUserdataInto(proxy, userdata.load(className, nbt))' "$OUT"   || fail "the proxy __persist recipe still returns a fresh table (site 8): the serializer will
       refuse every save holding a userdata with 'instead of filling its argument'"
grep -q 'setmetatable(self, wrappedUserdataMeta)' "$OUT"   || fail "the registry __persist recipe still returns a fresh table (site 7)"
LEGACY=$(grep -c 'return setmetatable({}, wrappedUserdataMeta)' "$OUT")
[ "$LEGACY" = "0" ] || fail "a legacy-shape registry recipe survived patching"

# SNAPSHOT WALKS (docs/forin-iterator-gap.md; os-shape-census.md #1 and #3):
# the two kernel iterators that wrapped next in a closure -- and so restored
# at the wrong key after a save, silently -- are snapshot walks now.  Each site
# is named by its own snapshot loop, and then each BLOCK is cut out between
# OC's neighbouring definitions and searched for a call to next, because a
# block could carry the snapshot loop and still advance with next(...) one
# line lower, which is the exact defect.  An empty cut fails rather than
# passing vacuously.  Last, the whole kernel: OC called next exactly three
# times, all inside these two blocks, so a survivor anywhere is an iterator
# this patch does not know about.
grep -q '^    for k in pairs(list) do$' "$OUT" \
  || fail "component.list (site 10) does not snapshot its keys: a save taken mid-iteration
       restores the walk at the key's position in a DIFFERENT hash layout and visits the
       wrong components with nothing raised (os-shape-census.md #1)"
grep -q '^    for k, v in next, self.fields do$' "$OUT" \
  || fail "componentProxy.__pairs (site 11) does not snapshot its fields phase: pairs(proxy)
       across a save loses and repeats keys (os-shape-census.md #3)"
SITE10=$(sed -n '/^  list = function(filter, exact)$/,/^  methods = function(address)$/p' "$OUT")
[ -n "$SITE10" ] || fail "cannot cut the component.list block out of the patched kernel: its bounds moved"
if printf '%s\n' "$SITE10" | grep -q 'next('; then
  fail "component.list (site 10) still calls next( inside its block: the snapshot loop is there
       but the walk would still restore at the wrong key.  Site 10 did not fully apply"
fi
SITE11=$(sed -n '/^  __pairs = function(self)$/,/^local componentCallback = {$/p' "$OUT")
[ -n "$SITE11" ] || fail "cannot cut the componentProxy.__pairs block out of the patched kernel: its bounds moved"
if printf '%s\n' "$SITE11" | grep -q 'next('; then
  fail "componentProxy.__pairs (site 11) still calls next( inside its block.  Site 11 did not
       fully apply"
fi
NEXTS=$(grep -c 'next(' "$OUT")
[ "$NEXTS" = "0" ] || fail "expected no next( call anywhere in the patched kernel (OC's three were all inside
       sites 10-11), found $NEXTS -- OpenComputers may have grown an iterator this patch does
       not know about, and a closure over next is the shape that restores wrong"

say "    arms=$ARMS  surviving debug.sethook=$LEFT  _ENV sites=2  shell-fill sites=3  snapshot walks=2  next( calls=$NEXTS"
say "    out     = $OUT  ($(wc -c < "$OUT") bytes)"
echo
echo "NEXT: package it."
echo "  ./gradlew build     # stages it at assets/ocluajit/lua/machine.lua"
