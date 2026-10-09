// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.bridge;

import com.krishcpatel.cuprum.engine.HostPlatform;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/** Small typed JNI boundary. Objective-C/Metal object pointers never escape the engine wrappers. */
public final class MetalNative {
    private static boolean loaded;

    private MetalNative() { }

    public static synchronized void load() {
        if (loaded) return;
        HostPlatform.requireSupported();
        String override = System.getProperty("cuprum.nativeLibrary");
        try {
            Path library;
            if (override != null) {
                library = Path.of(override).toRealPath();
            } else {
                try (var resource = MetalNative.class.getResourceAsStream("/native/macos-universal/libcuprum_metal.dylib")) {
                    if (resource == null) throw new IOException("The Cuprum universal macOS native bridge is missing. Build on macOS with Xcode Command Line Tools.");
                    library = Files.createTempFile("cuprum-metal-", ".dylib");
                    library.toFile().deleteOnExit();
                    Files.copy(resource, library, StandardCopyOption.REPLACE_EXISTING);
                }
            }
            System.load(library.toAbsolutePath().toString());
            loaded = true;
        } catch (IOException error) {
            throw new IllegalStateException("Cannot load Cuprum's direct Metal bridge.", error);
        }
    }

    public static native String[] loadedImagePaths();
    public static native long createRenderer(long metalLayer, String mslSource);
    public static native long createBuffer(long renderer, ByteBuffer bytes);
    public static native long createTexture(long renderer, int width, int height, ByteBuffer rgba);
    public static native boolean beginFrame(long renderer, int width, int height,
                                            double red, double green, double blue, double alpha);
    public static native void draw(long renderer, long vertices, long uniforms, long texture, int vertexCount);
    public static native byte[] finishFrame(long renderer, boolean wait, boolean readback);
    public static native void abortFrame(long renderer);
    public static native void releaseResource(long resource);
    public static native void destroyRenderer(long renderer);
}
