//! `zig build check` compiles this for the selected target. zui's code is
//! generic, and generic code is only type-checked once instantiated, so
//! this drives one full frame through every declaration function.

const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect");

const CheckPlatform = struct {
    pub fn measureText(_: *CheckPlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }
    pub fn scale(_: *const CheckPlatform) f32 {
        return 2;
    }
};

const Ui = zui.Context(.{ .max_elements = 64, .CustomData = u32, .ImageHandle = u32 }, CheckPlatform);

var platform: CheckPlatform = .{};
var memory: [Ui.required_bytes]u8 align(16) = undefined;

const Expanded = struct { open: bool };

var pool: zui.TaskPool(error{Unavailable}!u32, 2) = .init;

fn lookUp(value: u32) error{Unavailable}!u32 {
    return if (value == 0) error.Unavailable else value;
}

export fn zuiCheckFrame(width: f32, height: f32, pointer_x: f32, pointer_y: f32) usize {
    var ui = Ui.initBuffer(&memory, undefined, &platform) catch return 0;
    ui.beginFrame(.{
        .viewport = .{ width, height },
        .pointer = .{ pointer_x, pointer_y },
        .buttons = .initOne(.primary),
        .wheel = .{ 0, 10 },
        .keys_pressed = &.{ .tab, .enter },
        .modifiers = .{ .shift = true },
        .text_input = "x",
    });
    const save: zui.Id = .of("save");
    const list: zui.Id = .of("list");
    ui.open(.{ .id = .of("root"), .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 2 }, .background = .white, .border = .{ .color = .black, .widths = .all(1) } });
    ui.text("check every pass", .{ .wrap = .words, .alignment = .center });
    ui.image(1, .{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .percent(0.5) } } });
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .id = save, .focusable = true, .background = if (ui.widgetState(save) == .hovered) .black else .white, .layout = .{ .sizing = .{ .width = .growBetween(0, 40) } } });
    ui.open(.{ .id = list, .scroll = .both, .focus_scope = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } } });
    ui.box(.{ .clip = .both, .disabled = ui.clicked(save) or ui.pressed(save) or ui.focused(save), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(80) } } });
    ui.box(.{ .floating = .{ .attach_to = .{ .element = save }, .anchor = .center, .z = 2 }, .interactive = true });
    ui.close();
    ui.close();
    ui.state(save, Expanded).open = ui.keyPressed(.enter) and ui.modifiers().shift and ui.typedText().len == 1;
    ui.setScrollOffset(list, ui.scrollOffset(list));
    ui.requestFocus(save);
    _ = ui.pointerLocal(save);
    _ = ui.rectOf(list);
    _ = ui.stateIfPresent(list, Expanded);
    switch (pool.request(&ui, save, lookUp, .{3}, .{ .key = 1 })) {
        .pending, .failed => ui.requestFrame(),
        .ready => |value| _ = value,
    }
    declareWidgets(&ui);
    const frame = ui.endFrame() catch ui.lastFrame();
    defer ui.release(frame);
    defer pool.deinit(&ui);
    var snapshot_buffer: [256]u8 = undefined;
    var snapshot_writer: std.Io.Writer = .fixed(&snapshot_buffer);
    zui_testing.snapshot(&snapshot_writer, frame.commands(), zui.ids(.{"save"})) catch {};
    const violation_count = @intFromBool(zui_testing.findViolation(frame.commands()) != null);
    return frame.commands().len + @intFromBool(ui.needsFrame()) + violation_count;
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
    const widgets: zui_widgets.Widgets(Ui) = .{};
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

const ThreadSafePlatform = struct {
    pub const thread_safe_measure = true;

    pub fn measureText(_: *ThreadSafePlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }
};

const ParallelUi = zui.Context(.{ .max_elements = 64, .parallel_measure_threshold = 1 }, ThreadSafePlatform);

var thread_safe_platform: ThreadSafePlatform = .{};
var parallel_memory: [ParallelUi.required_bytes]u8 align(16) = undefined;

export fn zuiCheckParallelMeasurement() usize {
    var ui = ParallelUi.initBuffer(&parallel_memory, undefined, &thread_safe_platform) catch return 0;
    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    ui.text("measured on several threads", .{});
    ui.text("once the first text missed", .{ .wrap = .newlines });
    const frame = ui.endFrame() catch ui.lastFrame();
    defer ui.release(frame);
    return frame.commands().len;
}

const TestingUi = zui.Context(.{ .max_elements = 32 }, zui_testing.FixedMetricsPlatform(u16));

var testing_platform: zui_testing.FixedMetricsPlatform(u16) = .{};
var testing_memory: [TestingUi.required_bytes]u8 align(16) = undefined;

fn declareButton(clicks: *u32, ui: *TestingUi) void {
    if (ui.clicked(.of("button"))) clicks.* += 1;
    ui.box(.{ .id = .of("button"), .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
}

export fn zuiCheckDriver() u32 {
    var ui = TestingUi.initBuffer(&testing_memory, undefined, &testing_platform) catch return 0;
    var driver: zui_testing.Driver(TestingUi) = .{ .ui = &ui };
    var clicks: u32 = 0;
    _ = driver.frame(&clicks, declareButton, .{}) catch return 0;
    _ = driver.click(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.drag(&clicks, declareButton, .of("button"), .{ 0, 0 }, .{ 1, 1 }) catch return 0;
    _ = driver.hover(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.focus(&clicks, declareButton, .of("button")) catch return 0;
    _ = driver.pressKeys(&clicks, declareButton, &.{.enter}) catch return 0;
    _ = driver.typeText(&clicks, declareButton, "typed") catch return 0;
    return clicks;
}
