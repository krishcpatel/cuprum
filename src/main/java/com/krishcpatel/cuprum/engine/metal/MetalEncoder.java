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
    private final List<Runnable> callbacks = new ArrayList<>();
    private final ArrayDeque<Completion> completions = new ArrayDeque<>();

    record Completion(long command, List<Runnable> callbacks) {
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
        if (active != null) throw new IllegalStateException("Operation is invalid inside a Metal render pass");
    }

    void poll() {
        while (!completions.isEmpty() && MetalBackendNative.await(completions.peek().command, 0)) {
            var c = completions.remove();
            c.callbacks.forEach(Runnable::run);
            MetalBackendNative.release(c.command);
        }
    }

    @Override
    public void submit() {
        idlePass();
        poll();
        long command = MetalBackendNative.submit(device.handle, false);
        if (!callbacks.isEmpty()) {
            completions.add(new Completion(MetalBackendNative.retain(command), List.copyOf(callbacks)));
            callbacks.clear();
        }
        transientMemory.rotate(command);
    }

    void sync() {
        idlePass();
        long command = MetalBackendNative.submit(device.handle, true);
        transientMemory.rotate(command);
        MetalBackendNative.waitIdle(device.handle);
        poll();
        callbacks.forEach(Runnable::run);
        callbacks.clear();
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
        MetalBackendNative.copyBuffer(device.handle, ((MetalResources.Buffer) source.buffer()).handle(), source.offset(), ((MetalResources.Buffer) target.buffer()).handle(), target.offset(), source.length());
    }

    @Override
    public void writeToTexture(GpuTexture target, ByteBuffer data, int mip, int layer, int x, int y, int width, int height) {
        idlePass();
        int bpp = target.getFormat().blockSize();
        int row = width * bpp;
        int aligned = (row + 255) & -256;
        var mapped = transientMemory.allocateStaging((long) aligned * height, 256, 8);
        ByteBuffer src = data.duplicate();
        for (int j = 0; j < height; j++) mapped.data().put(j * aligned, src, src.position() + j * row, row);
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) mapped.slice().buffer()).handle(), mapped.slice().offset(), aligned, aligned * height, ((MetalResources.Texture) target).handle(), mip, layer, x, y, width, height, true);
    }

    @Override
    public void copyBufferToTexture(GpuBufferSlice source, int sx, int sy, int sourceWidth, int sourceHeight, GpuTexture target, int dx, int dy, int width, int height, int mip, int layer) {
        idlePass();
        int row = sourceWidth * target.getFormat().blockSize();
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) source.buffer()).handle(), source.offset() + (long) sy * row + (long) sx * target.getFormat().blockSize(), row, row * sourceHeight, ((MetalResources.Texture) target).handle(), mip, layer, dx, dy, width, height, true);
    }

    @Override
    public void copyTextureToBuffer(GpuTexture source, GpuBuffer target, long offset, Runnable callback, int mip) {
        copyTextureToBuffer(source, target, offset, callback, mip, 0, 0, source.getWidth(mip), source.getHeight(mip));
    }

    @Override
    public void copyTextureToBuffer(GpuTexture source, GpuBuffer target, long offset, Runnable callback, int mip, int x, int y, int width, int height) {
        idlePass();
        int row = width * source.getFormat().blockSize(), aligned = (row + 255) & -256;
        var staging = transientMemory.allocateGpu((long) aligned * height, 256, 3);
        MetalBackendNative.bufferTexture(device.handle, ((MetalResources.Buffer) staging.buffer()).handle(), staging.offset(), aligned, aligned * height, ((MetalResources.Texture) source).handle(), mip, 0, x, y, width, height, false);
        callbacks.add(() -> {
            ByteBuffer src = ((MetalResources.Buffer) staging.buffer()).bytes(staging.offset(), staging.length());
            ByteBuffer dst = ((MetalResources.Buffer) target).bytes(offset, (long) row * height);
            for (int j = 0; j < height; j++) dst.put(j * row, src, j * aligned, row);
            callback.run();
        });
    }

    @Override
    public void copyTextureToTexture(GpuTexture source, GpuTexture target, int mip, int dx, int dy, int sx, int sy, int width, int height) {
        idlePass();
        MetalBackendNative.copyTexture(device.handle, ((MetalResources.Texture) source).handle(), mip, 0, sx, sy, ((MetalResources.Texture) target).handle(), mip, 0, dx, dy, width, height);
    }

    @Override
    public GpuFence createFence() {
        idlePass();
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
        ((MetalQueries) pool).write(index);
    }

    @Override
    public void close() {
        sync();
        transientMemory.close();
    }
}
