//! One terminal: bundles the PTY, the read thread, and the libghostty-vt terminal.
//!
//! Always take the mutex before touching the terminal. The libghostty-vt terminal is not thread-safe,
//! and it is touched from both the read thread (which writes PTY output) and the caller's thread (resize, drawing).
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
/// Interprets mouse presses and drags as text selection (clicks, double and triple clicks, autoscroll).
gesture: vt.GhosttySelectionGesture,
mutex: std.c.pthread_mutex_t = .{},
thread: std.Thread,
/// Pipe to stop the read thread. Writing to it wakes poll.
stop_pipe: [2]c_int,
/// Calls on_wakeup only when the screen change has not been reported yet. takeDirty resets it.
dirty: std.atomic.Value(bool) = .init(false),
callbacks: Callbacks,
/// Current screen size. Used to center the startup face.
size: std.atomic.Value(u32),
/// Whether to draw the startup face before reading shell output.
show_intro: bool,
/// Notice shown below the startup face and on line 1 after it disappears (e.g. an update is available). Guarded by the mutex.
intro_note: [160]u8 = undefined,
intro_note_len: usize = 0,

pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,
    /// The screen changed. Called from the read thread.
    on_wakeup: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
    /// The child process exited. Called from the read thread.
    on_exit: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

/// One key press (release). Same layout as UpaaKeyEvent in Sources/CUpaaCore.
pub const KeyEvent = extern struct {
    /// macOS virtual key code.
    key_code: u16,
    action: Action,
    /// The sum of the Mods values.
    mods: u8 = 0,
    /// Character for the same key pressed without modifiers. 0 if unknown.
    unshifted_codepoint: u32 = 0,
    /// Text this key produces (UTF-8). null if none.
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

/// A mouse event for selecting text. Same layout as UpaaPointer in Sources/CUpaaCore.
pub const Pointer = extern struct {
    kind: Kind,
    /// Option held: select a rectangle instead of running text.
    rectangle: bool = false,
    /// Position in drawable pixels from the top-left of the view.
    x: f64,
    y: f64,
    /// Monotonic event time, and the longest gap and distance between clicks that still count as a double or triple click.
    time_ns: u64 = 0,
    repeat_interval_ns: u64 = 0,
    repeat_distance: f64 = 0,
    cols: u32,
    rows: u32,
    cell_width: u32,
    cell_height: u32,
    padding_left: u32 = 0,
    padding_top: u32 = 0,
    /// Height of the whole view in pixels. Dragging past it asks for autoscroll.
    screen_height: u32,

    pub const Kind = enum(u8) { press = 0, drag = 1, release = 2, autoscroll = 3 };
};

pub const Options = struct {
    size: Pty.Size,
    /// null means the login shell.
    command: ?[*:0]const u8 = null,
    /// Draws the startup face before reading shell output.
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
    // The library default (10,000 bytes) keeps only a few hundred lines of scrollback.
    var scrollback: usize = 10 * 1024 * 1024;
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback);

    var key_encoder: vt.GhosttyKeyEncoder = null;
    if (vt.ghostty_key_encoder_new(null, &key_encoder) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_encoder_free(key_encoder);
    var key_event: vt.GhosttyKeyEvent = null;
    if (vt.ghostty_key_event_new(null, &key_event) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_event_free(key_event);

    var gesture: vt.GhosttySelectionGesture = null;
    if (vt.ghostty_selection_gesture_new(null, &gesture) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_selection_gesture_free(gesture, terminal);

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
        .gesture = gesture,
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
    vt.ghostty_selection_gesture_free(self.gesture, self.terminal);
    vt.ghostty_key_event_free(self.key_event);
    vt.ghostty_key_encoder_free(self.key_encoder);
    vt.ghostty_terminal_free(self.terminal);
    alloc.destroy(self);
}

/// Input to the child process (e.g. bytes encoding a key press).
pub fn write(self: *Session, bytes: []const u8) void {
    // Typing brings the view back to the live screen if it was scrolled into the scrollback.
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    _ = self.pty.writeAll(bytes);
}

/// Moves the view through the scrollback. Up is a negative delta.
pub fn scroll(self: *Session, behavior: vt.GhosttyTerminalScrollViewport) void {
    self.lock();
    defer self.unlock();
    _ = vt.ghostty_terminal_scroll_viewport(self.terminal, behavior);
}

/// Turns a key press into bytes matching the terminal's current mode (e.g. cursor key mode), and sends them to the child process.
pub fn key(self: *Session, event: KeyEvent) void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    {
        self.lock();
        defer self.unlock();

        const text_len = if (event.text == null) 0 else event.text_len;
        // For keys that produce a character, Shift and Option are already used to make that character.
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

/// Decides the notice shown with the startup face. Calling this after the face has finished playing does nothing.
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

/// True if the screen changed since the previous call. Resets so that the next on_wakeup is received.
pub fn takeDirty(self: *Session) bool {
    return self.dirty.swap(false, .acq_rel);
}

/// Syncs the render state with the current screen. Holds the lock only while touching the terminal.
pub fn updateRenderState(self: *Session, state: vt.GhosttyRenderState) bool {
    {
        self.lock();
        defer self.unlock();
        if (vt.ghostty_render_state_begin_update(state, self.terminal) != vt.GHOSTTY_SUCCESS) return false;
    }
    return vt.ghostty_render_state_end_update(state) == vt.GHOSTTY_SUCCESS;
}

pub const PasteResult = enum(u8) { pasted = 0, rejected = 1, failed = 2 };

/// Pastes text into the shell, framed for the terminal's current mode (bracketed paste when the program asks for it).
/// Text that could run a command by itself (a line break outside bracketed paste, or the end-of-paste sequence) is
/// rejected unless allow_unsafe is set: ask the user, then call again with allow_unsafe.
pub fn paste(self: *Session, text: []const u8, allow_unsafe: bool) PasteResult {
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    self.lock();
    defer self.unlock();

    var source = text;
    const mime: vt.GhosttyString = .{ .ptr = "text/plain", .len = "text/plain".len };
    const request: vt.GhosttyPaste = .{
        .size = @sizeOf(vt.GhosttyPaste),
        .location = vt.GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
        .source = vt.GHOSTTY_PASTE_SOURCE_CLIPBOARD,
        .mimes = &mime,
        .mimes_len = 1,
        .reader = .{ .read = readPasteText, .userdata = @ptrCast(&source) },
        .allow_unsafe = allow_unsafe,
    };
    // The encoded bytes come back through onWritePty, which writes them to the PTY.
    return switch (vt.ghostty_terminal_paste(self.terminal, &request, null)) {
        vt.GHOSTTY_SUCCESS => .pasted,
        vt.GHOSTTY_REJECTED => .rejected,
        else => .failed,
    };
}

fn readPasteText(userdata: ?*anyopaque, _: vt.GhosttyString, writer: vt.GhosttyWriter) callconv(.c) bool {
    const text: *const []const u8 = @ptrCast(@alignCast(userdata orelse return false));
    const writeFn = writer.write orelse return false;
    return writeFn(writer.userdata, text.*.ptr, text.*.len);
}

/// The live screen (without the scrollback) as plain text, written to out. Returns the full length.
pub fn plainText(self: *Session, out: []u8) ?usize {
    self.lock();
    defer self.unlock();

    var cols: u16 = 0;
    var rows: u16 = 0;
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_COLS, &cols);
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    var screen = std.mem.zeroes(vt.GhosttySelection);
    if (vt.ghostty_terminal_grid_ref(self.terminal, activePoint(0, 0), &screen.start) != vt.GHOSTTY_SUCCESS) return null;
    if (vt.ghostty_terminal_grid_ref(self.terminal, activePoint(cols - 1, rows - 1), &screen.end) != vt.GHOSTTY_SUCCESS) return null;
    return self.format(&screen, out);
}

/// The selected text, written to out. Returns the full length; 0 if nothing is selected.
pub fn selectionText(self: *Session, out: []u8) ?usize {
    self.lock();
    defer self.unlock();
    var selection: vt.GhosttySelection = undefined;
    if (vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SELECTION, &selection) != vt.GHOSTTY_SUCCESS) return 0;
    return self.format(&selection, out);
}

pub fn selectAll(self: *Session) void {
    self.lock();
    defer self.unlock();
    var selection: vt.GhosttySelection = undefined;
    if (vt.ghostty_terminal_select_all(self.terminal, &selection) == vt.GHOSTTY_SUCCESS)
        _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

/// Feeds a mouse event to the selection gesture and makes its result the terminal's selection.
/// Returns the autoscroll direction a drag asks for (GhosttySelectionGestureAutoscroll: 0 none, 1 up, 2 down).
/// The caller sends autoscroll events from a timer while it is not 0.
pub fn select(self: *Session, p: Pointer) u8 {
    self.lock();
    defer self.unlock();

    const kind: vt.GhosttySelectionGestureEventType = switch (p.kind) {
        .press => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS,
        .drag => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG,
        .release => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE,
        .autoscroll => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
    };
    var event: vt.GhosttySelectionGestureEvent = null;
    if (vt.ghostty_selection_gesture_event_new(null, &event, kind) != vt.GHOSTTY_SUCCESS) return 0;
    defer vt.ghostty_selection_gesture_event_free(event);

    // The cell under the pointer, clamped to the grid.
    var cell: vt.GhosttyPointCoordinate = .{ .x = @intCast(cellIndex(p.x, p.padding_left, p.cell_width, p.cols)), .y = cellIndex(p.y, p.padding_top, p.cell_height, p.rows) };
    var ref: vt.GhosttyGridRef = undefined;
    const point: vt.GhosttyPoint = .{ .tag = vt.GHOSTTY_POINT_TAG_VIEWPORT, .value = .{ .coordinate = cell } };
    const has_ref = vt.ghostty_terminal_grid_ref(self.terminal, point, &ref) == vt.GHOSTTY_SUCCESS;
    var position: vt.GhosttySurfacePosition = .{ .x = p.x, .y = p.y };
    var geometry: vt.GhosttySelectionGestureGeometry = .{ .columns = p.cols, .cell_width = p.cell_width, .padding_left = p.padding_left, .screen_height = p.screen_height };
    var time_ns = p.time_ns;
    var repeat_interval_ns = p.repeat_interval_ns;
    var repeat_distance = p.repeat_distance;
    var rectangle = p.rectangle;

    if (has_ref and p.kind != .autoscroll) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
    if (p.kind != .release) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position);
    if (p.kind == .press) {
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time_ns);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeat_interval_ns);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &repeat_distance);
    }
    if (p.kind == .drag or p.kind == .autoscroll) {
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle);
    }
    if (p.kind == .autoscroll) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &cell);

    var selection: vt.GhosttySelection = undefined;
    switch (vt.ghostty_selection_gesture_event(self.gesture, self.terminal, event, &selection)) {
        vt.GHOSTTY_SUCCESS => _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection),
        // A plain click selects nothing and clears the old selection.
        vt.GHOSTTY_NO_VALUE => if (p.kind == .press) {
            _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, null);
        },
        else => {},
    }

    var autoscroll: vt.GhosttySelectionGestureAutoscroll = vt.GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
    _ = vt.ghostty_selection_gesture_get(self.gesture, self.terminal, vt.GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll);
    return @intCast(autoscroll);
}

fn cellIndex(px: f64, padding: u32, cell: u32, count: u32) u32 {
    const offset = px - @as(f64, @floatFromInt(padding));
    if (offset <= 0 or cell == 0 or count == 0) return 0;
    return @min(@as(u32, @intFromFloat(offset / @as(f64, @floatFromInt(cell)))), count - 1);
}

/// Writes the text inside selection as plain text to out. The caller holds the lock.
fn format(self: *Session, selection: *const vt.GhosttySelection, out: []u8) ?usize {
    var formatter: vt.GhosttyFormatter = null;
    if (vt.ghostty_formatter_terminal_new(null, &formatter, self.terminal) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_formatter_free(formatter);
    _ = vt.ghostty_formatter_set(formatter, vt.GHOSTTY_FORMATTER_OPT_SELECTION, selection);

    var buf: [*c]u8 = null;
    var n: usize = 0;
    if (vt.ghostty_formatter_format_alloc(formatter, null, &buf, &n) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_free(null, buf, n);

    const m = @min(n, out.len);
    if (m > 0) @memcpy(out[0..m], buf[0..m]);
    return n;
}

fn activePoint(x: u16, y: u16) vt.GhosttyPoint {
    return .{ .tag = vt.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = x, .y = y } } };
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

/// Writes directly to the terminal and signals that the screen changed.
fn feed(self: *Session, bytes: []const u8) void {
    self.lock();
    vt.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    self.unlock();

    if (!self.dirty.swap(true, .acq_rel)) {
        if (self.callbacks.on_wakeup) |f| f(self.callbacks.userdata);
    }
}

/// Draws the startup face one frame at a time. Shell output in the meantime accumulates in the PTY and is read after it finishes.
/// Returns false if told to stop partway through.
fn playIntro(self: *Session) bool {
    var buf: [4096]u8 = undefined;
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
        // When the child exits, read returns 0 or EIO.
        if (n <= 0) break;

        self.feed(buf[0..@intCast(n)]);
    }
    if (self.callbacks.on_exit) |f| f(self.callbacks.userdata);
}

/// Bytes the terminal wants to send back to the program (e.g. replies to cursor position queries).
/// Called from inside ghostty_terminal_vt_write, so the mutex is already held.
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

    // Wait for the shell to compute the result so it can be told apart from input echo.
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

    // Ctrl+C (keycode 8 is C) stops sleep, and the next command runs.
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
    // After the face disappears, the shell output that accumulated meanwhile is printed.
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

test "scrollback keeps history, and input returns to the live screen" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "seq 1 2000; echo seq-done; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("seq-done", &out);

    var bar: vt.GhosttyTerminalScrollbar = undefined;
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP, .value = .{ .delta = 0 } });
    self.lock();
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    self.unlock();
    // All 2000 lines are kept, and the view is at the top.
    try std.testing.expect(bar.total >= 2000);
    try std.testing.expectEqual(@as(u64, 0), bar.offset);

    self.write("x");
    self.lock();
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    self.unlock();
    try std.testing.expectEqual(bar.total - bar.len, bar.offset);
}

fn pointerAt(kind: Pointer.Kind, col: u32, row: u32, time_ms: u64) Pointer {
    // A 10 x 20 pixel cell on an 80 x 24 grid, pointing at the middle of the cell.
    return .{
        .kind = kind,
        .x = @floatFromInt(col * 10 + 5),
        .y = @floatFromInt(row * 20 + 10),
        .time_ns = time_ms * std.time.ns_per_ms,
        .repeat_interval_ns = 500 * std.time.ns_per_ms,
        .repeat_distance = 10,
        .cols = 80,
        .rows = 24,
        .cell_width = 10,
        .cell_height = 20,
        .screen_height = 480,
    };
}

test "mouse gestures select words, ranges and everything" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "printf 'hello world\\nsecond line\\n'; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("second line", &out);

    try std.testing.expectEqual(@as(?usize, 0), self.selectionText(&out));

    // A double click selects the word under the pointer.
    _ = self.select(pointerAt(.press, 7, 0, 1000));
    _ = self.select(pointerAt(.release, 7, 0, 1000));
    _ = self.select(pointerAt(.press, 7, 0, 1100));
    _ = self.select(pointerAt(.release, 7, 0, 1100));
    try std.testing.expectEqualStrings("world", out[0..self.selectionText(&out).?]);

    // Dragging selects from the press to the pointer, across lines. libghostty-vt includes the cell under the
    // pointer only once the pointer is past its middle, so ending in the middle of cell 6 selects "second".
    _ = self.select(pointerAt(.press, 0, 0, 5000));
    _ = self.select(pointerAt(.drag, 6, 1, 5000));
    _ = self.select(pointerAt(.release, 6, 1, 5000));
    try std.testing.expectEqualStrings("hello world\nsecond", out[0..self.selectionText(&out).?]);

    // A plain click clears the selection.
    _ = self.select(pointerAt(.press, 3, 3, 9000));
    _ = self.select(pointerAt(.release, 3, 3, 9000));
    try std.testing.expectEqual(@as(?usize, 0), self.selectionText(&out));

    self.selectAll();
    const all = out[0..self.selectionText(&out).?];
    try std.testing.expect(std.mem.indexOf(u8, all, "hello world\nsecond line") != null);
}

test "paste sends safe text, and holds back text that could run a command" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "read a; read b; echo \"got:$a/$b\"; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;

    try std.testing.expectEqual(PasteResult.pasted, self.paste("one", false));
    // A line break would press Enter, so it is rejected until the user agrees.
    try std.testing.expectEqual(PasteResult.rejected, self.paste("\ntwo\n", false));
    try std.testing.expectEqual(PasteResult.pasted, self.paste("\ntwo\n", true));
    try self.waitForText("got:one/two", &out);
}
