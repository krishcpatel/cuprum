# Direct Metal architecture for Minecraft 26.3

```mermaid
flowchart LR
    MC[Minecraft / RenderPearl frontend] --> D[MetalDevice]
    SPV[Vanilla shader frontend: SPIR-V] --> MSL[SPIRV-Cross: MSL]
    MSL --> PSO[Cached Metal libraries and pipeline states]
    D --> JNI[MetalBackendNative / JNI]
    PSO --> JNI
    JNI --> GPU[Metal command queue and encoders]
    GPU --> S[CAMetalLayer drawable]
    SDL[SDL3 Cocoa window and Metal view] --> S
```

There is no Vulkan runtime in this path. SPIR-V is an intermediate shader format,
and SPIRV-Cross is a shader compiler, not a Vulkan driver.

## Window and backend selection

`BackendSelectionMixin` selects Cuprum by default on supported Macs. The native
library bootstrap bypasses Minecraft's OpenGL and Vulkan driver loaders. `CuprumBackend` creates an
`SDL_WINDOW_METAL` window without OpenGL or Vulkan flags, then returns a
`FrontendGpuDevice` backed by `MetalDevice`.

`CocoaMetalBridge` obtains the NSWindow through SDL's Cocoa window property and
queries contentView and backingScaleFactor using ABI-correct Objective-C calls.
`SDL_Metal_CreateView` creates and owns the layer-hosting NSView and CAMetalLayer,
preserving SDL's input and resize handling. The attachment owns the SDL Metal view
and destroys it on the macOS main thread. The borrowed SDL layer address is
imported once into a typed, retained JNI handle. Surface acquisition refreshes Retina
scale and sets drawableSize from the framebuffer configuration in pixels. SDL pixel
extents and Cocoa scale changes mark the surface suboptimal, so Minecraft can
reconfigure after resize or display migration.

Minecraft 26.3 has no GLFW window, `BufferRenderer.drawWithShader`, or old
Tessellator flush contract. Implementing its backend interfaces intercepts all
vanilla submissions, including terrain, GUI, textures, lightmaps and post passes.
The five mixins are narrowly scoped to backend selection, library bootstrap,
window diagnostics, RenderSystem diagnostics and the frame presentation boundary.

## Shader and pipeline translation

RenderPearl compiles each vanilla GLSL variant to SPIR-V and remaps attributes and
uniform bindings. `MetalPipeline` translates those modules with a separate
SPIRV-Cross context per compilation worker. Native and translated shaders use the
same negotiated MSL version: 2.4 on macOS 12+, 2.3 on macOS 11. It requests native texture
buffers, and a vertex Y flip matching RenderPearl's zero-to-one coordinate
convention. Counter-clockwise source geometry becomes clockwise after this flip;
the native render encoder uses clockwise front faces. Presentation performs the
final texture-orientation conversion.

The backend preserves reflected vertex offsets, formats, strides and instance
step rates in MTLVertexDescriptor. Metal buffer slots 0–14 hold uniform blocks,
slot 15 holds push constants, and slots 16–30 hold vertex buffers. Texture and
sampler slots match the frontend's uniform binding indices. Extra bindings fail
with a clear error rather than silently aliasing slots.

Translated source and entry points outlive the SPIR-V modules. Native shader
libraries are cached by source. Native compilation happens during `compilePipeline`,
including every supported depth format, on Minecraft's preparation workers.
`ShaderManager.reload` prepares both required and optional vanilla pipelines before
applying the resource reload. `variant()` performs a lookup and never compiles.
Presentation, fan expansion and common clear shaders are compiled during device
initialization. Clear shaders for additional formats are prepared when those
render targets are allocated, before a clear can be submitted.

A device-wide immutable PSO key includes shader sources and entry points, flattened
vertex attributes and layouts, color attachment formats and blend states, depth and
stencil attachment formats, and the contract's sample count of one. Identical PSOs
share a native pipeline even when their dynamic raster or depth state differs.
Native binding reflection, depth states and samplers are cached separately.
Culling, wireframe and depth bias are set when binding the pipeline. Current
RenderPearl exposes a cull boolean and depth/bias through `DepthStencilState`;
it has no front-cull selector, winding selector, depth-bounds range or stencil-test
mask interface. Packed depth/stencil attachments are retained across passes.
These absent API settings are not advertised as implemented hooks.

Metal cannot sample three-component RGB texture formats; these are rejected.
D24/S8 is used only on devices advertising that format, never reinterpreted as
D32/S8 with a different byte layout. Vanilla's normal RGBA and D32 resources are
supported. Optional device formats and Intel-specific behavior need hardware testing.

## Commands, memory and synchronization

`MetalEncoder` provides clears, render passes, uploads, copies, fences and queries.
`MetalPass` binds resources and submits direct, indexed, instanced and indirect
draws. Multiple indirect draws are encoded individually. Direct triangle fans are
expanded into shared index buffers; indexed fans use a GPU compute expansion.
Indirect fans resolve their GPU argument counts before allocating the expanded
stream; this uncommon compatibility path synchronizes and is slower than other draws.
Render pass splits preserve attachments, bindings, viewport, scissor and debug groups.

Buffers use shared storage. Three upload arenas hold reusable pages, fence every
submission and wait only when reusing an arena whose GPU work is unfinished.
Write-mapped Minecraft ring buffers rely on Minecraft's fences before reuse;
read maps synchronize. Java validates logical buffer ranges independently of native
allocation padding. Mapped views pin their storage until close; transient slices
expire before their arena is reused and submission rejects active transient maps.
Uniform allocations include trailing padding required by
MSL structure alignment, while Java exposes the requested logical byte length.
Misaligned texel-buffer slices are copied into aligned storage before binding.

Textures use private storage, with shared staging buffers for transfers. CPU pixel
uploads and readbacks use padded rows; readback callbacks strip that padding after
GPU completion. GPU mipmap generation uses a blit encoder. Callback polling happens before an arena can overwrite its staging
pages. Completed command buffers remain retained until all owning fences and
callbacks release them. Encoded Metal commands retain their resource objects, so
closing a Java resource does not free an allocation already referenced by a command.

All queue encoding and resource management occur on the creating render thread.
Shader translation and native PSO preparation run on compilation workers. JNI
objects use opaque monotonic tokens in a shared registry with type, owning device,
reference count and owning-thread checks. Java and native checks reject stale or
foreign resources, invalid offsets, descriptors and texture regions before encoding.
ARC ownership and per-call autorelease pools manage native objects. Device shutdown
waits for submitted work, completes or cancels callbacks, closes owned resources and
synchronizes with pipeline preparation. Callback cleanup runs even after failures.

## Presentation and timestamps

The surface acquires at most one drawable per frame and uses CAMetalLayer's three
available drawables. A fullscreen pass scales the game's color texture into a
framebuffer-only BGRA8 drawable. Presentation is scheduled on the same command
buffer before Minecraft submits it; the later `GpuSurface.present` hook closes any remaining Java/native render pass,
submits pending commands, polls readback completions and releases the surface's
acquired reference. An already submitted frame does not advance upload arenas twice. A three-permit semaphore bounds in-flight
command buffers and completion handlers release permits.

Zero-sized or iconified surfaces produce SurfaceException and let Minecraft retry;
drawable timeouts also let Minecraft retry. Configuration changes resize the layer
on the next acquisition. FIFO and immediate
presentation map to CAMetalLayer.displaySyncEnabled.

Minecraft constructs TimerQuery unconditionally. Query pools use actual Metal
counter sample buffers and return values only after the recorded command buffer
completes. GPUs with draw-boundary counters sample directly. Stage-boundary GPUs
split and restore an active render encoder and insert a sampled blit encoder.
A small marker operation ensures timestamp encoders are not optimized away.
Calibration samples the device GPU clock against Java's monotonic clock.

## Native files and verification

`cuprum_backend.m` and `MetalBackendNative` implement the game backend. The original
`cuprum_metal.m`, `MetalNative`, `MetalRenderer` and `CuprumPipeline` also retain a
small independent MSL rendering diagnostic used by `NativeSmoke`. Both native
implementations are linked into one universal macOS dylib; neither links Vulkan.

Command buffer completion handlers collect bounded GPU error and shader logs.
`getDebugMessages()` drains those diagnostics; frame metrics use completed command
buffers' GPU execution durations and completion intervals. See the dated
[validation report](validation.md) for commands, captures and the limits of the
hardware and visual checks. Hosted CI builds the universal binary and runs platform
tests; the separate physical-Mac workflow runs the full GPU test suite.
