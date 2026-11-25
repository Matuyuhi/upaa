// Zig 側（core/src/root.zig）が export する関数。形を変えたら WREN_CORE_ABI_VERSION と Zig 側の wren_core_abi_version を一緒に上げる。
#ifndef WREN_CORE_H
#define WREN_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WREN_CORE_ABI_VERSION 3

uint32_t wren_core_abi_version(void);

// 端末セッション（PTY、シェル、libghostty-vt の端末をまとめたもの）

typedef struct WrenSession WrenSession;

// どちらも Zig の読み取りスレッドから呼ばれる。
typedef struct {
    void *userdata;
    // 画面が変わった。wren_session_take_dirty を呼ぶまで次は来ない。
    void (*on_wakeup)(void *userdata);
    // 子プロセスが終了した。
    void (*on_exit)(void *userdata);
} WrenSessionCallbacks;

// ログインシェルを起動する。失敗したら NULL。
WrenSession *wren_session_new(uint16_t cols, uint16_t rows, const WrenSessionCallbacks *callbacks);
void wren_session_free(WrenSession *session);
void wren_session_write(WrenSession *session, const uint8_t *data, size_t len);
void wren_session_resize(WrenSession *session, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
bool wren_session_take_dirty(WrenSession *session);
// 画面のプレーンテキスト。戻り値は本来の長さで、cap より長い分は切り捨てる。失敗したら -1。
ptrdiff_t wren_session_plain_text(WrenSession *session, uint8_t *out, size_t cap);

// リンクの確認（--check）

typedef struct {
    uint16_t glyph;
    double advance;
    double bbox_x;
    double bbox_y;
    double bbox_w;
    double bbox_h;
    char font_name[64];
} WrenGlyphInfo;

size_t wren_selftest_greeting(uint8_t *buf, size_t cap);
uint64_t wren_selftest_fnv1a64(const uint8_t *data, size_t len);
ptrdiff_t wren_selftest_vt_plain_text(const uint8_t *input, size_t len, uint8_t *out, size_t cap);
bool wren_selftest_glyph_info(const char *font_name, double size, uint32_t codepoint, WrenGlyphInfo *out);

#endif
