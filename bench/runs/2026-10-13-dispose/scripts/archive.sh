#!/bin/sh
# archive.sh -- copy this round's evidence into bench/runs/2026-10-13-dispose (refuses if it exists).
set -u
O=/c/Users/astro/claude-tmp/oclj
REPO=/c/Users/astro/Downloads/OC-LuaJIT
A=$REPO/bench/runs/2026-10-13-dispose
[ -e "$A" ] && { echo "REFUSING: $A exists"; exit 99; }
mkdir -p $A/logs/builds $A/logs/native/win $A/logs/native/win-mirror $A/logs/native/wsl \
         $A/logs/failfirst $A/logs/suite $A/logs/sabotage $A/logs/incident $A/sabotage $A/scripts $A/design
# builds
cp $O/builds/win-additive.log $A/logs/builds/build-additive.log
cp $O/builds/win-dropin.log $A/logs/builds/build-dropin.log
cp $O/builds/wsl-native.log $A/logs/builds/build-linux-additive.log
cp $O/builds/exportgate-proof.txt $O/builds/gradle-build.log $A/logs/builds/
( cd $O && md5sum new-6445f2e4/*/* head-aa12418/*/* ) > $A/logs/builds/natives.md5
md5sum $REPO/build/libs/ocluajit-aa12418-master+aa124186c8-dirty.jar | sed "s|$REPO/||" >> $A/logs/builds/natives.md5
( cd $REPO && md5sum native/lj52shim.c native/lj52shim.h native/build-native.sh native/jnlua/gen-luastate-subclass.py \
    build.gradle.kts src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java \
    src/main/java/io/github/astronfo/ocluajit/arch/LuaJITArchitecture.java test/native/OcljArch.scala \
    test/native/OcljSmoke.scala test/native/smoke-test.sh test/native/negative-control.sh test/native/vgc_test.c \
    test/native/run-vgc.sh ) > $A/logs/builds/sources.md5
# native suites
for t in vgc mem wd penalty negctl; do cp $O/builds/tests1/$t.log $A/logs/native/win/; done
for t in vgc mem wd penalty negctl race security; do printf '%s exit=%s\n' $t "$(cat $O/builds/tests1/$t.rc)"; done > $A/logs/native/win/summary.txt
cp $O/builds/tests1/race.log $A/logs/native/win/race-layout.log
cp $O/builds/tests1/security.log $A/logs/native/win/security-layout.log
cp $O/builds/mirror1/shim.log $O/builds/mirror1/security.log $O/builds/mirror1/race.log \
   $O/builds/mirror1/summary.txt $O/builds/mirror1/objects.md5 $A/logs/native/win-mirror/
cp $O/builds/wslgates1/* $A/logs/native/wsl/
# harness runs: run.log (the JVM's log is cat'ed into it) plus the launcher's records
keep() { d=$A/logs/$1/$2; mkdir -p $d; for f in run.log args.txt env.txt native.md5 exit.txt started.txt finished.txt; do [ -f $O/runs/$2/$f ] && cp $O/runs/$2/$f $d/; done; }
for r in ff-head-additive ff-head-dropin ff-head-stock; do keep failfirst $r; done
for r in fix-additive-on-a fix-dropin-a fix-stock-a fix-additive-off-a fix-additive-sieve-a fix-disposeoff-a fix-bundleoff-b; do keep suite $r; done
for r in sab-onecollect-b sab-countafter-b; do keep sabotage $r; done
for r in fix-bundleoff-a sab-onecollect-a sab-countafter-a; do keep incident $r; done
cp $O/runs/chain-a.txt $O/runs/chain-b.txt $A/logs/
# sabotage sources, as diffs against the tree
( cd $REPO && diff -u test/native/OcljArch.scala $O/sabotage/OcljArch-onecollect.scala ) | sed "s|$O/sabotage/||" > $A/sabotage/onecollect.diff
( cd $REPO && diff -u src/main/java/li/cil/repack/com/naef/jnlua/LuaStateLuaJIT.java $O/sabotage/countafter/LuaStateLuaJIT.java ) | sed "s|$O/sabotage/||" > $A/sabotage/countafter.diff
cp $O/sabotage.py $A/sabotage/
# scripts
cp $O/full.sh $O/chain-fix.sh $O/chain-seq.sh $O/build.sh $O/native-tests.sh $O/mirror-gates.sh \
   $O/exportgate-proof.sh $O/archive.sh $A/scripts/
cp $O/bin/make $A/scripts/make-shim
cp $REPO/build/wsl-gates-vgc.sh $A/scripts/
# design (the understand-phase notes are not archived)
cp $O/design/design.md $O/design/design-v2.md $O/design/implement-and-crosscheck.json $A/design/
mkdir -p $A/design/review
cp $O/design/review/findings.md $A/design/review/
for d in review-java-monitors review-oc-semantics review-skeptic review-tests; do cp -r $O/design/$d $A/design/review/; done
echo archived; du -sh $A
