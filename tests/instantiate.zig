//! `zig build check` compiles this for the selected target. zui's code is
//! generic, and generic code is only type-checked once instantiated, so
//! this drives one full frame through every declaration function.

const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_async = @import("zui_async");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect");
const zui_tracy = @import("zui_tracy");
const zui_app = @import("zui_app");
const zui_wire = @import("zui_wire");

/// A freestanding target has no default log output, so an application there
/// brings its own, as this one does.
pub const std_options: std.Options = .{ .logFn = discardLog };

fn discardLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

const CheckText = struct {
    pub fn zuiMeasure(_: *CheckText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }
};

const Ui = zui.Context(.{ .limits = .{ .max_elements = 64 }, .Text = CheckText, .CustomData = u32, .ImageHandle = u32, .features = .{ .semantics = true, .flex_wrap = true } });

var check_text: CheckText = .{};
var memory: [Ui.required_bytes]u8 align(Ui.buffer_alignment) = undefined;

const Expanded = struct { open: bool };

const check_style = zui.static(zui.Style{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = .white } });

export fn zuiCheckFrame(width: f32, height: f32, pointer_x: f32, pointer_y: f32) usize {
    var ui = Ui.initBuffer(&memory, undefined, &check_text) catch return 0;
    const at: zui.Instant = .fromNanoseconds(1);
    const mouse: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ pointer_x, pointer_y }, .at = at };
    const finger: zui.Pointer = .{ .id = @enumFromInt(1), .kind = .touch, .position = .{ pointer_x, pointer_y }, .at = at };
    var sampler: zui.InputSampler = .{};
    var sampled: [8]zui.Event = undefined;
    _ = sampler.sample(at, .{ .pointer = .{ pointer_x, pointer_y }, .buttons = .initOne(.primary) }, &sampled);
    ui.beginFrame(&.{
        .params = .{ .now = at, .viewport = .{ width, height }, .scale = 2, .zoom = 1.5 },
        .events = &.{
            .{ .pointer_move = .{ .pointer = mouse } },
            .{ .pointer_down = .{ .pointer = mouse } },
            .{ .pointer_up = .{ .pointer = mouse, .button = .primary } },
            .{ .pointer_down = .{ .pointer = finger } },
            .{ .pointer_cancel = finger.id },
            .{ .pointer_leave = .mouse },
            .{ .wheel = .{ .position = .{ pointer_x, pointer_y }, .delta = .{ 0, 10 }, .at = at } },
            .{ .key_down = .{ .key = .tab, .modifiers = .{ .shift = true }, .at = at } },
            .{ .key_up = .{ .key = .tab, .at = at } },
            .{ .key_down = .{ .key = .enter, .at = at } },
            .{ .text = "x" },
            .{ .environment = .{ .theme = .dark } },
            .{ .environment = .{ .locale = zui.Locale.parse("fr-CA") catch .default } },
        },
    });
    const save: zui.Id = .of("save");
    const list: zui.Id = .of("list");
    ui.open(.{ .id = .of("root"), .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 2 }, .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) } } });
    ui.text("check every pass", .{ .wrap = .words, .alignment = .center, .letter_spacing = 1 });
    ui.image(.{ .handle = 1 }, .{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .percent(0.5) } } });
    ui.image(.{ .handle = 1, .natural_size = .{ 16, 9 } }, .{ .layout = .{ .sizing = .{ .width = .grow } } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .aspectRatio(16.0 / 9.0) } } });
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .id = save, .focusable = true, .cursor = if (ui.environment().theme == .dark) .pointer else null, .decoration = .{ .background = if (ui.widgetState(save) == .hovered) .black else .white }, .layout = .{ .sizing = .{ .width = .{ .rule = .grow, .amount = 1, .max = 40 } } } });
    ui.open(.{ .id = list, .scroll = .both, .focus_scope = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } } });
    ui.wrapChildren();
    ui.box(.{ .clip = .both, .disabled = ui.clicked(save) or ui.pressed(save) or ui.focused(save), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(80) } } });
    ui.box(.{ .floating = .{ .attach_to = .{ .element = save }, .anchor = .center, .z = 2, .capture = false, .clip = .target }, .interactive = true });
    ui.box(.{ .style = check_style, .decoration = if (ui.hovered(save)) .{ .background = .black } else null });
    ui.close();
    ui.close();
    ui.state(save, Expanded).open = ui.keyPressed(.enter) and ui.chordPressed(.{ .key = .tab, .modifiers = .{ .shift = true } }) and ui.typedText().len == 1 and ui.keyEvents().len == 2;
    ui.setScrollOffset(list, ui.scrollOffset(list));
    ui.requestFocus(save);
    ui.requestTextInput(save, list);
    ui.requestFrameAt(ui.now().addSeconds(ui.dt() + 0.5));
    _ = ui.pointerLocal(save);
    _ = ui.primaryPointer();
    _ = ui.measureText("measured", .{});
    _ = ui.rectOf(list);
    _ = ui.stateIfPresent(list, Expanded);
    _ = ui.manipulation(list);
    declareWidgets(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    var snapshot_buffer: [256]u8 = undefined;
    var snapshot_writer: std.Io.Writer = .fixed(&snapshot_buffer);
    zui_testing.snapshot(&snapshot_writer, frame.commands(), zui.ids(.{"save"})) catch {};
    const violation_count = @intFromBool(zui_testing.findViolation(frame.commands()) != null);
    const failed_check = @intFromBool(std.meta.isError(frame.diagnostics.check()));
    const requests = frame.requests();
    const host_requests = @intFromEnum(requests.cursor) + @intFromBool(requests.text_input != null);
    return frame.commands().len + @intFromBool(ui.nextFrame() == .immediately) + violation_count + failed_check + frame.elementCount() + host_requests + frame.semantics().len;
}

const Settings = struct {
    enabled: bool = true,
    volume: f32 = 0.5,
    retries: i8 = 3,
    quality: enum { low, high } = .low,
    name: zui_widgets.EditableText = .{ .buffer = &name_bytes },
    version: []const u8 = "0.4.0",
    nested: struct { depth: u64 = 1 } = .{},

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{ .volume = .{ .min = 0, .max = 1 } } };
};

var name_bytes: [16]u8 = undefined;
var settings: Settings = .{};

fn declareWidgets(ui: *Ui) void {
    const widgets: zui_widgets.Widgets(Ui) = .{ .dark_theme = .{} };
    var expanded = true;
    var choice: usize = 0;
    widgets.labeledRow(ui, "row");
    _ = widgets.button(ui, .of("button"), "button", .{});
    ui.close();
    _ = widgets.disclosure(ui, .of("disclosure"), "disclosure", &expanded);
    _ = widgets.dropdown(ui, .of("dropdown"), &choice, &.{ "a", "b" }, .{});
    _ = widgets.slider(ui, .of("slider"), &settings.retries, .{ .max = 10 });
    _ = zui_reflect.inspector(widgets, ui, .of("settings"), &settings);
}

const ThreadSafeText = struct {
    pub const zui_thread_safe = true;

    pub fn zuiMeasure(_: *ThreadSafeText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }

    pub fn zuiSegment(_: *ThreadSafeText, paragraph: []const u8, breaks: *zui.BreakSink) void {
        for (paragraph, 0..) |byte, index| if (byte == ' ') breaks.add(index + 1);
    }
};

const ParallelUi = zui.Context(.{ .limits = .{ .max_elements = 64, .parallel_measure_threshold = 1 }, .Text = ThreadSafeText });

var thread_safe_text: ThreadSafeText = .{};
var parallel_memory: [ParallelUi.required_bytes]u8 align(ParallelUi.buffer_alignment) = undefined;

export fn zuiCheckParallelMeasurement() usize {
    var ui = ParallelUi.initBuffer(&parallel_memory, undefined, &thread_safe_text) catch return 0;
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.text("measured on several threads", .{});
    ui.text("once the first text missed", .{ .wrap = .newlines });
    const frame = ui.endFrame();
    defer ui.release(frame);
    return frame.commands().len;
}

const TextlessUi = zui.Context(.{ .limits = .{ .max_elements = 8 } });

var textless_memory: [TextlessUi.required_bytes]u8 align(TextlessUi.buffer_alignment) = undefined;

export fn zuiCheckWithoutText() usize {
    var ui = TextlessUi.initBuffer(&textless_memory, undefined) catch return 0;
    ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } }) catch return 0;
    ui.box(.{ .decoration = .{ .background = .black } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    return frame.commands().len;
}

const EveryCommandRenderer = struct {
    pub const zui_commands: zui.CommandSet = .initFull();
    pub const zui_surfaces: zui.SurfaceKinds = .initFull();
    pub const zui_extended_color = false;
    pub const zui_render_thread = true;
    pub const ImageHandle = u32;
    pub const MaterialHandle = u8;
    pub const CustomData = u16;

    drawn: usize = 0,

    pub fn zuiSubmit(self: *EveryCommandRenderer, surface: zui.Surface, frame: anytype) !void {
        if (surface != .offscreen) return error.UnsupportedSurface;
        for (frame.commands()) |command| {
            self.drawn += switch (command.payload) {
                .rectangle, .border, .text, .clip_begin, .clip_end => 1,
                .image, .custom => 2,
                .gradient, .shadow, .backdrop_blur, .transform_begin, .transform_end, .material => 3,
            };
        }
    }
};

const every_command_config: zui.Config = config: {
    zui.checkRenderer(EveryCommandRenderer);
    break :config .{
        .limits = .{ .max_elements = 16 },
        .commands = EveryCommandRenderer.zui_commands,
        .ImageHandle = EveryCommandRenderer.ImageHandle,
        .MaterialHandle = EveryCommandRenderer.MaterialHandle,
        .CustomData = EveryCommandRenderer.CustomData,
    };
};
const RendererUi = zui.Context(every_command_config);

var renderer_memory: [RendererUi.required_bytes]u8 align(RendererUi.buffer_alignment) = undefined;

export fn zuiCheckRenderer() usize {
    var ui = RendererUi.initBuffer(&renderer_memory, undefined) catch return 0;
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.image(.{ .handle = 7 }, .{ .decoration = .{ .background = .black } });
    ui.custom(3, .{});
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: EveryCommandRenderer = .{};
    renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 100, 100 } } }, frame) catch return 0;
    return renderer.drawn;
}

const OffscreenHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many };

    polls: u32 = 0,
    applied: zui.HostRequests = .{},

    pub fn init(self: *OffscreenHost, _: std.Io, _: zui.WindowOptions) !void {
        self.* = .{};
    }

    pub fn deinit(_: *OffscreenHost) void {}

    pub fn zuiPoll(self: *OffscreenHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        self.polls += 1;
        record.begin(.{ .now = .fromNanoseconds(self.polls), .viewport = .{ 100, 100 } });
        record.appendText("a");
        return self.polls == 1;
    }

    pub fn zuiWaker(self: *OffscreenHost) zui.Waker {
        return .{ .context = self, .wakeFn = wakeNothing };
    }

    pub fn zuiWait(_: *OffscreenHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *OffscreenHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 100, 100 } } };
    }

    pub fn zuiApply(self: *OffscreenHost, _: zui.WindowId, requests: zui.HostRequests) void {
        self.applied = requests;
    }
};

export fn zuiCheckHost() usize {
    comptime zui.checkHostAndRenderer(OffscreenHost, EveryCommandRenderer);
    var ui = RendererUi.initBuffer(&renderer_memory, undefined) catch return 0;
    var host: OffscreenHost = .{};
    var renderer: EveryCommandRenderer = .{};
    var events: [4]zui.Event = undefined;
    var text: [4]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text);
    while (host.zuiPoll(.main, &builder)) {
        ui.beginFrame(&builder.record());
        ui.box(.{ .decoration = .{ .background = .black } });
        const frame = ui.endFrame();
        renderer.zuiSubmit(host.zuiSurface(.main), frame) catch return 0;
        host.zuiApply(.main, frame.requests());
        ui.release(frame);
        host.zuiWait(ui.nextFrame());
    }
    host.zuiWaker().wake();
    return renderer.drawn;
}

const CheckApp = struct {
    pub const Host = OffscreenHost;
    pub const Renderer = EveryCommandRenderer;
    const AppUi = zui.Context(zui_app.contextConfig(EveryCommandRenderer, .{ .limits = .{ .max_elements = 16 } }));

    frames: u32 = 0,

    pub fn zuiDeclare(app: *CheckApp, ui: *AppUi) void {
        app.frames += 1;
        ui.box(.{ .decoration = .{ .background = .black } });
    }

    pub fn zuiLoader(app: *CheckApp, _: *const AppUi, _: std.Io) void {
        app.frames += 1;
    }
};

var app_runner: zui_app.Runner(CheckApp) = undefined;
var app_memory: [CheckApp.AppUi.required_bytes + 4096]u8 = undefined;

export fn zuiCheckApp(io: *const std.Io) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&app_memory);
    app_runner.start(.{ .gpa = fixed.allocator(), .io = io.* }, .{ .title = "check", .notify = ignoreNotice }) catch return 0;
    defer app_runner.stop();
    while (app_runner.frame() catch return 0) {}
    return app_runner.app.frames;
}

export fn zuiCheckRun(init: *const std.process.Init) usize {
    zui_app.run(CheckApp, init.*, .{}) catch return 0;
    return 1;
}

fn ignoreNotice(_: zui_app.Notice) void {}

const TextDrawingRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    text: *const CheckText,
    drawn: usize = 0,

    pub fn init(self: *TextDrawingRenderer, _: zui.Surface, text: *const CheckText) !void {
        self.* = .{ .text = text };
    }

    pub fn zuiSubmit(self: *TextDrawingRenderer, _: zui.Surface, frame: anytype) !void {
        self.drawn += frame.commands().len;
    }
};

const CheckTextApp = struct {
    pub const Host = OffscreenHost;
    pub const Renderer = TextDrawingRenderer;
    pub const Text = CheckText;
    const AppUi = zui.Context(zui_app.contextConfig(TextDrawingRenderer, .{ .limits = .{ .max_elements = 16 }, .Text = CheckText }));

    zoom: f32 = 2,

    pub fn zuiRecord(app: *CheckTextApp, record: *zui.RecordBuilder) void {
        record.params.zoom = app.zoom;
    }

    pub fn zuiDeclare(_: *CheckTextApp, ui: *AppUi) void {
        ui.text("check", .{});
    }
};

var text_app_runner: zui_app.Runner(CheckTextApp) = undefined;
var text_app_memory: [CheckTextApp.AppUi.required_bytes + 4096]u8 = undefined;

export fn zuiCheckAppWithText(io: *const std.Io) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&text_app_memory);
    text_app_runner.start(.{ .gpa = fixed.allocator(), .io = io.* }, .{ .notify = ignoreNotice }) catch return 0;
    defer text_app_runner.stop();
    while (text_app_runner.frame() catch return 0) {}
    return text_app_runner.renderer.drawn;
}

const EveryCommandHarness = struct {
    pub const config: zui.Config = every_command_config;

    drawn: EveryCommandRenderer = .{},
    host_under_test: OffscreenHost = .{},

    pub fn renderer(self: *EveryCommandHarness) *EveryCommandRenderer {
        return &self.drawn;
    }

    pub fn beginDraw(_: *EveryCommandHarness, size: [2]u32) zui.Surface {
        return .{ .offscreen = .{ .size = size } };
    }

    pub fn pixel(_: *EveryCommandHarness, _: u32, _: u32) zui.Color {
        return .black;
    }

    pub fn image(_: *EveryCommandHarness, color: zui.Color) u32 {
        return color.r;
    }

    pub fn custom(_: *EveryCommandHarness) u16 {
        return 1;
    }

    pub fn host(self: *EveryCommandHarness) *OffscreenHost {
        return &self.host_under_test;
    }

    pub fn post(_: *EveryCommandHarness, _: zui.Event) bool {
        return false;
    }
};

export fn zuiCheckConformanceSuites(io: *const std.Io) usize {
    var harness: EveryCommandHarness = .{};
    var nothing: [1]u8 = undefined;
    var no_memory: std.heap.FixedBufferAllocator = .init(&nothing);
    const renderer_violation = zui_testing.findRendererViolation(EveryCommandRenderer, &harness, .{ .gpa = no_memory.allocator(), .io = io.* }) catch return 0;
    const host_violation = zui_testing.findHostViolation(OffscreenHost, &harness, .{ .io = io.* }) catch return 0;
    return @intFromBool(renderer_violation == null) + @intFromBool(host_violation == null);
}

const TestingUi = zui.Context(.{ .limits = .{ .max_elements = 32 }, .Text = zui_testing.FixedMetricsText(u16) });

var testing_text: zui_testing.FixedMetricsText(u16) = .{};
var testing_memory: [TestingUi.required_bytes]u8 align(TestingUi.buffer_alignment) = undefined;

fn declareButton(clicks: *u32, ui: *TestingUi) void {
    if (ui.clicked(.of("button"))) clicks.* += 1;
    ui.box(.{ .id = .of("button"), .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
}

export fn zuiCheckDriver() u32 {
    var ui = TestingUi.initBuffer(&testing_memory, undefined, &testing_text) catch return 0;
    var driver: zui_testing.Driver(TestingUi) = .{ .ui = &ui };
    var clicks: u32 = 0;
    _ = driver.frame(&clicks, declareButton, &.{}) catch return 0;
    _ = driver.click(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.tap(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.drag(&clicks, declareButton, .of("button"), .{ 0, 0 }, .{ 1, 1 }) catch return 0;
    _ = driver.dragFingers(&clicks, declareButton, .of("button"), &.{ .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } }, .{ .from = .{ 1, 1 }, .to = .{ 0, 0 } } }) catch return 0;
    _ = driver.hover(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.focus(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.pressKeys(&clicks, declareButton, &.{.enter}) catch return 0;
    _ = driver.typeText(&clicks, declareButton, "typed") catch return 0;
    return clicks + replayDriven();
}

var recording_memory: [8 * 1024]u8 = undefined;

fn replayDriven() u32 {
    var fixed: std.heap.FixedBufferAllocator = .init(&recording_memory);
    var recording = zui_testing.Recording(WireUi).init(fixed.allocator(), .{ .records = 2, .events = 4, .bytes = 16 }) catch return 0;
    var ui = WireUi.initBuffer(&wire_ui_memory, undefined, &check_text) catch return 0;
    var driver: zui_testing.Driver(WireUi) = .{ .ui = &ui, .sources = &wire_sources };
    ui.relayTo(recording.listener());
    var app: u8 = 0;
    _ = driver.typeText(&app, declareWire, "x") catch return 0;
    ui.relayTo(null);
    for (recording.records()) |*record| _ = driver.replay(&app, declareWire, record) catch return 0;
    return @intCast(recording.records().len + recording.dropped);
}

fn declareWire(_: *u8, ui: *WireUi) void {
    ui.text(ui.typedText(), .{});
    _ = ui.source(.thumbnails).get(1);
}

const CheckTracer = struct {
    var open_zones: u32 = 0;

    pub fn zuiBegin(comptime zone: zui.TraceZone) zui.TraceZone {
        open_zones += 1;
        return zone;
    }

    pub fn zuiEnd(_: zui.TraceZone) void {
        open_zones -= 1;
    }
};

const TracedUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .features = .{ .Tracer = CheckTracer } });

var traced_memory: [TracedUi.required_bytes]u8 align(TracedUi.buffer_alignment) = undefined;

export fn zuiCheckTracer() u32 {
    var ui = TracedUi.initBuffer(&traced_memory, undefined) catch return 0;
    ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } }) catch return 0;
    ui.box(.{ .floating = .{ .z = 1 }, .decoration = .{ .background = .black } });
    ui.release(ui.endFrame());
    zui_tracy.frameMark();
    return CheckTracer.open_zones + @intFromBool(zui.Context(.{ .features = .{ .Tracer = zui_tracy.Tracer } }).Tracing.enabled);
}

const CheckSource = struct {
    pub const Delivery = ?u64;
    pub const View = zui.StatusWithProgress(error{Timeout}!u64, f32);

    published: ?u64 = null,
    status: View = .idle,
    received: ?u64 = null,
    refused: u32 = 0,

    pub fn zuiSwap(self: *CheckSource) void {
        self.received = self.published;
        if (self.published) |value| self.status = .{ .ready = value };
        self.published = null;
    }

    pub fn zuiView(self: *CheckSource) View {
        return self.status;
    }

    pub fn zuiDelivery(self: *const CheckSource, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *CheckSource, delivery: *const Delivery) void {
        if (delivery.*) |value| self.status = .fromResult(value);
    }

    pub fn zuiPending(self: *const CheckSource) bool {
        return self.published != null;
    }

    pub fn zuiEndFrame(_: *CheckSource, _: zui.EndFrameInfo) void {}

    pub fn zuiRefusedCount(self: *CheckSource) u32 {
        defer self.refused = 0;
        return self.refused;
    }
};

const CheckSources = struct {
    catalog: CheckSource = .{},
    prices: CheckSource = .{},
};

const SourcedUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = CheckSources, .features = .{ .Tracer = CheckTracer } });

var sourced_memory: [SourcedUi.required_bytes]u8 align(SourcedUi.buffer_alignment) = undefined;
var check_sources: CheckSources = .{};

fn wakeNothing(_: *anyopaque) void {}

var relayed_catalog: ?u64 = null;

fn relayCatalog(_: *anyopaque, record: *const SourcedUi.FrameRecord) void {
    relayed_catalog = record.deliveries.?.catalog;
}

export fn zuiCheckSources(published: u64) u64 {
    var ui = SourcedUi.initBuffer(&sourced_memory, undefined) catch return 0;
    var wake_target: u8 = 0;
    ui.relayTo(.{ .context = &wake_target, .relayFn = relayCatalog });
    const waker: zui.Waker = .{ .context = &wake_target, .wakeFn = wakeNothing };
    check_sources.catalog.published = published;
    waker.wakeIf(.needed);
    var builder: zui.RecordBuilder = .init(&.{}, &.{});
    builder.begin(.{ .now = .zero, .viewport = .{ 100, 100 } });
    ui.tryBeginFrame(&builder.recordWith(SourcedUi.Deliveries), &check_sources) catch return 0;
    const shown: u64 = switch (ui.source(.catalog)) {
        .idle, .canceled => 0,
        .running => |fraction| @intFromFloat(fraction),
        .ready => |value| value,
        .failed => 1,
    };
    const first = ui.endFrame();
    ui.release(first);
    const recorded: SourcedUi.Deliveries = .{ .catalog = published, .prices = null };
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } }, .deliveries = &recorded }, &check_sources);
    _ = ui.source(.prices);
    const second = ui.endFrame();
    ui.release(second);
    const pending = @intFromBool(ui.nextFrame(&check_sources) == .immediately);
    return shown +% ui.framesSinceRead(.catalog) +% ui.framesSinceRead(.prices) +% second.diagnostics.refused_publishes +% pending +% (relayed_catalog orelse 0);
}

const AsyncCatalog = zui_async.Task(error{Offline}!u32, .{ .Progress = f32 });
const AsyncThumbnails = zui_async.KeyedLoads(u64, error{Corrupt}!u32, .{ .capacity = 8, .owns_resources = true, .Progress = f32 });

const AsyncSources = struct {
    battery: zui_async.Latest(f32) = .{},
    quotes: zui_async.Stream(u32, .{ .capacity = 8, .producers = .many }) = .{},
    log: zui_async.Stream(u8, .{ .capacity = 4 }) = .{},
    catalog: AsyncCatalog = .{},
    thumbnails: AsyncThumbnails = .{},
};

const AsyncUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = AsyncSources });

var async_memory: [AsyncUi.required_bytes]u8 align(AsyncUi.buffer_alignment) = undefined;
var async_sources: AsyncSources = .{};

fn fetchCount(count: u32) error{Offline}!u32 {
    return count;
}

fn declareAsync(total: *u64, ui: *AsyncUi) void {
    total.* +%= @intFromFloat(ui.source(.battery).get() orelse 0);
    var quotes = ui.source(.quotes).items();
    while (quotes.next()) |quote| total.* +%= quote.*;
    total.* +%= ui.source(.log).count();
    switch (ui.source(.catalog).status()) {
        .ready => |count| total.* +%= count,
        .idle, .running, .failed, .canceled => {},
    }
    switch (ui.source(.thumbnails).get(7)) {
        .ready => |handle| total.* +%= handle,
        .idle, .running, .failed, .canceled => {},
    }
}

export fn zuiCheckAsync(value: u32) u64 {
    var ui = AsyncUi.initBuffer(&async_memory, undefined) catch return 0;
    var wake_target: u8 = 0;
    const waker: zui.Waker = .{ .context = &wake_target, .wakeFn = wakeNothing };
    waker.wakeIf(async_sources.battery.publish(@floatFromInt(value)));
    waker.wakeIf(async_sources.quotes.publish(value) catch .already_pending);
    waker.wakeIf(async_sources.log.publish(1) catch .already_pending);
    if (async_sources.catalog.begin(waker)) |run| {
        run.progress(0.5);
        AsyncCatalog.publishing(fetchCount)(run, .{value});
    } else |_| {}
    var total: u64 = 0;
    var driver: zui_testing.Driver(AsyncUi) = .{ .ui = &ui, .sources = &async_sources };
    _ = driver.frame(&total, declareAsync, &.{}) catch return 0;
    var to_start = async_sources.thumbnails.toStart(waker);
    while (to_start.next()) |load| {
        load.progress(0.5);
        if (load.abandoned()) load.finish(error.Corrupt) else load.finish(value);
    }
    _ = driver.frameDelivering(&total, declareAsync, .{ .catalog = .{ .ready = value }, .quotes = .init(&.{value}) }) catch return 0;
    var to_release = async_sources.thumbnails.toRelease();
    while (to_release.next()) |released| total +%= released catch 0;
    if (async_sources.catalog.clear()) |_| total +%= 1;
    async_sources.catalog.abandon();
    return total +% @intFromBool(async_sources.catalog.isIdle()) +% @intFromBool(ui.nextFrame(&async_sources) == .immediately);
}

const FileWatchingHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    sink: ?zui.FileChangeSink = null,

    pub fn zuiPoll(_: *FileWatchingHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }

    pub fn zuiWaker(self: *FileWatchingHost) zui.Waker {
        return .{ .context = self, .wakeFn = wakeNothing };
    }

    pub fn zuiWait(_: *FileWatchingHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *FileWatchingHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }

    pub fn zuiApply(_: *FileWatchingHost, _: zui.WindowId, _: zui.HostRequests) void {}

    pub const zuiFileWatch = struct {
        pub fn watch(host: *FileWatchingHost, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            if (directory.len == 0) return error.DirectoryUnavailable;
            host.sink = sink;
        }
    };
};

var file_changes: zui_async.Stream(zui.FileChange, .{ .capacity = 4, .producers = .one }) = .{};

export fn zuiCheckFileWatch(path_len: usize) usize {
    comptime zui.checkHost(FileWatchingHost);
    var host: FileWatchingHost = .{};
    FileWatchingHost.zuiFileWatch.watch(&host, "themes", .of(&file_changes)) catch return 0;
    const path = "themes/dark.zon";
    host.zuiWaker().wakeIf(host.sink.?.publish(.of(.modified, path[0..@min(path_len, path.len)])));
    file_changes.zuiSwap();
    var changes = file_changes.zuiView().items();
    var total: usize = 0;
    while (changes.next()) |change| total += change.pathBytes().len;
    return total;
}

const WireSources = struct {
    catalog: CheckSource = .{},
    log: zui_async.Stream(u32, .{ .capacity = 4 }) = .{},
    thumbnails: zui_async.KeyedLoads(u64, error{Missing}!u32, .{ .capacity = 2 }) = .{},
};

const WireUi = zui.Context(.{ .limits = .{ .max_elements = 8, .max_render_commands = 16, .max_text_bytes = 64 }, .Text = CheckText, .ImageHandle = u32, .Sources = WireSources });

var wire_ui_memory: [WireUi.required_bytes]u8 align(WireUi.buffer_alignment) = undefined;
var wire_sources: WireSources = .{};
var wire_memory: [16 * 1024]u8 = undefined;
var wire_bytes: [1024]u8 = undefined;

export fn zuiCheckWire(published: u64) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&wire_memory);
    var encoder = zui_wire.Encoder(WireUi).init(fixed.allocator()) catch return 0;
    var decoder = zui_wire.Decoder(WireUi).init(fixed.allocator(), .of(WireUi)) catch return 0;
    var ui = WireUi.initBuffer(&wire_ui_memory, undefined, &check_text) catch return 0;
    var writer: std.Io.Writer = .fixed(&wire_bytes);
    zui_wire.writeHeader(&writer, zui_wire.fingerprintOf(&check_text)) catch return 0;
    const deliveries: WireUi.Deliveries = .{ .catalog = published, .log = .init(&.{ 1, 2 }), .thumbnails = .init(&.{.{ .key = published, .result = error.Missing }}) };
    const record: WireUi.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } }, .events = &.{.{ .text = "x" }}, .deliveries = &deliveries };
    encoder.writeRecord(&writer, &record) catch return 0;
    ui.beginFrame(&record, &wire_sources);
    ui.text("on the wire", .{});
    ui.image(.{ .handle = 3 }, .{});
    const frame = ui.endFrame();
    encoder.writeFrame(&writer, frame) catch return 0;
    encoder.writeKeyFrame(&writer, frame) catch return 0;
    ui.release(frame);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    zui_wire.readHeader(&reader, null) catch return 0;
    var decoded: usize = 0;
    while (decoder.next(&reader) catch return 0) |message| decoded += switch (message) {
        .record => |received| received.events.len + received.deliveries.?.log.slice().len,
        .frame => |received| received.commands().len,
    };
    return decoded;
}

const has_network = @import("builtin").os.tag != .freestanding;

/// The remote host, renderer and client, on every target with a network;
/// they read and write their connection on a task of the `Io`'s own.
export fn zuiCheckRemote(port: u16) usize {
    if (!has_network) return 0;
    const io = std.Io.failing;
    var host: zui_wire.Host(WireUi) = .{};
    host.init(io, .{}) catch return 0;
    defer host.deinit();
    var renderer: zui_wire.Renderer(WireUi) = .{};
    renderer.init(host.zuiSurface(.main), &check_text) catch return 0;
    var fixed: std.heap.FixedBufferAllocator = .init(&wire_memory);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = address.connect(io, .{ .mode = .stream }) catch return 0;
    host.attach(fixed.allocator(), stream) catch return 0;
    var builder: zui.RecordBuilder = .init(&.{}, &.{});
    if (!host.zuiPoll(.main, &builder)) return 0;
    var ui = WireUi.initBuffer(&wire_ui_memory, undefined, &check_text) catch return 0;
    ui.beginFrame(&builder.recordWith(WireUi.Deliveries), &wire_sources);
    const frame = ui.endFrame();
    renderer.zuiSubmit(host.zuiSurface(.main), frame) catch return 0;
    ui.release(frame);
    host.zuiWait(ui.nextFrame(&wire_sources));

    var client: zui_wire.Client(WireUi) = undefined;
    client.init(fixed.allocator(), io, address.connect(io, .{ .mode = .stream }) catch return 0, .{ .waker = host.zuiWaker() }) catch return 0;
    defer client.deinit();
    return @intFromBool(client.frame(&host, &renderer) catch return 0);
}
