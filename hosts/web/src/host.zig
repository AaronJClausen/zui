const std = @import("std");
const zui = @import("zui");
const browser_input = @import("browser_input.zig");
const SteppedIo = @import("stepped_io.zig").SteppedIo;

/// When the platform takes the host's next turn, as the host last asked.
/// Each schedule replaces the one before.
pub const Schedule = union(enum) {
    /// On the page's next animation frame.
    animation_frame,
    /// At an instant on the platform's clock.
    timer: zui.Instant,
    /// Not until the page's input, or a wake, arrives.
    input,
    /// Never again: the run is over.
    ended,
};

/// The host's turns, as the platform's event loop takes them: each is a
/// poll and a step of the application, and ends by scheduling the next.
pub const Turns = struct {
    host: *anyopaque,
    takeFn: *const fn (*anyopaque) anyerror!void,

    /// Takes one turn, which schedules the next before it returns.
    pub fn take(self: Turns) anyerror!void {
        return self.takeFn(self.host);
    }
};

/// A `PointerEvent` as the page reads it: its `pointerId`, its
/// `pointerType` as `browser_input.BrowserPointerKind` numbers it, its
/// place in CSS pixels from the canvas's top-left, its pressure from 0 to
/// 1, its tilt in degrees and its `timeStamp`.
pub const BrowserPointer = struct {
    id: u32,
    kind: u32,
    position: [2]f32,
    pressure: f32 = 1,
    tilt_degrees: [2]f32 = .{ 0, 0 },
    at_milliseconds: f64,
};

/// The settings the page reads from its media queries, `navigator.language`,
/// the document's direction and the window's focus, each field named as the
/// `zui.EnvironmentChange` it becomes. Until the page says otherwise, each
/// is `zui.Environment`'s default; the first record reports every field.
///
/// The page sends each as text: a `bool` as `"true"` or `"false"`, an enum
/// by its tag name, a locale as its BCP 47 tag.
///
/// ```zig
/// host.changeSetting("theme", "dark");
/// host.changeSetting("locale", "fr-CA");
/// ```
pub const PageEnvironment = struct {
    theme: zui.Environment.Theme = .light,
    contrast: zui.Environment.Contrast = .normal,
    reduced_motion: bool = false,
    reduced_transparency: bool = false,
    locale: zui.Locale = .default,
    direction: zui.ReadingDirection = .left_to_right,
    window_focused: bool = true,

    const Setting = std.meta.FieldEnum(PageEnvironment);

    /// Sets the setting `name` to the value `text` names; false, and
    /// nothing changed, when it names no setting or no value of it.
    pub fn set(self: *PageEnvironment, name: []const u8, text: []const u8) bool {
        const setting = std.meta.stringToEnum(Setting, name) orelse return false;
        switch (setting) {
            inline else => |field| {
                const Value = @FieldType(PageEnvironment, @tagName(field));
                @field(self, @tagName(field)) = parseSetting(Value, text) orelse return false;
            },
        }
        return true;
    }

    fn parseSetting(comptime Value: type, text: []const u8) ?Value {
        if (Value == bool) {
            if (std.mem.eql(u8, text, "true")) return true;
            if (std.mem.eql(u8, text, "false")) return false;
            return null;
        }
        if (Value == zui.Locale) return localeKeepingWholeSubtags(text);
        return std.meta.stringToEnum(Value, text);
    }

    /// A tag longer than `zui.Locale` holds keeps the subtags that fit,
    /// so `"en-US-x-twain"` cut short is still `"en-US"`, never `"en-US-x-tw"`.
    fn localeKeepingWholeSubtags(language_tag: []const u8) ?zui.Locale {
        if (language_tag.len == 0) return null;
        var kept = language_tag;
        while (kept.len > zui.Locale.capacity) {
            kept = kept[0 .. std.mem.lastIndexOfScalar(u8, kept, '-') orelse return null];
        }
        return zui.Locale.parse(kept) catch unreachable;
    }
};

/// The browser's host: a pushed host, whose loop is the page's event loop,
/// with its window half over a platform that `Platform` is. The platform
/// hands the host the canvas, its size and its events, and takes the
/// host's turns when the host schedules them; the host turns them into
/// records, `.web` surfaces and the cursor. Every field has a default, so
/// `zui_app` makes it.
///
/// `Platform` declares:
/// - `now(*Platform) zui.Instant`, the page's clock;
/// - `schedule(*Platform, zui_web.Schedule) void`, when to take the next turn;
/// - `wake(*Platform) void`, from any thread: take a turn at once;
/// - `showCursor(*Platform, zui.Cursor) void`, the canvas's cursor;
/// - `run(*Platform, zui_web.Turns) !void`, or `noreturn`: the event
///   loop, taking each turn as scheduled until the run is over.
///
/// ```zig
/// const Host = zui_web.HostOn(WorkerPlatform);
/// // From the page's messages, on the thread that takes the turns:
/// host.attachCanvas(canvas_id, .{ css_width, css_height }, device_pixel_ratio);
/// host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ x, y }, .at_milliseconds = event_time });
/// host.loseContext();
/// host.changeSetting("theme", "dark");
/// host.showPage(false);
/// ```
pub fn HostOn(comptime Platform: type) type {
    comptime checkPlatform(Platform);
    return struct {
        const Self = @This();

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.web);

        /// Events the page can deliver between two polls; what does not
        /// fit is dropped and counted in the next record.
        pub const inbox_event_capacity = 256;
        /// Bytes of typed text the page can deliver between two polls.
        pub const inbox_text_capacity = 1024;

        platform: Platform = .{},
        canvas: ?u32 = null,
        canvas_css_size: [2]f32 = .{ 0, 0 },
        device_pixel_ratio: f32 = 1,
        inbox: Inbox = .{},
        shown_cursor: ?zui.Cursor = null,
        context_lost: bool = false,
        page_shown: bool = true,
        surfaces_suspended: bool = false,
        page_environment: PageEnvironment = .{},
        /// Null until the first poll reports every setting.
        reported_environment: ?PageEnvironment = null,
        woken: std.atomic.Value(bool) = .init(false),
        scheduled: Schedule = .input,
        phase: Phase = .not_running,
        io: std.Io = undefined,
        driver: zui.Driver = undefined,

        const Phase = enum { not_running, awaiting_start, running, ended };

        const Run = @typeInfo(@TypeOf(Platform.run)).@"fn".return_type.?;
        const runs_forever = Run == noreturn;

        const Inbox = struct {
            /// Positions are in CSS pixels until a poll converts them.
            events: [inbox_event_capacity]zui.Event = undefined,
            event_count: usize = 0,
            text: [inbox_text_capacity]u8 = undefined,
            text_len: usize = 0,
            dropped_events: u32 = 0,
            dropped_text_bytes: u32 = 0,

            fn push(self: *Inbox, event: zui.Event) void {
                if (self.event_count == inbox_event_capacity) {
                    self.dropped_events +|= 1;
                    return;
                }
                self.events[self.event_count] = event;
                self.event_count += 1;
            }

            fn pushText(self: *Inbox, utf8: []const u8) void {
                const fits = utf8.len <= inbox_text_capacity - self.text_len and self.event_count < inbox_event_capacity;
                if (!fits) {
                    self.dropped_text_bytes +|= std.math.lossyCast(u32, utf8.len);
                    return;
                }
                const start = self.text_len;
                @memcpy(self.text[start..][0..utf8.len], utf8);
                self.text_len += utf8.len;
                self.push(.{ .text = self.text[start..self.text_len] });
            }

            fn clear(self: *Inbox) void {
                self.* = .{};
            }
        };

        /// Starts the driver on the first turn after the canvas was given,
        /// and takes turns in the platform's event loop until a step ends
        /// the run, stopping the driver then.
        pub fn zuiRun(self: *Self, io: std.Io, _: zui.WindowOptions, driver: zui.Driver) if (runs_forever) noreturn else anyerror!void {
            self.begin(io, driver);
            if (comptime runs_forever) {
                self.platform.run(self.turns());
            } else {
                defer self.end();
                return self.platform.run(self.turns());
            }
        }

        fn begin(self: *Self, io: std.Io, driver: zui.Driver) void {
            self.io = io;
            self.driver = driver;
            self.phase = .awaiting_start;
            self.scheduleTurn(if (self.canStart()) .animation_frame else .input);
        }

        fn canStart(self: *const Self) bool {
            return self.canvas != null and !self.context_lost;
        }

        /// What the platform's `run` takes each turn through.
        pub fn turns(self: *Self) Turns {
            return .{ .host = self, .takeFn = takeTurn };
        }

        fn takeTurn(context: *anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.turn();
        }

        fn turn(self: *Self) anyerror!void {
            switch (self.phase) {
                .not_running, .ended => return,
                .awaiting_start => {
                    _ = self.woken.swap(false, .acq_rel);
                    if (!self.canStart()) return self.scheduleTurn(.input);
                    try self.driver.start(self.io);
                    self.phase = .running;
                },
                .running => _ = self.woken.swap(false, .acq_rel),
            }
            const stepped = SteppedIo.behind(self.io);
            if (stepped) |stepped_io| stepped_io.step(self.platform.now().nanoseconds);
            if (!self.context_lost and self.page_shown) try self.resumeSurfaces();
            if (self.context_lost) self.suspendSurfaces();
            const next = try self.driver.step() orelse return self.end();
            // After the step, so the application polled the `suspend` first.
            if (!self.page_shown) self.suspendSurfaces();
            self.scheduleTurn(self.scheduleAfter(next, stepped));
        }

        /// A wake from a task, which runs only inside a step, or page
        /// input that arrived while it ran, makes the next turn due at once.
        fn scheduleAfter(self: *const Self, next: zui.NextFrame, stepped: ?*SteppedIo) Schedule {
            var sooner = next;
            if (stepped) |stepped_io| {
                if (stepped_io.nextWakeNanoseconds()) |wake_nanoseconds| {
                    sooner = sooner.sooner(.{ .at = .fromNanoseconds(std.math.lossyCast(u64, wake_nanoseconds)) });
                }
            }
            const inbox_waits_for_a_poll = self.inbox.event_count > 0 and !self.surfaces_suspended;
            if (self.woken.load(.acquire) or inbox_waits_for_a_poll) sooner = .immediately;
            return switch (sooner) {
                .immediately => .animation_frame,
                .at => |instant| .{ .timer = instant },
                .on_event => .input,
            };
        }

        fn suspendSurfaces(self: *Self) void {
            if (self.surfaces_suspended) return;
            self.driver.suspendSurfaces();
            self.surfaces_suspended = true;
        }

        fn resumeSurfaces(self: *Self) !void {
            if (!self.surfaces_suspended) return;
            try self.driver.resumeSurfaces();
            self.surfaces_suspended = false;
        }

        fn end(self: *Self) void {
            switch (self.phase) {
                .not_running, .ended => return,
                .awaiting_start, .running => {},
            }
            self.driver.stop();
            self.phase = .ended;
            self.scheduleTurn(.ended);
        }

        fn scheduleTurn(self: *Self, schedule: Schedule) void {
            self.scheduled = schedule;
            self.platform.schedule(schedule);
        }

        /// Something the page delivered needs a turn: on the next animation
        /// frame, unless one is due by then.
        fn needTurn(self: *Self) void {
            switch (self.phase) {
                .not_running, .ended => return,
                .awaiting_start, .running => {},
            }
            if (self.scheduled != .animation_frame) self.scheduleTurn(.animation_frame);
        }

        /// The canvas the page transferred, by the id it gave it, with its
        /// size in CSS pixels and `devicePixelRatio`. The driver starts on
        /// the turn after it arrives.
        pub fn attachCanvas(self: *Self, id: u32, css_size: [2]f32, device_pixel_ratio: f32) void {
            self.canvas = id;
            self.resize(css_size, device_pixel_ratio);
        }

        /// The canvas's new size in CSS pixels, or `devicePixelRatio`.
        pub fn resize(self: *Self, css_size: [2]f32, device_pixel_ratio: f32) void {
            self.canvas_css_size = css_size;
            self.device_pixel_ratio = device_pixel_ratio;
            self.needTurn();
        }

        /// `webglcontextlost`: the surfaces are suspended on the next turn.
        pub fn loseContext(self: *Self) void {
            self.context_lost = true;
            self.needTurn();
        }

        /// `webglcontextrestored`: the surfaces resume on the next turn.
        pub fn restoreContext(self: *Self) void {
            self.context_lost = false;
            self.needTurn();
        }

        /// One of the page's settings, `PageEnvironment.set`'s `name` and
        /// `text`, reported in the next record when it changed. One the
        /// host does not know is left out.
        pub fn changeSetting(self: *Self, name: []const u8, text: []const u8) void {
            const before = self.page_environment;
            if (!self.page_environment.set(name, text)) return;
            if (!std.meta.eql(before, self.page_environment)) self.needTurn();
        }

        /// `document.visibilityState`: a page hidden is `suspend` in the
        /// next record, after which the surfaces are suspended and nothing
        /// is drawn, and one shown again is `resume`, its surfaces resumed.
        pub fn showPage(self: *Self, shown: bool) void {
            if (shown == self.page_shown) return;
            self.page_shown = shown;
            self.deliver(.{ .lifecycle = if (shown) .@"resume" else .@"suspend" });
        }

        /// A button pressed, `MouseEvent.button`; one zui has no
        /// `zui.Button` for is left out.
        pub fn pointerDown(self: *Self, pointer: BrowserPointer, browser_button: u32) void {
            const pressed = browser_input.button(browser_button) orelse return;
            self.deliver(.{ .pointer_down = .{ .pointer = pointerOf(pointer), .button = pressed } });
        }

        /// A button released, `MouseEvent.button`.
        pub fn pointerUp(self: *Self, pointer: BrowserPointer, browser_button: u32) void {
            const released = browser_input.button(browser_button) orelse return;
            self.deliver(.{ .pointer_up = .{ .pointer = pointerOf(pointer), .button = released } });
        }

        /// `pointermove`, hovering or pressed.
        pub fn pointerMove(self: *Self, pointer: BrowserPointer) void {
            self.deliver(.{ .pointer_move = .{ .pointer = pointerOf(pointer) } });
        }

        /// The browser took the pointer, as `pointercancel` says.
        pub fn pointerCancel(self: *Self, browser_pointer_id: u32, browser_kind: u32) void {
            self.deliver(.{ .pointer_cancel = browser_input.pointerId(browser_input.pointerKind(browser_kind), browser_pointer_id) });
        }

        /// A hovering pointer left the canvas.
        pub fn pointerLeave(self: *Self, browser_pointer_id: u32, browser_kind: u32) void {
            self.deliver(.{ .pointer_leave = browser_input.pointerId(browser_input.pointerKind(browser_kind), browser_pointer_id) });
        }

        /// A `WheelEvent`'s place in CSS pixels, its deltas and their
        /// `deltaMode`.
        pub fn wheel(self: *Self, css_position: [2]f32, delta: [2]f32, browser_delta_mode: u32, at_milliseconds: f64) void {
            self.deliver(.{ .wheel = .{
                .position = css_position,
                .delta = browser_input.wheelDelta(delta, browser_delta_mode, self.canvas_css_size),
                .at = browser_input.instant(at_milliseconds),
            } });
        }

        /// A `KeyboardEvent`'s `key` and `code`, with the modifiers held as
        /// `browser_input.modifiers` reads them.
        pub fn key(self: *Self, down: bool, browser_key: []const u8, code: []const u8, browser_modifier_bits: u32, repeat: bool, at_milliseconds: f64) void {
            const event: zui.KeyEvent = .{
                .key = browser_input.logicalKey(browser_key, code),
                .modifiers = browser_input.modifiers(browser_modifier_bits),
                .repeat = repeat,
                .scancode = browser_input.scancode(code),
                .at = browser_input.instant(at_milliseconds),
            };
            self.deliver(if (down) .{ .key_down = event } else .{ .key_up = event });
        }

        /// Committed UTF-8.
        pub fn typed(self: *Self, utf8: []const u8) void {
            self.inbox.pushText(utf8);
            self.needTurn();
        }

        fn deliver(self: *Self, event: zui.Event) void {
            self.inbox.push(event);
            self.needTurn();
        }

        fn pointerOf(pointer: BrowserPointer) zui.Pointer {
            const kind = browser_input.pointerKind(pointer.kind);
            return .{
                .id = browser_input.pointerId(kind, pointer.id),
                .kind = kind,
                .position = pointer.position,
                .at = browser_input.instant(pointer.at_milliseconds),
                .pressure = if (kind == .mouse) 1 else pointer.pressure,
                .tilt = .{ std.math.degreesToRadians(pointer.tilt_degrees[0]), std.math.degreesToRadians(pointer.tilt_degrees[1]) },
            };
        }

        /// The settings that changed since the last poll, every one the
        /// first time, then the page's events since the last poll, in
        /// layout units: CSS pixels over the application's zoom. The scale
        /// is `devicePixelRatio`.
        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            const css_pixels_per_unit = record.params.zoom;
            record.begin(.{
                .now = self.platform.now(),
                .viewport = .{ self.canvas_css_size[0] / css_pixels_per_unit, self.canvas_css_size[1] / css_pixels_per_unit },
                .scale = self.device_pixel_ratio,
            });
            self.reportEnvironment(record);
            for (self.inbox.events[0..self.inbox.event_count]) |queued| {
                const converted = inLayoutUnits(queued, css_pixels_per_unit);
                switch (converted) {
                    .text => |text| record.appendText(text),
                    else => record.append(converted),
                }
            }
            record.dropped_events +|= self.inbox.dropped_events;
            record.dropped_text_bytes +|= self.inbox.dropped_text_bytes;
            self.inbox.clear();
            return true;
        }

        fn reportEnvironment(self: *Self, record: *zui.RecordBuilder) void {
            const reported = self.reported_environment;
            inline for (std.meta.fields(PageEnvironment)) |field| {
                const value = @field(self.page_environment, field.name);
                if (reported == null or !std.meta.eql(@field(reported.?, field.name), value)) {
                    record.append(.{ .environment = @unionInit(zui.EnvironmentChange, field.name, value) });
                }
            }
            self.reported_environment = self.page_environment;
        }

        fn inLayoutUnits(queued: zui.Event, css_pixels_per_unit: f32) zui.Event {
            var converted = queued;
            switch (converted) {
                .pointer_down, .pointer_up => |*press| scalePosition(&press.pointer.position, css_pixels_per_unit),
                .pointer_move => |*move| scalePosition(&move.pointer.position, css_pixels_per_unit),
                .wheel => |*scroll| {
                    scalePosition(&scroll.position, css_pixels_per_unit);
                    scalePosition(&scroll.delta, css_pixels_per_unit);
                },
                else => {},
            }
            return converted;
        }

        fn scalePosition(position: *[2]f32, css_pixels_per_unit: f32) void {
            position.* = .{ position[0] / css_pixels_per_unit, position[1] / css_pixels_per_unit };
        }

        /// Wakes from any thread through the platform's `wake`.
        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.woken.store(true, .release);
            self.platform.wake();
        }

        /// On the thread that takes the turns, after the platform's `wake`
        /// reached it: a turn on the next animation frame, unless the wake
        /// came inside a turn, which already made the next one due.
        pub fn answerWake(self: *Self) void {
            if (self.woken.load(.acquire)) self.needTurn();
        }

        /// The canvas the page attached, by its id.
        pub fn zuiSurface(self: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            return .{ .web = .{ .canvas = self.canvas.? } };
        }

        /// Shows the cursor the frame asks for, telling the platform only
        /// when it changes.
        pub fn zuiApply(self: *Self, window: zui.WindowId, requests: zui.HostRequests) void {
            std.debug.assert(window == .main);
            if (self.shown_cursor == requests.cursor) return;
            self.shown_cursor = requests.cursor;
            self.platform.showCursor(requests.cursor);
        }
    };
}

fn checkPlatform(comptime Platform: type) void {
    const name = @typeName(Platform);
    if (@typeInfo(Platform) != .@"struct") @compileError("zui_web: a web host's platform must be a struct type, got " ++ name);
    const calls = [_]struct { name: []const u8, Expected: type, expected_name: []const u8 }{
        .{ .name = "now", .Expected = fn (*Platform) zui.Instant, .expected_name = "fn (*" ++ name ++ ") zui.Instant" },
        .{ .name = "schedule", .Expected = fn (*Platform, Schedule) void, .expected_name = "fn (*" ++ name ++ ", zui_web.Schedule) void" },
        .{ .name = "wake", .Expected = fn (*Platform) void, .expected_name = "fn (*" ++ name ++ ") void" },
        .{ .name = "showCursor", .Expected = fn (*Platform, zui.Cursor) void, .expected_name = "fn (*" ++ name ++ ", zui.Cursor) void" },
    };
    for (calls) |call| {
        if (!@hasDecl(Platform, call.name)) @compileError("zui_web: " ++ name ++ " is not a web host's platform: missing `" ++ call.name ++ "`, which must be " ++ call.expected_name);
        if (@TypeOf(@field(Platform, call.name)) != call.Expected) @compileError("zui_web: " ++ name ++ "." ++ call.name ++ " must be " ++ call.expected_name ++ ", found " ++ @typeName(@TypeOf(@field(Platform, call.name))));
    }
    const run_name = "fn (*" ++ name ++ ", zui_web.Turns) !void, or noreturn";
    if (!@hasDecl(Platform, "run")) @compileError("zui_web: " ++ name ++ " is not a web host's platform: missing `run`, which must be " ++ run_name);
    const runs_turns = switch (@typeInfo(@TypeOf(Platform.run))) {
        .@"fn" => |function| function.params.len == 2 and function.params[0].type == *Platform and function.params[1].type == Turns and
            if (function.return_type) |Returned| Returned == noreturn or (@typeInfo(Returned) == .error_union and @typeInfo(Returned).error_union.payload == void) else false,
        else => false,
    };
    if (!runs_turns) @compileError("zui_web: " ++ name ++ ".run must be " ++ run_name ++ ", found " ++ @typeName(@TypeOf(Platform.run)));
}

const testing = std.testing;
const zui_testing = @import("zui_testing");

/// A page in miniature: its event loop takes each turn as the host
/// scheduled it, waiting on the real clock, unless a test sets the clock
/// itself and takes the turns.
const ScriptedPlatform = struct {
    io: std.Io = undefined,
    /// Set, the clock stands still at it, as a test moves it.
    still_clock: ?zui.Instant = null,
    scheduled: Schedule = .input,
    schedules: u32 = 0,
    cursors: [8]zui.Cursor = undefined,
    cursor_count: usize = 0,
    woken: std.Io.Event = .unset,
    quitting: std.atomic.Value(bool) = .init(false),
    /// Delivered before the next turn.
    surface_change: ?SurfaceChange = null,

    const SurfaceChange = enum { context_lost, context_restored, page_hidden, page_shown };

    const longest_wait_ns = 10 * std.time.ns_per_s;

    pub fn now(self: *ScriptedPlatform) zui.Instant {
        return self.still_clock orelse .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    pub fn schedule(self: *ScriptedPlatform, next: Schedule) void {
        self.scheduled = next;
        self.schedules += 1;
    }

    pub fn wake(self: *ScriptedPlatform) void {
        self.woken.set(self.io);
    }

    pub fn showCursor(self: *ScriptedPlatform, cursor: zui.Cursor) void {
        self.cursors[self.cursor_count] = cursor;
        self.cursor_count += 1;
    }

    /// From any thread: the loop ends before its next turn.
    fn quit(self: *ScriptedPlatform) void {
        self.quitting.store(true, .release);
        self.woken.set(self.io);
    }

    pub fn run(self: *ScriptedPlatform, host_turns: Turns) !void {
        const host: *ScriptedHost = @ptrCast(@alignCast(host_turns.host));
        while (!self.quitting.load(.acquire)) {
            if (self.surface_change) |change| {
                self.surface_change = null;
                switch (change) {
                    .context_lost => host.loseContext(),
                    .context_restored => host.restoreContext(),
                    .page_hidden => host.showPage(false),
                    .page_shown => host.showPage(true),
                }
            }
            switch (self.scheduled) {
                .ended => return,
                .animation_frame => {},
                .timer => |instant| self.waitUntil(instant),
                .input => self.waitUntil(self.now().addNanoseconds(longest_wait_ns)),
            }
            if (self.quitting.load(.acquire)) return;
            self.woken.reset();
            try host_turns.take();
        }
    }

    fn waitUntil(self: *ScriptedPlatform, instant: zui.Instant) void {
        const deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = instant.nanoseconds }, .clock = .awake };
        while (!self.woken.isSet() and self.now().isBefore(instant)) {
            self.woken.waitTimeout(self.io, .{ .deadline = deadline }) catch {};
        }
    }
};

const ScriptedHost = HostOn(ScriptedPlatform);

const ConformanceHarness = struct {
    web_host: ScriptedHost,
    surface_taken_by: enum { losing_the_context, hiding_the_page },

    pub fn host(self: *ConformanceHarness) *ScriptedHost {
        return &self.web_host;
    }

    pub fn takeSurfaceAway(self: *ConformanceHarness) void {
        self.web_host.platform.surface_change = switch (self.surface_taken_by) {
            .losing_the_context => .context_lost,
            .hiding_the_page => .page_hidden,
        };
    }

    pub fn giveSurfaceBack(self: *ConformanceHarness) void {
        self.web_host.platform.surface_change = switch (self.surface_taken_by) {
            .losing_the_context => .context_restored,
            .hiding_the_page => .page_shown,
        };
    }

    pub fn quit(self: *ConformanceHarness) void {
        self.web_host.platform.quit();
    }
};

test "the web host's logic, on a scripted page, keeps the pushed host's contract" {
    var harness: ConformanceHarness = .{ .web_host = .{ .platform = .{ .io = testing.io } }, .surface_taken_by = .losing_the_context };
    harness.web_host.attachCanvas(1, .{ 800, 600 }, 1);
    try zui_testing.expectPushedHostConforms(ScriptedHost, &harness, .{ .io = testing.io });
}

test "the web host's logic keeps the pushed host's contract when hiding the page takes its surface away" {
    var harness: ConformanceHarness = .{ .web_host = .{ .platform = .{ .io = testing.io } }, .surface_taken_by = .hiding_the_page };
    harness.web_host.attachCanvas(1, .{ 800, 600 }, 1);
    try zui_testing.expectPushedHostConforms(ScriptedHost, &harness, .{ .io = testing.io });
}

/// A driver whose steps poll the host and answer, in turn, what `answers`
/// says, the last one again and again.
const ScriptedDriver = struct {
    host: *ScriptedHost,
    answers: []const ?zui.NextFrame = &.{.on_event},
    steps: usize = 0,
    starts: u32 = 0,
    stops: u32 = 0,
    suspends: u32 = 0,
    resumes: u32 = 0,
    suspended: bool = false,
    wake_while_stepping: bool = false,
    event_buffer: [ScriptedHost.inbox_event_capacity + 8]zui.Event = undefined,
    text_buffer: [ScriptedHost.inbox_text_capacity]u8 = undefined,
    builder: ?zui.RecordBuilder = null,
    zoom: f32 = 1,

    const calls: zui.Driver.Calls = .{
        .start = start,
        .step = step,
        .suspendSurfaces = suspendSurfaces,
        .resumeSurfaces = resumeSurfaces,
        .stop = stop,
    };

    fn driver(self: *ScriptedDriver) zui.Driver {
        return .{ .context = self, .calls = &calls };
    }

    fn of(context: *anyopaque) *ScriptedDriver {
        return @ptrCast(@alignCast(context));
    }

    fn start(context: *anyopaque, _: std.Io) anyerror!void {
        of(context).starts += 1;
    }

    fn step(context: *anyopaque) anyerror!?zui.NextFrame {
        const self = of(context);
        if (self.suspended) {
            self.steps += 1;
            return .on_event;
        }
        if (self.builder == null) self.builder = .init(&self.event_buffer, &self.text_buffer);
        self.builder.?.params.zoom = self.zoom;
        _ = self.host.zuiPoll(.main, &self.builder.?);
        if (self.wake_while_stepping) self.host.zuiWaker().wake();
        const answer = self.answers[@min(self.steps, self.answers.len - 1)];
        self.steps += 1;
        return answer;
    }

    fn suspendSurfaces(context: *anyopaque) void {
        of(context).suspends += 1;
        of(context).suspended = true;
    }

    fn resumeSurfaces(context: *anyopaque) anyerror!void {
        of(context).resumes += 1;
        of(context).suspended = false;
    }

    fn stop(context: *anyopaque) void {
        of(context).stops += 1;
    }

    fn events(self: *const ScriptedDriver) []const zui.Event {
        return self.builder.?.record().events;
    }
};

fn at(milliseconds: u64) zui.Instant {
    return .fromNanoseconds(milliseconds * std.time.ns_per_ms);
}

fn scriptedHost() ScriptedHost {
    return .{ .platform = .{ .io = testing.io, .still_clock = at(1000) } };
}

test "the driver starts on the first turn after the canvas arrives, which its surface names" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.begin(testing.io, driver.driver());
    try testing.expectEqual(Schedule.input, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(0, driver.starts);

    host.attachCanvas(7, .{ 640, 480 }, 1);
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(1, driver.starts);
    try testing.expectEqual(1, driver.steps);
    try testing.expectEqual(zui.Surface{ .web = .{ .canvas = 7 } }, host.zuiSurface(.main));
}

test "an input batch becomes the next record's events in layout units at the page's ratio" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host, .zoom = 1.5 };
    host.attachCanvas(1, .{ 600, 300 }, 2);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ 30, 60 }, .at_milliseconds = 10 });
    host.pointerDown(.{ .id = 4, .kind = 1, .position = .{ 15, 15 }, .pressure = 0.5, .at_milliseconds = 11 }, 0);
    host.pointerDown(.{ .id = 1, .kind = 0, .position = .{ 30, 60 }, .at_milliseconds = 11 }, 3);
    host.wheel(.{ 30, 60 }, .{ 0, 3 }, @intFromEnum(browser_input.WheelDeltaMode.line), 12);
    host.key(true, "a", "KeyA", 0b0001, false, 13);
    host.typed("hé");
    try host.turns().take();

    const record = driver.builder.?.record();
    try testing.expectEqualDeep([2]f32{ 400, 200 }, record.params.viewport);
    try testing.expectEqual(2, record.params.scale);
    try testing.expectEqual(at(1000), record.params.now);
    const events = driver.events();
    try testing.expectEqual(5, events.len);
    try testing.expectEqualDeep([2]f32{ 20, 40 }, events[0].pointer_move.pointer.position);
    try testing.expectEqual(zui.PointerId.mouse, events[0].pointer_move.pointer.id);
    try testing.expectEqual(at(10), events[0].pointer_move.pointer.at);
    try testing.expectEqual(zui.PointerKind.touch, events[1].pointer_down.pointer.kind);
    try testing.expectEqualDeep([2]f32{ 10, 10 }, events[1].pointer_down.pointer.position);
    try testing.expectEqual(0.5, events[1].pointer_down.pointer.pressure);
    try testing.expectEqualDeep([2]f32{ 0, 3 * browser_input.wheel_line_units / 1.5 }, events[2].wheel.delta);
    try testing.expectEqual(zui.Key.a, events[3].key_down.key);
    try testing.expect(events[3].key_down.modifiers.shift);
    try testing.expectEqualStrings("hé", events[4].text);
}

test "a resize changes the viewport and scale, and asks for a turn" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);

    host.resize(.{ 1000, 500 }, 1.25);
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqualDeep([2]f32{ 1000, 500 }, driver.builder.?.params.viewport);
    try testing.expectEqual(1.25, driver.builder.?.params.scale);
}

test "the cursor is shown once for each change" {
    var host = scriptedHost();
    for ([_]zui.Cursor{ .pointer, .pointer, .text, .text, .text, .default }) |cursor| host.zuiApply(.main, .{ .cursor = cursor });
    try testing.expectEqualSlices(zui.Cursor, &.{ .pointer, .text, .default }, host.platform.cursors[0..host.platform.cursor_count]);
}

test "a step's next frame schedules the next turn: an animation frame, a timer, or nothing until input" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host, .answers = &.{ .immediately, .{ .at = at(1030) }, .on_event, null } };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(Schedule{ .timer = at(1030) }, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);

    const schedules = host.platform.schedules;
    host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ 1, 1 }, .at_milliseconds = 1 });
    host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ 2, 2 }, .at_milliseconds = 2 });
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try testing.expectEqual(schedules + 1, host.platform.schedules);

    try host.turns().take();
    try testing.expectEqual(Schedule.ended, host.platform.scheduled);
    try testing.expectEqual(1, driver.stops);
    try host.turns().take();
    try testing.expectEqual(4, driver.steps);
}

test "a wake while a step runs makes the next turn due at once" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host, .answers = &.{.on_event}, .wake_while_stepping = true };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    driver.wake_while_stepping = false;
    try host.turns().take();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);
}

test "a wake answered between turns asks for a turn, and one a turn already took asks for none" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    host.answerWake();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);

    host.zuiWaker().wake();
    host.answerWake();
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    host.answerWake();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);
}

fn sleepFor(io: std.Io, nanoseconds: u64) std.Io.Cancelable!void {
    try io.sleep(.fromNanoseconds(nanoseconds), .awake);
}

test "a task's wake, when sooner than the step's, schedules the turn, on the clock the host steps it to" {
    var stepped: SteppedIo = try .init(testing.allocator, testing.io, .{ .thread_count = 1, .task_capacity = 4 });
    defer stepped.deinit(testing.allocator);
    const thread: std.Thread = try .spawn(.{}, SteppedIo.runThread, .{ &stepped, 0 });
    defer {
        stepped.stopThreads();
        thread.join();
    }
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host, .answers = &.{ .{ .at = at(1100) }, .on_event } };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(stepped.io(), driver.driver());

    var group: std.Io.Group = .init;
    defer group.cancel(stepped.io());
    try group.concurrent(stepped.io(), sleepFor, .{ stepped.io(), 1005 * std.time.ns_per_ms });
    try host.turns().take();
    try testing.expectEqual(1000 * std.time.ns_per_ms, stepped.clock_nanoseconds);
    try testing.expectEqual(Schedule{ .timer = at(1005) }, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(Schedule{ .timer = at(1005) }, host.platform.scheduled);

    host.platform.still_clock = at(1005);
    try host.turns().take();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);
}

test "a lost context suspends the surfaces on the next turn, and its return resumes them" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();

    host.loseContext();
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    try host.turns().take();
    try testing.expectEqual(1, driver.suspends);
    try testing.expectEqual(0, driver.resumes);

    host.restoreContext();
    try host.turns().take();
    try host.turns().take();
    try testing.expectEqual(1, driver.suspends);
    try testing.expectEqual(1, driver.resumes);
    try testing.expectEqual(5, driver.steps);
}

test "input past the inbox's room is dropped and counted, keeping what came first" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.attachCanvas(1, .{ 800, 600 }, 1);
    host.begin(testing.io, driver.driver());
    try host.turns().take();
    host.typed("first");
    for (0..ScriptedHost.inbox_event_capacity + 4) |index| {
        host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ @floatFromInt(index), 0 }, .at_milliseconds = 1 });
    }
    host.typed("late");
    try host.turns().take();

    const events = driver.events();
    try testing.expectEqual(ScriptedHost.inbox_event_capacity, events.len);
    try testing.expectEqualStrings("first", events[0].text);
    for (events[1..], 0..) |event, index| try testing.expectEqual(@as(f32, @floatFromInt(index)), event.pointer_move.pointer.position[0]);
    try testing.expectEqual(5, driver.builder.?.dropped_events);
    try testing.expectEqual(4, driver.builder.?.dropped_text_bytes);

    host.typed("again");
    try host.turns().take();
    try testing.expectEqual(1, driver.events().len);
    try testing.expectEqualStrings("again", driver.events()[0].text);
    try testing.expectEqual(0, driver.builder.?.dropped_events);
}

fn startedHost(driver: *ScriptedDriver) !void {
    driver.host.attachCanvas(1, .{ 800, 600 }, 1);
    driver.host.begin(testing.io, driver.driver());
    try driver.host.turns().take();
}

test "the first record reports every setting, as the page measured it before the canvas arrived" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    host.changeSetting("theme", "dark");
    host.changeSetting("locale", "fr-CA");
    host.changeSetting("direction", "right_to_left");
    try startedHost(&driver);

    var reported: zui.Environment = .{};
    const events = driver.events();
    try testing.expectEqual(std.meta.fields(PageEnvironment).len, events.len);
    for (events) |event| reported.apply(event.environment);
    try testing.expectEqual(zui.Environment.Theme.dark, reported.theme);
    try testing.expectEqualStrings("fr-CA", reported.locale.tag());
    try testing.expectEqual(zui.ReadingDirection.right_to_left, reported.direction);
    try testing.expectEqual(zui.Environment.Contrast.normal, reported.contrast);
    try testing.expect(reported.window_focused);
}

test "each setting the page changes reaches the next record once, and an unchanged one sends nothing" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    try startedHost(&driver);

    const changes = [_]struct { name: []const u8, text: []const u8, expected: zui.EnvironmentChange }{
        .{ .name = "theme", .text = "dark", .expected = .{ .theme = .dark } },
        .{ .name = "contrast", .text = "high", .expected = .{ .contrast = .high } },
        .{ .name = "reduced_motion", .text = "true", .expected = .{ .reduced_motion = true } },
        .{ .name = "reduced_transparency", .text = "true", .expected = .{ .reduced_transparency = true } },
        .{ .name = "locale", .text = "ar-EG", .expected = .{ .locale = try .parse("ar-EG") } },
        .{ .name = "direction", .text = "right_to_left", .expected = .{ .direction = .right_to_left } },
        .{ .name = "window_focused", .text = "false", .expected = .{ .window_focused = false } },
    };
    comptime std.debug.assert(changes.len == std.meta.fields(PageEnvironment).len);
    for (changes) |change| {
        host.changeSetting(change.name, change.text);
        try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
        try host.turns().take();
        try testing.expectEqual(1, driver.events().len);
        try testing.expect(std.meta.eql(change.expected, driver.events()[0].environment));

        const schedules = host.platform.schedules;
        host.changeSetting(change.name, change.text);
        try testing.expectEqual(schedules, host.platform.schedules);
        try host.turns().take();
        try testing.expectEqual(0, driver.events().len);
    }
}

test "a setting changed and changed back between two polls sends nothing" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    try startedHost(&driver);
    host.changeSetting("theme", "dark");
    host.changeSetting("theme", "light");
    try host.turns().take();
    try testing.expectEqual(0, driver.events().len);
}

test "a setting or a value the host does not know is left out" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    try startedHost(&driver);
    const schedules = host.platform.schedules;
    host.changeSetting("accent_color", "dark");
    host.changeSetting("theme", "sepia");
    host.changeSetting("reduced_motion", "yes");
    host.changeSetting("locale", "");
    try testing.expectEqual(schedules, host.platform.schedules);
    try testing.expectEqual(PageEnvironment{}, host.page_environment);
}

test "a language tag longer than a locale holds keeps the whole subtags that fit" {
    var environment: PageEnvironment = .{};
    try testing.expect(environment.set("locale", "en-US-x-twain-and-tom-sawyer"));
    try testing.expectEqualStrings("en-US-x-twain-and-tom", environment.locale.tag());
    try testing.expect(!environment.set("locale", "x" ** (zui.Locale.capacity + 1) ++ "-US"));
    try testing.expectEqualStrings("en-US-x-twain-and-tom", environment.locale.tag());
}

test "a hidden page is suspend in the next record, then draws nothing, and shown again is resume" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    try startedHost(&driver);

    host.showPage(false);
    try testing.expectEqual(Schedule.animation_frame, host.platform.scheduled);
    try host.turns().take();
    try testing.expectEqual(1, driver.events().len);
    try testing.expectEqual(zui.Lifecycle.@"suspend", driver.events()[0].lifecycle);
    try testing.expectEqual(1, driver.suspends);
    try testing.expectEqual(Schedule.input, host.platform.scheduled);

    host.showPage(false);
    host.pointerMove(.{ .id = 1, .kind = 0, .position = .{ 5, 5 }, .at_milliseconds = 1 });
    try host.turns().take();
    try testing.expectEqual(Schedule.input, host.platform.scheduled);
    try testing.expectEqual(1, driver.suspends);

    host.showPage(true);
    try host.turns().take();
    try testing.expectEqual(1, driver.resumes);
    const events = driver.events();
    try testing.expectEqual(2, events.len);
    try testing.expectEqual(zui.PointerId.mouse, events[0].pointer_move.pointer.id);
    try testing.expectEqual(zui.Lifecycle.@"resume", events[1].lifecycle);
}

test "a page shown while its context is lost resumes its surfaces only once the context returns" {
    var host = scriptedHost();
    var driver: ScriptedDriver = .{ .host = &host };
    try startedHost(&driver);
    host.showPage(false);
    host.loseContext();
    try host.turns().take();
    host.showPage(true);
    try host.turns().take();
    try testing.expectEqual(1, driver.suspends);
    try testing.expectEqual(0, driver.resumes);
    host.restoreContext();
    try host.turns().take();
    try testing.expectEqual(1, driver.resumes);
}
