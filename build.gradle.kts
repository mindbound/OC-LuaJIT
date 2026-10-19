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
 * The glibc floor: the newest glibc symbol version a packaged Linux native may
 * need, as x.y of GLIBC_x.y. 2.28 is AlmaLinux/RHEL 8's glibc, the oldest we can
 * build on, load and harness-test, and the release .so is built there (the
 * user's decision, 2026-10-19). A .so needs whatever the glibc it was LINKED
 * against introduced, so one linked on a newer distribution fails to load on
 * every older one, and no test on the build host can show it. build-native.sh
 * holds the same floor (GLIBC_FLOOR) for its own report: change both together.
 */
val glibcFloor = "2.28"

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
    description = "Refuse to package a library in OpenComputers' own name, or a Linux native above " +
        "the glibc floor; report what will ship"

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
    val floor = glibcFloor

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

        // THE LINUX NATIVE MUST LOAD ON THE GLIBC FLOOR (glibcFloor, above).  The
        // dynamic loader refuses a library that needs a symbol version its glibc
        // lacks ("version `GLIBC_2.38' not found"), OpenComputers' factory then
        // fails to load the native, and the LuaJIT architecture is never offered
        // on that machine.  Round 3's .so, linked in Ubuntu 26.04, needed
        // GLIBC_2.38 (fmod, __isoc23_strtoul): it could not load on Ubuntu 22.04,
        // Debian 12 or RHEL 9, and every check on the build host passed it.
        //
        // This reads the needs from the file itself, with no binutils, so it runs
        // the same on Windows and on CI: the ELF64 header, the section headers,
        // the one .gnu.version_r section (SHT_GNU_verneed) with its chain of
        // Elf64_Verneed records, one per library, and each one's Elf64_Vernaux
        // records, one per version, named from the string table the section
        // links to.  The chains are walked as glibc's loader walks them, by
        // vn_next and vna_next to the zero that ends each, and must end exactly
        // where the counts readelf trusts (sh_info, vn_cnt) say: where the two
        // disagree, one reader sees a need the other misses.
        //
        // Every need must be a release version, GLIBC_x.y, at or below the floor.
        // Any other name is refused: GLIBC_PRIVATE binds a library to the one
        // glibc build it was linked against, and GCC_x.y means libgcc_s, which
        // build-native.sh's -static-libgcc keeps out because the host may not
        // have it; a .so this tree builds needs neither.  A file that does not
        // parse is refused too, never passed: not knowing what a native needs is
        // not evidence that it loads.  Every read is bounds-checked, so a short
        // or corrupt file is refused with a reason rather than ending the build
        // in an exception.  A Windows DLL has no symbol versions and is not read.
        // build-native.sh's postflight reads the same needs with readelf.
        for (f in ours.filter { it.name.endsWith(".so") }) {
            val b = f.readBytes()
            val size = b.size.toLong()
            val rebuild = "Build it in AlmaLinux 8, or on any host whose glibc is $floor: " +
                "OCLJ_VARIANT=additive OCLJ_GLIBC_MAX=$floor sh native/build-native.sh"
            fun bad(why: String): Nothing = throw GradleException(
                "OC-LuaJIT: ${f.name} is not an ELF64 shared object this check can read ($why), " +
                    "so nothing shows which glibc it needs, and a native that may not load is not " +
                    "packaged. $rebuild"
            )
            fun at(o: Long, n: Int): Int {
                if (o < 0 || o > size - n) bad("a read at offset $o runs past the end of the file")
                return o.toInt()
            }
            fun u8(o: Long): Int = b[at(o, 1)].toInt() and 0xff
            fun u16(o: Long): Int = u8(o) or (u8(o + 1) shl 8)
            fun u32(o: Long): Long = u16(o).toLong() or (u16(o + 2).toLong() shl 16)
            fun u64(o: Long): Long = u32(o) or (u32(o + 4) shl 32)

            if (size < 64 || u32(0) != 0x464c457fL) bad("no ELF magic")
            if (u8(4) != 2) bad("EI_CLASS ${u8(4)}, not ELFCLASS64")
            if (u8(5) != 1) bad("EI_DATA ${u8(5)}, not little-endian")
            if (u16(16) != 3) bad("e_type ${u16(16)}, not ET_DYN")
            val shoff = u64(0x28)
            val shnum = u16(0x3c)
            if (u16(0x3a) != 64) bad("e_shentsize ${u16(0x3a)}, not 64")
            if (shnum == 0 || shoff < 64 || shoff > size - shnum * 64L) {
                bad("no section header table inside the file")
            }
            fun sh(i: Int): Long = shoff + i * 64L
            fun section(i: Int, what: String): Pair<Long, Long> {
                val o = u64(sh(i) + 24)
                val n = u64(sh(i) + 32)
                if (o < 0 || n < 0 || o > size || n > size - o) bad("$what lies outside the file")
                return o to o + n
            }

            val vr = (0 until shnum).filter { u32(sh(it) + 4) == 0x6ffffffeL }
            if (vr.size != 1) bad("${vr.size} .gnu.version_r sections, not 1")
            val (vrStart, vrEnd) = section(vr[0], ".gnu.version_r")
            val link = u32(sh(vr[0]) + 40)
            if (link < 1 || link >= shnum || u32(sh(link.toInt()) + 4) != 3L) {
                bad(".gnu.version_r links to section $link, which is not a string table")
            }
            val (stStart, stEnd) = section(link.toInt(), "the string table of .gnu.version_r")
            fun name(o: Long): String {
                if (o >= stEnd - stStart) bad("a name at offset $o lies outside its string table")
                var p = stStart + o
                while (p < stEnd && b[p.toInt()] != 0.toByte()) p++
                if (p >= stEnd) bad("a name runs past the end of its string table")
                return String(b, (stStart + o).toInt(), (p - stStart - o).toInt(), Charsets.ISO_8859_1)
            }

            // Elf64_Verneed {u16 version, u16 cnt, u32 file, u32 aux, u32 next} and
            // Elf64_Vernaux {u32 hash, u16 flags, u16 other, u32 name, u32 next}, 16
            // bytes each; the offsets are relative and unsigned, so every step moves
            // forward, and no more records are read than the section can hold.
            val room = (vrEnd - vrStart) / 16
            val libs = u32(sh(vr[0]) + 44)
            if (libs < 1 || libs > room) bad(".gnu.version_r claims $libs libraries in room for $room records")
            val needs = mutableListOf<Pair<String, String>>()
            var read = libs
            var vn = vrStart
            for (k in 1..libs) {
                if (vn > vrEnd - 16) bad("library $k of $libs lies outside .gnu.version_r")
                if (u16(vn) != 1) bad("library $k has Verneed revision ${u16(vn)}, not 1")
                val lib = name(u32(vn + 4))
                val cnt = u16(vn + 2)
                if (cnt < 1) bad("$lib is needed with no version")
                var aux = vn + u32(vn + 8)
                for (j in 1..cnt) {
                    if (++read > room) bad("more version records than .gnu.version_r holds")
                    if (aux > vrEnd - 16) bad("a version needed from $lib lies outside .gnu.version_r")
                    needs.add(lib to name(u32(aux + 8)))
                    val next = u32(aux + 12)
                    if (next == 0L && j < cnt) bad("the versions needed from $lib end after $j of the $cnt vn_cnt claims")
                    if (next != 0L && j == cnt) bad("the versions needed from $lib run on past the $cnt vn_cnt claims")
                    aux += next
                }
                val next = u32(vn + 12)
                if (next == 0L && k < libs) bad("the library chain ends after $k of the $libs sh_info claims")
                if (next != 0L && k == libs) bad("the library chain runs on past the $libs sh_info claims")
                vn += next
            }

            val release = Regex("GLIBC_([0-9]{1,4}(?:[.][0-9]{1,4})+)")
            fun ver(v: String): List<Int>? =
                release.matchEntire(v)?.groupValues?.get(1)?.split('.')?.map { it.toInt() }
            fun cmp(x: List<Int>, y: List<Int>): Int {
                for (i in 0 until maxOf(x.size, y.size)) {
                    val d = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
                    if (d != 0) return d
                }
                return 0
            }
            val odd = needs.filter { ver(it.second) == null }
            if (odd.isNotEmpty()) {
                throw GradleException(
                    "OC-LuaJIT: ${f.name} needs " + odd.joinToString { "${it.second} from ${it.first}" } +
                        (if (odd.size == 1) ", which is not a glibc release version" else
                            ", which are not glibc release versions") +
                        " (GLIBC_x.y), so no glibc floor can say where it loads. GLIBC_PRIVATE " +
                        "binds a library to the one glibc build it was " +
                        "linked against; GCC_x.y is libgcc_s, which build-native.sh's -static-libgcc " +
                        "keeps out. A .so this tree builds needs neither. $rebuild"
                )
            }
            val floorVer = ver("GLIBC_$floor")!!
            val top = needs.map { it.second }.maxWithOrNull(Comparator { x, y -> cmp(ver(x)!!, ver(y)!!) })!!
            val above = needs.filter { cmp(ver(it.second)!!, floorVer) > 0 }
            if (above.isNotEmpty()) {
                val list = above.groupBy({ it.second }, { it.first }).entries
                    .sortedWith(Comparator { x, y -> cmp(ver(y.key)!!, ver(x.key)!!) })
                    .joinToString("; ") { e -> e.key + " from " + e.value.distinct().joinToString() }
                throw GradleException(
                    "OC-LuaJIT: ${f.name} needs $top, above the glibc floor GLIBC_$floor " +
                        "($list). The dynamic loader refuses it wherever glibc is older than " +
                        "$top, and there the LuaJIT architecture would never be offered. It was " +
                        "linked on a newer distribution. $rebuild, and package that build's .so."
                )
            }
            logger.lifecycle("OC-LuaJIT: ${f.name} needs at most $top (the glibc floor is GLIBC_$floor)")
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
