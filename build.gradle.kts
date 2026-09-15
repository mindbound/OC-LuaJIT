
plugins {
    id("com.gtnewhorizons.gtnhconvention")
}

// ---------------------------------------------------------------------------
// NATIVE PACKAGING
//
// The VM has to reach the player inside this jar, and WHERE it goes is not ours
// to choose. OpenComputers' LuaStateFactory resolves a library as a classpath
// resource at /assets/<OC's resource domain>/lib/<libraryName>, computing that
// name privately from version(). We subclass that factory rather than write our
// own loader -- see docs/research/shipping-model.md -- so the file must land at
//
//     assets/opencomputers/lib/libjnluajit52-<platform><ext>
//
// inside OUR jar. That is OpenComputers' asset namespace and we are a guest in
// it; what makes it safe is that the FILENAME is ours alone.
//
// NOTHING IS CHECKED IN. Binaries do not belong in git, and the natives are
// built by native/build-native.sh, which needs a LuaJIT tree and a C toolchain
// that CI does not have. So this stages from the build directory instead, and
// A JAR WITH NO NATIVE MUST STILL BUILD: GTNH's build-and-test runs
// `./gradlew build` on a clean Ubuntu runner and has to stay green. The mod
// already behaves correctly in that case -- OCLuaJIT.init logs which filename
// it wanted and registers no architecture, leaving OpenComputers' own untouched.
// ---------------------------------------------------------------------------

/**
 * Where built natives are collected. build-native.sh copies every ADDITIVE
 * artifact here, so building on Windows and then on Linux leaves both in place
 * (the filenames differ by platform) and one jar can carry both.
 * Override with -Pocljit.nativesDir=<path>.
 */
val nativesDir: String = (project.findProperty("ocljit.nativesDir") as String?)
    ?: "build/native/dist"

/** Our library family, and the only thing that may be packaged. */
val ourNativeGlob = "libjnluajit52-*"

/**
 * OpenComputers' own library names.
 *
 * THIS IS THE ONE THING THAT MUST NOT HAPPEN. `libjnlua52-*` is the DROP-IN
 * variant -- our LuaJIT wearing OpenComputers' 5.2 name, which the benchmark
 * harness substitutes deliberately. Shipping one inside this jar would put it
 * on the classpath at exactly the path OC's own 5.2 factory searches, so every
 * computer in the world would silently switch VM with no way back. That is the
 * replacement-instead-of-additive failure the whole shipping model exists to
 * prevent, it would be invisible until someone noticed their Lua 5.2 CPUs had
 * changed behaviour, and one mis-set -Pocljit.nativesDir is all it would take.
 */
val ocOwnNativeRegex = "^libjnlua(5[234])?-"

/**
 * Checks the native source directory, and REPORTS WHAT IT FOUND, every time.
 *
 * SEPARATE FROM THE COPY ON PURPOSE. This began as doFirst/doLast on the Copy
 * task itself and could not fire in the one case that matters: a Copy whose
 * include pattern matches nothing is skipped as NO-SOURCE, actions and all. So
 * pointing the packager straight at the dropin directory -- the misconfiguration
 * the guard exists for -- produced a serene BUILD SUCCESSFUL, staged nothing,
 * and said nothing. A task with no declared inputs or outputs is never
 * up-to-date and never NO-SOURCE, so this one always runs.
 */
val verifyNativesSource by tasks.registering {
    group = "verification"
    description = "Refuse to package a library in OpenComputers' own name; report what will ship"

    // Captured at configuration time so the action holds values, not references
    // to this script, which the configuration cache cannot serialize.
    val sourceName = nativesDir
    val sourceDirFile = project.file(nativesDir)
    val glob = ourNativeGlob
    val forbidden = ocOwnNativeRegex
    val oursPrefix = ourNativeGlob.removeSuffix("*")

    doLast {
        val present = (sourceDirFile.listFiles() ?: emptyArray()).sortedBy { it.name }
        val trespass = present.filter { Regex(forbidden).containsMatchIn(it.name) }
        if (trespass.isNotEmpty()) {
            throw GradleException(
                "'$sourceName' contains ${trespass.joinToString { it.name }}, which is a library in " +
                    "OpenComputers' OWN name -- the DROPIN variant. Inside this jar it would be " +
                    "found by OC's own LuaStateFactory and replace the 5.2 VM for every computer " +
                    "in the world, silently and with no way back. Point -Pocljit.nativesDir at an " +
                    "additive output instead (OCLJ_VARIANT=additive sh native/build-native.sh)."
            )
        }

        val ours = present.filter { it.name.startsWith(oursPrefix) }
        if (ours.isEmpty()) {
            logger.lifecycle(
                "OC-LuaJIT: no $glob in '$sourceName' -- this jar will carry no native, and the " +
                    "LuaJIT architecture will not be offered at runtime. Build one with " +
                    "'OCLJ_VARIANT=additive sh native/build-native.sh'. (Expected on CI.)"
            )
        } else {
            logger.lifecycle(
                "OC-LuaJIT: packaging ${ours.size} native(s): " +
                    ours.joinToString { "${it.name} (${it.length()} bytes)" }
            )
        }
    }
}

val stageNatives by tasks.registering(Copy::class) {
    group = "build"
    description = "Stage built LuaJIT natives into the jar's resource tree"
    dependsOn(verifyNativesSource)

    // The destination is the RESOURCE ROOT, with the asset path expressed
    // inside the copy spec. That is what lets sourceSets below take this task
    // directly as a srcDir, so every consumer -- processResources, jar,
    // sourcesJar -- picks up the dependency automatically instead of each
    // needing its own dependsOn.
    from(nativesDir) {
        include(ourNativeGlob)
        into("assets/opencomputers/lib")
    }
    into(layout.buildDirectory.dir("native/resources"))
}

sourceSets {
    main {
        // The TASK, not a path: Gradle then knows this directory is produced by
        // stageNatives and wires the dependency for every task that reads it.
        resources.srcDir(stageNatives)
    }
}
