// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.bridge;

import com.krishcpatel.cuprum.engine.HostPlatform;

import org.lwjgl.system.Library;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.SharedLibrary;
import org.lwjgl.system.libffi.FFICIF;
import org.lwjgl.system.macosx.ObjCRuntime;

import static org.lwjgl.sdl.SDLVideo.SDL_GetWindowFlags;
import static org.lwjgl.sdl.SDLVideo.SDL_GetWindowProperties;
import static org.lwjgl.sdl.SDLVideo.SDL_GetWindowSizeInPixels;
import static org.lwjgl.sdl.SDLVideo.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER;
import static org.lwjgl.sdl.SDLVideo.SDL_WINDOW_METAL;
import static org.lwjgl.sdl.SDLProperties.SDL_GetPointerProperty;
import static org.lwjgl.sdl.SDLMetal.SDL_Metal_CreateView;
import static org.lwjgl.sdl.SDLMetal.SDL_Metal_DestroyView;
import static org.lwjgl.sdl.SDLMetal.SDL_Metal_GetLayer;
import static org.lwjgl.system.JNI.invokeP;
import static org.lwjgl.system.JNI.invokePPD;
import static org.lwjgl.system.JNI.invokePPJ;
import static org.lwjgl.system.JNI.invokePPP;
import static org.lwjgl.system.JNI.invokePPV;
import static org.lwjgl.system.JNI.invokePPZ;
import static org.lwjgl.system.MemoryUtil.NULL;
import static org.lwjgl.system.MemoryUtil.memAddress;
import static org.lwjgl.system.MemoryUtil.memUTF8;
import static org.lwjgl.system.libffi.LibFFI.FFI_DEFAULT_ABI;
import static org.lwjgl.system.libffi.LibFFI.FFI_OK;
import static org.lwjgl.system.libffi.LibFFI.ffi_call;
import static org.lwjgl.system.libffi.LibFFI.ffi_prep_cif;
import static org.lwjgl.system.libffi.LibFFI.ffi_type_double;
import static org.lwjgl.system.libffi.LibFFI.ffi_type_pointer;
import static org.lwjgl.system.libffi.LibFFI.ffi_type_void;
import static org.lwjgl.system.macosx.ObjCRuntime.objc_getClass;
import static org.lwjgl.system.macosx.ObjCRuntime.sel_getUid;

/** Objective-C calls use ABI-correct LWJGL JNI/libffi signatures, without preview FFM. */
public final class CocoaMetalBridge {
    private CocoaMetalBridge() { }

    // Frameworks remain loaded for the process lifetime, as do their registered ObjC classes.
    private static final class Native {
        static final SharedLibrary QUARTZ = Library.loadNative(CocoaMetalBridge.class, "org.lwjgl",
                "/System/Library/Frameworks/QuartzCore.framework/QuartzCore");
        static final SharedLibrary METAL = Library.loadNative(CocoaMetalBridge.class, "org.lwjgl",
                "/System/Library/Frameworks/Metal.framework/Metal");
        static final long SEND = ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");
    }

    public record DeviceInfo(String name, long registryId, boolean unifiedMemory) { }

    public static DeviceInfo deviceInfo() {
        HostPlatform.requireSupported();
        long pool = message(message(objc_getClass("NSAutoreleasePool"), "alloc"), "init");
        long device = invokeP(Native.METAL.getFunctionAddress("MTLCreateSystemDefaultDevice"));
        try {
            requirePointer(device, "Metal device");
            return new DeviceInfo(memUTF8(message(message(device, "name"), "UTF8String")),
                    invokePPJ(device, sel_getUid("registryID"), Native.SEND),
                    invokePPZ(device, sel_getUid("hasUnifiedMemory"), Native.SEND));
        } finally {
            if (device != NULL) sendVoid(device, "release");
            sendVoid(pool, "drain");
        }
    }

    public record WindowInfo(long nsWindow, long contentView, double scale) { }
    public record PixelExtent(int width, int height, double scale) { }

    /** SDL_Window* is not a GLFWwindow*. Minecraft 26.3 uses SDL3 exclusively. */
    public static WindowInfo windowInfo(long sdlWindow) {
        HostPlatform.requireSupported();
        requireMainThread();
        long window = requirePointer(SDL_GetPointerProperty(SDL_GetWindowProperties(sdlWindow),
                SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL), "NSWindow");
        return new WindowInfo(window, requirePointer(message(window, "contentView"), "NSView"),
                invokePPD(window, sel_getUid("backingScaleFactor"), Native.SEND));
    }

    /**
     * Attach only to a window created for Metal, before creating its renderer.
     * SDL creates the layer-hosting NSView and CAMetalLayer and tracks resizes.
     * The caller must not attach a second view to the same surface.
     */
    public static Attachment attach(long sdlWindow) {
        WindowInfo info = windowInfo(sdlWindow);
        if ((SDL_GetWindowFlags(sdlWindow) & SDL_WINDOW_METAL) == 0) {
            throw new IllegalArgumentException("Attach CAMetalLayer only to SDL_WINDOW_METAL windows.");
        }
        long view = requirePointer(SDL_Metal_CreateView(sdlWindow), "SDL Metal view");
        try {
            long layer = requirePointer(SDL_Metal_GetLayer(view), "CAMetalLayer");
            setDouble(layer, "setContentsScale:", info.scale());
            MetalNative.load();
            return new Attachment(sdlWindow, view, layer, MetalNative.registerLayer(layer));
        } catch (RuntimeException | Error error) {
            SDL_Metal_DestroyView(view);
            throw error;
        }
    }

    private static long message(long receiver, String selector) {
        return invokePPP(receiver, sel_getUid(selector), Native.SEND);
    }

    private static void sendVoid(long receiver, String selector) {
        invokePPV(receiver, sel_getUid(selector), Native.SEND);
    }

    private static long requirePointer(long pointer, String name) {
        if (pointer == NULL) throw new IllegalStateException("Unable to obtain " + name + ".");
        return pointer;
    }

    public static void requireMainThread() {
        if (!invokePPZ(objc_getClass("NSThread"), sel_getUid("isMainThread"), Native.SEND)) {
            throw new IllegalStateException("Cocoa window operations require the main thread; launch with -XstartOnFirstThread.");
        }
    }

    // CGFloat is double on both supported 64-bit macOS architectures. JNI's float/int signatures cannot be substituted.
    private static void setDouble(long receiver, String selector, double value) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            FFICIF cif = FFICIF.calloc(stack);
            int result = ffi_prep_cif(cif, FFI_DEFAULT_ABI, ffi_type_void,
                    stack.pointers(ffi_type_pointer.address(), ffi_type_pointer.address(), ffi_type_double.address()));
            if (result != FFI_OK) throw new IllegalStateException("Cannot prepare Objective-C CGFloat call: " + result);
            ffi_call(cif, Native.SEND, null, stack.pointers(
                    memAddress(stack.pointers(receiver)), memAddress(stack.pointers(sel_getUid(selector))),
                    memAddress(stack.doubles(value))));
        }
    }

    /** Drain and close the Metal renderer before closing this attachment. */
    public static final class Attachment implements AutoCloseable {
        private final long window;
        private final long view;
        private long layer;
        private long nativeLayer;

        private Attachment(long window, long view, long layer, long nativeLayer) {
            this.window = window;
            this.view = view;
            this.layer = layer;
            this.nativeLayer = nativeLayer;
        }

        public long layer() {
            if (layer == NULL) throw new IllegalStateException("Metal layer attachment is closed.");
            return nativeLayer;
        }

        public void updateScale() {
            if (layer == NULL) throw new IllegalStateException("Metal layer attachment is closed.");
            setDouble(layer, "setContentsScale:", windowInfo(window).scale());
        }

        public PixelExtent pixelExtent() {
            if (layer == NULL) throw new IllegalStateException("Metal layer attachment is closed.");
            double scale = windowInfo(window).scale();
            try (MemoryStack stack = MemoryStack.stackPush()) {
                var width = stack.mallocInt(1);
                var height = stack.mallocInt(1);
                if (!SDL_GetWindowSizeInPixels(window, width, height))
                    throw new IllegalStateException("SDL could not query the Metal window pixel extent");
                return new PixelExtent(width.get(0), height.get(0), scale);
            }
        }

        @Override
        public void close() {
            if (layer == NULL) return;
            requireMainThread();
            MetalNative.releaseResource(nativeLayer);
            nativeLayer = NULL;
            SDL_Metal_DestroyView(view);
            layer = NULL;
        }
    }
}
