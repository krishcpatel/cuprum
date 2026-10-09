// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.engine.CuprumBackend;
import com.mojang.renderpearl.api.device.GpuBackend;
import com.mojang.renderpearl.backend.opengl.GlBackend;
import net.minecraft.client.PreferredGraphicsApi;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(PreferredGraphicsApi.class)
public abstract class BackendSelectionMixin {
    @Inject(method = "getBackendsToTry", at = @At("HEAD"), cancellable = true)
    private void cuprum$chooseBackend(CallbackInfoReturnable<GpuBackend[]> callback) {
        if (CuprumBackend.enabled()) {
            // Metal is the default and has no automatic graphics-API fallback.
            // Diagnostic mode stays usable through OpenGL and never tries Vulkan.
            callback.setReturnValue(CuprumBackend.takeoverRequested()
                    ? new GpuBackend[]{new CuprumBackend()} : new GpuBackend[]{new GlBackend()});
        }
    }
}
