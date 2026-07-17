/*
 * mayhem/fuzz_open.c — libFuzzer harness for OpenSlide.
 *
 * Ported (additively) from the fork's original test/fuzz_open.c. Drives the
 * whole-slide-image open path: openslide_detect_vendor + openslide_open, and,
 * when a slide opens cleanly, exercises the metadata / associated-image /
 * region-read code paths that make up the bulk of the parsers Mayhem targets.
 *
 * OpenSlide only accepts a filesystem path (no in-memory API), so the fuzz
 * input is written to a temp file under a writable tmpfs and opened from there.
 * Fixes over the original harness: level0 dimensions use int64_t (the API
 * writes 8-byte values — the original passed `int*`, a stack overwrite), and
 * we always free/close everything so the harness itself is leak-clean.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include "openslide.h"

static char *buf_to_file(const uint8_t *buf, size_t size) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || dir[0] == '\0') {
        dir = "/tmp";
    }
    char tmpl[4096];
    snprintf(tmpl, sizeof(tmpl), "%s/openslide-fuzz-XXXXXX", dir);

    int fd = mkstemp(tmpl);
    if (fd == -1) {
        return NULL;
    }

    size_t pos = 0;
    while (pos < size) {
        ssize_t n = write(fd, buf + pos, size - pos);
        if (n <= 0) {
            if (n == -1 && errno == EINTR) {
                continue;
            }
            close(fd);
            unlink(tmpl);
            return NULL;
        }
        pos += (size_t)n;
    }
    if (close(fd) == -1) {
        unlink(tmpl);
        return NULL;
    }
    return strdup(tmpl);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    char *filename = buf_to_file(data, size);
    if (filename == NULL) {
        return 0;
    }

    /* Vendor detection is a distinct, cheap-to-reach code path. */
    const char *vendor = openslide_detect_vendor(filename);
    (void)vendor;

    openslide_t *slide = openslide_open(filename);
    if (slide != NULL) {
        if (openslide_get_error(slide) == NULL) {
            int32_t levels = openslide_get_level_count(slide);

            int64_t w = 0, h = 0;
            openslide_get_level0_dimensions(slide, &w, &h);

            /* Walk level metadata. */
            for (int32_t i = 0; i < levels; i++) {
                int64_t lw = 0, lh = 0;
                openslide_get_level_dimensions(slide, i, &lw, &lh);
                openslide_get_level_downsample(slide, i);
            }

            /* Properties. */
            const char *const *pnames = openslide_get_property_names(slide);
            for (int i = 0; pnames != NULL && pnames[i] != NULL; i++) {
                openslide_get_property_value(slide, pnames[i]);
            }

            /* Associated images. */
            const char *const *anames =
                openslide_get_associated_image_names(slide);
            for (int i = 0; anames != NULL && anames[i] != NULL; i++) {
                int64_t aw = 0, ah = 0;
                openslide_get_associated_image_dimensions(slide, anames[i],
                                                           &aw, &ah);
            }

            /* Read a small top-left region to drive the tile decoders. */
            if (w > 0 && h > 0) {
                int64_t rw = w < 64 ? w : 64;
                int64_t rh = h < 64 ? h : 64;
                uint32_t *dest =
                    (uint32_t *)malloc((size_t)rw * (size_t)rh * 4);
                if (dest != NULL) {
                    openslide_read_region(slide, dest, 0, 0, 0, rw, rh);
                    free(dest);
                }
            }
        }
        openslide_close(slide);
    }

    unlink(filename);
    free(filename);
    return 0;
}
