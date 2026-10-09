// SPDX-License-Identifier: LGPL-3.0-only
#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float3 position [[attribute(0)]];
    float4 color [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

// 80 bytes, column-major matrix followed by a float4; matches Java's packed UBO.
struct Uniforms {
    float4x4 mvp;
    float4 tint;
};

struct VertexOutput {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex VertexOutput cuprum_vertex(VertexInput input [[stage_in]],
                                  constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOutput output;
    output.position = uniforms.mvp * float4(input.position, 1.0);
    output.color = input.color * uniforms.tint;
    output.uv = input.uv;
    return output;
}

fragment float4 cuprum_fragment(VertexOutput input [[stage_in]],
                                texture2d<float> colorTexture [[texture(0)]],
                                sampler colorSampler [[sampler(0)]]) {
    return colorTexture.sample(colorSampler, input.uv) * input.color;
}
