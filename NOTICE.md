# Notices

Cuprum original source: Copyright (c) 2026 Krish C. Patel.
SPDX-License-Identifier: LGPL-3.0-only

The native Objective-C JNI bridge and MSL shader in this repository are original
Cuprum source and are covered by the same license. Their source is provided with
the sources artifact.

Cuprum depends on Minecraft Java Edition through Fabric Loom; Minecraft code and
assets are not included in the mod jar and are governed by Mojang's terms.
Fabric Loader, Sponge Mixin, LWJGL, shaderc, SPIRV-Cross and SDL3 retain their respective licenses.
LWJGL is BSD-licensed, shaderc and SPIRV-Cross are Apache-2.0-licensed, and SDL uses the zlib license. They are supplied by the game
runtime rather than redistributed inside Cuprum's mod jar.

The native bridge links directly to Apple's system Metal, Cocoa, QuartzCore and
Foundation frameworks. Apple frameworks are not redistributed. Cuprum does not
bundle or use MoltenVK, VulkanMod or a Vulkan rendering backend.
