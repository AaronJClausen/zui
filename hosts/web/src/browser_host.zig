const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const host = @import("host.zig");
const browser_input = @import("browser_input.zig");

/// The browser's host: `HostOn` the imports of the dedicated worker that
/// runs the application and draws on the canvas the page transferred to
/// it. Its `zuiRun` never returns: it yields to the worker's event loop
/// through an import that throws, which unwinds the WebAssembly stack
/// without running its epilogues, and the worker then takes each turn,
/// and hands over each of the page's events, through the module's exports.
pub const Host = host.HostOn(BrowserPlatform);

/// When the worker takes the next turn, as `zuiWebHostSchedule`'s first
/// argument numbers it.
pub const ScheduleKind = enum(u32) { animation_frame = 0, timer = 1, input = 2, ended = 3 };

/// The worker's side of the host, through the module's imports from
/// `zui_web_host`.
pub const BrowserPlatform = struct {
    extern "zui_web_host" fn zuiWebHostNow() f64;
    extern "zui_web_host" fn zuiWebHostSchedule(kind: u32, at_milliseconds: f64) void;
    extern "zui_web_host" fn zuiWebHostWake() void;
    extern "zui_web_host" fn zuiWebHostShowCursor(name: [*]const u8, length: usize) void;
    extern "zui_web_host" fn zuiWebHostYield() noreturn;

    /// The worker's `performance.now()`.
    pub fn now(_: *BrowserPlatform) zui.Instant {
        return browser_input.instant(zuiWebHostNow());
    }

    pub fn schedule(_: *BrowserPlatform, next: host.Schedule) void {
        switch (next) {
            .animation_frame => zuiWebHostSchedule(@intFromEnum(ScheduleKind.animation_frame), 0),
            .timer => |instant| zuiWebHostSchedule(@intFromEnum(ScheduleKind.timer), @as(f64, @floatFromInt(instant.nanoseconds)) / std.time.ns_per_ms),
            .input => zuiWebHostSchedule(@intFromEnum(ScheduleKind.input), 0),
            .ended => zuiWebHostSchedule(@intFromEnum(ScheduleKind.ended), 0),
        }
    }

    /// From the worker that takes the turns, or a task's worker, which
    /// tells it; either way it answers with `zuiWebHostAnswerWake` once
    /// what it is running returns.
    pub fn wake(_: *BrowserPlatform) void {
        zuiWebHostWake();
    }

    /// Posts the CSS cursor to the page, which sets it on the canvas.
    pub fn showCursor(_: *BrowserPlatform, cursor: zui.Cursor) void {
        const name = browser_input.cursorName(cursor);
        zuiWebHostShowCursor(name.ptr, name.len);
    }

    /// Keeps the turns for the exports and yields to the worker's event
    /// loop, abandoning the frames below, which the WebAssembly stack keeps
    /// unused from then on.
    pub fn run(_: *BrowserPlatform, host_turns: host.Turns) noreturn {
        running_turns = host_turns;
        zuiWebHostYield();
    }
};

var running_turns: ?host.Turns = null;
var last_error: ?anyerror = null;
const key_name_bytes_most = 64;
var key_names: [2 * key_name_bytes_most]u8 = undefined;
var typed_text: [Host.inbox_text_capacity]u8 = undefined;
const setting_word_bytes_most = 64;
var setting_words: [2 * setting_word_bytes_most]u8 = undefined;

/// Keeps `err` for `zuiWebErrorName`, for the worker to report.
pub fn fail(err: anyerror) void {
    last_error = err;
}

fn running() ?*Host {
    const turns = running_turns orelse return null;
    return @ptrCast(@alignCast(turns.host));
}

comptime {
    if (builtin.cpu.arch.isWasm()) _ = &exports;
}

/// What the worker calls. Before the host runs, each does nothing.
const exports = struct {
    /// Takes the turn the host scheduled: false when the application
    /// failed, as `zuiWebErrorName` says.
    export fn zuiWebHostTurn() bool {
        const turns = running_turns orelse return true;
        turns.take() catch |err| {
            fail(err);
            return false;
        };
        return true;
    }

    export fn zuiWebHostAnswerWake() void {
        if (running()) |web_host| web_host.answerWake();
    }

    /// The canvas the page transferred, by the id its `FrameDrawer` is
    /// kept under, its size in CSS pixels and `devicePixelRatio`.
    export fn zuiWebHostAttachCanvas(canvas: u32, css_width: f32, css_height: f32, device_pixel_ratio: f32) void {
        if (running()) |web_host| web_host.attachCanvas(canvas, .{ css_width, css_height }, device_pixel_ratio);
    }

    export fn zuiWebHostResize(css_width: f32, css_height: f32, device_pixel_ratio: f32) void {
        if (running()) |web_host| web_host.resize(.{ css_width, css_height }, device_pixel_ratio);
    }

    /// `webglcontextlost`, whose default the worker prevented.
    export fn zuiWebHostLoseContext() void {
        if (running()) |web_host| web_host.loseContext();
    }

    /// `webglcontextrestored`, once the worker has a `FrameDrawer` on the
    /// restored context.
    export fn zuiWebHostRestoreContext() void {
        if (running()) |web_host| web_host.restoreContext();
    }

    /// The last failure, as a C string, or an empty one.
    export fn zuiWebErrorName() [*:0]const u8 {
        return if (last_error) |err| @errorName(err) else "";
    }

    /// A button pressed, as the client's export of the same name takes it.
    export fn zuiWebPointerDown(browser_pointer_id: u32, browser_kind: u32, browser_button: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
        if (running()) |web_host| web_host.pointerDown(pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds), browser_button);
    }

    export fn zuiWebPointerUp(browser_pointer_id: u32, browser_kind: u32, browser_button: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
        if (running()) |web_host| web_host.pointerUp(pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds), browser_button);
    }

    export fn zuiWebPointerMove(browser_pointer_id: u32, browser_kind: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) void {
        if (running()) |web_host| web_host.pointerMove(pointer(browser_pointer_id, browser_kind, x, y, pressure, tilt_x, tilt_y, at_milliseconds));
    }

    export fn zuiWebPointerCancel(browser_pointer_id: u32, browser_kind: u32) void {
        if (running()) |web_host| web_host.pointerCancel(browser_pointer_id, browser_kind);
    }

    export fn zuiWebPointerLeave(browser_pointer_id: u32, browser_kind: u32) void {
        if (running()) |web_host| web_host.pointerLeave(browser_pointer_id, browser_kind);
    }

    export fn zuiWebWheel(x: f32, y: f32, delta_x: f32, delta_y: f32, browser_delta_mode: u32, at_milliseconds: f64) void {
        if (running()) |web_host| web_host.wheel(.{ x, y }, .{ delta_x, delta_y }, browser_delta_mode, at_milliseconds);
    }

    /// Where to write a `KeyboardEvent`'s `key` in UTF-8, and its `code`
    /// `zuiWebKeyNameBytesMost` bytes after it, before `zuiWebKey`.
    export fn zuiWebKeyNames() usize {
        return @intFromPtr(&key_names);
    }

    export fn zuiWebKeyNameBytesMost() usize {
        return key_name_bytes_most;
    }

    export fn zuiWebKey(down: bool, key_bytes: usize, code_bytes: usize, browser_modifier_bits: u32, repeat: bool, at_milliseconds: f64) void {
        const key = key_names[0..@min(key_bytes, key_name_bytes_most)];
        const code = key_names[key_name_bytes_most..][0..@min(code_bytes, key_name_bytes_most)];
        if (running()) |web_host| web_host.key(down, key, code, browser_modifier_bits, repeat, at_milliseconds);
    }

    /// Where to write up to `zuiWebTypedTextBytesMost` bytes of committed
    /// UTF-8 before `zuiWebTyped`.
    export fn zuiWebTypedText() usize {
        return @intFromPtr(&typed_text);
    }

    export fn zuiWebTypedTextBytesMost() usize {
        return typed_text.len;
    }

    export fn zuiWebTyped(count: usize) void {
        if (running()) |web_host| web_host.typed(typed_text[0..@min(count, typed_text.len)]);
    }

    /// Where to write a setting's name in UTF-8, and its value as text
    /// `zuiWebSettingWordBytesMost` bytes after it, before `zuiWebSetting`.
    export fn zuiWebSettingWords() usize {
        return @intFromPtr(&setting_words);
    }

    export fn zuiWebSettingWordBytesMost() usize {
        return setting_word_bytes_most;
    }

    /// One of the page's settings, as `zui_web.PageEnvironment.set` reads it.
    export fn zuiWebSetting(name_bytes: usize, value_bytes: usize) void {
        const name = setting_words[0..@min(name_bytes, setting_word_bytes_most)];
        const value = setting_words[setting_word_bytes_most..][0..@min(value_bytes, setting_word_bytes_most)];
        if (running()) |web_host| web_host.changeSetting(name, value);
    }

    /// `document.visibilityState` is `"visible"`, or it is not.
    export fn zuiWebPageShown(shown: bool) void {
        if (running()) |web_host| web_host.showPage(shown);
    }

    fn pointer(browser_pointer_id: u32, browser_kind: u32, x: f32, y: f32, pressure: f32, tilt_x: f32, tilt_y: f32, at_milliseconds: f64) host.BrowserPointer {
        return .{ .id = browser_pointer_id, .kind = browser_kind, .position = .{ x, y }, .pressure = pressure, .tilt_degrees = .{ tilt_x, tilt_y }, .at_milliseconds = at_milliseconds };
    }
};

comptime {
    zui.checkHost(Host);
}
