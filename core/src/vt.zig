const std = @import("std");
const c = @import("ghostty");

/// input を VT のバイト列として 80x24 の端末に書き、画面をプレーンテキストにして out に書く。
/// 戻り値は本来の長さで、cap より長い分は切り捨てる。失敗したら -1。
export fn wren_vt_plain_text(input: [*]const u8, len: usize, out: [*]u8, cap: usize) isize {
    var terminal: c.GhosttyTerminal = null;
    if (c.ghostty_terminal_new(null, &terminal, 80, 24) != c.GHOSTTY_SUCCESS) return -1;
    defer c.ghostty_terminal_free(terminal);

    c.ghostty_terminal_vt_write(terminal, input, len);

    var formatter: c.GhosttyFormatter = null;
    if (c.ghostty_formatter_terminal_new(null, &formatter, terminal) != c.GHOSTTY_SUCCESS) return -1;
    defer c.ghostty_formatter_free(formatter);

    var buf: [*c]u8 = null;
    var n: usize = 0;
    if (c.ghostty_formatter_format_alloc(formatter, null, &buf, &n) != c.GHOSTTY_SUCCESS) return -1;
    defer c.ghostty_free(null, buf, n);

    const m = @min(n, cap);
    if (m > 0) @memcpy(out[0..m], buf[0..m]);
    return @intCast(n);
}

test "plain text drops escape sequences" {
    const input = "Hello, \x1b[1;32mworld\x1b[0m!\r\nあいう";
    var out: [256]u8 = undefined;
    const n = wren_vt_plain_text(input.ptr, input.len, &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("Hello, world!\nあいう", out[0..@intCast(n)]);
}
