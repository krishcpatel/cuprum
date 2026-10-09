// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Objects;

/** Concrete direct Metal position/color/texture submission example, independent of RenderPearl's renderer. */
public final class CuprumPipeline {
    private final MetalRenderer renderer;

    public CuprumPipeline(MetalRenderer renderer) {
        this.renderer = Objects.requireNonNull(renderer);
    }

    /** Position float3, normalized RGBA8 color, UV float2: exactly 24 bytes per vertex. */
    public MetalRenderer.Buffer uploadVertices(ByteBuffer packedVertices) {
        if (packedVertices.remaining() % MetalRenderer.VERTEX_STRIDE != 0) {
            throw new IllegalArgumentException("Vertex data must contain complete 24-byte vertices.");
        }
        return renderer.createBuffer(packedVertices);
    }

    /** Column-major float4x4 MVP followed by float4 tint, aligned to 16 bytes. */
    public MetalRenderer.Buffer uploadUniforms(float[] mvp, float red, float green, float blue, float alpha) {
        if (mvp.length != 16) throw new IllegalArgumentException("The MVP matrix must have 16 elements.");
        ByteBuffer bytes = ByteBuffer.allocateDirect(MetalRenderer.UNIFORM_BYTES).order(ByteOrder.nativeOrder());
        for (float value : mvp) bytes.putFloat(value);
        bytes.putFloat(red).putFloat(green).putFloat(blue).putFloat(alpha).flip();
        return renderer.createBuffer(bytes);
    }

    /** Records MTLBuffer bindings and a triangle draw in the frame's MTLRenderCommandEncoder. */
    public void record(MetalRenderer.Frame frame, MetalRenderer.Buffer vertices,
                       MetalRenderer.Buffer uniforms, MetalRenderer.Texture texture, int vertexCount) {
        frame.draw(vertices, uniforms, texture, vertexCount);
    }
}
