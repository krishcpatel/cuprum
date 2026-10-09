// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.commands.RenderPassDescriptor;
import com.mojang.renderpearl.api.pipeline.IndexType;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;
import com.mojang.renderpearl.api.pipeline.UniformType;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import com.mojang.renderpearl.backend.api.RenderPassBackend;
import com.mojang.renderpearl.util.TextureViewAndSampler;
import org.lwjgl.PointerBuffer;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;

final class MetalPass implements RenderPassBackend, AutoCloseable {
    final MetalDevice device;
    final MetalEncoder encoder;
    final RenderPassDescriptor descriptor;
    final int depthFormat;
    MetalPipeline pipeline;
    GpuBuffer indices;
    IndexType indexType = IndexType.INT;
    final List<Long> texelViews = new ArrayList<>();
    private boolean closed;

    private void check() {
        device.checkThread();
        if (closed) throw new IllegalStateException("Metal render pass is closed");
    }

    MetalPass(MetalDevice device, MetalEncoder encoder, RenderPassDescriptor descriptor) {
        this.device = device;
        this.encoder = encoder;
        this.descriptor = descriptor;
        long[] colors = new long[descriptor.colorAttachments().size()];
        double[] clear = new double[colors.length * 5];
        for (int i = 0; i < colors.length; i++) {
            var a = descriptor.colorAttachments().get(i);
            if (a != null) {
                device.requireOwned(a.textureView());
                colors[i] = ((MetalResources.View) a.textureView()).handle();
                if (a.clearValue().isPresent()) {
                    var c = a.clearValue().get();
                    clear[i * 5] = 1;
                    clear[i * 5 + 1] = c.x();
                    clear[i * 5 + 2] = c.y();
                    clear[i * 5 + 3] = c.z();
                    clear[i * 5 + 4] = c.w();
                }
            }
        }
        var depth = descriptor.depthAttachment();
        if (depth != null) device.requireOwned(depth.textureView());
        depthFormat = depth == null ? -1 : depth.textureView().texture().getFormat().ordinal();
        var area = descriptor.renderArea();
        MetalBackendNative.beginPass(device.handle, colors, clear, depth == null ? 0 : ((MetalResources.View) depth.textureView()).handle(), depth == null ? -1 : depth.clearValue().orElse(-1), area.x(), area.y(), area.width(), area.height());
    }

    @Override
    public void setPipeline(BackendRenderPipeline pipeline) {
        check();
        device.requireOwned(pipeline);
        var next = (MetalPipeline) pipeline;
        MetalBackendNative.bindPipeline(device.handle, next.variant(depthFormat));
        this.pipeline = next;
    }

    @Override
    public void setUniform(int index, Object value) {
        check();
        if (pipeline == null) throw new IllegalStateException("Bind a pipeline before uniforms");
        if (index < 0 || index >= pipeline.info.uniforms().size())
            throw new IllegalArgumentException("Uniform binding outside pipeline layout: " + index);
        if (value == null) {
            if (pipeline.info.uniforms().get(index).type() == UniformType.UNIFORM_BUFFER)
                MetalBackendNative.bindBuffer(device.handle, index, 0, 0);
            else MetalBackendNative.bindTexture(device.handle, index, 0, 0);
            return;
        }
        if (value instanceof TextureViewAndSampler pair) {
            device.requireOwned(pair.view());
            device.requireOwned(pair.sampler());
            MetalBackendNative.bindTexture(device.handle, index, ((MetalResources.View) pair.view()).handle(), ((MetalResources.Sampler) pair.sampler()).handle());
        } else if (value instanceof GpuBufferSlice slice) {
            MetalChecks.slice(device, slice);
            var buffer = (MetalResources.Buffer) slice.buffer();
            if (pipeline.info.uniforms().get(index).type() == UniformType.TEXEL_BUFFER) {
                long view = MetalBackendNative.texelView(device.handle, buffer.handle(), slice.offset(), slice.length(), pipeline.info.uniforms().get(index).gpuFormat().ordinal());
                texelViews.add(view);
                MetalBackendNative.bindTexture(device.handle, index, view, 0);
            } else MetalBackendNative.bindBuffer(device.handle, index, buffer.handle(), slice.offset());
        } else throw new IllegalArgumentException("Unsupported Metal uniform value: " + value.getClass());
    }

    @Override
    public void pushConstants(ByteBuffer bytes) {
        check();
        requirePipeline();
        if (bytes.remaining() > pipeline.info.pushConstantsSize()) throw new IllegalArgumentException("Push constants exceed pipeline declaration");
        if (!bytes.hasRemaining()) return;
        var slice = encoder.transientMemory.uploadGpu(bytes, device.info.limits().minUniformOffsetAlignment(), GpuBuffer.USAGE_UNIFORM);
        MetalBackendNative.bindBuffer(device.handle, 15, ((MetalResources.Buffer) slice.buffer()).handle(), slice.offset());
    }

    @Override
    public void setVertexBuffer(int slot, GpuBufferSlice buffer) {
        check();
        if (buffer != null) MetalChecks.slice(device, buffer);
        if (slot < 0 || slot >= 15)
            throw new IllegalArgumentException("Metal exposes 15 vertex slots after reserving constant bindings");
        MetalBackendNative.bindBuffer(device.handle, slot + 16, buffer == null ? 0 : ((MetalResources.Buffer) buffer.buffer()).handle(), buffer == null ? 0 : buffer.offset());
    }

    @Override
    public void setIndexBuffer(GpuBuffer buffer, IndexType type) {
        check();
        if (buffer != null) device.requireOwned(buffer);
        indices = buffer;
        indexType = java.util.Objects.requireNonNull(type);
    }

    private void requirePipeline() {
        if (pipeline == null || pipeline.isClosed()) throw new IllegalStateException("Bind an open Metal pipeline before drawing");
    }

    private void drawArguments(int count, int instances, int first, int baseInstance) {
        requirePipeline();
        if (count < 0 || instances < 0 || first < 0 || baseInstance < 0) throw new IllegalArgumentException("Negative draw count, index or instance");
    }

    private void indirectArguments(GpuBufferSlice commands, int count, int stride) {
        requirePipeline();
        MetalChecks.slice(device, commands);
        if (count < 0 || commands.offset() % 4 != 0) throw new IllegalArgumentException("Invalid indirect draw count or alignment");
        MetalChecks.range(0, (long) count * stride, commands.length());
    }

    private int primitive() {
        return switch (pipeline.info.primitiveTopology()) {
            case POINTS -> 0;
            case DEBUG_LINES -> 1;
            case DEBUG_LINE_STRIP -> 2;
            case TRIANGLE_STRIP -> 4;
            case TRIANGLES, QUADS, LINES, TRIANGLE_FAN -> 3;
        };
    }

    @Override
    public void drawIndexed(int count, int instances, int first, int baseVertex, int baseInstance) {
        check();
        drawArguments(count, instances, first, baseInstance);
        device.requireOwned(indices);
        MetalChecks.range((long) first * indexType.bytes, (long) count * indexType.bytes, indices.size());
        if (count == 0 || instances == 0) return;
        if (pipeline.info.primitiveTopology() == PrimitiveTopology.TRIANGLE_FAN) {
            MetalBackendNative.drawIndexedFan(device.handle, count, instances, ((MetalResources.Buffer) indices).handle(), (long) first * indexType.bytes, indexType.ordinal(), baseVertex, baseInstance);
            return;
        }
        MetalBackendNative.draw(device.handle, primitive(), count, instances, 0, baseInstance, ((MetalResources.Buffer) indices).handle(), (long) first * indexType.bytes, indexType.ordinal(), baseVertex);
    }

    @Override
    public void draw(int count, int instances, int first, int baseInstance) {
        check();
        drawArguments(count, instances, first, baseInstance);
        if (count == 0 || instances == 0) return;
        if (pipeline.info.primitiveTopology() == PrimitiveTopology.TRIANGLE_FAN) {
            if (count < 3) return;
            int elements = Math.multiplyExact(count - 2, 3);
            try (var mapped = encoder.transientMemory.allocateGpuMapped((long) elements * 4, 4, GpuBuffer.USAGE_INDEX)) {
            var data = mapped.data().order(java.nio.ByteOrder.nativeOrder()).asIntBuffer();
            for (int i = 1; i < count - 1; i++) data.put(first).put(first + i).put(first + i + 1);
            MetalBackendNative.draw(device.handle, 3, elements, instances, 0, baseInstance, ((MetalResources.Buffer) mapped.slice().buffer()).handle(), mapped.slice().offset(), 1, 0);
            }
        } else MetalBackendNative.draw(device.handle, primitive(), count, instances, first, baseInstance, 0, 0, 0, 0);
    }

    @Override
    public void multiDrawIndexed(IntBuffer draws, int instances, int firstInstance, int count) {
        check();
        MetalChecks.range(0, (long) count * 3, draws.remaining());
        for (int i = 0; i < count; i++) {
            int b = draws.position() + i * 3;
            drawIndexed(draws.get(b + 1), instances, draws.get(b), draws.get(b + 2), firstInstance);
        }
    }

    @Override
    public void multiDrawIndexed(PointerBuffer offsets, IntBuffer counts, IntBuffer bases, int count) {
        check();
        MetalChecks.range(0, count, offsets.remaining());
        MetalChecks.range(0, count, counts.remaining());
        MetalChecks.range(0, count, bases.remaining());
        for (int i = 0; i < count; i++)
            {
                long offset = offsets.get(offsets.position() + i);
                if (offset < 0 || offset % indexType.bytes != 0) throw new IllegalArgumentException("Invalid index byte offset");
                drawIndexed(counts.get(counts.position() + i), 1, Math.toIntExact(offset / indexType.bytes), bases.get(bases.position() + i), 0);
            }
    }

    @Override
    public void multiDraw(IntBuffer draws, int instances, int base, int count) {
        check();
        MetalChecks.range(0, (long) count * 2, draws.remaining());
        for (int i = 0; i < count; i++)
            draw(draws.get(draws.position() + i * 2 + 1), instances, draws.get(draws.position() + i * 2), base);
    }

    @Override
    public void multiDraw(IntBuffer first, IntBuffer counts, int count) {
        check();
        MetalChecks.range(0, count, first.remaining());
        MetalChecks.range(0, count, counts.remaining());
        for (int i = 0; i < count; i++) draw(counts.get(counts.position() + i), 1, first.get(first.position() + i), 0);
    }

    @Override
    public void drawIndirect(GpuBufferSlice commands, int count) {
        check();
        indirectArguments(commands, count, 16);
        for (int i = 0; i < count; i++) {
            if (pipeline.info.primitiveTopology() == PrimitiveTopology.TRIANGLE_FAN)
                MetalBackendNative.drawIndirectFan(device.handle, ((MetalResources.Buffer) commands.buffer()).handle(), commands.offset() + (long) i * 16, 0, 0);
            else
                MetalBackendNative.drawIndirect(device.handle, primitive(), ((MetalResources.Buffer) commands.buffer()).handle(), commands.offset() + (long) i * 16, 0, 0);
        }
    }

    @Override
    public void drawIndexedIndirect(GpuBufferSlice commands, int count) {
        check();
        indirectArguments(commands, count, 20);
        device.requireOwned(indices);
        for (int i = 0; i < count; i++) {
            if (pipeline.info.primitiveTopology() == PrimitiveTopology.TRIANGLE_FAN)
                MetalBackendNative.drawIndirectFan(device.handle, ((MetalResources.Buffer) commands.buffer()).handle(), commands.offset() + (long) i * 20, ((MetalResources.Buffer) indices).handle(), indexType.ordinal());
            else
                MetalBackendNative.drawIndirect(device.handle, primitive(), ((MetalResources.Buffer) commands.buffer()).handle(), commands.offset() + (long) i * 20, ((MetalResources.Buffer) indices).handle(), indexType.ordinal());
        }
    }

    @Override
    public void enableScissor(int x, int y, int w, int h) {
        check();
        var a = descriptor.renderArea();
        if (w < 0 || h < 0) throw new IllegalArgumentException("Negative scissor extent");
        // Metal requires even an empty rect's origin to lie within the attachment.
        // Use long arithmetic so an offscreen GL-style rectangle cannot overflow.
        long rightEdge = (long) a.x() + a.width(), bottomEdge = (long) a.y() + a.height();
        int left = (int) Math.min(Math.max((long) x, a.x()), rightEdge);
        int top = (int) Math.min(Math.max((long) y, a.y()), bottomEdge);
        long right = Math.min((long) x + w, rightEdge), bottom = Math.min((long) y + h, bottomEdge);
        MetalBackendNative.scissor(device.handle, left, top, (int) Math.max(0, right - left), (int) Math.max(0, bottom - top));
    }

    @Override
    public void disableScissor() {
        check();
        var a = descriptor.renderArea();
        MetalBackendNative.scissor(device.handle, a.x(), a.y(), a.width(), a.height());
    }

    @Override
    public void pushDebugGroup(Supplier<String> label) {
        check();
        MetalBackendNative.debugGroup(device.handle, label.get(), true);
    }

    @Override
    public void popDebugGroup() {
        check();
        MetalBackendNative.debugGroup(device.handle, "", false);
    }

    @Override
    public void writeTimestamp(GpuQueryPool pool, int index) {
        check();
        device.requireOwned(pool);
        ((MetalQueries) pool).write(index);
    }

    @Override
    public void close() {
        device.checkThread();
        if (closed) return;
        closed = true;
        texelViews.forEach(MetalBackendNative::release);
        texelViews.clear();
    }
}
