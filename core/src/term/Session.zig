//! 端末 1 つ分。PTY、読み取りスレッド、libghostty-vt の端末をまとめて持つ。
//!
//! 端末（terminal）に触るのは必ず mutex を取ってから。libghostty-vt の端末はスレッドセーフではなく、
//! 読み取りスレッド（PTY の出力を書き込む）と呼び出し側のスレッド（リサイズ、描画）の両方から触るため。
const Session = @This();

const std = @import("std");
const c = @import("posix");
const vt = @import("ghostty");
const Pty = @import("Pty.zig");

const alloc = std.heap.c_allocator;

pty: Pty,
terminal: vt.GhosttyTerminal,
mutex: std.c.pthread_mutex_t = .{},
thread: std.Thread,
/// 読み取りスレッドを止めるためのパイプ。書くと poll が起きる。
stop_pipe: [2]c_int,
/// 画面が変わったことをまだ伝えていないときだけ on_wakeup を呼ぶ。takeDirty が戻す。
dirty: std.atomic.Value(bool) = .init(false),
callbacks: Callbacks,

pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,
    /// 画面が変わった。読み取りスレッドから呼ばれる。
    on_wakeup: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
    /// 子プロセスが終了した。読み取りスレッドから呼ばれる。
    on_exit: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

pub const Options = struct {
    size: Pty.Size,
    /// null ならログインシェル。
    command: ?[*:0]const u8 = null,
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
        .thread = undefined,
        .stop_pipe = stop_pipe,
        .callbacks = opts.callbacks,
    };
    self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

pub fn destroy(self: *Session) void {
    _ = c.write(self.stop_pipe[1], "x", 1);
    self.thread.join();
    self.pty.deinit();
    for (self.stop_pipe) |fd| _ = c.close(fd);
    vt.ghostty_terminal_free(self.terminal);
    alloc.destroy(self);
}

/// 子プロセスへの入力（キー入力をエンコードしたバイト列など）。
pub fn write(self: *Session, bytes: []const u8) void {
    _ = self.pty.writeAll(bytes);
}

pub fn resize(self: *Session, size: Pty.Size, cell_width_px: u32, cell_height_px: u32) void {
    self.lock();
    defer self.unlock();
    _ = vt.ghostty_terminal_resize(self.terminal, size.cols, size.rows, cell_width_px, cell_height_px);
    self.pty.resize(size);
}

/// 前回の呼び出しから画面が変わっていれば true。次の on_wakeup を受け取れる状態に戻す。
pub fn takeDirty(self: *Session) bool {
    return self.dirty.swap(false, .acq_rel);
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

fn readLoop(self: *Session) void {
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

        self.lock();
        vt.ghostty_terminal_vt_write(self.terminal, &buf, @intCast(n));
        self.unlock();

        if (!self.dirty.swap(true, .acq_rel)) {
            if (self.callbacks.on_wakeup) |f| f(self.callbacks.userdata);
        }
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
    self.write("echo wren-$((40+2))\n");
    var out: [4096]u8 = undefined;
    try self.waitForText("wren-42", &out);
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
