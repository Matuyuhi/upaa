const std = @import("std");
const c = @import("apple");

/// Sources/CWrenCore/wren_core.h の WrenGlyphInfo と同じ並び。
pub const GlyphInfo = extern struct {
    glyph: u16,
    advance: f64,
    bbox_x: f64,
    bbox_y: f64,
    bbox_w: f64,
    bbox_h: f64,
    /// 実際にグリフを持っていたフォントの PostScript 名。NUL 終端。
    font_name: [64]u8,
};

/// font_name のフォントで codepoint のグリフを引く。そのフォントに無い文字は CoreText のフォールバックで代わりのフォントを選ぶ。
export fn wren_ct_glyph_info(font_name: [*:0]const u8, size: f64, codepoint: u32, out: *GlyphInfo) bool {
    var units: [2]c.UniChar = undefined;
    const n = encodeUtf16(codepoint, &units) orelse return false;

    const name = c.CFStringCreateWithCString(null, font_name, c.kCFStringEncodingUTF8) orelse return false;
    defer c.CFRelease(name);
    const base = c.CTFontCreateWithName(name, size, null) orelse return false;
    defer c.CFRelease(base);
    const str = c.CFStringCreateWithCharacters(null, &units, @intCast(n)) orelse return false;
    defer c.CFRelease(str);
    const font = c.CTFontCreateForString(base, str, .{ .location = 0, .length = @intCast(n) }) orelse return false;
    defer c.CFRelease(font);

    var glyphs = [2]c.CGGlyph{ 0, 0 };
    if (!c.CTFontGetGlyphsForCharacters(font, &units, &glyphs, @intCast(n))) return false;

    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(font, c.kCTFontOrientationHorizontal, &glyphs, &advance, 1);
    var rect: c.CGRect = undefined;
    _ = c.CTFontGetBoundingRectsForGlyphs(font, c.kCTFontOrientationHorizontal, &glyphs, &rect, 1);

    out.* = .{
        .glyph = glyphs[0],
        .advance = advance.width,
        .bbox_x = rect.origin.x,
        .bbox_y = rect.origin.y,
        .bbox_w = rect.size.width,
        .bbox_h = rect.size.height,
        .font_name = std.mem.zeroes([64]u8),
    };
    const ps = c.CTFontCopyPostScriptName(font) orelse return false;
    defer c.CFRelease(ps);
    _ = c.CFStringGetCString(ps, &out.font_name, out.font_name.len, c.kCFStringEncodingUTF8);
    return true;
}

fn encodeUtf16(cp: u32, out: *[2]c.UniChar) ?usize {
    if (cp >= 0xD800 and cp <= 0xDFFF) return null;
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp > 0x10FFFF) return null;
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

fn fontName(info: *const GlyphInfo) []const u8 {
    return std.mem.sliceTo(&info.font_name, 0);
}

test "latin glyph from Menlo" {
    var info: GlyphInfo = undefined;
    try std.testing.expect(wren_ct_glyph_info("Menlo", 14, 'A', &info));
    try std.testing.expect(info.glyph != 0);
    try std.testing.expect(info.advance > 0);
    try std.testing.expectEqualStrings("Menlo-Regular", fontName(&info));
}

test "japanese glyph falls back to another font" {
    var info: GlyphInfo = undefined;
    try std.testing.expect(wren_ct_glyph_info("Menlo", 14, 0x3042, &info));
    try std.testing.expect(info.glyph != 0);
    try std.testing.expect(!std.mem.eql(u8, "Menlo-Regular", fontName(&info)));
}

test "surrogate pair" {
    var units: [2]c.UniChar = undefined;
    try std.testing.expectEqual(@as(?usize, 2), encodeUtf16(0x1F426, &units));
    try std.testing.expectEqual(@as(c.UniChar, 0xD83D), units[0]);
    try std.testing.expectEqual(@as(c.UniChar, 0xDC26), units[1]);
}
