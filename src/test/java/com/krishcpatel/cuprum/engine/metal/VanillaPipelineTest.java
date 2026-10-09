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

import static org.junit.jupiter.api.Assertions.*;

/** Uses the shipped vanilla assets and compiler, including every define and vertex layout. */
@EnabledIf("supported")
class VanillaPipelineTest {
    static boolean supported() { return HostPlatform.unsupportedReason().isEmpty(); }

    @Test
    void allVanillaPipelinesCompileToNativeMetal() {
        try (var device = new MetalDevice(); var builder = new PipelineBuilder(device); var sources = new VanillaSources()) {
            RenderSystem.initRenderThread();
            RenderSystem.initRenderer(new FrontendGpuDevice(device));
            try {
                var pipelines = Stream.concat(RenderPipelines.requiredPipelines().stream(), RenderPipelines.optionalPipelines().stream()).toList();
                assertTrue(pipelines.size() > 50, "Vanilla pipeline registry must be populated");
                for (var pipeline : pipelines) {
                    var pending = builder.compilePipeline(pipeline, sources, Runnable::run).join();
                    try (var compiled = pending.finishCompile()) {
                        assertNotNull(compiled, () -> "Failed vanilla shader: " + pipeline.getLocation());
                        var metal = (MetalPipeline) ((FrontendRenderPipeline) compiled).backendRenderPipeline();
                        int depth = pipeline.wantsDepthTexture() ? GpuFormat.D32_FLOAT.ordinal() : -1;
                        long state = metal.variant(depth);
                        assertNotEquals(0, state, () -> "Failed Metal PSO: " + pipeline.getLocation());
                        assertEquals(state, metal.variant(depth), "Repeated format must reuse its PSO");
                    }
                }
                System.out.println("PASS: " + pipelines.size() + " vanilla pipelines compiled through GLSL, SPIR-V, MSL and native PSOs.");
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
