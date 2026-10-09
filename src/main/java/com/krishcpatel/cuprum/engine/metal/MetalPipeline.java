// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.pipeline.ShaderType;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.util.spvc.SpvcMslResourceBinding;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

import static org.lwjgl.util.spvc.Spvc.SPVC_BACKEND_MSL;
import static org.lwjgl.util.spvc.Spvc.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP;
import static org.lwjgl.util.spvc.Spvc.SPVC_COMPILER_OPTION_FLIP_VERTEX_Y;
import static org.lwjgl.util.spvc.Spvc.SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE;
import static org.lwjgl.util.spvc.Spvc.SPVC_COMPILER_OPTION_MSL_VERSION;
import static org.lwjgl.util.spvc.Spvc.SPVC_MSL_PUSH_CONSTANT_BINDING;
import static org.lwjgl.util.spvc.Spvc.SPVC_MSL_PUSH_CONSTANT_DESC_SET;
import static org.lwjgl.util.spvc.Spvc.SPVC_SUCCESS;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_compile;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_create_compiler_options;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_get_cleansed_entry_point_name;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_install_compiler_options;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_msl_add_resource_binding;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_options_set_bool;
import static org.lwjgl.util.spvc.Spvc.spvc_compiler_options_set_uint;
import static org.lwjgl.util.spvc.Spvc.spvc_context_create;
import static org.lwjgl.util.spvc.Spvc.spvc_context_create_compiler;
import static org.lwjgl.util.spvc.Spvc.spvc_context_destroy;
import static org.lwjgl.util.spvc.Spvc.spvc_context_get_last_error_string;
import static org.lwjgl.util.spvc.Spvc.spvc_context_parse_spirv;
import static org.lwjgl.system.MemoryUtil.memUTF8;

final class MetalPipeline implements BackendRenderPipeline {
    record Shader(String msl, String entry) {
    }

    final MetalDevice device;
    final CreateInfo info;
    final Shader vertex, fragment;
    private final Map<Integer, Long> variants = new HashMap<>();
    private boolean closed;

    MetalPipeline(MetalDevice device, CreateInfo info) {
        this.device = device;
        this.info = info;
        vertex = translate(info.shaders().stream().filter(s -> s.module().type() == ShaderType.VERTEX).findFirst().orElseThrow());
        fragment = translate(info.shaders().stream().filter(s -> s.module().type() == ShaderType.FRAGMENT).findFirst().orElseThrow());
    }

    private Shader translate(CreateInfo.Shader shader) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            var p = stack.mallocPointer(1);
            check(0, spvc_context_create(p));
            long context = p.get(0);
            try {
                var spv = shader.module().spv();
                check(context, spvc_context_parse_spirv(context, spv.asIntBuffer(), spv.remaining() / 4, p));
                long ir = p.get(0);
                check(context, spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, p));
                long compiler = p.get(0);
                check(context, spvc_compiler_create_compiler_options(compiler, p));
                long options = p.get(0);
                check(context, spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 20400));
                check(context, spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, true));
                check(context, spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, true));
                check(context, spvc_compiler_install_compiler_options(compiler, options));
                int stage = shader.module().type() == ShaderType.VERTEX ? 0 : 4;
                for (int i = 0; i < info.uniforms().size(); i++) {
                    if (i >= 15)
                        throw new IllegalArgumentException("Metal pipeline exceeds the 15 uniform binding slots");
                    var binding = SpvcMslResourceBinding.calloc(stack).stage(stage).desc_set(0).binding(i).msl_buffer(i).msl_texture(i).msl_sampler(i);
                    check(context, spvc_compiler_msl_add_resource_binding(compiler, binding));
                }
                var push = SpvcMslResourceBinding.calloc(stack).stage(stage).desc_set(SPVC_MSL_PUSH_CONSTANT_DESC_SET).binding(SPVC_MSL_PUSH_CONSTANT_BINDING).msl_buffer(15);
                check(context, spvc_compiler_msl_add_resource_binding(compiler, push));
                check(context, spvc_compiler_compile(compiler, p));
                String source = memUTF8(p.get(0));
                String entry = spvc_compiler_get_cleansed_entry_point_name(compiler, shader.entryPoint(), stage);
                String dump = System.getProperty("cuprum.dumpShaders");
                if (dump != null) try {
                    var directory = java.nio.file.Path.of(dump);
                    java.nio.file.Files.createDirectories(directory);
                    java.nio.file.Files.writeString(directory.resolve(info.name().replaceAll("[^a-zA-Z0-9_-]", "_") + "_" + stage + ".metal"), source);
                } catch (java.io.IOException error) {
                    throw new IllegalStateException(error);
                }
                return new Shader(source, Objects.requireNonNull(entry));
            } finally {
                spvc_context_destroy(context);
            }
        }
    }

    private static void check(long context, int result) {
        if (result != SPVC_SUCCESS)
            throw new IllegalStateException("MSL translation failed: " + (context == 0 ? result : spvc_context_get_last_error_string(context)));
    }

    long variant(int depthFormat) {
        device.checkThread();
        if (closed) throw new IllegalStateException("Pipeline closed");
        return variants.computeIfAbsent(depthFormat, key -> {
            int[] attrs = info.attribBindings().stream().flatMapToInt(a -> java.util.stream.IntStream.of(a.bufferSlot(), a.location(), a.offset(), a.format().ordinal())).toArray();
            int[] layouts = info.vertexBuffers().stream().flatMapToInt(a -> java.util.stream.IntStream.of(a.bufferSlot(), a.stride(), a.stepRate())).toArray();
            int[] colors = new int[info.colorTargetStates().size() * 9];
            for (int i = 0; i < info.colorTargetStates().size(); i++) {
                var c = info.colorTargetStates().get(i);
                int b = i * 9;
                if (c == null) {
                    colors[b] = -1;
                    continue;
                }
                colors[b] = c.format().ordinal();
                colors[b + 1] = c.writeMask();
                if (c.blendFunction().isPresent()) {
                    var f = c.blendFunction().get();
                    colors[b + 2] = 1;
                    colors[b + 3] = f.color().sourceFactor().ordinal();
                    colors[b + 4] = f.color().destFactor().ordinal();
                    colors[b + 5] = f.color().op().ordinal();
                    colors[b + 6] = f.alpha().sourceFactor().ordinal();
                    colors[b + 7] = f.alpha().destFactor().ordinal();
                    colors[b + 8] = f.alpha().op().ordinal();
                }
            }
            var ds = info.depthStencilState();
            return MetalBackendNative.pipeline(device.handle, vertex.msl, vertex.entry, fragment.msl, fragment.entry, attrs, layouts, colors, key, ds == null ? 0 : ds.depthTest().ordinal(), ds != null && ds.writeDepth(), info.cull(), info.polygonMode().ordinal() == 1, ds == null ? 0 : ds.depthBiasConstant(), ds == null ? 0 : ds.depthBiasScaleFactor());
        });
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        device.checkThread();
        if (!closed) {
            closed = true;
            variants.values().forEach(MetalBackendNative::release);
            variants.clear();
            device.resources.remove(this);
        }
    }
}
