// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.engine.CuprumBackend;
import com.mojang.blaze3d.platform.NativeLibrariesBootstrap;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/** Minecraft normally loads its Vulkan loader before choosing a renderer. */
@Mixin(NativeLibrariesBootstrap.class)
public abstract class NativeLibrariesBootstrapMixin {
    @Inject(method = "tryLoadingVulkan", at = @At("HEAD"), cancellable = true)
    private static void cuprum$skipVulkan(CallbackInfoReturnable<Boolean> callback) {
        if (CuprumBackend.enabled()) callback.setReturnValue(false);
    }
}
