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
    errdefer c.CFRelease(font);
    // For a name it does not know, CoreText returns some other font instead of failing.
    if (!isNamed(font, cf_name)) return error.FontNotFound;

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
