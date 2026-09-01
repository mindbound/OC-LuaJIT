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
 * Non-persistent by design: a LuaJIT VM cannot be serialized (Eris works only on
 * PUC Lua internals), so this architecture uses the same contract as OC's shipped
 * LuaJ fallback — save() writes nothing, load() reboots a machine that was running.
 * See docs/feasibility.md for the full rationale and docs/watchdog.md for the
 * timeout-enforcement design.
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
