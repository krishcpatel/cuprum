# Metal backend validation — 2026-10-09

## Environment and build

Validation ran on an Apple M1 Pro, macOS 26.6.2, with JDK 25, Minecraft 26.3,
Fabric Loader 0.19.5, LWJGL 3.4.3 and Fabric Loom 1.17.21. Fabric API is not a
required dependency. The Gradle daemon and Java compile/test/launch toolchains
are pinned to Java 25.

Apple clang compiled the native bridge with `-O3 -fobjc-arc -Wall -Wextra -Werror`,
`-arch arm64 -arch x86_64` and `-mmacosx-version-min=11.0`. `lipo` verified both
slices and `otool -l` reported `minos 11.0` for each. The release jar includes the
universal native library; its direct load commands contain Apple system frameworks
and libraries, with no OpenGL, Vulkan or MoltenVK link.

## Implementation coverage

| Phase | Changes and checks |
| --- | --- |
| Toolchain and deployment | Java 25 daemon/compiler/test/client; universal macOS 11 dylib; negotiated MSL 2.3/2.4; hosted build and physical-Mac GPU workflows. |
| Pipeline preparation | Native libraries and all supported depth PSO variants compiled during worker preparation; pure draw-time lookup; shared immutable PSO cache; presentation, fan and common clear shaders prepared at device creation. |
| JNI and resource safety | Typed opaque registry handles, device/thread ownership, descriptor and range validation, mapped-storage pins, transient-generation guards, cleanup after callback and GPU failures. |
| RenderPearl | Existing direct/indexed/instanced/indirect and fan draw paths hardened; logical bounds and alignment checks; mip generation and texture transfer checks; actual GPU diagnostics and timing metrics. |
| Surface | Pixel-size and backing-scale comparisons, suboptimal queries, minimized/unavailable drawable recovery, triple-buffered completion throttling, guarded reconfiguration and frame cancellation. |
| Verification | 26 tests on both MSL versions, 192 vanilla pipelines per version, native smoke, title screen and single-player world, process library inspection. |

Minecraft's `ShaderManager.reload` prepares both `RenderPipelines.requiredPipelines()`
and `optionalPipelines()` before applying the reload. Native PSOs now participate in
that preparation. Cache tests confirm duplicate preparation and variant selection
cause no additional library or PSO compilation. The PSO key includes shaders,
vertex layouts, target formats, blend state and sample count (one in this API).
A resource reload or newly allocated unusual render target can still require
preparation; no claim of zero driver latency or measured frame-time improvement is
made. Indirect triangle fans retain an explicit GPU synchronization compatibility
path and are slower than normal draws.

## Executed checks

```sh
MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1 ./gradlew clean build nativeSmoke
CUPRUM_MSL_VERSION=20300 MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1 \
  ./gradlew test --rerun-tasks
lipo build/generated/metal-native/native/macos-universal/libcuprum_metal.dylib \
  -verify_arch arm64
lipo build/generated/metal-native/native/macos-universal/libcuprum_metal.dylib \
  -verify_arch x86_64
```

Both test runs passed **26 tests, zero failures, zero skipped**. Each compiled all
**192** registered vanilla pipelines through the real GLSL/SPIR-V frontend and
SPIRV-Cross into native Metal pipeline states. The compatibility test asserts that
MSL 20300 was selected. Safety checks include forged, stale, foreign and mistyped
handles, invalid descriptors, buffer ranges, index alignment and texture regions,
then valid GPU commands to verify recovery. Memory checks cover mapped buffers,
stale upload-arena slices, live-map submission rejection, callback cleanup,
readback after Java buffer close, R8 odd row strides, RGBA16F and mip generation.

`nativeSmoke` passed 120 textured diagnostic frames with GPU pixel readback and
resize/zero-size/cancellation checks, followed by 36 RenderPearl surface frames
covering fullscreen, minimization and reconfiguration. Metal API validation was
enabled; no Metal validation errors or critical Metal warnings were observed.

A Fabric client launched under the same Metal validation environment. The title
screen displayed background, logo, text and buttons. A copied single-player world
was then loaded using `--quickPlaySingleplayer CuprumValidation`; the original world
was preserved. GPU captures showed textured terrain and vegetation, sky and clouds,
lighting, the held item, hotbar and diagnostic text with the active Metal backend.
The world client remained active for several minutes without observed Metal errors.
It was then intentionally stopped with SIGTERM; Gradle reported exit 143 for that
manual termination, not a renderer exception.
Development-account authentication/Realms errors and a vanilla missing
`minecraft:end_of_frame` post-effect warning occurred; these are not described as
Metal validation successes or failures.

Local review artifacts (generated, not committed) are in `build/verification/`:

- `cuprum-verified-title.png`: presented title image.
- `cuprum-final-verification-world.png`: presented world image.
- `cuprum-world-vmmap.txt`: client process map.
- `msl24/test/` and `msl23/test/`: separate JUnit XML result sets.

## Process libraries and API limits

The actual client process map includes Metal, QuartzCore and Cuprum's native dylib.
No LWJGL OpenGL driver, Vulkan loader, MoltenVK or AWT renderer was mapped. Cuprum
skips both vanilla graphics-driver loaders and creates an SDL Metal window without
OpenGL/Vulkan flags. CPU PNG capture avoids bringing AWT graphics drivers into the
process.

**The requested absence of every `OpenGL.framework` mapping is not achieved.** On
this host, Apple's required system frameworks load it transitively. A minimal
Objective-C executable linked only to Foundation, Metal and QuartzCore already
maps it before creating a Metal device. This is distinct from Cuprum creating a GL
context or issuing rendering commands through OpenGL. The native dylib has no direct
OpenGL link. Process inspection cannot alone prove that no third-party code ever
calls a system GL symbol.

**The current RenderPearl contract has no front-cull selection, dynamic winding,
depth-bounds range or stencil-test/write-mask settings.** It exposes back/none
culling, fixed coordinate conventions, depth comparisons/write/bias and packed
depth/stencil formats. Supporting new configurable settings would require an API
extension, not extra hooks to old `GlStateManager` calls. They are not claimed as
completed interface implementations.

## Remaining hardware and visual verification

The deployment target and both binary slices are verified, but **macOS 11 and Intel
GPU execution have not been tested**. Forcing MSL 2.3 on a newer M1 host tests compiler
compatibility, not the complete older-OS driver stack. The physical-Mac CI workflow
requires an appropriately labeled runner and has not been executed on GitHub here.

The title and world captures establish an actual game boot and world render; they
do not establish complete visual parity for every entity, animation, translucent
water effect, particle, dynamic lighting update, post-processing pass, dimension,
shader pack or mod. Several of these paths have shader and GPU integration coverage,
but comprehensive scene-by-scene comparison, long-duration soak tests and performance
benchmarks remain necessary before calling this production-ready.
