// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.krishcpatel.cuprum.bridge.MetalNative;
import com.mojang.renderpearl.api.device.BackendCreationException;
import com.mojang.renderpearl.api.device.GpuBackend;
import com.mojang.renderpearl.api.device.GpuDebugOptions;
import com.mojang.renderpearl.api.device.GpuDevice;
import org.lwjgl.sdl.SDLError;
import org.lwjgl.sdl.SDLVideo;

/** RenderPearl integration boundary for the new, independent Metal renderer. */
public final class CuprumBackend implements GpuBackend {
    public static boolean enabled() {
        return Boolean.parseBoolean(System.getProperty("cuprum.enabled", "true"))
                && HostPlatform.unsupportedReason().isEmpty();
    }

    public static boolean takeoverRequested() {
        return "metal".equalsIgnoreCase(System.getProperty("cuprum.backend", "diagnostic"));
    }

    @Override
    public String getName() { return "Cuprum (direct Metal)"; }

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
        // Never return a Vulkan-backed device or advertise unimplemented capabilities.
        throw new BackendCreationException("Cuprum's direct Metal native renderer is operational, but the "
                + "Minecraft 26.3 RenderPearl device adapter is not implemented yet. "
                + "Run ./gradlew nativeSmoke for direct Metal rendering. Remove -Dcuprum.backend=metal "
                + "to use diagnostic mode and Minecraft's OpenGL renderer.", BackendCreationException.Reason.OTHER);
    }
}
