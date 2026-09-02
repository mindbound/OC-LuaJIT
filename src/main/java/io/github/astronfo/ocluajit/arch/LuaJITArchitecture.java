package io.github.astronfo.ocluajit.arch;

import net.minecraft.item.ItemStack;
import net.minecraft.nbt.NBTTagCompound;

import li.cil.oc.api.Driver;
import li.cil.oc.api.driver.Item;
import li.cil.oc.api.driver.item.Memory;
import li.cil.oc.api.machine.Architecture;
import li.cil.oc.api.machine.ExecutionResult;
import li.cil.oc.api.machine.Machine;

/**
 * LuaJIT-backed OpenComputers architecture.
 *
 * PERSISTENT. The original premise of this class — that a LuaJIT VM cannot be
 * serialized because Eris works only on PUC Lua internals — turned out to be
 * false, and Track P disproved it: serializer/eris_lj.c persists and restores a
 * full LuaJIT state, including suspended coroutines and live for-in loops, with
 * an Eris-compatible API. See serializer/README.md for the contract and what it
 * still refuses, docs/roadmap.md for where the integration stands, and
 * docs/watchdog.md for timeout enforcement.
 *
 * NOTE: this class is still a stub. Nothing below is wired to a VM yet.
 */
@Architecture.Name("LuaJIT")
public class LuaJITArchitecture implements Architecture {

    private final Machine machine;

    /** Total installed RAM in bytes, from the last recomputeMemory call. */
    private volatile double totalMemory = 0;

    private volatile boolean initialized = false;

    public LuaJITArchitecture(final Machine machine) {
        this.machine = machine;
    }

    @Override
    public boolean isInitialized() {
        return initialized;
    }

    @Override
    public boolean recomputeMemory(final Iterable<ItemStack> components) {
        double memory = 0;
        for (final ItemStack stack : components) {
            final Item driver = Driver.driverFor(stack);
            if (driver instanceof Memory) {
                memory += ((Memory) driver).amount(stack) * 1024;
            }
        }
        totalMemory = memory;
        // TODO: apply as the counting-allocator ceiling of the native state
        // (state must be created via lua_newstate with the counting allocator on a
        // GC64 build — installing it after luaL_newstate is unsafe on LuaJIT).
        return memory > 0;
    }

    @Override
    public boolean initialize() {
        // TODO: create the native LuaJIT state over JNI; open base/math/string/table/bit
        // and the jit library (JIT_F_ON is only set by luaopen_jit — CCLuaJIT's mistake),
        // then hide the jit/debug globals from the sandbox; load machine.lua as the
        // kernel coroutine.
        initialized = true;
        return true;
    }

    @Override
    public void close() {
        // TODO: destroy the native state.
        initialized = false;
    }

    @Override
    public void runSynchronized() {
        // TODO: resume the kernel with the pending synchronized-call closure, mirroring
        // NativeLuaArchitecture's closure-yield protocol.
    }

    @Override
    public ExecutionResult runThreaded(final boolean isSynchronizedReturn) {
        // TODO: resume the kernel coroutine under the watchdog deadline and translate
        // its yield into Sleep / SynchronizedCall / Shutdown.
        return new ExecutionResult.Error("The LuaJIT architecture is not implemented yet.");
    }

    @Override
    public void onSignal() {}

    @Override
    public void onConnect() {}

    @Override
    public void load(final NBTTagCompound nbt) {
        if (machine.isRunning()) {
            machine.stop();
            machine.start();
        }
    }

    @Override
    public void save(final NBTTagCompound nbt) {}
}
