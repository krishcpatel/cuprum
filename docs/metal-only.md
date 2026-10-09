# Making Cuprum exclusively Metal: research and implementation route

Research date: 2026-10-09. Local experiments: Apple M1 Pro, macOS 26.6.2.

## Conclusion

Cuprum can submit all game graphics work through Metal without creating an OpenGL
context, Vulkan instance or MoltenVK device. Its current RenderPearl path already
uses direct Metal objects and command buffers. The earlier library map did not
show a second active game renderer; it showed Apple framework dependencies.

A stronger requirement, **no OpenGL-named system image mapped anywhere in the
process**, cannot be met by this app on the tested stock OS using the required
frameworks. This finding is based on native reproductions, not an assumption from
Minecraft's process map. It is not a claim about every macOS release.

The recommended contract is: every game draw and presentation uses direct Metal;
no alternate application graphics backend initializes; incompatible graphics mods
fail instead of starting another renderer. An arbitrary native mod in the same
process can bypass application policy, so enforcement must include a tested mod
profile and runtime observation.

## Direct evidence from this Mac

`xcrun dyld_info -linked_dylibs` reports these actual Apple load commands:

```text
Metal.framework/Versions/A/Metal
  -> OpenGL.framework/Versions/A/Libraries/libCoreFSCache.dylib
QuartzCore.framework/Versions/A/QuartzCore
  -> OpenGL.framework/Versions/A/OpenGL
AppKit.framework/Versions/C/AppKit
  -> OpenGL.framework/Versions/A/OpenGL
```

`libCoreFSCache` being located inside the OpenGL framework is not proof that Metal
renders by translating through OpenGL. The presence of the full OpenGL image is
also not proof of GL context creation or GPU submission.

I compiled a tiny C loader probe. It creates no window and submits no graphics
commands. `_dyld_image_count()` / `_dyld_get_image_name()` enumerate the process's
loaded images. Separate executables differ only in their framework link flags:

| Probe | OpenGL.framework images before explicit calls in main |
| --- | ---: |
| C executable linked to libSystem only | 0 |
| Add Foundation | 8 |
| Add Metal | 8 |
| Add QuartzCore | 8 |
| Add Cocoa | 8 |
| Add Metal and Foundation, without Cocoa or QuartzCore link flags | 8 |

A C executable initially reporting zero such images reported eight immediately
after `dlopen()` of Metal. Creating a Metal device did not change that count.
Equivalent dynamic loads of QuartzCore and Cocoa also mapped them. Moving from
static framework linking to runtime loading therefore does not solve this host's
mapping requirement. Removing the explicit Cocoa link from Cuprum would not solve
it either; SDL's windowing implementation still uses Cocoa/AppKit and QuartzCore.

This experiment establishes **loading**, not use of the GL rendering API. Loading
can execute library initializers; it does not establish that any GL draw happened
or that two GPU render pipelines are working on the game. No performance or memory
saving should be inferred from merely deleting an unused backend jar.

Reproduce the experiment:

```sh
python3 scripts/audit-metal-libraries.py
```

The script compiles the independent C probe with Xcode tools and writes result
sets, actual framework load commands and a native import audit into
`build/verification/metal-only/`. It does not edit frameworks or change the game.
The local native import audit found **zero direct GL, CGL, Vulkan or SDL_GL imports**
in Cuprum's universal dylib. Import auditing alone cannot exclude indirect symbol
lookup or Objective-C dispatch; the source and runtime paths also need checking.

## What Cuprum already controls

The repository audit confirmed:

- `NativeLibrariesBootstrapMixin` cancels Minecraft's `loadOpenGL` and
  `tryLoadingVulkan` paths while Cuprum is enabled.
- `CuprumBackend.createWindow` rejects OpenGL/Vulkan flags and explicitly sets
  `SDL_WINDOW_METAL`. Backend selection chooses `MetalDevice` without automatic
  fallback to another renderer.
- Metal buffers, textures, pipeline states and render/blit/compute command encoders
  handle GPU work; a `CAMetalLayer` drawable is presented by the Metal queue.
- PNG capture uses a CPU encoder and avoids initializing an AWT graphics toolkit.
- The previously exercised title/world client process loaded no LWJGL OpenGL
  driver, Vulkan loader or MoltenVK library.

SDL source provides an additional reason to keep the explicit Metal window flag:
its macOS default can prefer OpenGL when no graphics flag is supplied. Its window
creation code treats Metal/OpenGL/Vulkan flags as mutually exclusive and loads GL
or Vulkan only for their corresponding branches. See [the exact SDL video source
for the bundled revision](https://github.com/libsdl-org/SDL/blob/62f10da/src/video/SDL_video.c).
SDL's Metal view is a CAMetalLayer-backed Cocoa view; it does not require creating
a GL context. See [SDL's Metal view implementation](https://github.com/libsdl-org/SDL/blob/62f10da/src/video/cocoa/SDL_cocoametalview.m).

GLSL and SPIR-V in the shader preparation path are not additional running graphics
APIs. GLSL is source text; SPIR-V is intermediate shader code. SPIRV-Cross translates
that code into MSL on the CPU, then Metal compiles and executes it. Replacing all
vanilla shader sources with handwritten MSL is unnecessary for a single-API GPU
backend and would complicate resource-pack compatibility. See [Khronos's SPIRV-Cross
Metal backend](https://github.com/KhronosGroup/SPIRV-Cross#metal-backend).
MoltenVK is a separate Vulkan-on-Metal implementation and is not part of Cuprum's
translation path; see [MoltenVK's own description](https://github.com/KhronosGroup/MoltenVK).

## Concrete next implementation steps

1. Keep the existing Metal selection and bootstrap interception. Add an early
   assertion that the actual selected RenderPearl device is Cuprum's Metal device,
   and recheck the window flags after fullscreen/resize transitions. Avoid silently
   accepting an alternative device or an implicitly created default SDL renderer.

2. Move the native-image rejection currently exercised by `NativeSmoke` into a
   reusable application diagnostic. Check at startup, after shader reload and
   periodically during validation. Reject non-system alternate driver images such
   as `liblwjgl_opengl`, `libMoltenVK`, Vulkan loaders, EGL/GLES and software GL
   replacements. Report Apple system dependencies separately. This detects an
   attempted alternate path after a library loads; it is not a sandbox that can
   prevent arbitrary native code from loading or making its first call.

3. For stricter capability removal, build a matching custom SDL. The supplied
   LWJGL native binary embeds `SDL-3.4.14-62f10da`; pin that upstream revision,
   build both architectures and preserve the required public ABI. Starting options:

   ```sh
   cmake -S SDL -B build/sdl-metal-only \
     -DCMAKE_BUILD_TYPE=Release \
     '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
     -DSDL_SHARED=ON -DSDL_STATIC=OFF \
     -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_VULKAN=OFF \
     -DSDL_METAL=ON -DSDL_GPU=OFF -DSDL_RENDER=OFF \
     -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF
   cmake --build build/sdl-metal-only --parallel
   ```

   SDL window/input/view support remains; its optional renderer and GPU abstraction
   are unnecessary for Cuprum's own native queue. These are proposed build settings,
   **not a custom SDL build or game integration completed in this research**.
   Verify that no required entry point disappears and validate the output's ABI,
   deployment metadata and both architecture slices. The supported build switches
   are defined in [SDL's pinned CMake configuration](https://github.com/libsdl-org/SDL/blob/62f10da/CMakeLists.txt).

4. Select the custom SDL before any LWJGL SDL class initializes:

   ```text
   -Dorg.lwjgl.sdl.libname=/absolute/path/to/custom/libSDL3.dylib
   ```

   Package/extract it through a dedicated bootstrap for a distributable mod, and
   set the override early enough in the actual launcher. An ordinary late client
   initializer may be too late. Verify the mapped path rather than assuming the
   override won. LWJGL 3.4.3 reads this setting when its SDL library class
   initializes: [SDL loader](https://github.com/LWJGL/lwjgl3/blob/3.4.3/modules/lwjgl/sdl/src/generated/java/org/lwjgl/sdl/SDL.java),
   [configuration property](https://github.com/LWJGL/lwjgl3/blob/3.4.3/modules/lwjgl/core/src/main/java/org/lwjgl/system/Configuration.java).

5. For a controlled launcher/profile, remove unused alternate native artifacts
   from the runtime distribution after auditing class initialization and optional
   features. Gradle changes to Cuprum alone cannot remove Minecraft launcher's
   inherited libraries for every installed profile. A jar present on the classpath
   is not a driver already running. Restrict or reject mods that call GL/Vulkan
   directly; engine interception does not convert arbitrary mod-native rendering.

6. Verify **execution**, as well as images. Capture title, terrain, transparency,
   entity, particle, GUI and post-processing frames with Xcode's Metal debugger.
   Correlate the game's draws/presentation with Cuprum's queue, and use Instruments
   Metal System Trace to inspect GPU submissions. During a native debugger run,
   put diagnostic breakpoints on context/driver creation (`SDL_GL_CreateContext`,
   `CGLCreateContext`, `NSOpenGLContext` constructors, `vkCreateInstance` and
   `vkCreateDevice`). Such breakpoints provide evidence for an exercised session,
   not a universal guarantee about all later mod behavior. A current-context query
   on one thread cannot establish the absence of contexts on every thread. Apple
   documents GPU capture and tracing in [Metal Shader Debugging and Profiling](https://developer.apple.com/videos/play/wwdc2018/608/).

## Scope and tradeoffs

Rebuilding SDL removes unused application backend capabilities; it does not
eliminate AppKit/QuartzCore's system dependencies. Replacing SDL with handwritten
Cocoa window/input code still uses those frameworks and would introduce another
large integration project. Loading Metal dynamically has already been tested here
and does not avoid the mappings. Another process for GPU work would also map the
Metal framework's dependencies on this OS.

Deleting, replacing or trying to unload Apple's OpenGL framework is not a supported
application solution. The tested framework dependency graph requires its images;
removing them attacks the host platform rather than selecting Cuprum's renderer.
There is no demonstrated supported app switch that removes those required load
commands from Apple's binaries.

This research added a reproducible native dependency audit and this report. It did
not rebuild SDL, change runtime policy, run a new Metal GPU trace, or prove the
absence of every system-internal GL call. Those boundaries matter when specifying
what the project can promise: direct Metal game rendering and no initialized
alternate application renderer are practical; a blanket absence of all OpenGL
system images is incompatible with the locally tested platform dependencies.
