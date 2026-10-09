// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.buffers.TransientMemory;
import com.mojang.renderpearl.api.commands.GpuFence;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.commands.RenderPassDescriptor;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.RenderPassBackend;
import org.joml.Vector4fc;

import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

final class MetalEncoder implements CommandEncoderBackend, AutoCloseable {
    final MetalDevice device;
    final MetalTransient transientMemory;
    private MetalPass active;
    private boolean closed;
    private final List<Readback> callbacks = new ArrayList<>();
    private final ArrayDeque<Completion> completions = new ArrayDeque<>();

    record Readback(Runnable work, Runnable cleanup) {
        void complete() { try { work.run(); } finally { cleanup.run(); } }
    }

    record Completion(long command, List<Readback> callbacks) {
    }

    MetalEncoder(MetalDevice device) {
        this.device = device;
        transientMemory = new MetalTransient(device);
    }

    @Override
    public TransientMemory transientMemory() {
        return transientMemory;
    }

    private void idlePass() {
        device.checkThread();
        if (closed) throw new IllegalStateException("Metal encoder is closed");
        if (active != null) throw new IllegalStateException("Operation is invalid inside a Metal render pass");
    }

    void poll() {
        while (!completions.isEmpty()) {
            try {
                if (!MetalBackendNative.await(completions.peek().command, 0)) return;
            } catch (RuntimeException | Error failure) {
                var failed = completions.remove();
                failed.callbacks.forEach(c -> c.cleanup.run());
                MetalBackendNative.release(failed.command);
                throw failure;
            }
            var c = completions.remove();
            try {
                runCallbacks(c.callbacks);
            } finally {
                MetalBackendNative.release(c.command);
            }
        }
    }

    // A failing readback must not skip the remaining owners' cleanup callbacks.
    private static void runCallbacks(List<Readback> work) {
        Throwable failure = null;
        for (Readback callback : work) {
            try {
                callback.complete();
            } catch (RuntimeException | Error error) {
                if (failure == null) failure = error;
                else if (failure != error) failure.addSuppressed(error);
            }
        }
        if (failure instanceof RuntimeException error) throw error;
        if (failure instanceof Error error) throw error;
    }

    void finishPass() {
        device.checkThread();
        if (active != null) submitRenderPass();
    }

    void finishFrame() {
        // Finalize both Java pass ownership and the native encoder at the frame boundary.
        finishPass();
        submit();
    }

    @Override
    public void submit() {
        idlePass();
        poll();
        transientMemory.ensureUnmapped();
        long command = MetalBackendNative.submit(device.handle, false);
        if (command == 0 && callbacks.isEmpty()) return;
        if (!callbacks.isEmpty()) {
            completions.add(new Completion(MetalBackendNative.retain(command), List.copyOf(callbacks)));
            callbacks.clear();
        }
        transientMemory.rotate(command);
    }

    void sync() {
        idlePass();
        try {
            transientMemory.ensureUnmapped();
            long command = MetalBackendNative.submit(device.handle, true);
            transientMemory.rotate(command);
            MetalBackendNative.waitIdle(device.handle);
            poll();
            var work = List.copyOf(callbacks);
            callbacks.clear();
            runCallbacks(work);
        } catch (RuntimeException | Error failure) {
            cancelCallbacks();
            throw failure;
        }
    }

    private void cancelCallbacks() {
        callbacks.forEach(c -> c.cleanup.run());
        callbacks.clear();
    }

    void abortFrame() {
        finishPass();
        cancelCallbacks();
        MetalBackendNative.discardDrawable(device.handle);
    }

    @Override
    public RenderPassBackend createRenderPass(RenderPassDescriptor descriptor) {
        idlePass();
        active = new MetalPass(device, this, descriptor);
        return active;
    }

    @Override
    public void submitRenderPass() {
        if (active == null) throw new IllegalStateException("No render pass active");
        active.close();
        active = null;
        MetalBackendNative.endPass(device.handle);
    }

    @Override
    public void clearColorTexture(GpuTexture texture, Vector4fc color) {
        clear(texture, color, null, -1, 0, 0, texture.getWidth(0), texture.getHeight(0), 0);
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture texture, Vector4fc color, GpuTexture depth, double value) {
        clear(texture, color, depth, value, 0, 0, texture.getWidth(0), texture.getHeight(0), 0);
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture texture, Vector4fc color, GpuTexture depth, double value, int x, int y, int width, int height, int mip) {
        clear(texture, color, depth, value, x, y, width, height, mip);
    }

    @Override
    public void clearDepthTexture(GpuTexture depth, double value) {
        clear(null, null, depth, value, 0, 0, depth.getWidth(0), depth.getHeight(0), 0);
    }

    private void clear(GpuTexture color, Vector4fc clear, GpuTexture depth, double value, int x, int y, int width, int height, int mip) {
        idlePass();
        if (color != null) MetalChecks.region(device, color, mip, 0, x, y, width, height);
        if (depth != null) MetalChecks.region(device, depth, mip, 0, x, y, width, height);
        boolean partial = x != 0 || y != 0 || width != (color == null ? depth : color).getWidth(mip) || height != (color == null ? depth : color).getHeight(mip);
        MetalResources.View cv = color == null ? null : new MetalResources.View((MetalResources.Texture) color, mip, 1);
        MetalResources.View dv = depth == null ? null : new MetalResources.View((MetalResources.Texture) depth, mip, 1);
        try {
            if (partial) {
                MetalBackendNative.clearRegion(device.handle, cv == null ? 0 : cv.handle(), dv == null ? 0 : dv.handle(), clear == null ? 0 : clear.x(), clear == null ? 0 : clear.y(), clear == null ? 0 : clear.z(), clear == null ? 0 : clear.w(), (float) value, x, y, width, height);
                return;
            }
            long[] targets = cv == null ? new long[0] : new long[]{cv.handle()};
            double[] colors = cv == null ? new double[0] : new double[]{1, clear.x(), clear.y(), clear.z(), clear.w()};
            MetalBackendNative.beginPass(device.handle, targets, colors, dv == null ? 0 : dv.handle(), value, x, y, width, height);
            MetalBackendNative.endPass(device.handle);
        } finally {
            if (cv != null) cv.close();
            if (dv != null) dv.close();
        }
    }

    @Override
    public void writeToBuffer(GpuBufferSlice destination, ByteBuffer data) {
        idlePass();
        var stage = transientMemory.uploadStaging(data, 16, 8);
        copyToBuffer(stage, destination.slice(0, data.remaining()));
    }

    @Override
    public void copyToBuffer(GpuBufferSlice source, GpuBufferSlice target) {
        idlePass();
        MetalChecks.slice(device, source);
        MetalChecks.slice(device, target);
        MetalChecks.range(0, source.length(), target.length());
        MetalBackendNative.copyBuffer(device.handle, ((MetalResources.Buffer) source.buffer()).handle(), source.offset(), ((MetalResources.Buffer) target.buffer()).handle(), target.offset(), source.length());
    }

    @Override
    public void writeToTexture(GpuTexture target, ByteBuffer data, int mip, int layer, int x, int y, int width, int height) {
        idlePass();
        MetalChecks.region(device, target, mip, layer, x, y, width, height);
        int bpp = target.getFormat().blockSize();
        int row = MetalChecks.rowBytes(width, bpp);
        int aligned = MetalChecks.paddedRow(row);
        MetalChecks.range(0, (long) row * height, data.remaining());
        try (var mapped = transientMemory.allocateStaging((long) aligned * height, 256, 8)) {
        ByteBuffer src = data.duplicate();
        for (int j = 0; j < height; j++) mapped.data().put(j * aligned, src, src.position() + j * row, row);
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) mapped.slice().buffer()).handle(), mapped.slice().offset(), aligned, aligned * height, ((MetalResources.Texture) target).handle(), mip, layer, x, y, width, height, true);
        }
    }

    @Override
    public void copyBufferToTexture(GpuBufferSlice source, int sx, int sy, int sourceWidth, int sourceHeight, GpuTexture target, int dx, int dy, int width, int height, int mip, int layer) {
        idlePass();
        MetalChecks.slice(device, source);
        MetalChecks.region(device, target, mip, layer, dx, dy, width, height);
        if (sx < 0 || sy < 0 || sourceWidth <= 0 || sourceHeight <= 0 || (long) sx + width > sourceWidth || (long) sy + height > sourceHeight)
            throw new IndexOutOfBoundsException("Source texture rectangle exceeds buffer layout");
        int row = MetalChecks.rowBytes(sourceWidth, target.getFormat().blockSize());
        MetalChecks.range((long) sy * row + (long) sx * target.getFormat().blockSize(), (long) (height - 1) * row + (long) width * target.getFormat().blockSize(), source.length());
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) source.buffer()).handle(), source.offset() + (long) sy * row + (long) sx * target.getFormat().blockSize(), row, Math.multiplyExact(row, height), ((MetalResources.Texture) target).handle(), mip, layer, dx, dy, width, height, true);
    }

    @Override
    public void copyTextureToBuffer(GpuTexture source, GpuBuffer target, long offset, Runnable callback, int mip) {
        copyTextureToBuffer(source, target, offset, callback, mip, 0, 0, source.getWidth(mip), source.getHeight(mip));
    }

    @Override
    public void copyTextureToBuffer(GpuTexture source, GpuBuffer target, long offset, Runnable callback, int mip, int x, int y, int width, int height) {
        idlePass();
        MetalChecks.region(device, source, mip, 0, x, y, width, height);
        device.requireOwned(target);
        int row = MetalChecks.rowBytes(width, source.getFormat().blockSize()), aligned = MetalChecks.paddedRow(row);
        MetalChecks.range(offset, (long) row * height, target.size());
        var staging = transientMemory.allocateGpu((long) aligned * height, 256, 3);
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) staging.buffer()).handle(), staging.offset(), aligned, aligned * height, ((MetalResources.Texture) source).handle(), mip, 0, x, y, width, height, false);
        long targetPin = MetalBackendNative.retain(((MetalResources.Buffer) target).handle());
        callbacks.add(new Readback(() -> {
            ByteBuffer src = ((MetalResources.Buffer) staging.buffer()).bytes(staging.offset(), staging.length());
            ByteBuffer dst = MetalBackendNative.mapBuffer(targetPin, offset, Math.toIntExact((long) row * height));
            for (int j = 0; j < height; j++) dst.put(j * row, src, j * aligned, row);
            callback.run();
        }, () -> MetalBackendNative.release(targetPin)));
    }

    @Override
    public void copyTextureToTexture(GpuTexture source, GpuTexture target, int mip, int dx, int dy, int sx, int sy, int width, int height) {
        idlePass();
        MetalChecks.region(device, source, mip, 0, sx, sy, width, height);
        MetalChecks.region(device, target, mip, 0, dx, dy, width, height);
        MetalBackendNative.copyTexture(device.handle, ((MetalResources.Texture) source).handle(), mip, 0, sx, sy, ((MetalResources.Texture) target).handle(), mip, 0, dx, dy, width, height);
    }

    void generateMipmaps(GpuTexture texture) {
        idlePass();
        device.requireOwned(texture);
        MetalBackendNative.generateMipmaps(device.handle, ((MetalResources.Texture) texture).handle());
    }

    @Override
    public GpuFence createFence() {
        idlePass();
        transientMemory.ensureUnmapped();
        long command = MetalBackendNative.submit(device.handle, false);
        return new GpuFence() {
            long h = command;

            public boolean awaitCompletion(long timeout) {
                return h == 0 || MetalBackendNative.await(h, timeout);
            }

            public void close() {
                if (h != 0) {
                    MetalBackendNative.release(h);
                    h = 0;
                }
            }
        };
    }

    @Override
    public void writeTimestamp(GpuQueryPool pool, int index) {
        idlePass();
        device.requireOwned(pool);
        ((MetalQueries) pool).write(index);
    }

    @Override
    public void close() {
        if (closed) return;
        device.checkThread();
        finishPass();
        try { sync(); }
        finally {
            closed = true;
            try { transientMemory.close(); }
            finally {
                cancelCallbacks();
                while (!completions.isEmpty()) {
                    var completion = completions.remove();
                    completion.callbacks.forEach(c -> c.cleanup.run());
                    MetalBackendNative.release(completion.command);
                }
            }
        }
    }
}
