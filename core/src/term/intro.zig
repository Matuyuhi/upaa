//! The startup face drawn on the terminal screen: the ASCII axolotl in splash.txt, with a small hop and one blink.
//! It is written to the terminal as escape sequences, not as shell output.
const std = @import("std");

const art = @embedFile("splash.txt");
const art_width: u16 = 58;
const art_height: u16 = 20;
/// The art, one row of room for the hop, a blank row, the name, and the note.
const block_height = art_height + 4;

const Pose = enum { rest, up, blink };
const poses = [_]Pose{ .rest, .up, .rest, .up, .rest, .blink, .rest };

pub const frame_count = poses.len;
pub const frame_ms = 200;

const art_color = "\x1b[38;2;249;193;208m";
const label_color = "\x1b[0;38;2;120;120;130m";
const note_color = "\x1b[0;38;2;233;111;146m";

/// Written after the last frame. Clears the screen and homes the cursor so the shell output starts clean.
/// The note, if any, stays on the first line, since it would be gone too fast with the face.
pub fn finish(buf: []u8, note: []const u8) []const u8 {
    var out: Out = .{ .buf = buf };
    out.put("\x1b[0m\x1b[2J\x1b[H\x1b[?25h");
    if (note.len > 0) {
        out.put(note_color);
        out.put(note);
        out.put("\x1b[0m\r\n");
    }
    return out.buf[0..out.len];
}

/// Writes frame index into buf and returns the written part, centered on a cols x rows screen.
/// The note, if any, goes under the name (centered by byte count, so non-ASCII text sits a little to the right).
pub fn frame(buf: []u8, cols: u16, rows: u16, index: usize, note: []const u8) []const u8 {
    var out: Out = .{ .buf = buf };
    const pose = poses[index % poses.len];
    const left: u16 = if (cols > art_width) (cols - art_width) / 2 + 1 else 1;
    const top: u16 = if (rows > block_height) (rows - block_height) / 2 + 1 else 1;
    const art_top = if (pose == .up) top else top + 1;

    out.put("\x1b[?25l\x1b[0m\x1b[2J");
    out.put(art_color);
    var lines = std.mem.splitScalar(u8, art, '\n');
    var line_index: u16 = 0;
    while (lines.next()) |line| : (line_index += 1) {
        if (line.len == 0) continue;
        out.move(art_top + line_index, left);
        var it = std.unicode.Utf8View.initUnchecked(line).iterator();
        var col: usize = 0;
        while (it.nextCodepointSlice()) |ch| : (col += 1) {
            out.put(if (pose == .blink) closedEye(line_index, col) orelse ch else ch);
        }
    }

    const label_indent: u16 = (art_width - "upaa".len) / 2;
    out.move(top + art_height + 2, left + label_indent);
    out.put(label_color);
    out.put("upaa");
    if (note.len > 0) {
        const width: u16 = @intCast(@min(note.len, cols));
        out.move(top + art_height + 3, if (cols > width) (cols - width) / 2 + 1 else 1);
        out.put(note_color);
        out.put(note);
    }
    out.put("\x1b[0m");
    return out.buf[0..out.len];
}

/// The eye is the `o` in `(o)` on line 5. A blink turns it into `-`.
const eye_line = 5;
const eye_cols = [_]usize{24};

fn closedEye(line: usize, col: usize) ?[]const u8 {
    if (line != eye_line) return null;
    return if (std.mem.indexOfScalar(usize, &eye_cols, col) != null) "-" else null;
}

const Out = struct {
    buf: []u8,
    len: usize = 0,

    /// Whatever does not fit is dropped.
    fn put(out: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, out.buf.len - out.len);
        @memcpy(out.buf[out.len..][0..n], bytes[0..n]);
        out.len += n;
    }

    fn move(out: *Out, line: u16, col: u16) void {
        var tmp: [16]u8 = undefined;
        out.put(std.fmt.bufPrint(&tmp, "\x1b[{d};{d}H", .{ line, col }) catch return);
    }
};

test "the art has the size the layout assumes" {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, art, "\n"), '\n');
    var count: usize = 0;
    var widest: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        widest = @max(widest, try std.unicode.utf8CountCodepoints(line));
    }
    try std.testing.expectEqual(@as(usize, art_height), count);
    try std.testing.expectEqual(@as(usize, art_width), widest);

    var rows = std.mem.splitScalar(u8, art, '\n');
    for (0..eye_line) |_| _ = rows.next();
    const eye_row = rows.next().?;
    for (eye_cols) |col| try std.testing.expectEqual(@as(u8, 'o'), eye_row[col]);
}

test "frames fit the buffer, and the hop and the blink change the frame" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const rest = frame(&a, 80, 24, 0, "");
    try std.testing.expect(rest.len < a.len);
    try std.testing.expect(std.mem.indexOf(u8, rest, "upaa") != null);
    try std.testing.expect(!std.mem.eql(u8, rest, frame(&b, 80, 24, 1, "")));
    try std.testing.expect(!std.mem.eql(u8, rest, frame(&b, 80, 24, 5, "")));

    const noted = frame(&b, 80, 24, 0, "v9.9.9 is out");
    try std.testing.expect(std.mem.indexOf(u8, noted, "v9.9.9 is out") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, "v9.9.9 is out"), "v9.9.9 is out\x1b[0m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, ""), "\r\n") == null);
}
