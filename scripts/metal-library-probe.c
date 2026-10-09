// SPDX-License-Identifier: LGPL-3.0-only
// Inspect loader mappings without creating windows or submitting graphics commands.
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
static void audit(const char *stage) {
    unsigned found = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *path = _dyld_get_image_name(i);
        if (strstr(path, "/OpenGL.framework/")) { printf("%s: %s\n", stage, path); ++found; }
    }
    printf("%s: %u OpenGL.framework images\n", stage, found);
}
int main(int argc, char **argv) {
    audit("before explicit loading");
    if (argc > 1) {
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        audit("after dlopen");
        void *(*create_device)(void) = (void *(*)(void)) dlsym(library, "MTLCreateSystemDefaultDevice");
        if (create_device) { printf("MTLDevice: %p\n", create_device()); audit("after Metal device creation"); }
    }
    return 0;
}
