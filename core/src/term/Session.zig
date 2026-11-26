//! 端末 1 つ分。PTY、読み取りスレッド、libghostty-vt の端末をまとめて持つ。
//!
//! 端末（terminal）に触るのは必ず mutex を取ってから。libghostty-vt の端末はスレッドセーフではなく、
//! 読み取りスレッド（PTY の出力を書き込む）と呼び出し側のスレッド（リサイズ、描画）の両方から触るため。
const Session = @This();

const std = @import("std");
const c = @import("posix");
const vt = @import("ghostty");
const Pty = @import("Pty.zig");
const keymap = @import("keymap.zig");
const intro = @import("intro.zig");

const alloc = std.heap.c_allocator;

pty: Pty,
terminal: vt.GhosttyTerminal,
key_encoder: vt.GhosttyKeyEncoder,
key_event: vt.GhosttyKeyEvent,
mutex: std.c.pthread_mutex_t = .{},
thread: std.Thread,
/// 読み取りスレッドを止めるためのパイプ。書くと poll が起きる。
stop_pipe: [2]c_int,
/// 画面が変わったことをまだ伝えていないときだけ on_wakeup を呼ぶ。takeDirty が戻す。
dirty: std.atomic.Value(bool) = .init(false),
callbacks: Callbacks,
/// 今の画面の大きさ。起動時の顔を中央に置くのに使う。
size: std.atomic.Value(u32),
/// シェルの出力を読み始める前に、起動時の顔を描くか。
show_intro: bool,
/// 起動時の顔の下と、消えたあとの 1 行目に出すお知らせ（更新があることなど）。mutex で守る。
intro_note: [160]u8 = undefined,
intro_note_len: usize = 0,

pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,
    /// 画面が変わった。読み取りスレッドから呼ばれる。
    on_wakeup: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
    /// 子プロセスが終了した。読み取りスレッドから呼ばれる。
    on_exit: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

/// キーを 1 回押した（離した）こと。Sources/CUpaaCore の UpaaKeyEvent と同じ並び。
pub const KeyEvent = extern struct {
    /// macOS の仮想キーコード。
    key_code: u16,
    action: Action,
    /// Mods の値を足し合わせたもの。
    mods: u8 = 0,
    /// 修飾キーなしで同じキーを押したときの文字。分からなければ 0。
    unshifted_codepoint: u32 = 0,
    /// このキーで入力される文字（UTF-8）。無ければ null。
    text: ?[*]const u8 = null,
    text_len: usize = 0,

    pub const Action = enum(u8) { release = 0, press = 1, repeat = 2 };

    pub const Mods = struct {
        pub const shift = 1 << 0;
        pub const ctrl = 1 << 1;
        pub const alt = 1 << 2;
        pub const super = 1 << 3;
    };
};

pub const Options = struct {
    size: Pty.Size,
    /// null ならログインシェル。
    command: ?[*:0]const u8 = null,
    /// シェルの出力を読み始める前に、起動時の顔を描く。
    intro: bool = false,
    callbacks: Callbacks = .{},
};

pub fn create(opts: Options) !*Session {
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);

    var terminal: vt.GhosttyTerminal = null;
    if (vt.ghostty_terminal_new(null, &terminal, opts.size.cols, opts.size.rows) != vt.GHOSTTY_SUCCESS)
        return error.TerminalFailed;
    errdefer vt.ghostty_terminal_free(terminal);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&onWritePty));

    var key_encoder: vt.GhosttyKeyEncoder = null;
    if (vt.ghostty_key_encoder_new(null, &key_encoder) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_encoder_free(key_encoder);
    var key_event: vt.GhosttyKeyEvent = null;
    if (vt.ghostty_key_event_new(null, &key_event) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_event_free(key_event);

    var stop_pipe: [2]c_int = undefined;
    if (c.pipe(&stop_pipe) != 0) return error.PipeFailed;
    errdefer for (stop_pipe) |fd| {
        _ = c.close(fd);
    };

    const pty = try Pty.spawn(opts.command, opts.size);
    errdefer pty.deinit();

    self.* = .{
        .pty = pty,
        .terminal = terminal,
        .key_encoder = key_encoder,
        .key_event = key_event,
        .thread = undefined,
        .stop_pipe = stop_pipe,
        .callbacks = opts.callbacks,
        .size = .init(packSize(opts.size)),
        .show_intro = opts.intro,
    };
    self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

pub fn destroy(self: *Session) void {
    _ = c.write(self.stop_pipe[1], "x", 1);
    self.thread.join();
    self.pty.deinit();
    for (self.stop_pipe) |fd| _ = c.close(fd);
    vt.ghostty_key_event_free(self.key_event);
    vt.ghostty_key_encoder_free(self.key_encoder);
    vt.ghostty_terminal_free(self.terminal);
    alloc.destroy(self);
}

/// 子プロセスへの入力（キー入力をエンコードしたバイト列など）。
pub fn write(self: *Session, bytes: []const u8) void {
    _ = self.pty.writeAll(bytes);
}

/// キー入力を、端末の今のモード（カーソルキーのモードなど）に合わせたバイト列にして子プロセスへ送る。
pub fn key(self: *Session, event: KeyEvent) void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    {
        self.lock();
        defer self.unlock();

        const text_len = if (event.text == null) 0 else event.text_len;
        // 文字になったキーでは、Shift と Option はその文字を作るのに使われている。
        const consumed: u8 = if (text_len > 0) event.mods & (KeyEvent.Mods.shift | KeyEvent.Mods.alt) else 0;

        const ev = self.key_event;
        _ = vt.ghostty_key_event_set_action(ev, @intFromEnum(event.action));
        _ = vt.ghostty_key_event_set_key(ev, keymap.fromMacKeyCode(event.key_code));
        _ = vt.ghostty_key_event_set_mods(ev, event.mods);
        _ = vt.ghostty_key_event_set_consumed_mods(ev, consumed);
        _ = vt.ghostty_key_event_set_unshifted_codepoint(ev, event.unshifted_codepoint);
        _ = vt.ghostty_key_event_set_composing(ev, false);
        _ = vt.ghostty_key_event_set_utf8(ev, .{ .ptr = event.text, .len = text_len });

        _ = vt.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.terminal);
        if (vt.ghostty_key_encoder_encode(self.key_encoder, ev, &buf, buf.len, &len) != vt.GHOSTTY_SUCCESS) return;
    }
    if (len > 0) self.write(buf[0..len]);
}

pub fn resize(self: *Session, size: Pty.Size, cell_width_px: u32, cell_height_px: u32) void {
    self.lock();
    defer self.unlock();
    _ = vt.ghostty_terminal_resize(self.terminal, size.cols, size.rows, cell_width_px, cell_height_px);
    self.pty.resize(size);
    self.size.store(packSize(size), .release);
}

/// 起動時の顔と一緒に出すお知らせを決める。顔を流し終えたあとに呼んでも何も起きない。
pub fn setIntroNote(self: *Session, text: []const u8) void {
    self.lock();
    defer self.unlock();
    const n = @min(text.len, self.intro_note.len);
    @memcpy(self.intro_note[0..n], text[0..n]);
    self.intro_note_len = n;
}

fn copyIntroNote(self: *Session, out: []u8) []const u8 {
    self.lock();
    defer self.unlock();
    const n = @min(self.intro_note_len, out.len);
    @memcpy(out[0..n], self.intro_note[0..n]);
    return out[0..n];
}

/// 前回の呼び出しから画面が変わっていれば true。次の on_wakeup を受け取れる状態に戻す。
pub fn takeDirty(self: *Session) bool {
    return self.dirty.swap(false, .acq_rel);
}

/// 描画用の状態を今の画面に合わせる。端末に触るあいだだけロックを持つ。
pub fn updateRenderState(self: *Session, state: vt.GhosttyRenderState) bool {
    {
        self.lock();
        defer self.unlock();
        if (vt.ghostty_render_state_begin_update(state, self.terminal) != vt.GHOSTTY_SUCCESS) return false;
    }
    return vt.ghostty_render_state_end_update(state) == vt.GHOSTTY_SUCCESS;
}

/// 画面をプレーンテキストにして out に書く。戻り値は本来の長さ。
pub fn plainText(self: *Session, out: []u8) ?usize {
    self.lock();
    defer self.unlock();

    var formatter: vt.GhosttyFormatter = null;
    if (vt.ghostty_formatter_terminal_new(null, &formatter, self.terminal) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_formatter_free(formatter);

    var buf: [*c]u8 = null;
    var n: usize = 0;
    if (vt.ghostty_formatter_format_alloc(formatter, null, &buf, &n) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_free(null, buf, n);

    const m = @min(n, out.len);
    if (m > 0) @memcpy(out[0..m], buf[0..m]);
    return n;
}

fn lock(self: *Session) void {
    _ = std.c.pthread_mutex_lock(&self.mutex);
}

fn unlock(self: *Session) void {
    _ = std.c.pthread_mutex_unlock(&self.mutex);
}

fn packSize(size: Pty.Size) u32 {
    return @as(u32, size.cols) << 16 | size.rows;
}

/// 端末に直接書き込み、画面が変わったことを伝える。
fn feed(self: *Session, bytes: []const u8) void {
    self.lock();
    vt.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    self.unlock();

    if (!self.dirty.swap(true, .acq_rel)) {
        if (self.callbacks.on_wakeup) |f| f(self.callbacks.userdata);
    }
}

/// 起動時の顔を 1 コマずつ描く。その間のシェルの出力は PTY に溜まっていて、終わってから読む。
/// 途中で止めるよう言われたら false。
fn playIntro(self: *Session) bool {
    var buf: [1024]u8 = undefined;
    var note_buf: [160]u8 = undefined;
    var stop = [_]c.struct_pollfd{.{ .fd = self.stop_pipe[0], .events = c.POLLIN, .revents = 0 }};
    for (0..intro.frame_count) |index| {
        const size = self.size.load(.acquire);
        const note = self.copyIntroNote(&note_buf);
        self.feed(intro.frame(&buf, @intCast(size >> 16), @truncate(size), index, note));
        if (c.poll(&stop, 1, intro.frame_ms) > 0) return false;
    }
    self.feed(intro.finish(&buf, self.copyIntroNote(&note_buf)));
    return true;
}

fn readLoop(self: *Session) void {
    if (self.show_intro and !self.playIntro()) return;

    var buf: [64 * 1024]u8 = undefined;
    var fds = [_]c.struct_pollfd{
        .{ .fd = self.pty.master, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.stop_pipe[0], .events = c.POLLIN, .revents = 0 },
    };
    while (true) {
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            break;
        }
        if (fds[1].revents != 0) return;

        const n = c.read(self.pty.master, &buf, buf.len);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        // 子が終了すると 0 か EIO が返る。
        if (n <= 0) break;

        self.feed(buf[0..@intCast(n)]);
    }
    if (self.callbacks.on_exit) |f| f(self.callbacks.userdata);
}

/// 端末がプログラムに返信したいバイト列（カーソル位置の問い合わせへの答えなど）。
/// ghostty_terminal_vt_write の中から呼ばれるので、mutex は取得済み。
fn onWritePty(_: vt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(userdata orelse return));
    _ = self.pty.writeAll(data[0..len]);
}

fn waitForText(self: *Session, needle: []const u8, out: []u8) !void {
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        const n = self.plainText(out) orelse return error.FormatFailed;
        if (std.mem.indexOf(u8, out[0..@min(n, out.len)], needle) != null) return;
        _ = c.usleep(10 * 1000);
    }
    return error.Timeout;
}

test "shell output reaches the terminal" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();

    // 入力のエコーと区別できるよう、シェルに計算させた結果を待つ。
    self.write("echo upaa-$((40+2))\n");
    var out: [4096]u8 = undefined;
    try self.waitForText("upaa-42", &out);
    try std.testing.expect(self.takeDirty());
}

test "resize is visible to the child" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();

    self.resize(.{ .cols = 100, .rows = 30 }, 8, 16);
    self.write("stty size\n");
    var out: [4096]u8 = undefined;
    try self.waitForText("30 100", &out);
}

fn typeText(self: *Session, text: []const u8) void {
    for (text) |ch| self.key(.{ .key_code = 0xFFFF, .action = .press, .text = @ptrCast(&ch), .text_len = 1 });
}

test "keys are encoded for the child" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();
    var out: [4096]u8 = undefined;

    // Ctrl+C（キーコード 8 は C）で sleep が止まり、次のコマンドが実行される。
    self.typeText("sleep 100");
    self.key(.{ .key_code = 36, .action = .press });
    _ = c.usleep(200 * 1000);
    self.key(.{ .key_code = 8, .action = .press, .mods = KeyEvent.Mods.ctrl, .unshifted_codepoint = 'c' });
    self.typeText("echo key-$((1+1))");
    self.key(.{ .key_code = 36, .action = .press });
    try self.waitForText("key-2", &out);
}

test "intro is drawn before the shell output" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "echo after-intro; sleep 5", .intro = true });
    defer self.destroy();
    var out: [4096]u8 = undefined;

    try self.waitForText("upaa", &out);
    try std.testing.expect(std.mem.indexOf(u8, &out, "after-intro") == null);
    // 顔が消えてから、溜まっていたシェルの出力が出る。
    try self.waitForText("after-intro", &out);
    const n = self.plainText(&out).?;
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "upaa") == null);
}

test "intro note stays on the first line after the face is gone" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "echo after-intro; sleep 5", .intro = true });
    defer self.destroy();
    self.setIntroNote("v9.9.9 is out");
    var out: [4096]u8 = undefined;

    try self.waitForText("after-intro", &out);
    const n = self.plainText(&out).?;
    try std.testing.expect(std.mem.startsWith(u8, out[0..n], "v9.9.9 is out\nafter-intro"));
}
