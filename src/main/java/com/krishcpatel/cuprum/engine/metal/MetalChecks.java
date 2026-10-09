// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.textures.GpuTexture;

final class MetalChecks {
    private MetalChecks() { }

    static void range(long offset, long length, long capacity) {
        if (offset < 0 || length < 0 || offset > capacity || length > capacity - offset)
            throw new IndexOutOfBoundsException("Metal range exceeds logical allocation");
    }

    static void slice(MetalDevice device, GpuBufferSlice slice) {
        device.requireOwned(slice.buffer());
        range(slice.offset(), slice.length(), slice.buffer().size());
    }

    static void region(MetalDevice device, GpuTexture texture, int mip, int layer, int x, int y, int w, int h) {
        device.requireOwned(texture);
        if (mip < 0 || mip >= texture.getMipLevels() || layer < 0 || layer >= texture.getDepthOrLayers()
                || x < 0 || y < 0 || w < 0 || h < 0
                || (long) x + w > texture.getWidth(mip) || (long) y + h > texture.getHeight(mip))
            throw new IndexOutOfBoundsException("Metal texture mip, layer or rectangle exceeds allocation");
    }

    static int rowBytes(int width, int bytesPerPixel) {
        if (width <= 0) throw new IllegalArgumentException("Texture transfer width must be positive");
        return Math.multiplyExact(width, bytesPerPixel);
    }

    static int paddedRow(int row) {
        return Math.addExact(row, 255) & -256;
    }
}
