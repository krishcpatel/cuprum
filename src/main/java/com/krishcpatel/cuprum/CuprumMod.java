// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum;

import com.krishcpatel.cuprum.bridge.CocoaMetalBridge;
import com.krishcpatel.cuprum.bridge.MetalNative;
import com.krishcpatel.cuprum.engine.HostPlatform;
import net.fabricmc.api.ClientModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Native diagnostics only; the independent Metal renderer is exercised by nativeSmoke. */
public final class CuprumMod implements ClientModInitializer {
    public static final Logger LOGGER = LoggerFactory.getLogger("Cuprum");

    @Override
    public void onInitializeClient() {
        var unsupported = HostPlatform.unsupportedReason();
        if (unsupported.isPresent()) {
            LOGGER.error("{} Cuprum initialization has been skipped.", unsupported.get());
            return;
        }
        if (!Boolean.parseBoolean(System.getProperty("cuprum.enabled", "true"))) {
            LOGGER.info("Cuprum is disabled by cuprum.enabled=false.");
            return;
        }
        try {
            MetalNative.load();
            CocoaMetalBridge.DeviceInfo metal = CocoaMetalBridge.deviceInfo();
            LOGGER.info("Direct Metal device: {}; registry ID: 0x{}; unified memory: {}", metal.name(),
                    Long.toUnsignedString(metal.registryId(), 16), metal.unifiedMemory());
            LOGGER.info("Cuprum direct Metal foundation loaded. The Minecraft device adapter is pending; "
                    + "diagnostic mode uses Minecraft's OpenGL renderer. Run nativeSmoke to exercise Metal.");
        } catch (RuntimeException | LinkageError error) {
            LOGGER.error("Cuprum could not initialize its direct Metal bridge. Use macOS 13+, ARM64 Java 25, "
                    + "and a build containing libcuprum_metal.dylib.", error);
        }
    }
}
