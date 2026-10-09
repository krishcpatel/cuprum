// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.diagnostic;

import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.bridge.MetalNative;
import com.krishcpatel.cuprum.engine.CuprumPipeline;
import com.krishcpatel.cuprum.engine.HostPlatform;
import com.krishcpatel.cuprum.engine.MetalRenderer;
import com.krishcpatel.cuprum.engine.metal.MetalDevice;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.device.GpuSurface;
import com.mojang.renderpearl.api.device.SurfaceException;
import com.mojang.renderpearl.api.textures.GpuTexture;
import org.lwjgl.sdl.SDL_Event;
import org.lwjgl.system.MemoryStack;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Locale;

import static org.lwjgl.sdl.SDLError.SDL_GetError;
import static org.lwjgl.sdl.SDLEvents.SDL_EVENT_QUIT;
import static org.lwjgl.sdl.SDLEvents.SDL_PollEvent;
import static org.lwjgl.sdl.SDLInit.SDL_INIT_VIDEO;
import static org.lwjgl.sdl.SDLInit.SDL_Init;
import static org.lwjgl.sdl.SDLInit.SDL_Quit;
import static org.lwjgl.sdl.SDLVideo.SDL_CreateWindow;
import static org.lwjgl.sdl.SDLVideo.SDL_DestroyWindow;
import static org.lwjgl.sdl.SDLVideo.SDL_GetWindowSizeInPixels;
import static org.lwjgl.sdl.SDLVideo.SDL_SetWindowSize;
import static org.lwjgl.sdl.SDLVideo.SDL_SetWindowFullscreen;
import static org.lwjgl.sdl.SDLVideo.SDL_MinimizeWindow;
import static org.lwjgl.sdl.SDLVideo.SDL_RestoreWindow;
import static org.lwjgl.sdl.SDLVideo.SDL_GetWindowFlags;
import static org.lwjgl.sdl.SDLVideo.SDL_WINDOW_MINIMIZED;
import static org.lwjgl.sdl.SDLVideo.SDL_SyncWindow;
import static org.lwjgl.sdl.SDLVideo.SDL_WINDOW_HIGH_PIXEL_DENSITY;
import static org.lwjgl.sdl.SDLVideo.SDL_WINDOW_METAL;
import static org.lwjgl.sdl.SDLVideo.SDL_WINDOW_RESIZABLE;

/** Draws a textured triangle with MSL, shared buffers and direct Metal presentation. No game/Vulkan bootstrap. */
public final class NativeSmoke {
    private NativeSmoke() { }

    public static void main(String[] args) throws SurfaceException {
        HostPlatform.requireSupported();
        if (!SDL_Init(SDL_INIT_VIDEO)) throw new IllegalStateException(SDL_GetError());
        try {
            long window = SDL_CreateWindow("Cuprum — direct Metal", 640, 360,
                    SDL_WINDOW_METAL | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
            if (window == 0) throw new IllegalStateException(SDL_GetError());
            try {
                render(window);
                renderBackendSurface(window);
            } finally {
                SDL_DestroyWindow(window);
            }
        } finally {
            SDL_Quit();
        }
    }

    private static void renderBackendSurface(long window) throws SurfaceException {
        try (var device = new MetalDevice(); var surface = device.createSurface(window,
                () -> (SDL_GetWindowFlags(window) & SDL_WINDOW_MINIMIZED) != 0);
             var source = device.createTexture("surface smoke", GpuTexture.USAGE_RENDER_ATTACHMENT | GpuTexture.USAGE_TEXTURE_BINDING,
                     GpuFormat.RGBA8_UNORM, 16, 16, 1, 1);
             var view = device.createTextureView(source, 0, 1);
             var stack = MemoryStack.stackPush()) {
            var encoder = device.createCommandEncoder();
            var width = stack.mallocInt(1); var height = stack.mallocInt(1);
            var event = SDL_Event.calloc(stack);
            boolean resized = false;
            int configuredWidth = -1;
            for (int frame=0; frame<36; frame++) {
                while (SDL_PollEvent(event)) { }
                if (frame == 12 && !SDL_SetWindowSize(window, 720, 400)) throw new IllegalStateException(SDL_GetError());
                if (frame == 24 && (!SDL_SetWindowFullscreen(window, true) || !SDL_SyncWindow(window))) throw new IllegalStateException(SDL_GetError());
                if (!SDL_GetWindowSizeInPixels(window, width, height)) throw new IllegalStateException(SDL_GetError());
                if (surface.isSuboptimal()) {
                    if (configuredWidth > 0 && width.get(0) != configuredWidth) resized = true;
                    surface.configure(new GpuSurface.Configuration(width.get(0), height.get(0), GpuSurface.PresentMode.FIFO));
                    configuredWidth = width.get(0);
                }
                surface.acquireNextTexture();
                try {
                    surface.configure(new GpuSurface.Configuration(width.get(0), height.get(0), GpuSurface.PresentMode.FIFO));
                    throw new AssertionError("An acquired surface accepted reconfiguration");
                } catch (SurfaceException expected) { }
                encoder.clearColorTexture(source, new org.joml.Vector4f(0.2f, 0.4f, 0.6f, 1));
                surface.blitFromTexture(encoder, view);
                surface.present();
            }
            if (!resized) throw new AssertionError("The backend failed to detect a changed pixel extent");
            if (!SDL_SetWindowFullscreen(window, false) || !SDL_SyncWindow(window) || !SDL_MinimizeWindow(window) || !SDL_SyncWindow(window))
                throw new IllegalStateException(SDL_GetError());
            while (SDL_PollEvent(event)) { }
            try { surface.acquireNextTexture(); throw new AssertionError("Minimized surface acquired a drawable"); }
            catch (SurfaceException expected) { }
            if (!SDL_RestoreWindow(window) || !SDL_SyncWindow(window)) throw new IllegalStateException(SDL_GetError());
            while (SDL_PollEvent(event)) { }
            if (!device.getLastDebugMessages().isEmpty()) throw new AssertionError("Metal reported backend validation errors");
            System.out.println("PASS: RenderPearl Metal surface presentation, resize, fullscreen, minimization and reconfiguration guards.");
        }
    }

    private static void render(long window) {
        try (var layer = CocoaMetalBridge.attach(window); var renderer = new MetalRenderer(layer);
             MemoryStack stack = MemoryStack.stackPush()) {
            System.out.println("Metal diagnostics: " + CocoaMetalBridge.deviceInfo());
            CuprumPipeline pipeline = new CuprumPipeline(renderer);
            ByteBuffer vertices = ByteBuffer.allocateDirect(3 * MetalRenderer.VERTEX_STRIDE).order(ByteOrder.nativeOrder());
            putVertex(vertices, -0.8f, -0.8f, 0, 0, 1);
            putVertex(vertices, 0.8f, -0.8f, 0, 1, 1);
            putVertex(vertices, 0, 0.8f, 0, 0.5f, 0);
            vertices.flip();
            ByteBuffer rgba = ByteBuffer.allocateDirect(16);
            for (int i = 0; i < 4; i++) rgba.put((byte) 200).put((byte) 110).put((byte) 60).put((byte) 255);
            rgba.flip();
            float[] identity = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
            var width = stack.mallocInt(1);
            var height = stack.mallocInt(1);
            SDL_Event event = SDL_Event.calloc(stack);
            try (var mesh = pipeline.uploadVertices(vertices); var texture = renderer.createTexture(2, 2, rgba);
                 var uniforms = pipeline.uploadUniforms(identity, 1, 1, 1, 1)) {
                int frames = 0;
                int unavailable = 0;
                int initialWidth = 0;
                while (frames < 120) {
                    while (SDL_PollEvent(event)) {
                        if (event.type() == SDL_EVENT_QUIT) throw new IllegalStateException("Native smoke test was closed before completion.");
                    }
                    if (frames == 60 && unavailable == 0 && !SDL_SetWindowSize(window, 800, 450)) {
                        throw new IllegalStateException(SDL_GetError());
                    }
                    if (!SDL_GetWindowSizeInPixels(window, width, height)) throw new IllegalStateException(SDL_GetError());
                    if (frames == 0) initialWidth = width.get(0);
                    layer.updateScale();
                    var acquired = renderer.beginFrame(width.get(0), height.get(0), 0.04, 0.06, 0.08, 1);
                    if (acquired.isEmpty()) {
                        if (++unavailable >= 120) throw new IllegalStateException("No Metal drawable became available.");
                        continue;
                    }
                    unavailable = 0;
                    try (var frame = acquired.get()) {
                        pipeline.record(frame, mesh, uniforms, texture, 3);
                        if (frames == 119) {
                            byte[] pixels = frame.submitAndReadback();
                            verifyTriangle(pixels, width.get(0), height.get(0));
                            if (width.get(0) == initialWidth) throw new AssertionError("The resize did not change framebuffer dimensions.");
                        } else {
                            frame.submit();
                        }
                    }
                    frames++;
                }
                // Exercise zero-extent skip and cancellation of unsubmitted work.
                if (renderer.beginFrame(0, 0, 0, 0, 0, 1).isPresent()) throw new AssertionError("Zero-size surface acquired a frame.");
                try (var cancelled = renderer.beginFrame(width.get(0), height.get(0), 0, 0, 0, 1).orElseThrow()) {
                    pipeline.record(cancelled, mesh, uniforms, texture, 3);
                }
                try (var afterCancel = renderer.beginFrame(width.get(0), height.get(0), 0, 0, 0, 1).orElseThrow()) {
                    pipeline.record(afterCancel, mesh, uniforms, texture, 3);
                    afterCancel.submitAndReadback();
                }
                for (String image : MetalNative.loadedImagePaths()) {
                    String path = image.toLowerCase(Locale.ROOT);
                    if (path.contains("moltenvk") || path.contains("libvulkan") || path.contains("liblwjgl_opengl")) {
                        throw new AssertionError("A non-Metal graphics library was loaded during direct Metal rendering: " + image);
                    }
                }
                System.out.println("PASS: no LWJGL OpenGL driver, Vulkan loader or MoltenVK dylib loaded in this process.");
                if (java.util.Arrays.stream(MetalNative.loadedImagePaths()).anyMatch(p -> p.contains("/OpenGL.framework/")))
                    System.out.println("NOTE: Apple's required system frameworks transitively map OpenGL.framework; Cuprum does not create a GL context or call its rendering API.");
                System.out.println("PASS: 120 direct Metal textured frames, GPU pixel readback, resize, zero-extent skip and frame cancellation.");
            }
        }
    }

    private static void putVertex(ByteBuffer data, float x, float y, float z, float u, float v) {
        data.putFloat(x).putFloat(y).putFloat(z);
        data.putInt(-1); // Normalized RGBA8 white.
        data.putFloat(u).putFloat(v);
    }

    private static void verifyTriangle(byte[] pixels, int width, int height) {
        if (pixels.length != width * height * 4) throw new AssertionError("Invalid Metal readback dimensions.");
        int center = ((height / 2) * width + width / 2) * 4;
        int blue = Byte.toUnsignedInt(pixels[center]);
        int green = Byte.toUnsignedInt(pixels[center + 1]);
        int red = Byte.toUnsignedInt(pixels[center + 2]);
        int alpha = Byte.toUnsignedInt(pixels[center + 3]);
        if (Math.abs(red - 200) > 2 || Math.abs(green - 110) > 2 || Math.abs(blue - 60) > 2 || alpha != 255) {
            throw new AssertionError("The GPU did not render the expected textured triangle: RGBA=" + red + "," + green + "," + blue + "," + alpha);
        }
        System.out.println("PASS: GPU readback matches textured MSL draw (RGBA " + red + "," + green + "," + blue + "," + alpha + ").");
    }
}
