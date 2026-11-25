//! 起動時に端末の画面へ描く、文字で組んだウーパールーパーの顔。
//! シェルの出力ではなく、端末に直接書き込むエスケープシーケンスとして作る。
const std = @import("std");

pub const frame_count = 14;
pub const frame_ms = 110;

/// 最後のコマのあとに書く。画面を消してカーソルを戻し、シェルの出力を受けられる状態にする。
/// note があれば 1 行目に残す。顔と一緒に消えると読み切れないため。
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

/// 外えらは 2 コマおきに外側へ 1 文字ずれて、揺れているように見せる。
const Gills = struct { top_l: []const u8, top_r: []const u8, mid_l: []const u8, mid_r: []const u8, bot_l: []const u8, bot_r: []const u8 };
const gills_in: Gills = .{ .top_l = " \\\\\\ ", .top_r = " /// ", .mid_l = " === ", .mid_r = " === ", .bot_l = " /// ", .bot_r = " \\\\\\ " };
const gills_out: Gills = .{ .top_l = "\\\\\\  ", .top_r = "  ///", .mid_l = "===  ", .mid_r = "  ===", .bot_l = "///  ", .bot_r = "  \\\\\\" };
const no_gill = "     ";

/// index 番目のコマを buf に書き、書いた部分を返す。cols x rows の画面の中央に置く。
/// note があれば名前の下に出す（半角の文字数で中央に寄せるので、全角を含むと少し右に寄る）。
pub fn frame(buf: []u8, cols: u16, rows: u16, index: usize, note: []const u8) []const u8 {
    var out: Out = .{ .buf = buf };
    const gills = if ((index / 2) % 2 == 0) gills_in else gills_out;
    // 終わり近くで 1 回まばたきする。
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
    const label_indent: u16 = (art_width - "uparupa".len) / 2;
    out.move(top + 7, left + label_indent);
    out.put(label_color);
    out.put("uparupa");
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

    /// 入りきらない分は捨てる。
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
    try std.testing.expect(std.mem.indexOf(u8, first, "uparupa") != null);
    // 小さすぎる画面でも位置が 1 行 1 桁目より前に出ない。
    const tiny = frame(&b, 4, 2, 0, "");
    try std.testing.expect(std.mem.indexOf(u8, tiny, "\x1b[1;1H") != null);

    const noted = frame(&b, 80, 24, 0, "v9.9.9 is out");
    try std.testing.expect(std.mem.indexOf(u8, noted, "v9.9.9 is out") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, "v9.9.9 is out"), "v9.9.9 is out\x1b[0m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, finish(&a, ""), "\r\n") == null);
}
