// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.mojang.renderpearl.api.device.GpuSurface;

/** Single presentation boundary; MetalSurface finalizes any remaining pass and submission. */
public final class CuprumFramePresenter {
    private CuprumFramePresenter() { }

    public static void present(GpuSurface surface) {
        // Surface ownership includes draining any unfinished encoder before releasing the drawable.
        surface.present();
    }
}
