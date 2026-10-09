// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.engine.CuprumBackend;
import com.mojang.renderpearl.api.device.GpuBackend;
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
            CuprumBackend.takeoverRequested(); // Reject obsolete/unknown backend settings explicitly.
            callback.setReturnValue(new GpuBackend[]{new CuprumBackend()});
        }
    }
}
