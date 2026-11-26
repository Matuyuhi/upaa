//! One monospace font, and the cell dimensions determined by it.
const Face = @This();

const std = @import("std");
const c = @import("apple");

font: c.CTFontRef,
metrics: Metrics,

pub const Metrics = extern struct {
    cell_width: u32,
    cell_height: u32,
    /// From the top of the cell to the baseline.
    baseline: u32,
    /// From the top of the cell to the top of the underline, and the underline thickness.
    underline_offset: u32,
    underline_thickness: u32,
};

/// size_px is the pixel size after multiplying by the scale factor (2 for Retina).
pub fn init(name: [*:0]const u8, size_px: f64) error{FontNotFound}!Face {
    const cf_name = c.CFStringCreateWithCString(null, name, c.kCFStringEncodingUTF8) orelse return error.FontNotFound;
    defer c.CFRelease(cf_name);
    const font = c.CTFontCreateWithName(cf_name, size_px, null) orelse return error.FontNotFound;

    // Monospace font, so the advance width is the same for every character.
    var units = [_]c.UniChar{'M'};
    var glyphs = [_]c.CGGlyph{0};
    _ = c.CTFontGetGlyphsForCharacters(font, &units, &glyphs, 1);
    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(font, c.kCTFontOrientationHorizontal, &glyphs, &advance, 1);

    const ascent = @ceil(c.CTFontGetAscent(font));
    const descent = @ceil(c.CTFontGetDescent(font));
    const leading = @ceil(c.CTFontGetLeading(font));
    const cell_height: u32 = @intFromFloat(ascent + descent + leading);
    const baseline: u32 = @intFromFloat(ascent + @floor(leading / 2));
    const thickness: u32 = @max(1, @as(u32, @intFromFloat(@round(c.CTFontGetUnderlineThickness(font)))));
    // CoreText's underline position is negative downward from the baseline. Keep it within the cell.
    const below: u32 = @intFromFloat(@max(1, @round(-c.CTFontGetUnderlinePosition(font))));
    return .{
        .font = font,
        .metrics = .{
            .cell_width = @intFromFloat(@round(advance.width)),
            .cell_height = cell_height,
            .baseline = baseline,
            .underline_offset = @min(baseline + below, cell_height - thickness),
            .underline_thickness = thickness,
        },
    };
}

pub fn deinit(face: Face) void {
    c.CFRelease(face.font);
}

pub const Resolved = struct {
    /// The caller calls CFRelease.
    font: c.CTFontRef,
    glyph: c.CGGlyph,
};

/// Returns a font that can draw the codepoint, and its glyph. Characters this font lacks are left to CoreText fallback.
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
    try std.testing.expect(face.metrics.underline_offset > face.metrics.baseline);
    try std.testing.expect(face.metrics.underline_offset + face.metrics.underline_thickness <= face.metrics.cell_height);
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
