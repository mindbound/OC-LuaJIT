package io.github.astronfo.ocluajit;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLInitializationEvent;
import io.github.astronfo.ocluajit.arch.LuaJITArchitecture;
import io.github.astronfo.ocluajit.arch.LuaJITStateFactory;

@Mod(
    modid = OCLuaJIT.MODID,
    version = Tags.VERSION,
    name = "OC-LuaJIT",
    acceptedMinecraftVersions = "[1.7.10]",
    dependencies = "required-after:OpenComputers;")
public class OCLuaJIT {

    public static final String MODID = "ocluajit";
    public static final Logger LOG = LogManager.getLogger(MODID);

    /**
     * Register the architecture, but only if the VM behind it actually loaded.
     *
     * WHY init RATHER THAN preInit: api/Machine.java forbids Machine.add before
     * init. That ordering is also what makes us safe to install -- OpenComputers
     * registers its own three in preInit, so it keeps the first slot and we can
     * never become the silent default for an existing world.
     *
     * WHY THE GATE: a registered architecture a player can select but whose
     * machines never start is worse than an absent one -- the computer simply
     * refuses to boot with "native libraries not available", a message about the
     * MACHINE that says nothing about which file was missing. init() resolves and
     * loads the library; isAvailable() reports whether that worked. On failure we
     * say so once, with the filename, and register nothing, so OpenComputers'
     * own architectures are all the player sees.
     */
    @Mod.EventHandler
    public void init(FMLInitializationEvent event) {
        // DO NOT CALL init() HERE. Touching INSTANCE is already the load:
        // OpenComputers' LuaStateFactory calls init() from its own CONSTRUCTOR
        // (verified in the pinned dev jar, invokevirtual init:()V at offset 293),
        // so class initialization does it for us. A second call crashes the game.
        // init() keeps tmpLibFile in a LOCAL assigned at exactly two points, both
        // inside branches a second call skips -- the forced-path hit, and the
        // extraction block guarded by currentLib.isEmpty, where currentLib is an
        // INSTANCE field still holding the first call's result. It then logs
        // "Found a compatible native library: tmpLibFile.getName" unconditionally,
        // dereferencing null; its catch block dereferences the same null again and
        // is not itself covered by the exception table, so the NPE escapes into FML
        // as a hard crash. Note the inversion that makes this so easy to miss: with
        // the native ABSENT the second call returns early and nothing happens, so it
        // crashes only where the mod would otherwise work.
        //
        // ocelot-brain's port does NOT call init() from its constructor -- its
        // init() takes a Path and is driven by Ocelot.initialize -- which is why
        // test/native/OcljArch.scala must call it explicitly and why the harness
        // could never have caught this.
        if (!LuaJITStateFactory.INSTANCE.isAvailable()) {
            LOG.warn(
                "No OC-LuaJIT native for this platform: OpenComputers' loader found no "
                    + "libjnluajit52-<platform> on the classpath under /assets/opencomputers/lib/ "
                    + "and debug.forceNativeLibPathFirst did not supply one. The LuaJIT "
                    + "architecture will NOT be offered; OpenComputers' own are unaffected.");
            return;
        }
        li.cil.oc.api.Machine.add(LuaJITArchitecture.class);
        LOG.info("Registered the LuaJIT architecture with OpenComputers.");
    }
}
