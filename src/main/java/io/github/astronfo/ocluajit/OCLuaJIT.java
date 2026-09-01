package io.github.astronfo.ocluajit;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLInitializationEvent;
import io.github.astronfo.ocluajit.arch.LuaJITArchitecture;

@Mod(
    modid = OCLuaJIT.MODID,
    version = Tags.VERSION,
    name = "OC-LuaJIT",
    acceptedMinecraftVersions = "[1.7.10]",
    dependencies = "required-after:OpenComputers;")
public class OCLuaJIT {

    public static final String MODID = "ocluajit";
    public static final Logger LOG = LogManager.getLogger(MODID);

    @Mod.EventHandler
    public void init(FMLInitializationEvent event) {
        // Machine.add must not be called before init (OC api/Machine.java contract).
        // TODO: gate registration on native library availability once the JNI bridge
        // exists (mirror LuaStateFactory: extract to tmp dir, System.load, probe-create
        // a state, register only on success so vanilla architectures keep working).
        li.cil.oc.api.Machine.add(LuaJITArchitecture.class);
        LOG.info("Registered the LuaJIT architecture with OpenComputers.");
    }
}
