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
const zui_debug = @import("zui_debug");
const zui_motion = @import("zui_motion");
const zui_color = @import("zui_color");
const zui_design = @import("zui_design");

/// A freestanding target has no default log output, so an application there
/// brings its own, as this one does.
pub const std_options: std.Options = .{ .logFn = discardLog };

fn discardLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

const CheckText = struct {
    pub fn zuiMeasure(_: *CheckText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }
};

const Ui = zui.Context(.{ .limits = .{ .max_elements = 64 }, .Text = CheckText, .CustomData = u32, .ImageHandle = u32, .features = .{ .semantics = true, .flex_wrap = true, .chrome_regions = true } });

var check_text: CheckText = .{};
var inspector: zui_debug.Inspector(Ui) = .{};
var memory: [Ui.required_bytes]u8 align(Ui.buffer_alignment) = undefined;

const Expanded = struct { open: bool };

const check_effects: zui.Effects = .{ .gradient = .{ .from = .black, .to = .white, .angle = 1 }, .shadow = .glow(.black, 4), .backdrop_blur = .{ .radius = 4, .tint = .rgba(0xffffff40) }, .transform = .{ .rotation = 0.5 } };

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
            .{ .action = .{ .target = zui.Id.of("save").hash, .action = .invoke } },
            .{ .action = .{ .target = zui.Id.of("list").hash, .action = .{ .scroll = .{ 0, 4 } } } },
            .{ .action = .{ .target = zui.Id.of("save").hash, .action = .{ .adjust = -1 } } },
        },
    });
    const save: zui.Id = .of("save");
    const list: zui.Id = .of("list");
    ui.open(.{ .id = .of("root"), .chrome = if (ui.environment().custom_title_bar) .title_bar else null, .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 2 }, .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) } } });
    ui.text("check every pass", .{ .wrap = .words, .alignment = .center, .letter_spacing = 1 });
    ui.image(.{ .handle = 1 }, .{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .percent(0.5) } } });
    ui.image(.{ .handle = 1, .natural_size = .{ 16, 9 } }, .{ .layout = .{ .sizing = .{ .width = .grow } } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .aspectRatio(16.0 / 9.0) } } });
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .id = save, .focusable = true, .cursor = if (ui.environment().theme == .dark) .pointer else null, .decoration = .{ .background = if (ui.widgetState(save) == .hovered) .black else .white }, .layout = .{ .sizing = .{ .width = .{ .rule = .grow, .amount = 1, .max = 40 } } }, .semantics = .{ .role = .button, .label = "Save", .state = .{ .checked = ui.clicked(save) } } });
    ui.open(.{ .id = list, .scroll = .both, .focus_scope = true, .gestures = .{ .pan = if (ui.hovered(list)) .both else .vertical, .zoom = true, .drag = ui.pressed(list), .long_press = true, .double_tap = ui.focused(list), .custom = true }, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } }, .semantics = .{ .role = .list_box, .value = .{ .range = .{ .value = 0.5 } }, .actions = .initOne(.dismiss) } });
    ui.wrapChildren();
    ui.box(.{ .clip = .both, .disabled = ui.clicked(save) or ui.pressed(save) or ui.focused(save), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(80) } } });
    ui.box(.{ .floating = .{ .attach_to = .{ .element = save }, .anchor = .center, .z = 2, .capture = false, .clip = .target }, .interactive = true });
    ui.box(.{ .style = check_style, .decoration = if (ui.hovered(save)) .{ .background = .black } else null });
    ui.box(.{ .style = check_style, .effects = &check_effects });
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
    var recognized = ui.pointerEvents(list);
    if (recognized.next()) |_| ui.claim(.mouse) else ui.decline(.mouse);
    if (ui.dragging(save)) |drag| ui.startDrag(save, drag.translation);
    _ = ui.dropped(list, [2]f32) orelse ui.draggedOver(list, [2]f32);
    _ = ui.doubleTapped(save) or ui.contextRequested(save) or ui.dismissed(list) or ui.adjusted(save) != null or ui.navigated(save) == .up;
    declareWidgets(&ui);
    declareMotion(&ui, pointer_x);
    inspector.declare(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    inspector.observe(frame, .{ pointer_x, pointer_y });
    var snapshot_buffer: [256]u8 = undefined;
    var snapshot_writer: std.Io.Writer = .fixed(&snapshot_buffer);
    zui_testing.snapshot(&snapshot_writer, frame.commands(), zui.ids(.{"save"})) catch {};
    const violation_count = @intFromBool(zui_testing.findViolation(frame.commands()) != null);
    const failed_check = @intFromBool(std.meta.isError(frame.diagnostics.check()));
    const broken_invariant = @intFromBool(frame.sweep() != null);
    const requests = frame.requests();
    const host_requests = @intFromEnum(requests.cursor) + @intFromBool(requests.text_input != null);
    const inspected = frame.inspect(frame.elementCount() - 1);
    const inspected_content = @intFromEnum(inspected.content) + @intFromBool(inspected.effects != null and inspected.floating != null);
    var audit_room: [8]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, .{ .page_background = .white, .focus_ring_color = .black }, &audit_room);
    const command_hash: usize = @truncate(zui_design.hashCommands(frame.commands()));
    return command_hash +% findings.slice().len + findings.dropped + frame.commands().len + @intFromBool(ui.nextFrame() == .immediately) + violation_count + failed_check + broken_invariant + frame.elementCount() + host_requests + frame.semantics().len + frame.chromeRegions().len + inspected_content + inspector.rows().len;
}

const MotionCard = struct { offset: [2]f32, background: zui.Color, glow: zui.ExtendedColor, opacity: f32 };

fn declareMotion(ui: *Ui, target: f32) void {
    const card = zui_motion.tween(ui, .of("motion card"), MotionCard, .{ .offset = .{ target, 0 }, .background = .white, .glow = .rgb(0x3366ff), .opacity = 1 }, .{ .duration = 0.3, .easing = .ease_in_out, .delay = 0.1 });
    const thumb = zui_motion.spring(ui, .of("motion thumb"), [2]f32, .{ target, target }, .{ .angular_frequency = 30 });
    const design_motion = zui_design.default.motion;
    const drawer_x = zui.motion.spring(ui, .of("motion drawer"), f32, target, design_motion.drawer);
    const press_scale = zui.motion.tween(ui, .of("motion press"), f32, design_motion.press_scale, design_motion.press);
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(thumb[0] + card.offset[0] + drawer_x), .height = .fixed(card.opacity * press_scale) } }, .decoration = .{ .background = card.background } });
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

const FlatSkin = struct {
    color: zui.Color = .rgb(0x808080),

    pub fn zuiStyle(skin: *const FlatSkin, _: zui_widgets.Part, _: zui.WidgetState, _: *const zui.Environment) zui_widgets.Style(Ui) {
        return .{ .background = skin.color, .size = .{ 16, 24 } };
    }
};

fn declareWidgets(ui: *Ui) void {
    declareWidgetsWith(zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)){ .skin = .{ .tokens = &resolved_tokens } }, ui, .of("design_skin"));
    declareWidgetsWith(zui_widgets.Widgets(Ui, zui_widgets.DesignSkinWith(Ui, CheckRoles)){ .skin = .{ .tokens = &check_tokens } }, ui, .of("design_skin_with_roles"));
    declareWidgetsWith(zui_widgets.Widgets(Ui, FlatSkin){ .skin = .{} }, ui, .of("flat_skin"));
}

fn declareWidgetsWith(widgets: anytype, ui: *Ui, scope: zui.Id) void {
    var expanded = true;
    var choice: usize = 0;
    widgets.labeledRow(ui, "row");
    _ = widgets.button(ui, scope.child("button"), "button", .{});
    ui.close();
    _ = widgets.disclosure(ui, scope.child("disclosure"), "disclosure", &expanded);
    _ = widgets.dropdown(ui, scope.child("dropdown"), &choice, &.{ "a", "b" }, .{});
    _ = widgets.slider(ui, scope.child("slider"), &settings.retries, .{ .max = 10 });
    var selection: zui_widgets.Lasso = .{};
    _ = widgets.lasso(ui, scope.child("settings"), &selection);
    _ = zui_reflect.inspector(widgets, ui, scope.child("settings"), &settings);
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
                .gradient => |gradient| gradient.colorAt(command.bounds, .{ 0, 0 }).r,
                .transform_begin => |transform| @intFromFloat(@abs(transform.affine(command.bounds).apply(.{ 1, 1 })[0])),
                .shadow, .backdrop_blur, .transform_end, .material => 3,
            };
        }
    }
};

const every_command_config: zui.Config = config: {
    zui.checkRenderer(EveryCommandRenderer);
    break :config .{
        .limits = .{ .max_elements = 16, .exit_ghost_commands = 32 },
        .commands = EveryCommandRenderer.zui_commands,
        .ImageHandle = EveryCommandRenderer.ImageHandle,
        .MaterialHandle = EveryCommandRenderer.MaterialHandle,
        .CustomData = EveryCommandRenderer.CustomData,
        .features = .{ .nested_corners = true },
    };
};
const RendererUi = zui.Context(every_command_config);

var renderer_memory: [RendererUi.required_bytes]u8 align(RendererUi.buffer_alignment) = undefined;

export fn zuiCheckRenderer() usize {
    var ui = RendererUi.initBuffer(&renderer_memory, undefined) catch return 0;
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.image(.{ .handle = 7 }, .{ .decoration = .{ .background = .black } });
    ui.custom(3, .{});
    ui.box(.{ .decoration = .{ .background = .black, .material = 2 } });
    ui.open(.{ .id = .of("card"), .layout = .{ .sizing = .grow_both }, .decoration = .{ .corner_radius = .all(8) }, .effects = &check_effects, .exit = .{ .seconds = 0.2, .fade = .ease_in_out } });
    ui.box(.{ .floating = .{ .z = 1 }, .interactive = true, .decoration = .{ .background = .white } });
    ui.box(.{ .decoration = .{ .background = .white, .material = 1, .nested_corners = .{ .minimum = 2 } } });
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: EveryCommandRenderer = .{};
    renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 100, 100 } } }, frame) catch return 0;
    return renderer.drawn;
}

fn ExtendedColorUi(comptime renderer_draws_extended_color: bool) type {
    return zui.Context(.{
        .limits = .{ .max_elements = 16, .exit_ghost_commands = 16 },
        .commands = .initFull(),
        .ImageHandle = u32,
        .MaterialHandle = u8,
        .Color = zui.ExtendedColor,
        .extended_color = renderer_draws_extended_color,
    });
}
const ClampingColorUi = ExtendedColorUi(false);
const DrawingColorUi = ExtendedColorUi(true);

var clamping_color_memory: [ClampingColorUi.required_bytes]u8 align(ClampingColorUi.buffer_alignment) = undefined;
var drawing_color_memory: [DrawingColorUi.required_bytes]u8 align(DrawingColorUi.buffer_alignment) = undefined;

fn declareExtendedColors(comptime ColorUi: type, buffer: *[ColorUi.required_bytes]u8) usize {
    const hdr_white: zui.ExtendedColor = .linear(4, 4, 4, 1);
    const effects: ColorUi.Effects = .{
        .gradient = .{ .from = .rgb(0x3366ff), .to = hdr_white },
        .shadow = .glow(hdr_white, 8),
        .backdrop_blur = .{ .radius = 4, .tint = .rgba(0xffffff40) },
    };
    var ui = ColorUi.initBuffer(@alignCast(buffer), undefined) catch return 0;
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.image(.{ .handle = 7, .tint = hdr_white }, .{});
    ui.box(.{ .id = .of("hdr"), .decoration = .{ .background = hdr_white, .material = 2, .border = .{ .color = .linear(1.2, -0.1, 0, 1), .widths = .all(1) } }, .effects = &effects, .exit = .{ .seconds = 0.2 } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    return frame.commands().len + @intFromBool(frame.diagnostics.clamped_colors);
}

export fn zuiCheckExtendedColor() usize {
    return declareExtendedColors(ClampingColorUi, &clamping_color_memory) + declareExtendedColors(DrawingColorUi, &drawing_color_memory);
}

const OffscreenHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .custom_title_bar = true };
    pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });

    polls: u32 = 0,
    chrome_region_count: usize = 0,
    applied: zui.HostRequests = .{},
    format: zui.OutputFormat = .sdr,
    windows_opened: u32 = 0,
    windows_closed: u32 = 0,

    pub fn init(self: *OffscreenHost, _: std.Io, window: zui.WindowOptions) !void {
        self.* = .{ .format = if (window.output_formats.contains(.scrgb_fp16)) .scrgb_fp16 else .sdr };
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

    pub fn zuiSurface(self: *OffscreenHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 100, 100 }, .format = self.format } };
    }

    pub fn zuiApply(self: *OffscreenHost, _: zui.WindowId, requests: zui.HostRequests) void {
        self.applied = requests;
    }

    pub fn zuiChromeRegions(self: *OffscreenHost, _: zui.WindowId, regions: []const zui.ChromeRegion) void {
        self.chrome_region_count = regions.len;
    }

    pub fn zuiOpenWindow(self: *OffscreenHost, _: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        self.windows_opened += 1;
        return @enumFromInt(self.windows_opened);
    }

    pub fn zuiCloseWindow(self: *OffscreenHost, _: zui.WindowId) void {
        self.windows_closed += 1;
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
    const shared = comptime zui.sharedOutputFormats(OffscreenHost, EveryCommandRenderer);
    return renderer.drawn + shared.count() + @intFromEnum(host.zuiSurface(.main).outputFormat());
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

    pub fn zuiObserve(app: *CheckApp, _: *const AppUi, frame: *const AppUi.Frame) void {
        app.frames += frame.elementCount();
    }

    pub fn zuiLoader(app: *CheckApp, _: *const AppUi, _: std.Io) void {
        app.frames += 1;
    }
};

var app_runner: zui_app.Session(CheckApp) = undefined;
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

var stepped_app_session: zui_app.Session(CheckApp) = undefined;
var stepped_app_memory: [CheckApp.AppUi.required_bytes + 4096]u8 = undefined;

export fn zuiCheckSessionSteps(io: *const std.Io) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&stepped_app_memory);
    stepped_app_session.start(.{ .gpa = fixed.allocator(), .io = io.* }, .{ .notify = ignoreNotice }) catch return 0;
    defer stepped_app_session.stop();
    var turns: usize = 0;
    while (stepped_app_session.step() catch return 0) |next| : (turns += 1) {
        if (next == .immediately) stepped_app_session.suspendSurfaces();
        stepped_app_session.resumeSurfaces() catch return 0;
    }
    return turns + stepped_app_session.app.frames;
}

/// Runs its own loop, as a page's animation frames would.
const PushCheckHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    turns: u32 = 0,

    pub fn zuiRun(self: *PushCheckHost, io: std.Io, _: zui.WindowOptions, driver: zui.Driver) !void {
        try driver.start(io);
        defer driver.stop();
        while (try driver.step()) |next| {
            if (next == .on_event) driver.suspendSurfaces();
            try driver.resumeSurfaces();
            self.turns += 1;
        }
    }

    pub fn zuiPoll(self: *PushCheckHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        record.begin(.{ .now = .fromNanoseconds(self.turns), .viewport = .{ 100, 100 } });
        return self.turns < 2;
    }

    pub fn zuiWaker(self: *PushCheckHost) zui.Waker {
        return .{ .context = self, .wakeFn = wakeNothing };
    }

    pub fn zuiSurface(_: *PushCheckHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 100, 100 } } };
    }

    pub fn zuiApply(_: *PushCheckHost, _: zui.WindowId, _: zui.HostRequests) void {}
};

const PushCheckApp = struct {
    pub const Host = PushCheckHost;
    pub const Renderer = SurfaceKeepingRenderer;
    const AppUi = zui.Context(zui_app.contextConfig(SurfaceKeepingRenderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 2 }));

    pub fn zuiDeclare(_: *PushCheckApp, ui: *AppUi) void {
        ui.box(.{ .decoration = .{ .background = .black } });
    }
};

export fn zuiCheckPushedRun(setup: *const zui_app.Setup) usize {
    zui_app.runWith(PushCheckApp, setup.*, .{ .notify = ignoreNotice }) catch return 0;
    return 1;
}

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

var text_app_runner: zui_app.Session(CheckTextApp) = undefined;
var text_app_memory: [CheckTextApp.AppUi.required_bytes + 4096]u8 = undefined;

export fn zuiCheckAppWithText(io: *const std.Io) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&text_app_memory);
    text_app_runner.start(.{ .gpa = fixed.allocator(), .io = io.* }, .{ .notify = ignoreNotice }) catch return 0;
    defer text_app_runner.stop();
    while (text_app_runner.frame() catch return 0) {}
    return text_app_runner.renderer.drawn;
}

const SurfaceKeepingRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_render_thread = true;

    drawn: usize = 0,
    attached: usize = 0,

    pub fn zuiSubmit(self: *SurfaceKeepingRenderer, _: zui.Surface, frame: anytype) !void {
        self.drawn += frame.commands().len;
    }

    pub fn zuiAttachSurface(self: *SurfaceKeepingRenderer, _: zui.Surface) error{OutOfMemory}!void {
        self.attached += 1;
    }

    pub fn zuiDetachSurface(self: *SurfaceKeepingRenderer, _: zui.Surface) void {
        self.attached -= 1;
    }
};

const WindowSources = struct { counter: zui_async.Latest(u32) = .{} };

const WindowsCheckApp = struct {
    pub const Host = OffscreenHost;
    pub const Renderer = SurfaceKeepingRenderer;
    const AppUi = zui.Context(zui_app.contextConfig(SurfaceKeepingRenderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 2, .Sources = WindowSources }));

    windows: zui_app.Windows(WindowsCheckApp) = undefined,
    sources: [2]WindowSources = .{ .{}, .{} },
    closed: u32 = 0,

    pub fn init(app: *WindowsCheckApp, start: zui_app.Start(WindowsCheckApp)) !void {
        app.* = .{ .windows = start.windows };
        if (comptime zui_app.Windows(WindowsCheckApp).has_many_windows) _ = try app.windows.open(.{ .title = "second", .visible = false });
    }

    pub fn zuiSources(app: *WindowsCheckApp, window: zui.WindowId) *WindowSources {
        return &app.sources[@min(@intFromEnum(window), 1)];
    }

    pub fn zuiDeclare(_: *WindowsCheckApp, ui: *AppUi, window: zui.WindowId) void {
        if (ui.source(.counter).get()) |count| ui.requestFrameAt(.fromNanoseconds(count));
        ui.box(.{ .decoration = .{ .background = if (window == .main) .black else .white } });
    }

    pub fn zuiLoader(app: *WindowsCheckApp, _: *const AppUi, window: zui.WindowId, _: std.Io) void {
        if (window != .main) app.windows.close(window);
    }

    pub fn zuiWindowClosed(app: *WindowsCheckApp, _: zui.WindowId) void {
        app.closed += 1;
    }
};

var windows_app_runner: zui_app.Session(WindowsCheckApp) = undefined;
var windows_app_memory: [3 * WindowsCheckApp.AppUi.required_bytes + 64 * 1024]u8 = undefined;

export fn zuiCheckAppWithWindows(io: *const std.Io) usize {
    var fixed: std.heap.FixedBufferAllocator = .init(&windows_app_memory);
    windows_app_runner.start(.{ .gpa = fixed.allocator(), .io = io.* }, .{ .notify = ignoreNotice }) catch return 0;
    defer windows_app_runner.stop();
    while (windows_app_runner.frame() catch return 0) {}
    return windows_app_runner.renderer.drawn + windows_app_runner.app.closed;
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

    pub fn material(_: *EveryCommandHarness, color: zui.Color) u8 {
        return color.g;
    }

    pub fn host(self: *EveryCommandHarness) *OffscreenHost {
        return &self.host_under_test;
    }

    pub fn post(_: *EveryCommandHarness, _: zui.Event) bool {
        return false;
    }

    pub fn postTo(_: *EveryCommandHarness, _: zui.WindowId, _: zui.Event) bool {
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

var sdr_read_back: zui_testing.ReadBack(.sdr) = .{ .rows = .bottom_up };
var extended_read_back: zui_testing.ReadBack(.scrgb_fp16) = .{ .rows = .top_down };

export fn zuiCheckHarnessParts() usize {
    var polled_host: OffscreenHost = .{};
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const polled_both = polled.poll(&polled_host) and polled.pollWindow(&polled_host, .main) and polled.find(.key_down) == null;
    const read_pixels = @intFromBool(sdr_read_back.pixel(0, 0).r > 0) + @intFromBool(extended_read_back.pixel(1, 1).r > 1);
    return @intFromBool(polled_both) + read_pixels + sdr_read_back.bytes().len + extended_read_back.bytes().len;
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
    _ = driver.action(&clicks, declareButton, .of("button"), .show_menu) catch return 0;
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

const CheckZoneTimer = zui_debug.ZoneTimer(CheckTracer);
const TimedUi = zui.Context(.{ .limits = .{ .max_elements = 64 }, .Text = CheckText, .features = .{ .Tracer = CheckZoneTimer } });

var timed_memory: [TimedUi.required_bytes]u8 align(TimedUi.buffer_alignment) = undefined;
var timed_inspector: zui_debug.Inspector(TimedUi) = .{};

export fn zuiCheckZoneTimer() u32 {
    var ui = TimedUi.initBuffer(&timed_memory, undefined, &check_text) catch return 0;
    CheckZoneTimer.useClock(ui.io);
    for (0..2) |_| {
        ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } }) catch return 0;
        timed_inspector.declare(&ui);
        const frame = ui.endFrame();
        timed_inspector.observe(frame, null);
        ui.release(frame);
    }
    return @intCast(CheckZoneTimer.frameTimes().ran.count() + timed_inspector.zones.count);
}

const color_tones = zui_color.lightnessScale(4, .rgb(0x3366ff), 0.3, 0.9);

export fn zuiCheckColor(red: u8, amount: f32) u8 {
    const color: zui.Color = .{ .r = red, .g = 40, .b = 200 };
    const mixed = zui_color.mixOklch(color, zui_color.mix(color, .white, amount), amount);
    const hsl: zui_color.Hsl = .fromColor(zui_color.ramp(3, color, mixed)[1]);
    const extended = zui_color.Oklch.fromExtendedColor(.fromColor(hsl.toColor())).toExtendedColor();
    return zui_color.shiftLightness(zui_color.withLightness(extended.toColor(), amount), amount).r +% color_tones[1].g;
}

const CheckChip = struct {
    pub const Part = enum { container, label, close };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs, .states = .{ .pressed = .{ .surface = .accent_container } } },
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .container },
        .close = .{ .icon = .unchecked(.rgb(0xff00ff), "the brand's mark"), .on = .container, .target = .touch, .outline = .outline },
    });

    pub const zuiDistinguish = .{
        .{ .container, .label },
        .{ .close, .idle, .hovered },
    };
};

const CheckRoles = enum {
    brand,
    on_brand,

    pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand };
};

const CheckBadge = struct {
    pub const Part = enum { body, count };

    pub const zuiAppearance = zui.design.AppearanceWith(Part, CheckRoles, .{
        .body = .{ .surface = .extra(.brand), .shape = .indicator },
        .count = .{ .text = .extra(.on_brand), .type = .numeric, .on = .body },
    });
};

var check_tokens: zui.design.Tokens(Ui, CheckRoles) = .{};

export fn zuiCheckDesign(state_index: u8) usize {
    const state: zui.WidgetState = @enumFromInt(state_index % std.enums.values(zui.WidgetState).len);
    const container = check_tokens.look(CheckChip, .container, state);
    const close = check_tokens.look(CheckChip, .close, state);
    const body = check_tokens.look(CheckBadge, .body, state);
    const count = check_tokens.look(CheckBadge, .count, state);
    const plain_tokens: zui.design.Tokens(Ui, void) = .{};
    const label = plain_tokens.look(CheckChip, .label, state);
    const check_design: zui.design.Design = .{ .seeds = .{ .accent = .{ .lightness = 0.6, .chroma = 0.1, .hue = 200 }, .neutral = .{ .lightness = 0.5, .chroma = 0, .hue = 0 } } };
    const shape: zui.CornerShape = check_design.corner_shape;
    return @intFromBool(container.decoration.background != null) + @intFromBool(close.decoration.border != null) + body.decoration.background.?.r +
        count.text.color.g + label.text.color.b + @as(usize, @intFromFloat(container.padding.left + close.min_size[0] + check_tokens.space(.m))) +
        @intFromEnum(shape) + CheckChip.zuiAppearance.unchecked_colors.len;
}

const ExtendedDesignUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Color = zui.ExtendedColor, .FontId = enum(u8) { regular, strong, monospace } });

const ResolvedRoles = enum {
    brand,
    on_brand,
    chart_line,

    pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand, .chart_line = .surface };
};

const resolved_design: zui.design.Design = .{
    .name = "instantiate.resolved_design",
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
};

var resolved_tokens: zui.design.Tokens(Ui, void) = .{};
var resolved_extended_tokens: zui.design.Tokens(ExtendedDesignUi, ResolvedRoles) = .{};
var resolved_environment: zui.Environment = .{};

const tokens_resolved_at_comptime = resolved: {
    var tokens: zui.design.Tokens(Ui, ResolvedRoles) = .{};
    _ = zui_design.resolve(resolved_design, .{ .theme = .dark, .contrast = .high }, &tokens);
    break :resolved tokens;
};

const StatusBadge = struct {
    pub const Part = enum { failed, passed, selected };

    pub const zuiAppearance = zui.design.AppearanceWith(Part, ResolvedRoles, .{
        .failed = .{ .surface = .danger },
        .passed = .{ .surface = .success },
        .selected = .{ .surface = .extra(.brand), .cue = "a check mark" },
    });

    pub const zuiDistinguish = .{
        .{ .failed, .passed },
        .{ .passed, .selected },
    };
};

comptime {
    zui_design.checkDistinguished(resolved_design, .{StatusBadge});
}

const PreviewedBadge = struct {
    pub const Content = struct { count: u32 };

    pub const zuiPreviews = .{
        .none = Content{ .count = 0 },
        .many = Content{ .count = 1200 },
    };
};

export fn zuiCheckPermutations(index: usize) usize {
    const Pairs = zui_design.Permutations(PreviewedBadge, .pairs);
    const Full = zui_design.Permutations(PreviewedBadge, .full);
    const permutation = Full.at(index % Full.count);
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{f}", .{Full.key(permutation)}) catch return 0;
    const parsed = zui_design.PermutationKey.parse(text) catch return 1;
    const preferences = parsed.axes.preferences(.{});
    const changes = parsed.axes.environmentChanges();
    return Pairs.count + zui_design.Permutations(PreviewedBadge, .glance).count + zui_design.Permutations(PreviewedBadge, .sweep).count +
        Full.preview(permutation).count + @intFromBool(parsed.eql(Full.key(permutation))) + @intFromEnum(preferences.density) + changes.len;
}

const MeasuredFontMetrics = struct { ascent: f32, descent: f32, line_gap: f32 = 0, x_height: f32, cap_height: f32 };
var measured_body_face: MeasuredFontMetrics = .{ .ascent = 950, .descent = -290, .x_height = 496, .cap_height = 668 };

export fn zuiCheckDesignResolve() f32 {
    const preferences: zui_design.Preferences = .from(&resolved_environment, .{ .accent = .rgb(0xff8800), .color_vision = .deutan });
    var design_with_faces = resolved_design;
    design_with_faces.type.faces.regular = .of(measured_body_face);
    design_with_faces.type.faces.italic = .of(measured_body_face);
    design_with_faces.type.fonts.italic = 1;
    const repairs = zui_design.resolve(design_with_faces, preferences, &resolved_tokens);
    _ = zui_design.resolve(resolved_design, preferences, &resolved_extended_tokens);
    var audit_room: [4]zui_design.Finding = undefined;
    var findings: zui_design.Findings = .init(&audit_room);
    zui_design.auditDistinguished(&resolved_extended_tokens, .{StatusBadge}, &findings);
    const audit_options: zui_design.AuditOptions = .fromTokens(&resolved_extended_tokens, .high);
    const repaired: f32 = @floatFromInt(repairs.slice().len + repairs.dropped + findings.slice().len);
    const italic_size = resolved_tokens.italic_text_styles.get(.body).size + tokens_resolved_at_comptime.italic_text_styles.get(.title).size;
    return audit_options.target_floor + resolved_tokens.space(.m) + resolved_extended_tokens.space(.m) + tokens_resolved_at_comptime.measure + repaired + italic_size;
}

const CheckPanelTheme = zui_debug.PanelTheme(u16, zui.Color);
const PanelThemeSources = struct {
    theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 4 }) = .{},
    theme: zui_async.Latest(CheckPanelTheme) = .{},
};
const ThemedUi = zui.Context(.{ .limits = .{ .max_elements = 64 }, .Text = CheckText, .Sources = PanelThemeSources });

var themed_memory: [ThemedUi.required_bytes]u8 align(ThemedUi.buffer_alignment) = undefined;
var themed_inspector: zui_debug.Inspector(ThemedUi) = .{};
var panel_theme_sources: PanelThemeSources = .{};
/// A freestanding target has no current directory, so the check reads from
/// a directory it never opens.
var panel_theme_directory: std.Io.Dir = undefined;

export fn zuiCheckPanelThemeReload() u32 {
    var ui = ThemedUi.initBuffer(&themed_memory, undefined, &check_text) catch return 0;
    themed_inspector.theme_file = .{ .directory = panel_theme_directory, .name = "debug.zon" };
    _ = panel_theme_sources.theme_files.publish(.of(.modified, "debug.zon")) catch return 0;
    ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } }, &panel_theme_sources) catch return 0;
    themed_inspector.declareWithThemeFrom(&ui, .{ .file_changes = .theme_files, .theme = .theme });
    ui.release(ui.endFrame());
    const loaded = themed_inspector.loadTheme(ui.io) catch return 1;
    if (loaded) |theme| _ = panel_theme_sources.theme.publish(theme);
    return 2;
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

/// Answers each service at once, as a host whose system answers before the
/// call returns would.
const ServicesHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    copied: [32]u8 = undefined,
    copied_len: usize = 0,
    opened: usize = 0,

    pub fn zuiPoll(_: *ServicesHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }

    pub fn zuiWaker(self: *ServicesHost) zui.Waker {
        return .{ .context = self, .wakeFn = wakeNothing };
    }

    pub fn zuiWait(_: *ServicesHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *ServicesHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }

    pub fn zuiApply(_: *ServicesHost, _: zui.WindowId, _: zui.HostRequests) void {}

    pub const zuiClipboard = struct {
        pub fn write(host: *ServicesHost, text: []const u8) zui.ServiceError!void {
            if (text.len > host.copied.len) return error.TooLarge;
            @memcpy(host.copied[0..text.len], text);
            host.copied_len = text.len;
        }

        pub fn read(host: *ServicesHost, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            host.answer(sink, .{ .request = request, .outcome = .{ .clipboard_text = host.copied[0..host.copied_len] } });
        }
    };

    pub const zuiNotifications = struct {
        pub fn show(host: *ServicesHost, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
            host.answer(sink, .{ .request = request, .outcome = if (notification.title.len == 0) .{ .failed = .denied } else .notification_activated });
        }
    };

    pub const zuiFileDialogs = struct {
        pub fn show(host: *ServicesHost, window: zui.WindowId, request: zui.ServiceRequest, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
            host.answer(sink, .{ .request = request, .window = window, .outcome = if (dialog.file_name.len == 0) .canceled else .{ .files_chosen = dialog.file_name } });
        }
    };

    pub const zuiOpenUrl = struct {
        pub fn open(host: *ServicesHost, url: []const u8) zui.ServiceError!void {
            if (!zui.isOpenableUrl(url)) return error.InvalidUrl;
            host.opened += 1;
        }
    };

    pub const zuiMenus = struct {
        pub fn popup(host: *ServicesHost, window: zui.WindowId, request: zui.ServiceRequest, items: []const zui.MenuItem, _: [2]f32, sink: zui.ServiceSink) zui.ServiceError!void {
            if (items.len == 0) return error.TooLarge;
            host.answer(sink, .{ .request = request, .window = window, .outcome = .{ .menu_item_chosen = items[items.len - 1].id } });
        }

        pub fn setBar(_: *ServicesHost, _: zui.WindowId, _: zui.ServiceRequest, _: []const zui.MenuItem, _: zui.ServiceSink) zui.ServiceError!void {}
    };

    fn answer(self: *ServicesHost, sink: zui.ServiceSink, answered: zui.ServiceAnswer) void {
        self.zuiWaker().wakeIf(sink.publish(&answered));
    }
};

var service_replies: zui_async.Stream(zui.ServiceReply(16), .{ .capacity = 8 }) = .{};

export fn zuiCheckServices(text_len: usize) usize {
    comptime zui.checkHost(ServicesHost);
    var host: ServicesHost = .{};
    const sink: zui.ServiceSink = .of(&service_replies);
    const text = "copied, then pasted";
    ServicesHost.zuiClipboard.write(&host, text[0..@min(text_len, text.len)]) catch return 0;
    ServicesHost.zuiClipboard.read(&host, .of("paste"), sink) catch return 0;
    ServicesHost.zuiNotifications.show(&host, .of("saved"), .{ .title = "Saved" }, sink) catch return 0;
    ServicesHost.zuiFileDialogs.show(&host, .main, .of("open"), .{ .kind = .open_files, .file_name = "a.zon", .filters = &.{.{ .name = "Themes", .extensions = &.{"zon"} }} }, sink) catch return 0;
    ServicesHost.zuiOpenUrl.open(&host, "https://ziglang.org/") catch return 0;
    const items = [_]zui.MenuItem{ .{ .id = @enumFromInt(1), .label = "Cut", .shortcut = .{ .key = .x, .modifiers = .{ .control = true } } }, .separator, .{ .label = "More", .submenu = &.{.{ .id = @enumFromInt(2), .label = "Wrap", .checked = true }} } };
    ServicesHost.zuiMenus.popup(&host, .main, .of("edit"), &items, .{ 10, 20 }, sink) catch return 0;
    service_replies.zuiSwap();
    var replies = service_replies.zuiView().items();
    var total: usize = host.opened;
    while (replies.next()) |reply| total += reply.len + @intFromEnum(reply.kind) + @intFromEnum(reply.menu_item) + reply.left_out_bytes;
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

const zui_icons = @import("zui_icons");

var icon_tokens: zui.design.Tokens(Ui, void) = .{};
var icon_name: zui_icons.Name = .settings;

/// An application's icon font in its design, resolved and drawn as text.
export fn zuiCheckIcons(font: u32) usize {
    var design_with_icons = zui_design.default;
    design_with_icons.icons = zui_icons.tabler;
    design_with_icons.type.fonts.icons = font;
    _ = zui_design.resolve(design_with_icons, .{}, &icon_tokens);
    const check = icon_tokens.icon(.check) orelse return 0;
    return check.utf8().len + zui_icons.utf8(icon_name).len + zui_icons.codepoint(icon_name);
}
