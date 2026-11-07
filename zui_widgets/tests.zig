const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets.zig");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{
        .max_elements = 256,
        .max_text_bytes = 4096,
        .max_depth = 16,
        .max_render_commands = 512,
        .state_slots = 256,
        .measure_cache_entries = 1024,
    },
    .Text = Text,
});
const Widgets = zui_widgets.Widgets(Ui);
const Driver = zui_testing.Driver(Ui);

const widgets: Widgets = .{};

const Fixture = struct {
    text: Text = .{},
    ui: Ui = undefined,
    driver: Driver = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
        fixture.driver = .{ .ui = &fixture.ui };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ui.deinit(testing.allocator);
    }
};

const Form = struct {
    const ids = zui.ids(.{ "save", "locked", "autosave", "locked_checkbox", "volume", "level", "name", "quality", "other" });

    clicks: u32 = 0,
    locked_clicks: u32 = 0,
    autosave: bool = false,
    autosave_toggles: u32 = 0,
    locked_checkbox: bool = false,
    volume: f32 = 0.5,
    level: u8 = 3,
    name_bytes: [16]u8 = undefined,
    name: zui_widgets.EditableText = undefined,
    submitted: u32 = 0,
    quality: enum { low, medium, high_quality } = .medium,
    quality_changes: u32 = 0,

    fn init(form: *Form, initial_name: []const u8) void {
        form.* = .{};
        form.name = .init(&form.name_bytes, initial_name);
    }

    fn declare(form: *Form, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) }, .padding = .all(10), .child_gap = 10 } });
        if (widgets.button(ui, ids.save, "Save", .{})) form.clicks += 1;
        if (widgets.button(ui, ids.locked, "Locked", .{ .disabled = true })) form.locked_clicks += 1;
        if (widgets.checkbox(ui, ids.autosave, "Autosave", &form.autosave, .{})) form.autosave_toggles += 1;
        _ = widgets.checkbox(ui, ids.locked_checkbox, "Locked", &form.locked_checkbox, .{ .disabled = true });
        _ = widgets.slider(ui, ids.volume, &form.volume, .{});
        _ = widgets.slider(ui, ids.level, &form.level, .{ .min = 0, .max = 10 });
        if (widgets.textField(ui, ids.name, &form.name, .{ .placeholder = "Name" }).submitted) form.submitted += 1;
        if (widgets.dropdownEnum(ui, ids.quality, &form.quality, .{})) form.quality_changes += 1;
        if (widgets.button(ui, ids.other, "Other", .{})) {}
        ui.close();
    }
};

fn start(fixture: *Fixture, form: *Form, initial_name: []const u8) !void {
    try fixture.init();
    form.init(initial_name);
    _ = try fixture.driver.frame(form, Form.declare, &.{});
}

test "a button reports each click once, and a disabled one never" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&form, Form.declare, Form.ids.save);
    try testing.expectEqual(@as(u32, 1), form.clicks);
    _ = try driver.frame(&form, Form.declare, &.{});
    try testing.expectEqual(@as(u32, 1), form.clicks);

    _ = try driver.pressKeys(&form, Form.declare, &.{.enter});
    try testing.expectEqual(@as(u32, 2), form.clicks);

    _ = try driver.click(&form, Form.declare, Form.ids.locked);
    _ = try driver.focus(&form, Form.declare, Form.ids.locked);
    _ = try driver.pressKeys(&form, Form.declare, &.{.space});
    try testing.expectEqual(@as(u32, 0), form.locked_clicks);
}

test "a checkbox toggles by pointer and by keyboard" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&form, Form.declare, Form.ids.autosave);
    try testing.expect(form.autosave);
    _ = try driver.pressKeys(&form, Form.declare, &.{.space});
    try testing.expect(!form.autosave);
    try testing.expectEqual(@as(u32, 2), form.autosave_toggles);

    _ = try driver.click(&form, Form.declare, Form.ids.locked_checkbox);
    _ = try driver.focus(&form, Form.declare, Form.ids.locked_checkbox);
    _ = try driver.pressKeys(&form, Form.declare, &.{.space});
    try testing.expect(!form.locked_checkbox);
}

test "a slider follows a drag and clamps at its ends" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    const rect = fixture.ui.rectOf(Form.ids.volume).?;
    const thumb_width = widgets.theme.slider_thumb_size[0];
    const quarter = (thumb_width / 2 + (rect.width - thumb_width) * 0.25) / rect.width;
    _ = try driver.drag(&form, Form.declare, Form.ids.volume, .{ 0.5, 0.5 }, .{ quarter, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.25), form.volume, 1e-4);

    _ = try driver.drag(&form, Form.declare, Form.ids.volume, .{ 0.5, 0.5 }, .{ 3, 0.5 });
    try testing.expectEqual(@as(f32, 1), form.volume);
    _ = try driver.drag(&form, Form.declare, Form.ids.volume, .{ 0.5, 0.5 }, .{ -2, 0.5 });
    try testing.expectEqual(@as(f32, 0), form.volume);
}

test "the slider thumb is drawn at the value" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();

    form.volume = 0.25;
    const frame = try fixture.driver.frame(&form, Form.declare, &.{});
    const track = frame.rectOf(Form.ids.volume).?;
    const thumb = thumbOf(frame.commands(), track) orelse return error.ThumbNotFound;
    const travel = track.width - widgets.theme.slider_thumb_size[0];
    try testing.expectApproxEqAbs(track.x + travel * 0.25, thumb.x, 0.5);
}

fn thumbOf(commands: []const Ui.RenderCommand, track: zui.Rect) ?zui.Rect {
    for (commands) |command| {
        if (command.payload != .rectangle) continue;
        const bounds = command.bounds;
        const inside = bounds.x >= track.x and bounds.x + bounds.width <= track.x + track.width and bounds.y >= track.y and bounds.y + bounds.height <= track.y + track.height;
        if (inside and bounds.width == widgets.theme.slider_thumb_size[0] and bounds.height == widgets.theme.slider_thumb_size[1]) return bounds;
    }
    return null;
}

test "an integer slider rounds and steps with the keyboard" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.focus(&form, Form.declare, Form.ids.level);
    _ = try driver.pressKeys(&form, Form.declare, &.{.right});
    try testing.expectEqual(@as(u8, 4), form.level);
    _ = try driver.pressKeys(&form, Form.declare, &.{.end});
    try testing.expectEqual(@as(u8, 10), form.level);
    _ = try driver.pressKeys(&form, Form.declare, &.{.right});
    try testing.expectEqual(@as(u8, 10), form.level);
    _ = try driver.pressKeys(&form, Form.declare, &.{.home});
    _ = try driver.pressKeys(&form, Form.declare, &.{.left});
    try testing.expectEqual(@as(u8, 0), form.level);

    _ = try driver.clickAt(&form, Form.declare, Form.ids.level, .{ 0.5, 0.5 });
    try testing.expectEqual(@as(u8, 5), form.level);
}

test "a text field edits at the caret" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "ad");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.focus(&form, Form.declare, Form.ids.name);
    _ = try driver.typeText(&form, Form.declare, "a");
    try testing.expectEqualStrings("ada", form.name.slice());

    _ = try driver.pressKeys(&form, Form.declare, &.{ .home, .delete });
    try testing.expectEqualStrings("da", form.name.slice());
    _ = try driver.typeText(&form, Form.declare, "A");
    try testing.expectEqualStrings("Ada", form.name.slice());
    _ = try driver.pressKeys(&form, Form.declare, &.{.end});
    _ = try driver.typeText(&form, Form.declare, " \x08Lovelace\n");
    try testing.expectEqualStrings("Ada Lovelace", form.name.slice());
    _ = try driver.pressKeys(&form, Form.declare, &.{ .backspace, .enter });
    try testing.expectEqualStrings("Ada Lovelac", form.name.slice());
    try testing.expectEqual(@as(u32, 1), form.submitted);
}

test "a text field moves and deletes whole characters" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "né");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.focus(&form, Form.declare, Form.ids.name);
    _ = try driver.pressKeys(&form, Form.declare, &.{.backspace});
    try testing.expectEqualStrings("n", form.name.slice());

    form.name.set("éa");
    _ = try driver.pressKeys(&form, Form.declare, &.{ .home, .right });
    _ = try driver.typeText(&form, Form.declare, "-");
    try testing.expectEqualStrings("é-a", form.name.slice());
}

test "a text field stops at its buffer, at a character boundary" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "0123456789abcde");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.focus(&form, Form.declare, Form.ids.name);
    _ = try driver.typeText(&form, Form.declare, "é");
    try testing.expectEqualStrings("0123456789abcde", form.name.slice());
    _ = try driver.typeText(&form, Form.declare, "fg");
    try testing.expectEqualStrings("0123456789abcdef", form.name.slice());
}

test "clicking a text field places the caret at the nearest boundary" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "abcdef");
    defer fixture.deinit();
    const driver = &fixture.driver;

    // Characters are 8 wide: 3 * 8 + 2 is nearest the boundary after "c",
    // 3 * 8 + 6 nearest the one after "d".
    const field = fixture.ui.rectOf(Form.ids.name).?;
    const text_start = field.x + widgets.theme.gap;
    _ = try driver.clickAt(&form, Form.declare, Form.ids.name, .{ (text_start + 3 * 8 + 2 - field.x) / field.width, 0.5 });
    _ = try driver.typeText(&form, Form.declare, "|");
    try testing.expectEqualStrings("abc|def", form.name.slice());

    form.name.set("abcdef");
    _ = try driver.clickAt(&form, Form.declare, Form.ids.name, .{ (text_start + 3 * 8 + 6 - field.x) / field.width, 0.5 });
    _ = try driver.typeText(&form, Form.declare, "|");
    try testing.expectEqualStrings("abcd|ef", form.name.slice());
}

test "a long text field scrolls to keep the caret visible" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try fixture.init();
    defer fixture.deinit();
    form.init("");
    const driver = &fixture.driver;
    const Narrow = struct {
        fn declare(narrow_form: *Form, ui: *Ui) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100) } } });
            _ = widgets.textField(ui, Form.ids.name, &narrow_form.name, .{});
            ui.close();
        }
    };
    _ = try driver.frame(&form, Narrow.declare, &.{});
    _ = try driver.focus(&form, Narrow.declare, Form.ids.name);
    _ = try driver.typeText(&form, Narrow.declare, "0123456789abcde");
    var frame = try driver.frame(&form, Narrow.declare, &.{});
    const field = frame.rectOf(Form.ids.name).?;
    try testing.expectEqual(@as(f32, 100), field.width);
    var caret = frame.rectOf(Form.ids.name.child("caret")).?;
    try testing.expect(caret.x + caret.width <= field.x + field.width);
    try testing.expect(caret.x >= field.x);

    const caret_at_end = caret.x;
    _ = try driver.clickAt(&form, Narrow.declare, Form.ids.name, .{ (caret_at_end - 4 * 8 - field.x) / field.width, 0.5 });
    _ = try driver.typeText(&form, Narrow.declare, "|");
    try testing.expectEqualStrings("0123456789a|bcde", form.name.slice());

    _ = try driver.pressKeys(&form, Narrow.declare, &.{.home});
    frame = try driver.frame(&form, Narrow.declare, &.{});
    caret = frame.rectOf(Form.ids.name.child("caret")).?;
    try testing.expectEqual(field.x + widgets.theme.gap, caret.x);
}

test "a dropdown opens, chooses, and closes" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&form, Form.declare, Form.ids.quality);
    var frame = try driver.frame(&form, Form.declare, &.{});
    const button = frame.rectOf(Form.ids.quality).?;
    const third_option = frame.rectOf(Form.ids.quality.indexedChild("option", 2)) orelse return error.PopupNotOpen;
    try testing.expect(third_option.y > button.y + button.height);
    try zui_testing.checkCommands(frame.commands());

    _ = try driver.click(&form, Form.declare, Form.ids.quality.indexedChild("option", 2));
    try testing.expectEqual(.high_quality, form.quality);
    try testing.expectEqual(@as(u32, 1), form.quality_changes);
    frame = try driver.frame(&form, Form.declare, &.{});
    try testing.expect(frame.rectOf(Form.ids.quality.indexedChild("option", 0)) == null);
    try testing.expect(fixture.ui.focused(Form.ids.quality));

    _ = try driver.pressKeys(&form, Form.declare, &.{.up});
    try testing.expectEqual(.medium, form.quality);
    try testing.expectEqual(@as(u32, 2), form.quality_changes);
}

test "a dropdown closes on Escape and on a click outside, without changing" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&form, Form.declare, Form.ids.quality);
    _ = try driver.pressKeys(&form, Form.declare, &.{.escape});
    var frame = try driver.frame(&form, Form.declare, &.{});
    try testing.expect(frame.rectOf(Form.ids.quality.indexedChild("option", 0)) == null);

    _ = try driver.click(&form, Form.declare, Form.ids.quality);
    _ = try driver.frame(&form, Form.declare, &.{});
    _ = try driver.clickAt(&form, Form.declare, Form.ids.save, .{ 4, 0.5 });
    frame = try driver.frame(&form, Form.declare, &.{});
    try testing.expect(frame.rectOf(Form.ids.quality.indexedChild("option", 0)) == null);
    try testing.expectEqual(.medium, form.quality);
    try testing.expectEqual(@as(u32, 0), form.quality_changes);
}

test "an open dropdown keeps Tab inside its list" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&form, Form.declare, Form.ids.quality);
    _ = try driver.frame(&form, Form.declare, &.{});
    try testing.expect(fixture.ui.focused(Form.ids.quality.indexedChild("option", 1)));
    for (0..3) |_| _ = try driver.pressKeys(&form, Form.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Form.ids.quality.indexedChild("option", 1)));
    _ = try driver.pressKeys(&form, Form.declare, &.{.enter});
    try testing.expectEqual(.medium, form.quality);
}

test "widgets render valid commands" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "Ada");
    defer fixture.deinit();
    form.autosave = true;
    const frame = try fixture.driver.frame(&form, Form.declare, &.{});
    try zui_testing.checkCommands(frame.commands());
    try testing.expect(frame.diagnostics.ok());
}

const ThemedButton = struct {
    const save: zui.Id = .of("save");
    const light_idle: zui.Color = .rgb(0xdddddd);
    const dark_idle: zui.Color = .rgb(0x222222);
    const themed: Widgets = .{
        .theme = .{ .control = .initFill(light_idle) },
        .dark_theme = .{ .control = .initFill(dark_idle) },
    };

    fn declare(_: *ThemedButton, ui: *Ui) void {
        _ = themed.button(ui, save, "Save", .{});
    }

    fn background(frame: *const Ui.Frame) !zui.Color {
        for (frame.commands()) |command| {
            if (command.id == save.hash and command.payload == .rectangle) return command.payload.rectangle.color;
        }
        return error.NoBackground;
    }
};

test "widgets follow the environment's theme from the frame that changes it" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: ThemedButton = .{};
    const driver = &fixture.driver;

    try testing.expectEqual(ThemedButton.light_idle, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{})));
    const to_dark: zui.Event = .{ .environment = .{ .theme = .dark } };
    try testing.expectEqual(ThemedButton.dark_idle, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{to_dark})));
    try testing.expectEqual(ThemedButton.dark_idle, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{})));
    const to_light: zui.Event = .{ .environment = .{ .theme = .light } };
    try testing.expectEqual(ThemedButton.light_idle, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{to_light})));
}

test "controls ask for a cursor while hovered" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "");
    defer fixture.deinit();
    const driver = &fixture.driver;

    try testing.expectEqual(zui.Cursor.pointer, (try driver.hover(&form, Form.declare, Form.ids.save)).requests().cursor);
    try testing.expectEqual(zui.Cursor.text, (try driver.hover(&form, Form.declare, Form.ids.name)).requests().cursor);
    try testing.expectEqual(zui.Cursor.default, (try driver.hover(&form, Form.declare, Form.ids.locked)).requests().cursor);
}

test "a focused text field asks for text input at its caret" {
    var fixture: Fixture = .{};
    var form: Form = undefined;
    try start(&fixture, &form, "Ada");
    defer fixture.deinit();
    const driver = &fixture.driver;

    try testing.expectEqual(@as(?zui.TextInputArea, null), (try driver.frame(&form, Form.declare, &.{})).requests().text_input);
    const frame = try driver.focus(&form, Form.declare, Form.ids.name);
    const area = frame.requests().text_input orelse return error.NoTextInputRequested;
    try testing.expectEqual(frame.rectOf(Form.ids.name.child("caret")).?, area.caret);
    try testing.expect(area.caret.x > frame.rectOf(Form.ids.name).?.x);
}

test "labels from identifiers" {
    try testing.expectEqualStrings("Max fps", zui_widgets.labelFromIdentifier("max_fps"));
    try testing.expectEqualStrings("X", zui_widgets.labelFromIdentifier("x"));
    try testing.expectEqualStrings("", zui_widgets.labelFromIdentifier(""));
}

test "EditableText inserts and removes in place" {
    var bytes: [8]u8 = undefined;
    var text: zui_widgets.EditableText = .init(&bytes, "held");
    try testing.expectEqual(@as(usize, 4), text.insert(2, "llo world"));
    try testing.expectEqualStrings("hello ld", text.slice());
    text.remove(0, 6);
    try testing.expectEqualStrings("ld", text.slice());
}
