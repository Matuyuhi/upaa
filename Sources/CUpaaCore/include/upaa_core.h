// Zig 側（core/src/root.zig）が export する関数。形を変えたら UPAA_CORE_ABI_VERSION と Zig 側の upaa_core_abi_version を一緒に上げる。
#ifndef UPAA_CORE_H
#define UPAA_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define UPAA_CORE_ABI_VERSION 8

uint32_t upaa_core_abi_version(void);

// upaa 自身のバージョン（"0.1.0" の形）。値は build.zig.zon の .version から来る。
const char *upaa_version(void);
// candidate（"v0.2.0" や "0.2.0" の形）が今のバージョンより新しければ true。読めない形なら false。
bool upaa_version_is_newer(const char *candidate);

// 端末セッション（PTY、シェル、libghostty-vt の端末をまとめたもの）

typedef struct UpaaSession UpaaSession;

// どちらも Zig の読み取りスレッドから呼ばれる。
typedef struct {
    void *userdata;
    // 画面が変わった。upaa_session_take_dirty を呼ぶまで次は来ない。
    void (*on_wakeup)(void *userdata);
    // 子プロセスが終了した。
    void (*on_exit)(void *userdata);
} UpaaSessionCallbacks;

// command が NULL ならログインシェルを、そうでなければ /bin/sh -c command を起動する。失敗したら NULL。
// show_intro が true なら、シェルの出力を出す前に、起動時の顔（文字で組んだウーパールーパー）を画面に描く。
UpaaSession *upaa_session_new(uint16_t cols, uint16_t rows, const char *command, bool show_intro, const UpaaSessionCallbacks *callbacks);
// 起動時の顔の index 番目のコマ（エスケープシーケンス）を out に書き、長さを返す。見た目の確認用。
size_t upaa_intro_frame(uint16_t cols, uint16_t rows, size_t index, uint8_t *out, size_t cap);
size_t upaa_intro_frame_count(void);
void upaa_session_free(UpaaSession *session);
void upaa_session_write(UpaaSession *session, const uint8_t *data, size_t len);
// キーを 1 回押した（離した）こと。
typedef struct {
    // macOS の仮想キーコード（NSEvent.keyCode）。
    uint16_t key_code;
    // UPAA_KEY_RELEASE / PRESS / REPEAT
    uint8_t action;
    // UPAA_MOD_* を足し合わせたもの。
    uint8_t mods;
    // 修飾キーなしで同じキーを押したときの文字。分からなければ 0。
    uint32_t unshifted_codepoint;
    // このキーで入力される文字（UTF-8）。無ければ NULL。
    const uint8_t *text;
    size_t text_len;
} UpaaKeyEvent;

enum { UPAA_KEY_RELEASE = 0, UPAA_KEY_PRESS = 1, UPAA_KEY_REPEAT = 2 };
enum { UPAA_MOD_SHIFT = 1 << 0, UPAA_MOD_CTRL = 1 << 1, UPAA_MOD_ALT = 1 << 2, UPAA_MOD_SUPER = 1 << 3 };

// キー入力を、端末の今のモードに合わせたバイト列にしてシェルへ送る。
void upaa_session_key(UpaaSession *session, const UpaaKeyEvent *event);
void upaa_session_resize(UpaaSession *session, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
// 起動時の顔の下と、顔が消えたあとの 1 行目に出すお知らせ。顔を流し終えたあとに呼んでも何も起きない。
void upaa_session_set_intro_note(UpaaSession *session, const char *text);
bool upaa_session_take_dirty(UpaaSession *session);
// 画面のプレーンテキスト。戻り値は本来の長さで、cap より長い分は切り捨てる。失敗したら -1。
ptrdiff_t upaa_session_plain_text(UpaaSession *session, uint8_t *out, size_t cap);

// 描画（フォント、グリフのアトラス、セルのデータの組み立て）

typedef struct UpaaRenderer UpaaRenderer;

typedef struct {
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t baseline;
} UpaaMetrics;

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
} UpaaCell;

typedef struct {
    uint32_t cell_count;
    uint16_t cols;
    uint16_t rows;
    uint8_t background[4];
    // アトラスの画像が変わるたびに増える。前回と違えばテクスチャを更新する。
    uint64_t atlas_generation;
} UpaaFrame;

// font_size_px は拡大率（Retina なら 2）を掛けたあとのピクセル数。失敗したら NULL。
UpaaRenderer *upaa_renderer_new(const char *font_name, double font_size_px);
void upaa_renderer_free(UpaaRenderer *renderer);
UpaaMetrics upaa_renderer_metrics(UpaaRenderer *renderer);
// アトラスの画像。1 ピクセル 1 バイトで、一辺は upaa_renderer_atlas_size ピクセル。
const uint8_t *upaa_renderer_atlas_pixels(UpaaRenderer *renderer);
uint32_t upaa_renderer_atlas_size(void);
// session の今の画面を cells に書く。cells は Metal のバッファの中身を直接指してよい。
UpaaFrame upaa_renderer_frame(UpaaRenderer *renderer, UpaaSession *session, UpaaCell *cells, size_t cap);

// リンクの確認（--check）

typedef struct {
    uint16_t glyph;
    double advance;
    double bbox_x;
    double bbox_y;
    double bbox_w;
    double bbox_h;
    char font_name[64];
} UpaaGlyphInfo;

size_t upaa_selftest_greeting(uint8_t *buf, size_t cap);
uint64_t upaa_selftest_fnv1a64(const uint8_t *data, size_t len);
ptrdiff_t upaa_selftest_vt_plain_text(const uint8_t *input, size_t len, uint8_t *out, size_t cap);
bool upaa_selftest_glyph_info(const char *font_name, double size, uint32_t codepoint, UpaaGlyphInfo *out);

#endif
