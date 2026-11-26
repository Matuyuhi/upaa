//! リンクの確認（--check）で使う小さな関数。C への公開は root.zig が行う。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("apple");
const vt = @import("ghostty");

pub const greeting = "hello from zig " ++ builtin.zig_version_string;

/// 64 ビットの FNV-1a。Swift 側でも同じ計算をして、バイト列の受け渡しが壊れていないかを確かめる。
pub fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

/// input を VT のバイト列として 80x24 の端末に書き、画面をプレーンテキストにして out に書く。
/// 戻り値は本来の長さで、out より長い分は切り捨てる。
pub fn vtPlainText(input: []const u8, out: []u8) ?usize {
    var terminal: vt.GhosttyTerminal = null;
    if (vt.ghostty_terminal_new(null, &terminal, 80, 24) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_terminal_free(terminal);

    vt.ghostty_terminal_vt_write(terminal, input.ptr, input.len);

    var formatter: vt.GhosttyFormatter = null;
    if (vt.ghostty_formatter_terminal_new(null, &formatter, terminal) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_formatter_free(formatter);

    var buf: [*c]u8 = null;
    var n: usize = 0;
    if (vt.ghostty_formatter_format_alloc(formatter, null, &buf, &n) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_free(null, buf, n);

    const m = @min(n, out.len);
    if (m > 0) @memcpy(out[0..m], buf[0..m]);
    return n;
}

/// Sources/CUpaaCore/upaa_core.h の UpaaGlyphInfo と同じ並び。
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
pub fn glyphInfo(font_name: [*:0]const u8, size: f64, codepoint: u32, out: *GlyphInfo) bool {
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
    try std.testing.expect(glyphInfo("Menlo", 14, 'A', &info));
    try std.testing.expect(info.glyph != 0);
    try std.testing.expect(info.advance > 0);
    try std.testing.expectEqualStrings("Menlo-Regular", fontName(&info));
}

test "japanese glyph falls back to another font" {
    var info: GlyphInfo = undefined;
    try std.testing.expect(glyphInfo("Menlo", 14, 0x3042, &info));
    try std.testing.expect(info.glyph != 0);
    try std.testing.expect(!std.mem.eql(u8, "Menlo-Regular", fontName(&info)));
}

test "surrogate pair" {
    var units: [2]c.UniChar = undefined;
    try std.testing.expectEqual(@as(?usize, 2), encodeUtf16(0x1F426, &units));
    try std.testing.expectEqual(@as(c.UniChar, 0xD83D), units[0]);
    try std.testing.expectEqual(@as(c.UniChar, 0xDC26), units[1]);
}

test "fnv1a64" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a64(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a64("a"));
}

test "plain text drops escape sequences" {
    var out: [256]u8 = undefined;
    const n = vtPlainText("Hello, \x1b[1;32mworld\x1b[0m!\r\nあいう", &out).?;
    try std.testing.expectEqualStrings("Hello, world!\nあいう", out[0..n]);
}
