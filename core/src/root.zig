//! Functions exported to C (corresponds to Sources/CUpaaCore/include/upaa_core.h).
//! Only export fn lives here; the implementation is in each module.
const std = @import("std");
const vt = @import("ghostty");
const Session = @import("term/Session.zig");
const version = @import("version.zig");
const Renderer = @import("render/Renderer.zig");
const Cell = @import("render/Cell.zig").Cell;
const Frame = @import("render/Frame.zig");
const Face = @import("font/Face.zig");
const Atlas = @import("font/Atlas.zig");

comptime {
    _ = @import("term/Pty.zig");
    _ = @import("term/keymap.zig");
    _ = @import("term/intro.zig");
    _ = @import("font/Face.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("render/Frame.zig");
}

/// upaa's own version (.version in build.zig.zon).
export fn upaa_version() [*:0]const u8 {
    return version.current.ptr;
}

/// True if candidate (in the form "v0.2.0") is newer than the current version.
export fn upaa_version_is_newer(candidate: [*:0]const u8) bool {
    return version.isNewer(std.mem.span(candidate));
}

// Terminal session

/// If command is null, starts the login shell; otherwise starts /bin/sh -c command.
/// If show_intro is true, draws the startup face before printing shell output.
export fn upaa_session_new(cols: u16, rows: u16, command: ?[*:0]const u8, show_intro: bool, callbacks: ?*const Session.Callbacks) ?*Session {
    return Session.create(.{
        .size = .{ .cols = cols, .rows = rows },
        .command = command,
        .intro = show_intro,
        .callbacks = if (callbacks) |cb| cb.* else .{},
    }) catch null;
}

export fn upaa_session_free(session: *Session) void {
    session.destroy();
}

export fn upaa_session_write(session: *Session, data: [*]const u8, len: usize) void {
    session.write(data[0..len]);
}

/// Moves the view through the scrollback by rows (up is negative).
export fn upaa_session_scroll(session: *Session, rows: isize) void {
    session.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = rows } });
}

export fn upaa_session_key(session: *Session, event: *const Session.KeyEvent) void {
    session.key(event.*);
}

export fn upaa_session_resize(session: *Session, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) void {
    session.resize(.{
        .cols = cols,
        .rows = rows,
        .width_px = std.math.lossyCast(u16, @as(u64, cols) * cell_width_px),
        .height_px = std.math.lossyCast(u16, @as(u64, rows) * cell_height_px),
    }, cell_width_px, cell_height_px);
}

/// Notice shown with the startup face. Calling this after the face has finished playing does nothing.
export fn upaa_session_set_intro_note(session: *Session, text: [*:0]const u8) void {
    session.setIntroNote(std.mem.span(text));
}

export fn upaa_session_take_dirty(session: *Session) bool {
    return session.takeDirty();
}

/// Returns the full length; anything beyond cap is truncated. Returns -1 on failure.
export fn upaa_session_plain_text(session: *Session, out: [*]u8, cap: usize) isize {
    return @intCast(session.plainText(out[0..cap]) orelse return -1);
}

// Rendering

export fn upaa_renderer_new(font_name: [*:0]const u8, font_size_px: f64) ?*Renderer {
    return Renderer.create(font_name, font_size_px) catch null;
}

export fn upaa_renderer_free(renderer: *Renderer) void {
    renderer.destroy();
}

export fn upaa_renderer_metrics(renderer: *Renderer) Face.Metrics {
    return renderer.face.metrics;
}

/// Atlas image (1 byte per pixel, side upaa_renderer_atlas_size pixels).
export fn upaa_renderer_atlas_pixels(renderer: *Renderer) [*]const u8 {
    return renderer.atlas.pixels.ptr;
}

export fn upaa_renderer_atlas_size() u32 {
    return Atlas.size;
}

/// Writes the session's current screen to cells. cells may point directly into the Metal buffer's contents.
/// preedit is the IME composing string (UTF-8). null if none.
export fn upaa_renderer_frame(renderer: *Renderer, session: *Session, preedit: ?[*]const u8, preedit_len: usize, cells: [*]Cell, cap: usize) Frame.Info {
    const text: []const u8 = if (preedit) |p| p[0..preedit_len] else "";
    return renderer.buildFrame(session, text, cells[0..cap]);
}

