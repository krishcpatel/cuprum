// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.device.GpuSurface;
import com.mojang.renderpearl.api.device.SurfaceException;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.GpuSurfaceBackend;

import java.util.Collection;
import java.util.List;
import java.util.function.BooleanSupplier;

final class MetalSurface implements GpuSurfaceBackend {
    final MetalDevice device;
    final BooleanSupplier iconified;
    final CocoaMetalBridge.Attachment layer;
    private int frames;
    GpuSurface.Configuration config;
    boolean acquired;
    boolean closed;

    MetalSurface(MetalDevice device, long window, BooleanSupplier iconified) {
        this.device = device;
        this.iconified = iconified;
        layer = CocoaMetalBridge.attach(window);
        device.resources.add(this);
    }

    @Override
    public void configure(GpuSurface.Configuration config) throws SurfaceException {
        device.checkThread();
        if (closed) throw new SurfaceException("Metal surface is closed");
        if (acquired) throw new SurfaceException("Cannot configure an acquired Metal drawable");
        if (config.width() <= 0 || config.height() <= 0) throw new SurfaceException("Zero drawable extent");
        this.config = config;
    }

    @Override
    public boolean isSuboptimal() {
        return false;
    }

    @Override
    public void acquireNextTexture() throws SurfaceException {
        device.checkThread();
        if (closed || acquired || config == null) throw new SurfaceException("Invalid Metal acquisition lifecycle");
        layer.updateScale();
        if (iconified.getAsBoolean() || MetalBackendNative.acquire(device.handle, layer.layer(), config.width(), config.height(), config.presentMode() == GpuSurface.PresentMode.FIFO) == 0)
            throw new SurfaceException("Metal drawable is unavailable");
        acquired = true;
    }

    @Override
    public void blitFromTexture(CommandEncoderBackend encoder, GpuTextureView view) {
        device.checkThread();
        if (!acquired) throw new IllegalStateException("No drawable acquired");
        if (encoder != device.encoder) throw new IllegalArgumentException("Foreign command encoder");
        device.requireOwned(view);
        device.encoder.finishPass();
        MetalBackendNative.blitDrawable(device.handle, ((MetalResources.View) view).handle());
        String capture = System.getProperty("cuprum.captureFrame");
        if (++frames == Integer.getInteger("cuprum.captureFrameNumber", 300) && capture != null) {
            capture(view, capture, true);
            if (Boolean.getBoolean("cuprum.captureTextures")) for (var resource : List.copyOf(device.resources)) {
                if (resource instanceof MetalResources.Texture texture && texture.getFormat() == com.mojang.renderpearl.api.GpuFormat.RGBA8_UNORM && (texture.getWidth(0) >= 1024 || texture.getLabel().toLowerCase(java.util.Locale.ROOT).contains("light"))) {
                    try (var textureView = new MetalResources.View(texture, 0, 1)) {
                        capture(textureView, capture + "_" + texture.getLabel().replaceAll("[^a-zA-Z0-9_-]", "_") + "_" + texture.handle() + ".png", false);
                    }
                }
            }
        }
    }

    private void capture(GpuTextureView view, String path, boolean flip) {
        int width = view.texture().getWidth(view.baseMipLevel());
        int height = view.texture().getHeight(view.baseMipLevel());
        int stride = (width * 4 + 255) & -256;
        long buffer = MetalBackendNative.buffer(device.handle, (long) stride * height);
        try {
            MetalBackendNative.bufferTexture(device.handle, buffer, 0, stride, stride * height,
                    ((MetalResources.View) view).handle(), 0, 0, 0, 0, width, height, false);
            long command = MetalBackendNative.submit(device.handle, true);
            MetalBackendNative.release(command);
            var bytes = MetalBackendNative.mapBuffer(buffer, 0, stride * height);
            var image = new java.awt.image.BufferedImage(width, height, java.awt.image.BufferedImage.TYPE_INT_ARGB);
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++) {
                    int offset = y * stride + x * 4;
                    image.setRGB(x, flip ? height - 1 - y : y, ((bytes.get(offset + 3) & 255) << 24)
                            | ((bytes.get(offset) & 255) << 16) | ((bytes.get(offset + 1) & 255) << 8)
                            | (bytes.get(offset + 2) & 255));
                }
            javax.imageio.ImageIO.write(image, "png", new java.io.File(path));
        } catch (java.io.IOException error) {
            throw new IllegalStateException("Unable to save Metal validation frame", error);
        } finally {
            MetalBackendNative.release(buffer);
        }
    }

    @Override
    public void present() {
        device.checkThread();
        if (!acquired) throw new IllegalStateException("No drawable acquired");
        device.encoder.finishFrame();
        MetalBackendNative.present(device.handle);
        acquired = false;
    }

    @Override
    public Collection<GpuSurface.PresentMode> supportedPresentModes() {
        return List.of(GpuSurface.PresentMode.FIFO, GpuSurface.PresentMode.IMMEDIATE);
    }

    @Override
    public void close() {
        device.checkThread();
        if (closed) return;
        if (acquired) present();
        device.encoder.sync();
        layer.close();
        closed = true;
        device.resources.remove(this);
    }
}
