// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine.metal;

import com.krishcpatel.cuprum.bridge.MetalBackendNative;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.textures.AddressMode;
import com.mojang.renderpearl.api.textures.FilterMode;
import com.mojang.renderpearl.api.textures.GpuSampler;
import com.mojang.renderpearl.backend.common.BaseGpuTexture;
import com.mojang.renderpearl.backend.common.BaseGpuTextureView;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.OptionalDouble;

final class MetalResources {
    private MetalResources() {
    }

    static final class Buffer implements GpuBuffer {
        final MetalDevice owner;
        final long size;
        final int usage;
        final boolean transientAllocation;
        long handle;

        Buffer(MetalDevice owner, int usage, long size, boolean transientAllocation) {
            if (size <= 0 || size > owner.info.limits().maxMemoryAllocationSize())
                throw new IllegalArgumentException("Invalid buffer allocation size: " + size);
            this.owner = owner;
            this.usage = usage;
            this.size = size;
            this.transientAllocation = transientAllocation;
            handle = MetalBackendNative.buffer(owner.handle, size);
            owner.resources.add(this);
        }

        long handle() {
            owner.checkThread();
            if (handle == 0) throw new IllegalStateException("Buffer is closed");
            return handle;
        }

        ByteBuffer bytes(long offset, long length) {
            if (offset < 0 || length < 0 || offset > size - length)
                throw new IndexOutOfBoundsException("Buffer map outside logical allocation");
            return MetalBackendNative.mapBuffer(handle(), offset, Math.toIntExact(length)).order(ByteOrder.nativeOrder());
        }

        @Override
        public long size() {
            return size;
        }

        @Override
        public int usage() {
            return usage;
        }

        @Override
        public boolean isClosed() {
            return handle == 0;
        }

        @Override
        public GpuBufferSlice.MappedView map(long offset, long length, boolean read, boolean write) {
            if (read && (usage & USAGE_MAP_READ) == 0 || write && (usage & USAGE_MAP_WRITE) == 0)
                throw new IllegalArgumentException("Buffer was not allocated with the requested map usage");
            // RenderPearl fences write-mapped ring buffers before reusing their slots.
            if (read && !transientAllocation) owner.encoder.sync();
            return new GpuBufferSlice.MappedView(slice(offset, length), bytes(offset, length), () -> {
            });
        }

        @Override
        public void close() {
            owner.checkThread();
            if (handle != 0) {
                MetalBackendNative.release(handle);
                handle = 0;
                owner.resources.remove(this);
            }
        }
    }

    static final class Texture extends BaseGpuTexture {
        final MetalDevice owner;
        long handle;

        Texture(MetalDevice owner, String label, int usage, GpuFormat format, int w, int h, int layers, int mips) {
            super(usage, label, format, w, h, layers, mips);
            this.owner = owner;
            handle = MetalBackendNative.texture(owner.handle, format.ordinal(), w, h, layers, mips, usage);
            owner.resources.add(this);
        }

        long handle() {
            owner.checkThread();
            if (handle == 0) throw new IllegalStateException("Texture closed");
            return handle;
        }

        @Override
        public int getWidth(int mip) {
            return Math.max(1, super.getWidth(mip));
        }

        @Override
        public int getHeight(int mip) {
            return Math.max(1, super.getHeight(mip));
        }

        @Override
        public boolean isClosed() {
            return handle == 0;
        }

        @Override
        public void close() {
            owner.checkThread();
            if (handle != 0) {
                MetalBackendNative.release(handle);
                handle = 0;
                owner.resources.remove(this);
            }
        }
    }

    static final class View extends BaseGpuTextureView {
        final MetalDevice owner;
        long handle;

        View(Texture texture, int base, int count) {
            super(texture, base, count);
            owner = texture.owner;
            handle = MetalBackendNative.textureView(texture.handle(), base, count);
            owner.resources.add(this);
        }

        long handle() {
            owner.checkThread();
            if (isClosed()) throw new IllegalStateException("Texture view closed");
            return handle;
        }

        @Override
        public boolean isClosed() {
            return handle == 0 || texture().isClosed();
        }

        @Override
        public void close() {
            owner.checkThread();
            if (handle != 0) {
                MetalBackendNative.release(handle);
                handle = 0;
                owner.resources.remove(this);
            }
        }
    }

    static final class Sampler implements GpuSampler {
        final MetalDevice owner;
        final AddressMode u, v;
        final FilterMode min, mag;
        final int anisotropy;
        final OptionalDouble lod;
        long handle;

        Sampler(MetalDevice owner, AddressMode u, AddressMode v, FilterMode min, FilterMode mag, int anisotropy, OptionalDouble lod) {
            this.owner = owner;
            this.u = u;
            this.v = v;
            this.min = min;
            this.mag = mag;
            this.anisotropy = anisotropy;
            this.lod = lod;
            handle = MetalBackendNative.sampler(owner.handle, u.ordinal(), v.ordinal(), min.ordinal(), mag.ordinal(), anisotropy, lod.orElse(1000));
            owner.resources.add(this);
        }

        long handle() {
            owner.checkThread();
            if (handle == 0) throw new IllegalStateException("Sampler is closed");
            return handle;
        }

        @Override
        public AddressMode getAddressModeU() {
            return u;
        }

        @Override
        public AddressMode getAddressModeV() {
            return v;
        }

        @Override
        public FilterMode getMinFilter() {
            return min;
        }

        @Override
        public FilterMode getMagFilter() {
            return mag;
        }

        @Override
        public int getMaxAnisotropy() {
            return anisotropy;
        }

        @Override
        public OptionalDouble getMaxLod() {
            return lod;
        }

        @Override
        public boolean isClosed() {
            return handle == 0;
        }

        @Override
        public void close() {
            owner.checkThread();
            if (handle != 0) {
                MetalBackendNative.release(handle);
                handle = 0;
                owner.resources.remove(this);
            }
        }
    }
}
