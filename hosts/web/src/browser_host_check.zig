//! The web host's logic built for the browser, on a platform of imports
//! that `zig build check` compiles and nothing runs, so a host that would
//! not compile for `wasm32-freestanding` fails there.

const zui = @import("zui");
const host = @import("host.zig");

const ImportedPlatform = struct {
    extern "zui_web_host_check" fn nowMilliseconds() f64;
    extern "zui_web_host_check" fn requestAnimationFrame() void;
    extern "zui_web_host_check" fn setTimer(at_milliseconds: f64) void;
    extern "zui_web_host_check" fn clearTimer() void;
    extern "zui_web_host_check" fn wakeFromAnyThread() void;
    extern "zui_web_host_check" fn showCssCursor(name: [*:0]const u8) void;
    extern "zui_web_host_check" fn yieldToEventLoop() noreturn;

    var turns: host.Turns = undefined;

    pub fn now(_: *ImportedPlatform) zui.Instant {
        return .fromNanoseconds(@intFromFloat(nowMilliseconds() * 1e6));
    }

    pub fn schedule(_: *ImportedPlatform, next: host.Schedule) void {
        switch (next) {
            .animation_frame => requestAnimationFrame(),
            .timer => |instant| setTimer(@as(f64, @floatFromInt(instant.nanoseconds)) / 1e6),
            .input, .ended => clearTimer(),
        }
    }

    pub fn wake(_: *ImportedPlatform) void {
        wakeFromAnyThread();
    }

    pub fn showCursor(_: *ImportedPlatform, cursor: zui.Cursor) void {
        showCssCursor(@import("browser_input.zig").cursorName(cursor));
    }

    pub fn run(_: *ImportedPlatform, host_turns: host.Turns) noreturn {
        turns = host_turns;
        yieldToEventLoop();
    }
};

const CheckedHost = host.HostOn(ImportedPlatform);
var checked_host: CheckedHost = .{};

comptime {
    zui.checkHost(CheckedHost);
}

export fn zuiHostCheckRun(driver_context: *anyopaque, driver_calls: *const zui.Driver.Calls) void {
    checked_host.zuiRun(undefined, .{}, .{ .context = driver_context, .calls = driver_calls });
}

export fn zuiHostCheckTurn() bool {
    ImportedPlatform.turns.take() catch return false;
    return true;
}

export fn zuiHostCheckPage(x: f32, y: f32, at_milliseconds: f64) void {
    checked_host.attachCanvas(1, .{ x, y }, 2);
    checked_host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ x, y }, .at_milliseconds = at_milliseconds });
    checked_host.pointerDown(.{ .id = 1, .kind = 0, .position = .{ x, y }, .at_milliseconds = at_milliseconds }, 0);
    checked_host.pointerUp(.{ .id = 1, .kind = 0, .position = .{ x, y }, .at_milliseconds = at_milliseconds }, 0);
    checked_host.pointerCancel(1, 0);
    checked_host.pointerLeave(1, 0);
    checked_host.wheel(.{ x, y }, .{ x, y }, 0, at_milliseconds);
    checked_host.key(true, "a", "KeyA", 0, false, at_milliseconds);
    checked_host.typed("a");
    checked_host.resize(.{ x, y }, 1);
    checked_host.loseContext();
    checked_host.restoreContext();
    checked_host.zuiApply(.main, .{ .cursor = .pointer });
    checked_host.zuiWaker().wake();
    _ = checked_host.zuiSurface(.main);
}
