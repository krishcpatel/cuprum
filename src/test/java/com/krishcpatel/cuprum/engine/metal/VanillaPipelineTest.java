// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.engine.HostPlatform;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.frontend.FrontendGpuDevice;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.pipeline.ShaderSource;
import com.mojang.renderpearl.api.pipeline.ShaderType;
import com.mojang.renderpearl.frontend.FrontendRenderPipeline;
import com.mojang.renderpearl.frontend.shaders.PipelineBuilder;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.resources.Identifier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.stream.Stream;
import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import java.util.concurrent.Executors;

import static org.junit.jupiter.api.Assertions.*;

/** Uses the shipped vanilla assets and compiler, including every define and vertex layout. */
@EnabledIf("supported")
class VanillaPipelineTest {
    static boolean supported() { return HostPlatform.unsupportedReason().isEmpty(); }

    @Test
    void allVanillaPipelinesCompileToNativeMetal() {
        try (var device = new MetalDevice(); var builder = new PipelineBuilder(device); var sources = new VanillaSources();
             var compiler = Executors.newSingleThreadExecutor()) {
            RenderSystem.initRenderThread();
            RenderSystem.initRenderer(new FrontendGpuDevice(device));
            try {
                var pipelines = Stream.concat(RenderPipelines.requiredPipelines().stream(), RenderPipelines.optionalPipelines().stream()).toList();
                assertEquals(192, pipelines.size(), "Audit the pipeline inventory when changing Minecraft versions");
                if ("20300".equals(System.getenv("CUPRUM_MSL_VERSION"))) assertEquals(20300, device.mslVersion);
                for (var pipeline : pipelines) {
                    var pending = builder.compilePipeline(pipeline, sources, compiler).join();
                    try (var compiled = pending.finishCompile()) {
                        assertNotNull(compiled, () -> "Failed vanilla shader: " + pipeline.getLocation());
                        var metal = (MetalPipeline) ((FrontendRenderPipeline) compiled).backendRenderPipeline();
                        int depth = pipeline.wantsDepthTexture() ? GpuFormat.D32_FLOAT.ordinal() : -1;
                        long[] prepared = MetalBackendNative.cacheStats(device.handle);
                        long state = metal.variant(depth);
                        assertNotEquals(0, state, () -> "Failed Metal PSO: " + pipeline.getLocation());
                        assertEquals(state, metal.variant(depth), "Repeated format must reuse its PSO");
                        assertArrayEquals(prepared, MetalBackendNative.cacheStats(device.handle), "Binding must not compile native shaders or PSOs");
                        var duplicatePending = builder.compilePipeline(pipeline, sources, compiler).join();
                        try (var duplicate = duplicatePending.finishCompile()) {
                            var same = (MetalPipeline) ((FrontendRenderPipeline) duplicate).backendRenderPipeline();
                            assertEquals(state, same.variant(depth), "Identical pipelines must share native state across Java objects");
                            assertArrayEquals(prepared, MetalBackendNative.cacheStats(device.handle), "Duplicate preparation must reuse libraries and PSOs");
                        }
                    }
                }
                System.out.println("PASS: " + pipelines.size() + " vanilla pipelines compiled through GLSL, SPIR-V, MSL " + device.mslVersion + " and native PSOs on a compiler worker; duplicate preparation and binding caused no additional compilation.");
            } finally {
                RenderSystem.shutdownRenderer();
            }
        }
    }

    private static final class VanillaSources implements ShaderSource {
        private final Map<Identifier, CachedIncludeSource> includes = new HashMap<>();

        public String getShader(Identifier id, ShaderType type) {
            return read(type.idConverter().idToFile(id));
        }

        public CachedIncludeSource getInclude(Identifier id) {
            return includes.computeIfAbsent(id, key -> {
                String source = read(Identifier.fromNamespaceAndPath(key.getNamespace(), "shaders/include/" + key.getPath()));
                return source == null ? CachedIncludeSource.createError("Missing vanilla include: " + key)
                        : CachedIncludeSource.create(key, source);
            });
        }

        private String read(Identifier file) {
            String path = "/assets/" + file.getNamespace() + "/" + file.getPath();
            try (var stream = VanillaPipelineTest.class.getResourceAsStream(path)) {
                return stream == null ? null : new String(stream.readAllBytes(), StandardCharsets.UTF_8);
            } catch (IOException error) {
                throw new IllegalStateException("Cannot read " + path, error);
            }
        }

        public void close() { includes.values().forEach(CachedIncludeSource::close); }
    }
}
