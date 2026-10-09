// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.CuprumMod;
import com.krishcpatel.cuprum.engine.CuprumBackend;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.api.device.GpuDevice;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(RenderSystem.class)
public abstract class RenderSystemMixin {
    @Inject(method = "initRenderer", at = @At("RETURN"))
    private static void cuprum$rendererReady(GpuDevice device, CallbackInfo callback) {
        if (CuprumBackend.enabled()) {
            CuprumMod.LOGGER.info("Active graphics backend: {}", device.getDeviceInfo().backendName());
        }
    }
}
