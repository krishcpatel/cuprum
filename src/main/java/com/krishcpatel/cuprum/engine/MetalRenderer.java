// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.bridge.MetalNative;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Optional;
import java.util.Set;

/** Owns a direct Metal command queue and PSO, borrowing an attached CAMetalLayer. */
public final class MetalRenderer implements AutoCloseable {
    public static final int VERTEX_STRIDE = 24;
    public static final int UNIFORM_BYTES = 80;
    private final Thread owner = Thread.currentThread();
    private final Set<Resource> resources = new HashSet<>();
    private long handle;
    private Frame activeFrame;

    public MetalRenderer(CocoaMetalBridge.Attachment attachment) {
        HostPlatform.requireSupported();
        CocoaMetalBridge.requireMainThread();
        MetalNative.load();
        handle = MetalNative.createRenderer(attachment.layer(), shaderSource());
        if (handle == 0) throw new IllegalStateException("Metal renderer creation returned no device.");
    }

    private static String shaderSource() {
        try (var source = MetalRenderer.class.getResourceAsStream("/assets/cuprum/shaders/position_color_tex.metal")) {
            if (source == null) throw new IOException("Missing position_color_tex.metal.");
            return new String(source.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new IllegalStateException("Cannot read Cuprum's MSL shader.", error);
        }
    }

    public Buffer createBuffer(ByteBuffer bytes) {
        requireOpen();
        requireDirect(bytes);
        Buffer buffer = new Buffer(MetalNative.createBuffer(handle, bytes.slice()), bytes.remaining());
        resources.add(buffer);
        return buffer;
    }

    public Texture createTexture(int width, int height, ByteBuffer rgba) {
        requireOpen();
        requireDirect(rgba);
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384
                || (long) width * height * 4 != rgba.remaining()) {
            throw new IllegalArgumentException("Expected exactly width * height * 4 RGBA8 bytes within device limits.");
        }
        Texture texture = new Texture(MetalNative.createTexture(handle, width, height, rgba.slice()));
        resources.add(texture);
        return texture;
    }

    private static void requireDirect(ByteBuffer buffer) {
        if (buffer == null || !buffer.isDirect() || !buffer.hasRemaining()) {
            throw new IllegalArgumentException("Expected non-empty direct buffer data.");
        }
    }

    /** No drawable is acquired for a zero-size or temporarily unavailable surface. */
    public Optional<Frame> beginFrame(int width, int height, double red, double green, double blue, double alpha) {
        requireOpen();
        if (activeFrame != null) throw new IllegalStateException("Finish or cancel the active Metal frame first.");
        if (!Double.isFinite(red) || !Double.isFinite(green) || !Double.isFinite(blue) || !Double.isFinite(alpha)) {
            throw new IllegalArgumentException("Clear color components must be finite.");
        }
        if (!MetalNative.beginFrame(handle, width, height, red, green, blue, alpha)) return Optional.empty();
        activeFrame = new Frame();
        return Optional.of(activeFrame);
    }

    private void requireOwner() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Metal resources belong to their Cocoa render thread.");
    }

    private void requireOpen() {
        requireOwner();
        if (handle == 0) throw new IllegalStateException("Metal renderer is closed.");
    }

    @Override
    public void close() {
        requireOwner();
        if (handle == 0) return;
        if (activeFrame != null) activeFrame.close();
        // Drain queued work before releasing resources or detaching the layer.
        MetalNative.destroyRenderer(handle);
        handle = 0;
        for (Resource resource : Set.copyOf(resources)) resource.close();
    }

    public abstract sealed class Resource implements AutoCloseable permits Buffer, Texture {
        private long nativeHandle;

        private Resource(long nativeHandle) {
            if (nativeHandle == 0) throw new IllegalStateException("Metal resource allocation failed.");
            this.nativeHandle = nativeHandle;
        }

        private long nativeHandle() {
            requireOpen();
            if (nativeHandle == 0) throw new IllegalStateException("Metal resource is closed.");
            return nativeHandle;
        }

        @Override
        public final void close() {
            requireOwner();
            if (nativeHandle == 0) return;
            // Command buffers retain encoded resources until GPU completion.
            MetalNative.releaseResource(nativeHandle);
            nativeHandle = 0;
            resources.remove(this);
        }
    }

    public final class Buffer extends Resource {
        private final int size;

        private Buffer(long nativeHandle, int size) {
            super(nativeHandle);
            this.size = size;
        }

        public int size() { return size; }
    }

    public final class Texture extends Resource {
        private Texture(long nativeHandle) { super(nativeHandle); }
    }

    /** Explicit submission; closing an unsubmitted frame cancels it. */
    public final class Frame implements AutoCloseable {
        private Frame() { }

        private void requireRecording() {
            requireOpen();
            if (activeFrame != this) throw new IllegalStateException("This Metal frame is no longer recording.");
        }

        public void draw(Buffer vertices, Buffer uniforms, Texture texture, int vertexCount) {
            requireRecording();
            if (!resources.contains(vertices) || !resources.contains(uniforms) || !resources.contains(texture)) {
                throw new IllegalArgumentException("Draw resources must belong to this renderer and remain open.");
            }
            if (vertexCount <= 0 || vertexCount % 3 != 0 || (long) vertexCount * VERTEX_STRIDE > vertices.size
                    || uniforms.size != UNIFORM_BYTES) {
                throw new IllegalArgumentException("Expected complete triangles, packed 24-byte vertices and an 80-byte uniform block.");
            }
            MetalNative.draw(handle, ((Resource) vertices).nativeHandle(), ((Resource) uniforms).nativeHandle(),
                    ((Resource) texture).nativeHandle(), vertexCount);
        }

        public void submit() {
            requireRecording();
            try {
                MetalNative.finishFrame(handle, false, false);
            } finally {
                activeFrame = null;
            }
        }

        /** Diagnostic only: waits for GPU completion and returns tightly packed, top-down BGRA8 pixels. */
        public byte[] submitAndReadback() {
            requireRecording();
            try {
                return MetalNative.finishFrame(handle, true, true);
            } finally {
                activeFrame = null;
            }
        }

        @Override
        public void close() {
            requireOwner();
            if (activeFrame == this) {
                MetalNative.abortFrame(handle);
                activeFrame = null;
            }
        }
    }
}
