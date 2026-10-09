# Cuprum

Cuprum is a **direct Apple Metal renderer project** for Minecraft Java **26.3**,
Fabric Loader **0.19.5+**, Java **25**, and macOS **13+** on Apple Silicon. Its
rendering path uses Metal command queues, render pipeline states, MSL shaders,
shared buffers, textures and CAMetalLayer drawables. Vulkan and MoltenVK are not
part of Cuprum's renderer.

The current deliverable is a native renderer foundation with a working textured
rendering test. **The Minecraft RenderPearl device adapter is not implemented yet;
Minecraft gameplay is not currently rendered by Cuprum's Metal renderer.** The
previous Vulkan-backed game integration has been removed.

## Build and run

Install an ARM64 **JDK 25** and Xcode Command Line Tools, set `JAVA_HOME` to that
JDK, then run on macOS ARM64:

```sh
./gradlew build
./gradlew nativeSmoke
```

The build compiles `src/main/native/cuprum_metal.m` into
`libcuprum_metal.dylib`, linking directly to Apple's Metal, QuartzCore and Foundation
frameworks. It embeds the dylib in the mod jar and embeds the MSL source used to
create the pipeline at runtime. JNI uses ARC-managed Objective-C objects, not
preview Java APIs. Minecraft supplies LWJGL core and SDL3; Cuprum adds no Vulkan
module or MoltenVK native dependency.

`nativeSmoke` creates an SDL3 Metal window and draws 120 textured triangles through
Metal. It reads the rendered GPU pixels back and verifies the expected color,
resizes the drawable, and tests zero-size surfaces and cancellation. It also checks
the process's loaded dylibs to verify that no Vulkan loader or MoltenVK was loaded.
The test needs a logged-in macOS graphical session. `-XstartOnFirstThread` and
`--enable-native-access=ALL-UNNAMED` are configured for development runs.

The output is `build/libs/cuprum-0.1.0-SNAPSHOT.jar`. Source and license material for
the JNI bridge is also included in the sources artifact. A native release jar must
be built on macOS ARM64; Java compilation and platform tests can run elsewhere.

## Minecraft integration status

Install the jar in a Minecraft **26.3** Fabric profile if you want native diagnostics.
Fabric API is not required. The default mode is deliberately `diagnostic`:

```sh
./gradlew runClient
```

In diagnostic mode, Cuprum reports Metal hardware information and Minecraft uses
its **OpenGL** renderer. On supported Macs, Cuprum skips Minecraft's Vulkan loader
initialization and excludes Vulkan from backend selection. Minecraft's dependency
classpath still contains its own Vulkan artifacts; Cuprum does not invoke or
initialize them. This distinction matters because the native Metal test works,
but a full replacement game renderer is still future work.

`-Dcuprum.backend=metal` requests the future Metal game backend explicitly. That
request currently fails with a clear adapter-not-implemented message, with no
fallback to another graphics API. It is an integration boundary, not a playable
Metal mode. `-Dcuprum.enabled=false` disables Cuprum's hooks and restores vanilla
behavior, including vanilla's available backend choices. Unsupported hosts also
retain vanilla behavior and skip Cuprum diagnostics.

See [the architecture notes](docs/architecture.md) for the implemented native path,
resource ownership, the shader/buffer layout, and the remaining Minecraft adapter
contracts.

## License

Cuprum's original source is **LGPL-3.0-only**. See [LICENSE.txt](LICENSE.txt),
[COPYING](COPYING), and [NOTICE.md](NOTICE.md). Minecraft and third-party libraries
retain their own licenses. Apple's frameworks are linked as system libraries and
are not distributed in the mod jar.
