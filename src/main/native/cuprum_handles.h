// SPDX-License-Identifier: LGPL-3.0-only
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <jni.h>

// Monotonic opaque IDs, never object addresses. Lookups take a strong ARC reference.
jlong CuprumKeep(id object, jlong owner, NSString *kind);
id CuprumGet(JNIEnv *env, jlong token, NSString *kind, jlong owner, BOOL optional);
jlong CuprumOwner(JNIEnv *env, jlong token);
BOOL CuprumThread(JNIEnv *env, jlong token);
void CuprumRelease(JNIEnv *env, jlong token);
jlong CuprumRetain(JNIEnv *env, jlong token);
void CuprumError(JNIEnv *env, NSString *message);
MTLLanguageVersion CuprumLanguageVersion(void);
