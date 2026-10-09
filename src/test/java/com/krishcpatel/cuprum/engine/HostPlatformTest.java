// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.engine;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.junit.jupiter.api.Assertions.assertEquals;

class HostPlatformTest {
    @ParameterizedTest
    @CsvSource({
            "Mac OS X,aarch64,13.0,true",
            "Mac OS X,arm64,15.1,true",
            "macOS,aarch64,26.0,true",
            "Darwin,arm64,26.0,true",
            "Mac OS X,x86_64,15.1,true",
            "Mac OS X,aarch64,12.7,true",
            "Mac OS X,x86_64,11.0,true",
            "Mac OS X,aarch64,10.15,false",
            "Mac OS X,aarch64,unknown,false",
            "Windows 11,aarch64,11.0,false",
            "Linux,aarch64,6.12,false"
    })
    void onlySupportsModernMacsWithCompatibleRuntime(String os, String arch, String version, boolean supported) {
        assertEquals(supported, HostPlatform.unsupportedReason(os, arch, version).isEmpty());
    }
}
