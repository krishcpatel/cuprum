// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.krishcpatel.cuprum.bridge.MetalNative;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.device.DeviceFeatures;
import com.mojang.renderpearl.api.device.DeviceInfo;
import com.mojang.renderpearl.api.device.DeviceLimits;
import com.mojang.renderpearl.api.device.DeviceType;
import com.mojang.renderpearl.api.device.HintsAndWorkarounds;
import com.mojang.renderpearl.api.textures.AddressMode;
import com.mojang.renderpearl.api.textures.FilterMode;
import com.mojang.renderpearl.api.textures.GpuSampler;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.GpuDeviceBackend;
import com.mojang.renderpearl.backend.api.GpuSurfaceBackend;
import com.mojang.renderpearl.util.UncheckedAutoCloseable;

import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.OptionalDouble;
import java.util.Set;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

/**
 * Complete RenderPearl device owner. Graphics commands are restricted to the creating render thread.
 */
public final class MetalDevice implements GpuDeviceBackend, AutoCloseable {
    final Thread thread = Thread.currentThread();
    final Set<UncheckedAutoCloseable> resources = Collections.newSetFromMap(new IdentityHashMap<>());
    final MetalEncoder encoder;
    final DeviceInfo info;
    final int mslVersion;
    private final Object compilationLock = new Object();
    private final Set<MetalPipeline> pendingPipelines = java.util.concurrent.ConcurrentHashMap.newKeySet();
    long handle;

    public MetalDevice() {
        MetalNative.load();
        handle = MetalBackendNative.createDevice();
        try {
            mslVersion = MetalBackendNative.mslVersion(handle);
            var metal = CocoaMetalBridge.deviceInfo();
            long[] limits = MetalBackendNative.limits(handle);
            info = new DeviceInfo(metal.name(), "Apple Metal", "Native Metal / MSL " + (mslVersion == 20300 ? "2.3" : "2.4"), true, "Metal", 1,
                    new DeviceLimits(16, (int) limits[1], 16384, limits[0], 0, 8, 65535),
                    new DeviceFeatures(true, true, false, false, true, true, true, false), Set.of("Metal", "MSL"),
                    new HintsAndWorkarounds(false, false, false, false), metal.unifiedMemory() ? DeviceType.INTEGRATED : DeviceType.DISCRETE);
            encoder = new MetalEncoder(this);
        } catch (RuntimeException | Error failure) {
            MetalBackendNative.closeDevice(handle);
            handle = 0;
            throw failure;
        }
    }

    void checkThread() {
        if (Thread.currentThread() != thread)
            throw new IllegalStateException("Metal graphics commands must run on the render thread");
        if (handle == 0) throw new IllegalStateException("Metal device is closed");
    }

    void requireOwned(Object resource) {
        boolean owned = switch (resource) {
            case MetalResources.Buffer buffer -> buffer.owner == this;
            case MetalResources.Texture texture -> texture.owner == this;
            case MetalResources.View view -> view.owner == this;
            case MetalResources.Sampler sampler -> sampler.owner == this;
            case MetalPipeline pipeline -> pipeline.device == this;
            case MetalQueries queries -> queries.device == this;
            default -> false;
        };
        if (!owned) throw new IllegalArgumentException("Resource belongs to another Metal device");
        boolean closed = switch (resource) {
            case GpuBuffer b -> b.isClosed();
            case GpuTexture t -> t.isClosed();
            case GpuTextureView v -> v.isClosed();
            case GpuSampler s -> s.isClosed();
            case MetalPipeline p -> p.isClosed();
            case MetalQueries q -> q.handle == 0;
            default -> false;
        };
        if (closed) throw new IllegalStateException("Metal resource is closed");
    }

    @Override
    public GpuSurfaceBackend createSurface(long window, BooleanSupplier iconified) {
        checkThread();
        return new MetalSurface(this, window, iconified);
    }

    @Override
    public CommandEncoderBackend createCommandEncoder() {
        checkThread();
        if (handle == 0) throw new IllegalStateException("Metal device is closed");
        return encoder;
    }

    @Override
    public GpuSampler createSampler(AddressMode u, AddressMode v, FilterMode min, FilterMode mag, int aniso, OptionalDouble lod) {
        checkThread();
        return new MetalResources.Sampler(this, u, v, min, mag, aniso, lod);
    }

    @Override
    public GpuTexture createTexture(String label, int usage, GpuFormat format, int w, int h, int layers, int mips) {
        checkThread();
        return new MetalResources.Texture(this, label == null ? "" : label, usage, format, w, h, layers, mips);
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture texture, int base, int count) {
        checkThread();
        requireOwned(texture);
        return new MetalResources.View((MetalResources.Texture) texture, base, count);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, long size) {
        checkThread();
        return new MetalResources.Buffer(this, usage, size, false);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, ByteBuffer data) {
        checkThread();
        var b = new MetalResources.Buffer(this, usage, data.remaining(), false);
        b.bytes(0, b.size).put(data.duplicate());
        return b;
    }

    @Override
    public List<String> getLastDebugMessages() {
        checkThread();
        return List.of(MetalBackendNative.debugMessages(handle));
    }

    @Override
    public boolean isDebuggingEnabled() {
        return "1".equals(System.getenv("MTL_DEBUG_LAYER")) || "1".equals(System.getenv("METAL_DEVICE_WRAPPER_TYPE"));
    }

    /** Completed submission count, last GPU duration in ms, and completion interval in ms. */
    public double[] frameMetrics() {
        checkThread();
        return MetalBackendNative.metrics(handle);
    }

    @Override
    public BackendRenderPipeline.Pending compilePipeline(BackendRenderPipeline.CreateInfo createInfo) {
        MetalPipeline pipeline;
        synchronized (compilationLock) {
            if (handle == 0) throw new IllegalStateException("Metal device is closed");
            pipeline = new MetalPipeline(this, createInfo);
            pendingPipelines.add(pipeline);
        }
        return () -> {
            checkThread();
            resources.add(pipeline);
            pendingPipelines.remove(pipeline);
            return pipeline;
        };
    }

    @Override
    public GpuQueryPool createTimestampQueryPool(int size) {
        checkThread();
        return new MetalQueries(this, size);
    }

    @Override
    public long getTimestampCalibrationOffset() {
        checkThread();
        long before = System.nanoTime();
        long gpu = MetalBackendNative.currentGpuTimestamp(handle);
        long after = System.nanoTime();
        return before + (after - before) / 2 - gpu;
    }

    @Override
    public DeviceInfo getDeviceInfo() {
        return info;
    }

    @Override
    public void close() {
        if (handle == 0) return;
        checkThread();
        synchronized (compilationLock) {
            var cleanup = new java.util.ArrayList<Runnable>();
            cleanup.add(encoder::finishPass);
            for (var r : List.copyOf(resources)) if (r instanceof MetalSurface) cleanup.add(r::close);
            cleanup.add(encoder::close);
            for (var r : List.copyOf(resources)) if (!(r instanceof MetalSurface)) cleanup.add(r::close);
            pendingPipelines.forEach(p -> cleanup.add(p::close));
            Throwable failure = null;
            for (var action : cleanup) try { action.run(); }
            catch (RuntimeException | Error error) {
                if (failure == null) failure = error;
                else if (failure != error) failure.addSuppressed(error);
            }
            try { MetalBackendNative.closeDevice(handle); }
            finally { handle = 0; pendingPipelines.clear(); }
            if (failure instanceof RuntimeException error) throw error;
            if (failure instanceof Error error) throw error;
        }
    }
}
