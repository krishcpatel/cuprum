// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.buffers.TransientMemory;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Three completion-fenced shared-memory arenas; no page is reused before its GPU submission completes.
 */
final class MetalTransient implements TransientMemory, AutoCloseable {
    private static final int PAGE_BYTES = 1024 * 1024;
    private final MetalDevice device;
    private final Arena[] arenas = {new Arena(), new Arena(), new Arena()};
    private int index;

    private static final class Arena {
        final List<MetalResources.Buffer> pages = new ArrayList<>();
        int page;
        long offset;
        long completion;
    }

    MetalTransient(MetalDevice device) {
        this.device = device;
    }

    private GpuBufferSlice allocate(long size, long alignment) {
        device.checkThread();
        if (size <= 0 || size > Integer.MAX_VALUE || alignment <= 0 || Long.bitCount(alignment) != 1)
            throw new IllegalArgumentException("Invalid transient size/alignment");
        Arena a = arenas[index];
        long aligned = (a.offset + alignment - 1) & -alignment;
        if (a.page >= a.pages.size() || aligned + size > a.pages.get(a.page).size) {
            if (a.page < a.pages.size()) a.page++;
            a.offset = 0;
            aligned = 0;
            if (a.page >= a.pages.size())
                a.pages.add(new MetalResources.Buffer(device, 1023, Math.max(PAGE_BYTES, size + alignment), true));
            else if (a.pages.get(a.page).size < size) {
                a.pages.get(a.page).close();
                a.pages.set(a.page, new MetalResources.Buffer(device, 1023, Math.max(PAGE_BYTES, size + alignment), true));
            }
        }
        var result = a.pages.get(a.page).slice(aligned, size);
        a.offset = aligned + size;
        return result;
    }

    void rotate(long command) {
        Arena current = arenas[index];
        if (current.completion != 0) MetalBackendNative.release(current.completion);
        current.completion = command;
        index = (index + 1) % arenas.length;
        Arena next = arenas[index];
        if (next.completion != 0) {
            MetalBackendNative.await(next.completion, -1);
            MetalBackendNative.release(next.completion);
            next.completion = 0;
        }
        device.encoder.poll();
        next.page = 0;
        next.offset = 0;
    }

    @Override
    public ByteBuffer allocateCpu(long size, long alignment, long minimum, long element) {
        var slice = allocate(size, alignment);
        return ((MetalResources.Buffer) slice.buffer()).bytes(slice.offset(), slice.length());
    }

    @Override
    public GpuBufferSlice allocateGpu(long size, long alignment, int usage, long minimum, long element) {
        return allocate(size, alignment);
    }

    @Override
    public GpuBufferSlice.MappedView allocateGpuMapped(long size, long alignment, int usage, long minimum, long element) {
        var slice = allocate(size, alignment);
        return new GpuBufferSlice.MappedView(slice, ((MetalResources.Buffer) slice.buffer()).bytes(slice.offset(), slice.length()), () -> {
        });
    }

    @Override
    public GpuBufferSlice.MappedView allocateStaging(long size, long alignment, int usage, long minimum, long element) {
        return allocateGpuMapped(size, alignment, usage, minimum, element);
    }

    @Override
    public GpuBufferSlice uploadGpu(List<ByteBuffer> sources, long alignment, int usage, long minimum, long element) {
        long size = sources.stream().mapToLong(ByteBuffer::remaining).sum();
        var mapped = allocateGpuMapped(size, alignment, usage, minimum, element);
        for (var b : sources) mapped.data().put(b.duplicate());
        return mapped.slice();
    }

    @Override
    public GpuBufferSlice uploadStaging(List<ByteBuffer> sources, long alignment, int usage, long minimum, long element) {
        return uploadGpu(sources, alignment, usage, minimum, element);
    }

    @Override
    public List<GpuBufferSlice> multiUploadGpu(List<ByteBuffer> sources, long alignment, int usage) {
        return sources.stream().map(b -> uploadGpu(b, alignment, usage)).toList();
    }

    @Override
    public List<GpuBufferSlice> multiUploadStaging(List<ByteBuffer> sources, long alignment, int usage) {
        return multiUploadGpu(sources, alignment, usage);
    }

    @Override
    public void close() {
        for (Arena a : arenas) {
            if (a.completion != 0) {
                MetalBackendNative.await(a.completion, -1);
                MetalBackendNative.release(a.completion);
                a.completion = 0;
            }
            a.pages.forEach(MetalResources.Buffer::close);
            a.pages.clear();
        }
    }
}
