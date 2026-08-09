/* Dump what the display is actually showing, for the black-screen post-mortem.
 *
 * Two things can make every pixel black while the machine is perfectly healthy,
 * and the unified log records neither: a window covering the screen, and a
 * gamma ramp that maps everything to zero. WindowServer composites normally in
 * both cases -- which is exactly what its stack showed during the outage -- so
 * the answer has to be read from CoreGraphics rather than inferred from logs.
 *
 * Needs no root. Window titles would need Screen Recording consent, so they are
 * not asked for; owner, bounds, layer and alpha are enough to see a cover.
 *
 * cc -O2 -o screen-state screen-state.c -framework ApplicationServices
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void dump_gamma(void)
{
    CGDirectDisplayID displays[8];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(8, displays, &count) != kCGErrorSuccess) {
        printf("gamma: could not list displays\n");
        return;
    }

    for (uint32_t d = 0; d < count; d++) {
        uint32_t cap = CGDisplayGammaTableCapacity(displays[d]);
        if (!cap) continue;

        CGGammaValue *r = calloc(cap, sizeof(CGGammaValue));
        CGGammaValue *g = calloc(cap, sizeof(CGGammaValue));
        CGGammaValue *b = calloc(cap, sizeof(CGGammaValue));
        uint32_t n = 0;

        if (CGGetDisplayTransferByTable(displays[d], cap, r, g, b, &n) == kCGErrorSuccess && n) {
            /* An identity ramp ends at 1.0. A ramp whose top entry is at or near
             * zero is a black screen with everything behind it still drawing. */
            printf("display %u gamma: %u entries, last r=%.3f g=%.3f b=%.3f, mid r=%.3f\n",
                   displays[d], n, r[n - 1], g[n - 1], b[n - 1], r[n / 2]);
            if (r[n - 1] < 0.01f && g[n - 1] < 0.01f && b[n - 1] < 0.01f)
                printf("  *** GAMMA IS BLACK -- the ramp maps everything to zero ***\n");
        } else {
            printf("display %u gamma: unreadable\n", displays[d]);
        }
        free(r); free(g); free(b);
    }
}

static void dump_windows(void)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                 kCGNullWindowID);
    if (!list) { printf("windows: unreadable\n"); return; }

    CFIndex n = CFArrayGetCount(list);
    printf("on-screen windows: %ld\n", (long)n);
    printf("  %-6s %-8s %-24s %-28s %s\n", "layer", "pid", "owner", "bounds", "alpha");

    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        long layer = 0, pid = 0;
        double alpha = 1.0;
        char owner[64] = "?";
        CGRect bounds = CGRectZero;

        CFNumberRef num;
        if ((num = CFDictionaryGetValue(w, kCGWindowLayer)))
            CFNumberGetValue(num, kCFNumberLongType, &layer);
        if ((num = CFDictionaryGetValue(w, kCGWindowOwnerPID)))
            CFNumberGetValue(num, kCFNumberLongType, &pid);
        if ((num = CFDictionaryGetValue(w, kCGWindowAlpha)))
            CFNumberGetValue(num, kCFNumberDoubleType, &alpha);

        CFStringRef name = CFDictionaryGetValue(w, kCGWindowOwnerName);
        if (name) CFStringGetCString(name, owner, sizeof(owner), kCFStringEncodingUTF8);

        CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
        if (b) CGRectMakeWithDictionaryRepresentation(b, &bounds);

        char rect[32];
        snprintf(rect, sizeof(rect), "%.0fx%.0f @ %.0f,%.0f",
                 bounds.size.width, bounds.size.height, bounds.origin.x, bounds.origin.y);

        printf("  %-6ld %-8ld %-24s %-28s %.2f\n", layer, pid, owner, rect, alpha);
    }
    CFRelease(list);
}

int main(int argc, char **argv)
{
    /* Restoring is the same subject as reporting, so it lives here rather than
     * in a second binary that could drift from it. Note it only takes effect
     * from inside the window session -- run under `launchctl asuser` when
     * coming in over ssh, or CoreGraphics silently addresses nothing. */
    if (argc > 1 && strcmp(argv[1], "--restore") == 0) {
        CGDisplayRestoreColorSyncSettings();
        printf("gamma: restored from the ColorSync profile\n");
        return 0;
    }

    dump_gamma();
    printf("\n");
    dump_windows();
    return 0;
}
