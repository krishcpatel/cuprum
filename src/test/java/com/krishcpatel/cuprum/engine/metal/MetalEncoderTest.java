// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.engine.HostPlatform;
import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.commands.RenderPassDescriptor;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.api.textures.AddressMode;
import com.mojang.renderpearl.api.textures.FilterMode;
import java.util.OptionalDouble;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIf("supported")
class MetalEncoderTest {
    static boolean supported() {
        return HostPlatform.unsupportedReason().isEmpty();
    }

    @Test
    void atlasMipLightmapAndOverlayBindToIndependentTextureSlots() {
        try (var device = new MetalDevice()) {
            int sampledUsage = GpuTexture.USAGE_COPY_DST | GpuTexture.USAGE_TEXTURE_BINDING;
            var atlas = device.createTexture("mipped atlas", sampledUsage, GpuFormat.RGBA8_UNORM, 7, 3, 1, 3);
            var lightmap = device.createTexture("lightmap", sampledUsage, GpuFormat.RGBA8_UNORM, 1, 1, 1, 1);
            var overlay = device.createTexture("overlay", sampledUsage, GpuFormat.RGBA8_UNORM, 1, 1, 1, 1);
            var target = device.createTexture("three samplers", GpuTexture.USAGE_RENDER_ATTACHMENT | GpuTexture.USAGE_COPY_SRC,
                    GpuFormat.RGBA8_UNORM, 4, 4, 1, 1);
            device.encoder.writeToTexture(atlas, pixels(21, 255, 255, 255, 255), 0, 0, 0, 0, 7, 3);
            device.encoder.writeToTexture(atlas, pixels(3, 128, 64, 32, 255), 1, 0, 0, 0, 3, 1);
            device.encoder.writeToTexture(atlas, pixels(1, 0, 0, 0, 255), 2, 0, 0, 0, 1, 1);
            device.encoder.writeToTexture(lightmap, pixels(1, 128, 255, 255, 255), 0, 0, 0, 0, 1, 1);
            device.encoder.writeToTexture(overlay, pixels(1, 255, 0, 0, 128), 0, 0, 0, 0, 1, 1);
            var sampler = (MetalResources.Sampler) device.createSampler(AddressMode.CLAMP_TO_EDGE, AddressMode.REPEAT,
                    FilterMode.NEAREST, FilterMode.NEAREST, 1, OptionalDouble.of(2));
            var duplicate = (MetalResources.Sampler) device.createSampler(AddressMode.CLAMP_TO_EDGE, AddressMode.REPEAT,
                    FilterMode.NEAREST, FilterMode.NEAREST, 1, OptionalDouble.of(2));
            assertEquals(sampler.handle(), duplicate.handle(), "Identical samplers must share the cached native state");
            duplicate.close(); // Its independent JNI retain must keep the first sampler alive.
            String vertex = """
                    #include <metal_stdlib>
                    using namespace metal;
                    vertex float4 v(uint id [[vertex_id]]) {
                        const float2 corners[4] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
                        return float4(corners[id], 0, 1);
                    }
                    """;
            String fragment = """
                    #include <metal_stdlib>
                    using namespace metal;
                    fragment float4 f(texture2d<float> atlas [[texture(0)]], sampler a [[sampler(0)]],
                        texture2d<float> lightmap [[texture(1)]], sampler l [[sampler(1)]],
                        texture2d<float> overlay [[texture(2)]], sampler o [[sampler(2)]]) {
                        float4 base = atlas.sample(a, float2(0.5), level(1));
                        float4 light = lightmap.sample(l, float2(0.5));
                        float4 tint = overlay.sample(o, float2(0.5));
                        return float4(mix(base.rgb * light.rgb, tint.rgb, tint.a), 1);
                    }
                    """;
            long pipeline = MetalBackendNative.pipeline(device.handle, vertex, "v", fragment, "f", new int[0], new int[0],
                    new int[]{GpuFormat.RGBA8_UNORM.ordinal(), 15, 0, 0, 0, 0, 0, 0, 0}, -1, 0, false, false, false, 0, 0);
            try {
                MetalBackendNative.beginPass(device.handle, new long[]{((MetalResources.Texture) target).handle()},
                        new double[]{1, 0, 0, 0, 1}, 0, -1, 0, 0, 4, 4);
                MetalBackendNative.bindPipeline(device.handle, pipeline);
                MetalBackendNative.bindTexture(device.handle, 0, ((MetalResources.Texture) atlas).handle(), sampler.handle());
                MetalBackendNative.bindTexture(device.handle, 1, ((MetalResources.Texture) lightmap).handle(), sampler.handle());
                MetalBackendNative.bindTexture(device.handle, 2, ((MetalResources.Texture) overlay).handle(), sampler.handle());
                MetalBackendNative.draw(device.handle, 4, 4, 1, 0, 0, 0, 0, 0, 0); // Native triangle strip.
                MetalBackendNative.endPass(device.handle);
                var readback = device.createBuffer(() -> "three sampler readback", GpuBuffer.USAGE_MAP_READ | GpuBuffer.USAGE_COPY_DST, 64);
                AtomicInteger completed = new AtomicInteger();
                device.encoder.copyTextureToBuffer(target, readback, 0, () -> {
                    var bytes = ((MetalResources.Buffer) readback).bytes(0, 64);
                    for (int i = 0; i < 16; i++) {
                        assertTrue(Math.abs((bytes.get(i * 4) & 255) - 160) <= 1);
                        assertTrue(Math.abs((bytes.get(i * 4 + 1) & 255) - 32) <= 1);
                        assertTrue(Math.abs((bytes.get(i * 4 + 2) & 255) - 16) <= 1);
                        assertEquals(255, bytes.get(i * 4 + 3) & 255);
                    }
                    completed.incrementAndGet();
                }, 0);
                device.encoder.sync();
                assertEquals(1, completed.get());
            } finally {
                MetalBackendNative.release(pipeline);
            }
        }
    }

    private static ByteBuffer pixels(int count, int red, int green, int blue, int alpha) {
        ByteBuffer data = ByteBuffer.allocateDirect(count * 4);
        for (int i = 0; i < count; i++) data.put((byte) red).put((byte) green).put((byte) blue).put((byte) alpha);
        return data.flip();
    }

    @Test
    void frameBoundaryClosesLingeringPassAndClampsOffscreenScissors() {
        try (var device = new MetalDevice()) {
            var texture = device.createTexture("frame boundary", GpuTexture.USAGE_RENDER_ATTACHMENT,
                    GpuFormat.RGBA8_UNORM, 16, 16, 1, 1);
            var view = device.createTextureView(texture, 0, 1);
            var pass = device.encoder.createRenderPass(RenderPassDescriptor.builder(() -> "unfinished pass")
                    .withColorAttachment(view).build());
            pass.enableScissor(Integer.MAX_VALUE, Integer.MAX_VALUE, Integer.MAX_VALUE, Integer.MAX_VALUE);
            pass.enableScissor(-32, -32, 16, 16);
            pass.disableScissor();
            device.encoder.finishFrame();
            assertThrows(IllegalStateException.class, pass::disableScissor);
            // The following clear verifies both native and Java pass state were drained.
            device.encoder.clearColorTexture(texture, new org.joml.Vector4f(1, 0, 0, 1));
            device.encoder.sync();
        }
    }

    @Test
    void failedReadbackStillRunsOtherCallbacksAndReleasesSubmission() {
        try (var device = new MetalDevice()) {
            var texture = device.createTexture("callback cleanup", GpuTexture.USAGE_RENDER_ATTACHMENT | GpuTexture.USAGE_COPY_SRC,
                    GpuFormat.RGBA8_UNORM, 1, 1, 1, 1);
            var readback = device.createBuffer(() -> "readback", GpuBuffer.USAGE_MAP_READ | GpuBuffer.USAGE_COPY_DST, 4);
            device.encoder.clearColorTexture(texture, new org.joml.Vector4f(1, 0, 0, 1));
            AtomicInteger completed = new AtomicInteger();
            device.encoder.copyTextureToBuffer(texture, readback, 0, () -> { throw new IllegalStateException("callback failure"); }, 0);
            device.encoder.copyTextureToBuffer(texture, readback, 0, completed::incrementAndGet, 0);
            assertEquals("callback failure", assertThrows(IllegalStateException.class, device.encoder::sync).getMessage());
            assertEquals(1, completed.get());
            device.encoder.sync();
            assertEquals(1, completed.get(), "Callbacks must not run again after a failure");
        }
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
