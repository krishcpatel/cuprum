// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import com.krishcpatel.cuprum.CuprumMod;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.parallel.ResourceLock;

import static org.junit.jupiter.api.Assertions.*;

@ResourceLock("java.lang.System.properties")
class CuprumBackendTest {
    @Test
    void unsupportedPlatformAbortsBeforeSelectingVanillaOrLoadingNativeCode() {
        String previous = System.getProperty("os.name");
        try {
            System.setProperty("os.name", "Linux");
            assertTrue(assertThrows(IllegalStateException.class, CuprumBackend::enabled).getMessage().contains("requires macOS"));
            assertThrows(IllegalStateException.class, () -> new CuprumMod().onInitializeClient());
        } finally {
            restore("os.name", previous);
        }
    }

    @Test
    void diagnosticSettingCannotSelectAnOpenGlFallback() {
        String previous = System.getProperty("cuprum.backend");
        try {
            System.setProperty("cuprum.backend", "diagnostic");
            assertTrue(assertThrows(IllegalArgumentException.class, CuprumBackend::takeoverRequested).getMessage().contains("only metal"));
            System.setProperty("cuprum.backend", "metal");
            assertTrue(CuprumBackend.takeoverRequested());
        } finally {
            restore("cuprum.backend", previous);
        }
    }

    private static void restore(String key, String value) {
        if (value == null) System.clearProperty(key);
        else System.setProperty(key, value);
    }
}
