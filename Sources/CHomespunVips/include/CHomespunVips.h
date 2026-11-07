// SPDX-License-Identifier: Apache-2.0
// A small C interface to libvips for Swift. libvips' own API is variadic, which Swift
// cannot call. Strings returned through `error` and blobs through `data` are allocated
// with malloc; release them with hs_vips_free.
#ifndef CHOMESPUNVIPS_H
#define CHOMESPUNVIPS_H

#include <stddef.h>

/// Starts libvips once per process. Returns 0 on success.
int hs_vips_init(char **error);

/// Decodes `input`, applies its orientation, shrinks it to fit `max_edge` (never enlarging),
/// flattens transparency onto white, and writes a progressive, optimised JPEG at `quality`.
/// Keeps the ICC profile and IPTC; EXIF and XMP are left for the caller to write.
/// Fails on truncated input. Reports the upright source size and the output size.
int hs_vips_compact_jpeg(const char *input, const char *output, int max_edge, int quality,
                         int *source_width, int *source_height, int *width, int *height,
                         char **error);

/// Copies the raw EXIF ("Exif\0\0" + TIFF) and XMP blobs from `input`'s header.
/// A missing blob is returned as NULL with length 0.
int hs_vips_metadata(const char *input, unsigned char **exif, size_t *exif_length,
                     unsigned char **xmp, size_t *xmp_length, char **error);

/// Decodes every pixel of `input`, failing on truncation or decode errors.
int hs_vips_decode(const char *input, int *width, int *height, char **error);

void hs_vips_free(void *pointer);

/// The libvips version, or NULL if libvips is unavailable.
const char *hs_vips_version(void);

#endif
