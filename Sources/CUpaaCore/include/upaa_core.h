// Functions exported by the Zig side (core/src/root.zig). Change both files together.
#ifndef UPAA_CORE_H
#define UPAA_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// upaa's own version (form "0.1.0"). The value comes from .version in build.zig.zon.
const char *upaa_version(void);
// true if candidate (form "v0.2.0" or "0.2.0") is newer than the current version. false if it cannot be parsed.
bool upaa_version_is_newer(const char *candidate);

// Terminal session (bundles the PTY, the shell, and the libghostty-vt terminal)

typedef struct UpaaSession UpaaSession;

// Both are called from the Zig read thread.
typedef struct {
    void *userdata;
    // The screen changed. The next call does not come until upaa_session_take_dirty is called.
    void (*on_wakeup)(void *userdata);
    // The child process exited.
    void (*on_exit)(void *userdata);
} UpaaSessionCallbacks;

// If command is NULL, starts the login shell; otherwise starts /bin/sh -c command. Returns NULL on failure.
// If show_intro is true, draws the startup face (an axolotl made of text characters) on screen before the shell's output.
UpaaSession *upaa_session_new(uint16_t cols, uint16_t rows, const char *command, bool show_intro, const UpaaSessionCallbacks *callbacks);
void upaa_session_free(UpaaSession *session);
void upaa_session_write(UpaaSession *session, const uint8_t *data, size_t len);
// A key was pressed once (and released).
typedef struct {
    // macOS virtual key code (NSEvent.keyCode).
    uint16_t key_code;
    // UPAA_KEY_RELEASE / PRESS / REPEAT
    uint8_t action;
    // UPAA_MOD_* values added together.
    uint8_t mods;
    // The character produced by the same key without modifiers. 0 if unknown.
    uint32_t unshifted_codepoint;
    // Characters this key inputs (UTF-8). NULL if none.
    const uint8_t *text;
    size_t text_len;
} UpaaKeyEvent;

enum { UPAA_KEY_RELEASE = 0, UPAA_KEY_PRESS = 1, UPAA_KEY_REPEAT = 2 };
enum { UPAA_MOD_SHIFT = 1 << 0, UPAA_MOD_CTRL = 1 << 1, UPAA_MOD_ALT = 1 << 2, UPAA_MOD_SUPER = 1 << 3 };

// Converts key input into a byte sequence matching the terminal's current mode and sends it to the shell.
void upaa_session_key(UpaaSession *session, const UpaaKeyEvent *event);
void upaa_session_resize(UpaaSession *session, uint16_t cols, uint16_t rows, uint32_t cell_width_px, uint32_t cell_height_px);
// Notice shown under the startup face and on line 1 after the face disappears. Calling it after the face has finished playing does nothing.
void upaa_session_set_intro_note(UpaaSession *session, const char *text);
bool upaa_session_take_dirty(UpaaSession *session);
// Plain text of the screen. The return value is the original length; anything beyond cap is truncated. -1 on failure.
ptrdiff_t upaa_session_plain_text(UpaaSession *session, uint8_t *out, size_t cap);

// Drawing (font, glyph atlas, cell data assembly)

typedef struct UpaaRenderer UpaaRenderer;

typedef struct {
    uint32_t cell_width;
    uint32_t cell_height;
    uint32_t baseline;
    // From the top edge of the cell to the top edge of the underline, and the underline thickness.
    uint32_t underline_offset;
    uint32_t underline_thickness;
} UpaaMetrics;

// Data for one cell passed to Metal. Same layout as Cell in Shaders/terminal.metal (28 bytes).
typedef struct {
    uint16_t col;
    uint16_t row;
    // Position and size of the glyph in the atlas. Size 0 means there is nothing to draw.
    uint16_t glyph_x;
    uint16_t glyph_y;
    uint16_t glyph_width;
    uint16_t glyph_height;
    // From the top-left of the cell to the top-left of the glyph image.
    int16_t glyph_offset_x;
    int16_t glyph_offset_y;
    uint8_t fg[4];
    uint8_t bg[4];
    // UPAA_CELL_* values added together.
    uint32_t flags;
} UpaaCell;

// Draws an underline in the foreground color below the cell.
enum { UPAA_CELL_UNDERLINE = 1 << 0 };

typedef struct {
    uint32_t cell_count;
    uint16_t cols;
    uint16_t rows;
    uint8_t background[4];
    // Incremented every time the atlas image changes. If it differs from last time, the texture is updated.
    uint64_t atlas_generation;
    // The cell with the cursor. Used as the position for the candidate window. Meaningless when cursor_visible is false.
    uint16_t cursor_col;
    uint16_t cursor_row;
    bool cursor_visible;
} UpaaFrame;

// font_size_px is the pixel count after multiplying by the scale factor (2 on Retina). NULL on failure.
UpaaRenderer *upaa_renderer_new(const char *font_name, double font_size_px);
void upaa_renderer_free(UpaaRenderer *renderer);
UpaaMetrics upaa_renderer_metrics(UpaaRenderer *renderer);
// Atlas image. 1 byte per pixel; each side is upaa_renderer_atlas_size pixels.
const uint8_t *upaa_renderer_atlas_pixels(UpaaRenderer *renderer);
uint32_t upaa_renderer_atlas_size(void);
// Writes the session's current screen into cells. cells may point directly at the contents of the Metal buffer.
// preedit is the text being composed with IME (UTF-8). NULL if none. Overlaid with an underline starting at the cursor position.
UpaaFrame upaa_renderer_frame(UpaaRenderer *renderer, UpaaSession *session, const uint8_t *preedit, size_t preedit_len, UpaaCell *cells, size_t cap);


#endif
