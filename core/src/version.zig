//! upaa's own version. The value comes from .version in build.zig.zon.
const std = @import("std");
const build_options = @import("build_options");

pub const current: [:0]const u8 = build_options.version ++ "";

/// True if candidate ("v0.2.0" or "0.2.0" form) is newer than the current version. False if it cannot be parsed.
pub fn isNewer(candidate: []const u8) bool {
    const theirs = parse(candidate) orelse return false;
    const ours = parse(current) orelse return false;
    for (theirs, ours) |a, b| {
        if (a != b) return a > b;
    }
    return false;
}

fn parse(text: []const u8) ?[3]u32 {
    const digits = if (text.len > 0 and text[0] == 'v') text[1..] else text;
    var parts: [3]u32 = undefined;
    var it = std.mem.splitScalar(u8, digits, '.');
    for (&parts) |*part| {
        part.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    }
    if (it.next() != null) return null;
    return parts;
}

test "parse" {
    try std.testing.expectEqual([3]u32{ 1, 20, 3 }, parse("v1.20.3").?);
    try std.testing.expectEqual([3]u32{ 0, 1, 0 }, parse("0.1.0").?);
    try std.testing.expect(parse("1.2") == null);
    try std.testing.expect(parse("1.2.3.4") == null);
    try std.testing.expect(parse("1.2.x") == null);
    try std.testing.expect(parse("") == null);
}

test "isNewer compares numerically against the current version" {
    const ours = parse(current).?;
    var buf: [64]u8 = undefined;
    const next_patch = try std.fmt.bufPrint(&buf, "v{d}.{d}.{d}", .{ ours[0], ours[1], ours[2] + 1 });
    try std.testing.expect(isNewer(next_patch));
    const next_major = try std.fmt.bufPrint(&buf, "{d}.0.0", .{ours[0] + 1});
    try std.testing.expect(isNewer(next_major));
    try std.testing.expect(!isNewer(current));
    try std.testing.expect(!isNewer("not-a-version"));
}
