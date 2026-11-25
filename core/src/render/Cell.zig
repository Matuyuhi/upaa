//! Metal に渡す 1 セル分のデータ。Shaders/terminal.metal の Cell と同じ並び（24 バイト）。
const Atlas = @import("../font/Atlas.zig");

pub const Cell = extern struct {
    col: u16,
    row: u16,
    glyph: Atlas.Glyph,
    fg: [4]u8,
    bg: [4]u8,

    comptime {
        if (@sizeOf(Cell) != 24) @compileError("Cell は 24 バイト。Shaders/terminal.metal と揃える");
    }
};
