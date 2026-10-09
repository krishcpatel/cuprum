// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.engine.HostPlatform;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.textures.GpuTexture;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;

@EnabledIf("supported")
class MetalEncoderTest {
    static boolean supported() {
        return HostPlatform.unsupportedReason().isEmpty();
    }

    @Test
    void uploadArenasSurviveRepeatedRotationAndUnalignedTextureReadback() {
        try (var device = new MetalDevice()) {
            var texture = device.createTexture("odd-stride upload test", GpuTexture.USAGE_COPY_DST | GpuTexture.USAGE_COPY_SRC,
                    GpuFormat.RGBA8_UNORM, 7, 3, 1, 1);
            AtomicInteger callbacks = new AtomicInteger();
            for (int frame = 0; frame < 12; frame++) {
                int expected = 17 + frame;
                ByteBuffer pixels = ByteBuffer.allocateDirect(7 * 3 * 4);
                for (int i = 0; i < 21; i++) pixels.put((byte) expected).put((byte) 110).put((byte) 60).put((byte) 255);
                pixels.flip();
                var readback = device.createBuffer(() -> "texture readback", GpuBuffer.USAGE_COPY_DST | GpuBuffer.USAGE_MAP_READ, pixels.remaining());
                device.encoder.writeToTexture(texture, pixels, 0, 0, 0, 0, 7, 3);
                device.encoder.copyTextureToBuffer(texture, readback, 0, () -> {
                    var bytes = ((MetalResources.Buffer) readback).bytes(0, readback.size());
                    for (int i = 0; i < 21; i++) {
                        assertEquals(expected, bytes.get(i * 4) & 255);
                        assertEquals(110, bytes.get(i * 4 + 1) & 255);
                        assertEquals(60, bytes.get(i * 4 + 2) & 255);
                        assertEquals(255, bytes.get(i * 4 + 3) & 255);
                    }
                    callbacks.incrementAndGet();
                    readback.close();
                }, 0);
                device.encoder.submit();
            }
            device.encoder.sync();
            assertEquals(12, callbacks.get());
        }
    }
}
