// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.bridge;

import java.nio.ByteBuffer;

/**
 * Typed RenderPearl-to-Metal ABI; all handles are retained native objects.
 */
public final class MetalBackendNative {
    private MetalBackendNative() {
    }

    public static native long createDevice();

    public static native long currentGpuTimestamp(long device);

    public static native long queryPool(long device, int size);

    public static native void timestamp(long device, long pool, int index);

    public static native long queryValue(long pool, int index);

    public static native void debugGroup(long device, String label, boolean push);

    public static native void closeDevice(long device);

    public static native long[] limits(long device);

    public static native long buffer(long device, long length);

    public static native ByteBuffer mapBuffer(long buffer, long offset, int length);

    public static native long texture(long device, int format, int width, int height, int layers, int mips, int usage);

    public static native long textureView(long texture, int mip, int count);

    public static native long texelView(long device, long buffer, long offset, long length, int format);

    public static native long sampler(long device, int u, int v, int min, int mag, int anisotropy, double maxLod);

    public static native void release(long resource);

    public static native long retain(long resource);

    public static native void clearRegion(long device, long color, long depth, float red, float green,
                                          float blue, float alpha, float depthValue, int x, int y, int width, int height);

    public static native long pipeline(long device, String vertex, String vertexEntry, String fragment, String fragmentEntry,
                                       int[] attributes, int[] layouts, int[] colors, int depthFormat, int compare,
                                       boolean depthWrite, boolean cull, boolean wireframe, float bias, float slope);

    public static native void beginPass(long device, long[] colors, double[] clears, long depth, double depthClear,
                                        int x, int y, int width, int height);

    public static native void endPass(long device);

    public static native void bindPipeline(long device, long pipeline);

    public static native void bindBuffer(long device, int slot, long buffer, long offset);

    public static native void bindTexture(long device, int slot, long texture, long sampler);

    public static native void scissor(long device, int x, int y, int width, int height);

    public static native void draw(long device, int primitive, int count, int instances, int first, int baseInstance,
                                   long indexBuffer, long indexOffset, int indexType, int baseVertex);

    public static native void drawIndexedFan(long device, int count, int instances, long indices,
                                             long offset, int indexType, int baseVertex, int baseInstance);

    public static native void drawIndirectFan(long device, long commands, long offset, long indices, int indexType);

    public static native void drawIndirect(long device, int primitive, long commands, long offset,
                                           long indexBuffer, int indexType);

    public static native void copyBuffer(long device, long source, long srcOffset, long target, long dstOffset, long size);

    public static native void bufferTexture(long device, long buffer, long offset, int rowBytes, int imageBytes,
                                            long texture, int mip, int layer, int x, int y, int width, int height, boolean upload);

    public static native void copyTexture(long device, long source, int srcMip, int srcLayer, int sx, int sy,
                                          long target, int dstMip, int dstLayer, int dx, int dy, int width, int height);

    public static native long submit(long device, boolean wait);

    public static native boolean await(long command, long timeout);

    public static native long acquire(long device, long layer, int width, int height, boolean vsync);

    public static native void present(long device);

    public static native void blitDrawable(long device, long source);

    public static native void waitIdle(long device);
}
