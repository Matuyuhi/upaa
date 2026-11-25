//! グリフを 1 枚の 8 ビット画像（濃度だけ）に詰めて覚えておく。Swift 側がこの画像を Metal のテクスチャにする。
const Atlas = @This();

const std = @import("std");
const c = @import("apple");
const Face = @import("Face.zig");

const alloc = std.heap.c_allocator;

pub const size = 2048;

/// size x size。行は上から下の順。
pixels: []u8,
glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty,
/// 次に置く位置（棚に左から並べ、いっぱいになったら次の棚へ）。
cursor_x: u32 = 1,
cursor_y: u32 = 1,
shelf_height: u32 = 0,
/// 画像が変わるたびに増える。Swift 側はこれを見てテクスチャを更新する。
generation: u64 = 1,

pub const Glyph = extern struct {
    /// アトラス内の位置と大きさ。大きさ 0 は描くものが無い（空白など）。
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    /// セルの左上から、グリフの画像の左上まで。
    offset_x: i16 = 0,
    offset_y: i16 = 0,
};

pub fn init() error{OutOfMemory}!Atlas {
    const pixels = try alloc.alloc(u8, size * size);
    @memset(pixels, 0);
    return .{ .pixels = pixels };
}

pub fn deinit(atlas: *Atlas) void {
    atlas.glyphs.deinit(alloc);
    alloc.free(atlas.pixels);
}

/// 初めての文字はここで描く。描けない文字やアトラスが満杯のときは、空のグリフを返す。
pub fn get(atlas: *Atlas, face: Face, codepoint: u21) Glyph {
    if (atlas.glyphs.get(codepoint)) |glyph| return glyph;
    const glyph = atlas.rasterize(face, codepoint) orelse Glyph{};
    atlas.glyphs.put(alloc, codepoint, glyph) catch {};
    return glyph;
}

fn rasterize(atlas: *Atlas, face: Face, codepoint: u21) ?Glyph {
    const resolved = face.resolve(codepoint) orelse return null;
    defer c.CFRelease(resolved.font);

    var glyphs = [_]c.CGGlyph{resolved.glyph};
    var rect: c.CGRect = undefined;
    _ = c.CTFontGetBoundingRectsForGlyphs(resolved.font, c.kCTFontOrientationHorizontal, &glyphs, &rect, 1);
    if (rect.size.width <= 0 or rect.size.height <= 0) return Glyph{};

    // ベースライン原点・上向きの座標で、グリフを囲むピクセルの範囲。アンチエイリアスのにじみ分を 1 ずつ広げる。
    const x0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.x))) - 1;
    const y0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.y))) - 1;
    const x1: i32 = @as(i32, @intFromFloat(@ceil(rect.origin.x + rect.size.width))) + 1;
    const y1: i32 = @as(i32, @intFromFloat(@ceil(rect.origin.y + rect.size.height))) + 1;
    const width: u32 = @intCast(x1 - x0);
    const height: u32 = @intCast(y1 - y0);

    const pos = atlas.reserve(width, height) orelse return null;

    // アトラスの該当部分をそのまま描画先にする。
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
    var point = c.CGPoint{ .x = @floatFromInt(-x0), .y = @floatFromInt(-y0) };
    c.CTFontDrawGlyphs(resolved.font, &glyphs, &point, 1, ctx);

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

/// 隣のグリフがにじんで見えないよう、1 ピクセルずつ間を空けて場所を取る。
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

    const a = atlas.get(face, 'A');
    try std.testing.expect(a.width > 0 and a.height > 0);
    try std.testing.expect(atlas.inkSum(a) > 0);
    const generation = atlas.generation;
    try std.testing.expectEqual(a, atlas.get(face, 'A'));
    try std.testing.expectEqual(generation, atlas.generation);

    const kana = atlas.get(face, 0x3042);
    try std.testing.expect(atlas.inkSum(kana) > 0);
    // 全角は 1 セルより広い。
    try std.testing.expect(kana.width > face.metrics.cell_width);

    try std.testing.expectEqual(@as(u16, 0), atlas.get(face, ' ').width);
}
