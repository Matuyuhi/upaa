//! Settings from the config file. The Swift side reads the file and passes its text here.
//!
//! One setting per line, `key = value`. Empty lines and lines starting with `#` are ignored.
//! The keys and the color syntax are Ghostty's, so lines can be copied from a Ghostty config.
//! A line that cannot be read keeps the default, and the first such line is reported.
const Config = @This();

const std = @import("std");
const vt = @import("ghostty");

/// NUL-terminated. The last byte is never written.
font_family: [129]u8 = fixed("Menlo"),
/// Points.
font_size: f64 = 13,
/// Cells.
window_width: u16 = 80,
window_height: u16 = 24,
/// null keeps libghostty-vt's default.
foreground: ?vt.GhosttyColorRgb = null,
background: ?vt.GhosttyColorRgb = null,
palette: [256]?vt.GhosttyColorRgb = @splat(null),
/// NUL-terminated ASCII, empty if every line was read.
problem: [80]u8 = @splat(0),

/// What the Swift side reads. Same layout as UpaaConfigValues in Sources/CUpaaCore. The pointers live as long as the Config.
pub const Values = extern struct {
    font_family: [*:0]const u8,
    font_size: f64,
    window_width: u16,
    window_height: u16,
    /// The first line that could not be read, or null.
    problem: ?[*:0]const u8,
};

pub fn parse(text: []const u8) Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            config.fail(number, "expected key = value");
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        config.set(key, value) catch |err| config.fail(number, switch (err) {
            error.UnknownKey => "unknown key",
            error.InvalidValue => "invalid value",
        });
    }
    return config;
}

pub fn values(config: *const Config) Values {
    return .{
        .font_family = config.font_family[0 .. config.font_family.len - 1 :0].ptr,
        .font_size = config.font_size,
        .window_width = config.window_width,
        .window_height = config.window_height,
        .problem = if (config.problem[0] == 0) null else config.problem[0 .. config.problem.len - 1 :0].ptr,
    };
}

/// Sets the colors on a new terminal. Colors the file does not name keep libghostty-vt's defaults.
pub fn applyColors(config: *const Config, terminal: vt.GhosttyTerminal) void {
    if (config.foreground) |rgb| _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &rgb);
    if (config.background) |rgb| _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &rgb);

    var palette: [256]vt.GhosttyColorRgb = undefined;
    if (vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette) != vt.GHOSTTY_SUCCESS) return;
    var changed = false;
    for (config.palette, &palette) |entry, *slot| if (entry) |rgb| {
        slot.* = rgb;
        changed = true;
    };
    if (changed) _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette);
}

fn set(config: *Config, key: []const u8, value: []const u8) error{ UnknownKey, InvalidValue }!void {
    if (std.mem.eql(u8, key, "font-family")) {
        if (value.len == 0 or value.len >= config.font_family.len) return error.InvalidValue;
        @memset(&config.font_family, 0);
        @memcpy(config.font_family[0..value.len], value);
    } else if (std.mem.eql(u8, key, "font-size")) {
        const size = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
        if (!(size >= 4 and size <= 200)) return error.InvalidValue;
        config.font_size = size;
    } else if (std.mem.eql(u8, key, "window-width")) {
        config.window_width = try cells(value, 10);
    } else if (std.mem.eql(u8, key, "window-height")) {
        config.window_height = try cells(value, 4);
    } else if (std.mem.eql(u8, key, "foreground")) {
        config.foreground = try color(value);
    } else if (std.mem.eql(u8, key, "background")) {
        config.background = try color(value);
    } else if (std.mem.eql(u8, key, "palette")) {
        var index: u8 = 0;
        var rgb: vt.GhosttyColorRgb = undefined;
        if (vt.ghostty_color_parse_palette_entry(value.ptr, value.len, &index, &rgb) != vt.GHOSTTY_SUCCESS) return error.InvalidValue;
        config.palette[index] = rgb;
    } else return error.UnknownKey;
}

fn cells(value: []const u8, min: u16) error{InvalidValue}!u16 {
    const n = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
    return if (n >= min and n <= 1000) n else error.InvalidValue;
}

fn color(value: []const u8) error{InvalidValue}!vt.GhosttyColorRgb {
    var rgb: vt.GhosttyColorRgb = undefined;
    if (vt.ghostty_color_parse(value.ptr, value.len, &rgb) != vt.GHOSTTY_SUCCESS) return error.InvalidValue;
    return rgb;
}

fn unquote(value: []const u8) []const u8 {
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}

fn fail(config: *Config, line: usize, reason: []const u8) void {
    if (config.problem[0] != 0) return;
    _ = std.fmt.bufPrint(config.problem[0 .. config.problem.len - 1], "config line {d}: {s}", .{ line, reason }) catch {};
}

fn fixed(comptime text: []const u8) [129]u8 {
    var out: [129]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

test "defaults" {
    const config = parse("");
    const v = config.values();
    try std.testing.expectEqualStrings("Menlo", std.mem.span(v.font_family));
    try std.testing.expectEqual(@as(f64, 13), v.font_size);
    try std.testing.expectEqual(@as(u16, 80), v.window_width);
    try std.testing.expectEqual(@as(u16, 24), v.window_height);
    try std.testing.expect(v.problem == null);
}

test "settings, and the first line that cannot be read" {
    const config = parse(
        \\# comment
        \\font-family = "JetBrains Mono"
        \\font-size = 14.5
        \\window-width = 100
        \\window-height=30
        \\
        \\background = #1e1e2e
        \\palette = 1 = #ff0000
        \\bogus = 1
        \\font-size = huge
    );
    const v = config.values();
    try std.testing.expectEqualStrings("JetBrains Mono", std.mem.span(v.font_family));
    try std.testing.expectEqual(@as(f64, 14.5), v.font_size);
    try std.testing.expectEqual(@as(u16, 100), v.window_width);
    try std.testing.expectEqual(@as(u16, 30), v.window_height);
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, config.background.?);
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0xff, .g = 0, .b = 0 }, config.palette[1].?);
    try std.testing.expect(config.palette[2] == null);
    try std.testing.expectEqualStrings("config line 9: unknown key", std.mem.span(v.problem.?));

    const bad = parse("window-width = 3\nwindow-width = 120\nno equals sign");
    try std.testing.expectEqual(@as(u16, 120), bad.window_width);
    try std.testing.expectEqualStrings("config line 1: invalid value", std.mem.span(bad.values().problem.?));
}

test "colors reach the terminal" {
    var terminal: vt.GhosttyTerminal = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_new(null, &terminal, 10, 3));
    defer vt.ghostty_terminal_free(terminal);
    const config = parse("foreground = #102030\nbackground = black\npalette = 4=#abcdef");
    config.applyColors(terminal);

    var rgb: vt.GhosttyColorRgb = undefined;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &rgb));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, rgb);
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &rgb));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0, .g = 0, .b = 0 }, rgb);
    var palette: [256]vt.GhosttyColorRgb = undefined;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &palette));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, palette[4]);
}
