// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.bridge;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import com.krishcpatel.cuprum.engine.HostPlatform;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Exercises the same JNI implementation used by the RenderPearl game adapter.
 */
@EnabledOnOs(OS.MAC)
@EnabledIf("supported")
class MetalBackendNativeTest {
    static boolean supported(){return HostPlatform.unsupportedReason().isEmpty();}
    @Test
    void texturedDrawsBlendDepthScissorPartialClearAndGpuTimestamps() {
        MetalNative.load();
        long device = MetalBackendNative.createDevice();
        List<Long> resources = new ArrayList<>();
        try {
            long target = own(resources, MetalBackendNative.texture(device, 6, 16, 16, 1, 1, 14));
            long depth = own(resources, MetalBackendNative.texture(device, 51, 16, 16, 1, 1, 8));
            long texture = own(resources, MetalBackendNative.texture(device, 6, 1, 1, 1, 1, 5));
            long upload = own(resources, MetalBackendNative.buffer(device, 256));
            MetalBackendNative.mapBuffer(upload, 0, 4).put(new byte[]{(byte) 200, 110, 60, (byte) 255});
            MetalBackendNative.bufferTexture(device, upload, 0, 256, 256, texture, 0, 0, 0, 0, 1, 1, true);
            long sampler = own(resources, MetalBackendNative.sampler(device, 1, 1, 0, 0, 1, 0));
            long vertices = own(resources, MetalBackendNative.buffer(device, 48));
            MetalBackendNative.mapBuffer(vertices, 0, 48).order(ByteOrder.nativeOrder()).asFloatBuffer()
                    .put(new float[]{-1, -1, 0, 0, 3, -1, 2, 0, -1, 3, 0, 2});
            long indices = own(resources, MetalBackendNative.buffer(device, 12));
            MetalBackendNative.mapBuffer(indices, 0, 12).order(ByteOrder.nativeOrder()).asIntBuffer().put(new int[]{0, 1, 2});
            long uniform = own(resources, MetalBackendNative.buffer(device, 16));
            MetalBackendNative.mapBuffer(uniform, 0, 16).order(ByteOrder.nativeOrder()).asFloatBuffer().put(new float[]{1, 1, 1, 1});
            String vertex = """
                    #include <metal_stdlib>
                    using namespace metal;
                    struct I { float2 p [[attribute(0)]];float2 uv [[attribute(1)]]; };
                    struct O { float4 p [[position]];float2 uv; };
                    vertex O vertexMain(I i [[stage_in]]) {return {float4(i.p,0.5,1),i.uv};}
                    """;
            String fragment = """
                    #include <metal_stdlib>
                    using namespace metal;
                    struct O {float4 p [[position]];float2 uv;};
                    fragment float4 fragmentMain(O i [[stage_in]],constant float4 &tint [[buffer(0)]],
                        texture2d<float> t [[texture(0)]],texture_buffer<float> table [[texture(1)]],sampler s [[sampler(0)]]) {return t.sample(s,i.uv)*tint*table.read(0u);}
                    """;
            long pipeline = own(resources, MetalBackendNative.pipeline(device, vertex, "vertexMain", fragment, "fragmentMain",
                    new int[]{0, 0, 0, 45, 0, 1, 8, 45}, new int[]{0, 16, 0},
                    new int[]{6, 15, 0, 0, 0, 0, 0, 0, 0}, 51, 1, true, false, false, 0, 0));
            long darkUniform=own(resources,MetalBackendNative.buffer(device,16));
            MetalBackendNative.mapBuffer(darkUniform,0,16).order(ByteOrder.nativeOrder()).asFloatBuffer().put(new float[]{0.2f,0.2f,0.2f,1});
            long alphaUniform=own(resources,MetalBackendNative.buffer(device,16));
            MetalBackendNative.mapBuffer(alphaUniform,0,16).order(ByteOrder.nativeOrder()).asFloatBuffer().put(new float[]{1,1,1,0.5f});
            long blended=own(resources,MetalBackendNative.pipeline(device,vertex,"vertexMain",fragment,"fragmentMain",
                    new int[]{0,0,0,45,0,1,8,45},new int[]{0,16,0},new int[]{6,15,1,11,9,0,4,9,0},51,0,false,false,false,0,0));
            long indirect = own(resources, MetalBackendNative.buffer(device, 20));
            MetalBackendNative.mapBuffer(indirect, 0, 20).order(ByteOrder.nativeOrder()).asIntBuffer().put(new int[]{3, 1, 0, 0, 0});
            long queries = own(resources, MetalBackendNative.queryPool(device, 3));
            long texels = own(resources, MetalBackendNative.texelView(device, uniform, 0, 16, 47));
            long readback = own(resources, MetalBackendNative.buffer(device, 256 * 16));
            for (int frame = 0; frame < 12; frame++) {
                MetalBackendNative.timestamp(device, queries, 0);
                MetalBackendNative.beginPass(device, new long[]{target}, new double[]{1, 0, 0, 0, 1}, depth, 1, 0, 0, 16, 16);
                MetalBackendNative.bindPipeline(device, pipeline);
                MetalBackendNative.bindBuffer(device, 16, vertices, 0);
                MetalBackendNative.bindBuffer(device, 0, uniform, 0);
                MetalBackendNative.bindTexture(device, 0, texture, sampler);
                MetalBackendNative.bindTexture(device, 1, texels, 0);
                MetalBackendNative.scissor(device, 0, 0, 8, 16);
                MetalBackendNative.draw(device, 3, 3, 1, 0, 0, indices, 0, 1, 0);
                MetalBackendNative.debugGroup(device, "mid-pass timestamp and fan", true);
                MetalBackendNative.timestamp(device, queries, 2);
                MetalBackendNative.drawIndexedFan(device, 3, 1, indices, 0, 1, 0, 0);
                MetalBackendNative.drawIndirectFan(device, indirect, 0, indices, 1);
                MetalBackendNative.drawIndirectFan(device, indirect, 0, 0, 0);
                MetalBackendNative.debugGroup(device, "", false);
                MetalBackendNative.endPass(device);
                MetalBackendNative.clearRegion(device, target, depth, 1, 0, 0, 1, 0.25f, 0, 0, 2, 2);
                // Equal-depth fragments and fragments behind the cleared near depth must not replace color.
                MetalBackendNative.beginPass(device,new long[]{target},new double[]{0,0,0,0,0},depth,-1,0,0,16,16);
                bind(device,pipeline,vertices,darkUniform,texture,sampler,texels);
                MetalBackendNative.scissor(device,0,0,8,16);
                MetalBackendNative.draw(device,3,3,1,0,0,indices,0,1,0);
                MetalBackendNative.endPass(device);
                // Source-alpha blending over blue has a predictable GPU-readback result.
                MetalBackendNative.clearRegion(device,target,0,0,0,1,1,0,8,0,8,16);
                MetalBackendNative.beginPass(device,new long[]{target},new double[]{0,0,0,0,0},depth,-1,0,0,16,16);
                bind(device,blended,vertices,alphaUniform,texture,sampler,texels);
                MetalBackendNative.scissor(device,8,0,8,16);
                MetalBackendNative.draw(device,3,3,1,0,0,indices,0,1,0);
                MetalBackendNative.endPass(device);
                MetalBackendNative.bufferTexture(device, readback, 0, 256, 4096, target, 0, 0, 0, 0, 16, 16, false);
                MetalBackendNative.timestamp(device, queries, 1);
                long command = MetalBackendNative.submit(device, true);
                try {
                    assertTrue(MetalBackendNative.await(command, 0));
                    long start = MetalBackendNative.queryValue(queries, 0), end = MetalBackendNative.queryValue(queries, 1);
                    long middle = MetalBackendNative.queryValue(queries, 2);
                    assertTrue(middle >= start && middle <= end, "Mid-pass timestamp must be ordered");
                    assertTrue(start > 0 && end >= start, "GPU counter samples must be available and ordered: " + start + "/" + end);
                    var pixels = MetalBackendNative.mapBuffer(readback, 0, 4096);
                    assertEquals(200, pixels.get(8 * 256 + 4 * 4) & 255);
                    assertEquals(110, pixels.get(8 * 256 + 4 * 4 + 1) & 255);
                    assertEquals(60, pixels.get(8 * 256 + 4 * 4 + 2) & 255);
                    assertEquals(100,pixels.get(8*256+12*4)&255);
                    assertEquals(55,pixels.get(8*256+12*4+1)&255);
                    assertTrue(Math.abs((pixels.get(8*256+12*4+2)&255)-158)<=1);
                    assertEquals(255,pixels.get(8*256+12*4+3)&255);
                    assertEquals(255, pixels.get(0) & 255);
                    assertEquals(0, pixels.get(1) & 255);
                } finally {
                    MetalBackendNative.release(command);
                }
            }
        } finally {
            MetalBackendNative.waitIdle(device);
            resources.reversed().forEach(MetalBackendNative::release);
            MetalBackendNative.closeDevice(device);
        }
    }

    private static void bind(long device,long pipeline,long vertices,long uniform,long texture,long sampler,long texels) {
        MetalBackendNative.bindPipeline(device,pipeline);
        MetalBackendNative.bindBuffer(device,16,vertices,0);
        MetalBackendNative.bindBuffer(device,0,uniform,0);
        MetalBackendNative.bindTexture(device,0,texture,sampler);
        MetalBackendNative.bindTexture(device,1,texels,0);
    }

    private static long own(List<Long> resources, long handle) {
        assertTrue(handle != 0);
        resources.add(handle);
        return handle;
    }
}
