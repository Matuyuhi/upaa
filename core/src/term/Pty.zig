//! PTY と、その上で動く子プロセス（シェル）。
const Pty = @This();

const std = @import("std");
const c = @import("posix");

/// 親側の fd。読むと子の出力、書くと子への入力になる。
master: c_int,
child: c.pid_t,

pub const Size = struct {
    cols: u16,
    rows: u16,
    width_px: u16 = 0,
    height_px: u16 = 0,

    fn winsize(size: Size) c.struct_winsize {
        return .{ .ws_col = size.cols, .ws_row = size.rows, .ws_xpixel = size.width_px, .ws_ypixel = size.height_px };
    }
};

pub const SpawnError = error{ ForkFailed, NoShell };

/// command が null ならユーザーのログインシェルをログインシェルとして起動する。
/// null でなければ、そのパスを引数なしで起動する（テスト用）。
pub fn spawn(command: ?[*:0]const u8, size: Size) SpawnError!Pty {
    // fork と exec の間では malloc できないので、必要な文字列は fork の前に作る。
    const path: [*:0]const u8 = command orelse loginShell() orelse return error.NoShell;
    var argv0_buf: [256]u8 = undefined;
    const argv0: [*:0]const u8 = if (command == null) loginArgv0(path, &argv0_buf) else path;
    const home: ?[*:0]const u8 = c.getenv("HOME");

    var ws = size.winsize();
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // 子プロセス。ここから exec までは async-signal-safe な関数だけを呼ぶ。
        if (home) |dir| _ = c.chdir(dir);
        _ = c.setenv("TERM", "xterm-256color", 1);
        var argv = [_:null]?[*:0]const u8{argv0};
        _ = c.execv(path, @ptrCast(&argv));
        c._exit(127);
    }
    return .{ .master = master, .child = pid };
}

pub fn resize(pty: Pty, size: Size) void {
    var ws = size.winsize();
    _ = c.ioctl(pty.master, c.TIOCSWINSZ, &ws);
}

/// 全部書けるまで繰り返す。子が終了しているなどで書けなければ false。
pub fn writeAll(pty: Pty, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(pty.master, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return false;
        }
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// 子プロセスを終わらせて回収し、fd を閉じる。
pub fn deinit(pty: Pty) void {
    _ = c.kill(pty.child, c.SIGHUP);
    _ = c.close(pty.master);
    var status: c_int = 0;
    _ = c.waitpid(pty.child, &status, 0);
}

fn loginShell() ?[*:0]const u8 {
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.*.pw_shell) |shell| {
            if (shell[0] != 0) return shell;
        }
    }
    return c.getenv("SHELL");
}

/// ログインシェルとして起動する慣習どおり、argv[0] を "-zsh" の形にする。
fn loginArgv0(path: [*:0]const u8, buf: []u8) [*:0]const u8 {
    const full = std.mem.span(path);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| full[i + 1 ..] else full;
    if (base.len + 2 > buf.len) return path;
    buf[0] = '-';
    @memcpy(buf[1..][0..base.len], base);
    buf[1 + base.len] = 0;
    return @ptrCast(buf.ptr);
}

test "login argv0" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", std.mem.span(loginArgv0("/bin/zsh", &buf)));
}
