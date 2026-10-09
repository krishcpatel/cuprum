// SPDX-License-Identifier: LGPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <jni.h>
#import "cuprum_handles.h"
#include "com_krishcpatel_cuprum_bridge_MetalBackendNative.h"
#include <math.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#define JNI_METHOD(name) Java_com_krishcpatel_cuprum_bridge_MetalBackendNative_##name

static void failBackend(JNIEnv *env, NSString *message) {
    if ((*env)->ExceptionCheck(env))
        return;
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (type)
        (*env)->ThrowNew(env, type, message.UTF8String);
}

#define REQUIRE(condition, message, result) do { if (!(condition)) { failBackend(e, message); return result; } } while (0)
static BOOL bufferRange(JNIEnv *e, jlong token, jlong offset, jlong length) {
    id<MTLBuffer> b = CuprumGet(e, token, @"buffer", 0, NO);
    if (!b || offset < 0 || length < 0 || (uint64_t)offset > b.length || (uint64_t)length > b.length - (uint64_t)offset) {
        failBackend(e, @"Metal buffer range is outside the allocation."); return NO;
    }
    return YES;
}
static BOOL textureRegion(JNIEnv *e, jlong token, int mip, int layer, int x, int y, int width, int height) {
    id<MTLTexture> t = CuprumGet(e, token, @"texture", 0, NO);
    NSUInteger layers = t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
    if (!t || mip < 0 || (NSUInteger)mip >= t.mipmapLevelCount || layer < 0 || (NSUInteger)layer >= layers ||
        x < 0 || y < 0 || width < 0 || height < 0 ||
        (uint64_t)x + width > MAX((NSUInteger)1, t.width >> mip) ||
        (uint64_t)y + height > MAX((NSUInteger)1, t.height >> mip)) {
        failBackend(e, @"Metal texture mip, layer or rectangle is outside the allocation."); return NO;
    }
    return YES;
}
static NSUInteger pixelBytes(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatStencil8: return 1;
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float: case MTLPixelFormatDepth16Unorm: return 2;
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float:
        case MTLPixelFormatDepth32Float: case MTLPixelFormatDepth24Unorm_Stencil8: return 4;
        case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatDepth32Float_Stencil8: return 8;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
        default: return 0;
    }
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
@property(strong) NSMutableDictionary *pipelines;
@property(strong) NSMutableDictionary *pipelineStates;
@property(strong) NSMutableArray<NSString *> *messages;
@property NSUInteger submissions;
@property double gpuMilliseconds;
@property NSTimeInterval lastCompletion;
@property double completionInterval;
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
static CuprumBackendContext *ctx(JNIEnv *e, jlong h) { return CuprumGet(e, h, @"backend", 0, NO); }
static id<MTLCommandBuffer> command(JNIEnv *e, CuprumBackendContext *d) {
    if (!d.command) {
        MTLCommandBufferDescriptor *descriptor = [MTLCommandBufferDescriptor new];
        descriptor.retainedReferences = YES;
        descriptor.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        d.command = [d.queue commandBufferWithDescriptor:descriptor];
        if (!d.command) failBackend(e, @"Cannot allocate a Metal command buffer.");
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
static id<MTLBlitCommandEncoder> blit(JNIEnv *e, CuprumBackendContext *d) {
    if (!d.blit) {
        d.blit = [command(e, d) blitCommandEncoder];
        if (!d.blit) failBackend(e, @"Cannot allocate a Metal blit encoder.");
    }
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
static void resumeRender(JNIEnv *e, CuprumBackendContext *d) {
    MTLRenderPassDescriptor *p = [d.renderDescriptor copy];
    for (NSUInteger i = 0; i < 8; i++)
        if (p.colorAttachments[i].texture)
            p.colorAttachments[i].loadAction = MTLLoadActionLoad;
    if (p.depthAttachment.texture)
        p.depthAttachment.loadAction = MTLLoadActionLoad;
    if (p.stencilAttachment.texture)
        p.stencilAttachment.loadAction = MTLLoadActionLoad;
    d.render = [command(e, d) renderCommandEncoderWithDescriptor:p];
    if (!d.render) { failBackend(e, @"Cannot resume a Metal render pass."); return; }
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
    if (!s) { failBackend(e, @"Java string argument is required."); return nil; }
    const jchar *p = (*e)->GetStringChars(e, s, NULL);
    if (!p) return nil;
    NSString *r = [[NSString alloc] initWithCharacters:p length:(*e)->GetStringLength(e, s)];
    (*e)->ReleaseStringChars(e, s, p);
    return r;
}
static BOOL prepareHelpers(JNIEnv *e, CuprumBackendContext *d);
static CuprumBackendPipeline *prepareClear(JNIEnv *e, CuprumBackendContext *d, MTLPixelFormat color, MTLPixelFormat depth);
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
        d.messages = [NSMutableArray new];
        if (!prepareHelpers(e, d)) return 0;
        int colors[] = {6, 43, 0};
        int depths[] = {51, 52, 53, 54};
        for (NSUInteger i=0; i<4; i++) {
            if (depths[i] == 53 && !d.device.isDepth24Stencil8PixelFormatSupported) continue;
            if (!prepareClear(e, d, 0, pixelFormat(depths[i]))) return 0;
        }
        for (NSUInteger i=0; i<3; i++) {
            if (!prepareClear(e, d, pixelFormat(colors[i]), 0)) return 0;
            for (NSUInteger j=0; j<4; j++) {
                if (depths[j] == 53 && !d.device.isDepth24Stencil8PixelFormatSupported) continue;
                if (!prepareClear(e, d, pixelFormat(colors[i]), pixelFormat(depths[j]))) return 0;
            }
        }
        return CuprumKeep(d, 0, @"backend");
    }
}
JNIEXPORT jlongArray JNICALL JNI_METHOD(limits)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        (void)t;
        CuprumBackendContext *d = ctx(e, h);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(length > 0 && (uint64_t)length <= ctx(e, h).device.maxBufferLength - 255, @"Invalid Metal buffer size.", 0);
        id<MTLBuffer> b = [ctx(e, h).device newBufferWithLength:((NSUInteger)length + 255) & ~(NSUInteger)255
                                                     options:MTLResourceStorageModeShared];
        if (!b) {
            failBackend(e, @"Metal buffer allocation failed.");
            return 0;
        }
        return CuprumKeep(b, h, @"buffer");
    }
}
JNIEXPORT jobject JNICALL JNI_METHOD(mapBuffer)(JNIEnv *e, jclass t, jlong h, jlong offset, jint length) {
    @autoreleasepool {
        CuprumGet(e, h, @"buffer", 0, NO);
        if (!(*e)->ExceptionCheck(e)) CuprumThread(e, CuprumOwner(e, h));
        if ((*e)->ExceptionCheck(e)) { return 0; }
        (void)t;
        id<MTLBuffer> b = CuprumGet(e, h, @"buffer", 0, YES);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(w > 0 && height > 0 && w <= 16384 && height <= 16384 && layers > 0 && layers <= 2048 && mips > 0 && mips <= 1 + (int)floor(log2(MAX(w, height))), @"Invalid Metal texture dimensions or mip count.", 0);
        REQUIRE(!(usage & 16) || (w == height && layers % 6 == 0), @"Cube textures require square faces and a multiple of six layers.", 0);
        MTLPixelFormat pf = pixelFormat(format);
        if (pf == MTLPixelFormatDepth24Unorm_Stencil8 &&
            !ctx(e, h).device.isDepth24Stencil8PixelFormatSupported) {
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
        id<MTLTexture> tex = [ctx(e, h).device newTextureWithDescriptor:d];
        if (!tex) {
            failBackend(e, @"Metal texture allocation failed.");
            return 0;
        }
        if (usage & 8) {
            CuprumBackendContext *owner = ctx(e, h);
            if (format >= 51) {
                if (!prepareClear(e, owner, 0, pf)) return 0;
            } else {
                if (!prepareClear(e, owner, pf, 0)) return 0;
                int depths[] = {51, 52, 53, 54};
                for (NSUInteger i = 0; i < 4; i++) {
                    if (depths[i] == 53 && !owner.device.isDepth24Stencil8PixelFormatSupported) continue;
                    if (!prepareClear(e, owner, pf, pixelFormat(depths[i]))) return 0;
                }
            }
        }
        return CuprumKeep(tex, h, @"texture");
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(textureView)(JNIEnv *e, jclass t, jlong h, jint base, jint count) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"texture", 0, NO);
        if (!(*e)->ExceptionCheck(e)) CuprumThread(e, CuprumOwner(e, h));
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(base >= 0 && count > 0 && (uint64_t)base + count <= [CuprumGet(e, h, @"texture", 0, NO) mipmapLevelCount], @"Texture view mip range is invalid.", 0);
        id<MTLTexture> tex = CuprumGet(e, h, @"texture", 0, YES);
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
        return CuprumKeep(view, CuprumOwner(e, h), @"texture");
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(texelView)(JNIEnv *e, jclass t, jlong device, jlong h, jlong offset,
                                              jlong length, jint format) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, device, @"backend", 0, NO);
        CuprumThread(e, device);
        CuprumGet(e, h, @"buffer", device, NO);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(format >= 0 && format < 51, @"Invalid texel format.", 0);
        id<MTLBuffer> b = CuprumGet(e, h, @"buffer", 0, YES);
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
        CuprumBackendContext *owner = ctx(e, device);
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
                    resumeRender(e, owner);
                failBackend(e, @"Cannot allocate aligned texel buffer.");
                return 0;
            }
            [blit(e, owner) copyFromBuffer:b
                           sourceOffset:offset
                               toBuffer:aligned
                      destinationOffset:0
                                   size:length];
            endBlit(owner);
            if (restart)
                resumeRender(e, owner);
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
        return CuprumKeep(v, device, @"texture");
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(sampler)(JNIEnv *e, jclass t, jlong h, jint u, jint v, jint min, jint mag,
                                            jint aniso, jdouble lod) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(u >= 0 && u <= 1 && v >= 0 && v <= 1 && min >= 0 && min <= 1 && mag >= 0 && mag <= 1 && aniso >= 1 && aniso <= 16 && isfinite(lod) && lod >= 0, @"Invalid Metal sampler parameters.", 0);
        CuprumBackendContext *d = ctx(e, h);
        NSString *key = [NSString stringWithFormat:@"%d/%d/%d/%d/%d/%.17g", u, v, min, mag, aniso, lod];
        if (!d.samplers)
            d.samplers = [NSMutableDictionary new];
        id<MTLSamplerState> cached = d.samplers[key];
        if (cached)
            return CuprumKeep(cached, h, @"sampler"); // Each Java sampler retains an independent ownership reference.
        MTLSamplerDescriptor *s = [MTLSamplerDescriptor new];
        s.sAddressMode = u ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        s.tAddressMode = v ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        s.rAddressMode = MTLSamplerAddressModeClampToEdge;
        s.minFilter = min ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        s.magFilter = mag ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        s.mipFilter = min ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        s.maxAnisotropy = aniso;
        s.lodMaxClamp = lod;
        id<MTLSamplerState> state = [ctx(e, h).device newSamplerStateWithDescriptor:s];
        if (!state) {
            failBackend(e, @"Metal sampler allocation failed.");
            return 0;
        }
        d.samplers[key] = state;
        return CuprumKeep(state, h, @"sampler");
    }
}
JNIEXPORT void JNICALL JNI_METHOD(release)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        (void)e;
        (void)t;
        if (h)
            CuprumRelease(e, h);
    }
}
static id<MTLLibrary> shaderLibrary(CuprumBackendContext *d, NSString *source, NSError **error) {
    @synchronized(d) {
    if (!d.libraries)
        d.libraries = [NSMutableDictionary new];
    id<MTLLibrary> cached = d.libraries[source];
    if (cached)
        return cached;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = CuprumLanguageVersion();
    id<MTLLibrary> library = [d.device newLibraryWithSource:source options:options error:error];
    if (library)
        d.libraries[source] = library;
    return library;
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(pipeline)(JNIEnv *e, jclass t, jlong h, jstring vs, jstring ve, jstring fs,
                                             jstring fe, jintArray attrs, jintArray layouts, jintArray colors,
                                             jint depthFormat, jint depthCompare, jboolean write,
                                             jboolean cull, jboolean wire, jfloat bias, jfloat slope) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(vs && ve && fs && fe && attrs && layouts && colors, @"Pipeline sources and descriptors are required.", 0);
        int attributeCount = (*e)->GetArrayLength(e, attrs), layoutCount = (*e)->GetArrayLength(e, layouts), colorCount = (*e)->GetArrayLength(e, colors);
        REQUIRE(attributeCount % 4 == 0 && attributeCount <= 124 && layoutCount % 3 == 0 && layoutCount <= 45 && colorCount % 9 == 0 && colorCount <= 72, @"Malformed Metal pipeline descriptor arrays.", 0);
        REQUIRE(depthCompare >= 0 && depthCompare < 8 && (depthFormat == -1 || (depthFormat >= 51 && depthFormat <= 54)) && isfinite(bias) && isfinite(slope), @"Invalid pipeline depth state.", 0);
        jint av[124], lv[45], cv[72];
        (*e)->GetIntArrayRegion(e, attrs, 0, attributeCount, av);
        (*e)->GetIntArrayRegion(e, layouts, 0, layoutCount, lv);
        (*e)->GetIntArrayRegion(e, colors, 0, colorCount, cv);
        if ((*e)->ExceptionCheck(e)) return 0;
        for (int i = 0; i < layoutCount; i += 3) REQUIRE(lv[i] >= 0 && lv[i] < 15 && lv[i+1] > 0 && lv[i+2] >= 0, @"Invalid vertex buffer layout.", 0);
        for (int i = 0; i < attributeCount; i += 4) {
            REQUIRE(av[i] >= 0 && av[i] < 15 && av[i+1] >= 0 && av[i+1] < 31 && av[i+2] >= 0 && vertexFormat(av[i+3]) != MTLVertexFormatInvalid, @"Invalid vertex attribute descriptor.", 0);
            BOOL found = NO;
            for (int j = 0; j < layoutCount; j += 3) if (lv[j] == av[i] && av[i+2] < lv[j+1]) found = YES;
            REQUIRE(found, @"Vertex attribute has no compatible layout.", 0);
        }
        for (int i = 0; i < colorCount; i += 9) {
            if (cv[i] == -1) continue;
            REQUIRE(cv[i] >= 0 && cv[i] < 51 && pixelFormat(cv[i]) && cv[i+1] >= 0 && cv[i+1] <= 15 && cv[i+2] >= 0 && cv[i+2] <= 1, @"Invalid color attachment state.", 0);
            if (cv[i+2]) REQUIRE(cv[i+3] >= 0 && cv[i+3] < 15 && cv[i+4] >= 0 && cv[i+4] < 15 && cv[i+5] >= 0 && cv[i+5] < 5 && cv[i+6] >= 0 && cv[i+6] < 15 && cv[i+7] >= 0 && cv[i+7] < 15 && cv[i+8] >= 0 && cv[i+8] < 5, @"Invalid blend factors or operations.", 0);
        }
        CuprumBackendContext *d = ctx(e, h);
        @synchronized(d) {
        if (!d.pipelines) d.pipelines = [NSMutableDictionary new];
        if (!d.pipelineStates) d.pipelineStates = [NSMutableDictionary new];
        NSData *attributeKey, *layoutKey, *colorKey;
        jint *keyValues = (*e)->GetIntArrayElements(e, attrs, NULL);
        if (!keyValues) return 0;
        attributeKey = [NSData dataWithBytes:keyValues length:(*e)->GetArrayLength(e, attrs) * sizeof(jint)];
        (*e)->ReleaseIntArrayElements(e, attrs, keyValues, JNI_ABORT);
        keyValues = (*e)->GetIntArrayElements(e, layouts, NULL);
        if (!keyValues) return 0;
        layoutKey = [NSData dataWithBytes:keyValues length:(*e)->GetArrayLength(e, layouts) * sizeof(jint)];
        (*e)->ReleaseIntArrayElements(e, layouts, keyValues, JNI_ABORT);
        keyValues = (*e)->GetIntArrayElements(e, colors, NULL);
        if (!keyValues) return 0;
        colorKey = [NSData dataWithBytes:keyValues length:(*e)->GetArrayLength(e, colors) * sizeof(jint)];
        (*e)->ReleaseIntArrayElements(e, colors, keyValues, JNI_ABORT);
        // RenderPearl has one sample and no independent stencil-state descriptor.
        NSString *vertexSource = string(e, vs), *vertexEntry = string(e, ve), *fragmentSource = string(e, fs), *fragmentEntry = string(e, fe);
        if ((*e)->ExceptionCheck(e)) return 0;
        REQUIRE(vertexSource && vertexEntry && fragmentSource && fragmentEntry, @"Cannot read pipeline sources.", 0);
        NSArray *cacheKey = @[vertexSource, vertexEntry, fragmentSource, fragmentEntry,
            attributeKey, layoutKey, colorKey, @(depthFormat), @1, @(depthCompare), @(write),
            @(cull), @(wire), @(bias), @(slope)];
        CuprumBackendPipeline *existing = d.pipelines[cacheKey];
        if (existing) return CuprumKeep(existing, h, @"pipeline");
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
        REQUIRE(p.vertexFunction && p.fragmentFunction, @"Metal shader entry point does not exist.", 0);
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        jint *a = (*e)->GetIntArrayElements(e, attrs, NULL);
        if (!a) return 0;
        int ac = (*e)->GetArrayLength(e, attrs);
        for (int i = 0; i < ac; i += 4) {
            vd.attributes[a[i + 1]].bufferIndex = a[i] + 16;
            vd.attributes[a[i + 1]].offset = a[i + 2];
            vd.attributes[a[i + 1]].format = vertexFormat(a[i + 3]);
        }
        (*e)->ReleaseIntArrayElements(e, attrs, a, JNI_ABORT);
        jint *l = (*e)->GetIntArrayElements(e, layouts, NULL);
        if (!l) return 0;
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
        if (!c) return 0;
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
        NSArray *psoKey = [cacheKey subarrayWithRange:NSMakeRange(0, 9)];
        CuprumBackendPipeline *shared = d.pipelineStates[psoKey];
        if (shared) {
            r.pso = shared.pso;
            reflection = shared.reflection;
        } else {
        r.pso = [d.device newRenderPipelineStateWithDescriptor:p
                                                    options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo
                                                 reflection:&reflection error:&error];
        }
        r.reflection = reflection;
        if (!r.pso) {
            failBackend(e, [@"Metal PSO: " stringByAppendingString:error.localizedDescription ?: @"unknown"]);
            return 0;
        }
        if (!shared) d.pipelineStates[psoKey] = r;
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
        d.pipelines[cacheKey] = r;
        return CuprumKeep(r, h, @"pipeline");
        }
    }
}
JNIEXPORT void JNICALL JNI_METHOD(beginPass)(JNIEnv *e, jclass t, jlong h, jlongArray colors,
                                             jdoubleArray clears, jlong depth, jdouble depthClear, jint x,
                                             jint y, jint width, jint height) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        CuprumGet(e, depth, @"texture", h, YES);
        if ((*e)->ExceptionCheck(e)) return;
        REQUIRE(colors && clears, @"Pass attachment arrays are required.", );
        int attachmentCount = (*e)->GetArrayLength(e, colors);
        REQUIRE(attachmentCount <= 8 && (*e)->GetArrayLength(e, clears) == attachmentCount * 5 && isfinite(depthClear) && depthClear <= 1, @"Malformed pass attachments or depth clear.", );
        jlong attachments[8]; (*e)->GetLongArrayRegion(e, colors, 0, attachmentCount, attachments);
        if ((*e)->ExceptionCheck(e)) return;
        BOOL hasAttachment = depth != 0;
        for (int i = 0; i < attachmentCount; i++) if (attachments[i]) {
            CuprumGet(e, attachments[i], @"texture", h, NO);
            REQUIRE(textureRegion(e, attachments[i], 0, 0, x, y, width, height), @"Invalid pass render area.", );
            hasAttachment = YES;
        }
        REQUIRE(hasAttachment && width > 0 && height > 0, @"Render pass requires attachments and a nonempty area.", );
        if (depth) REQUIRE(textureRegion(e, depth, 0, 0, x, y, width, height), @"Invalid depth render area.", );
        if ((*e)->ExceptionCheck(e)) return;
        CuprumBackendContext *d = ctx(e, h);
        endBlit(d);
        if (d.render) {
            failBackend(e, @"Nested Metal render pass.");
            return;
        }
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        jlong *c = (*e)->GetLongArrayElements(e, colors, NULL);
        if (!c) return;
        jdouble *v = (*e)->GetDoubleArrayElements(e, clears, NULL);
        if (!v) { (*e)->ReleaseLongArrayElements(e, colors, c, JNI_ABORT); return; }
        int count = (*e)->GetArrayLength(e, colors);
        for (int i = 0; i < count; i++) {
            if (!c[i])
                continue;
            p.colorAttachments[i].texture = CuprumGet(e, c[i], @"texture", 0, YES);
            p.colorAttachments[i].loadAction = v[i * 5] ? MTLLoadActionClear : MTLLoadActionLoad;
            p.colorAttachments[i].storeAction = MTLStoreActionStore;
            p.colorAttachments[i].clearColor =
                MTLClearColorMake(v[i * 5 + 1], v[i * 5 + 2], v[i * 5 + 3], v[i * 5 + 4]);
        }
        (*e)->ReleaseLongArrayElements(e, colors, c, JNI_ABORT);
        (*e)->ReleaseDoubleArrayElements(e, clears, v, JNI_ABORT);
        if (depth) {
            id<MTLTexture> tex = CuprumGet(e, depth, @"texture", 0, YES);
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
        d.render = [command(e, d) renderCommandEncoderWithDescriptor:p];
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        (void)e;
        (void)t;
        CuprumBackendContext *d = ctx(e, h);
        finishRender(d);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindPipeline)(JNIEnv *e, jclass t, jlong h, jlong p) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, p, @"pipeline", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );

        (void)e;
        (void)t;
        CuprumBackendContext *d = ctx(e, h);
        d.boundPipeline = CuprumGet(e, p, @"pipeline", 0, YES);
        applyPipeline(d, d.boundPipeline);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindBuffer)(JNIEnv *e, jclass t, jlong h, jint slot, jlong b,
                                              jlong offset) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, b, @"buffer", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(slot >= 0 && slot < 31 && offset >= 0 && (!b || bufferRange(e, b, offset, 1)), @"Invalid Metal buffer slot or offset.", );
        if (slot < 16 && b) REQUIRE(offset % (ctx(e,h).device.hasUnifiedMemory ? 16 : 256) == 0, @"Uniform offset is misaligned.", );
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> x = ctx(e, h).render;
        id<MTLBuffer> buffer = CuprumGet(e, b, @"buffer", 0, YES);
        if (buffer)
            ctx(e, h).boundBuffers[@(slot)] = @[ buffer, @(offset) ];
        else
            [ctx(e, h).boundBuffers removeObjectForKey:@(slot)];
        [x setVertexBuffer:buffer offset:offset atIndex:slot];
        if (slot < 16)
            [x setFragmentBuffer:buffer offset:offset atIndex:slot];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bindTexture)(JNIEnv *e, jclass t, jlong h, jint slot, jlong tex, jlong s) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, tex, @"texture", h, YES);
        CuprumGet(e, s, @"sampler", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(slot >= 0 && slot < 16, @"Invalid Metal texture/sampler slot.", );
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> x = ctx(e, h).render;
        CuprumBackendContext *d = ctx(e, h);
        if (tex)
            d.boundTextures[@(slot)] = CuprumGet(e, tex, @"texture", 0, YES);
        else
            [d.boundTextures removeObjectForKey:@(slot)];
        if (s)
            d.boundSamplers[@(slot)] = CuprumGet(e, s, @"sampler", 0, YES);
        else
            [d.boundSamplers removeObjectForKey:@(slot)];
        [x setVertexTexture:CuprumGet(e, tex, @"texture", 0, YES) atIndex:slot];
        [x setFragmentTexture:CuprumGet(e, tex, @"texture", 0, YES) atIndex:slot];
        {
            [x setVertexSamplerState:CuprumGet(e, s, @"sampler", 0, YES) atIndex:slot];
            [x setFragmentSamplerState:CuprumGet(e, s, @"sampler", 0, YES) atIndex:slot];
        }
    }
}
JNIEXPORT void JNICALL JNI_METHOD(scissor)(JNIEnv *e, jclass t, jlong h, jint x, jint y, jint w,
                                           jint height) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        id<MTLTexture> extent = ctx(e,h).renderDescriptor.depthAttachment.texture;
        for (NSUInteger i=0; !extent && i<8; i++) extent=ctx(e,h).renderDescriptor.colorAttachments[i].texture;
        REQUIRE(x >= 0 && y >= 0 && w >= 0 && height >= 0 && (uint64_t)x + w <= extent.width && (uint64_t)y + height <= extent.height, @"Scissor rectangle is outside attachments.", );
        (void)e;
        (void)t;
        ctx(e, h).scissor = (MTLScissorRect){x, y, w, height};
        [ctx(e, h).render setScissorRect:ctx(e, h).scissor];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(draw)(JNIEnv *e, jclass t, jlong h, jint primitive, jint count,
                                        jint instances, jint first, jint baseInstance, jlong indices,
                                        jlong offset, jint indexType, jint baseVertex) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, indices, @"buffer", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).boundPipeline, @"No Metal pipeline is bound.", );
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(primitive >= 0 && primitive <= 4 && count >= 0 && instances >= 0 && first >= 0 && baseInstance >= 0 && indexType >= 0 && indexType <= 1, @"Invalid draw parameters.", );
        if (indices) REQUIRE(offset % (indexType ? 4 : 2) == 0 && bufferRange(e, indices, offset, (jlong)count * (indexType ? 4 : 2)), @"Invalid indexed draw range or alignment.", );
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> r = ctx(e, h).render;
        if (indices) {
            [r drawIndexedPrimitives:primitive
                          indexCount:count
                           indexType:indexType
                         indexBuffer:CuprumGet(e, indices, @"buffer", 0, YES)
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, commands, @"buffer", h, NO);
        CuprumGet(e, indices, @"buffer", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).boundPipeline, @"No Metal pipeline is bound.", );
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(primitive >= 0 && primitive <= 4 && indexType >= 0 && indexType <= 1 && offset % 4 == 0 && bufferRange(e, commands, offset, indices ? 20 : 16), @"Invalid indirect command range or alignment.", );
        (void)e;
        (void)t;
        id<MTLRenderCommandEncoder> r = ctx(e, h).render;
        if (indices)
            [r drawIndexedPrimitives:primitive
                           indexType:indexType
                         indexBuffer:CuprumGet(e, indices, @"buffer", 0, YES)
                   indexBufferOffset:0
                      indirectBuffer:CuprumGet(e, commands, @"buffer", 0, YES)
                indirectBufferOffset:offset];
        else
            [r drawPrimitives:primitive
                      indirectBuffer:CuprumGet(e, commands, @"buffer", 0, YES)
                indirectBufferOffset:offset];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(copyBuffer)(JNIEnv *e, jclass t, jlong h, jlong src, jlong so, jlong dst,
                                              jlong to, jlong size) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, src, @"buffer", h, NO);
        CuprumGet(e, dst, @"buffer", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(!ctx(e,h).render && size > 0 && bufferRange(e, src, so, size) && bufferRange(e, dst, to, size), @"Invalid buffer copy or active render pass.", );
        REQUIRE(src != dst || (uint64_t)so + size <= (uint64_t)to || (uint64_t)to + size <= (uint64_t)so, @"Overlapping same-buffer copies are unsupported.", );
        (void)e;
        (void)t;
        [blit(e, ctx(e, h)) copyFromBuffer:CuprumGet(e, src, @"buffer", 0, YES)
                        sourceOffset:so
                            toBuffer:CuprumGet(e, dst, @"buffer", 0, YES)
                   destinationOffset:to
                                size:size];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(bufferTexture)(JNIEnv *e, jclass t, jlong h, jlong b, jlong offset,
                                                 jint rowBytes, jint imageBytes, jlong tex, jint mip,
                                                 jint layer, jint x, jint y, jint w, jint height,
                                                 jboolean upload) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, b, @"buffer", h, NO);
        CuprumGet(e, tex, @"texture", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(!ctx(e,h).render && textureRegion(e, tex, mip, layer, x, y, w, height), @"Invalid texture transfer or active render pass.", );
        id<MTLTexture> transferTexture = CuprumGet(e, tex, @"texture", h, NO);
        NSUInteger bytesPerPixel = pixelBytes(transferTexture.pixelFormat);
        REQUIRE(bytesPerPixel && w > 0 && height > 0 && rowBytes > 0 && (uint64_t)rowBytes >= (uint64_t)w * bytesPerPixel && rowBytes % bytesPerPixel == 0 && imageBytes >= 0 && (uint64_t)imageBytes >= (uint64_t)rowBytes * height && offset % bytesPerPixel == 0 && bufferRange(e, b, offset, (jlong)(height-1) * rowBytes + (jlong)w * bytesPerPixel), @"Invalid texture row stride or staging range.", );
        (void)e;
        (void)t;
        id<MTLBlitCommandEncoder> r = blit(e, ctx(e, h));
        if (upload)
            [r copyFromBuffer:CuprumGet(e, b, @"buffer", 0, YES)
                       sourceOffset:offset
                  sourceBytesPerRow:rowBytes
                sourceBytesPerImage:imageBytes
                         sourceSize:MTLSizeMake(w, height, 1)
                          toTexture:CuprumGet(e, tex, @"texture", 0, YES)
                   destinationSlice:layer
                   destinationLevel:mip
                  destinationOrigin:MTLOriginMake(x, y, 0)];
        else
            [r copyFromTexture:CuprumGet(e, tex, @"texture", 0, YES)
                             sourceSlice:layer
                             sourceLevel:mip
                            sourceOrigin:MTLOriginMake(x, y, 0)
                              sourceSize:MTLSizeMake(w, height, 1)
                                toBuffer:CuprumGet(e, b, @"buffer", 0, YES)
                       destinationOffset:offset
                  destinationBytesPerRow:rowBytes
                destinationBytesPerImage:imageBytes];
    }
}
JNIEXPORT void JNICALL JNI_METHOD(copyTexture)(JNIEnv *e, jclass t, jlong h, jlong src, jint sm, jint sl,
                                               jint sx, jint sy, jlong dst, jint dm, jint dl, jint dx,
                                               jint dy, jint w, jint height) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, src, @"texture", h, NO);
        CuprumGet(e, dst, @"texture", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(!ctx(e,h).render && textureRegion(e, src, sm, sl, sx, sy, w, height) && textureRegion(e, dst, dm, dl, dx, dy, w, height), @"Invalid texture copy.", );
        REQUIRE([CuprumGet(e, src, @"texture", h, NO) pixelFormat] == [CuprumGet(e, dst, @"texture", h, NO) pixelFormat], @"Texture copies require identical formats.", );
        (void)e;
        (void)t;
        [blit(e, ctx(e, h)) copyFromTexture:CuprumGet(e, src, @"texture", 0, YES)
                          sourceSlice:sl
                          sourceLevel:sm
                         sourceOrigin:MTLOriginMake(sx, sy, 0)
                           sourceSize:MTLSizeMake(w, height, 1)
                            toTexture:CuprumGet(e, dst, @"texture", 0, YES)
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
      @synchronized(d.messages) {
          d.submissions++;
          d.gpuMilliseconds = MAX(0, done.GPUEndTime - done.GPUStartTime) * 1000;
          NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
          d.completionInterval = d.lastCompletion ? (now - d.lastCompletion) * 1000 : 0;
          d.lastCompletion = now;
          if (done.status == MTLCommandBufferStatusError) [d.messages addObject:done.error.description ?: @"Metal submission failed"];
          for (id<MTLFunctionLog> log in done.logs) [d.messages addObject:[NSString stringWithFormat:@"Metal validation: %@ / %@", log.encoderLabel, log.debugLocation.functionName]];
          while (d.messages.count > 256) [d.messages removeObjectAtIndex:0];
      }
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        id<MTLCommandBuffer> c = submitBackend(ctx(e, h), wait);
        if (wait && c.status == MTLCommandBufferStatusError) {
            failBackend(e, c.error.localizedDescription);
            return 0;
        }
        return c ? CuprumKeep(c, h, @"command") : 0;
    }
}
JNIEXPORT jboolean JNICALL JNI_METHOD(await)(JNIEnv *e, jclass t, jlong h, jlong timeout) {
    (void)t;
    @autoreleasepool {
        id<MTLCommandBuffer> c = CuprumGet(e, h, @"command", 0, YES);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        CuprumBackendContext *d = ctx(e, h);
        submitBackend(d, YES);
        id<MTLCommandBuffer> c = [d.queue commandBuffer];
        REQUIRE(c, @"Cannot allocate Metal queue drain command.", );
        [c commit];
        [c waitUntilCompleted];
        if (c.status == MTLCommandBufferStatusError) failBackend(e, c.error.localizedDescription);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(closeDevice)(JNIEnv *e, jclass t, jlong h) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        JNI_METHOD(waitIdle)(e, t, h);
        ctx(e, h).drawable = nil;
        CuprumRelease(e, h);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, layer, @"layer", 0, NO);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE([NSThread isMainThread] && w > 0 && height > 0 && w <= 16384 && height <= 16384, @"Invalid drawable size or Cocoa thread.", 0);
        CuprumBackendContext *d = ctx(e, h);
        if (d.drawable) {
            failBackend(e, @"Metal drawable already acquired.");
            return 0;
        }
        CAMetalLayer *l = CuprumGet(e, layer, @"layer", 0, YES);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, source, @"texture", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        CuprumBackendContext *d = ctx(e, h);
        REQUIRE(!d.render && !d.drawableScheduled, @"Presentation requires a finished pass and a drawable not already scheduled.", );
        endBlit(d);
        if (!d.drawable) {
            failBackend(e, @"No drawable acquired.");
            return;
        }

        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = d.drawable.texture;
        p.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> r = [command(e, d) renderCommandEncoderWithDescriptor:p];
        REQUIRE(r, @"Cannot allocate drawable render encoder.", );
        [r setRenderPipelineState:d.screenPipeline];
        [r setFragmentTexture:CuprumGet(e, source, @"texture", 0, YES) atIndex:0];
        [r setFragmentSamplerState:d.screenSampler atIndex:0];
        [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [r endEncoding];
        [command(e, d) presentDrawable:d.drawable];
        d.drawableScheduled = YES;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(present)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        CuprumBackendContext *d = ctx(e, h);
        if (!d.drawable) {
            failBackend(e, @"No Metal drawable to present.");
            return;
        }
        if (!d.drawableScheduled) {
            [command(e, d) presentDrawable:d.drawable];
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(size > 0 && size <= 1048576, @"Invalid timestamp query pool size.", 0);
        CuprumBackendContext *d = ctx(e, h);
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
        return CuprumKeep(q, h, @"query");
    }
}
JNIEXPORT void JNICALL JNI_METHOD(timestamp)(JNIEnv *e, jclass t, jlong h, jlong pool, jint index) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, pool, @"query", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(index >= 0 && (NSUInteger)index < [CuprumGet(e, pool, @"query", h, NO) commands].count, @"Timestamp index is outside pool.", );
        CuprumBackendContext *d = ctx(e, h);
        CuprumBackendQueries *q = CuprumGet(e, pool, @"query", 0, YES);
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
                id<MTLBlitCommandEncoder> b = [command(e, d) blitCommandEncoderWithDescriptor:p];
                if (!d.timestampMarker)
                    d.timestampMarker = [d.device newBufferWithLength:4 options:MTLResourceStorageModeShared];
                [b fillBuffer:d.timestampMarker range:NSMakeRange(0, 4) value:0];
                [b endEncoding];
            } else if ([d.device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary]) {
                [blit(e, d) sampleCountersInBuffer:q.samples atSampleIndex:index withBarrier:YES];
                endBlit(d);
            } else {
                failBackend(e, @"Metal GPU timestamp sampling is unavailable.");
                return;
            }
        }
        q.commands[index] = command(e, d);
        if (restart)
            resumeRender(e, d);
    }
}
JNIEXPORT jlong JNICALL JNI_METHOD(queryValue)(JNIEnv *e, jclass t, jlong pool, jint index) {
    (void)e;
    (void)t;
    @autoreleasepool {
        CuprumGet(e, pool, @"query", 0, NO);
        if (!(*e)->ExceptionCheck(e)) CuprumThread(e, CuprumOwner(e, pool));
        if ((*e)->ExceptionCheck(e)) { return 0; }
        REQUIRE(index >= 0 && (NSUInteger)index < [CuprumGet(e, pool, @"query", 0, NO) commands].count, @"Timestamp index is outside pool.", 0);
        CuprumBackendQueries *q = CuprumGet(e, pool, @"query", 0, YES);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(label && (push || ctx(e,h).debugGroups.count > 0), @"Unbalanced debug group or missing label.", );
        (void)t;
        CuprumBackendContext *d = ctx(e, h);
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
        return CuprumRetain(e, h);
    }
}
JNIEXPORT void JNICALL JNI_METHOD(clearRegion)(JNIEnv *e, jclass t, jlong h, jlong color, jlong depth,
                                               jfloat red, jfloat green, jfloat blue, jfloat alpha,
                                               jfloat depthValue, jint x, jint y, jint width, jint height) {
    (void)t;
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, color, @"texture", h, YES);
        CuprumGet(e, depth, @"texture", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(!ctx(e,h).render && (color || depth) && isfinite(red) && isfinite(green) && isfinite(blue) && isfinite(alpha) && (!depth || (isfinite(depthValue) && depthValue >= 0 && depthValue <= 1)), @"Invalid clear parameters or active pass.", );
        if (color) REQUIRE(textureRegion(e, color, 0, 0, x, y, width, height), @"Invalid color clear rectangle.", );
        if (depth) REQUIRE(textureRegion(e, depth, 0, 0, x, y, width, height), @"Invalid depth clear rectangle.", );
        CuprumBackendContext *d = ctx(e, h);
        endBlit(d);
        id<MTLTexture> c = CuprumGet(e, color, @"texture", 0, YES), z = CuprumGet(e, depth, @"texture", 0, YES), extent = c ?: z;
        NSString *key = [NSString
            stringWithFormat:@"%lu/%lu", (unsigned long)c.pixelFormat, (unsigned long)z.pixelFormat];
        if (!d.clearPipelines)
            d.clearPipelines = [NSMutableDictionary new];
        CuprumBackendPipeline *pipeline = d.clearPipelines[key];
        if (!pipeline) {
            failBackend(e, @"Clear attachment combination was not prepared during resource creation.");
            return;
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
        id<MTLRenderCommandEncoder> r = [command(e, d) renderCommandEncoderWithDescriptor:p];
        REQUIRE(r, @"Cannot allocate clear render encoder.", );
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, indices, @"buffer", h, NO);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).boundPipeline, @"No Metal pipeline is bound.", );
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(count >= 0 && instances >= 0 && baseInstance >= 0 && type >= 0 && type <= 1 && offset % (type ? 4 : 2) == 0 && bufferRange(e, indices, offset, (jlong)count * (type ? 4 : 2)), @"Invalid indexed fan parameters.", );
        REQUIRE(count < 3 || (uint64_t)(count - 2) * 12 <= ctx(e, h).device.maxBufferLength, @"Expanded fan exceeds device allocation limit.", );
        if (count < 3)
            return;
        CuprumBackendContext *d = ctx(e, h);

        suspendRender(d);
        id<MTLBuffer> expanded = [d.device newBufferWithLength:(NSUInteger)(count - 2) * 12
                                                       options:MTLResourceStorageModePrivate];
        if (!expanded) {
            resumeRender(e, d);
            failBackend(e, @"Cannot allocate expanded triangle fan.");
            return;
        }
        id<MTLComputeCommandEncoder> compute = [command(e, d) computeCommandEncoder];
        if (!compute) { resumeRender(e,d); failBackend(e, @"Cannot allocate fan compute encoder."); return; }
        [compute setComputePipelineState:d.fanPipeline];
        [compute setBuffer:CuprumGet(e, indices, @"buffer", 0, YES) offset:offset atIndex:0];
        [compute setBuffer:expanded offset:0 atIndex:1];
        uint32_t args[2] = {(uint32_t)count - 2, (uint32_t)type};
        [compute setBytes:args length:sizeof(args) atIndex:2];
        [compute dispatchThreads:MTLSizeMake(count - 2, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(MIN((NSUInteger)(count - 2),
                                                  d.fanPipeline.maxTotalThreadsPerThreadgroup),
                                              1, 1)];
        [compute endEncoding];
        resumeRender(e, d);
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
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        if ((*e)->ExceptionCheck(e)) { return 0; }
        (void)e;
        (void)t;
        MTLTimestamp cpu, gpu;
        [ctx(e, h).device sampleTimestamps:&cpu gpuTimestamp:&gpu];
        return (jlong)gpu;
    }
}

// Metal has no fan primitive. Indirect fan counts must be known before allocating
// the expanded index stream; this uncommon path resolves the argument buffer first.
JNIEXPORT void JNICALL JNI_METHOD(drawIndirectFan)(JNIEnv *e, jclass t, jlong h, jlong commands, jlong offset,
                                                   jlong indices, jint indexType) {
    @autoreleasepool {
        CuprumGet(e, h, @"backend", 0, NO);
        CuprumThread(e, h);
        CuprumGet(e, commands, @"buffer", h, NO);
        CuprumGet(e, indices, @"buffer", h, YES);
        if ((*e)->ExceptionCheck(e)) { return; }
        REQUIRE(ctx(e,h).boundPipeline, @"No Metal pipeline is bound.", );
        REQUIRE(ctx(e,h).render, @"No Metal render pass is active.", );
        REQUIRE(indexType >= 0 && indexType <= 1 && offset % 4 == 0 && bufferRange(e, commands, offset, indices ? 20 : 16), @"Invalid indirect fan command range.", );
        CuprumBackendContext *d = ctx(e, h);
        id<MTLBuffer> arguments = CuprumGet(e, commands, @"buffer", 0, YES);
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
        resumeRender(e, d);
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

static BOOL prepareHelpers(JNIEnv *e, CuprumBackendContext *d) {
    {

            NSError *error = nil;
            id<MTLLibrary> lib = shaderLibrary(d, screenMSL(), &error);
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
                return NO;
            }

    }
    {
            NSError *error = nil;
            NSString *source =
                @"#include <metal_stdlib>\nusing namespace metal;kernel void fan(device const uchar *src "
                @"[[buffer(0)]],device uint *dst [[buffer(1)]],constant uint2 &args [[buffer(2)]],uint i "
                @"[[thread_position_in_grid]]){if(i>=args.x)return;uint a=0,b=i+1,c=i+2;if(args.y==0){device "
                @"const ushort *p=(device const "
                @"ushort*)src;dst[i*3]=p[a];dst[i*3+1]=p[b];dst[i*3+2]=p[c];}else{device const "
                @"uint*p=(device const uint*)src;dst[i*3]=p[a];dst[i*3+1]=p[b];dst[i*3+2]=p[c];}}";
            id<MTLLibrary> lib = shaderLibrary(d, source, &error);
            if (!lib) {
                failBackend(e, error.localizedDescription);
                return NO;
            }
            d.fanPipeline = [d.device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fan"]
                                                                    error:&error];
            if (!d.fanPipeline) {
                failBackend(e, error.localizedDescription);
                return NO;
            }

    }
    return YES;
}

static NSString *clearType(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRGBA8Uint:
        case MTLPixelFormatR16Uint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint:
        case MTLPixelFormatRGB10A2Uint: return @"uint4";
        case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatR16Sint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatR32Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA32Sint: return @"int4";
        default: return @"float4";
    }
}
static CuprumBackendPipeline *prepareClear(JNIEnv *e, CuprumBackendContext *d, MTLPixelFormat color, MTLPixelFormat depth) {
    NSString *key = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)color, (unsigned long)depth];
    if (!d.clearPipelines) d.clearPipelines = [NSMutableDictionary new];
    CuprumBackendPipeline *pipeline = d.clearPipelines[key];
    if (pipeline) return pipeline;

            NSString *source = [@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 cv(uint i "
                                @"[[vertex_id]]){float2 p=float2((i<<1)&2,i&2);return "
                                @"float4(p*2-1,0,1);}struct V{float4 color;float depth;};struct O{"
                stringByAppendingFormat:
                    @"%@%@}; fragment O cf(constant V &v [[buffer(0)]]){O o;%@%@return o;}",
                    color ? [NSString stringWithFormat:@"%@ color [[color(0)]];", clearType(color)] : @"", depth ? @"float depth [[depth(any)]];" : @"",
                    color ? [NSString stringWithFormat:@"o.color=%@(v.color);", clearType(color)] : @"", depth ? @"o.depth=v.depth;" : @""];
            NSError *error = nil;
            id<MTLLibrary> lib = shaderLibrary(d, source, &error);
            if (!lib) {
                failBackend(e, error.localizedDescription);
                return nil;
            }
            MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
            p.vertexFunction = [lib newFunctionWithName:@"cv"];
            p.fragmentFunction = [lib newFunctionWithName:@"cf"];
            p.colorAttachments[0].pixelFormat = color;
            p.depthAttachmentPixelFormat = depth;
            if (depth == MTLPixelFormatDepth32Float_Stencil8 ||
                depth == MTLPixelFormatDepth24Unorm_Stencil8)
                p.stencilAttachmentPixelFormat = depth;
            pipeline = [CuprumBackendPipeline new];
            pipeline.pso = [d.device newRenderPipelineStateWithDescriptor:p error:&error];
            if (!pipeline.pso) {
                failBackend(e, error.localizedDescription);
                return nil;
            }
            MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
            ds.depthCompareFunction = MTLCompareFunctionAlways;
            ds.depthWriteEnabled = depth != 0;
            pipeline.depth = [d.device newDepthStencilStateWithDescriptor:ds];
            d.clearPipelines[key] = pipeline;

    return pipeline;
}

JNIEXPORT jint JNICALL JNI_METHOD(mslVersion)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        if (!CuprumGet(e, h, @"backend", 0, NO)) return 0;
        return CuprumLanguageVersion() == MTLLanguageVersion2_3 ? 20300 : 20400;
    }
}
JNIEXPORT jintArray JNICALL JNI_METHOD(depthFormats)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e, h, @"backend", 0, NO);
        if (!d) return NULL;
        jint formats[] = {-1, 51, 52, 54, 53};
        int count = d.device.isDepth24Stencil8PixelFormatSupported ? 5 : 4;
        jintArray result = (*e)->NewIntArray(e, count);
        if (result) (*e)->SetIntArrayRegion(e, result, 0, count, formats);
        return result;
    }
}
JNIEXPORT jobjectArray JNICALL JNI_METHOD(debugMessages)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e, h, @"backend", 0, NO);
        if (!d || !CuprumThread(e, h)) return NULL;
        @synchronized(d.messages) {
            jclass cls = (*e)->FindClass(e, "java/lang/String");
            if (!cls) return NULL;
            jobjectArray result = (*e)->NewObjectArray(e, (jsize)d.messages.count, cls, NULL);
            if (!result) return NULL;
            for (NSUInteger i=0; i<d.messages.count; i++) {
                jstring message = (*e)->NewStringUTF(e, d.messages[i].UTF8String);
                if (!message) return NULL;
                (*e)->SetObjectArrayElement(e, result, (jsize)i, message);
                (*e)->DeleteLocalRef(e, message);
            }
            [d.messages removeAllObjects];
            return result;
        }
    }
}
JNIEXPORT jdoubleArray JNICALL JNI_METHOD(metrics)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e, h, @"backend", 0, NO);
        if (!d || !CuprumThread(e, h)) return NULL;
        @synchronized(d.messages) {
            jdouble values[] = {(double)d.submissions, d.gpuMilliseconds, d.completionInterval};
            jdoubleArray result = (*e)->NewDoubleArray(e, 3);
            if (result) (*e)->SetDoubleArrayRegion(e, result, 0, 3, values);
            return result;
        }
    }
}

JNIEXPORT jlongArray JNICALL JNI_METHOD(cacheStats)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e,h,@"backend",0,NO);
        if (!d) return NULL;
        @synchronized(d) {
            jlong values[] = {(jlong)d.libraries.count, (jlong)d.pipelineStates.count, (jlong)d.clearPipelines.count};
            jlongArray result = (*e)->NewLongArray(e,3);
            if (result) (*e)->SetLongArrayRegion(e,result,0,3,values);
            return result;
        }
    }
}
JNIEXPORT void JNICALL JNI_METHOD(discardDrawable)(JNIEnv *e, jclass t, jlong h) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e,h,@"backend",0,NO);
        if (!d || !CuprumThread(e,h)) return;
        endBlit(d);
        finishRender(d);
        d.command = nil;
        d.drawable = nil;
        d.drawableScheduled = NO;
    }
}
JNIEXPORT void JNICALL JNI_METHOD(generateMipmaps)(JNIEnv *e, jclass t, jlong h, jlong texture) {
    (void)t;
    @autoreleasepool {
        CuprumBackendContext *d = CuprumGet(e,h,@"backend",0,NO);
        id<MTLTexture> tex = CuprumGet(e,texture,@"texture",h,NO);
        if (!d || !tex || !CuprumThread(e,h)) return;
        REQUIRE(!d.render, @"Cannot generate mipmaps inside a render pass.", );
        if (tex.mipmapLevelCount <= 1) return;
        // Metal's mip generator needs a filterable color format.
        switch (tex.pixelFormat) {
            case MTLPixelFormatR8Unorm: case MTLPixelFormatRG8Unorm: case MTLPixelFormatRGBA8Unorm:
            case MTLPixelFormatR16Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA16Float:
            case MTLPixelFormatR32Float: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA32Float: break;
            default: failBackend(e,@"Mip generation requires a supported filterable color format."); return;
        }
        [blit(e, d) generateMipmapsForTexture:tex];
    }
}
