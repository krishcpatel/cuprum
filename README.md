# Cuprum

Cuprum replaces Minecraft Java **26.3** rendering with a direct **Apple Metal**
backend. It targets Fabric Loader **0.19.5+**, Java **25**, and macOS **11+** with
an ARM64 or x86_64 Java runtime. Fabric API is not required.

Minecraft 26.3 uses **RenderPearl and SDL3**. Cuprum implements RenderPearl's device,
command encoder, resources, pipelines and surface interfaces; it does not patch
obsolete GLFW or `BufferRenderer` calls. Metal is selected by default on supported
Macs, with no automatic fallback to another renderer.

Minecraft's shader frontend produces SPIR-V, which its existing SPIRV-Cross
library translates to MSL. All GPU execution uses Apple's Metal API. **No Vulkan
instance, Vulkan driver, MoltenVK or VulkanMod is used.** Minecraft still supplies
Vulkan artifacts on its dependency classpath; Cuprum bypasses their initialization.

## Build and run

Install JDK **25**, Xcode Command Line Tools and a compatible macOS graphical
session. Set `JAVA_HOME` to JDK 25, then run:

```sh
./gradlew clean build
./gradlew runClient
```

The build compiles both Objective-C implementations into a **universal
ARM64/x86_64 dylib**, links Metal, Cocoa, Foundation and QuartzCore, and packages it
at `native/macos-universal/libcuprum_metal.dylib` inside
`build/libs/cuprum-0.1.0-SNAPSHOT.jar`. Install that jar in a Minecraft 26.3 Fabric
profile. Native release jars must be built on macOS; Java compilation and platform
checks can run elsewhere. The source jar includes the native implementations and shared handle registry.
Gradle daemon, compilation, test and development launch toolchains are pinned to
Java 25. Apple clang uses `-O3 -fobjc-arc -Wall -Wextra -Werror` and a macOS 11.0
deployment target for both architecture slices.

`-XstartOnFirstThread` and `--enable-native-access=ALL-UNNAMED` are configured for
development runs. Keep the launcher's macOS first-thread option enabled in normal
Minecraft profiles.

## Verification

```sh
MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1 ./gradlew test
CUPRUM_MSL_VERSION=20300 MTL_DEBUG_LAYER=1 ./gradlew test --rerun-tasks
MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1 ./gradlew nativeSmoke
```

The shader integration test compiles all **192 registered vanilla pipelines**, including
terrain, entity, GUI, sky, clouds and post-processing, through Minecraft's GLSL/SPIR-V
frontend into MSL and actual Metal PSOs, including supported depth attachment
variants. MSL 2.4 is negotiated on macOS 12+, with MSL 2.3 on macOS 11;
`CUPRUM_MSL_VERSION=20300` exercises the compatibility path on newer hosts.
Native compilation happens during pipeline preparation, and draw-time variant
selection only looks up prepared states. Native integration tests verify textured
indexed rendering, uniform and texel-buffer
bindings, blending, depth, scissor, partial clears, GPU triangle-fan expansion, timestamp
queries inside and outside passes, asynchronous readback, atlas mip uploads,
independent lightmap/overlay sampler slots, triangle strips, odd texture row strides,
repeated upload-arena reuse, offscreen scissors, unfinished-pass cleanup and callback
failure recovery. Native tests run only on compatible Macs.
`nativeSmoke` additionally opens a Metal window, renders and reads back 120 frames,
checks resizing, fullscreen, minimization and cancellation, and rejects loaded
LWJGL OpenGL/Vulkan/MoltenVK libraries. Apple system frameworks can transitively
map `OpenGL.framework` even without a GL context; see the validation report.

The actual Fabric client has been exercised through resource loading, title-screen
rendering and a single-player world with Metal API validation on an **M1 Pro**.
See [architecture](docs/architecture.md) and the [validation report](docs/validation.md). Universal Intel
compilation is verified; macOS 11 and Intel GPU execution and third-party shader packs remain
unvalidated. This is an experimental renderer, not a claim of complete mod
compatibility or a benchmarked performance improvement.

## Configuration

- `-Dcuprum.backend=metal`: default, renders Minecraft through Metal.
- `-Dcuprum.enabled=false`: disables Cuprum's backend hooks.
- `-Dcuprum.nativeLibrary=/absolute/path/libcuprum_metal.dylib`: development override.
- `-Dcuprum.captureFrame=/absolute/path/frame.png`: captures the presented image
  orientation after 300 frames. `-Dcuprum.captureFrameNumber=900` changes the frame.
- `-Dcuprum.dumpShaders=/absolute/path/directory`: writes translated MSL for inspection.

Unsupported operating systems or architectures fail immediately with a descriptive
platform error. Native initialization failures also abort startup. Metal is the only
supported backend; `cuprum.backend=diagnostic` is rejected.

## License

Original Cuprum source is **LGPL-3.0-only**. See [LICENSE.txt](LICENSE.txt),
[COPYING](COPYING) and [NOTICE.md](NOTICE.md). Third-party libraries retain their
licenses. Apple's system frameworks are linked, not distributed.
