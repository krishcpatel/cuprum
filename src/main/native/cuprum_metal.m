// SPDX-License-Identifier: LGPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <jni.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>

// ARC owns native resources; JNI handles are explicit +1 retained Objective-C references.
@interface CuprumMetalContext : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLSamplerState> sampler;
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic, strong) id<CAMetalDrawable> drawable;
@property(nonatomic, strong) id<MTLCommandBuffer> command;
@property(nonatomic, strong) id<MTLRenderCommandEncoder> encoder;
@property(nonatomic, strong) dispatch_semaphore_t permits;
@end
@implementation CuprumMetalContext
@end

static void fail(JNIEnv *env, const char *type, NSString *message) {
    if ((*env)->ExceptionCheck(env))
        return;
    jclass exception = (*env)->FindClass(env, type);
    if (exception)
        (*env)->ThrowNew(env, exception, message.UTF8String);
}
static void stateError(JNIEnv *env, NSString *message) {
    fail(env, "java/lang/IllegalStateException", message);
}
static void argumentError(JNIEnv *env, NSString *message) {
    fail(env, "java/lang/IllegalArgumentException", message);
}
static BOOL onMainThread(JNIEnv *env) {
    if ([NSThread isMainThread])
        return YES;
    stateError(env, @"Metal surface operations require the Cocoa main thread.");
    return NO;
}
static CuprumMetalContext *context(JNIEnv *env, jlong handle) {
    if (!onMainThread(env))
        return nil;
    if (!handle) {
        stateError(env, @"Metal renderer is closed.");
        return nil;
    }
    return (__bridge CuprumMetalContext *)(void *)(intptr_t)handle;
}
static jlong retainHandle(id object) { return (jlong)(intptr_t)(__bridge_retained void *)object; }
static const void *directBytes(JNIEnv *env, jobject buffer, jlong *size) {
    if (!buffer) {
        argumentError(env, @"Direct buffer data is required.");
        return NULL;
    }
    void *bytes = (*env)->GetDirectBufferAddress(env, buffer);
    *size = (*env)->GetDirectBufferCapacity(env, buffer);
    if (!bytes || *size <= 0) {
        argumentError(env, @"Expected a non-empty direct ByteBuffer slice.");
        return NULL;
    }
    return bytes;
}

JNIEXPORT jlong JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_createRenderer(JNIEnv *env,
                                                                                      jclass type,
                                                                                      jlong layerHandle,
                                                                                      jstring source) {
    (void)type;
    @autoreleasepool {
        if (!onMainThread(env))
            return 0;
        if (!layerHandle || !source) {
            argumentError(env, @"A Metal layer and MSL source are required.");
            return 0;
        }
        CuprumMetalContext *ctx = [CuprumMetalContext new];
        ctx.permits = dispatch_semaphore_create(3);
        ctx.device = MTLCreateSystemDefaultDevice();
        if (!ctx.device) {
            stateError(env, @"No Metal device is available.");
            return 0;
        }
        ctx.layer = (__bridge CAMetalLayer *)(void *)(intptr_t)layerHandle;
        ctx.layer.device = ctx.device;
        ctx.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ctx.layer.framebufferOnly = NO; // Allow the diagnostic GPU readback/blit path.
        ctx.layer.opaque = YES;
        ctx.layer.maximumDrawableCount = 3;
        ctx.layer.displaySyncEnabled = YES;
        ctx.layer.allowsNextDrawableTimeout = YES;
        ctx.queue = [ctx.device newCommandQueue];
        ctx.queue.label = @"Cuprum direct Metal queue";
        if (!ctx.queue) {
            stateError(env, @"Cannot create a Metal command queue.");
            return 0;
        }
        const char *utf8 = (*env)->GetStringUTFChars(env, source, NULL);
        if (!utf8)
            return 0;
        NSString *msl = [NSString stringWithUTF8String:utf8];
        (*env)->ReleaseStringUTFChars(env, source, utf8);
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_4;
        NSError *error = nil;
        id<MTLLibrary> library = [ctx.device newLibraryWithSource:msl options:options error:&error];
        if (!library) {
            stateError(env, [@"MSL compilation failed: "
                                stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
            return 0;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.label = @"Cuprum position_color_tex";
        descriptor.vertexFunction = [library newFunctionWithName:@"cuprum_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"cuprum_fragment"];
        if (!descriptor.vertexFunction || !descriptor.fragmentFunction) {
            stateError(env, @"The MSL library must export cuprum_vertex and cuprum_fragment.");
            return 0;
        }
        descriptor.colorAttachments[0].pixelFormat = ctx.layer.pixelFormat;
        MTLVertexDescriptor *vertices = [MTLVertexDescriptor vertexDescriptor];
        vertices.attributes[0].format = MTLVertexFormatFloat3;
        vertices.attributes[0].offset = 0;
        vertices.attributes[0].bufferIndex = 0;
        vertices.attributes[1].format = MTLVertexFormatUChar4Normalized;
        vertices.attributes[1].offset = 12;
        vertices.attributes[1].bufferIndex = 0;
        vertices.attributes[2].format = MTLVertexFormatFloat2;
        vertices.attributes[2].offset = 16;
        vertices.attributes[2].bufferIndex = 0;
        vertices.layouts[0].stride = 24;
        vertices.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        descriptor.vertexDescriptor = vertices;
        ctx.pipeline = [ctx.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!ctx.pipeline) {
            stateError(env, [@"Metal pipeline creation failed: "
                                stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
            return 0;
        }
        MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
        sampler.minFilter = MTLSamplerMinMagFilterNearest;
        sampler.magFilter = MTLSamplerMinMagFilterNearest;
        sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
        ctx.sampler = [ctx.device newSamplerStateWithDescriptor:sampler];
        if (!ctx.sampler) {
            stateError(env, @"Cannot create a Metal sampler.");
            return 0;
        }
        return retainHandle(ctx);
    }
}

JNIEXPORT jlong JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_createBuffer(JNIEnv *env, jclass type,
                                                                                    jlong handle,
                                                                                    jobject bytes) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return 0;
        jlong size;
        const void *data = directBytes(env, bytes, &size);
        if (!data)
            return 0;
        id<MTLBuffer> buffer = [ctx.device newBufferWithBytes:data
                                                       length:(NSUInteger)size
                                                      options:MTLResourceStorageModeShared];
        if (!buffer) {
            stateError(env, @"Cannot allocate a shared Metal buffer.");
            return 0;
        }
        return retainHandle(buffer);
    }
}

JNIEXPORT jlong JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_createTexture(JNIEnv *env, jclass type,
                                                                                     jlong handle, jint width,
                                                                                     jint height,
                                                                                     jobject bytes) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return 0;
        jlong size;
        const void *data = directBytes(env, bytes, &size);
        if (!data)
            return 0;
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
            size != (int64_t)width * height * 4) {
            argumentError(
                env, @"Texture data must contain exactly width * height RGBA8 pixels within device limits.");
            return 0;
        }
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:(NSUInteger)width
                                                              height:(NSUInteger)height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [ctx.device newTextureWithDescriptor:descriptor];
        if (!texture) {
            stateError(env, @"Cannot allocate a Metal texture.");
            return 0;
        }
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0
                     withBytes:data
                   bytesPerRow:(NSUInteger)width * 4];
        return retainHandle(texture);
    }
}

JNIEXPORT jboolean JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_beginFrame(
    JNIEnv *env, jclass type, jlong handle, jint width, jint height, jdouble red, jdouble green, jdouble blue,
    jdouble alpha) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return JNI_FALSE;
        if (ctx.command) {
            stateError(env, @"A Metal frame is already recording.");
            return JNI_FALSE;
        }
        if (width <= 0 || height <= 0)
            return JNI_FALSE;
        ctx.layer.drawableSize = CGSizeMake(width, height);
        ctx.drawable = [ctx.layer nextDrawable];
        if (!ctx.drawable)
            return JNI_FALSE; // Iconified/unavailable surface: skip without submitting.
        ctx.command = [ctx.queue commandBuffer];
        if (!ctx.command) {
            ctx.drawable = nil;
            stateError(env, @"Cannot allocate a Metal command buffer.");
            return JNI_FALSE;
        }
        ctx.command.label = @"Cuprum frame";
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = ctx.drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(red, green, blue, alpha);
        ctx.encoder = [ctx.command renderCommandEncoderWithDescriptor:pass];
        if (!ctx.encoder) {
            ctx.command = nil;
            ctx.drawable = nil;
            stateError(env, @"Cannot begin a Metal render encoder.");
            return JNI_FALSE;
        }
        [ctx.encoder setRenderPipelineState:ctx.pipeline];
        [ctx.encoder setCullMode:MTLCullModeNone];
        [ctx.encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        return JNI_TRUE;
    }
}

JNIEXPORT void JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_draw(JNIEnv *env, jclass type,
                                                                           jlong handle, jlong vertices,
                                                                           jlong uniforms, jlong texture,
                                                                           jint vertexCount) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return;
        if (!ctx.encoder) {
            stateError(env, @"No Metal frame is recording.");
            return;
        }
        if (!vertices || !uniforms || !texture || vertexCount <= 0) {
            argumentError(env, @"Draw resources and a positive vertex count are required.");
            return;
        }
        id<MTLBuffer> vertexBuffer = (__bridge id<MTLBuffer>)(void *)(intptr_t)vertices;
        id<MTLBuffer> uniformBuffer = (__bridge id<MTLBuffer>)(void *)(intptr_t)uniforms;
        id<MTLTexture> colorTexture = (__bridge id<MTLTexture>)(void *)(intptr_t)texture;
        if (vertexBuffer.device != ctx.device || uniformBuffer.device != ctx.device ||
            colorTexture.device != ctx.device || vertexBuffer.length < (uint64_t)vertexCount * 24 ||
            uniformBuffer.length != 80) {
            argumentError(
                env,
                @"Draw resources must belong to this device and match the pipeline's vertex/UBO layout.");
            return;
        }
        [ctx.encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
        [ctx.encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
        [ctx.encoder setFragmentTexture:colorTexture atIndex:0];
        [ctx.encoder setFragmentSamplerState:ctx.sampler atIndex:0];
        [ctx.encoder drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0
                        vertexCount:(NSUInteger)vertexCount];
    }
}

JNIEXPORT jbyteArray JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_finishFrame(
    JNIEnv *env, jclass type, jlong handle, jboolean wait, jboolean readback) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return NULL;
        if (!ctx.encoder) {
            stateError(env, @"No Metal frame is recording.");
            return NULL;
        }
        [ctx.encoder endEncoding];
        ctx.encoder = nil;
        NSUInteger width = ctx.drawable.texture.width, height = ctx.drawable.texture.height;
        NSUInteger rowBytes = (width * 4 + 255) & ~(NSUInteger)255;
        id<MTLBuffer> pixels = nil;
        if (readback) {
            if (width > INT_MAX / 4 || height > INT_MAX / (width * 4)) {
                ctx.command = nil;
                ctx.drawable = nil;
                stateError(env, @"Readback image is too large for Java.");
                return NULL;
            }
            pixels = [ctx.device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = [ctx.command blitCommandEncoder];
            if (!pixels || !blit) {
                if (blit)
                    [blit endEncoding];
                ctx.command = nil;
                ctx.drawable = nil;
                stateError(env, @"Cannot allocate Metal readback resources.");
                return NULL;
            }
            [blit copyFromTexture:ctx.drawable.texture
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(width, height, 1)
                                toBuffer:pixels
                       destinationOffset:0
                  destinationBytesPerRow:rowBytes
                destinationBytesPerImage:rowBytes * height];
            [blit endEncoding];
        }
        id<MTLCommandBuffer> command = ctx.command;
        [command presentDrawable:ctx.drawable];
        // Bound submissions even when a drawable is released before GPU completion.
        // Capture the semaphore, not the context, so shutdown cannot form a retain cycle.
        dispatch_semaphore_wait(ctx.permits, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_t permits = ctx.permits;
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
          if (completed.status == MTLCommandBufferStatusError)
              NSLog(@"Cuprum Metal submission failed: %@", completed.error);
          dispatch_semaphore_signal(permits);
        }];
        [command commit];
        ctx.command = nil;
        ctx.drawable = nil;
        if (wait || readback) {
            [command waitUntilCompleted];
            if (command.status == MTLCommandBufferStatusError) {
                stateError(
                    env, [@"Metal submission failed: "
                             stringByAppendingString:command.error.localizedDescription ?: @"unknown error"]);
                return NULL;
            }
        }
        if (!readback)
            return NULL;
        jbyteArray result = (*env)->NewByteArray(env, (jsize)(width * height * 4));
        if (!result)
            return NULL;
        const jbyte *data = pixels.contents;
        for (NSUInteger row = 0; row < height; row++) {
            (*env)->SetByteArrayRegion(env, result, (jsize)(row * width * 4), (jsize)(width * 4),
                                       data + row * rowBytes);
            if ((*env)->ExceptionCheck(env))
                return NULL;
        }
        return result; // Tightly packed BGRA8 pixels, top row first.
    }
}

JNIEXPORT void JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_abortFrame(JNIEnv *env, jclass type,
                                                                                 jlong handle) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return;
        if (ctx.encoder)
            [ctx.encoder endEncoding];
        ctx.encoder = nil;
        ctx.command = nil;
        ctx.drawable = nil;
    }
}
JNIEXPORT void JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_releaseResource(JNIEnv *env,
                                                                                      jclass type,
                                                                                      jlong resource) {
    (void)type;
    if (!onMainThread(env))
        return;
    if (resource)
        CFRelease((CFTypeRef)(void *)(intptr_t)resource);
}
JNIEXPORT void JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_destroyRenderer(JNIEnv *env,
                                                                                      jclass type,
                                                                                      jlong handle) {
    (void)type;
    @autoreleasepool {
        CuprumMetalContext *ctx = context(env, handle);
        if (!ctx)
            return;
        if (ctx.encoder)
            [ctx.encoder endEncoding];
        ctx.encoder = nil;
        ctx.command = nil;
        ctx.drawable = nil;
        // A final command on the serial queue drains every previously submitted frame.
        id<MTLCommandBuffer> drain = [ctx.queue commandBuffer];
        [drain commit];
        [drain waitUntilCompleted];
        ctx.layer.device = nil;
        CFRelease((CFTypeRef)(void *)(intptr_t)handle);
    }
}

JNIEXPORT jobjectArray JNICALL Java_com_krishcpatel_cuprum_bridge_MetalNative_loadedImagePaths(JNIEnv *env,
                                                                                               jclass type) {
    (void)type;
    uint32_t count = _dyld_image_count();
    jclass stringClass = (*env)->FindClass(env, "java/lang/String");
    if (!stringClass)
        return NULL;
    jobjectArray result = (*env)->NewObjectArray(env, (jsize)count, stringClass, NULL);
    if (!result)
        return NULL;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        jstring path = (*env)->NewStringUTF(env, name ? name : "");
        if (!path)
            return NULL;
        (*env)->SetObjectArrayElement(env, result, (jsize)i, path);
        (*env)->DeleteLocalRef(env, path);
        if ((*env)->ExceptionCheck(env))
            return NULL;
    }
    return result;
}
