// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.commands.GpuQueryPool;

import java.util.OptionalLong;

/**
 * GPU timestamp samples become readable only after their command buffer completes.
 */
final class MetalQueries implements GpuQueryPool {
    final MetalDevice device;
    private final int size;
    private long handle;

    MetalQueries(MetalDevice device, int size) {
        if (size <= 0) throw new IllegalArgumentException("Query pool size must be positive");
        this.device = device;
        this.size = size;
        handle = MetalBackendNative.queryPool(device.handle, size);
        device.resources.add(this);
    }

    private void check(int index) {
        device.checkThread();
        if (handle == 0) throw new IllegalStateException("Query pool is closed");
        if (index < 0 || index >= size) throw new IndexOutOfBoundsException(index);
    }

    void write(int index) {
        check(index);
        MetalBackendNative.timestamp(device.handle, handle, index);
    }

    @Override
    public int size() {
        return size;
    }

    @Override
    public OptionalLong getValue(int index) {
        check(index);
        long value = MetalBackendNative.queryValue(handle, index);
        return value < 0 ? OptionalLong.empty() : OptionalLong.of(value);
    }

    @Override
    public OptionalLong[] getValues(int index, int count) {
        if (count < 0 || index < 0 || index > size - count) throw new IndexOutOfBoundsException();
        OptionalLong[] result = new OptionalLong[count];
        for (int i = 0; i < count; i++) result[i] = getValue(index + i);
        return result;
    }

    @Override
    public void close() {
        device.checkThread();
        if (handle != 0) {
            MetalBackendNative.release(handle);
            handle = 0;
            device.resources.remove(this);
        }
    }
}
