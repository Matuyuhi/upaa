//! フォント、アトラス、描画用の状態をまとめて持ち、端末セッションから 1 フレーム分のセルを作る。
const Renderer = @This();

const std = @import("std");
const vt = @import("ghostty");
const Atlas = @import("../font/Atlas.zig");
const Face = @import("../font/Face.zig");
const Session = @import("../term/Session.zig");
const Cell = @import("Cell.zig").Cell;
const Frame = @import("Frame.zig");

const alloc = std.heap.c_allocator;

face: Face,
atlas: Atlas,
state: vt.GhosttyRenderState,
frame: Frame,

pub fn create(font_name: [*:0]const u8, font_size_px: f64) !*Renderer {
    const self = try alloc.create(Renderer);
    errdefer alloc.destroy(self);

    const face = try Face.init(font_name, font_size_px);
    errdefer face.deinit();
    var atlas = try Atlas.init();
    errdefer atlas.deinit();
    var state: vt.GhosttyRenderState = null;
    if (vt.ghostty_render_state_new(null, &state) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_render_state_free(state);
    const frame = try Frame.init();

    self.* = .{ .face = face, .atlas = atlas, .state = state, .frame = frame };
    return self;
}

pub fn destroy(self: *Renderer) void {
    self.frame.deinit();
    vt.ghostty_render_state_free(self.state);
    self.atlas.deinit();
    self.face.deinit();
    alloc.destroy(self);
}

/// session の今の画面を out に書く。
pub fn buildFrame(self: *Renderer, session: *Session, out: []Cell) Frame.Info {
    if (!session.updateRenderState(self.state)) return .{};
    const info = self.frame.build(self.state, self.face, &self.atlas, out);
    _ = vt.ghostty_render_state_clean(self.state);
    return info;
}
