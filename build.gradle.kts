import java.security.MessageDigest

plugins {
    id("com.gtnewhorizons.gtnhconvention")
}

// ---------------------------------------------------------------------------
// PACKAGING THE TWO THINGS THE VM NEEDS
//
// Neither is Java, neither can be built by CI, and each has to land at a path
// that is not ours to choose freely.
//
//   the native      assets/opencomputers/lib/libjnluajit52-<platform><ext>
//   the kernel      assets/ocluajit/lua/machine.lua
//
// THE NATIVE goes in OPENCOMPUTERS' asset namespace because that is where its
// LuaStateFactory resolves a classpath library, and we subclass that factory
// rather than write a loader. We are a guest there; what makes it safe is that
// the FILENAME is ours alone.
//
// THE KERNEL goes in OURS, for the opposite reason. NativeLuaArchitecture loads
// /assets/opencomputers/lua/machine.lua, and a mod cannot win a classpath race
// against OpenComputers for OpenComputers' own resource -- the path would be
// byte-identical, with nothing to distinguish the two. So
// OCLuaJITArchitecture.initialize() lets super() load OC's and then swaps in
// ours, from a path nothing else claims.
//
// NOTHING IS CHECKED IN, and A JAR WITH NEITHER MUST STILL BUILD: GTNH's
// build-and-test runs `./gradlew build` on a clean Ubuntu runner with no C
// toolchain and no Lua interpreter, and has to stay green. The mod degrades
// honestly in both cases -- no native and the architecture is never registered,
// no kernel and it runs on OpenComputers' with the standing hook and says so.
// ---------------------------------------------------------------------------

/**
 * Where built natives are collected. build-native.sh copies every ADDITIVE
 * artifact here, so building on Windows and then on Linux leaves both in place
 * (the filenames differ by platform) and one jar can carry both. Override with
 * -Pocljit.nativesDir=<path>.
 */
val nativesDir: String = (project.findProperty("ocljit.nativesDir") as String?)
    ?: "build/native/dist"

/** Where native/kernel/build-kernel.sh writes the patched machine.lua. */
val kernelDir: String = (project.findProperty("ocljit.kernelDir") as String?)
    ?: "build/native/kernel"

/** Our library family, and the only thing that may be packaged. */
val ourNativeGlob = "libjnluajit52-*"

/**
 * OpenComputers' own library names.
 *
 * THIS IS THE ONE THING THAT MUST NOT HAPPEN. `libjnlua52-*` is the DROP-IN
 * variant -- our LuaJIT wearing OpenComputers' 5.2 name, which the benchmark
 * harness substitutes deliberately. Shipping one inside this jar would put it on
 * the classpath at exactly the path OC's own 5.2 factory searches, so every
 * computer in the world would silently switch VM with no way back. That is the
 * replacement-instead-of-additive failure the whole shipping model exists to
 * prevent, it would be invisible until someone noticed their Lua 5.2 CPUs had
 * changed behaviour, and one mis-set -Pocljit.nativesDir is all it would take.
 */
val ocOwnNativeRegex = "^libjnlua(5[234])?-"

/**
 * Checks both sources, and REPORTS WHAT WILL SHIP, every time.
 *
 * SEPARATE FROM THE COPY ON PURPOSE. This began as doFirst/doLast on the Copy
 * task itself and could not fire in the one case that matters: a Copy whose
 * include patterns match nothing is skipped as NO-SOURCE, actions and all. So
 * pointing the packager straight at the dropin directory -- the misconfiguration
 * the guard exists for -- produced a serene BUILD SUCCESSFUL, staged nothing,
 * and said nothing. A task with no declared inputs or outputs is never
 * up-to-date and never NO-SOURCE, so this one always runs.
 */
val verifyModAssets by tasks.registering {
    group = "verification"
    description = "Refuse to package a library in OpenComputers' own name; report what will ship"

    // Captured at configuration time so the action holds values, not references
    // to this script, which the configuration cache cannot serialize. The paths
    // are resolved against the PROJECT -- a bare File() on a relative path
    // resolves against the daemon's working directory, which is how this guard
    // first managed to inspect nothing at all and pass.
    val nativesName = nativesDir
    val nativesFile = project.file(nativesDir)
    val kernelName = kernelDir
    val kernelFile = project.file("$kernelDir/machine.lua")
    val glob = ourNativeGlob
    val forbidden = ocOwnNativeRegex
    val oursPrefix = ourNativeGlob.removeSuffix("*")
    val serC = project.file("serializer/eris_lj.c")
    val serH = project.file("serializer/eris_lj.h")

    doLast {
        val present = (nativesFile.listFiles() ?: emptyArray()).sortedBy { it.name }
        val trespass = present.filter { Regex(forbidden).containsMatchIn(it.name) }
        if (trespass.isNotEmpty()) {
            throw GradleException(
                "'$nativesName' contains ${trespass.joinToString { it.name }}, which is a library " +
                    "in OpenComputers' OWN name -- the DROPIN variant. Inside this jar it would " +
                    "be found by OC's own LuaStateFactory and replace the 5.2 VM for every " +
                    "computer in the world, silently and with no way back. Point " +
                    "-Pocljit.nativesDir at an additive output instead " +
                    "(OCLJ_VARIANT=additive sh native/build-native.sh)."
            )
        }

        val ours = present.filter { it.name.startsWith(oursPrefix) }
        if (ours.isEmpty()) {
            logger.lifecycle(
                "OC-LuaJIT: no $glob in '$nativesName' -- this jar will carry no native, and the " +
                    "LuaJIT architecture will not be offered at runtime. Build one with " +
                    "'OCLJ_VARIANT=additive sh native/build-native.sh'. (Expected on CI.)"
            )
        } else {
            logger.lifecycle(
                "OC-LuaJIT: packaging ${ours.size} native(s): " +
                    ours.joinToString { "${it.name} (${it.length()} bytes)" }
            )
        }

        // THE NATIVE MUST HAVE BEEN BUILT FROM THE SERIALIZER IN THIS TREE.  The
        // blob fingerprint embeds ERIS_LJ_SERHASH -- the first 8 hex digits of
        // sha1 over serializer/eris_lj.c + eris_lj.h at build time -- so a DLL
        // whose bytes do not contain the hash of the sources AS THEY ARE NOW was
        // built from a different serializer.  That happened on 2026-09-17: two
        // native builds ran the DROPIN variant (the default), the additive DLL in
        // dist/ stayed at a build from the day before, and a jar was assembled
        // that paired this tree's shell-fill kernel with a serializer that calls
        // its recipes with no argument.  Skipped when no native is present (CI);
        // fatal when one is.  Since 2026-10-16 the hash is followed by the
        // VM-features word serializer/eris_lj.c derives from the LuaJIT it was
        // compiled against, and the word's first two tokens are the decided
        // feature set (native/luajit/oclj_features.h): ffi0, FFI compiled out,
        // and lua52, LUA52COMPAT on.  So the fragment is "<hash>|ffi0.lua52.",
        // and a native built with FFI, or from another serializer, is refused.
        // Since 2026-10-17 the word's eighth token names our fork's string.pack
        // (OCLJ_LIB_STRPACK in oclj_features.h), so a native whose string
        // library lacks string.pack/unpack/packsize is refused too.  Since round
        // 3 (2026-10-17) a ninth token, bit64, names what the bitwise operators
        // compute (OCLJ_OPS_BIT64: Lua 5.3.6's 64-bit results, and bytecode
        // version 0x80), and the WHOLE word is compared, not a prefix and a
        // suffix: the middle tokens (gc64, fr2, dn0, le, p64) had gone
        // unchecked, and a word that grows a tenth token must be named here
        // before a jar ships it.  The match runs on through every character a
        // word can hold, so a longer word is a different word, never a match.
        // One word fits every native a jar carries because x86_64 (Windows and
        // Linux) is the only platform we build; aarch64 is parked (roadmap).
        if (ours.isNotEmpty() && serC.isFile && serH.isFile) {
            val md = MessageDigest.getInstance("SHA-1")
            md.update(serC.readBytes())
            md.update(serH.readBytes())
            val want = md.digest().joinToString("") { b -> "%02x".format(b) }.take(8) +
                "|ffi0.lua52.gc64.fr2.dn0.le.p64.pack1.bit64"
            val word = Regex(Regex.escape(want) + "[a-z0-9.]*")
            val stale = ours.filter { f ->
                word.findAll(String(f.readBytes(), Charsets.ISO_8859_1)).none { m -> m.value == want }
            }
            if (stale.isNotEmpty()) {
                throw GradleException(
                    "OC-LuaJIT: " + stale.joinToString { it.name } + " was NOT built from the " +
                        "serializer in this tree with this tree's LuaJIT feature set (expected fingerprint " +
                        "fragment '" + want + "', exactly: the sha1 of serializer/eris_lj.c + eris_lj.h, " +
                        "then the whole VM-features word -- FFI off, LUA52COMPAT, x86_64's layout, " +
                        "string.pack and the 64-bit bitwise operators, native/luajit/oclj_features.h). " +
                        "A jar built now would pair this tree's kernel with a native from a different " +
                        "serializer or LuaJIT feature set. " +
                        "Rebuild it: OCLJ_VARIANT=additive sh native/build-native.sh"
                )
            }
            logger.lifecycle("OC-LuaJIT: native fingerprint matches the serializer sources and the LuaJIT feature set (" + want + ")")
        }

        // THE NATIVE MUST BACK THE CLASS IN THIS TREE.  LuaStateLuaJIT declares four
        // natives of its own: two for the memory accounting's Java boundary
        // (docs/accounting-sync.md), one of them called from its capped constructor,
        // and two for Value disposal (THE VALUE FINALIZER in native/lj52shim.c), the
        // install called from every LuaJITArchitecture.initialize().  A native built
        // before the first two would stop every LuaJIT machine from starting, with an
        // UnsatisfiedLinkError; one built before the last two would start every
        // machine with Value disposal uninstalled -- logged once, then dropped file
        // handles and AE2 iterators leaking until reboot, the defect it exists to
        // remove.  The names are plain ASCII both in a PE export table and in an ELF
        // dynamic string table.
        if (ours.isNotEmpty()) {
            val need = listOf(
                "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljUsedMemory",
                "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljSetTotalMemory",
                "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljInstallValueFinalizer",
                "Java_li_cil_repack_com_naef_jnlua_LuaStateLuaJIT_ocljValueGcCounters",
            )
            val lacking = ours.filter { f ->
                val bytes = String(f.readBytes(), Charsets.ISO_8859_1)
                need.any { !bytes.contains(it) }
            }
            if (lacking.isNotEmpty()) {
                throw GradleException(
                    "OC-LuaJIT: " + lacking.joinToString { it.name } + " does not export all four " +
                        "oclj natives LuaStateLuaJIT declares (ocljUsedMemory, ocljSetTotalMemory, " +
                        "ocljInstallValueFinalizer, ocljValueGcCounters). It was built before them: " +
                        "every LuaJIT machine would fail to start, or would start with Value disposal " +
                        "uninstalled and leak dropped file handles until reboot. Rebuild it: " +
                        "OCLJ_VARIANT=additive sh native/build-native.sh"
                )
            }
            logger.lifecycle("OC-LuaJIT: native exports the four oclj natives LuaStateLuaJIT declares")
        }

        if (!kernelFile.isFile) {
            logger.lifecycle(
                "OC-LuaJIT: no patched kernel in '$kernelName' -- this jar will carry none, so " +
                    "machines will run on OpenComputers' own machine.lua and its standing " +
                    "deadline hook. They will work; the JIT will thrash. Build one with " +
                    "'sh native/kernel/build-kernel.sh'. (Expected on CI.)"
            )
        } else {
            logger.lifecycle("OC-LuaJIT: packaging the patched kernel (${kernelFile.length()} bytes)")
        }
    }
}

val stageModAssets by tasks.registering(Copy::class) {
    group = "build"
    description = "Stage the built native and patched kernel into the jar's resource tree"
    dependsOn(verifyModAssets)

    // The destination is the RESOURCE ROOT, with each asset path expressed
    // inside its own copy spec. That is what lets sourceSets below take this
    // task directly as a srcDir, so every consumer -- processResources, jar,
    // sourcesJar -- picks up the dependency automatically instead of each
    // needing its own dependsOn.
    from(nativesDir) {
        include(ourNativeGlob)
        into("assets/opencomputers/lib")
    }
    from(kernelDir) {
        include("machine.lua")
        into("assets/ocluajit/lua")
    }
    into(layout.buildDirectory.dir("native/resources"))
}

sourceSets {
    main {
        // The TASK, not a path: Gradle then knows this directory is produced by
        // stageModAssets and wires the dependency for every task that reads it.
        resources.srcDir(stageModAssets)
    }
}
