const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_host = @import("zui_host");
const linux = std.os.linux;

/// Runs an application whose window is never shown in a process of its
/// own, sends it SIGTERM and then SIGINT, and fails unless each run ends
/// within a second. A window the compositor does not show gets no frame
/// callbacks, so its waits end only on input or a signal.
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 2 and std.mem.eql(u8, arguments[1], app_argument)) {
        return zui_app.run(UnshownApp, init, .{ .title = "zui terminate check", .size = .{ 160, 120 }, .visible = false });
    }
    if (init.environ_map.get("WAYLAND_DISPLAY") == null and init.environ_map.get("DISPLAY") == null) {
        std.debug.print("terminate check: skipped, no Wayland compositor or X server to connect to\n", .{});
        return;
    }
    const watchdog = try std.Thread.spawn(.{}, failAfterWatchdog, .{init.io});
    watchdog.detach();

    var every_run_ended = true;
    for ([_]std.posix.SIG{ .TERM, .INT }) |signal| {
        if (!try endsWithinDeadline(init.io, arguments[0], signal)) every_run_ended = false;
    }
    if (!every_run_ended) return error.ApplicationOutlivedTerminationSignal;
}

const app_argument = "--unshown-app";
const exit_deadline_ns = std.time.ns_per_s;
const watchdog_seconds = 30;

fn endsWithinDeadline(io: std.Io, program: []const u8, signal: std.posix.SIG) !bool {
    leaveSignalAtDefaultForChildren(signal);
    var child = try std.process.spawn(io, .{ .argv = &.{ program, app_argument }, .stdout = .pipe });
    var line_buffer: [16]u8 = undefined;
    var child_output = child.stdout.?.reader(io, &line_buffer);
    _ = child_output.interface.takeDelimiterExclusive('\n') catch {
        std.debug.print("terminate check: SIG{t}: the application ended before its first frame: {any}\n", .{ signal, try child.wait(io) });
        return false;
    };

    const pid = child.id.?;
    const process_descriptor = linux.pidfd_open(pid, 0);
    if (linux.errno(process_descriptor) != .SUCCESS) {
        child.kill(io);
        return error.PidfdUnavailable;
    }
    defer _ = linux.close(@intCast(process_descriptor));

    const sent_at = std.Io.Timestamp.now(io, .awake);
    try std.posix.kill(pid, signal);
    const ended_in_time = endsBefore(io, @intCast(process_descriptor), sent_at, exit_deadline_ns);
    if (!ended_in_time) std.posix.kill(pid, .KILL) catch {};
    const ended = try child.wait(io);
    const elapsed_ms = sent_at.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    const ended_cleanly = ended_in_time and ended == .exited and ended.exited == 0;
    if (ended_cleanly) {
        std.debug.print("terminate check: SIG{t}: an unshown window's application ended in {d} ms\n", .{ signal, elapsed_ms });
    } else {
        std.debug.print("terminate check: SIG{t}: the application did not end within {d} ms ({any}), so the host's wait outlived the signal\n", .{ signal, exit_deadline_ns / std.time.ns_per_ms, ended });
    }
    return ended_cleanly;
}

fn endsBefore(io: std.Io, process_descriptor: linux.fd_t, since: std.Io.Timestamp, within_ns: u64) bool {
    while (true) {
        const elapsed_ns: u64 = @intCast(@max(0, since.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds));
        if (elapsed_ns >= within_ns) return false;
        const remaining_ns = within_ns - elapsed_ns;
        var remaining: linux.timespec = .{ .sec = @intCast(remaining_ns / std.time.ns_per_s), .nsec = @intCast(remaining_ns % std.time.ns_per_s) };
        var descriptors = [_]linux.pollfd{.{ .fd = process_descriptor, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.ppoll(&descriptors, descriptors.len, &remaining, null);
        switch (linux.errno(ready)) {
            .SUCCESS => return ready == 1,
            .INTR => continue,
            else => return false,
        }
    }
}

/// A signal ignored here would stay ignored in the child, whose host then
/// leaves it alone, as it does every signal an application ignores.
fn leaveSignalAtDefaultForChildren(signal: std.posix.SIG) void {
    const default_action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(signal, &default_action, null);
}

fn failAfterWatchdog(io: std.Io) void {
    io.sleep(.fromSeconds(watchdog_seconds), .awake) catch {};
    std.debug.print("terminate check: still running after {d} s, so an application or its host blocked\n", .{watchdog_seconds});
    std.c._exit(1);
}

const Ui = zui.Context(zui_app.contextConfig(NothingDrawn, .{ .limits = .{ .max_elements = 8 } }));

/// Says on its first frame that its process is ready for the signal: the
/// host has installed its handlers by then.
const UnshownApp = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = NothingDrawn;

    reported_ready: bool = false,

    pub fn zuiDeclare(_: *UnshownApp, ui: *Ui) void {
        ui.box(.{ .decoration = .{ .background = .white }, .layout = .{ .sizing = .grow_both } });
    }

    pub fn zuiLoader(app: *UnshownApp, _: *const Ui, io: std.Io) void {
        if (app.reported_ready) return;
        app.reported_ready = true;
        std.Io.File.stdout().writeStreamingAll(io, "ready\n") catch {};
    }
};

/// Draws nothing, so the surface is never committed and the compositor
/// answers none of its frames.
const NothingDrawn = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;

    pub fn zuiSubmit(_: *NothingDrawn, _: zui.Surface, _: anytype) !void {}
};
