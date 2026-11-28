//! Keeps glyphs packed into one 8-bit image (density only). The Swift side turns this image into a Metal texture.
const Atlas = @This();

const std = @import("std");
const c = @import("apple");
const Face = @import("Face.zig");

const alloc = std.heap.c_allocator;

pub const size = 2048;

/// size x size. Rows run from top to bottom.
pixels: []u8,
/// Keyed by the cell's text (one grapheme cluster, UTF-8). The keys are owned by the atlas.
glyphs: std.StringHashMapUnmanaged(Glyph) = .empty,
/// Where the next glyph goes (placed left to right on a shelf; moves to the next shelf when full).
cursor_x: u32 = 1,
cursor_y: u32 = 1,
shelf_height: u32 = 0,
/// Increases each time the image changes. The Swift side watches this to update the texture.
generation: u64 = 1,

pub const Glyph = extern struct {
    /// Position and size in the atlas. Size 0 means nothing to draw (e.g. a blank).
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    /// From the top-left of the cell to the top-left of the glyph image.
    offset_x: i16 = 0,
    offset_y: i16 = 0,
};

pub fn init() error{OutOfMemory}!Atlas {
    const pixels = try alloc.alloc(u8, size * size);
    @memset(pixels, 0);
    return .{ .pixels = pixels };
}

pub fn deinit(atlas: *Atlas) void {
    atlas.clear();
    atlas.glyphs.deinit(alloc);
    alloc.free(atlas.pixels);
}

/// Forgets every glyph, for a new font.
pub fn clear(atlas: *Atlas) void {
    var keys = atlas.glyphs.keyIterator();
    while (keys.next()) |key| alloc.free(key.*);
    atlas.glyphs.clearRetainingCapacity();
    @memset(atlas.pixels, 0);
    atlas.cursor_x = 1;
    atlas.cursor_y = 1;
    atlas.shelf_height = 0;
    atlas.generation += 1;
}

/// text is one cell's grapheme cluster (UTF-8). New text is drawn here on first use.
/// Text that cannot be drawn, or anything after the atlas is full, gets an empty glyph.
pub fn get(atlas: *Atlas, face: Face, text: []const u8) Glyph {
    if (atlas.glyphs.get(text)) |glyph| return glyph;
    const glyph = (if (brailleBits(text)) |bits| atlas.drawBraille(face.metrics, bits) else atlas.rasterize(face, text)) orelse Glyph{};
    const key = alloc.dupe(u8, text) catch return glyph;
    atlas.glyphs.put(alloc, key, glyph) catch alloc.free(key);
    return glyph;
}

/// Draws text with a CTLine, so CoreText composes combining marks and picks a fallback font for characters the face lacks.
fn rasterize(atlas: *Atlas, face: Face, text: []const u8) ?Glyph {
    const str = c.CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), c.kCFStringEncodingUTF8, 0) orelse return null;
    defer c.CFRelease(str);
    var keys = [_]?*const anyopaque{c.kCTFontAttributeName};
    var values = [_]?*const anyopaque{face.font};
    const attrs = c.CFDictionaryCreate(null, &keys, &values, 1, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer c.CFRelease(attrs);
    const attributed = c.CFAttributedStringCreate(null, str, attrs) orelse return null;
    defer c.CFRelease(attributed);
    const line = c.CTLineCreateWithAttributedString(attributed) orelse return null;
    defer c.CFRelease(line);

    const rect = c.CTLineGetBoundsWithOptions(line, c.kCTLineBoundsUseGlyphPathBounds);
    if (rect.size.width <= 0 or rect.size.height <= 0) return Glyph{};

    // Pixel range enclosing the glyph, in baseline-origin upward coordinates. Expand by 1 on each side for the antialiasing bleed.
    const x0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.x))) - 1;
    const y0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.y))) - 1;
    const x1: i32 = @as(i32, @intFromFloat(@ceil(rect.origin.x + rect.size.width))) + 1;
    const y1: i32 = @as(i32, @intFromFloat(@ceil(rect.origin.y + rect.size.height))) + 1;
    const width: u32 = @intCast(x1 - x0);
    const height: u32 = @intCast(y1 - y0);

    const pos = atlas.reserve(width, height) orelse return null;

    // Use the corresponding part of the atlas directly as the drawing target.
    const ctx = c.CGBitmapContextCreate(
        atlas.pixels.ptr + pos.y * size + pos.x,
        width,
        height,
        8,
        size,
        null,
        c.kCGImageAlphaOnly,
    ) orelse return null;
    defer c.CGContextRelease(ctx);
    c.CGContextSetShouldAntialias(ctx, true);
    c.CGContextSetShouldSmoothFonts(ctx, false);
    c.CGContextSetTextPosition(ctx, @floatFromInt(-x0), @floatFromInt(-y0));
    c.CTLineDraw(line, ctx);

    atlas.generation += 1;
    return .{
        .x = @intCast(pos.x),
        .y = @intCast(pos.y),
        .width = @intCast(width),
        .height = @intCast(height),
        .offset_x = @intCast(x0),
        .offset_y = @intCast(@as(i32, @intCast(face.metrics.baseline)) - y1),
    };
}

/// Braille (U+2800 to U+28FF) is drawn here as square dots in a 2 x 4 grid filling the cell, not with a font:
/// fonts draw small dots with gaps between lines, so pictures made of braille fall apart into stripes.
fn drawBraille(atlas: *Atlas, metrics: Face.Metrics, bits: u8) ?Glyph {
    const w = metrics.cell_width;
    const h = metrics.cell_height;
    const pos = atlas.reserve(w, h) orelse return null;
    // Bit i of the codepoint is the dot at dots[i] (column, row).
    const dots = [8][2]u32{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 } };
    const side = @max(1, @min(w / 2, h / 4) * 5 / 9);
    for (dots, 0..) |dot, i| {
        if (bits & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const x = (2 * dot[0] + 1) * w / 4 - side / 2;
        const y = (2 * dot[1] + 1) * h / 8 - side / 2;
        for (0..side) |dy| @memset(atlas.pixels[(pos.y + y + dy) * size + pos.x + x ..][0..side], 255);
    }
    atlas.generation += 1;
    return .{ .x = @intCast(pos.x), .y = @intCast(pos.y), .width = @intCast(w), .height = @intCast(h) };
}

fn brailleBits(text: []const u8) ?u8 {
    if (text.len != 3 or text[0] != 0xE2 or text[1] & 0xFC != 0xA0) return null;
    return (text[1] & 0x03) << 6 | (text[2] & 0x3F);
}

/// Reserve 1 pixel between glyphs so that neighbors do not show through each other.
fn reserve(atlas: *Atlas, width: u32, height: u32) ?struct { x: u32, y: u32 } {
    if (width + 2 > size) return null;
    if (atlas.cursor_x + width + 1 > size) {
        atlas.cursor_x = 1;
        atlas.cursor_y += atlas.shelf_height + 1;
        atlas.shelf_height = 0;
    }
    if (atlas.cursor_y + height + 1 > size) return null;
    const pos = .{ .x = atlas.cursor_x, .y = atlas.cursor_y };
    atlas.cursor_x += width + 1;
    atlas.shelf_height = @max(atlas.shelf_height, height);
    return .{ .x = pos.x, .y = pos.y };
}

fn inkSum(atlas: Atlas, glyph: Glyph) u64 {
    var sum: u64 = 0;
    for (0..glyph.height) |dy| {
        const row = atlas.pixels[(glyph.y + dy) * size + glyph.x ..][0..glyph.width];
        for (row) |p| sum += p;
    }
    return sum;
}

test "glyphs are drawn once and cached" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    var atlas = try Atlas.init();
    defer atlas.deinit();

    const a = atlas.get(face, "A");
    try std.testing.expect(a.width > 0 and a.height > 0);
    try std.testing.expect(atlas.inkSum(a) > 0);
    const generation = atlas.generation;
    try std.testing.expectEqual(a, atlas.get(face, "A"));
    try std.testing.expectEqual(generation, atlas.generation);

    // Menlo has no kana, so this also checks the fallback font. Full-width characters are wider than one cell.
    const kana = atlas.get(face, "\u{3042}");
    try std.testing.expect(atlas.inkSum(kana) > 0);
    try std.testing.expect(kana.width > face.metrics.cell_width);

    // A decomposed dakuten (ka + U+3099, as in macOS file names) is drawn as one glyph with more ink than ka alone.
    const ka = atlas.get(face, "\u{304B}");
    const ga = atlas.get(face, "\u{304B}\u{3099}");
    try std.testing.expect(atlas.inkSum(ga) > atlas.inkSum(ka));
    try std.testing.expect(ga.width < 2 * face.metrics.cell_width + 4);

    try std.testing.expectEqual(@as(u16, 0), atlas.get(face, " ").width);
}

test "braille is drawn as dots that fill the cell" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    var atlas = try Atlas.init();
    defer atlas.deinit();

    const one = atlas.get(face, "\u{2801}");
    const all = atlas.get(face, "\u{28FF}");
    try std.testing.expectEqual(@as(u16, @intCast(face.metrics.cell_width)), all.width);
    try std.testing.expectEqual(@as(u16, @intCast(face.metrics.cell_height)), all.height);
    try std.testing.expect(atlas.inkSum(one) > 0);
    try std.testing.expectEqual(8 * atlas.inkSum(one), atlas.inkSum(all));
}
