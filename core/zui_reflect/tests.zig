const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect.zig");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{
        .max_elements = 512,
        .max_text_bytes = 4096,
        .max_depth = 24,
        .max_render_commands = 1024,
        .state_slots = 256,
        .measure_cache_entries = 1024,
    },
    .Text = Text,
});
const widgets: zui_widgets.Widgets(Ui) = .{};

const Audio = struct {
    volume: f32 = 0.8,
    muted: bool = false,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .volume = .{ .min = 0, .max = 1 },
    } };
};

const Settings = struct {
    fullscreen: bool = false,
    quality: enum { low, medium, high } = .medium,
    max_fps: u16 = 140,
    gamma: f32 = 1,
    retries: i8 = 126,
    player_name: zui_widgets.EditableText,
    build: []const u8 = "0.4.0",
    audio: Audio = .{},
    frames_rendered: u64 = 0,
    callback: *const fn () void = noop,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .max_fps = .{ .label = "Frame cap", .min = 30, .max = 240, .step = 10 },
        .retries = .{ .max = 100, .step = 2 },
        .frames_rendered = .{ .hidden = true },
        .callback = .{ .hidden = true },
        .player_name = .{ .placeholder = "Anonymous" },
    } };

    fn noop() void {}
};

const settings_id: zui.Id = .of("settings");

const App = struct {
    name_bytes: [32]u8 = undefined,
    settings: Settings = undefined,
    changes: u32 = 0,

    fn init(app: *App) void {
        app.* = .{};
        app.settings = .{ .player_name = .init(&app.name_bytes, "") };
    }

    fn declare(app: *App, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(500) }, .padding = .all(8) } });
        if (zui_reflect.inspector(widgets, ui, settings_id, &app.settings)) app.changes += 1;
        ui.close();
    }
};

const Fixture = struct {
    text: Text = .{},
    ui: Ui = undefined,
    driver: zui_testing.Driver(Ui) = undefined,
    app: App = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
        fixture.driver = .{ .ui = &fixture.ui, .viewport = .{ 600, 800 } };
        fixture.app.init();
        _ = try fixture.frame();
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ui.deinit(testing.allocator);
    }

    fn frame(fixture: *Fixture) !*const Ui.Frame {
        return fixture.driver.frame(&fixture.app, App.declare, &.{});
    }

    fn click(fixture: *Fixture, id: zui.Id) !void {
        _ = try fixture.driver.click(&fixture.app, App.declare, id);
    }
};

test "each field gets the editor for its type" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const frame = try fixture.frame();

    try testing.expect(frame.rectOf(settings_id.child("fullscreen")) != null);
    try testing.expect(frame.rectOf(settings_id.child("quality")) != null);
    try testing.expect(frame.rectOf(settings_id.child("max_fps")) != null);
    try testing.expect(frame.rectOf(settings_id.child("gamma").child("increment")) != null);
    try testing.expect(frame.rectOf(settings_id.child("retries").child("decrement")) != null);
    try testing.expect(frame.rectOf(settings_id.child("player_name")) != null);
    try testing.expect(frame.rectOf(settings_id.child("audio")) != null);
    try testing.expect(frame.rectOf(settings_id.child("audio").child("volume")) != null);
    try testing.expect(frame.rectOf(settings_id.child("frames_rendered").child("increment")) == null);
    try testing.expect(frame.rectOf(settings_id.child("callback")) == null);
    try zui_testing.checkCommands(frame.commands());
    try testing.expect(frame.diagnostics.ok());

    try testing.expect(hasText(frame, "Frame cap"));
    try testing.expect(hasText(frame, "Player name"));
    try testing.expect(hasText(frame, "Anonymous"));
    try testing.expect(hasText(frame, "0.4.0"));
    try testing.expect(hasText(frame, "140"));
    try testing.expect(hasText(frame, "1.00"));
}

fn hasText(frame: *const Ui.Frame, content: []const u8) bool {
    for (frame.commands()) |command| switch (command.payload) {
        .text => |text| if (std.mem.eql(u8, text.content, content)) return true,
        else => {},
    };
    return false;
}

test "editing through the inspector writes the fields" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const settings = &fixture.app.settings;

    try fixture.click(settings_id.child("fullscreen"));
    try testing.expect(settings.fullscreen);
    try testing.expectEqual(@as(u32, 1), fixture.app.changes);

    _ = try fixture.driver.focus(&fixture.app, App.declare, settings_id.child("max_fps"));
    _ = try fixture.driver.pressKeys(&fixture.app, App.declare, &.{.right});
    try testing.expectEqual(@as(u16, 150), settings.max_fps);

    try fixture.click(settings_id.child("gamma").child("increment"));
    try testing.expectApproxEqAbs(@as(f32, 1.1), settings.gamma, 1e-6);

    try fixture.click(settings_id.child("audio").child("muted"));
    try testing.expect(settings.audio.muted);

    _ = try fixture.driver.focus(&fixture.app, App.declare, settings_id.child("player_name"));
    _ = try fixture.driver.typeText(&fixture.app, App.declare, "Ada");
    try testing.expectEqualStrings("Ada", settings.player_name.slice());

    try fixture.click(settings_id.child("quality"));
    _ = try fixture.frame();
    try fixture.click(settings_id.child("quality").indexedChild("option", 2));
    try testing.expectEqual(.high, settings.quality);
    try testing.expectEqual(@as(u32, 6), fixture.app.changes);
}

test "steppers respect the bounds of the options and of the type" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const settings = &fixture.app.settings;

    settings.retries = 99;
    try fixture.click(settings_id.child("retries").child("increment"));
    try testing.expectEqual(@as(i8, 100), settings.retries);
    try fixture.click(settings_id.child("retries").child("increment"));
    try testing.expectEqual(@as(i8, 100), settings.retries);

    settings.retries = -127;
    try fixture.click(settings_id.child("retries").child("decrement"));
    try testing.expectEqual(@as(i8, -128), settings.retries);
}

test "a nested struct collapses and expands" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const audio_id = settings_id.child("audio");

    try fixture.click(audio_id);
    var frame = try fixture.frame();
    try testing.expect(frame.rectOf(audio_id.child("volume")) == null);
    try fixture.click(audio_id);
    frame = try fixture.frame();
    try testing.expect(frame.rectOf(audio_id.child("volume")) != null);
}

test "Options has one entry per field" {
    const fields = @typeInfo(zui_reflect.FieldOptionsOf(Audio)).@"struct".fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("volume", fields[0].name);
    try testing.expectEqual(zui_reflect.FieldOptions, fields[1].type);
}
