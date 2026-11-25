//! C に公開する関数（Sources/CWrenCore/include/wren_core.h と対応）。
//! ここには export fn だけを置き、中身は各モジュールに書く。
const std = @import("std");
const selftest = @import("selftest.zig");
const Session = @import("term/Session.zig");
const Renderer = @import("render/Renderer.zig");
const Cell = @import("render/Cell.zig").Cell;
const Frame = @import("render/Frame.zig");
const Face = @import("font/Face.zig");
const Atlas = @import("font/Atlas.zig");

comptime {
    _ = @import("term/Pty.zig");
    _ = @import("font/Face.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("render/Frame.zig");
}

/// Swift 側のヘッダと食い違っていないかを起動時に確かめるための番号。
/// 公開する関数や構造体の形を変えたら、ヘッダの WREN_CORE_ABI_VERSION と一緒に上げる。
export fn wren_core_abi_version() u32 {
    return 4;
}

// 端末セッション

export fn wren_session_new(cols: u16, rows: u16, callbacks: ?*const Session.Callbacks) ?*Session {
    return Session.create(.{
        .size = .{ .cols = cols, .rows = rows },
        .callbacks = if (callbacks) |cb| cb.* else .{},
    }) catch null;
}

export fn wren_session_free(session: *Session) void {
    session.destroy();
}

export fn wren_session_write(session: *Session, data: [*]const u8, len: usize) void {
    session.write(data[0..len]);
}

export fn wren_session_resize(session: *Session, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) void {
    session.resize(.{
        .cols = cols,
        .rows = rows,
        .width_px = std.math.lossyCast(u16, @as(u64, cols) * cell_width_px),
        .height_px = std.math.lossyCast(u16, @as(u64, rows) * cell_height_px),
    }, cell_width_px, cell_height_px);
}

export fn wren_session_take_dirty(session: *Session) bool {
    return session.takeDirty();
}

/// 戻り値は本来の長さで、cap より長い分は切り捨てる。失敗したら -1。
export fn wren_session_plain_text(session: *Session, out: [*]u8, cap: usize) isize {
    return @intCast(session.plainText(out[0..cap]) orelse return -1);
}

// 描画

export fn wren_renderer_new(font_name: [*:0]const u8, font_size_px: f64) ?*Renderer {
    return Renderer.create(font_name, font_size_px) catch null;
}

export fn wren_renderer_free(renderer: *Renderer) void {
    renderer.destroy();
}

export fn wren_renderer_metrics(renderer: *Renderer) Face.Metrics {
    return renderer.face.metrics;
}

/// アトラスの画像（1 ピクセル 1 バイト、一辺 wren_renderer_atlas_size ピクセル）。
export fn wren_renderer_atlas_pixels(renderer: *Renderer) [*]const u8 {
    return renderer.atlas.pixels.ptr;
}

export fn wren_renderer_atlas_size() u32 {
    return Atlas.size;
}

/// session の今の画面を cells に書く。cells は Metal のバッファの中身を直接指してよい。
export fn wren_renderer_frame(renderer: *Renderer, session: *Session, cells: [*]Cell, cap: usize) Frame.Info {
    return renderer.buildFrame(session, cells[0..cap]);
}

// リンクの確認（--check）

export fn wren_selftest_greeting(buf: [*]u8, cap: usize) usize {
    const n = @min(cap, selftest.greeting.len);
    @memcpy(buf[0..n], selftest.greeting[0..n]);
    return selftest.greeting.len;
}

export fn wren_selftest_fnv1a64(data: [*]const u8, len: usize) u64 {
    return selftest.fnv1a64(data[0..len]);
}

export fn wren_selftest_vt_plain_text(input: [*]const u8, len: usize, out: [*]u8, cap: usize) isize {
    return @intCast(selftest.vtPlainText(input[0..len], out[0..cap]) orelse return -1);
}

export fn wren_selftest_glyph_info(font_name: [*:0]const u8, size: f64, codepoint: u32, out: *selftest.GlyphInfo) bool {
    return selftest.glyphInfo(font_name, size, codepoint, out);
}
