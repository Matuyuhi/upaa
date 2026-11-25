//! libghostty-vt の描画用の状態をなめて、セルのデータを組み立てる。
const Frame = @This();

const std = @import("std");
const vt = @import("ghostty");
const Atlas = @import("../font/Atlas.zig");
const Face = @import("../font/Face.zig");
const Cell = @import("Cell.zig").Cell;

row_iter: vt.GhosttyRenderStateRowIterator,
row_cells: vt.GhosttyRenderStateRowCells,

pub const Info = extern struct {
    /// 書き込んだセルの数。
    cell_count: u32 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    background: [4]u8 = .{ 0, 0, 0, 255 },
    atlas_generation: u64 = 0,
};

pub fn init() error{OutOfMemory}!Frame {
    var row_iter: vt.GhosttyRenderStateRowIterator = null;
    if (vt.ghostty_render_state_row_iterator_new(null, &row_iter) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_render_state_row_iterator_free(row_iter);
    var row_cells: vt.GhosttyRenderStateRowCells = null;
    if (vt.ghostty_render_state_row_cells_new(null, &row_cells) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    return .{ .row_iter = row_iter, .row_cells = row_cells };
}

pub fn deinit(frame: Frame) void {
    vt.ghostty_render_state_row_cells_free(frame.row_cells);
    vt.ghostty_render_state_row_iterator_free(frame.row_iter);
}

/// state は更新済み（ghostty_render_state_update か begin/end_update のあと）であること。
/// 画面の全セルを out に書く。out が足りなければ入る分だけ書く。
pub fn build(frame: *Frame, state: vt.GhosttyRenderState, face: Face, atlas: *Atlas, out: []Cell) Info {
    var info: Info = .{};
    _ = vt.ghostty_render_state_get(state, vt.GHOSTTY_RENDER_STATE_DATA_COLS, &info.cols);
    _ = vt.ghostty_render_state_get(state, vt.GHOSTTY_RENDER_STATE_DATA_ROWS, &info.rows);

    var colors: vt.GhosttyRenderStateColors = std.mem.zeroes(vt.GhosttyRenderStateColors);
    colors.size = @sizeOf(vt.GhosttyRenderStateColors);
    _ = vt.ghostty_render_state_get(state, vt.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    const default_fg = rgba(colors.foreground);
    const default_bg = rgba(colors.background);
    info.background = default_bg;

    var cursor: vt.GhosttyRenderStateCursor = std.mem.zeroes(vt.GhosttyRenderStateCursor);
    cursor.size = @sizeOf(vt.GhosttyRenderStateCursor);
    _ = vt.ghostty_render_state_get(state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
    const cursor_shown = cursor.visible and cursor.viewport_has_value;

    if (vt.ghostty_render_state_get(state, vt.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&frame.row_iter)) != vt.GHOSTTY_SUCCESS)
        return info;

    var n: usize = 0;
    var row: u16 = 0;
    while (vt.ghostty_render_state_row_iterator_next(frame.row_iter)) : (row += 1) {
        if (vt.ghostty_render_state_row_get(frame.row_iter, vt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&frame.row_cells)) != vt.GHOSTTY_SUCCESS)
            continue;

        var col: u16 = 0;
        while (vt.ghostty_render_state_row_cells_next(frame.row_cells)) : (col += 1) {
            if (n == out.len) break;
            var cell = frame.readCell(face, atlas, default_fg, default_bg);
            cell.col = col;
            cell.row = row;
            // ブロック形のカーソルとして、前景と背景を入れ替える。形の描き分けはまだしていない。
            if (cursor_shown and cursor.viewport_x == col and cursor.viewport_y == row) {
                cell.bg = default_fg;
                cell.fg = default_bg;
            }
            out[n] = cell;
            n += 1;
        }
    }

    info.cell_count = @intCast(n);
    info.atlas_generation = atlas.generation;
    return info;
}

fn readCell(frame: *Frame, face: Face, atlas: *Atlas, default_fg: [4]u8, default_bg: [4]u8) Cell {
    const cells = frame.row_cells;

    var fg = default_fg;
    var bg = default_bg;
    var color: vt.GhosttyColorRgb = undefined;
    if (vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == vt.GHOSTTY_SUCCESS)
        fg = rgba(color);
    if (vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == vt.GHOSTTY_SUCCESS)
        bg = rgba(color);

    var has_styling = false;
    _ = vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has_styling);
    if (has_styling) {
        var style: vt.GhosttyStyle = undefined;
        if (vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == vt.GHOSTTY_SUCCESS) {
            if (style.flags & vt.GHOSTTY_STYLE_FLAG_INVERSE != 0) std.mem.swap([4]u8, &fg, &bg);
            if (style.flags & vt.GHOSTTY_STYLE_FLAG_INVISIBLE != 0) fg = bg;
        }
    }

    // 結合文字（濁点の合成や絵文字の連結）はまだ描かない。先頭の 1 文字だけを使う。
    var codepoint: u32 = 0;
    var graphemes: vt.GhosttyCodepointBuffer = .{ .ptr = &codepoint, .cap = 1, .len = 0 };
    _ = vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes);
    const glyph: Atlas.Glyph = if (graphemes.len > 0 and codepoint <= 0x10FFFF)
        atlas.get(face, @intCast(codepoint))
    else
        .{};

    return .{ .col = 0, .row = 0, .glyph = glyph, .fg = fg, .bg = bg };
}

fn rgba(color: vt.GhosttyColorRgb) [4]u8 {
    return .{ color.r, color.g, color.b, 255 };
}

test "cells carry glyphs, colors and the cursor" {
    var terminal: vt.GhosttyTerminal = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_new(null, &terminal, 10, 3));
    defer vt.ghostty_terminal_free(terminal);
    const input = "A\x1b[31mB\x1b[0m\x1b[7mC\x1b[0mあ";
    vt.ghostty_terminal_vt_write(terminal, input.ptr, input.len);

    var state: vt.GhosttyRenderState = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_render_state_new(null, &state));
    defer vt.ghostty_render_state_free(state);
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_render_state_update(state, terminal));

    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    var atlas = try Atlas.init();
    defer atlas.deinit();
    var frame = try Frame.init();
    defer frame.deinit();

    var cells: [64]Cell = undefined;
    const info = frame.build(state, face, &atlas, &cells);
    try std.testing.expectEqual(@as(u32, 30), info.cell_count);
    try std.testing.expectEqual(@as(u16, 10), info.cols);

    const a = cells[0];
    const b = cells[1];
    const inverse = cells[2];
    const kana = cells[3];
    const kana_tail = cells[4];
    const cursor = cells[5];
    const empty = cells[6];

    try std.testing.expect(a.glyph.width > 0);
    try std.testing.expect(!std.mem.eql(u8, &a.fg, &b.fg));
    try std.testing.expectEqual(a.fg, inverse.bg);
    try std.testing.expectEqual(a.bg, inverse.fg);
    try std.testing.expect(kana.glyph.width > face.metrics.cell_width);
    // 全角の右半分のセルには何も描かない。
    try std.testing.expectEqual(@as(u16, 0), kana_tail.glyph.width);
    try std.testing.expectEqual(a.fg, cursor.bg);
    try std.testing.expectEqual(@as(u16, 0), empty.glyph.width);
    try std.testing.expectEqual(a.bg, empty.bg);
    try std.testing.expectEqual(@as(u16, 1), cells[10].row);
}
