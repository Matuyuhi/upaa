// Zig 側（core/src/root.zig）が export する関数。形を変えたら WREN_CORE_ABI_VERSION と Zig 側の wren_core_abi_version を一緒に上げる。
#ifndef WREN_CORE_H
#define WREN_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WREN_CORE_ABI_VERSION 5

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
// キーを 1 回押した（離した）こと。
typedef struct {
    // macOS の仮想キーコード（NSEvent.keyCode）。
    uint16_t key_code;
    // WREN_KEY_RELEASE / PRESS / REPEAT
    uint8_t action;
    // WREN_MOD_* を足し合わせたもの。
    uint8_t mods;
    // 修飾キーなしで同じキーを押したときの文字。分からなければ 0。
    uint32_t unshifted_codepoint;
    // このキーで入力される文字（UTF-8）。無ければ NULL。
    const uint8_t *text;
    size_t text_len;
} WrenKeyEvent;

enum { WREN_KEY_RELEASE = 0, WREN_KEY_PRESS = 1, WREN_KEY_REPEAT = 2 };
enum { WREN_MOD_SHIFT = 1 << 0, WREN_MOD_CTRL = 1 << 1, WREN_MOD_ALT = 1 << 2, WREN_MOD_SUPER = 1 << 3 };

// キー入力を、端末の今のモードに合わせたバイト列にしてシェルへ送る。
void wren_session_key(WrenSession *session, const WrenKeyEvent *event);
void wren_session_resize(WrenSession *session, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
bool wren_session_take_dirty(WrenSession *session);
// 画面のプレーンテキスト。戻り値は本来の長さで、cap より長い分は切り捨てる。失敗したら -1。
ptrdiff_t wren_session_plain_text(WrenSession *session, uint8_t *out, size_t cap);

// 描画（フォント、グリフのアトラス、セルのデータの組み立て）

typedef struct WrenRenderer WrenRenderer;

typedef struct {
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t baseline;
} WrenMetrics;

// Metal に渡す 1 セル分のデータ。Shaders/terminal.metal の Cell と同じ並び（24 バイト）。
typedef struct {
    uint16_t col;
    uint16_t row;
    // アトラス内のグリフの位置と大きさ。大きさ 0 は描くものが無い。
    uint16_t glyph_x;
    uint16_t glyph_y;
    uint16_t glyph_width;
    uint16_t glyph_height;
    // セルの左上から、グリフの画像の左上まで。
    int16_t glyph_offset_x;
    int16_t glyph_offset_y;
    uint8_t fg[4];
    uint8_t bg[4];
} WrenCell;

typedef struct {
    uint32_t cell_count;
    uint16_t cols;
    uint16_t rows;
    uint8_t background[4];
    // アトラスの画像が変わるたびに増える。前回と違えばテクスチャを更新する。
    uint64_t atlas_generation;
} WrenFrame;

// font_size_px は拡大率（Retina なら 2）を掛けたあとのピクセル数。失敗したら NULL。
WrenRenderer *wren_renderer_new(const char *font_name, double font_size_px);
void wren_renderer_free(WrenRenderer *renderer);
WrenMetrics wren_renderer_metrics(WrenRenderer *renderer);
// アトラスの画像。1 ピクセル 1 バイトで、一辺は wren_renderer_atlas_size ピクセル。
const uint8_t *wren_renderer_atlas_pixels(WrenRenderer *renderer);
uint32_t wren_renderer_atlas_size(void);
// session の今の画面を cells に書く。cells は Metal のバッファの中身を直接指してよい。
WrenFrame wren_renderer_frame(WrenRenderer *renderer, WrenSession *session, WrenCell *cells, size_t cap);

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
