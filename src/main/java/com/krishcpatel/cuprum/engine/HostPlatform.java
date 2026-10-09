// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import java.util.Locale;
import java.util.Optional;

/** Pure platform validation: safe to load before any native classes. */
public final class HostPlatform {
    private HostPlatform() { }

    public static Optional<String> unsupportedReason() {
        return unsupportedReason(System.getProperty("os.name", ""),
                System.getProperty("os.arch", ""), System.getProperty("os.version", ""));
    }

    public static Optional<String> unsupportedReason(String os, String arch, String version) {
        String normalized = os.toLowerCase(Locale.ROOT);
        if (!(normalized.equals("mac os x") || normalized.equals("macos") || normalized.equals("darwin"))) {
            return Optional.of("Cuprum requires macOS 13 or newer; detected " + os + ".");
        }
        if (!(arch.equalsIgnoreCase("aarch64") || arch.equalsIgnoreCase("arm64")
                || arch.equalsIgnoreCase("x86_64") || arch.equalsIgnoreCase("amd64"))) {
            return Optional.of("Cuprum requires an ARM64 or x86_64 Java runtime on macOS; detected " + arch
                    + ". Install Java 25 for your Mac architecture.");
        }
        try {
            if (Integer.parseInt(version.split("\\.")[0]) >= 13) {
                return Optional.empty();
            }
        } catch (NumberFormatException ignored) {
            // Fail closed if the operating system version cannot be established.
        }
        return Optional.of("Cuprum requires macOS 13 or newer; detected version " + version + ".");
    }

    public static void requireSupported() {
        unsupportedReason().ifPresent(reason -> { throw new IllegalStateException(reason); });
    }
}
