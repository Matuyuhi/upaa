//! One cell's data passed to Metal. Same layout as Cell in Shaders/terminal.metal (28 bytes).
const Atlas = @import("../font/Atlas.zig");

pub const Cell = extern struct {
    col: u16,
    row: u16,
    glyph: Atlas.Glyph,
    fg: [4]u8,
    bg: [4]u8,
    /// The sum of the Flags values.
    flags: u32 = 0,

    pub const Flags = struct {
        /// Draws an underline in the foreground color below the cell.
        pub const underline: u32 = 1 << 0;
    };

    comptime {
        if (@sizeOf(Cell) != 28) @compileError("Cell must be 28 bytes. Keep in sync with Shaders/terminal.metal");
    }
};
