// SPDX-License-Identifier: LGPL-3.0-only
#import "cuprum_handles.h"
#include <stdlib.h>
#include <string.h>

@interface CuprumHandle : NSObject
@property(strong) id object;
@property(strong) NSString *kind;
@property(strong) NSThread *thread;
@property jlong owner;
@property NSUInteger references;
@end
@implementation CuprumHandle
@end

static NSMutableDictionary<NSNumber *, CuprumHandle *> *handles(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMutableDictionary new]; });
    return table;
}
static NSMutableDictionary<NSArray *, NSNumber *> *identities(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMutableDictionary new]; });
    return table;
}
static NSArray *identity(id object, jlong owner, NSString *kind) {
    return @[[NSValue valueWithNonretainedObject:object], @(owner), kind];
}
void CuprumError(JNIEnv *env, NSString *message) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (type) (*env)->ThrowNew(env, type, message.UTF8String);
}
jlong CuprumKeep(id object, jlong owner, NSString *kind) {
    if (!object) return 0;
    @synchronized(handles()) {
        static jlong next = 1;
        NSArray *key = identity(object, owner, kind);
        NSNumber *existing = identities()[key];
        if (existing) {
            handles()[existing].references++;
            return existing.longLongValue;
        }
        CuprumHandle *entry = [CuprumHandle new];
        entry.object = object;
        entry.owner = owner;
        entry.kind = kind;
        entry.thread = NSThread.currentThread;
        entry.references = 1;
        jlong token = next++;
        handles()[@(token)] = entry;
        identities()[key] = @(token);
        return token;
    }
}
id CuprumGet(JNIEnv *env, jlong token, NSString *kind, jlong owner, BOOL optional) {
    if (!token && optional) return nil;
    @synchronized(handles()) {
        CuprumHandle *entry = handles()[@(token)];
        if (!entry || (kind && ![entry.kind isEqualToString:kind]) ||
            (owner && entry.owner != owner) || (entry.owner && !handles()[@(entry.owner)])) {
            CuprumError(env, [NSString stringWithFormat:@"Invalid, closed, mistyped or foreign Metal %@ handle: %lld", kind ?: @"object", (long long)token]);
            return nil;
        }
        return entry.object;
    }
}
jlong CuprumOwner(JNIEnv *env, jlong token) {
    @synchronized(handles()) {
        if (!CuprumGet(env, token, nil, 0, NO)) return 0;
        return handles()[@(token)].owner;
    }
}
BOOL CuprumThread(JNIEnv *env, jlong token) {
    @synchronized(handles()) {
        CuprumHandle *entry = handles()[@(token)];
        if (!entry || entry.thread != NSThread.currentThread) {
            CuprumError(env, @"Metal command/resource operation must run on its owning thread.");
            return NO;
        }
        return YES;
    }
}
void CuprumRelease(JNIEnv *env, jlong token) {
    if (!token) return;
    @synchronized(handles()) {
        CuprumHandle *entry = handles()[@(token)];
        if (!entry) { CuprumError(env, @"Metal handle was already released or never allocated."); return; }
        if (--entry.references == 0) {
            [identities() removeObjectForKey:identity(entry.object, entry.owner, entry.kind)];
            [handles() removeObjectForKey:@(token)];
        }
    }
}
jlong CuprumRetain(JNIEnv *env, jlong token) {
    if (!token) return 0;
    @synchronized(handles()) {
        if (!CuprumGet(env, token, nil, 0, NO)) return 0;
        handles()[@(token)].references++;
        return token;
    }
}
MTLLanguageVersion CuprumLanguageVersion(void) {
    const char *override = getenv("CUPRUM_MSL_VERSION");
    if (override && strcmp(override, "20300") == 0) return MTLLanguageVersion2_3;
    if (@available(macOS 12.0, *)) return MTLLanguageVersion2_4;
    return MTLLanguageVersion2_3;
}
