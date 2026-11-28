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

pub const SpawnError = error{ ForkFailed, NoShell, OutOfMemory };

/// If command is null, starts the user's login shell as a login shell, in start_dir or else the home directory.
/// If not null, runs /bin/sh -c command in start_dir or else the current directory (for tests and screen dumps).
/// integration_dir is the directory with upaa's startup files for zsh, bash and fish (Resources/shell-integration).
/// A login shell that is one of them is pointed at its files there, as integrationFor says.
pub fn spawn(command: ?[*:0]const u8, start_dir: ?[*:0]const u8, size: Size, integration_dir: ?[*:0]const u8) SpawnError!Pty {
    // malloc is not allowed between fork and exec, so build the needed strings before fork.
    const path: [*:0]const u8 = if (command == null) loginShell() orelse return error.NoShell else "/bin/sh";
    var argv0_buf: [256]u8 = undefined;
    var argv: [4:null]?[*:0]const u8 = if (command) |cmd|
        .{ "sh", "-c", cmd, null }
    else
        .{ loginArgv0(path, &argv0_buf), null, null, null };
    const dir: ?[*:0]const u8 = start_dir orelse if (command == null) c.getenv("HOME") else null;
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const integration: ?Integration = if (command == null and integration_dir != null)
        try integrationFor(arena.allocator(), path, std.mem.span(integration_dir.?))
    else
        null;
    // bash reads the file in ENV only when it starts in POSIX mode.
    if (integration != null and std.mem.eql(u8, integration.?.name, "ENV")) argv[1] = "--posix";
    const env = try childEnv(arena.allocator(), integration);

    var ws = size.winsize();
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child process. From here to exec, call only async-signal-safe functions.
        if (dir) |d| _ = c.chdir(d);
        _ = c.execve(path, @ptrCast(&argv), @ptrCast(env.ptr));
        c._exit(127);
    }
    return .{ .master = master, .child = pid };
}

/// The environment variable that points a login shell at upaa's startup files, and its value. The shell's startup
/// files find the user's own value in UPAA_ and the name, unset if the user had none, and put it back.
const Integration = struct { name: []const u8, value: [:0]const u8 };

/// zsh reads ZDOTDIR/.zshenv first. bash, started in POSIX mode, reads only the file in ENV; Apple's /bin/bash (3.2)
/// does not read it there, so it starts as it is, as in Ghostty. fish loads fish/vendor_conf.d from each directory in
/// XDG_DATA_DIRS, so upaa's goes first, before the user's or else fish's default ones. null for other shells.
fn integrationFor(arena: std.mem.Allocator, shell: [*:0]const u8, dir: []const u8) error{OutOfMemory}!?Integration {
    const full = std.mem.span(shell);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| full[i + 1 ..] else full;
    if (std.mem.eql(u8, base, "zsh"))
        return .{ .name = "ZDOTDIR", .value = try std.fmt.allocPrintSentinel(arena, "{s}/zsh", .{dir}, 0) };
    if (std.mem.eql(u8, base, "bash") and !std.mem.eql(u8, full, "/bin/bash"))
        return .{ .name = "ENV", .value = try std.fmt.allocPrintSentinel(arena, "{s}/bash/upaa.bash", .{dir}, 0) };
    if (std.mem.eql(u8, base, "fish")) {
        const old: ?[*:0]const u8 = c.getenv("XDG_DATA_DIRS");
        const rest = if (old != null and old.?[0] != 0) std.mem.span(old.?) else "/usr/local/share:/usr/share";
        return .{ .name = "XDG_DATA_DIRS", .value = try std.fmt.allocPrintSentinel(arena, "{s}:{s}", .{ dir, rest }, 0) };
    }
    return null;
}

/// The child's environment: this process's, with TERM set, and with the integration's variable set if it is not null,
/// the old value moved to UPAA_ and the name. Built before fork, because setenv may allocate.
fn childEnv(arena: std.mem.Allocator, integration: ?Integration) error{OutOfMemory}![:null]?[*:0]const u8 {
    const environ: [*:null]?[*:0]const u8 = @ptrCast(c._NSGetEnviron().*);
    const count = std.mem.len(environ);
    // Room for every entry, TERM, the integration's variable and the null at the end.
    const env = try arena.allocSentinel(?[*:0]const u8, count + 3, null);
    var n: usize = 0;
    for (environ[0..count]) |entry| {
        const s = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, s, "TERM=")) continue;
        if (integration) |i| {
            if (isVariable(s, i.name)) {
                env[n] = (try std.fmt.allocPrintSentinel(arena, "UPAA_{s}", .{s}, 0)).ptr;
                n += 1;
                continue;
            }
            if (std.mem.startsWith(u8, s, "UPAA_") and isVariable(s[5..], i.name)) continue;
        }
        env[n] = entry;
        n += 1;
    }
    env[n] = "TERM=xterm-256color";
    n += 1;
    if (integration) |i| {
        env[n] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ i.name, i.value }, 0)).ptr;
        n += 1;
    }
    env[n] = null;
    return env[0..n :null];
}

/// Whether the environment entry sets the variable.
fn isVariable(entry: []const u8, name: []const u8) bool {
    return entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name);
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

/// The child's current directory, read from the kernel, so the shell needs no setup to report it. null if unknown.
pub fn cwd(pty: Pty, out: []u8) ?[]const u8 {
    var info: c.struct_proc_vnodepathinfo = undefined;
    const size: c_int = @sizeOf(c.struct_proc_vnodepathinfo);
    if (c.proc_pidinfo(pty.child, c.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) return null;
    const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (path.len == 0 or path.len > out.len) return null;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

/// The name of the program in the terminal's foreground when it is not the shell (a command the shell started), copied
/// into out; "" when its name cannot be read. null while the shell itself has the terminal.
pub fn running(pty: Pty, out: []u8) ?[]const u8 {
    const group = c.tcgetpgrp(pty.master);
    if (group <= 0 or group == pty.child) return null;
    const n = c.proc_name(group, out.ptr, @intCast(out.len));
    if (n > 0) return out[0..@intCast(n)];
    // proc_name reads only the user's own processes, and a setuid program (top, sudo) runs as root. The kernel's
    // process table, which ps reads, gives any process's name, cut to 16 bytes.
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID, group };
    var info: c.struct_kinfo_proc = undefined;
    var size: usize = @sizeOf(c.struct_kinfo_proc);
    if (c.sysctl(&mib, mib.len, &info, &size, null, 0) != 0 or size == 0) return out[0..0];
    const name = std.mem.sliceTo(&info.kp_proc.p_comm, 0);
    const len = @min(name.len, out.len);
    @memcpy(out[0..len], name[0..len]);
    return out[0..len];
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

test "bash is started with upaa's file, but not Apple's /bin/bash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bash = (try integrationFor(arena.allocator(), "/opt/homebrew/bin/bash", "/upaa")).?;
    try std.testing.expectEqualStrings("/upaa/bash/upaa.bash", bash.value);
    try std.testing.expect(try integrationFor(arena.allocator(), "/bin/bash", "/upaa") == null);
}

test "the child's environment sets TERM and ZDOTDIR once each" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var terms: usize = 0;
    var zdotdirs: usize = 0;
    for (try childEnv(arena.allocator(), .{ .name = "ZDOTDIR", .value = "/upaa/zsh" })) |entry| {
        const s = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, s, "TERM=")) {
            try std.testing.expectEqualStrings("TERM=xterm-256color", s);
            terms += 1;
        }
        if (std.mem.startsWith(u8, s, "ZDOTDIR=")) {
            try std.testing.expectEqualStrings("ZDOTDIR=/upaa/zsh", s);
            zdotdirs += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), terms);
    try std.testing.expectEqual(@as(usize, 1), zdotdirs);
}
