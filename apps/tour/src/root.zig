//! zui's tour: zui shown four ways, for any host, renderer and font
//! system: an operations console built on it, the same console with each
//! feature pointed out, real problems solved plainly, and pages built to
//! impress. A target names the three, and `zui_app` runs it:
//!
//! ```zig
//! const App = zui_tour.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib" });
//!
//! pub fn main(init: std.process.Init) !void {
//!     try zui_app.run(App, init, .{ .title = "zui tour (raylib)", .size = .{ 1440, 900 } });
//! }
//! ```
//!
//! The tour gives the font system Atkinson Hyperlegible, its bold and
//! Liberation Mono from `zui_fonts`, and lays text out for the placement
//! the renderer draws. A screen is offered only when the renderer draws
//! what it needs: `clickable_chaos` needs `.transform`. The light lab
//! draws a material only for a `MaterialHandle` of patterns, and frost
//! only with `.backdrop_blur`; otherwise it shows what they lower to.

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_tracy = @import("zui_tracy");
const shared = @import("shared.zig");
const perf = @import("perf.zig");

pub const Screen = shared.Screen;
pub const Typeface = shared.Typeface;
pub const Sources = shared.Sources;
pub const Palette = shared.Palette;
pub const FrameReason = perf.FrameReason;
pub const Perf = perf.Perf;
pub const Stopwatch = perf.Stopwatch;
pub const Kit = @import("kit.zig").Kit;
pub const Tour = @import("tour.zig").Tour;
pub const stage_id = @import("tour.zig").stage_id;
pub const root_id = @import("tour.zig").root_id;

/// What a target names: the tour's host, renderer and font system.
pub const Config = struct {
    Host: type,
    Renderer: type,
    /// A font system, such as `zui_truetype.Text`: it declares
    /// `addFont(bytes) !FontId`, `zuiMeasure` and `zuiFingerprint`.
    Text: type,
    /// `zui_debug`'s inspector, which F12 toggles, and its zone timer,
    /// which passes each zone on to Tracy when zui is built with
    /// `-Dzui-tracy`. Off, neither is compiled in.
    inspector: bool = true,
    /// The renderer as the tour names it on its screens, such as "raylib".
    renderer_name: []const u8,
};

/// How a run of the tour behaves: the start screen, a smoke test's cycle
/// and frame limit, and what a target does around the tour, as its flags
/// say:
///
/// ```sh
/// --screen <name>        start on one screen
/// --frames <count>       quit after this many frames, printing whether every frame was ok
/// --cycle <frames>       move to the next screen every this many frames, in live mode
/// --zui-debug            open zui_debug's inspector, which F12 toggles
/// --measure-idle         print the CPU time an idle tour uses over 10 s, then quit
/// --hidden               for the target: keep the window hidden
/// --screenshot <path>    for the target: save the window once the tour settles, then quit
/// --measure-startup      for the target: measure the time to the first presented frame
/// ```
pub const Options = struct {
    screen: ?Screen = null,
    frame_limit: ?u64 = null,
    cycle_every: ?u32 = null,
    zui_debug: bool = false,
    hidden: bool = false,
    screenshot_path: ?[:0]const u8 = null,
    measure_idle: bool = false,
    measure_startup: bool = false,

    pub const usage = "--screen <name>, --frames <count>, --cycle <frames>, --zui-debug, --hidden, --screenshot <path>, --measure-idle or --measure-startup";

    /// The options `arguments` give, the program's name first.
    pub fn parse(arguments: []const [:0]const u8) error{ UnknownArgument, UnknownScreen, InvalidCharacter, Overflow }!Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            const has_value = index + 1 < arguments.len;
            if (std.mem.eql(u8, argument, "--screen") and has_value) {
                index += 1;
                options.screen = std.meta.stringToEnum(Screen, arguments[index]) orelse return error.UnknownScreen;
            } else if (std.mem.eql(u8, argument, "--frames") and has_value) {
                index += 1;
                options.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
            } else if (std.mem.eql(u8, argument, "--cycle") and has_value) {
                index += 1;
                options.cycle_every = try std.fmt.parseInt(u32, arguments[index], 10);
            } else if (std.mem.eql(u8, argument, "--screenshot") and has_value) {
                index += 1;
                options.screenshot_path = arguments[index];
                options.hidden = true;
            } else if (std.mem.eql(u8, argument, "--hidden")) {
                options.hidden = true;
            } else if (std.mem.eql(u8, argument, "--measure-idle")) {
                options.hidden = true;
                options.measure_idle = true;
            } else if (std.mem.eql(u8, argument, "--measure-startup")) {
                options.hidden = true;
                options.measure_startup = true;
            } else if (std.mem.eql(u8, argument, "--zui-debug")) {
                options.zui_debug = true;
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }
};

/// The tour as `zui_app` runs an application on `config.Host`, drawn by
/// `config.Renderer` in `config.Text`'s fonts. It times each frame for the
/// strip on its `stopwatch`, and reads the renderer's `layer_overflows`
/// and `glyphOverflows()` when it counts them, and `submitMicroseconds()`
/// when the renderer reports how long drawing took, as one whose frames a
/// page draws after `zuiSubmit` has returned does. Its `init` takes its `Options`
/// from the process's arguments; a target that does more around the tour
/// holds an `App` and calls `initWith`, with `startOf` its own `Start`,
/// and each hook itself.
pub fn App(comptime config: Config) type {
    return struct {
        const Self = @This();

        pub const Host = config.Host;
        pub const Renderer = config.Renderer;
        pub const kit = Kit(.{
            .Renderer = Renderer,
            .FontSystem = config.Text,
            .inspector = config.inspector,
            .renderer_name = config.renderer_name,
        });
        pub const Text = kit.Text;
        pub const Ui = kit.Ui;

        const counts_layer_overflows = @hasField(Renderer, "layer_overflows");
        const counts_glyph_overflows = @hasDecl(Renderer, "glyphOverflows");
        const reports_submit_time = @hasDecl(Renderer, "submitMicroseconds");

        tour: Tour(kit),
        sources: *Sources,
        host: *Host,
        renderer: *Renderer,
        io: std.Io,
        options: Options,
        stopwatch: Stopwatch = .io,
        /// Frames drawn so far.
        frames: u64 = 0,
        next: zui.NextFrame = .immediately,
        previous_params: ?zui.FrameParams = null,
        reason: FrameReason = .first,
        polled_at: zui.Instant = .zero,
        declare_started_at: zui.Instant = .zero,
        declared_at: zui.Instant = .zero,
        observed_at: zui.Instant = .zero,
        observed: Observed = .{},
        measure_calls_seen: u64 = 0,
        idle_measurement: ?IdleMeasurement = null,

        const Observed = struct {
            elements: u32 = 0,
            commands: u32 = 0,
            diagnostics: zui.Diagnostics = .{},
        };

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            if (builtin.os.tag == .freestanding) return app.initWith(start, .{});
            const process = start.process orelse return app.initWith(start, .{});
            const options = Options.parse(try process.minimal.args.toSlice(process.arena.allocator())) catch |err| {
                std.log.err("{t}; the tour takes {s}", .{ err, Options.usage });
                return err;
            };
            try app.initWith(start, options);
        }

        pub fn initWith(app: *Self, start: zui_app.Start(Self), options: Options) !void {
            app.* = .{
                .tour = undefined,
                .sources = &app.tour.sources,
                .host = start.host,
                .renderer = start.renderer,
                .io = start.io,
                .options = options,
            };
            if (kit.ZoneTimer != void) kit.ZoneTimer.useClock(start.io);
            app.tour.init(start.io, .zero, start.text.fonts);
            app.tour.host_waker = start.waker;
            if (options.screen) |screen| app.tour.show(screen);
            app.tour.cycle_every = options.cycle_every;
            app.tour.zui_debug_open = options.zui_debug;
            if (options.measure_idle) {
                app.tour.heartbeat = false;
                app.idle_measurement = .{ .launched_at = app.now() };
            }
            if (options.screenshot_path != null) app.tour.live = true;
        }

        /// `start`, a `zui_app.Start` of a target's application around
        /// this one, as this one's.
        pub fn startOf(start: anytype) zui_app.Start(Self) {
            return .{ .gpa = start.gpa, .io = start.io, .process = start.process, .host = start.host, .renderer = start.renderer, .text = start.text, .waker = start.waker, .windows = {} };
        }

        /// Stops the tour's producers, so the sources outlive them.
        pub fn deinit(app: *Self) void {
            app.tour.deinit();
            if (app.options.frame_limit == null) return;
            const tour_perf = &app.tour.perf;
            if (counts_layer_overflows or counts_glyph_overflows) {
                std.log.info("drew {d} frames, {d} layer overflows, {d} glyph atlas overflows, diagnostics ok: {}", .{ app.frames, tour_perf.layer_overflows, tour_perf.glyph_overflows, tour_perf.diagnostics.ok() });
            } else {
                std.log.info("drew {d} frames, diagnostics ok: {}", .{ app.frames, tour_perf.diagnostics.ok() });
            }
        }

        pub fn zuiRecord(app: *Self, record: *zui.RecordBuilder) void {
            if (app.previous_params == null) app.tour.started_at = record.params.now;
            // The host measured the viewport at the zoom of the record
            // before, and the tour may have zoomed since.
            const polled_zoom = record.params.zoom;
            record.params.zoom = app.tour.zoom;
            record.params.viewport = .{ record.params.viewport[0] * polled_zoom / app.tour.zoom, record.params.viewport[1] * polled_zoom / app.tour.zoom };
            for (app.tour.environment_changes.drain()) |change| record.append(.{ .environment = change });
            app.tour.perf.dropped_input_events +|= record.dropped_events;
            app.reason = app.frameReason(record);
            app.previous_params = record.params;
            app.polled_at = app.now();
        }

        pub fn zuiDeclare(app: *Self, ui: *Ui) void {
            if (app.idle_measurement) |*measurement| {
                if (measurement.reportAt(ui.now(), app.frames, app.tour.wakes.load(.monotonic))) |report| {
                    // Measuring idle is a native target's flag, and a
                    // freestanding build has no stderr to print to.
                    if (builtin.os.tag != .freestanding) std.debug.print("{f}\n", .{report});
                    app.idle_measurement = null;
                    app.closeHost();
                    // The host sees it closed only when it polls again, and an idle screen asks for no frame.
                    ui.requestFrame();
                } else {
                    ui.requestFrameAt(measurement.nextCheckpoint());
                }
            }
            app.declare_started_at = app.now();
            app.tour.declare(ui);
            app.declared_at = app.now();
            const background = Palette.forEnvironment(ui.environment()).background;
            if (@hasField(Renderer, "clear_color")) app.renderer.clear_color = background;
        }

        pub fn zuiObserve(app: *Self, ui: *const Ui, frame: *const Ui.Frame) void {
            app.observed_at = app.now();
            app.observed = .{ .elements = frame.elementCount(), .commands = @intCast(frame.commands().len), .diagnostics = frame.diagnostics };
            app.tour.observe(ui, frame);
        }

        /// After each frame: records what it cost, runs the tour's
        /// loaders, and closes the host at the frame limit.
        pub fn zuiLoader(app: *Self, ui: *const Ui, _: std.Io) void {
            app.recordPerf(ui);
            app.tour.afterFrame(ui);
            zui_tracy.frameMark();

            app.frames += 1;
            if (app.options.frame_limit) |limit| if (app.frames == limit) app.closeHost();

            app.next = ui.nextFrame(app.sources);
            app.tour.perf.next_frame = app.next;
            app.tour.perf.next_frame_seconds = switch (app.next) {
                .at => |deadline| deadline.secondsSince(ui.now()),
                else => 0,
            };
        }

        /// Ends the run after this frame, on a host that can close its window.
        pub fn closeHost(app: *Self) void {
            if (@hasDecl(Host, "close")) app.host.close() else std.log.err("zui_tour: {s} cannot close its window, so the run goes on", .{@typeName(Host)});
        }

        fn now(app: *Self) zui.Instant {
            return app.stopwatch.read(app.io);
        }

        /// What ended the host's wait for this frame.
        fn frameReason(app: *const Self, record: *const zui.RecordBuilder) FrameReason {
            const previous = app.previous_params orelse return .first;
            if (record.events().len != 0) return .input;
            const params = record.params;
            if (!std.meta.eql(params.viewport, previous.viewport) or params.scale != previous.scale or params.zoom != previous.zoom) return .resize;
            if (sourcesPending(app.sources)) return .source;
            return switch (app.next) {
                .immediately => .requested,
                .at => .timer,
                // The host's wait ended for input that made no event of zui's.
                .on_event => .input,
            };
        }

        fn recordPerf(app: *Self, ui: *const Ui) void {
            const loaded_at = app.now();
            const tour_perf = &app.tour.perf;
            const measure_calls = ui.measureCalls() - app.measure_calls_seen;
            app.measure_calls_seen = ui.measureCalls();
            tour_perf.record(.{
                .begin_frame_us = microsecondsBetween(app.polled_at, app.declare_started_at),
                .declare_us = microsecondsBetween(app.declare_started_at, app.declared_at),
                .end_frame_us = microsecondsBetween(app.declared_at, app.observed_at),
                .elements = app.observed.elements,
                .commands = app.observed.commands,
                .measure_calls = @intCast(measure_calls),
                .reason = app.reason,
            });
            tour_perf.zui_frames += 1;
            tour_perf.countFrameAt(ui.now().secondsSince(app.tour.started_at));
            tour_perf.measure_calls_total += measure_calls;
            tour_perf.submit_us = if (reports_submit_time) app.renderer.submitMicroseconds() else microsecondsBetween(app.observed_at, loaded_at);
            tour_perf.diagnostics = app.observed.diagnostics;
            tour_perf.wakes = app.tour.wakes.load(.monotonic);
            if (counts_layer_overflows) tour_perf.layer_overflows = app.renderer.layer_overflows;
            if (counts_glyph_overflows) tour_perf.glyph_overflows = app.renderer.glyphOverflows();
        }
    };
}

/// `--measure-idle`: the CPU time the tour uses while idle, read by the
/// process itself at two frames it asks for with `requestFrameAt`, so the
/// run ends on its own and needs no outside sampler.
const IdleMeasurement = struct {
    const warm_up_seconds = 5;
    const measured_seconds = 10;

    launched_at: zui.Instant,
    start: ?Checkpoint = null,

    const Checkpoint = struct { at: zui.Instant, cpu_nanoseconds: u64, frames: u64, wakes: u32 };

    const Report = struct {
        cpu_nanoseconds: u64,
        seconds: f32,
        frames: u64,
        wakes: u32,

        pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("idle: {d:.1} ms of CPU over {d:.1} s ({d:.3}% of one core), {d} frames, {d} wakes", .{
                @as(f64, @floatFromInt(self.cpu_nanoseconds)) / std.time.ns_per_ms,
                self.seconds,
                @as(f64, @floatFromInt(self.cpu_nanoseconds)) / (self.seconds * std.time.ns_per_s) * 100,
                self.frames,
                self.wakes,
            });
        }
    };

    fn nextCheckpoint(self: *const IdleMeasurement) zui.Instant {
        if (self.start) |start| return start.at.addSeconds(measured_seconds);
        return self.launched_at.addSeconds(warm_up_seconds);
    }

    /// Called in every frame; the frame at the end of the measurement
    /// counts toward it.
    fn reportAt(self: *IdleMeasurement, at: zui.Instant, frames: u64, wakes: u32) ?Report {
        if (at.isBefore(self.nextCheckpoint())) return null;
        const checkpoint: Checkpoint = .{ .at = at, .cpu_nanoseconds = processCpuNanoseconds(), .frames = frames, .wakes = wakes };
        const start = self.start orelse {
            self.start = checkpoint;
            return null;
        };
        return .{
            .cpu_nanoseconds = checkpoint.cpu_nanoseconds - start.cpu_nanoseconds,
            .seconds = checkpoint.at.secondsSince(start.at),
            .frames = checkpoint.frames - start.frames,
            .wakes = checkpoint.wakes - start.wakes,
        };
    }
};

const windows = std.os.windows;
extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *windows.FILETIME, exit: *windows.FILETIME, kernel: *windows.FILETIME, user: *windows.FILETIME) callconv(.winapi) windows.BOOL;

/// User and kernel time of every thread of this process; 0 where the
/// system keeps no account of it.
fn processCpuNanoseconds() u64 {
    switch (builtin.os.tag) {
        .windows => {
            var times: [4]windows.FILETIME = undefined;
            if (GetProcessTimes(windows.GetCurrentProcess(), &times[0], &times[1], &times[2], &times[3]) == .FALSE) return 0;
            return (fileTimeTicks(times[2]) + fileTimeTicks(times[3])) * 100;
        },
        .freestanding, .wasi => return 0,
        else => {
            const usage = std.posix.getrusage(std.posix.rusage.SELF);
            return timevalNanoseconds(usage.utime) + timevalNanoseconds(usage.stime);
        },
    }
}

fn fileTimeTicks(time: windows.FILETIME) u64 {
    return @as(u64, time.dwHighDateTime) << 32 | time.dwLowDateTime;
}

fn timevalNanoseconds(time: anytype) u64 {
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.usec)) * std.time.ns_per_us;
}

fn sourcesPending(sources: *const Sources) bool {
    inline for (@typeInfo(Sources).@"struct".fields) |field| {
        if (@field(sources, field.name).zuiPending()) return true;
    }
    return false;
}

fn microsecondsBetween(earlier: zui.Instant, later: zui.Instant) f32 {
    return later.secondsSince(earlier) * std.time.us_per_s;
}
