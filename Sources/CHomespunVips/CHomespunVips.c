// SPDX-License-Identifier: Apache-2.0
#include "CHomespunVips.h"
#include <stdlib.h>
#include <string.h>

#if __has_include(<vips/vips.h>)
#include <pthread.h>
#include <vips/vips.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int init_status = -1;

static void start(void) {
    init_status = VIPS_INIT("homespun") ? -1 : 0;
    if (init_status == 0) {
        // Files are replaced in place; never serve stale decoded copies.
        vips_cache_set_max(0);
    }
}

static int fail(char **error, const char *fallback) {
    const char *message = vips_error_buffer();
    if (error) *error = strdup(message && *message ? message : fallback);
    vips_error_clear();
    return -1;
}

int hs_vips_init(char **error) {
    pthread_once(&once, start);
    return init_status == 0 ? 0 : fail(error, "libvips did not start");
}

static int upright_size(const char *input, int *width, int *height, char **error) {
    VipsImage *header = vips_image_new_from_file(input, "access", VIPS_ACCESS_SEQUENTIAL, NULL);
    if (!header) return fail(error, "cannot read image header");
    int w = header->Xsize, h = header->Ysize;
    if (vips_image_get_orientation_swap(header)) { int t = w; w = h; h = t; }
    g_object_unref(header);
    *width = w;
    *height = h;
    return 0;
}

int hs_vips_compact_jpeg(const char *input, const char *output, int max_edge, int quality,
                         int *source_width, int *source_height, int *width, int *height,
                         char **error) {
    if (hs_vips_init(error)) return -1;
    if (upright_size(input, source_width, source_height, error)) return -1;

    VipsImage *image = NULL;
    if (vips_thumbnail(input, &image, max_edge, "height", max_edge, "size", VIPS_SIZE_DOWN,
                       "fail_on", VIPS_FAIL_ON_TRUNCATED, NULL))
        return fail(error, "cannot decode image");

    if (vips_image_hasalpha(image)) {
        int colours = image->Bands - 1;
        double white = vips_interpretation_max_alpha(image->Type);
        VipsArrayDouble *background = vips_array_double_new((double[]){white, white, white, white}, colours);
        VipsImage *flat = NULL;
        int status = vips_flatten(image, &flat, "background", background, NULL);
        vips_area_unref(VIPS_AREA(background));
        g_object_unref(image);
        if (status) return fail(error, "cannot flatten transparency");
        image = flat;
    }

    int status = vips_jpegsave(image, output, "Q", quality, "optimize_coding", TRUE, "interlace", TRUE,
                               "keep", VIPS_FOREIGN_KEEP_ICC | VIPS_FOREIGN_KEEP_IPTC, NULL);
    *width = image->Xsize;
    *height = image->Ysize;
    g_object_unref(image);
    return status ? fail(error, "cannot write JPEG") : 0;
}

static unsigned char *copy_blob(VipsImage *image, const char *name, size_t *length) {
    const void *data = NULL;
    size_t size = 0;
    *length = 0;
    if (!vips_image_get_typeof(image, name) || vips_image_get_blob(image, name, &data, &size) || size == 0)
        return NULL;
    unsigned char *copy = malloc(size);
    if (!copy) return NULL;
    memcpy(copy, data, size);
    *length = size;
    return copy;
}

int hs_vips_metadata(const char *input, unsigned char **exif, size_t *exif_length,
                     unsigned char **xmp, size_t *xmp_length, char **error) {
    if (hs_vips_init(error)) return -1;
    VipsImage *image = vips_image_new_from_file(input, "access", VIPS_ACCESS_SEQUENTIAL, NULL);
    if (!image) return fail(error, "cannot read image header");
    *exif = copy_blob(image, VIPS_META_EXIF_NAME, exif_length);
    *xmp = copy_blob(image, VIPS_META_XMP_NAME, xmp_length);
    g_object_unref(image);
    return 0;
}

int hs_vips_decode(const char *input, int *width, int *height, char **error) {
    if (hs_vips_init(error)) return -1;
    VipsImage *image = vips_image_new_from_file(input, "access", VIPS_ACCESS_SEQUENTIAL,
                                                "fail_on", VIPS_FAIL_ON_TRUNCATED, NULL);
    if (!image) return fail(error, "cannot read image");
    double average = 0;
    int status = vips_avg(image, &average, NULL);
    *width = image->Xsize;
    *height = image->Ysize;
    g_object_unref(image);
    return status ? fail(error, "image does not decode") : 0;
}

void hs_vips_free(void *pointer) { free(pointer); }

#else
// Built without libvips headers (for example on macOS, where ImageIO is used instead).
static int unavailable(char **error) {
    if (error) *error = strdup("libvips is not available on this platform");
    return -1;
}
int hs_vips_init(char **error) { return unavailable(error); }
int hs_vips_compact_jpeg(const char *input, const char *output, int max_edge, int quality,
                         int *source_width, int *source_height, int *width, int *height,
                         char **error) { return unavailable(error); }
int hs_vips_metadata(const char *input, unsigned char **exif, size_t *exif_length,
                     unsigned char **xmp, size_t *xmp_length, char **error) { return unavailable(error); }
int hs_vips_decode(const char *input, int *width, int *height, char **error) { return unavailable(error); }
void hs_vips_free(void *pointer) { free(pointer); }
#endif
