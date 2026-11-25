// Zig 側（core/src/）が export する関数。形を変えたら WREN_CORE_ABI_VERSION と Zig 側の wren_core_abi_version を一緒に上げる。
#ifndef WREN_CORE_H
#define WREN_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WREN_CORE_ABI_VERSION 2

typedef struct {
    uint16_t glyph;
    double advance;
    double bbox_x;
    double bbox_y;
    double bbox_w;
    double bbox_h;
    char font_name[64];
} WrenGlyphInfo;

uint32_t wren_core_abi_version(void);
size_t wren_core_greeting(uint8_t *buf, size_t cap);
uint64_t wren_core_fnv1a64(const uint8_t *data, size_t len);
ptrdiff_t wren_vt_plain_text(const uint8_t *input, size_t len, uint8_t *out, size_t cap);
bool wren_ct_glyph_info(const char *font_name, double size, uint32_t codepoint, WrenGlyphInfo *out);

#endif
