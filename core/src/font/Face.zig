//! One monospace font with its fallbacks, and the cell dimensions determined by it.
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

/// names is the font, then its fallbacks, one per line. CoreText tries the fallbacks, in order, for characters the font
/// lacks (such as Nerd Font icons) before the system's own. Fallbacks that are not installed are skipped.
/// size_px is the pixel size after multiplying by the scale factor (2 for Retina).
pub fn init(names: [*:0]const u8, size_px: f64) error{FontNotFound}!Face {
    var lines = std.mem.splitScalar(u8, std.mem.span(names), '\n');
    const font = withFallbacks(try named(lines.first(), size_px), &lines, size_px);
    errdefer c.CFRelease(font);

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

fn named(name: []const u8, size_px: f64) error{FontNotFound}!c.CTFontRef {
    const cf_name = c.CFStringCreateWithBytes(null, name.ptr, @intCast(name.len), c.kCFStringEncodingUTF8, 0) orelse return error.FontNotFound;
    defer c.CFRelease(cf_name);
    const font = c.CTFontCreateWithName(cf_name, size_px, null) orelse return error.FontNotFound;
    // For a name it does not know, CoreText returns some other font instead of failing.
    if (!isNamed(font, cf_name)) {
        c.CFRelease(font);
        return error.FontNotFound;
    }
    return font;
}

/// font with the fonts named by the remaining lines as its cascade list. Takes over font.
fn withFallbacks(font: c.CTFontRef, lines: anytype, size_px: f64) c.CTFontRef {
    const cascade = c.CFArrayCreateMutable(null, 0, &c.kCFTypeArrayCallBacks) orelse return font;
    defer c.CFRelease(cascade);
    while (lines.next()) |name| {
        const fallback = named(name, size_px) catch continue;
        defer c.CFRelease(fallback);
        const descriptor = c.CTFontCopyFontDescriptor(fallback) orelse continue;
        defer c.CFRelease(descriptor);
        c.CFArrayAppendValue(cascade, descriptor);
    }
    if (c.CFArrayGetCount(cascade) == 0) return font;

    var keys = [_]?*const anyopaque{c.kCTFontCascadeListAttribute};
    var values = [_]?*const anyopaque{cascade};
    const attrs = c.CFDictionaryCreate(null, &keys, &values, 1, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return font;
    defer c.CFRelease(attrs);
    const own = c.CTFontCopyFontDescriptor(font) orelse return font;
    defer c.CFRelease(own);
    const descriptor = c.CTFontDescriptorCreateCopyWithAttributes(own, attrs) orelse return font;
    defer c.CFRelease(descriptor);
    const copy = c.CTFontCreateWithFontDescriptor(descriptor, size_px, null) orelse return font;
    c.CFRelease(font);
    return copy;
}

/// Whether name is the PostScript, family, or full name of font (ignoring case).
fn isNamed(font: c.CTFontRef, name: c.CFStringRef) bool {
    var found = false;
    for ([_]c.CFStringRef{ c.CTFontCopyPostScriptName(font), c.CTFontCopyFamilyName(font), c.CTFontCopyFullName(font) }) |copy| {
        const copied = copy orelse continue;
        defer c.CFRelease(copied);
        if (c.CFStringCompare(copied, name, @intCast(c.kCFCompareCaseInsensitive)) == c.kCFCompareEqualTo) found = true;
    }
    return found;
}

pub fn deinit(face: Face) void {
    c.CFRelease(face.font);
}

test "Menlo metrics" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    try std.testing.expectEqual(@as(u32, 16), face.metrics.cell_width);
    try std.testing.expect(face.metrics.cell_height > face.metrics.baseline);
    try std.testing.expect(face.metrics.underline_offset > face.metrics.baseline);
    try std.testing.expect(face.metrics.underline_offset + face.metrics.underline_thickness <= face.metrics.cell_height);
    try std.testing.expectError(error.FontNotFound, Face.init("No Such Font upaa", 26));
}

test "fallbacks become the cascade list, skipping fonts that are not installed" {
    const face = try Face.init("Menlo\nNo Such Font upaa\nApple Color Emoji", 26);
    defer face.deinit();
    try std.testing.expectEqual(@as(u32, 16), face.metrics.cell_width);
    const cascade: c.CFArrayRef = @ptrCast(c.CTFontCopyAttribute(face.font, c.kCTFontCascadeListAttribute));
    try std.testing.expect(cascade != null);
    defer c.CFRelease(cascade);
    try std.testing.expectEqual(@as(c.CFIndex, 1), c.CFArrayGetCount(cascade));
    try std.testing.expectError(error.FontNotFound, Face.init("No Such Font upaa\nMenlo", 26));
}
