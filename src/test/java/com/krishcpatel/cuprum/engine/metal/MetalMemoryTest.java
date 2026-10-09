// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.engine.HostPlatform;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.textures.GpuTexture;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import java.nio.ByteBuffer;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIf("supported")
class MetalMemoryTest {
    static boolean supported() { return HostPlatform.unsupportedReason().isEmpty(); }

    @Test
    void mapsPinStorageAndCloseIdempotentlyEvenAfterBufferClose() {
        try (var device = new MetalDevice()) {
            var buffer = device.createBuffer(() -> "mapped", GpuBuffer.USAGE_MAP_WRITE, 16);
            var mapped = buffer.map(0, 16, false, true);
            buffer.close();
            mapped.data().putInt(42); // Storage survives until the view closes.
            mapped.close();
            mapped.close();
            assertEquals(0, mapped.data().limit());
        }
    }

    @Test
    void transientUploadsRespectSourceAlignmentAndExpireBeforeReuse() {
        try (var device = new MetalDevice()) {
            var source = device.encoder.transientMemory.uploadGpu(List.of(ByteBuffer.wrap(new byte[]{1, 2, 3}), ByteBuffer.wrap(new byte[]{4})), 16, GpuBuffer.USAGE_COPY_SRC);
            var buffer = (MetalResources.Buffer) source.buffer();
            assertEquals(17, source.length());
            assertEquals(4, buffer.bytes(source.offset(), source.length()).get(16));
            var target = device.createBuffer(() -> "copy", GpuBuffer.USAGE_COPY_DST, 17);
            device.encoder.copyToBuffer(source, target.slice());
            device.encoder.submit();
            for (int i=0; i<3; i++) {
                device.encoder.writeToBuffer(target.slice(), ByteBuffer.wrap(new byte[]{5}));
                device.encoder.submit();
            }
            assertTrue(source.buffer().isClosed());
            assertThrows(IllegalStateException.class, () -> device.encoder.copyToBuffer(source, target.slice()));
            var mapped = device.encoder.transientMemory.allocateGpuMapped(16, 16, GpuBuffer.USAGE_COPY_SRC);
            assertThrows(IllegalStateException.class, device.encoder::submit);
            mapped.close();
            device.encoder.submit();
        }
    }

    @Test
    void logicalRangesRejectPaddingAndReadbackOwnsClosedDestination() {
        try (var device = new MetalDevice(); var other = new MetalDevice()) {
            var buffer = device.createBuffer(() -> "logical", GpuBuffer.USAGE_COPY_DST, 4);
            assertThrows(IndexOutOfBoundsException.class, () -> device.encoder.copyToBuffer(new GpuBufferSlice(buffer, 0, 32), buffer.slice()));
            assertThrows(IllegalArgumentException.class, () -> other.encoder.copyToBuffer(buffer.slice(), buffer.slice()));
            var texture = device.createTexture("readback", GpuTexture.USAGE_COPY_SRC | GpuTexture.USAGE_RENDER_ATTACHMENT, GpuFormat.RGBA8_UNORM, 1, 1, 1, 1);
            device.encoder.clearColorTexture(texture, new org.joml.Vector4f(1, 0, 0, 1));
            boolean[] completed = {false};
            device.encoder.copyTextureToBuffer(texture, buffer, 0, () -> completed[0] = true, 0);
            buffer.close();
            device.encoder.sync();
            assertTrue(completed[0]);
            assertTrue(device.getLastDebugMessages().isEmpty());
        }
    }

    @Test
    void generatesMipmapsAndTransfersR8AndHalfFloatTextures() {
        try (var device = new MetalDevice()) {
            int usage = GpuTexture.USAGE_COPY_SRC | GpuTexture.USAGE_COPY_DST | GpuTexture.USAGE_TEXTURE_BINDING;
            var texture = device.createTexture("generated mips", usage, GpuFormat.RGBA8_UNORM, 4, 4, 1, 3);
            byte[] color = new byte[64];
            for (int i=0; i<16; i++) { color[i*4]=80; color[i*4+3]=(byte)255; }
            device.encoder.writeToTexture(texture, ByteBuffer.wrap(color), 0, 0, 0, 0, 4, 4);
            device.encoder.generateMipmaps(texture);
            var target = (MetalResources.Buffer) device.createBuffer(() -> "mip readback", GpuBuffer.USAGE_COPY_DST, 4);
            device.encoder.copyTextureToBuffer(texture, target, 0, () -> {}, 2);
            var red = device.createTexture("R8 odd rows", usage, GpuFormat.R8_UNORM, 3, 2, 1, 1);
            device.encoder.writeToTexture(red, ByteBuffer.wrap(new byte[]{1, 2, 3, 4, 5, 6}), 0, 0, 0, 0, 3, 2);
            var redBuffer = (MetalResources.Buffer) device.createBuffer(() -> "R8 readback", GpuBuffer.USAGE_COPY_DST, 6);
            device.encoder.copyTextureToBuffer(red, redBuffer, 0, () -> {}, 0);
            var half = device.createTexture("half float", usage, GpuFormat.RGBA16_FLOAT, 1, 1, 1, 1);
            byte[] halfData = {0, 60, 0, 56, 0, 52, 0, 60};
            device.encoder.writeToTexture(half, ByteBuffer.wrap(halfData), 0, 0, 0, 0, 1, 1);
            var halfBuffer = (MetalResources.Buffer) device.createBuffer(() -> "half readback", GpuBuffer.USAGE_COPY_DST, 8);
            device.encoder.copyTextureToBuffer(half, halfBuffer, 0, () -> {}, 0);
            device.encoder.sync();
            assertEquals(80, target.bytes(0, 4).get() & 255);
            assertEquals(6, redBuffer.bytes(0, 6).get(5));
            byte[] actual = new byte[8]; halfBuffer.bytes(0, 8).get(actual);
            assertArrayEquals(halfData, actual);
            assertTrue(device.getLastDebugMessages().isEmpty());
        }
    }
}
