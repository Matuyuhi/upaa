//! 等幅フォント 1 つと、そこから決まるセルの寸法。
const Face = @This();

const std = @import("std");
const c = @import("apple");

font: c.CTFontRef,
metrics: Metrics,

pub const Metrics = extern struct {
    cell_width: u32,
    cell_height: u32,
    /// セルの上端からベースラインまで。
    baseline: u32,
};

/// size_px は拡大率（Retina なら 2）を掛けたあとのピクセル数。
pub fn init(name: [*:0]const u8, size_px: f64) error{FontNotFound}!Face {
    const cf_name = c.CFStringCreateWithCString(null, name, c.kCFStringEncodingUTF8) orelse return error.FontNotFound;
    defer c.CFRelease(cf_name);
    const font = c.CTFontCreateWithName(cf_name, size_px, null) orelse return error.FontNotFound;

    // 等幅フォントなので、どの文字でも送り幅は同じ。
    var units = [_]c.UniChar{'M'};
    var glyphs = [_]c.CGGlyph{0};
    _ = c.CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1);
    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(font, c.kCTFontOrientationHorizontal, &glyphs, &advance, 1);

    const ascent = @ceil(c.CTFontGetAscent(font));
    const descent = @ceil(c.CTFontGetDescent(font));
    const leading = @ceil(c.CTFontGetLeading(font));
    return .{
        .font = font,
        .metrics = .{
            .cell_width = @intFromFloat(@round(advance.width)),
            .cell_height = @intFromFloat(ascent + descent + leading),
            .baseline = @intFromFloat(ascent + @floor(leading / 2)),
        },
    };
}

pub fn deinit(face: Face) void {
    c.CFRelease(face.font);
}

pub const Resolved = struct {
    /// 呼び出し側が CFRelease する。
    font: c.CTFontRef,
    glyph: c.CGGlyph,
};

/// codepoint を描けるフォントとグリフを返す。このフォントに無い文字は CoreText のフォールバックに任せる。
pub fn resolve(face: Face, codepoint: u21) ?Resolved {
    var units: [2]c.UniChar = undefined;
    const n: c.CFIndex = if (codepoint < 0x10000) blk: {
        units[0] = @intCast(codepoint);
        break :blk 1;
    } else blk: {
        const v = codepoint - 0x10000;
        units[0] = @intCast(0xD800 + (v >> 10));
        units[1] = @intCast(0xDC00 + (v & 0x3FF));
        break :blk 2;
    };

    var glyphs = [2]c.CGGlyph{ 0, 0 };
    if (c.CTFontGetGlyphsForCharacters(face.font, &units, &glyphs, n)) {
        _ = c.CFRetain(face.font);
        return .{ .font = face.font, .glyph = glyphs[0] };
    }

    const str = c.CFStringCreateWithCharacters(null, &units, n) orelse return null;
    defer c.CFRelease(str);
    const fallback = c.CTFontCreateForString(face.font, str, .{ .location = 0, .length = n }) orelse return null;
    if (!c.CTFontGetGlyphsForCharacters(fallback, &units, &glyphs, n)) {
        c.CFRelease(fallback);
        return null;
    }
    return .{ .font = fallback, .glyph = glyphs[0] };
}

test "Menlo metrics" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    try std.testing.expectEqual(@as(u32, 16), face.metrics.cell_width);
    try std.testing.expect(face.metrics.cell_height > face.metrics.baseline);
}

test "resolve falls back for Japanese" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    const latin = face.resolve('A').?;
    defer c.CFRelease(latin.font);
    try std.testing.expect(latin.font == face.font);
    const kana = face.resolve(0x3042).?;
    defer c.CFRelease(kana.font);
    try std.testing.expect(kana.font != face.font);
    try std.testing.expect(kana.glyph != 0);
}
