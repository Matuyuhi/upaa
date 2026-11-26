//! PTY and the child process (shell) running on it.
const Pty = @This();

const std = @import("std");
const c = @import("posix");

/// Parent-side fd. Reads get the child's output; writes become input to the child.
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

/// If command is null, starts the user's login shell as a login shell in the home directory.
/// If not null, runs /bin/sh -c command in the current directory (for tests and screen dumps).
pub fn spawn(command: ?[*:0]const u8, size: Size) SpawnError!Pty {
    // malloc is not allowed between fork and exec, so build the needed strings before fork.
    const path: [*:0]const u8 = if (command == null) loginShell() orelse return error.NoShell else "/bin/sh";
    var argv0_buf: [256]u8 = undefined;
    var argv: [4:null]?[*:0]const u8 = if (command) |cmd|
        .{ "sh", "-c", cmd, null }
    else
        .{ loginArgv0(path, &argv0_buf), null, null, null };
    const home: ?[*:0]const u8 = if (command == null) c.getenv("HOME") else null;

    var ws = size.winsize();
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child process. From here to exec, call only async-signal-safe functions.
        if (home) |dir| _ = c.chdir(dir);
        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.execv(path, @ptrCast(&argv));
        c._exit(127);
    }
    return .{ .master = master, .child = pid };
}

pub fn resize(pty: Pty, size: Size) void {
    var ws = size.winsize();
    _ = c.ioctl(pty.master, c.TIOCSWINSZ, &ws);
}

/// Repeats until everything is written. Returns false if writing fails, e.g. because the child has exited.
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

/// Terminates the child process, reaps it, and closes the fd.
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

/// Sets argv[0] to the "-zsh" form, following the convention for starting a login shell.
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
