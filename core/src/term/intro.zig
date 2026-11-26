//! The text-art axolotl face drawn on the terminal screen at startup.
//! Not shell output: built as escape sequences written directly to the terminal.
const std = @import("std");

pub const frame_count = 14;
pub const frame_ms = 110;

/// Written after the last frame. Clears the screen, returns the cursor, and gets the terminal ready to receive shell output.
/// If note is given, it stays on line 1, since it would be hard to read if it disappeared with the face.
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

const art_width = 24;
const art_height = 8;

const gill_color = "\x1b[38;2;233;111;146m";
const face_color = "\x1b[38;2;249;193;208m";
const eye_color = "\x1b[1;38;2;255;255;255m";
const label_color = "\x1b[0;38;2;120;120;130m";
const note_color = "\x1b[0;38;2;233;111;146m";

/// The outer gills shift one character outward every 2 frames, so they look like they are wobbling.
const Gills = struct { top_l: []const u8, top_r: []const u8, mid_l: []const u8, mid_r: []const u8, bot_l: []const u8, bot_r: []const u8 };
const gills_in: Gills = .{ .top_l = " \\\\\\ ", .top_r = " /// ", .mid_l = " === ", .mid_r = " === ", .bot_l = " /// ", .bot_r = " \\\\\\ " };
const gills_out: Gills = .{ .top_l = "\\\\\\  ", .top_r = "  ///", .mid_l = "===  ", .mid_r = "  ===", .bot_l = "///  ", .bot_r = "  \\\\\\" };
const no_gill = "     ";

/// Writes the index-th frame to buf and returns the written part. Centered in a cols x rows screen.
/// If note is given, it is shown below the name. Centering uses half-width character counts, so full-width characters shift it slightly to the right.
pub fn frame(buf: []u8, cols: u16, rows: u16, index: usize, note: []const u8) []const u8 {
    var out: Out = .{ .buf = buf };
    const gills = if ((index / 2) % 2 == 0) gills_in else gills_out;
    // Blink once near the end.
    const eye = if (index == frame_count - 5) "-" else "\u{25CF}";

    const left: u16 = if (cols > art_width) (cols - art_width) / 2 + 1 else 1;
    const top: u16 = if (rows > art_height) (rows - art_height) / 2 + 1 else 1;

    out.put("\x1b[?25l\x1b[0m\x1b[2J");
    out.row(top + 0, left, no_gill, " .----------. ", no_gill);
    out.row(top + 1, left, gills.top_l, "/            \\", gills.top_r);
    out.eyes(top + 2, left, gills.mid_l, gills.mid_r, eye);
    out.row(top + 3, left, gills.bot_l, "|    \\__/    |", gills.bot_r);
    out.row(top + 4, left, no_gill, "\\            /", no_gill);
    out.row(top + 5, left, no_gill, " '----------' ", no_gill);
    const label_indent: u16 = (art_width - "upaa".len) / 2;
    out.move(top + 7, left + label_indent);
    out.put(label_color);
    out.put("upaa");
    if (note.len > 0) {
        const width: u16 = @intCast(@min(note.len, cols));
        out.move(top + 9, if (cols > width) (cols - width) / 2 + 1 else 1);
        out.put(note_color);
        out.put(note);
    }
    out.put("\x1b[0m");
    return out.buf[0..out.len];
}

const Out = struct {
    buf: []u8,
    len: usize = 0,

    /// Anything that does not fit is discarded.
    fn put(out: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, out.buf.len - out.len);
        @memcpy(out.buf[out.len..][0..n], bytes[0..n]);
        out.len += n;
    }

    fn number(out: *Out, value: u16) void {
        var digits: [5]u8 = undefined;
        var i: usize = digits.len;
        var v = value;
        while (true) {
            i -= 1;
            digits[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            if (v == 0) break;
        }
        out.put(digits[i..]);
    }

    fn move(out: *Out, line: u16, col: u16) void {
        out.put("\x1b[");
        out.number(line);
        out.put(";");
        out.number(col);
        out.put("H");
    }

    fn row(out: *Out, line: u16, col: u16, gill_l: []const u8, face: []const u8, gill_r: []const u8) void {
        out.move(line, col);
        out.put(gill_color);
        out.put(gill_l);
        out.put(face_color);
        out.put(face);
        out.put(gill_color);
        out.put(gill_r);
    }

    fn eyes(out: *Out, line: u16, col: u16, gill_l: []const u8, gill_r: []const u8, eye: []const u8) void {
        out.move(line, col);
        out.put(gill_color);
        out.put(gill_l);
        out.put(face_color);
        out.put("|  ");
        out.put(eye_color);
        out.put(eye);
        out.put("      ");
        out.put(eye);
        out.put("\x1b[0m");
        out.put(face_color);
        out.put("  |");
        out.put(gill_color);
        out.put(gill_r);
    }
};

test "frames fit the buffer and differ when the gills move" {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const first = frame(&a, 80, 24, 0, "");
    const moved = frame(&b, 80, 24, 2, "");
    try std.testing.expect(first.len < a.len);
    try std.testing.expect(!std.mem.eql(u8, first, moved));
    try std.testing.expect(std.mem.indexOf(u8, first, "upaa") != null);
    // Even on a very small screen, the position never goes before row 1, column 1.
    const tiny = frame(&b, 4, 2, 0, "");
    try std.testing.expect(std.mem.indexOf(u8, tiny, "\x1b[1;1H") != null);

    const noted = frame(&b, 80, 24, 0, "v9.9.9 is out");
    try std.testing.expect(std.mem.indexOf(u8, noted, "v9.9.9 is out") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, "v9.9.9 is out"), "v9.9.9 is out\x1b[0m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, ""), "\r\n") == null);
}
