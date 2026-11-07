//! `zig build check` compiles this for the selected target. zui's code is
//! generic, and generic code is only type-checked once instantiated, so
//! this drives one full frame through every declaration function.

const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect");
const zui_tracy = @import("zui_tracy");

const CheckText = struct {
    pub fn zuiMeasure(_: *CheckText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }
};

const Ui = zui.Context(.{ .limits = .{ .max_elements = 64 }, .Text = CheckText, .CustomData = u32, .ImageHandle = u32 });

var check_text: CheckText = .{};
var memory: [Ui.required_bytes]u8 align(Ui.buffer_alignment) = undefined;

const Expanded = struct { open: bool };

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
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .id = save, .focusable = true, .cursor = if (ui.environment().theme == .dark) .pointer else null, .decoration = .{ .background = if (ui.widgetState(save) == .hovered) .black else .white }, .layout = .{ .sizing = .{ .width = .{ .rule = .grow, .amount = 1, .max = 40 } } } });
    ui.open(.{ .id = list, .scroll = .both, .focus_scope = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } } });
    ui.box(.{ .clip = .both, .disabled = ui.clicked(save) or ui.pressed(save) or ui.focused(save), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(80) } } });
    ui.box(.{ .floating = .{ .attach_to = .{ .element = save }, .anchor = .center, .z = 2 }, .interactive = true });
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
    return frame.commands().len + @intFromBool(ui.nextFrame() == .immediately) + violation_count + failed_check + frame.elementCount() + host_requests;
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
    return clicks;
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

export fn zuiCheckSources(published: u64) u64 {
    var ui = SourcedUi.initBuffer(&sourced_memory, undefined) catch return 0;
    var wake_target: u8 = 0;
    const waker: zui.Waker = .{ .context = &wake_target, .wakeFn = wakeNothing };
    check_sources.catalog.published = published;
    waker.wakeIf(.needed);
    ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } }, &check_sources) catch return 0;
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
    return shown +% ui.framesSinceRead(.catalog) +% ui.framesSinceRead(.prices) +% second.diagnostics.refused_publishes +% pending;
}
