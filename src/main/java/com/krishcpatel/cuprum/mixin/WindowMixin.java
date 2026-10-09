// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.mixin;

import com.krishcpatel.cuprum.CuprumMod;
import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.engine.CuprumBackend;
import com.mojang.blaze3d.platform.Window;
import com.mojang.renderpearl.api.device.GpuBackend;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(Window.class)
public abstract class WindowMixin {
    @Inject(method = "createWindow", at = @At("RETURN"))
    private void cuprum$windowCreated(GpuBackend backend, int width, int height, String title,
                                     CallbackInfoReturnable<Long> callback) {
        if (backend instanceof CuprumBackend && callback.getReturnValue() != 0) {
            var window = CocoaMetalBridge.windowInfo(callback.getReturnValue());
            CuprumMod.LOGGER.info("Cocoa window ready; Retina backing scale: {}", window.scale());
            // CuprumBackend creates SDL_WINDOW_METAL, without an OpenGL context.
            // The Metal device adapter attaches exactly one SDL-managed Metal view.
        }
    }
}
