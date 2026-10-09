// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.bridge;

import com.krishcpatel.cuprum.engine.HostPlatform;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIf("supported")
class MetalSafetyTest {
    static boolean supported() { return HostPlatform.unsupportedReason().isEmpty(); }

    @Test
    void sharesPSOsAcrossIndependentRasterAndDepthStateAndPrewarmsClears() {
        MetalNative.load();
        long device = MetalBackendNative.createDevice();
        String vertex = "#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint i [[vertex_id]]) { return float4(i,0,0,1); }";
        String fragment = "#include <metal_stdlib>\nusing namespace metal; fragment float4 f() { return float4(1); }";
        int[] color = {6, 15, 0, 0, 0, 0, 0, 0, 0};
        long first = 0, second = 0, texture = 0;
        try {
            long[] startup = MetalBackendNative.cacheStats(device);
            texture = MetalBackendNative.texture(device, 6, 4, 4, 1, 1, 14);
            assertArrayEquals(startup, MetalBackendNative.cacheStats(device), "Vanilla clear formats must be warm before texture creation");
            first = MetalBackendNative.pipeline(device, vertex, "v", fragment, "f", new int[0], new int[0], color, 51, 0, false, false, false, 0, 0);
            long[] prepared = MetalBackendNative.cacheStats(device);
            second = MetalBackendNative.pipeline(device, vertex, "v", fragment, "f", new int[0], new int[0], color, 51, 1, true, true, true, 1, 2);
            assertNotEquals(first, second, "Dynamic depth/raster state wrappers remain independent");
            assertArrayEquals(prepared, MetalBackendNative.cacheStats(device), "Dynamic state differences must not duplicate native PSOs");
            MetalBackendNative.clearRegion(device, texture, 0, 1, 0, 0, 1, 0, 0, 0, 2, 2);
            assertArrayEquals(prepared, MetalBackendNative.cacheStats(device), "First partial clear must not compile shaders");
        } finally {
            MetalBackendNative.release(texture);
            MetalBackendNative.release(second);
            MetalBackendNative.release(first);
            MetalBackendNative.closeDevice(device);
        }
    }

    @Test
    void rejectsForgedStaleMistypedAndForeignHandlesWithoutCrashing() {
        MetalNative.load();
        long first = MetalBackendNative.createDevice(), second = MetalBackendNative.createDevice();
        long buffer = MetalBackendNative.buffer(first, 256);
        try {
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.mapBuffer(Long.MAX_VALUE, 0, 1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.mapBuffer(first, 0, 1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.copyBuffer(second, buffer, 0, buffer, 128, 16));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.mapBuffer(buffer, Long.MAX_VALUE, 16));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.buffer(first, -1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.texture(first, 6, -1, 4, 1, 1, 8));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.pipeline(first, "", "v", "", "f",
                    new int[]{0}, new int[0], new int[0], -1, 0, false, false, false, 0, 0));
            MetalBackendNative.mapBuffer(buffer, 0, 1).put((byte) 73);
            assertEquals(73, MetalBackendNative.mapBuffer(buffer, 0, 1).get());
            MetalBackendNative.release(buffer);
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.mapBuffer(buffer, 0, 1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.release(buffer));
        } finally {
            MetalBackendNative.closeDevice(second);
            MetalBackendNative.closeDevice(first);
        }
    }

    @Test
    void rejectsBadTextureRegionsAndQueriesThenCompletesValidCommands() {
        MetalNative.load();
        long device = MetalBackendNative.createDevice();
        long texture = MetalBackendNative.texture(device, 6, 4, 4, 1, 3, 14);
        long buffer = MetalBackendNative.buffer(device, 1024);
        long query = MetalBackendNative.queryPool(device, 1);
        try {
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.textureView(texture, 2, 2));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.bufferTexture(device, buffer, 0, 256, 1024, texture, 0, 0, 3, 0, 4, 4, true));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.timestamp(device, query, 1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.queryValue(query, -1));
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.beginPass(device, new long[]{texture}, new double[4], 0, -1, 0, 0, 4, 4));
            MetalBackendNative.beginPass(device, new long[]{texture}, new double[]{1, 1, 0, 0, 1}, 0, -1, 0, 0, 4, 4);
            assertThrows(IllegalStateException.class, () -> MetalBackendNative.bindBuffer(device, 31, buffer, 0));
            MetalBackendNative.endPass(device);
            MetalBackendNative.bufferTexture(device, buffer, 0, 256, 1024, texture, 0, 0, 0, 0, 4, 4, false);
            long command = MetalBackendNative.submit(device, true);
            try { assertEquals(255, MetalBackendNative.mapBuffer(buffer, 0, 1).get() & 255); }
            finally { MetalBackendNative.release(command); }
            assertEquals(0, MetalBackendNative.debugMessages(device).length);
            assertTrue(MetalBackendNative.metrics(device)[0] > 0);
        } finally {
            MetalBackendNative.release(query);
            MetalBackendNative.release(buffer);
            MetalBackendNative.release(texture);
            MetalBackendNative.closeDevice(device);
        }
    }
}
