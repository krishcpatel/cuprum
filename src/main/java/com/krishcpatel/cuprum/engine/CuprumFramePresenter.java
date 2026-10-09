// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.mojang.renderpearl.api.device.GpuSurface;

/** Single presentation boundary; the caller already submitted the command encoder. */
public final class CuprumFramePresenter {
    private CuprumFramePresenter() { }

    public static void present(GpuSurface surface) {
        // Rendering and drawable presentation have been scheduled before encoder submission.
        surface.present();
    }
}
