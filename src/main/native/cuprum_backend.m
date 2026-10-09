// SPDX-License-Identifier: LGPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <jni.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#define JNI_METHOD(name) Java_com_krishcpatel_cuprum_bridge_MetalBackendNative_##name
#define OBJ(type, h) ((__bridge type)(void *)(intptr_t)(h))
static jlong keep(id obj) { return (jlong)(intptr_t)(__bridge_retained void *)obj; }
static void failBackend(JNIEnv *env, NSString *message) {
    if ((*env)->ExceptionCheck(env))
        return;
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (type)
        (*env)->ThrowNew(env, type, message.UTF8String);
}
@class CuprumBackendPipeline;
@interface CuprumBackendContext : NSObject
@property(strong) id<MTLDevice> device;
@property(strong) id<MTLCommandQueue> queue;
@property(strong) id<MTLCommandBuffer> command;
@property(strong) id<MTLRenderCommandEncoder> render;
@property(strong) id<MTLBlitCommandEncoder> blit;
@property(strong) id<CAMetalDrawable> drawable;
@property BOOL drawableScheduled;
@property(strong) id<MTLRenderPipelineState> screenPipeline;
@property(strong) id<MTLSamplerState> screenSampler;
@property(strong) dispatch_semaphore_t permits;
@property(strong) NSMutableDictionary *clearPipelines;
@property(strong) NSMutableDictionary *libraries;
@property(strong) NSMutableDictionary *samplers;
@property(strong) NSMutableDictionary *depthStates;
@property(strong) id<MTLBuffer> timestampMarker;
@property(strong) MTLRenderPassDescriptor *renderDescriptor;
@property(strong) CuprumBackendPipeline *boundPipeline;
@property(strong) NSMutableDictionary *boundBuffers;
@property(strong) NSMutableDictionary *boundTextures;
@property(strong) NSMutableDictionary *boundSamplers;
@property(strong) NSMutableArray *debugGroups;
@property MTLViewport viewport;
@property MTLScissorRect scissor;
@property(strong) id<MTLComputePipelineState> fanPipeline;
@end
@implementation CuprumBackendContext
@end
@interface CuprumBackendPipeline : NSObject
@property(strong) id<MTLRenderPipelineState> pso;
@property(strong) id<MTLDepthStencilState> depth;
// Reflection has the same lifetime as the cached PSO, never the temporary library function.
@property(strong) MTLRenderPipelineReflection *reflection;
@property BOOL cull;
@property BOOL wireframe;
@property float bias;
@property float slope;
@end
@implementation CuprumBackendPipeline
@end
static CuprumBackendContext *ctx(jlong h) { return OBJ(CuprumBackendContext *, h); }
static id<MTLCommandBuffer> command(CuprumBackendContext *d) {
    if (!d.command) {
        d.command = [d.queue commandBuffer];
        d.command.label = @"Cuprum frame commands";
    }
    return d.command;
}
static void endBlit(CuprumBackendContext *d) {
    if (d.blit) {
        [d.blit endEncoding];
        d.blit = nil;
    }
}
static id<MTLBlitCommandEncoder> blit(CuprumBackendContext *d) {
    if (!d.blit)
        d.blit = [command(d) blitCommandEncoder];
    return d.blit;
}
// Metal stage-only counters and fan expansion split an encoder while preserving pass state.
static void applyPipeline(CuprumBackendContext *d, CuprumBackendPipeline *r) {
    if (!r)
        return;
    [d.render setRenderPipelineState:r.pso];
    [d.render setDepthStencilState:r.depth];
    [d.render setCullMode:r.cull ? MTLCullModeBack : MTLCullModeNone];
    [d.render setTriangleFillMode:r.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    [d.render setDepthBias:r.bias slopeScale:r.slope clamp:0];
}
static void suspendRender(CuprumBackendContext *d) {
    for (NSUInteger i = 0; i < d.debugGroups.count; i++)
        [d.render popDebugGroup];
    [d.render endEncoding];
    d.render = nil;
}
// Pass replay state is needed only while a pass is suspended. Encoded Metal
// commands retain their own resources; dropping these references at endPass lets
// closed Java textures/buffers be freed as soon as their GPU work completes.
static void finishRender(CuprumBackendContext *d) {
    if (d.render)
        suspendRender(d);
    d.renderDescriptor = nil;
    d.boundPipeline = nil;
    d.boundBuffers = nil;
    d.boundTextures = nil;
    d.boundSamplers = nil;
    d.debugGroups = nil;
}
static void resumeRender(CuprumBackendContext *d) {
    MTLRenderPassDescriptor *p = [d.renderDescriptor copy];
    for (NSUInteger i = 0; i < 8; i++)
        if (p.colorAttachments[i].texture)
            p.colorAttachments[i].loadAction = MTLLoadActionLoad;
    if (p.depthAttachment.texture)
        p.depthAttachment.loadAction = MTLLoadActionLoad;
    if (p.stencilAttachment.texture)
        p.stencilAttachment.loadAction = MTLLoadActionLoad;
    d.render = [command(d) renderCommandEncoderWithDescriptor:p];
    [d.render setViewport:d.viewport];
    [d.render setScissorRect:d.scissor];
    [d.render setFrontFacingWinding:MTLWindingClockwise];
    applyPipeline(d, d.boundPipeline);
    for (NSNumber *slot in d.boundBuffers) {
        NSArray *b = d.boundBuffers[slot];
        NSUInteger i = slot.unsignedIntegerValue;
        [d.render setVertexBuffer:b[0] offset:[b[1] unsignedIntegerValue] atIndex:i];
        if (i < 16)
            [d.render setFragmentBuffer:b[0] offset:[b[1] unsignedIntegerValue] atIndex:i];
    }
    for (NSNumber *slot in d.boundTextures) {
        id<MTLTexture> tex = d.boundTextures[slot];
        NSUInteger i = slot.unsignedIntegerValue;
        [d.render setVertexTexture:tex atIndex:i];
        [d.render setFragmentTexture:tex atIndex:i];
    }
    for (NSNumber *slot in d.boundSamplers) {
        id<MTLSamplerState> sampler = d.boundSamplers[slot];
        NSUInteger i = slot.unsignedIntegerValue;
        [d.render setVertexSamplerState:sampler atIndex:i];
        [d.render setFragmentSamplerState:sampler atIndex:i];
    }
    for (NSString *label in d.debugGroups)
        [d.render pushDebugGroup:label];
}
static MTLPixelFormat pixelFormat(int f) {
    static const MTLPixelFormat table[] = {MTLPixelFormatR8Unorm,
                                           MTLPixelFormatR8Snorm,
                                           MTLPixelFormatRG8Unorm,
                                           MTLPixelFormatRG8Snorm,
                                           0,
                                           0,
                                           MTLPixelFormatRGBA8Unorm,
                                           MTLPixelFormatRGBA8Snorm,
                                           MTLPixelFormatR16Unorm,
                                           MTLPixelFormatR16Snorm,
                                           MTLPixelFormatRG16Unorm,
                                           MTLPixelFormatRG16Snorm,
                                           0,
                                           0,
                                           MTLPixelFormatRGBA16Unorm,
                                           MTLPixelFormatRGBA16Snorm,
                                           MTLPixelFormatR8Uint,
                                           MTLPixelFormatR8Sint,
                                           MTLPixelFormatRG8Uint,
                                           MTLPixelFormatRG8Sint,
                                           0,
                                           0,
                                           MTLPixelFormatRGBA8Uint,
                                           MTLPixelFormatRGBA8Sint,
                                           MTLPixelFormatR16Uint,
                                           MTLPixelFormatR16Sint,
                                           MTLPixelFormatRG16Uint,
                                           MTLPixelFormatRG16Sint,
                                           0,
                                           0,
                                           MTLPixelFormatRGBA16Uint,
                                           MTLPixelFormatRGBA16Sint,
                                           MTLPixelFormatR32Uint,
                                           MTLPixelFormatR32Sint,
                                           MTLPixelFormatRG32Uint,
                                           MTLPixelFormatRG32Sint,
                                           0,
                                           0,
                                           MTLPixelFormatRGBA32Uint,
                                           MTLPixelFormatRGBA32Sint,
                                           MTLPixelFormatR16Float,
                                           MTLPixelFormatRG16Float,
                                           0,
                                           MTLPixelFormatRGBA16Float,
                                           MTLPixelFormatR32Float,
                                           MTLPixelFormatRG32Float,
                                           0,
                                           MTLPixelFormatRGBA32Float,
                                           MTLPixelFormatRGB10A2Unorm,
                                           MTLPixelFormatRGB10A2Uint,
                                           MTLPixelFormatRG11B10Float,
                                           MTLPixelFormatDepth32Float,
                                           MTLPixelFormatDepth32Float_Stencil8,
                                           MTLPixelFormatDepth24Unorm_Stencil8,
                                           MTLPixelFormatDepth16Unorm,
                                           MTLPixelFormatStencil8};
    return f >= 0 && f < (int)(sizeof(table) / sizeof(table[0])) ? table[f] : 0;
}
static MTLVertexFormat vertexFormat(int f) {
    static const MTLVertexFormat table[] = {MTLVertexFormatUCharNormalized,
                                            MTLVertexFormatCharNormalized,
                                            MTLVertexFormatUChar2Normalized,
                                            MTLVertexFormatChar2Normalized,
                                            MTLVertexFormatUChar3Normalized,
                                            MTLVertexFormatChar3Normalized,
                                            MTLVertexFormatUChar4Normalized,
                                            MTLVertexFormatChar4Normalized,
                                            MTLVertexFormatUShortNormalized,
                                            MTLVertexFormatShortNormalized,
                                            MTLVertexFormatUShort2Normalized,
                                            MTLVertexFormatShort2Normalized,
                                            MTLVertexFormatUShort3Normalized,
                                            MTLVertexFormatShort3Normalized,
                                            MTLVertexFormatUShort4Normalized,
                                            MTLVertexFormatShort4Normalized,
                                            MTLVertexFormatUChar,
                                            MTLVertexFormatChar,
                                            MTLVertexFormatUChar2,
                                            MTLVertexFormatChar2,
                                            MTLVertexFormatUChar3,
                                            MTLVertexFormatChar3,
                                            MTLVertexFormatUChar4,
                                            MTLVertexFormatChar4,
                                            MTLVertexFormatUShort,
                                            MTLVertexFormatShort,
                                            MTLVertexFormatUShort2,
                                            MTLVertexFormatShort2,
                                            MTLVertexFormatUShort3,
                                            MTLVertexFormatShort3,
                                            MTLVertexFormatUShort4,
                                            MTLVertexFormatShort4,
                                            MTLVertexFormatUInt,
                                            MTLVertexFormatInt,
                                            MTLVertexFormatUInt2,
                                            MTLVertexFormatInt2,
                                            MTLVertexFormatUInt3,
                                            MTLVertexFormatInt3,
                                            MTLVertexFormatUInt4,
                                            MTLVertexFormatInt4,
                                            MTLVertexFormatHalf,
                                            MTLVertexFormatHalf2,
                                            MTLVertexFormatHalf3,
                                            MTLVertexFormatHalf4,
                                            MTLVertexFormatFloat,
                                            MTLVertexFormatFloat2,
                                            MTLVertexFormatFloat3,
                                            MTLVertexFormatFloat4,
                                            MTLVertexFormatUInt1010102Normalized};
    return f >= 0 && f < (int)(sizeof(table) / sizeof(table[0])) ? table[f] : MTLVertexFormatInvalid;
}
static MTLCompareFunction compare(int f) {
    static const MTLCompareFunction t[] = {MTLCompareFunctionAlways,    MTLCompareFunctionLess,
                                           MTLCompareFunctionLessEqual, MTLCompareFunctionEqual,
                                           MTLCompareFunctionNotEqual,  MTLCompareFunctionGreaterEqual,
                                           MTLCompareFunctionGreater,   MTLCompareFunctionNever};
    return t[f];
}
static MTLBlendFactor factor(int f) {
    static const MTLBlendFactor t[] = {MTLBlendFactorBlendAlpha,
                                       MTLBlendFactorBlendColor,
                                       MTLBlendFactorDestinationAlpha,
                                       MTLBlendFactorDestinationColor,
                                       MTLBlendFactorOne,
                                       MTLBlendFactorOneMinusBlendAlpha,
                                       MTLBlendFactorOneMinusBlendColor,
                                       MTLBlendFactorOneMinusDestinationAlpha,
                                       MTLBlendFactorOneMinusDestinationColor,
                                       MTLBlendFactorOneMinusSourceAlpha,
                                       MTLBlendFactorOneMinusSourceColor,
                                       MTLBlendFactorSourceAlpha,
                                       MTLBlendFactorSourceAlphaSaturated,
                                       MTLBlendFactorSourceColor,
                                       MTLBlendFactorZero};
    return t[f];
}
static NSString *string(JNIEnv *e, jstring s) {
    const char *p = (*e)->GetStringUTFChars(e, s, NULL);
    if (!p)
        return nil;
    NSString *r = [NSString stringWithUTF8String:p];
    (*e)->ReleaseStringUTFChars(e, s, p);
    return r;
}
JNIEXPORT jlong JNICALL JNI_METHOD(createDevice)(JNIEnv *e, jclass t) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = [CuprumBackendContext new];
        d.device = MTLCreateSystemDefaultDevice();
        d.queue = [d.device newCommandQueue];
        d.permits = dispatch_semaphore_create(3);
        if (!d.device || !d.queue) {
            failBackend(e, @"No usable Metal device/queue.");
            return 0;
        }
        return keep(d);
    }
}
JNIEXPORT jlongArray JNICALL JNI_METHOD(limits)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)t;
        CuprumBackendContext *d = ctx(h);
        jlong values[] = {(jlong)d.device.maxBufferLength, d.device.hasUnifiedMemory ? 16 : 256,
                          d.device.hasUnifiedMemory ? 1 : 0};
        jlongArray out = (*e)->NewLongArray(e, 3);
        if (out)
            (*e)->SetLongArrayRegion(e, out, 0, 3, values);
        return out;
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(buffer)(JNIEnv *e, jclass t, jlong h, jlong length) {
    (void)t;
    @autoreleasepool {
        id<MTLBuffer> b = [ctx(h).device newBufferWithLength:((NSUInteger)length + 255) & ~(NSUInteger)255
                                                     options:MTLResourceStorageModeShared];
        if (!b) {
            failBackend(e, @"Metal buffer allocation failed.");
            return 0;
        }
        return keep(b);
    }
}
JNIEXPORT jobject JNICALL JNI_METHOD(mapBuffer)(JNIEnv *e, jclass t, jlong h, jlong offset, jint length) {
    @autoreleasepool {
        (void)t;
        id<MTLBuffer> b = OBJ(id<MTLBuffer>, h);
        if (offset < 0 || length < 0 || (uint64_t)offset + length > b.length) {
            failBackend(e, @"Metal buffer map outside allocation.");
            return NULL;
        }
        return (*e)->NewDirectByteBuffer(e, (char *)b.contents + offset, length);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(texture)(JNIEnv *e, jclass t, jlong h, jint format, jint w, jint height,
                                            jint layers, jint mips, jint usage) {
    (void)t;
    @autoreleasepool {
        MTLPixelFormat pf = pixelFormat(format);
        if (pf == MTLPixelFormatDepth24Unorm_Stencil8 &&
            !ctx(h).device.isDepth24Stencil8PixelFormatSupported) {
            failBackend(e, @"This Metal GPU does not support D24_UNORM_S8_UINT; use D32_FLOAT_S8_UINT.");
            return 0;
        }
        if (!pf) {
            failBackend(e, @"Unsupported Metal texture format.");
            return 0;
        }
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                     width:w
                                                                                    height:height
                                                                                 mipmapped:mips > 1];
        d.mipmapLevelCount = mips;
        d.arrayLength = layers;
        d.textureType = layers > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        if (usage & 16) {
            d.textureType = layers > 6 ? MTLTextureTypeCubeArray : MTLTextureTypeCube;
            d.arrayLength = layers / 6;
        }
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsagePixelFormatView;
        if (usage & 4)
            d.usage |= MTLTextureUsageShaderRead;
        if (usage & 8)
            d.usage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> tex = [ctx(h).device newTextureWithDescriptor:d];
        if (!tex) {
            failBackend(e, @"Metal texture allocation failed.");
            return 0;
        }
        return keep(tex);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(textureView)(JNIEnv *e, jclass t, jlong h, jint base, jint count) {
    (void)t;
    @autoreleasepool {
        id<MTLTexture> tex = OBJ(id<MTLTexture>, h);
        NSUInteger slices =
            tex.arrayLength *
            (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1);
        id<MTLTexture> view = [tex newTextureViewWithPixelFormat:tex.pixelFormat
                                                     textureType:tex.textureType
                                                          levels:NSMakeRange(base, count)
                                                          slices:NSMakeRange(0, slices)];
        if (!view) {
            failBackend(e, @"Cannot create Metal texture view.");
            return 0;
        }
        return keep(view);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(texelView)(JNIEnv *e, jclass t, jlong device, jlong h, jlong offset,
                                              jlong length, jint format) {
    (void)t;
    @autoreleasepool {
        id<MTLBuffer> b = OBJ(id<MTLBuffer>, h);
        MTLPixelFormat pf = pixelFormat(format);
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = MTLTextureTypeTextureBuffer;
        d.pixelFormat = pf;
        int bytes;
        if (format < 32) {
            int group = format % 16;
            bytes = (group / 2 + 1) * (group < 8 ? 1 : 2);
            if (group >= 8)
                bytes = (group / 2 - 3) * 2;
        } else if (format < 40)
            bytes = ((format - 32) / 2 + 1) * 4;
        else if (format < 44)
            bytes = (format - 39) * 2;
        else if (format < 48)
            bytes = (format - 43) * 4;
        else
            bytes = 4;
        if (!pf || length <= 0 || length % bytes || offset < 0 ||
            (uint64_t)offset + (uint64_t)length > b.length) {
            failBackend(e, @"Invalid Metal texel buffer format or range.");
            return 0;
        }
        CuprumBackendContext *owner = ctx(device);
        NSUInteger alignment = [owner.device minimumTextureBufferAlignmentForPixelFormat:pf];
        if ((NSUInteger)offset % alignment) {
            BOOL restart = owner.render != nil;
            if (restart)
                suspendRender(owner);
            id<MTLBuffer> aligned =
                [owner.device newBufferWithLength:((NSUInteger)length + 255) & ~(NSUInteger)255
                                          options:MTLResourceStorageModeShared];
            if (!aligned) {
                if (restart)
                    resumeRender(owner);
                failBackend(e, @"Cannot allocate aligned texel buffer.");
                return 0;
            }
            [blit(owner) copyFromBuffer:b
                           sourceOffset:offset
                               toBuffer:aligned
                      destinationOffset:0
                                   size:length];
            endBlit(owner);
            if (restart)
                resumeRender(owner);
            b = aligned;
            offset = 0;
        }
        d.width = length / bytes;
        d.height = 1;
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> v = [b newTextureWithDescriptor:d offset:offset bytesPerRow:length];
        if (!v) {
            failBackend(e, @"Cannot create Metal texel buffer view (alignment/format).");
            return 0;
        }
        return keep(v);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(sampler)(JNIEnv *e, jclass t, jlong h, jint u, jint v, jint min, jint mag,
                                            jint aniso, jdouble lod) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        NSString *key = [NSString stringWithFormat:@"%d/%d/%d/%d/%d/%.17g", u, v, min, mag, aniso, lod];
        if (!d.samplers)
            d.samplers = [NSMutableDictionary new];
        id<MTLSamplerState> cached = d.samplers[key];
        if (cached)
            return keep(cached); // Each Java sampler retains an independent ownership reference.
        MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
        s.sAddressMode = u ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        s.tAddressMode = v ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        s.rAddressMode = MTLSamplerAddressModeClampToEdge;
        s.minFilter = min ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        s.magFilter = mag ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        s.mipFilter = min ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        s.maxAnisotropy = aniso;
        s.lodMaxClamp = lod;
        id<MTLSamplerState> state = [ctx(h).device newSamplerStateWithDescriptor:s];
        if (!state) {
            failBackend(e, @"Metal sampler allocation failed.");
            return 0;
        }
        d.samplers[key] = state;
        return keep(state);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(release)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)e;
        (void)t;
        if (h)
            CFRelease((CFTypeRef)(void *)(intptr_t)h);
    }
}
static id<MTLLibrary> shaderLibrary(CuprumBackendContext *d, NSString *source, NSError **error) {
    if (!d.libraries)
        d.libraries = [NSMutableDictionary new];
    id<MTLLibrary> cached = d.libraries[source];
    if (cached)
        return cached;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion2_4;
    id<MTLLibrary> library = [d.device newLibraryWithSource:source options:options error:error];
    if (library)
        d.libraries[source] = library;
    return library;
}
JNIEXPORT jlong JNICALL JNI_METHOD(pipeline)(JNIEnv *e, jclass t, jlong h, jstring vs, jstring ve, jstring fs,
                                             jstring fe, jintArray attrs, jintArray layouts, jintArray colors,
                                             jint depthFormat, jint depthCompare, jboolean write,
                                             jboolean cull, jboolean wire, jfloat bias, jfloat slope) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        NSError *error = nil;
        id<MTLLibrary> v = shaderLibrary(d, string(e, vs), &error);
        if (!v) {
            failBackend(e,
                        [@"Vertex MSL: " stringByAppendingString:error.localizedDescription ?: @"unknown"]);
            return 0;
        }
        id<MTLLibrary> f = shaderLibrary(d, string(e, fs), &error);
        if (!f) {
            failBackend(e,
                        [@"Fragment MSL: " stringByAppendingString:error.localizedDescription ?: @"unknown"]);
            return 0;
        }
        MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
        p.vertexFunction = [v newFunctionWithName:string(e, ve)];
        p.fragmentFunction = [f newFunctionWithName:string(e, fe)];
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        jint *a = (*e)->GetIntArrayElements(e, attrs, NULL);
        int ac = (*e)->GetArrayLength(e, attrs);
        for (int i = 0; i < ac; i += 4) {
            vd.attributes[a[i + 1]].bufferIndex = a[i] + 16;
            vd.attributes[a[i + 1]].offset = a[i + 2];
            vd.attributes[a[i + 1]].format = vertexFormat(a[i + 3]);
        }
        (*e)->ReleaseIntArrayElements(e, attrs, a, JNI_ABORT);
        jint *l = (*e)->GetIntArrayElements(e, layouts, NULL);
        int lc = (*e)->GetArrayLength(e, layouts);
        for (int i = 0; i < lc; i += 3) {
            vd.layouts[l[i] + 16].stride = l[i + 1];
            vd.layouts[l[i] + 16].stepFunction =
                l[i + 2] > 0 ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex;
            vd.layouts[l[i] + 16].stepRate = l[i + 2] > 0 ? l[i + 2] : 1;
        }
        (*e)->ReleaseIntArrayElements(e, layouts, l, JNI_ABORT);
        p.vertexDescriptor = vd;
        jint *c = (*e)->GetIntArrayElements(e, colors, NULL);
        int cc = (*e)->GetArrayLength(e, colors);
        for (int i = 0; i < cc; i += 9) {
            if (c[i] < 0)
                continue;
            MTLRenderPipelineColorAttachmentDescriptor *ca = p.colorAttachments[i / 9];
            ca.pixelFormat = pixelFormat(c[i]);
            ca.writeMask =
                ((c[i + 1] & 1) ? MTLColorWriteMaskRed : 0) | ((c[i + 1] & 2) ? MTLColorWriteMaskGreen : 0) |
                ((c[i + 1] & 4) ? MTLColorWriteMaskBlue : 0) | ((c[i + 1] & 8) ? MTLColorWriteMaskAlpha : 0);
            ca.blendingEnabled = c[i + 2];
            if (c[i + 2]) {
                ca.sourceRGBBlendFactor = factor(c[i + 3]);
                ca.destinationRGBBlendFactor = factor(c[i + 4]);
                ca.rgbBlendOperation = c[i + 5];
                ca.sourceAlphaBlendFactor = factor(c[i + 6]);
                ca.destinationAlphaBlendFactor = factor(c[i + 7]);
                ca.alphaBlendOperation = c[i + 8];
            }
        }
        (*e)->ReleaseIntArrayElements(e, colors, c, JNI_ABORT);
        if (depthFormat >= 0) {
            p.depthAttachmentPixelFormat = pixelFormat(depthFormat);
            if (depthFormat == 52 || depthFormat == 53)
                p.stencilAttachmentPixelFormat = pixelFormat(depthFormat);
        }
        CuprumBackendPipeline *r = [CuprumBackendPipeline new];
        MTLRenderPipelineReflection *reflection = nil;
        r.pso = [d.device newRenderPipelineStateWithDescriptor:p
                                                    options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo
                                                 reflection:&reflection error:&error];
        r.reflection = reflection;
        if (!r.pso) {
            failBackend(e, [@"Metal PSO: " stringByAppendingString:error.localizedDescription ?: @"unknown"]);
            return 0;
        }
        // Depth testing disabled maps to ALWAYS with writes disabled, as supplied by
        // RenderPearl. Cache immutable depth state separately from shader/format PSOs.
        if (!d.depthStates)
            d.depthStates = [NSMutableDictionary new];
        NSNumber *depthKey = @((depthCompare << 1) | (write ? 1 : 0));
        r.depth = d.depthStates[depthKey];
        if (!r.depth) {
            MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
            ds.depthCompareFunction = compare(depthCompare);
            ds.depthWriteEnabled = write;
            r.depth = [d.device newDepthStencilStateWithDescriptor:ds];
            d.depthStates[depthKey] = r.depth;
        }
        r.cull = cull;
        r.wireframe = wire;
        r.bias = bias;
        r.slope = slope;
        return keep(r);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(beginPass)(JNIEnv *e, jclass t, jlong h, jlongArray colors,
                                             jdoubleArray clears, jlong depth, jdouble depthClear, jint x,
                                             jint y, jint width, jint height) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        endBlit(d);
        if (d.render) {
            failBackend(e, @"Nested Metal render pass.");
            return;
        }
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        jlong *c = (*e)->GetLongArrayElements(e, colors, NULL);
        jdouble *v = (*e)->GetDoubleArrayElements(e, clears, NULL);
        int count = (*e)->GetArrayLength(e, colors);
        for (int i = 0; i < count; i++) {
            if (!c[i])
                continue;
            p.colorAttachments[i].texture = OBJ(id<MTLTexture>, c[i]);
            p.colorAttachments[i].loadAction = v[i * 5] ? MTLLoadActionClear : MTLLoadActionLoad;
            p.colorAttachments[i].storeAction = MTLStoreActionStore;
            p.colorAttachments[i].clearColor =
                MTLClearColorMake(v[i * 5 + 1], v[i * 5 + 2], v[i * 5 + 3], v[i * 5 + 4]);
        }
        (*e)->ReleaseLongArrayElements(e, colors, c, JNI_ABORT);
        (*e)->ReleaseDoubleArrayElements(e, clears, v, JNI_ABORT);
        if (depth) {
            id<MTLTexture> tex = OBJ(id<MTLTexture>, depth);
            p.depthAttachment.texture = tex;
            p.depthAttachment.loadAction = depthClear >= 0 ? MTLLoadActionClear : MTLLoadActionLoad;
            p.depthAttachment.storeAction = MTLStoreActionStore;
            p.depthAttachment.clearDepth = depthClear >= 0 ? depthClear : 1;
            if (tex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                tex.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8) {
                p.stencilAttachment.texture = tex;
                p.stencilAttachment.loadAction = MTLLoadActionLoad;
                p.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
        d.render = [command(d) renderCommandEncoderWithDescriptor:p];
        if (!d.render) {
            failBackend(e, @"Cannot begin Metal render pass.");
            return;
        }
        id<MTLTexture> extent = p.depthAttachment.texture;
        for (NSUInteger i = 0; !extent && i < 8; i++)
            extent = p.colorAttachments[i].texture;
        d.renderDescriptor = p;
        d.boundPipeline = nil;
        d.boundBuffers = [NSMutableDictionary new];
        d.boundTextures = [NSMutableDictionary new];
        d.boundSamplers = [NSMutableDictionary new];
        d.debugGroups = [NSMutableArray new];
        d.viewport = (MTLViewport){0, 0, extent.width, extent.height, 0, 1};
        d.scissor = (MTLScissorRect){x, y, width, height};
        [d.render setViewport:d.viewport];
        [d.render setScissorRect:d.scissor];
        [d.render setFrontFacingWinding:MTLWindingClockwise];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(endPass)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)e;
        (void)t;
        CuprumBackendContext *d = ctx(h);
        finishRender(d);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindPipeline)(JNIEnv *e, jclass t, jlong h, jlong p) {
    @autoreleasepool {
        (void)e;
        (void)t;
        CuprumBackendContext *d = ctx(h);
        d.boundPipeline = OBJ(CuprumBackendPipeline *, p);
        applyPipeline(d, d.boundPipeline);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindBuffer)(JNIEnv *e, jclass t, jlong h, jint slot, jlong b,
                                              jlong offset) {
    @autoreleasepool {
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> x = ctx(h).render;
        id<MTLBuffer> buffer = OBJ(id<MTLBuffer>, b);
        if (buffer)
            ctx(h).boundBuffers[@(slot)] = @[ buffer, @(offset) ];
        else
            [ctx(h).boundBuffers removeObjectForKey:@(slot)];
        [x setVertexBuffer:buffer offset:offset atIndex:slot];
        if (slot < 16)
            [x setFragmentBuffer:buffer offset:offset atIndex:slot];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindTexture)(JNIEnv *e, jclass t, jlong h, jint slot, jlong tex, jlong s) {
    @autoreleasepool {
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> x = ctx(h).render;
        CuprumBackendContext *d = ctx(h);
        if (tex)
            d.boundTextures[@(slot)] = OBJ(id<MTLTexture>, tex);
        else
            [d.boundTextures removeObjectForKey:@(slot)];
        if (s)
            d.boundSamplers[@(slot)] = OBJ(id<MTLSamplerState>, s);
        [x setVertexTexture:OBJ(id<MTLTexture>, tex) atIndex:slot];
        [x setFragmentTexture:OBJ(id<MTLTexture>, tex) atIndex:slot];
        if (s) {
            [x setVertexSamplerState:OBJ(id<MTLSamplerState>, s) atIndex:slot];
            [x setFragmentSamplerState:OBJ(id<MTLSamplerState>, s) atIndex:slot];
        }
    }
}
JNIEXPORT void JNICALL JNI_METHOD(scissor)(JNIEnv *e, jclass t, jlong h, jint x, jint y, jint w,
                                           jint height) {
    @autoreleasepool {
        (void)e;
        (void)t;
        ctx(h).scissor = (MTLScissorRect){x, y, w, height};
        [ctx(h).render setScissorRect:ctx(h).scissor];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(draw)(JNIEnv *e, jclass t, jlong h, jint primitive, jint count,
                                        jint instances, jint first, jint baseInstance, jlong indices,
                                        jlong offset, jint indexType, jint baseVertex) {
    @autoreleasepool {
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> r = ctx(h).render;
        if (indices) {
            [r drawIndexedPrimitives:primitive
                          indexCount:count
                           indexType:indexType
                         indexBuffer:OBJ(id<MTLBuffer>, indices)
                   indexBufferOffset:offset
                       instanceCount:instances
                          baseVertex:baseVertex
                        baseInstance:baseInstance];
        } else {
            [r drawPrimitives:primitive
                  vertexStart:first
                  vertexCount:count
                instanceCount:instances
                 baseInstance:baseInstance];
        }
    }
}
JNIEXPORT void JNICALL JNI_METHOD(drawIndirect)(JNIEnv *e, jclass t, jlong h, jint primitive, jlong commands,
                                                jlong offset, jlong indices, jint indexType) {
    @autoreleasepool {
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> r = ctx(h).render;
        if (indices)
            [r drawIndexedPrimitives:primitive
                           indexType:indexType
                         indexBuffer:OBJ(id<MTLBuffer>, indices)
                   indexBufferOffset:0
                      indirectBuffer:OBJ(id<MTLBuffer>, commands)
                indirectBufferOffset:offset];
        else
            [r drawPrimitives:primitive
                      indirectBuffer:OBJ(id<MTLBuffer>, commands)
                indirectBufferOffset:offset];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(copyBuffer)(JNIEnv *e, jclass t, jlong h, jlong src, jlong so, jlong dst,
                                              jlong to, jlong size) {
    @autoreleasepool {
        (void)e;
        (void)t;
        [blit(ctx(h)) copyFromBuffer:OBJ(id<MTLBuffer>, src)
                        sourceOffset:so
                            toBuffer:OBJ(id<MTLBuffer>, dst)
                   destinationOffset:to
                                size:size];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bufferTexture)(JNIEnv *e, jclass t, jlong h, jlong b, jlong offset,
                                                 jint rowBytes, jint imageBytes, jlong tex, jint mip,
                                                 jint layer, jint x, jint y, jint w, jint height,
                                                 jboolean upload) {
    @autoreleasepool {
        (void)e;
        (void)t;
        id<MTLBlitCommandEncoder> r = blit(ctx(h));
        if (upload)
            [r copyFromBuffer:OBJ(id<MTLBuffer>, b)
                       sourceOffset:offset
                  sourceBytesPerRow:rowBytes
                sourceBytesPerImage:imageBytes
                         sourceSize:MTLSizeMake(w, height, 1)
                          toTexture:OBJ(id<MTLTexture>, tex)
                   destinationSlice:layer
                   destinationLevel:mip
                  destinationOrigin:MTLOriginMake(x, y, 0)];
        else
            [r copyFromTexture:OBJ(id<MTLTexture>, tex)
                             sourceSlice:layer
                             sourceLevel:mip
                            sourceOrigin:MTLOriginMake(x, y, 0)
                              sourceSize:MTLSizeMake(w, height, 1)
                                toBuffer:OBJ(id<MTLBuffer>, b)
                       destinationOffset:offset
                  destinationBytesPerRow:rowBytes
                destinationBytesPerImage:imageBytes];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(copyTexture)(JNIEnv *e, jclass t, jlong h, jlong src, jint sm, jint sl,
                                               jint sx, jint sy, jlong dst, jint dm, jint dl, jint dx,
                                               jint dy, jint w, jint height) {
    @autoreleasepool {
        (void)e;
        (void)t;
        [blit(ctx(h)) copyFromTexture:OBJ(id<MTLTexture>, src)
                          sourceSlice:sl
                          sourceLevel:sm
                         sourceOrigin:MTLOriginMake(sx, sy, 0)
                           sourceSize:MTLSizeMake(w, height, 1)
                            toTexture:OBJ(id<MTLTexture>, dst)
                     destinationSlice:dl
                     destinationLevel:dm
                    destinationOrigin:MTLOriginMake(dx, dy, 0)];
    }
}
static id<MTLCommandBuffer> submitBackend(CuprumBackendContext *d, BOOL wait) {
    endBlit(d);
    if (d.render)
        finishRender(d);
    if (!d.command)
        return nil;
    id<MTLCommandBuffer> c = d.command;
    d.command = nil;
    dispatch_semaphore_wait(d.permits, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_t permits = d.permits;
    [c addCompletedHandler:^(id<MTLCommandBuffer> done) {
      if (done.status == MTLCommandBufferStatusError)
          NSLog(@"Cuprum GPU error: %@", done.error);
      dispatch_semaphore_signal(permits);
    }];
    [c commit];
    if (wait)
        [c waitUntilCompleted];
    return c;
}
JNIEXPORT jlong JNICALL JNI_METHOD(submit)(JNIEnv *e, jclass t, jlong h, jboolean wait) {
    (void)t;
    @autoreleasepool {
        id<MTLCommandBuffer> c = submitBackend(ctx(h), wait);
        if (wait && c.status == MTLCommandBufferStatusError)
            failBackend(e, c.error.localizedDescription);
        return c ? keep(c) : 0;
    }
}
JNIEXPORT jboolean JNICALL JNI_METHOD(await)(JNIEnv *e, jclass t, jlong h, jlong timeout) {
    (void)t;
    @autoreleasepool {
        id<MTLCommandBuffer> c = OBJ(id<MTLCommandBuffer>, h);
        if (!c)
            return JNI_TRUE;
        struct timespec start;
        clock_gettime(CLOCK_MONOTONIC, &start);
        if (timeout < 0)
            [c waitUntilCompleted];
        else
            while (c.status < MTLCommandBufferStatusCompleted) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                int64_t elapsed = (now.tv_sec - start.tv_sec) * 1000000000LL + now.tv_nsec - start.tv_nsec;
                if (elapsed >= timeout)
                    return JNI_FALSE;
                usleep(100);
            }
        if (c.status == MTLCommandBufferStatusError) {
            failBackend(e, c.error.localizedDescription);
            return JNI_FALSE;
        }
        return JNI_TRUE;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(waitIdle)(JNIEnv *e, jclass t, jlong h) {
    (void)e;
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        submitBackend(d, YES);
        id<MTLCommandBuffer> c = [d.queue commandBuffer];
        [c commit];
        [c waitUntilCompleted];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(closeDevice)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        JNI_METHOD(waitIdle)(e, t, h);
        CFRelease((CFTypeRef)(void *)(intptr_t)h);
    }
}
static NSString *screenMSL(void) {
    return @"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 position [[position]];float2 "
           @"uv;};vertex O cv(uint i [[vertex_id]]){float2 p=float2((i<<1)&2,i&2);O "
           @"o;o.position=float4(p*2-1,0,1);o.uv=p;return o;}fragment float4 cf(O o "
           @"[[stage_in]],texture2d<float>t [[texture(0)]],sampler s [[sampler(0)]]){return "
           @"t.sample(s,o.uv);}";
}
JNIEXPORT jlong JNICALL JNI_METHOD(acquire)(JNIEnv *e, jclass t, jlong h, jlong layer, jint w, jint height,
                                            jboolean vsync) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        if (d.drawable) {
            failBackend(e, @"Metal drawable already acquired.");
            return 0;
        }
        CAMetalLayer *l = OBJ(CAMetalLayer *, layer);
        l.device = d.device;
        l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.framebufferOnly = YES;
        l.drawableSize = CGSizeMake(w, height);
        l.maximumDrawableCount = 3;
        l.displaySyncEnabled = vsync;
        l.allowsNextDrawableTimeout = YES;
        d.drawableScheduled = NO;
        d.drawable = [l nextDrawable];
        return d.drawable ? 1 : 0;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(blitDrawable)(JNIEnv *e, jclass t, jlong h, jlong source) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        endBlit(d);
        if (!d.drawable) {
            failBackend(e, @"No drawable acquired.");
            return;
        }
        if (!d.screenPipeline) {
            NSError *error = nil;
            id<MTLLibrary> lib = [d.device newLibraryWithSource:screenMSL() options:nil error:&error];
            MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
            p.vertexFunction = [lib newFunctionWithName:@"cv"];
            p.fragmentFunction = [lib newFunctionWithName:@"cf"];
            p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            d.screenPipeline = [d.device newRenderPipelineStateWithDescriptor:p error:&error];
            MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
            s.minFilter = MTLSamplerMinMagFilterNearest;
            s.magFilter = MTLSamplerMinMagFilterNearest;
            d.screenSampler = [d.device newSamplerStateWithDescriptor:s];
            if (!d.screenPipeline) {
                failBackend(e, error.localizedDescription);
                return;
            }
        }
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = d.drawable.texture;
        p.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> r = [command(d) renderCommandEncoderWithDescriptor:p];
        [r setRenderPipelineState:d.screenPipeline];
        [r setFragmentTexture:OBJ(id<MTLTexture>, source) atIndex:0];
        [r setFragmentSamplerState:d.screenSampler atIndex:0];
        [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [r endEncoding];
        [command(d) presentDrawable:d.drawable];
        d.drawableScheduled = YES;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(present)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        if (!d.drawable) {
            failBackend(e, @"No Metal drawable to present.");
            return;
        }
        if (!d.drawableScheduled) {
            [command(d) presentDrawable:d.drawable];
            submitBackend(d, NO);
        }
        d.drawable = nil;
        d.drawableScheduled = NO;
    }
}

@interface CuprumBackendQueries : NSObject
@property(strong) id<MTLCounterSampleBuffer> samples;
@property(strong) NSMutableArray *commands;
@end
@implementation CuprumBackendQueries
@end
JNIEXPORT jlong JNICALL JNI_METHOD(queryPool)(JNIEnv *e, jclass t, jlong h, jint size) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        MTLCounterSampleBufferDescriptor *desc = [MTLCounterSampleBufferDescriptor new];
        for (id<MTLCounterSet> set in d.device.counterSets)
            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp])
                desc.counterSet = set;
        if (!desc.counterSet) {
            failBackend(e, @"Metal device has no GPU timestamp counter set.");
            return 0;
        }
        desc.sampleCount = size;
        desc.storageMode = MTLStorageModeShared;
        NSError *error = nil;
        CuprumBackendQueries *q = [CuprumBackendQueries new];
        q.samples = [d.device newCounterSampleBufferWithDescriptor:desc error:&error];
        if (!q.samples) {
            failBackend(e, error.localizedDescription);
            return 0;
        }
        q.commands = [NSMutableArray arrayWithCapacity:size];
        for (int i = 0; i < size; i++)
            [q.commands addObject:NSNull.null];
        return keep(q);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(timestamp)(JNIEnv *e, jclass t, jlong h, jlong pool, jint index) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        CuprumBackendQueries *q = OBJ(CuprumBackendQueries *, pool);
        BOOL restart = d.render && ![d.device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary];
        if (restart)
            suspendRender(d);
        if (d.render) {
            [d.render sampleCountersInBuffer:q.samples atSampleIndex:index withBarrier:YES];
        } else {
            endBlit(d);
            if ([d.device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
                MTLBlitPassDescriptor *p = [MTLBlitPassDescriptor blitPassDescriptor];
                p.sampleBufferAttachments[0].sampleBuffer = q.samples;
                p.sampleBufferAttachments[0].startOfEncoderSampleIndex = index;
                p.sampleBufferAttachments[0].endOfEncoderSampleIndex = MTLCounterDontSample;
                id<MTLBlitCommandEncoder> b = [command(d) blitCommandEncoderWithDescriptor:p];
                if (!d.timestampMarker)
                    d.timestampMarker = [d.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
                [b fillBuffer:d.timestampMarker range:NSMakeRange(0, 4) value:0];
                [b endEncoding];
            } else if ([d.device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary]) {
                [blit(d) sampleCountersInBuffer:q.samples atSampleIndex:index withBarrier:YES];
                endBlit(d);
            } else {
                failBackend(e, @"Metal GPU timestamp sampling is unavailable.");
                return;
            }
        }
        q.commands[index] = command(d);
        if (restart)
            resumeRender(d);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(queryValue)(JNIEnv *e, jclass t, jlong pool, jint index) {
    (void)e;
    (void)t;
    @autoreleasepool {
        CuprumBackendQueries *q = OBJ(CuprumBackendQueries *, pool);
        id value = q.commands[index];
        if (value == NSNull.null)
            return -1;
        id<MTLCommandBuffer> c = value;
        if (c.status == MTLCommandBufferStatusError) {
            failBackend(e, c.error.localizedDescription);
            return -1;
        }
        if (c.status != MTLCommandBufferStatusCompleted)
            return -1;
        NSData *data = [q.samples resolveCounterRange:NSMakeRange(index, 1)];
        if (data.length < sizeof(MTLCounterResultTimestamp))
            return -1;
        uint64_t valueNs = ((const MTLCounterResultTimestamp *)data.bytes)->timestamp;
        return valueNs == MTLCounterErrorValue ? -1 : (jlong)valueNs;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(debugGroup)(JNIEnv *e, jclass t, jlong h, jstring label, jboolean push) {
    @autoreleasepool {
        (void)t;
        CuprumBackendContext *d = ctx(h);
        if (push) {
            NSString *name = string(e, label);
            [d.debugGroups addObject:name];
            [d.render pushDebugGroup:name];
        } else {
            [d.debugGroups removeLastObject];
            [d.render popDebugGroup];
        }
    }
}

JNIEXPORT jlong JNICALL JNI_METHOD(retain)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)e;
        (void)t;
        if (h)
            CFRetain((CFTypeRef)(void *)(intptr_t)h);
        return h;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(clearRegion)(JNIEnv *e, jclass t, jlong h, jlong color, jlong depth,
                                               jfloat red, jfloat green, jfloat blue, jfloat alpha,
                                               jfloat depthValue, jint x, jint y, jint width, jint height) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        endBlit(d);
        id<MTLTexture> c = OBJ(id<MTLTexture>, color), z = OBJ(id<MTLTexture>, depth), extent = c ?: z;
        NSString *key = [NSString
            stringWithFormat:@"%lu/%lu", (unsigned long)c.pixelFormat, (unsigned long)z.pixelFormat];
        if (!d.clearPipelines)
            d.clearPipelines = [NSMutableDictionary new];
        CuprumBackendPipeline *pipeline = d.clearPipelines[key];
        if (!pipeline) {
            NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 cv(uint i "
                                @"[[vertex_id]]){float2 p=float2((i<<1)&2,i&2);return "
                                @"float4(p*2-1,0,1);}struct V{float4 color;float depth;};struct O{"
                stringByAppendingFormat:
                    @"%@%@}; fragment O cf(constant V &v [[buffer(0)]]){O o;%@%@return o;}",
                    c ? @"float4 color [[color(0)]];" : @"", z ? @"float depth [[depth(any)]];" : @"",
                    c ? @"o.color=v.color;" : @"", z ? @"o.depth=v.depth;" : @""];
            NSError *error = nil;
            id<MTLLibrary> lib = [d.device newLibraryWithSource:source options:nil error:&error];
            if (!lib) {
                failBackend(e, error.localizedDescription);
                return;
            }
            MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
            p.vertexFunction = [lib newFunctionWithName:@"cv"];
            p.fragmentFunction = [lib newFunctionWithName:@"cf"];
            p.colorAttachments[0].pixelFormat = c.pixelFormat;
            p.depthAttachmentPixelFormat = z.pixelFormat;
            if (z.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                z.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8)
                p.stencilAttachmentPixelFormat = z.pixelFormat;
            pipeline = [CuprumBackendPipeline new];
            pipeline.pso = [d.device newRenderPipelineStateWithDescriptor:p error:&error];
            if (!pipeline.pso) {
                failBackend(e, error.localizedDescription);
                return;
            }
            MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
            ds.depthCompareFunction = MTLCompareFunctionAlways;
            ds.depthWriteEnabled = z != nil;
            pipeline.depth = [d.device newDepthStencilStateWithDescriptor:ds];
            d.clearPipelines[key] = pipeline;
        }
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        if (c) {
            p.colorAttachments[0].texture = c;
            p.colorAttachments[0].loadAction = MTLLoadActionLoad;
            p.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        if (z) {
            p.depthAttachment.texture = z;
            p.depthAttachment.loadAction = MTLLoadActionLoad;
            p.depthAttachment.storeAction = MTLStoreActionStore;
            if (z.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                z.pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8) {
                p.stencilAttachment.texture = z;
                p.stencilAttachment.loadAction = MTLLoadActionLoad;
                p.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
        id<MTLRenderCommandEncoder> r = [command(d) renderCommandEncoderWithDescriptor:p];
        [r setViewport:(MTLViewport){0, 0, extent.width, extent.height, 0, 1}];
        [r setScissorRect:(MTLScissorRect){x, y, width, height}];
        [r setRenderPipelineState:pipeline.pso];
        [r setDepthStencilState:pipeline.depth];
        float values[8] = {red, green, blue, alpha, depthValue, 0, 0, 0};
        [r setFragmentBytes:values length:sizeof(values) atIndex:0];
        [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [r endEncoding];
    }
}

JNIEXPORT void JNICALL JNI_METHOD(drawIndexedFan)(JNIEnv *e, jclass t, jlong h, jint count, jint instances,
                                                  jlong indices, jlong offset, jint type, jint baseVertex,
                                                  jint baseInstance) {
    (void)t;
    @autoreleasepool {
        if (count < 3)
            return;
        CuprumBackendContext *d = ctx(h);
        if (!d.fanPipeline) {
            NSError *error = nil;
            NSString *source =
                @"#include <metal_stdlib>\nusing namespace metal;kernel void fan(device const uchar *src "
                @"[[buffer(0)]],device uint *dst [[buffer(1)]],constant uint2 &args [[buffer(2)]],uint i "
                @"[[thread_position_in_grid]]){if(i>=args.x)return;uint a=0,b=i+1,c=i+2;if(args.y==0){device "
                @"const ushort *p=(device const "
                @"ushort*)src;dst[i*3]=p[a];dst[i*3+1]=p[b];dst[i*3+2]=p[c];}else{device const "
                @"uint*p=(device const uint*)src;dst[i*3]=p[a];dst[i*3+1]=p[b];dst[i*3+2]=p[c];}}";
            id<MTLLibrary> lib = [d.device newLibraryWithSource:source options:nil error:&error];
            if (!lib) {
                failBackend(e, error.localizedDescription);
                return;
            }
            d.fanPipeline = [d.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fan"]
                                                                    error:&error];
            if (!d.fanPipeline) {
                failBackend(e, error.localizedDescription);
                return;
            }
        }
        suspendRender(d);
        id<MTLBuffer> expanded = [d.device newBufferWithLength:(NSUInteger)(count - 2) * 12
                                                       options:MTLResourceStorageModePrivate];
        if (!expanded) {
            resumeRender(d);
            failBackend(e, @"Cannot allocate expanded triangle fan.");
            return;
        }
        id<MTLComputeCommandEncoder> compute = [command(d) computeCommandEncoder];
        [compute setComputePipelineState:d.fanPipeline];
        [compute setBuffer:OBJ(id<MTLBuffer>, indices) offset:offset atIndex:0];
        [compute setBuffer:expanded offset:0 atIndex:1];
        uint32_t args[2] = {(uint32_t)count - 2, (uint32_t)type};
        [compute setBytes:args length:sizeof(args) atIndex:2];
        [compute dispatchThreads:MTLSizeMake(count - 2, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)(count - 2),
                                                  d.fanPipeline.maxTotalThreadsPerThreadgroup),
                                              1, 1)];
        [compute endEncoding];
        resumeRender(d);
        [d.render drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                             indexCount:(NSUInteger)(count - 2) * 3
                              indexType:MTLIndexTypeUInt32
                            indexBuffer:expanded
                      indexBufferOffset:0
                          instanceCount:instances
                             baseVertex:baseVertex
                           baseInstance:baseInstance];
    }
}

JNIEXPORT jlong JNICALL JNI_METHOD(currentGpuTimestamp)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)e;
        (void)t;
        MTLTimestamp cpu, gpu;
        [ctx(h).device sampleTimestamps:&cpu gpuTimestamp:&gpu];
        return (jlong)gpu;
    }
}

// Metal has no fan primitive. Indirect fan counts must be known before allocating
// the expanded index stream; this uncommon path resolves the argument buffer first.
JNIEXPORT void JNICALL JNI_METHOD(drawIndirectFan)(JNIEnv *e, jclass t, jlong h, jlong commands, jlong offset,
                                                   jlong indices, jint indexType) {
    @autoreleasepool {
        CuprumBackendContext *d = ctx(h);
        id<MTLBuffer> arguments = OBJ(id<MTLBuffer>, commands);
        NSUInteger argumentSize = indices ? sizeof(MTLDrawIndexedPrimitivesIndirectArguments)
                                          : sizeof(MTLDrawPrimitivesIndirectArguments);
        if (offset < 0 || (uint64_t)offset + argumentSize > arguments.length) {
            failBackend(e, @"Indirect fan arguments are outside their buffer.");
            return;
        }
        suspendRender(d);
        id<MTLCommandBuffer> pending = submitBackend(d, YES);
        if (pending.status == MTLCommandBufferStatusError) {
            failBackend(e, pending.error.localizedDescription);
            return;
        }
        resumeRender(d);
        if (indices) {
            MTLDrawIndexedPrimitivesIndirectArguments args;
            memcpy(&args, (const char *)arguments.contents + offset, sizeof(args));
            if (args.indexCount > INT32_MAX || args.instanceCount > INT32_MAX) {
                failBackend(e, @"Indirect fan count exceeds the backend draw range.");
                return;
            }
            JNI_METHOD(drawIndexedFan)(e, t, h, args.indexCount, args.instanceCount, indices,
                                       (jlong)args.indexStart * (indexType ? 4 : 2), indexType,
                                       args.baseVertex, args.baseInstance);
        } else {
            MTLDrawPrimitivesIndirectArguments args;
            memcpy(&args, (const char *)arguments.contents + offset, sizeof(args));
            if (args.vertexCount < 3 || !args.instanceCount)
                return;
            if (args.vertexCount > INT32_MAX || args.instanceCount > INT32_MAX ||
                (uint64_t)(args.vertexCount - 2) * 12 > d.device.maxBufferLength) {
                failBackend(e, @"Indirect fan count exceeds the backend draw range.");
                return;
            }
            id<MTLBuffer> expanded = [d.device newBufferWithLength:(NSUInteger)(args.vertexCount - 2) * 12
                                                           options:MTLResourceStorageModeShared];
            if (!expanded) {
                failBackend(e, @"Cannot allocate indirect fan indices.");
                return;
            }
            uint32_t *out = expanded.contents;
            for (uint32_t i = 1; i < args.vertexCount - 1; i++) {
                *out++ = args.vertexStart;
                *out++ = args.vertexStart + i;
                *out++ = args.vertexStart + i + 1;
            }
            [d.render drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                 indexCount:(NSUInteger)(args.vertexCount - 2) * 3
                                  indexType:MTLIndexTypeUInt32
                                indexBuffer:expanded
                          indexBufferOffset:0
                              instanceCount:args.instanceCount
                                 baseVertex:0
                               baseInstance:args.baseInstance];
        }
    }
}
