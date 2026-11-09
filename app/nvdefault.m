// libnvdefault.dylib: makes the NVIDIA card an app's default Metal device, like Optimus on Windows: the app draws
// on the NVIDIA card and the Intel GPU that drives the panel shows the result. macOS otherwise gives every app the
// GPU of the main display (the Intel iGPU on this laptop).
//
// KBColor loads it in two ways (DYLD_INSERT_LIBRARIES):
// - "NVIDIA ile aç" opens one app with NVDEFAULT_FORCE=1, so it is on for that app.
// - Automatic mode sets the variable for every app launchd starts and lists the chosen bundle IDs in NVDEFAULT_APPS
//   (separated by ':'). Then it is loaded into every app, but does nothing unless the app is on the list.
// An app it is on for passes NVDEFAULT_FORCE=1 to the processes it starts, so a game started from a launcher gets
// the NVIDIA card too. With no NVIDIA Metal device it changes nothing.
#import <Metal/Metal.h>
#include <stdlib.h>
#include <string.h>

#define INTERPOSE(_new, _old) __attribute__((used)) static struct { const void *n; const void *o; } interpose_##_old \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_new, (const void *)(unsigned long)&_old };

static int gOn;

static int listed(const char *list)
{
    CFBundleRef b = CFBundleGetMainBundle();
    CFStringRef bid = b ? CFBundleGetIdentifier(b) : NULL;
    char me[256];
    if (!bid || !CFStringGetCString(bid, me, sizeof me, kCFStringEncodingUTF8)) return 0;
    char *dup = strdup(list), *save = NULL;
    int hit = 0;
    for (char *t = dup ? strtok_r(dup, ":", &save) : NULL; t && !hit; t = strtok_r(NULL, ":", &save)) hit = !strcmp(t, me);
    free(dup);
    return hit;
}

__attribute__((constructor)) static void nvdef_init(void)
{
    const char *force = getenv("NVDEFAULT_FORCE"), *list = getenv("NVDEFAULT_APPS");
    gOn = (force && !strcmp(force, "1")) || (list && *list && listed(list));
    if (gOn) setenv("NVDEFAULT_FORCE", "1", 1);
}

static BOOL isNvidia(id<MTLDevice> d) { return strcasestr(d.name.UTF8String ?: "", "NVIDIA") != NULL; }

// Both return +1 like the Metal functions they replace (Create/Copy rule). Calls made from this library are not
// interposed, so these reach Metal itself.
static NSArray<id<MTLDevice>> *nvdef_copy_all(void) NS_RETURNS_RETAINED
{
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    if (!gOn) return all;
    NSUInteger i = [all indexOfObjectPassingTest:^BOOL(id<MTLDevice> d, NSUInteger idx, BOOL *stop) { return isNvidia(d); }];
    if (i == NSNotFound || i == 0) return all;
    NSMutableArray *m = [all mutableCopy];
    id<MTLDevice> nv = m[i];
    [m removeObjectAtIndex:i];
    [m insertObject:nv atIndex:0];
    return m;
}

static id<MTLDevice> nvdef_default(void) NS_RETURNS_RETAINED
{
    if (gOn)
        for (id<MTLDevice> d in MTLCopyAllDevices())
            if (isNvidia(d)) return d;
    return MTLCreateSystemDefaultDevice();
}

INTERPOSE(nvdef_copy_all, MTLCopyAllDevices)
INTERPOSE(nvdef_default, MTLCreateSystemDefaultDevice)
