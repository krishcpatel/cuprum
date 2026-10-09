// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.engine.CuprumFramePresenter;
import com.mojang.renderpearl.api.device.GpuSurface;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

@Mixin(Minecraft.class)
public abstract class FramePresentMixin {
    @Redirect(method = "renderFrame(Z)V", at = @At(value = "INVOKE",
            target = "Lcom/mojang/renderpearl/api/device/GpuSurface;present()V"))
    private void cuprum$present(GpuSurface surface) {
        CuprumFramePresenter.present(surface);
    }
}
