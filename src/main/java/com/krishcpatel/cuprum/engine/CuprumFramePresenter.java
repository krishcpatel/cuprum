// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.mojang.renderpearl.api.device.GpuSurface;

/** Single presentation boundary; the caller already submitted the command encoder. */
public final class CuprumFramePresenter {
    private CuprumFramePresenter() { }

    public static void present(GpuSurface surface) {
        // Integration seam for the future Metal GpuSurface adapter. In diagnostic
        // mode this is Minecraft's OpenGL surface. Submission happens before this
        // hook; never acquire another drawable or submit a second frame here.
        surface.present();
    }
}
