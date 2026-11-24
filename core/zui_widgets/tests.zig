const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets.zig");
const zui_design = @import("zui_design");
const EveryContainer = @import("containers_tests.zig").EveryContainer;
const EveryInput = @import("inputs_tests.zig").EveryInput;

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{
        .max_elements = 512,
        .max_text_bytes = 8192,
        .max_depth = 16,
        .max_render_commands = 1024,
        .state_slots = 512,
        .measure_cache_entries = 1024,
    },
    .Text = Text,
});
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const Driver = zui_testing.Driver(Ui);

fn TokensIn(comptime ContextType: type, comptime preferences: zui_design.Preferences) zui.design.Tokens(ContextType, void) {
    @setEvalBranchQuota(10_000_000);
    var tokens: zui.design.Tokens(ContextType, void) = .{};
    _ = zui_design.resolve(zui_design.default, preferences, &tokens);
    return tokens;
}

const dark_tokens = TokensIn(Ui, .{ .theme = .dark });
const light_tokens = TokensIn(Ui, .{ .theme = .light });

const widgets: Widgets = .{ .skin = .{ .tokens = &dark_tokens } };

fn skinStyle(part: zui_widgets.Part) zui_widgets.Style(Ui) {
    return widgets.skin.zuiStyle(part, .idle, &.{});
}

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
    const thumb_width = skinStyle(.slider_thumb).size[0];
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
    const travel = track.width - skinStyle(.slider_thumb).size[0];
    try testing.expectApproxEqAbs(track.x + travel * 0.25, thumb.x, 0.5);
}

fn thumbOf(commands: []const Ui.RenderCommand, track: zui.Rect) ?zui.Rect {
    for (commands) |command| {
        if (command.payload != .rectangle) continue;
        const bounds = command.bounds;
        const inside = bounds.x >= track.x and bounds.x + bounds.width <= track.x + track.width and bounds.y >= track.y and bounds.y + bounds.height <= track.y + track.height;
        const thumb_size = skinStyle(.slider_thumb).size;
        if (inside and bounds.width == thumb_size[0] and bounds.height == thumb_size[1]) return bounds;
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
    const text_start = field.x + skinStyle(.text_field).padding.left;
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
    try testing.expectEqual(field.x + skinStyle(.text_field).padding.left, caret.x);
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

    themed: Widgets = .{ .skin = .{ .tokens = &light_tokens } },

    fn declare(app: *ThemedButton, ui: *Ui) void {
        _ = app.themed.button(ui, save, "Save", .{});
    }

    fn background(frame: *const Ui.Frame) !zui.Color {
        for (frame.commands()) |command| {
            if (command.id == save.hash and command.payload == .rectangle) return command.payload.rectangle.color;
        }
        return error.NoBackground;
    }
};

test "widgets follow the tokens they point at from the frame those change" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: ThemedButton = .{};
    const driver = &fixture.driver;

    const light_accent = light_tokens.colors.get(.idle).get(.accent);
    const dark_accent = dark_tokens.colors.get(.idle).get(.accent);
    try testing.expectEqual(light_accent, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{})));
    app.themed.skin.tokens = &dark_tokens;
    try testing.expectEqual(dark_accent, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{})));
    app.themed.skin.tokens = &light_tokens;
    try testing.expectEqual(light_accent, try ThemedButton.background(try driver.frame(&app, ThemedButton.declare, &.{})));
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

const AccessibleUi = zui.Context(.{
    .limits = .{ .max_elements = 256, .max_text_bytes = 4096, .max_depth = 16, .max_render_commands = 512, .state_slots = 256, .measure_cache_entries = 1024 },
    .Text = Text,
    .features = .{ .semantics = true },
});
const accessible_tokens = TokensIn(AccessibleUi, .{});
const accessible_widgets: zui_widgets.Widgets(AccessibleUi, zui_widgets.DesignSkin(AccessibleUi)) = .{ .skin = .{ .tokens = &accessible_tokens } };

const AccessibleForm = struct {
    const ids = zui.ids(.{ "save", "autosave", "advanced", "volume", "name", "quality" });

    clicks: u32 = 0,
    autosave: bool = true,
    advanced: bool = false,
    volume: u8 = 4,
    name_bytes: [16]u8 = undefined,
    name: zui_widgets.EditableText = undefined,
    quality: enum { low, medium, high_quality } = .medium,

    fn declare(form: *AccessibleForm, ui: *AccessibleUi) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) }, .child_gap = 10 } });
        if (accessible_widgets.button(ui, ids.save, "Save", .{})) form.clicks += 1;
        _ = accessible_widgets.checkbox(ui, ids.autosave, "Autosave", &form.autosave, .{});
        _ = accessible_widgets.disclosure(ui, ids.advanced, "Advanced", &form.advanced);
        _ = accessible_widgets.slider(ui, ids.volume, &form.volume, .{ .max = 10, .label = "Volume" });
        _ = accessible_widgets.textField(ui, ids.name, &form.name, .{ .placeholder = "Name" });
        _ = accessible_widgets.dropdownEnum(ui, ids.quality, &form.quality, .{ .label = "Quality" });
        ui.close();
    }

    fn node(frame: *const AccessibleUi.Frame, id: zui.Id) !zui.SemanticNode {
        for (frame.semantics()) |listed| {
            if (listed.id == id.hash) return listed;
        }
        return error.NotListed;
    }
};

test "each control lists what it is, and answers the actions it lists" {
    var text: Text = .{};
    var ui: AccessibleUi = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    var driver: zui_testing.Driver(AccessibleUi) = .{ .ui = &ui };
    var form: AccessibleForm = .{};
    form.name = .init(&form.name_bytes, "Ada");
    const ids = AccessibleForm.ids;
    const node = AccessibleForm.node;

    var frame = try driver.frame(&form, AccessibleForm.declare, &.{});
    try testing.expectEqual(@as(usize, 6), frame.semantics().len);

    const save = try node(frame, ids.save);
    try testing.expectEqual(zui.SemanticRole.button, save.role);
    try testing.expectEqualStrings("Save", save.label);
    try testing.expect(save.actions.contains(.invoke));

    const autosave = try node(frame, ids.autosave);
    try testing.expectEqual(zui.SemanticRole.checkbox, autosave.role);
    try testing.expectEqualStrings("Autosave", autosave.label);
    try testing.expectEqual(@as(?bool, true), autosave.state.checked);

    const advanced = try node(frame, ids.advanced);
    try testing.expectEqual(zui.SemanticRole.button, advanced.role);
    try testing.expectEqual(@as(?bool, false), advanced.state.expanded);

    const volume = try node(frame, ids.volume);
    try testing.expectEqual(zui.SemanticRole.slider, volume.role);
    try testing.expectEqualStrings("Volume", volume.label);
    try testing.expectEqual(zui.SemanticRange{ .value = 4, .min = 0, .max = 10, .step = 1 }, volume.value.range);
    try testing.expect(volume.actions.contains(.adjust));

    const name = try node(frame, ids.name);
    try testing.expectEqual(zui.SemanticRole.text_field, name.role);
    try testing.expectEqualStrings("Name", name.label);
    try testing.expectEqualStrings("Ada", name.value.text);

    const quality = try node(frame, ids.quality);
    try testing.expectEqual(zui.SemanticRole.combo_box, quality.role);
    try testing.expectEqualStrings("Quality", quality.label);
    try testing.expectEqualStrings("Medium", quality.value.text);
    try testing.expectEqual(@as(?bool, false), quality.state.expanded);

    _ = try driver.action(&form, AccessibleForm.declare, ids.save, .invoke);
    try testing.expectEqual(@as(u32, 1), form.clicks);
    frame = try driver.action(&form, AccessibleForm.declare, ids.autosave, .invoke);
    try testing.expect(!form.autosave);
    try testing.expectEqual(@as(?bool, false), (try node(frame, ids.autosave)).state.checked);
    frame = try driver.action(&form, AccessibleForm.declare, ids.advanced, .invoke);
    try testing.expectEqual(@as(?bool, true), (try node(frame, ids.advanced)).state.expanded);
    frame = try driver.action(&form, AccessibleForm.declare, ids.volume, .{ .adjust = 3 });
    try testing.expectEqual(@as(u8, 7), form.volume);
    try testing.expectEqual(@as(f64, 7), (try node(frame, ids.volume)).value.range.value);
    frame = try driver.action(&form, AccessibleForm.declare, ids.name, .focus);
    try testing.expect((try node(frame, ids.name)).state.focused);

    frame = try driver.action(&form, AccessibleForm.declare, ids.quality, .invoke);
    try testing.expectEqual(@as(?bool, true), (try node(frame, ids.quality)).state.expanded);
    const popup = try node(frame, ids.quality.child("popup"));
    try testing.expectEqual(zui.SemanticRole.list_box, popup.role);
    try testing.expect(popup.actions.contains(.dismiss));
    const third = try node(frame, ids.quality.indexedChild("option", 2));
    try testing.expectEqual(zui.SemanticRole.option, third.role);
    try testing.expectEqualStrings("High quality", third.label);
    try testing.expect((try node(frame, ids.quality.indexedChild("option", 1))).state.selected);
    try testing.expect(!third.state.selected);

    frame = try driver.action(&form, AccessibleForm.declare, ids.quality.child("popup"), .dismiss);
    try testing.expectError(error.NotListed, node(frame, ids.quality.child("popup")));
    try testing.expectEqual(.medium, form.quality);

    _ = try driver.action(&form, AccessibleForm.declare, ids.quality, .invoke);
    frame = try driver.action(&form, AccessibleForm.declare, ids.quality.indexedChild("option", 2), .invoke);
    try testing.expectEqual(.high_quality, form.quality);
    try testing.expectEqualStrings("High quality", (try node(frame, ids.quality)).value.text);
    try testing.expect(frame.diagnostics.ok());
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

const ScrollingSettings = struct {
    const ids = zui.ids(.{ "settings", "brightness" });

    brightness: f32 = 0.5,

    fn declare(settings: *ScrollingSettings, ui: *Ui) void {
        ui.open(.{ .id = ids.settings, .scroll = .{}, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300), .height = .fixed(200) } } });
        _ = widgets.slider(ui, ids.brightness, &settings.brightness, .{});
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(300), .height = .fixed(1000) } } });
        ui.close();
    }
};

test "a slider in a list that scrolls by dragging keeps a horizontal drag, and the list a vertical one" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var settings: ScrollingSettings = .{};
    _ = try driver.frame(&settings, ScrollingSettings.declare, &.{});

    _ = try driver.dragFingers(&settings, ScrollingSettings.declare, ScrollingSettings.ids.brightness, &.{.{ .from = .{ 0.5, 0.5 }, .to = .{ 1.5, 0.6 } }});
    try testing.expectEqual(@as(f32, 1), settings.brightness);
    try testing.expectEqual([2]f32{ 0, 0 }, fixture.ui.scrollOffset(ScrollingSettings.ids.settings));

    _ = try driver.dragFingers(&settings, ScrollingSettings.declare, ScrollingSettings.ids.brightness, &.{.{ .from = .{ 0.5, 0.5 }, .to = .{ 0.4, -2 } }});
    try testing.expectApproxEqAbs(@as(f32, 0.5), settings.brightness, 1e-4); // set where the finger landed, then left alone
    try testing.expect(fixture.ui.scrollOffset(ScrollingSettings.ids.settings)[1] > 0);
}

const LassoMap = struct {
    const id: zui.Id = .of("map");

    selection: zui_widgets.Lasso = .{},
    lassos: u32 = 0,
    panned: [2]f32 = .{ 0, 0 },

    fn declare(map: *LassoMap, ui: *Ui) void {
        if (ui.manipulation(id)) |moved| {
            map.panned[0] += moved.translation[0];
            map.panned[1] += moved.translation[1];
        }
        ui.box(.{ .id = id, .gestures = .{ .pan = .both, .zoom = true, .custom = true }, .layout = .{ .sizing = .{ .width = .fixed(400), .height = .fixed(300) } } });
        if (widgets.lasso(ui, id, &map.selection)) map.lassos += 1;
    }
};

fn pointerAt(driver: *const Driver, kind: zui.PointerKind, position: [2]f32) zui.Pointer {
    return .{ .id = @enumFromInt(7), .kind = kind, .position = position, .at = driver.now };
}

test "a lasso written as a module function draws with a pen and leaves fingers to pan the map" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var map: LassoMap = .{};
    _ = try driver.frame(&map, LassoMap.declare, &.{});

    _ = try driver.frame(&map, LassoMap.declare, &.{
        .{ .pointer_down = .{ .pointer = pointerAt(driver, .pen, .{ 100, 100 }) } },
        .{ .pointer_move = .{ .pointer = pointerAt(driver, .pen, .{ 150, 100 }) } },
    });
    _ = try driver.frame(&map, LassoMap.declare, &.{.{ .pointer_move = .{ .pointer = pointerAt(driver, .pen, .{ 150, 150 }) } }});
    _ = try driver.frame(&map, LassoMap.declare, &.{.{ .pointer_up = .{ .pointer = pointerAt(driver, .pen, .{ 100, 150 }) } }});
    try testing.expectEqual(@as(u32, 1), map.lassos);
    try testing.expectEqualSlices([2]f32, &.{ .{ 100, 100 }, .{ 150, 100 }, .{ 150, 150 }, .{ 100, 150 } }, map.selection.points());
    try testing.expectEqual([2]f32{ 0, 0 }, map.panned);
    try testing.expect(!fixture.ui.clicked(LassoMap.id));

    // The finger's first frame waits for the lasso to decline it; then
    // the map pans by all of it, from where it pressed.
    _ = try driver.frame(&map, LassoMap.declare, &.{
        .{ .pointer_down = .{ .pointer = pointerAt(driver, .touch, .{ 200, 200 }) } },
        .{ .pointer_move = .{ .pointer = pointerAt(driver, .touch, .{ 240, 190 }) } },
    });
    try testing.expectEqual([2]f32{ 0, 0 }, map.panned);
    _ = try driver.frame(&map, LassoMap.declare, &.{});
    try testing.expectEqual([2]f32{ 40, -10 }, map.panned);
    _ = try driver.frame(&map, LassoMap.declare, &.{.{ .pointer_move = .{ .pointer = pointerAt(driver, .touch, .{ 250, 190 }) } }});
    _ = try driver.frame(&map, LassoMap.declare, &.{.{ .pointer_up = .{ .pointer = pointerAt(driver, .touch, .{ 250, 190 }) } }});
    try testing.expectEqual([2]f32{ 50, -10 }, map.panned);
    try testing.expectEqual(@as(u32, 1), map.lassos);
}

/// Declares every part a skin styles: both disclosure indicators, a
/// checked and an unchecked box, an empty field's placeholder and a
/// focused one's caret, and an open dropdown's selected and other options.
fn EveryWidget(comptime SkinnedWidgets: type) type {
    return struct {
        const Self = @This();
        const ids = struct {
            const expanded: zui.Id = .of("expanded");
            const collapsed: zui.Id = .of("collapsed");
            const button: zui.Id = .of("button");
            const variants = [_]zui.Id{ .of("secondary"), .of("tonal"), .of("tertiary"), .of("danger") };
            const disabled_button: zui.Id = .of("disabled_button");
            const small_button: zui.Id = .of("small_button");
            const large_button: zui.Id = .of("large_button");
            const checked: zui.Id = .of("checked");
            const unchecked: zui.Id = .of("unchecked");
            const slider: zui.Id = .of("slider");
            const field: zui.Id = .of("field");
            const empty_field: zui.Id = .of("empty_field");
            const dropdown: zui.Id = .of("dropdown");
        };

        widgets: SkinnedWidgets,
        expanded: bool = true,
        collapsed: bool = false,
        checked: bool = true,
        unchecked: bool = false,
        level: f32 = 0.5,
        field_bytes: [16]u8 = undefined,
        field: zui_widgets.EditableText = undefined,
        empty_field_bytes: [16]u8 = undefined,
        empty_field: zui_widgets.EditableText = undefined,
        choice: usize = 1,

        fn init(form: *Self, skinned: SkinnedWidgets) void {
            form.* = .{ .widgets = skinned };
            form.field = .init(&form.field_bytes, "Ada");
            form.empty_field = .init(&form.empty_field_bytes, "");
        }

        fn declare(form: *Self, ui: *Ui) void {
            const widgets_in_use = form.widgets;
            ui.open(.{ .layout = .{ .padding = .all(10), .child_gap = 10 } });
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300) }, .child_gap = 10 } });
            widgets_in_use.label(ui, "label");
            widgets_in_use.mutedLabel(ui, "muted");
            widgets_in_use.labelWith(ui, "accent", .{ .tone = .accent });
            inline for (comptime std.enums.values(zui.design.TypeRole)) |role| widgets_in_use.labelWith(ui, @tagName(role), .{ .role = role });
            widgets_in_use.labeledRow(ui, "row");
            _ = widgets_in_use.disclosure(ui, ids.expanded, "expanded", &form.expanded);
            ui.close();
            widgets_in_use.labeledRowWith(ui, "described", .{ .description = "description", .divider_above = true });
            ui.close();
            _ = widgets_in_use.disclosure(ui, ids.collapsed, "collapsed", &form.collapsed);
            ui.close();
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200) }, .child_gap = 10 } });
            _ = widgets_in_use.button(ui, ids.button, "button", .{});
            inline for (comptime std.enums.values(zui_widgets.ButtonVariant)[1..], ids.variants) |variant, id| {
                _ = widgets_in_use.button(ui, id, @tagName(variant), .{ .variant = variant });
            }
            _ = widgets_in_use.button(ui, ids.disabled_button, "disabled", .{ .disabled = true });
            _ = widgets_in_use.button(ui, ids.small_button, "small", .{ .size = .small, .leading_icon = .check });
            _ = widgets_in_use.button(ui, ids.large_button, "large", .{ .size = .large });
            _ = widgets_in_use.checkbox(ui, ids.checked, "checked", &form.checked, .{});
            _ = widgets_in_use.checkbox(ui, ids.unchecked, "unchecked", &form.unchecked, .{});
            ui.close();
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(260) }, .child_gap = 10 } });
            _ = widgets_in_use.slider(ui, ids.slider, &form.level, .{ .step = 0.25, .ticks = true });
            _ = widgets_in_use.textField(ui, ids.field, &form.field, .{ .label = "field", .show_label = true, .help = "help", .leading_icon = .search, .trailing = "kg" });
            _ = widgets_in_use.textField(ui, ids.empty_field, &form.empty_field, .{ .placeholder = "empty", .error_message = "error" });
            _ = widgets_in_use.dropdown(ui, ids.dropdown, &form.choice, &.{ "one", "two", "three" }, .{});
            ui.close();
            ui.close();
        }
    };
}

/// Plain data: one style for every part, whatever the state or the
/// environment.
const UniformSkin = struct {
    look: zui_widgets.Style(Ui),

    pub fn zuiStyle(skin: *const UniformSkin, _: zui_widgets.Part, _: zui.WidgetState, _: *const zui.Environment) zui_widgets.Style(Ui) {
        return skin.look;
    }
};

test "a skin of data alone restyles every widget" {
    const fill: zui.Color = .rgb(0x102030);
    const outline: zui.Color = .rgb(0x405060);
    const ring: zui.Color = .rgb(0x708090);
    const ink: zui.Color = .rgb(0xa0b0c0);
    const uniform: UniformSkin = .{ .look = .{
        .background = fill,
        .border = .{ .color = outline, .widths = .all(1) },
        .focus_ring = .{ .color = ring, .widths = .all(3) },
        .text = .{ .color = ink, .size = 10 },
        .size = .{ 14, 22 },
        .glyph = "*",
    } };
    const SkinnedForm = EveryWidget(zui_widgets.Widgets(Ui, UniformSkin));

    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var form: SkinnedForm = undefined;
    form.init(.{ .skin = uniform });
    _ = try fixture.driver.frame(&form, SkinnedForm.declare, &.{});
    _ = try fixture.driver.click(&form, SkinnedForm.declare, SkinnedForm.ids.dropdown);
    const frame = try fixture.driver.focus(&form, SkinnedForm.declare, SkinnedForm.ids.field);

    var rectangles: usize = 0;
    var rings: usize = 0;
    var texts: usize = 0;
    for (frame.commands()) |command| switch (command.payload) {
        .rectangle => |rectangle| {
            try testing.expectEqual(fill, rectangle.color);
            rectangles += 1;
        },
        .border => |border| {
            if (std.meta.eql(border.color, ring)) rings += 1 else try testing.expectEqual(outline, border.color);
        },
        .text => |text| {
            try testing.expectEqual(ink, text.style.color);
            try testing.expectEqual(@as(f32, 10), text.style.size);
            texts += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), rings);
    try testing.expect(frame.rectOf(SkinnedForm.ids.dropdown.child("popup")) != null);
    try testing.expectEqual(@as(usize, 29), rectangles);
    try testing.expectEqual(@as(usize, 44), texts);
    for ([_]zui.Id{ SkinnedForm.ids.expanded, SkinnedForm.ids.button, SkinnedForm.ids.checked, SkinnedForm.ids.slider, SkinnedForm.ids.field, SkinnedForm.ids.dropdown }) |id| {
        try testing.expectEqual(@as(f32, 22), frame.rectOf(id).?.height);
    }
    try testing.expect(frame.diagnostics.ok());
}

const AskedOfSkin = struct {
    parts: std.EnumArray(zui_widgets.Part, bool) = .initFill(false),
    states: std.EnumArray(zui.WidgetState, bool) = .initFill(false),
};

const RecordingSkin = struct {
    asked: *AskedOfSkin,

    pub fn zuiStyle(skin: *const RecordingSkin, part: zui_widgets.Part, state: zui.WidgetState, _: *const zui.Environment) zui_widgets.Style(Ui) {
        skin.asked.parts.set(part, true);
        skin.asked.states.set(state, true);
        return .{ .size = .{ 12, 24 } };
    }
};

test "every part and every state reach the skin" {
    var asked: AskedOfSkin = .{};
    const Recorded = zui_widgets.Widgets(Ui, RecordingSkin);
    const SkinnedForm = EveryWidget(Recorded);
    const SkinnedContainers = EveryContainer(Recorded);
    const SkinnedInputs = EveryInput(Recorded);
    const Both = struct {
        form: SkinnedForm,
        containers: SkinnedContainers,
        inputs: SkinnedInputs,

        fn declare(both: *@This(), ui: *Ui) void {
            ui.open(.{ .layout = .{ .sizing = .grow_both } });
            SkinnedForm.declare(&both.form, ui);
            SkinnedContainers.declare(&both.containers, ui);
            SkinnedInputs.declare(&both.inputs, ui);
            ui.close();
        }
    };

    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var both: Both = .{ .form = undefined, .containers = .{ .widgets = .{ .skin = .{ .asked = &asked } } }, .inputs = undefined };
    both.form.init(.{ .skin = .{ .asked = &asked } });
    both.inputs.init(.{ .skin = .{ .asked = &asked } });
    _ = try driver.frame(&both, Both.declare, &.{});
    _ = try driver.hover(&both, Both.declare, SkinnedForm.ids.button);
    _ = try driver.drag(&both, Both.declare, SkinnedForm.ids.slider, .{ 0.5, 0.5 }, .{ 0.6, 0.5 });
    _ = try driver.focus(&both, Both.declare, SkinnedForm.ids.field);
    _ = try driver.click(&both, Both.declare, SkinnedForm.ids.dropdown);
    _ = try driver.frame(&both, Both.declare, &.{});

    // A context that draws no gradients asks for no edge fades; the
    // containers' own tests draw them.
    const drawn_only_with_gradients = [_]zui_widgets.Part{ .scroll_edge_fade, .scroll_edge_fade_raised };
    for (std.enums.values(zui_widgets.Part)) |part| {
        if (std.mem.indexOfScalar(zui_widgets.Part, &drawn_only_with_gradients, part) != null) continue;
        if (!asked.parts.get(part)) {
            std.debug.print("never asked for {t}\n", .{part});
            return error.PartNeverStyled;
        }
    }
    for (std.enums.values(zui.WidgetState)) |state| {
        if (!asked.states.get(state)) {
            std.debug.print("never asked in {t}\n", .{state});
            return error.StateNeverStyled;
        }
    }
}

test "widgets add nothing to a skin known at compile time" {
    const EmptySkin = struct {
        pub fn zuiStyle(_: *const @This(), _: zui_widgets.Part, _: zui.WidgetState, _: *const zui.Environment) zui_widgets.Style(Ui) {
            return .{};
        }
    };
    try testing.expectEqual(0, @sizeOf(zui_widgets.Widgets(Ui, EmptySkin)));
    try testing.expectEqual(@sizeOf(zui_widgets.DesignSkin(Ui)), @sizeOf(Widgets));
    try testing.expectEqual(@sizeOf(UniformSkin), @sizeOf(zui_widgets.Widgets(Ui, UniformSkin)));
}

test "every widget in the design skin meets its contrast and target floor in every scheme and density" {
    const SkinnedForm = EveryWidget(Widgets);
    const OnPage = struct {
        fn declare(form: *SkinnedForm, ui: *Ui) void {
            const page = form.widgets.skin.tokens.colors.get(.idle).get(.surface);
            ui.open(.{ .layout = .{ .sizing = .grow_both }, .decoration = .{ .background = page } });
            SkinnedForm.declare(form, ui);
            ui.close();
        }
    };
    inline for (comptime std.enums.values(zui_design.Scheme)) |scheme| {
        inline for (comptime std.enums.values(zui.design.Density)) |density| {
            const theme: zui.Environment.Theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark;
            const tokens = comptime TokensIn(Ui, .{ .theme = theme, .contrast = scheme.environmentContrast(), .density = density });
            var fixture: Fixture = .{};
            try fixture.init();
            defer fixture.deinit();
            var form: SkinnedForm = undefined;
            form.init(.{ .skin = .{ .tokens = &tokens } });
            fixture.driver.viewport = .{ 800, 1000 };
            _ = try fixture.driver.frame(&form, OnPage.declare, &.{});
            _ = try fixture.driver.click(&form, OnPage.declare, SkinnedForm.ids.dropdown);
            const frame = try fixture.driver.focus(&form, OnPage.declare, SkinnedForm.ids.dropdown.indexedChild("option", 0));
            const options: zui_design.AuditOptions = .fromTokens(&tokens, scheme.environmentContrast());
            var room: [16]zui_design.Finding = undefined;
            const findings = zui_design.audit(frame, options, &room);
            for (findings.slice()) |finding| switch (finding.measured) {
                .text_contrast, .focus_ring_contrast => |contrast| std.debug.print("{s} {t}: {t} Lc {d:.1} {d:.2}:1 fg {any} bg {any}\n", .{ scheme.name(), density, finding.measured, contrast.measured.lightness_contrast, contrast.measured.ratio, contrast.foreground, contrast.background }),
                else => std.debug.print("{s} {t}: {any}\n", .{ scheme.name(), density, finding.measured }),
            };
            try testing.expectEqual(0, findings.slice().len + findings.dropped);
        }
    }
}

test "the design skin's focus ring stands apart from every focused control, filled ones too, in every scheme" {
    const SkinnedForm = EveryWidget(Widgets);
    const OnPage = struct {
        fn declare(form: *SkinnedForm, ui: *Ui) void {
            const page = form.widgets.skin.tokens.colors.get(.idle).get(.surface);
            ui.open(.{ .layout = .{ .sizing = .grow_both }, .decoration = .{ .background = page } });
            SkinnedForm.declare(form, ui);
            ui.close();
        }
    };
    const focused_controls = [_]zui.Id{ SkinnedForm.ids.expanded, SkinnedForm.ids.button } ++ SkinnedForm.ids.variants ++
        [_]zui.Id{ SkinnedForm.ids.checked, SkinnedForm.ids.unchecked, SkinnedForm.ids.slider, SkinnedForm.ids.dropdown };
    inline for (comptime std.enums.values(zui_design.Scheme)) |scheme| {
        const theme: zui.Environment.Theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark;
        const tokens = comptime TokensIn(Ui, .{ .theme = theme, .contrast = scheme.environmentContrast(), .density = .comfortable });
        const ring_color = tokens.colors.get(.focused).get(.focus);
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        var form: SkinnedForm = undefined;
        form.init(.{ .skin = .{ .tokens = &tokens } });
        fixture.driver.viewport = .{ 800, 1000 };
        _ = try fixture.driver.frame(&form, OnPage.declare, &.{});
        for (focused_controls) |control| {
            const frame = try fixture.driver.focus(&form, OnPage.declare, control);
            var rings: usize = 0;
            for (frame.commands()) |command| if (command.payload == .border and command.payload.border.color.eql(ring_color)) {
                rings += 1;
            };
            try testing.expectEqual(1, rings);
            var room: [16]zui_design.Finding = undefined;
            var options: zui_design.AuditOptions = .fromTokens(&tokens, scheme.environmentContrast());
            options.checks = .initOne(.focus_ring_contrast);
            const findings = zui_design.audit(frame, options, &room);
            for (findings.slice()) |finding| std.debug.print("{s}, control {x}: {any}\n", .{ scheme.name(), control.hash, finding.measured });
            try testing.expectEqual(0, findings.slice().len + findings.dropped);
        }
    }
}
