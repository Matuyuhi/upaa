//! Walks libghostty-vt's render state and builds the cell data.
const Frame = @This();

const std = @import("std");
const vt = @import("ghostty");
const Atlas = @import("../font/Atlas.zig");
const Face = @import("../font/Face.zig");
const Cell = @import("Cell.zig").Cell;

row_iter: vt.GhosttyRenderStateRowIterator,
row_cells: vt.GhosttyRenderStateRowCells,

pub const Info = extern struct {
    /// Number of cells written.
    cell_count: u32 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    background: [4]u8 = .{ 0, 0, 0, 255 },
    atlas_generation: u64 = 0,
    /// The cell with the cursor. Used as the position for the candidate window. Meaningless when cursor_visible is false.
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_visible: bool = false,
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

/// state must already be updated (after ghostty_render_state_update, or after begin/end_update).
/// Writes all cells of the screen to out. If out is too small, writes as many as fit.
/// preedit is the IME composing string (UTF-8). If not empty, it is overlaid with an underline starting at the cursor position.
pub fn build(frame: *Frame, state: vt.GhosttyRenderState, face: Face, atlas: *Atlas, preedit: []const u8, out: []Cell) Info {
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
    if (cursor_shown) {
        info.cursor_visible = true;
        info.cursor_col = cursor.viewport_x;
        info.cursor_row = cursor.viewport_y;
    }

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
            // Swap foreground and background to draw a block cursor. Distinguishing cursor shapes is not implemented yet.
            // While composing, the cursor is drawn after the composing string, so it is not drawn here.
            if (preedit.len == 0 and cursor_shown and cursor.viewport_x == col and cursor.viewport_y == row) {
                cell.bg = default_fg;
                cell.fg = default_bg;
            }
            out[n] = cell;
            n += 1;
        }
    }

    // A cell's row and column are determined only when all cells were written.
    if (preedit.len > 0 and cursor_shown and n == @as(usize, info.cols) * info.rows) {
        const line = out[@as(usize, cursor.viewport_y) * info.cols ..][0..info.cols];
        overlayPreedit(line, cursor.viewport_x, preedit, face, atlas, default_fg, default_bg);
    }

    info.cell_count = @intCast(n);
    info.atlas_generation = atlas.generation;
    return info;
}

/// Overlays the composing string on the line from column start, with an underline. Clipped at the end of the line (no wrapping).
fn overlayPreedit(line: []Cell, start: u16, preedit: []const u8, face: Face, atlas: *Atlas, fg: [4]u8, bg: [4]u8) void {
    const view = std.unicode.Utf8View.init(preedit) catch return;
    var it = view.iterator();
    var col: usize = start;
    while (it.nextCodepoint()) |codepoint| {
        const width: usize = vt.ghostty_unicode_codepoint_width(codepoint);
        // Zero-width combining characters cannot be drawn yet, so skip them.
        if (width == 0) continue;
        if (col + width > line.len) break;
        line[col].glyph = atlas.get(face, codepoint);
        for (line[col..][0..width], 0..) |*cell, i| {
            if (i > 0) cell.glyph = .{};
            cell.fg = fg;
            cell.bg = bg;
            cell.flags = Cell.Flags.underline;
        }
        col += width;
    }
    // The cursor sits right after the composing string.
    if (col < line.len) {
        line[col].bg = fg;
        line[col].fg = bg;
    }
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

    var flags: u32 = 0;
    var has_styling = false;
    _ = vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has_styling);
    if (has_styling) {
        var style: vt.GhosttyStyle = undefined;
        if (vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == vt.GHOSTTY_SUCCESS) {
            if (style.flags & vt.GHOSTTY_STYLE_FLAG_INVERSE != 0) std.mem.swap([4]u8, &fg, &bg);
            if (style.flags & vt.GHOSTTY_STYLE_FLAG_INVISIBLE != 0) fg = bg;
            // Double and wavy underlines are also drawn as a single underline for now.
            if ((style.flags >> vt.GHOSTTY_STYLE_UNDERLINE_SHIFT) & 0x7 != 0) flags |= Cell.Flags.underline;
        }
    }

    // Combining characters (dakuten composition, emoji joining) are not drawn yet. Only the first codepoint is used.
    var codepoint: u32 = 0;
    var graphemes: vt.GhosttyCodepointBuffer = .{ .ptr = &codepoint, .cap = 1, .len = 0 };
    _ = vt.ghostty_render_state_row_cells_get(cells, vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes);
    const glyph: Atlas.Glyph = if (graphemes.len > 0 and codepoint <= 0x10FFFF)
        atlas.get(face, @intCast(codepoint))
    else
        .{};

    return .{ .col = 0, .row = 0, .glyph = glyph, .fg = fg, .bg = bg, .flags = flags };
}

fn rgba(color: vt.GhosttyColorRgb) [4]u8 {
    return .{ color.r, color.g, color.b, 255 };
}

test "cells carry glyphs, colors and the cursor" {
    var terminal: vt.GhosttyTerminal = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_new(null, &terminal, 10, 3));
    defer vt.ghostty_terminal_free(terminal);
    const input = "A\x1b[31mB\x1b[0m\x1b[7mC\x1b[0mあ\r\n\x1b[4mU\x1b[0m";
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
    const info = frame.build(state, face, &atlas, "", &cells);
    try std.testing.expectEqual(@as(u32, 30), info.cell_count);
    try std.testing.expectEqual(@as(u16, 10), info.cols);

    const a = cells[0];
    const b = cells[1];
    const inverse = cells[2];
    const kana = cells[3];
    const kana_tail = cells[4];
    const empty = cells[6];
    const underlined = cells[10];
    const cursor = cells[11];

    try std.testing.expect(a.glyph.width > 0);
    try std.testing.expect(!std.mem.eql(u8, &a.fg, &b.fg));
    try std.testing.expectEqual(a.fg, inverse.bg);
    try std.testing.expectEqual(a.bg, inverse.fg);
    try std.testing.expect(kana.glyph.width > face.metrics.cell_width);
    // Nothing is drawn in the right half of a full-width character's cell.
    try std.testing.expectEqual(@as(u16, 0), kana_tail.glyph.width);
    try std.testing.expectEqual(a.fg, cursor.bg);
    try std.testing.expectEqual(@as(u16, 0), empty.glyph.width);
    try std.testing.expectEqual(a.bg, empty.bg);
    try std.testing.expectEqual(@as(u16, 1), cells[10].row);
    try std.testing.expectEqual(@as(u32, 0), a.flags);
    try std.testing.expectEqual(Cell.Flags.underline, underlined.flags);
    try std.testing.expect(info.cursor_visible);
    try std.testing.expectEqual(@as(u16, 1), info.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), info.cursor_row);

    // The composing string overlays from the cursor position (row 2, column 2) with an underline, and the cursor moves after it.
    const composing = frame.build(state, face, &atlas, "かa", &cells);
    try std.testing.expectEqual(@as(u32, 30), composing.cell_count);
    try std.testing.expect(cells[11].glyph.width > face.metrics.cell_width);
    try std.testing.expectEqual(Cell.Flags.underline, cells[11].flags);
    try std.testing.expectEqual(@as(u16, 0), cells[12].glyph.width);
    try std.testing.expectEqual(Cell.Flags.underline, cells[12].flags);
    try std.testing.expect(cells[13].glyph.width > 0);
    try std.testing.expectEqual(a.fg, cells[14].bg);
    try std.testing.expectEqual(@as(u32, 0), cells[14].flags);
    // The original cursor position is overwritten by the composing string (no block remains).
    try std.testing.expectEqual(a.bg, cells[11].bg);
}
