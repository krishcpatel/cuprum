// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.krishcpatel.cuprum.bridge.MetalNative;
import com.krishcpatel.cuprum.engine.metal.MetalDevice;
import com.mojang.renderpearl.frontend.FrontendGpuDevice;
import com.mojang.renderpearl.api.device.BackendCreationException;
import com.mojang.renderpearl.api.device.GpuBackend;
import com.mojang.renderpearl.api.device.GpuDebugOptions;
import com.mojang.renderpearl.api.device.GpuDevice;
import org.lwjgl.sdl.SDLError;
import org.lwjgl.sdl.SDLVideo;

/**
 * Selects the RenderPearl Metal device and creates context-free SDL Metal windows.
 */
public final class CuprumBackend implements GpuBackend {
    public static boolean enabled() {
        return Boolean.parseBoolean(System.getProperty("cuprum.enabled", "true"))
                && HostPlatform.unsupportedReason().isEmpty();
    }

    public static boolean takeoverRequested() {
        String backend = System.getProperty("cuprum.backend", "metal");
        if ("metal".equalsIgnoreCase(backend)) return true;
        if ("diagnostic".equalsIgnoreCase(backend)) return false;
        throw new IllegalArgumentException("Unknown cuprum.backend: " + backend + "; use metal or diagnostic");
    }

    @Override
    public String getName() {
        return "Cuprum (direct Metal)";
    }

    @Override
    public void loadLibrary() throws BackendCreationException {
        try {
            HostPlatform.requireSupported();
            MetalNative.load();
        } catch (RuntimeException | LinkageError error) {
            throw new BackendCreationException("Cannot load Cuprum's Metal bridge: " + error.getMessage(),
                    BackendCreationException.Reason.PLATFORM_ERROR);
        }
    }

    @Override
    public void unloadLibrary() {
        // System.load owns the JNI library for this classloader's lifetime.
        // Devices and windows must be closed individually; there is no global GPU instance.
    }

    @Override
    public long createWindow(String title, int width, int height, long flags) {
        HostPlatform.requireSupported();
        if ((flags & (SDLVideo.SDL_WINDOW_OPENGL | SDLVideo.SDL_WINDOW_VULKAN)) != 0) {
            throw new IllegalArgumentException("Direct Metal windows cannot request another graphics API.");
        }
        long window = SDLVideo.SDL_CreateWindow(title, width, height, flags | SDLVideo.SDL_WINDOW_METAL);
        if (window == 0) throw new IllegalStateException("Cannot create Metal window: " + SDLError.SDL_GetError());
        return window;
    }

    @Override
    public GpuDevice createDevice(GpuDebugOptions options) throws BackendCreationException {
        return new FrontendGpuDevice(new MetalDevice());
    }
}
