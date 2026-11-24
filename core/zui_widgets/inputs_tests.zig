const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets.zig");
const zui_design = @import("zui_design");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const limits: zui.Limits = .{
    .max_elements = 512,
    .max_text_bytes = 8192,
    .max_depth = 24,
    .max_render_commands = 1024,
    .state_slots = 512,
    .measure_cache_entries = 1024,
};
const Ui = zui.Context(.{ .limits = limits, .Text = Text, .features = .{ .semantics = true }, .commands = .initOne(.shadow) });
const DrawingUi = zui.Context(.{ .limits = limits, .Text = Text, .commands = .initMany(&.{ .gradient, .transform, .shadow }) });

const icon_font = 7;
const lettered_icons: zui.design.IconSet = .{ .codepoints = .initFill('*') };

fn TokensIn(comptime ContextType: type, comptime with_icons: bool, comptime preferences: zui_design.Preferences) zui.design.Tokens(ContextType, void) {
    @setEvalBranchQuota(10_000_000);
    var design = zui_design.default;
    if (with_icons) {
        design.icons = lettered_icons;
        design.type.fonts.icons = icon_font;
    }
    var resolved: zui.design.Tokens(ContextType, void) = .{};
    _ = zui_design.resolve(design, preferences, &resolved);
    return resolved;
}

const tokens = TokensIn(Ui, false, .{ .theme = .dark });
const icon_tokens = TokensIn(Ui, true, .{ .theme = .dark });
const drawing_tokens = TokensIn(DrawingUi, false, .{ .theme = .dark });
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const widgets: Widgets = .{ .skin = .{ .tokens = &tokens } };
const icon_widgets: Widgets = .{ .skin = .{ .tokens = &icon_tokens } };
const DrawingWidgets = zui_widgets.Widgets(DrawingUi, zui_widgets.DesignSkin(DrawingUi));
const drawing_widgets: DrawingWidgets = .{ .skin = .{ .tokens = &drawing_tokens } };

fn Fixture(comptime ContextType: type) type {
    return struct {
        text: Text = .{},
        ui: ContextType = undefined,
        driver: zui_testing.Driver(ContextType) = undefined,

        fn init(fixture: *@This()) !void {
            fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
            fixture.driver = .{ .ui = &fixture.ui };
        }

        fn deinit(fixture: *@This()) void {
            fixture.ui.deinit(testing.allocator);
        }
    };
}

fn nodeOf(frame: anytype, id: zui.Id) !zui.SemanticNode {
    for (frame.semantics()) |listed| {
        if (listed.id == id.hash) return listed;
    }
    return error.NotListed;
}

fn rectangleOf(frame: anytype, id: zui.Id) ?@TypeOf(frame.commands()[0].payload.rectangle) {
    for (frame.commands()) |command| {
        if (command.id == id.hash and command.payload == .rectangle) return command.payload.rectangle;
    }
    return null;
}

fn borderOf(frame: anytype, id: zui.Id) ?@TypeOf(frame.commands()[0].payload.border) {
    for (frame.commands()) |command| {
        if (command.id == id.hash and command.payload == .border) return command.payload.border;
    }
    return null;
}

fn textCommand(frame: anytype, content: []const u8) ?@TypeOf(frame.commands()[0]) {
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, content)) return command;
    }
    return null;
}

fn textCount(frame: anytype, content: []const u8) usize {
    var count: usize = 0;
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, content)) count += 1;
    }
    return count;
}

fn transformOf(frame: anytype) ?zui.Transform {
    for (frame.commands()) |command| {
        if (command.payload == .transform_begin) return command.payload.transform_begin;
    }
    return null;
}

fn color(role: zui.design.ColorRole) zui.Color {
    return tokens.colors.get(.idle).get(role);
}

fn mouse(driver: anytype, position: [2]f32) zui.Pointer {
    return .{ .id = .mouse, .kind = .mouse, .position = position, .at = driver.now };
}

// =============================================================
// Label and labeled row
// =============================================================

const Labels = struct {
    fn declare(_: *Labels, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) } } });
        widgets.labelWith(ui, "Storage", .{ .role = .title });
        widgets.labelWith(ui, "Updated today", .{ .role = .caption, .tone = .muted });
        widgets.labelWith(ui, "3 new", .{ .tone = .accent });
        widgets.label(ui, "Plain");
        ui.close();
    }
};

test "a label takes any type role, in the page's text color, muted or accented" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Labels = .{};
    const frame = try fixture.driver.frame(&app, Labels.declare, &.{});
    const title = textCommand(frame, "Storage").?.payload.text.style;
    try testing.expectEqual(tokens.text_styles.get(.title).size, title.size);
    try testing.expectEqual(color(.on_surface), title.color);
    const caption = textCommand(frame, "Updated today").?.payload.text.style;
    try testing.expectEqual(tokens.text_styles.get(.caption).size, caption.size);
    try testing.expectEqual(color(.on_surface_muted), caption.color);
    try testing.expectEqual(color(.on_surface_accent), textCommand(frame, "3 new").?.payload.text.style.color);
    try testing.expectEqual(tokens.text_styles.get(.body).size, textCommand(frame, "Plain").?.payload.text.style.size);
}

const SettingsRows = struct {
    const first: zui.Id = .of("first");
    const second: zui.Id = .of("second");

    fn declare(_: *SettingsRows, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) } } });
        widgets.labeledRowWith(ui, "Wi-Fi only", .{ .description = "Waits for Wi-Fi" });
        ui.box(.{ .id = first, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(20) } } });
        ui.close();
        widgets.labeledRowWith(ui, "Photos", .{ .divider_above = true });
        ui.box(.{ .id = second, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(20) } } });
        ui.close();
        ui.close();
    }
};

test "a labeled row describes itself under its label, and the rows of a list stand apart by an inset divider" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: SettingsRows = .{};
    const frame = try fixture.driver.frame(&app, SettingsRows.declare, &.{});
    const label = textCommand(frame, "Wi-Fi only").?;
    const description = textCommand(frame, "Waits for Wi-Fi").?;
    try testing.expectEqual(label.bounds.x, description.bounds.x);
    try testing.expectApproxEqAbs(label.bounds.y + label.bounds.height, description.bounds.y, 0.5);
    try testing.expectEqual(color(.on_surface_muted), description.payload.text.style.color);
    try testing.expectEqual(tokens.text_styles.get(.caption).size, description.payload.text.style.size);

    var divider: ?zui.Rect = null;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.payload.rectangle.color.eql(color(.outline_muted))) divider = command.bounds;
    }
    const line = divider orelse return error.NoDivider;
    try testing.expectEqual(tokens.space(.l), line.x);
    try testing.expectEqual(@as(f32, 1), line.height);
    try testing.expect(line.y >= description.bounds.y + description.bounds.height);
    try testing.expect(line.y + line.height <= frame.rectOf(SettingsRows.second).?.y);
}

// =============================================================
// Disclosure
// =============================================================

const Section = struct {
    const id: zui.Id = .of("advanced");
    expanded: bool = false,

    fn declare(app: *Section, ui: *DrawingUi) void {
        _ = drawing_widgets.disclosure(ui, id, "Advanced", &app.expanded);
    }

    fn declareFlat(app: *Section, ui: *Ui) void {
        _ = widgets.disclosure(ui, id, "Advanced", &app.expanded);
    }
};

test "a disclosure's chevron turns a quarter through the disclosure motion, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Section = .{};
    var frame = try driver.frame(&app, Section.declare, &.{});
    try testing.expectEqual(@as(?zui.Transform, null), transformOf(frame));
    try testing.expect(textCommand(frame, ">") != null);

    _ = try driver.click(&app, Section.declare, Section.id);
    try testing.expect(app.expanded);
    frame = try driver.frame(&app, Section.declare, &.{});
    const partway = (transformOf(frame) orelse return error.NotTurned).rotation;
    try testing.expect(partway > 0 and partway < std.math.pi / 2.0);
    for (0..30) |_| frame = try driver.frame(&app, Section.declare, &.{});
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), transformOf(frame).?.rotation, 1e-4);
    try testing.expect(textCommand(frame, ">") != null);

    _ = try driver.frame(&app, Section.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = try driver.click(&app, Section.declare, Section.id);
    frame = try driver.frame(&app, Section.declare, &.{});
    try testing.expectEqual(@as(?zui.Transform, null), transformOf(frame));
}

test "where the context draws no transforms, a disclosure's chevron points down while expanded" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Section = .{};
    var frame = try fixture.driver.frame(&app, Section.declareFlat, &.{});
    try testing.expect(textCommand(frame, ">") != null);
    frame = try fixture.driver.click(&app, Section.declareFlat, Section.id);
    frame = try fixture.driver.frame(&app, Section.declareFlat, &.{});
    try testing.expect(textCommand(frame, "v") != null);
    try testing.expectEqual(true, (try nodeOf(frame, Section.id)).state.expanded);
    _ = try fixture.driver.focus(&app, Section.declareFlat, Section.id);
    _ = try fixture.driver.pressKeys(&app, Section.declareFlat, &.{.space});
    try testing.expect(!app.expanded);
}

// =============================================================
// Button
// =============================================================

const Buttons = struct {
    const ids = zui.ids(.{ "small", "medium", "large", "fixed", "export" });

    fn declareWith(used: Widgets, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 8 } });
        _ = used.button(ui, ids.small, "S", .{ .size = .small });
        _ = used.button(ui, ids.medium, "M", .{});
        _ = used.button(ui, ids.large, "L", .{ .size = .large });
        _ = used.button(ui, ids.fixed, "F", .{ .width = .fixed(30) });
        _ = used.button(ui, ids.@"export", "Export", .{ .leading_icon = .arrow_down });
        ui.close();
    }

    fn declare(_: *Buttons, ui: *Ui) void {
        declareWith(widgets, ui);
    }

    fn declareWithIcons(_: *Buttons, ui: *Ui) void {
        declareWith(icon_widgets, ui);
    }
};

test "a button's size sets its height and its label's type, and a fitted one is at least twice as wide as tall" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Buttons = .{};
    const frame = try fixture.driver.frame(&app, Buttons.declare, &.{});
    inline for (.{ .{ Buttons.ids.small, .small }, .{ Buttons.ids.medium, .medium }, .{ Buttons.ids.large, .large } }) |each| {
        const height = tokens.control_heights.get(each[1]);
        const rect = frame.rectOf(each[0]).?;
        try testing.expectEqual(height, rect.height);
        try testing.expectEqual(2 * height, rect.width);
    }
    try testing.expectEqual(tokens.text_styles.get(.label_strong).size, textCommand(frame, "S").?.payload.text.style.size);
    try testing.expectEqual(tokens.text_styles.get(.body_strong).size, textCommand(frame, "M").?.payload.text.style.size);
    try testing.expectEqual(@as(f32, 30), frame.rectOf(Buttons.ids.fixed).?.width);
}

test "a button draws its leading icon from the design's icon font in its label's color, and without one draws none and counts it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Buttons = .{};
    var frame = try fixture.driver.frame(&app, Buttons.declareWithIcons, &.{});
    const glyph = textCommand(frame, "*") orelse return error.NoIcon;
    try testing.expectEqual(@as(u16, icon_font), glyph.payload.text.style.font);
    try testing.expectEqual(icon_tokens.icon_sizes.get(.medium), glyph.payload.text.style.size);
    try testing.expectEqual(icon_tokens.colors.get(.idle).get(.on_accent), glyph.payload.text.style.color);
    try testing.expect(glyph.bounds.x < textCommand(frame, "Export").?.bounds.x);
    try testing.expectEqual(0, frame.diagnostics.missing_icons);

    frame = try fixture.driver.frame(&app, Buttons.declare, &.{});
    try testing.expectEqual(null, textCommand(frame, "*"));
    try testing.expectEqual(1, frame.diagnostics.missing_icons);
    try testing.expect(frame.diagnostics.ok());
}

const PressedButton = struct {
    const id: zui.Id = .of("save");

    fn declare(_: *PressedButton, ui: *DrawingUi) void {
        _ = drawing_widgets.button(ui, id, "Save", .{});
    }
};

test "a pressed button shrinks to the press scale through the press motion, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: PressedButton = .{};
    _ = try driver.frame(&app, PressedButton.declare, &.{});
    const pointer = mouse(driver, try driver.pointOn(PressedButton.id, .{ 0.5, 0.5 }));
    _ = try driver.frame(&app, PressedButton.declare, &.{ .{ .pointer_move = .{ .pointer = pointer } }, .{ .pointer_down = .{ .pointer = pointer } } });
    var frame = try driver.frame(&app, PressedButton.declare, &.{});
    const partway = (transformOf(frame) orelse return error.NotScaled).scale[0];
    try testing.expect(partway < 1 and partway > drawing_tokens.motion.press_scale);
    for (0..20) |_| frame = try driver.frame(&app, PressedButton.declare, &.{});
    try testing.expectApproxEqAbs(drawing_tokens.motion.press_scale, transformOf(frame).?.scale[0], 1e-4);
    _ = try driver.frame(&app, PressedButton.declare, &.{.{ .pointer_up = .{ .pointer = pointer } }});
    for (0..20) |_| frame = try driver.frame(&app, PressedButton.declare, &.{});
    try testing.expectEqual(@as(?zui.Transform, null), transformOf(frame));

    _ = try driver.frame(&app, PressedButton.declare, &.{ .{ .environment = .{ .reduced_motion = true } }, .{ .pointer_down = .{ .pointer = pointer } } });
    frame = try driver.frame(&app, PressedButton.declare, &.{});
    try testing.expectApproxEqAbs(drawing_tokens.motion.press_scale, transformOf(frame).?.scale[0], 1e-4);
}

// =============================================================
// Checkbox
// =============================================================

const Agreement = struct {
    const id: zui.Id = .of("agree");
    agreed: bool = false,

    fn declare(app: *Agreement, ui: *Ui) void {
        _ = widgets.checkbox(ui, id, "I agree", &app.agreed, .{});
    }

    fn markSide(frame: *const Ui.Frame) ?f32 {
        const box = frame.rectOf(id).?;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.payload.rectangle.color.eql(color(.on_accent)) and command.bounds.x >= box.x) return command.bounds.width;
        }
        return null;
    }
};

test "a checkbox's mark grows in through the check motion, and at once under reduced motion" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Agreement = .{};
    var frame = try driver.frame(&app, Agreement.declare, &.{});
    try testing.expectEqual(null, Agreement.markSide(frame));
    const full = widgets.skin.zuiStyle(.checkbox_mark, .idle, &.{}).size[0];

    frame = try driver.click(&app, Agreement.declare, Agreement.id);
    try testing.expect(app.agreed);
    frame = try driver.frame(&app, Agreement.declare, &.{});
    const partway = Agreement.markSide(frame) orelse return error.NoMark;
    try testing.expect(partway < full);
    for (0..20) |_| frame = try driver.frame(&app, Agreement.declare, &.{});
    try testing.expectApproxEqAbs(full, Agreement.markSide(frame).?, 0.5);

    _ = try driver.focus(&app, Agreement.declare, Agreement.id);
    frame = try driver.pressKeys(&app, Agreement.declare, &.{.space});
    try testing.expect(!app.agreed);
    try testing.expectEqual(null, Agreement.markSide(frame));

    _ = try driver.frame(&app, Agreement.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    frame = try driver.pressKeys(&app, Agreement.declare, &.{.space});
    try testing.expect(app.agreed);
    try testing.expectApproxEqAbs(full, Agreement.markSide(frame).?, 0.5);
}

// =============================================================
// Slider
// =============================================================

const Volume = struct {
    const id: zui.Id = .of("volume");
    level: u8 = 4,

    fn declare(app: *Volume, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(400) }, .padding = .all(40) } });
        _ = widgets.slider(ui, id, &app.level, .{ .max = 8, .step = 1, .ticks = true, .label = "Volume" });
        ui.close();
    }

    fn ticks(frame: *const Ui.Frame, role: zui.design.ColorRole) usize {
        var count: usize = 0;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.payload.rectangle.color.eql(color(role)) and command.bounds.width == 4 and command.bounds.height == 4) count += 1;
        }
        return count;
    }
};

test "a slider ticks each step, in on_accent on the filled track and outline on the empty one" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Volume = .{};
    _ = try fixture.driver.frame(&app, Volume.declare, &.{});
    const frame = try fixture.driver.frame(&app, Volume.declare, &.{});
    try testing.expectEqual(4, Volume.ticks(frame, .on_accent));
    try testing.expectEqual(4, Volume.ticks(frame, .outline));
}

test "a dragged slider shows its value in a bubble above the thumb, until it is let go" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Volume = .{};
    _ = try driver.frame(&app, Volume.declare, &.{});
    var frame = try driver.frame(&app, Volume.declare, &.{});
    try testing.expectEqual(null, textCommand(frame, "4"));

    const start = mouse(driver, try driver.pointOn(Volume.id, .{ 0.5, 0.5 }));
    _ = try driver.frame(&app, Volume.declare, &.{ .{ .pointer_move = .{ .pointer = start } }, .{ .pointer_down = .{ .pointer = start } } });
    const end = mouse(driver, try driver.pointOn(Volume.id, .{ 1, 0.5 }));
    frame = try driver.frame(&app, Volume.declare, &.{.{ .pointer_move = .{ .pointer = end } }});
    try testing.expectEqual(@as(u8, 8), app.level);
    const bubble = textCommand(frame, "8") orelse return error.NoBubble;
    try testing.expectEqual(tokens.colors.get(.idle).get(.on_surface_inverse), bubble.payload.text.style.color);
    const thumb = frame.rectOf(Volume.id.child("thumb")).?;
    try testing.expect(bubble.bounds.y + bubble.bounds.height <= thumb.y - 8 + 0.5);
    try testing.expectApproxEqAbs(thumb.x + thumb.width / 2, bubble.bounds.x + bubble.bounds.width / 2, 0.5);

    frame = try driver.frame(&app, Volume.declare, &.{.{ .pointer_up = .{ .pointer = end } }});
    frame = try driver.frame(&app, Volume.declare, &.{});
    try testing.expectEqual(null, textCommand(frame, "8"));
}

// =============================================================
// Text field
// =============================================================

const Signup = struct {
    const email: zui.Id = .of("email");
    const weight: zui.Id = .of("weight");

    email_bytes: [32]u8 = undefined,
    email_text: zui_widgets.EditableText = undefined,
    weight_bytes: [8]u8 = undefined,
    weight_text: zui_widgets.EditableText = undefined,
    invalid: bool = false,
    used: Widgets = widgets,

    fn init(app: *Signup) void {
        app.email_text = .init(&app.email_bytes, "ada@");
        app.weight_text = .init(&app.weight_bytes, "72");
    }

    fn declare(app: *Signup, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) }, .child_gap = 16 } });
        _ = app.used.textField(ui, email, &app.email_text, .{
            .label = "Email",
            .show_label = true,
            .help = "We send the receipt here.",
            .error_message = if (app.invalid) "Enter a whole address." else "",
            .leading_icon = .search,
        });
        _ = app.used.textField(ui, weight, &app.weight_text, .{ .label = "Weight", .trailing = "kg" });
        ui.close();
    }
};

test "a text field shows its label above it and its help below, and an error in place of the help" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Signup = .{};
    app.init();
    var frame = try fixture.driver.frame(&app, Signup.declare, &.{});
    const field = frame.rectOf(Signup.email).?;
    const label = textCommand(frame, "Email").?;
    try testing.expectEqual(field.x, label.bounds.x);
    try testing.expectApproxEqAbs(field.y - tokens.space(.xs), label.bounds.y + label.bounds.height, 0.5);
    try testing.expectEqual(tokens.text_styles.get(.label_strong).size, label.payload.text.style.size);
    const help = textCommand(frame, "We send the receipt here.").?;
    try testing.expectApproxEqAbs(field.y + field.height + tokens.space(.xs), help.bounds.y, 0.5);
    try testing.expectEqual(color(.on_surface_muted), help.payload.text.style.color);
    try testing.expectEqual(null, borderOf(frame, Signup.email));
    try testing.expectEqualStrings("Email", (try nodeOf(frame, Signup.email)).label);
    try testing.expectEqual(1, frame.diagnostics.missing_icons);

    app.invalid = true;
    frame = try fixture.driver.frame(&app, Signup.declare, &.{});
    try testing.expectEqual(null, textCommand(frame, "We send the receipt here."));
    const message = textCommand(frame, "Enter a whole address.").?;
    try testing.expectEqual(color(.on_danger_container), message.payload.text.style.color);
    const border = borderOf(frame, Signup.email) orelse return error.NoBorder;
    try testing.expectEqual(color(.danger), border.color);
    try testing.expectEqual(@as(f32, 2), border.widths.top);
    try testing.expectEqual(2, frame.diagnostics.missing_icons);
}

test "a text field draws its leading icon before the text and its trailing text after it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Signup = .{ .used = icon_widgets, .invalid = true };
    app.init();
    const frame = try fixture.driver.frame(&app, Signup.declare, &.{});
    try testing.expectEqual(2, textCount(frame, "*"));
    try testing.expectEqual(0, frame.diagnostics.missing_icons);
    var icon: ?zui.Rect = null;
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, "*") and command.payload.text.style.size == icon_tokens.icon_sizes.get(.small)) icon = command.bounds;
    }
    const leading = icon orelse return error.NoIcon;
    try testing.expect(leading.x + leading.width <= textCommand(frame, "ada@").?.bounds.x);
    const weight_field = frame.rectOf(Signup.weight).?;
    const unit = textCommand(frame, "kg").?;
    try testing.expect(unit.bounds.x > textCommand(frame, "72").?.bounds.x);
    try testing.expectApproxEqAbs(weight_field.x + weight_field.width - icon_tokens.space(.m), unit.bounds.x + unit.bounds.width, 0.5);
}

// =============================================================
// Dropdown
// =============================================================

const Frequency = struct {
    const id: zui.Id = .of("frequency");
    choice: usize = 1,
    used: Widgets = widgets,

    fn declare(app: *Frequency, ui: *Ui) void {
        _ = app.used.dropdown(ui, id, &app.choice, &.{ "Hourly", "Daily", "Weekly" }, .{ .label = "Frequency" });
    }
};

test "an open dropdown checks its selected option at its end, in on_surface_accent" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Frequency = .{ .used = icon_widgets };
    _ = try fixture.driver.frame(&app, Frequency.declare, &.{});
    var frame = try fixture.driver.click(&app, Frequency.declare, Frequency.id);
    frame = try fixture.driver.frame(&app, Frequency.declare, &.{});
    try testing.expectEqual(2, textCount(frame, "*"));
    const option = frame.rectOf(Frequency.id.indexedChild("option", 1)).?;
    var found: ?zui.Rect = null;
    for (frame.commands()) |command| {
        if (command.payload != .text or !std.mem.eql(u8, command.payload.text.content, "*") or command.bounds.y < option.y) continue;
        try testing.expectEqual(icon_tokens.colors.get(.idle).get(.on_surface_accent), command.payload.text.style.color);
        found = command.bounds;
    }
    const check = found orelse return error.NoCheck;
    try testing.expect(check.y < option.y + option.height);
    try testing.expectApproxEqAbs(option.x + option.width - icon_tokens.space(.m), check.x + check.width, 0.5);

    app.used = widgets;
    frame = try fixture.driver.frame(&app, Frequency.declare, &.{});
    try testing.expectEqual(0, textCount(frame, "*"));
    try testing.expect(textCommand(frame, "v") != null);
    try testing.expectEqual(1, frame.diagnostics.missing_icons);
}

// =============================================================
// Radio group
// =============================================================

const Rooms = struct {
    const Room = enum { single, double, family_suite };
    const id: zui.Id = .of("room");
    room: Room = .single,
    direction: zui.Direction = .top_to_bottom,

    fn declare(app: *Rooms, ui: *Ui) void {
        _ = widgets.radioGroup(ui, id, &app.room, .{ .label = "Room", .direction = app.direction });
    }

    fn option(index: usize) zui.Id {
        return id.indexedChild("option", index);
    }
};

test "a radio group chooses by click, and the arrow keys move the choice and the focus with it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Rooms = .{};
    var frame = try driver.frame(&app, Rooms.declare, &.{});
    try testing.expectEqualStrings("Family suite", textCommand(frame, "Family suite").?.payload.text.content);
    _ = try driver.click(&app, Rooms.declare, Rooms.option(2));
    try testing.expectEqual(.family_suite, app.room);

    _ = try driver.focus(&app, Rooms.declare, Rooms.option(2));
    _ = try driver.pressKeys(&app, Rooms.declare, &.{.down});
    try testing.expectEqual(.single, app.room);
    frame = try driver.frame(&app, Rooms.declare, &.{});
    try testing.expect(fixture.ui.focused(Rooms.option(0)));
    _ = try driver.pressKeys(&app, Rooms.declare, &.{.up});
    try testing.expectEqual(.family_suite, app.room);

    app.direction = .left_to_right;
    _ = try driver.frame(&app, Rooms.declare, &.{});
    _ = try driver.pressKeys(&app, Rooms.declare, &.{.right});
    try testing.expectEqual(.single, app.room);
    frame = try driver.frame(&app, Rooms.declare, &.{});
    try testing.expect(frame.rectOf(Rooms.option(1)).?.x > frame.rectOf(Rooms.option(0)).?.x);
}

test "only the chosen option is in the Tab order, and each says whether it is chosen" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Rooms = .{ .room = .double };
    _ = try fixture.driver.frame(&app, Rooms.declare, &.{});
    const frame = try fixture.driver.pressKeys(&app, Rooms.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Rooms.option(1)));
    for (0..3) |index| {
        const node = try nodeOf(frame, Rooms.option(index));
        try testing.expectEqual(zui.SemanticRole.radio, node.role);
        try testing.expectEqual(index == 1, node.state.checked.?);
    }
    try testing.expectEqualStrings("Room", (try nodeOf(frame, Rooms.id)).label);
    const ring = borderOf(frame, Rooms.option(1)) orelse return error.NoRing;
    try testing.expectEqual(tokens.colors.get(.focused).get(.focus), ring.color);
    const circle_ring = tokens.colors.get(.idle).get(.accent);
    var rings: usize = 0;
    for (frame.commands()) |command| {
        if (command.payload == .border and command.payload.border.color.eql(circle_ring) and command.payload.border.widths.top == 5.5) rings += 1;
    }
    try testing.expectEqual(1, rings);
}

// =============================================================
// Segmented control
// =============================================================

const Views = struct {
    const View = enum { list, grid, map };
    const id: zui.Id = .of("view");
    view: View = .list,

    fn declare(app: *Views, ui: *DrawingUi) void {
        _ = drawing_widgets.segmented(ui, id, &app.view, .{ .label = "View" });
    }

    fn segment(index: usize) zui.Id {
        return id.indexedChild("segment", index);
    }

    fn thumbX(frame: *const DrawingUi.Frame) ?f32 {
        const surface = drawing_tokens.colors.get(.idle).get(.surface_raised);
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.payload.rectangle.color.eql(surface)) return command.bounds.x;
        }
        return null;
    }

    fn separators(frame: *const DrawingUi.Frame) usize {
        const line = drawing_tokens.colors.get(.idle).get(.outline_muted);
        var count: usize = 0;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.payload.rectangle.color.eql(line) and command.bounds.width == 1) count += 1;
        }
        return count;
    }
};

test "a segmented control slides its thumb to the chosen segment through the toggle spring, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Views = .{};
    _ = try driver.frame(&app, Views.declare, &.{});
    var frame = try driver.frame(&app, Views.declare, &.{});
    try testing.expectApproxEqAbs(frame.rectOf(Views.segment(0)).?.x, Views.thumbX(frame).?, 0.5);
    try testing.expectEqual(1, Views.separators(frame));

    _ = try driver.click(&app, Views.declare, Views.segment(2));
    try testing.expectEqual(.map, app.view);
    frame = try driver.frame(&app, Views.declare, &.{});
    const target = frame.rectOf(Views.segment(2)).?.x;
    try testing.expect(Views.thumbX(frame).? < target - 1);
    for (0..40) |_| frame = try driver.frame(&app, Views.declare, &.{});
    try testing.expectApproxEqAbs(target, Views.thumbX(frame).?, 0.5);
    try testing.expectEqual(1, Views.separators(frame));

    _ = try driver.focus(&app, Views.declare, Views.segment(2));
    _ = try driver.pressKeys(&app, Views.declare, &.{.right});
    try testing.expectEqual(.list, app.view);
    _ = try driver.frame(&app, Views.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = try driver.pressKeys(&app, Views.declare, &.{.left});
    try testing.expectEqual(.map, app.view);
    frame = try driver.frame(&app, Views.declare, &.{});
    try testing.expectApproxEqAbs(frame.rectOf(Views.segment(2)).?.x, Views.thumbX(frame).?, 0.5);
}

// =============================================================
// Number stepper
// =============================================================

const Nights = struct {
    const id: zui.Id = .of("nights");
    const decrement = id.child("decrement");
    const increment = id.child("increment");
    nights: u8 = 2,

    fn declare(app: *Nights, ui: *Ui) void {
        ui.open(.{ .layout = .{ .padding = .all(20) } });
        _ = widgets.numberStepper(ui, id, &app.nights, .{ .min = 1, .max = 5, .unit = "nights", .label = "Nights" });
        ui.close();
    }
};

test "a number stepper steps with its buttons, disabled at each limit, and with Up and Down" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Nights = .{};
    var frame = try driver.frame(&app, Nights.declare, &.{});
    try testing.expect(textCommand(frame, "2") != null);
    try testing.expect(textCommand(frame, "nights") != null);
    _ = try driver.click(&app, Nights.declare, Nights.decrement);
    try testing.expectEqual(@as(u8, 1), app.nights);
    frame = try driver.click(&app, Nights.declare, Nights.decrement);
    try testing.expectEqual(@as(u8, 1), app.nights);
    try testing.expect((try nodeOf(frame, Nights.decrement)).state.disabled);

    _ = try driver.focus(&app, Nights.declare, Nights.id);
    _ = try driver.pressKeys(&app, Nights.declare, &.{ .up, .up, .up, .up, .up, .up });
    try testing.expectEqual(@as(u8, 5), app.nights);
    frame = try driver.pressKeys(&app, Nights.declare, &.{.down});
    try testing.expectEqual(@as(u8, 4), app.nights);
    const node = try nodeOf(frame, Nights.id);
    try testing.expectEqualStrings("Nights", node.label);
    try testing.expectEqual(@as(f64, 4), node.value.range.value);
    _ = try driver.action(&app, Nights.declare, Nights.id, .{ .adjust = -2 });
    try testing.expectEqual(@as(u8, 2), app.nights);
}

test "typing into a focused number stepper replaces its value" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Nights = .{};
    _ = try driver.frame(&app, Nights.declare, &.{});
    _ = try driver.focus(&app, Nights.declare, Nights.id);
    _ = try driver.typeText(&app, Nights.declare, "4");
    try testing.expectEqual(@as(u8, 4), app.nights);
    _ = try driver.typeText(&app, Nights.declare, "0");
    try testing.expectEqual(@as(u8, 5), app.nights);
    _ = try driver.pressKeys(&app, Nights.declare, &.{.backspace});
    try testing.expectEqual(@as(u8, 4), app.nights);
    const frame = try driver.typeText(&app, Nights.declare, "x");
    try testing.expectEqual(@as(u8, 4), app.nights);
    try testing.expect(textCommand(frame, "4") != null);
}

test "dragging a number stepper's value sideways scrubs a step for every four units" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Nights = .{ .nights = 1 };
    _ = try driver.frame(&app, Nights.declare, &.{});
    const start = try driver.pointOn(Nights.id.child("value"), .{ 0.5, 0.5 });
    const down = mouse(driver, start);
    _ = try driver.frame(&app, Nights.declare, &.{ .{ .pointer_move = .{ .pointer = down } }, .{ .pointer_down = .{ .pointer = down } } });
    _ = try driver.frame(&app, Nights.declare, &.{.{ .pointer_move = .{ .pointer = mouse(driver, .{ start[0] + 9, start[1] }) } }});
    try testing.expectEqual(@as(u8, 3), app.nights);
    _ = try driver.frame(&app, Nights.declare, &.{.{ .pointer_move = .{ .pointer = mouse(driver, .{ start[0] + 100, start[1] }) } }});
    try testing.expectEqual(@as(u8, 5), app.nights);
    _ = try driver.frame(&app, Nights.declare, &.{.{ .pointer_up = .{ .pointer = mouse(driver, .{ start[0] + 100, start[1] }) } }});
}

// =============================================================
// Search field
// =============================================================

const Search = struct {
    const id: zui.Id = .of("search");
    bytes: [32]u8 = undefined,
    query: zui_widgets.EditableText = undefined,

    fn init(app: *Search, initial: []const u8) void {
        app.query = .init(&app.bytes, initial);
    }

    fn declare(app: *Search, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(300) }, .padding = .all(10) } });
        _ = widgets.searchField(ui, id, &app.query, .{ .shortcut = "Ctrl K", .label = "Search" });
        ui.close();
    }
};

test "a search field shows its shortcut while empty and unfocused, and a clear button while it has text" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Search = .{};
    app.init("");
    var frame = try driver.frame(&app, Search.declare, &.{});
    try testing.expect(textCommand(frame, "Ctrl K") != null);
    try testing.expect(textCommand(frame, "Search") != null);
    try testing.expectEqual(null, frame.rectOf(Search.id.child("clear")));
    try testing.expectEqual(1, frame.diagnostics.missing_icons);
    const field = rectangleOf(frame, Search.id).?;
    try testing.expectEqual(frame.rectOf(Search.id).?.height / 2, field.corner_radius.top_left);

    _ = try driver.focus(&app, Search.declare, Search.id);
    frame = try driver.typeText(&app, Search.declare, "lisbon");
    try testing.expectEqual(null, textCommand(frame, "Ctrl K"));
    frame = try driver.frame(&app, Search.declare, &.{});
    try testing.expect(textCommand(frame, "×") != null);
    _ = try driver.click(&app, Search.declare, Search.id.child("clear"));
    try testing.expectEqualStrings("", app.query.slice());
}

test "Escape clears a search field, and a second Escape leaves it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Search = .{};
    app.init("harbor");
    _ = try driver.frame(&app, Search.declare, &.{});
    _ = try driver.focus(&app, Search.declare, Search.id);
    _ = try driver.pressKeys(&app, Search.declare, &.{.escape});
    try testing.expectEqualStrings("", app.query.slice());
    try testing.expect(fixture.ui.focused(Search.id));
    _ = try driver.pressKeys(&app, Search.declare, &.{.escape});
    _ = try driver.frame(&app, Search.declare, &.{});
    try testing.expect(!fixture.ui.focused(Search.id));
}

// =============================================================
// Icon button and link
// =============================================================

const Toolbar = struct {
    const close: zui.Id = .of("close");
    const help: zui.Id = .of("help");
    closes: u32 = 0,
    follows: u32 = 0,
    used: Widgets = widgets,

    fn declare(app: *Toolbar, ui: *Ui) void {
        ui.open(.{ .layout = .{ .padding = .all(10), .child_gap = 10, .child_alignment = .{ .y = .center } } });
        if (app.used.iconButton(ui, close, .close, .{ .label = "Close", .size = .small })) app.closes += 1;
        if (app.used.link(ui, help, "Help", "https://example.com/help")) app.follows += 1;
        ui.close();
    }

    fn underline(frame: *const Ui.Frame) ?zui.Color {
        const text = textCommand(frame, "Help").?.bounds;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.bounds.height == 1 and command.bounds.y >= text.y + text.height - 0.5) return command.payload.rectangle.color;
        }
        return null;
    }
};

test "an icon button is a square of its size, named by its label, and draws its icon only from an icon font" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    var frame = try driver.frame(&app, Toolbar.declare, &.{});
    const side = tokens.control_heights.get(.small);
    try testing.expectEqual(side, frame.rectOf(Toolbar.close).?.width);
    try testing.expectEqual(side, frame.rectOf(Toolbar.close).?.height);
    const node = try nodeOf(frame, Toolbar.close);
    try testing.expectEqual(zui.SemanticRole.button, node.role);
    try testing.expectEqualStrings("Close", node.label);
    try testing.expectEqual(1, frame.diagnostics.missing_icons);
    _ = try driver.click(&app, Toolbar.declare, Toolbar.close);
    _ = try driver.focus(&app, Toolbar.declare, Toolbar.close);
    _ = try driver.pressKeys(&app, Toolbar.declare, &.{.space});
    try testing.expectEqual(@as(u32, 2), app.closes);

    frame = try driver.hover(&app, Toolbar.declare, Toolbar.close);
    try testing.expectEqual(tokens.colors.get(.hovered).get(.secondary_container), rectangleOf(frame, Toolbar.close).?.color);
    app.used = icon_widgets;
    frame = try driver.frame(&app, Toolbar.declare, &.{});
    const glyph = textCommand(frame, "*").?.payload.text.style;
    try testing.expectEqual(icon_tokens.icon_sizes.get(.small), glyph.size);
    try testing.expectEqual(icon_tokens.colors.get(.hovered).get(.on_surface), glyph.color);
    try testing.expectEqual(0, frame.diagnostics.missing_icons);
}

test "a link is underlined faintly until hovered, reports its address, and is followed by click or Enter" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    var frame = try driver.frame(&app, Toolbar.declare, &.{});
    const accent = color(.on_surface_accent);
    try testing.expectEqual(accent, textCommand(frame, "Help").?.payload.text.style.color);
    try testing.expectApproxEqAbs(@as(f32, 0.4), @as(f32, @floatFromInt(Toolbar.underline(frame).?.a)) / 255, 0.01);
    try testing.expect(frame.rectOf(Toolbar.help).?.height >= tokens.target_floors.get(.pointer));
    const node = try nodeOf(frame, Toolbar.help);
    try testing.expectEqual(zui.SemanticRole.link, node.role);
    try testing.expectEqualStrings("https://example.com/help", node.value.text);

    frame = try driver.hover(&app, Toolbar.declare, Toolbar.help);
    try testing.expectEqual(@as(u8, 255), Toolbar.underline(frame).?.a);
    _ = try driver.click(&app, Toolbar.declare, Toolbar.help);
    _ = try driver.focus(&app, Toolbar.declare, Toolbar.help);
    _ = try driver.pressKeys(&app, Toolbar.declare, &.{.enter});
    try testing.expectEqual(@as(u32, 2), app.follows);
}

// =============================================================
// Chip
// =============================================================

const Filters = struct {
    const sea: zui.Id = .of("sea");
    const city: zui.Id = .of("city");
    sea_view: bool = false,
    toggles: u32 = 0,
    closes: u32 = 0,

    fn declare(app: *Filters, ui: *DrawingUi) void {
        ui.open(.{ .layout = .{ .padding = .all(10), .child_gap = 10 } });
        if (drawing_widgets.chip(ui, sea, "Sea view", .{ .selected = &app.sea_view }).toggled) app.toggles += 1;
        if (drawing_widgets.chip(ui, city, "Lisbon", .{ .closable = true }).closed) app.closes += 1;
        ui.close();
    }
};

test "a filter chip toggles by click and Space, filling in accent_container and leading with a growing check" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Filters = .{};
    var frame = try driver.frame(&app, Filters.declare, &.{});
    const resting_width = frame.rectOf(Filters.sea).?.width;
    try testing.expectEqual(drawing_tokens.colors.get(.idle).get(.surface_sunken), rectangleOf(frame, Filters.sea).?.color);

    _ = try driver.click(&app, Filters.declare, Filters.sea);
    try testing.expect(app.sea_view);
    frame = try driver.frame(&app, Filters.declare, &.{});
    const partway = frame.rectOf(Filters.sea).?.width;
    try testing.expect(partway > resting_width);
    for (0..20) |_| frame = try driver.frame(&app, Filters.declare, &.{});
    const full = drawing_tokens.icon_sizes.get(.small) + drawing_tokens.space(.xs);
    try testing.expectApproxEqAbs(resting_width + full, frame.rectOf(Filters.sea).?.width, 0.5);
    try testing.expect(partway < resting_width + full);
    try testing.expectEqual(drawing_tokens.colors.get(.hovered).get(.accent_container), rectangleOf(frame, Filters.sea).?.color);
    try testing.expectEqual(1, frame.diagnostics.missing_icons);

    _ = try driver.focus(&app, Filters.declare, Filters.sea);
    _ = try driver.pressKeys(&app, Filters.declare, &.{.space});
    try testing.expect(!app.sea_view);
    try testing.expectEqual(@as(u32, 2), app.toggles);
}

test "a closable chip closes by its button, by Delete or Backspace, and by a dismiss action" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Filters = .{};
    const frame = try driver.frame(&app, Filters.declare, &.{});
    const close = frame.rectOf(Filters.city.child("close")).?;
    try testing.expect(close.height >= drawing_tokens.target_floors.get(.pointer));
    try testing.expect(textCommand(frame, "×") != null);
    _ = try driver.click(&app, Filters.declare, Filters.city.child("close"));
    try testing.expectEqual(@as(u32, 1), app.closes);
    _ = try driver.focus(&app, Filters.declare, Filters.city);
    _ = try driver.pressKeys(&app, Filters.declare, &.{.delete});
    _ = try driver.pressKeys(&app, Filters.declare, &.{.backspace});
    try testing.expectEqual(@as(u32, 3), app.closes);
}

const DismissableTag = struct {
    const id: zui.Id = .of("tag");
    closes: u32 = 0,

    fn declare(app: *DismissableTag, ui: *Ui) void {
        if (widgets.chip(ui, id, "Urgent", .{ .closable = true }).closed) app.closes += 1;
    }
};

test "a closable chip lists the dismiss action" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: DismissableTag = .{};
    const frame = try fixture.driver.frame(&app, DismissableTag.declare, &.{});
    try testing.expect((try nodeOf(frame, DismissableTag.id)).actions.contains(.dismiss));
    _ = try fixture.driver.action(&app, DismissableTag.declare, DismissableTag.id, .dismiss);
    try testing.expectEqual(@as(u32, 1), app.closes);
}

// =============================================================
// Toggle
// =============================================================

const Breakfast = struct {
    const id: zui.Id = .of("breakfast");
    on: bool = false,

    fn declare(app: *Breakfast, ui: *DrawingUi) void {
        _ = drawing_widgets.toggle(ui, id, "Breakfast", &app.on, .{});
    }

    fn declareFlat(app: *Breakfast, ui: *Ui) void {
        _ = widgets.toggle(ui, id, "Breakfast", &app.on, .{});
    }

    /// The rectangle as tall as the thumb, which is in `state`'s layer of
    /// `surface`.
    fn thumb(frame: anytype, surface: zui.design.ColorRole, state: zui.WidgetState) ?zui.Rect {
        const side = drawing_tokens.control_heights.get(.small) - 8;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.bounds.height == side) {
                if (!command.payload.rectangle.color.eql(drawing_tokens.colors.get(state).get(surface))) return null;
                return command.bounds;
            }
        }
        return null;
    }
};

test "a toggle switches by click and Space, its thumb springing across, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Breakfast = .{};
    var frame = try driver.frame(&app, Breakfast.declare, &.{});
    const off = Breakfast.thumb(frame, .outline, .idle) orelse return error.NoThumb;
    const track_height = drawing_tokens.control_heights.get(.small) - 4;
    try testing.expectEqual(track_height - 4, off.height);

    _ = try driver.click(&app, Breakfast.declare, Breakfast.id);
    try testing.expect(app.on);
    frame = try driver.frame(&app, Breakfast.declare, &.{});
    const travel = 2 * track_height - 8 - 4 - off.width;
    const partway = (Breakfast.thumb(frame, .surface_raised, .hovered) orelse return error.NoThumb).x;
    try testing.expect(partway > off.x and partway < off.x + travel);
    for (0..40) |_| frame = try driver.frame(&app, Breakfast.declare, &.{});
    try testing.expectApproxEqAbs(off.x + travel, Breakfast.thumb(frame, .surface_raised, .hovered).?.x, 0.5);
    var accent_track: ?zui.Rect = null;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.payload.rectangle.color.eql(drawing_tokens.colors.get(.hovered).get(.accent))) accent_track = command.bounds;
    }
    try testing.expectEqual(2 * track_height - 8, (accent_track orelse return error.NoTrack).width);

    _ = try driver.frame(&app, Breakfast.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = try driver.focus(&app, Breakfast.declare, Breakfast.id);
    frame = try driver.pressKeys(&app, Breakfast.declare, &.{.space});
    try testing.expect(!app.on);
    frame = try driver.frame(&app, Breakfast.declare, &.{});
    try testing.expectApproxEqAbs(off.x, Breakfast.thumb(frame, .outline, .hovered).?.x, 0.5);
}

test "a pressed toggle's thumb widens toward its travel, and the switch reports itself on or off" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Breakfast = .{};
    var frame = try driver.frame(&app, Breakfast.declareFlat, &.{});
    const resting = Breakfast.thumb(frame, .outline, .idle).?;
    const node = try nodeOf(frame, Breakfast.id);
    try testing.expectEqual(zui.SemanticRole.toggle, node.role);
    try testing.expectEqual(false, node.state.checked.?);
    const pointer = mouse(driver, try driver.pointOn(Breakfast.id, .{ 0.9, 0.5 }));
    frame = try driver.frame(&app, Breakfast.declareFlat, &.{ .{ .pointer_move = .{ .pointer = pointer } }, .{ .pointer_down = .{ .pointer = pointer } } });
    for (0..30) |_| frame = try driver.frame(&app, Breakfast.declareFlat, &.{});
    const pressed = Breakfast.thumb(frame, .outline, .pressed).?;
    try testing.expectEqual(resting.x, pressed.x);
    try testing.expectEqual(resting.width + 4, pressed.width);
}

// =============================================================
// When the focus ring shows
// =============================================================

const Ringed = struct {
    const save: zui.Id = .of("save");
    const share: zui.Id = .of("share");
    const note: zui.Id = .of("note");

    note_bytes: [16]u8 = undefined,
    note_text: zui_widgets.EditableText = undefined,
    saves: u32 = 0,

    fn init(app: *Ringed) void {
        app.note_text = .init(&app.note_bytes, "");
    }

    fn declare(app: *Ringed, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .padding = .all(20), .child_gap = 20 } });
        if (widgets.button(ui, save, "Save", .{})) app.saves += 1;
        _ = widgets.button(ui, share, "Share", .{});
        _ = widgets.textField(ui, note, &app.note_text, .{ .label = "Note" });
        ui.close();
    }

    fn ringed(ui: *const Ui, frame: anytype, id: zui.Id) bool {
        const drawn = borderOf(frame, id) orelse return false;
        const part: zui_widgets.Part = if (id.hash == note.hash) .text_field else .button;
        const ring = widgets.style(ui, part, .focused).focus_ring.?;
        return drawn.color.eql(ring.color) and std.meta.eql(drawn.widths, ring.widths);
    }

    fn start(fixture: *Fixture(Ui), app: *Ringed) !void {
        try fixture.init();
        app.init();
        _ = try fixture.driver.frame(app, declare, &.{});
    }

    fn pointerAt(driver: anytype, id: zui.Id) !zui.Pointer {
        return .{ .id = .mouse, .kind = .mouse, .position = try driver.pointOn(id, .{ 0.5, 0.5 }), .at = driver.now };
    }
};

test "the ring shows after Tab, a gamepad's move and an accessibility action, and not after a click" {
    var fixture: Fixture(Ui) = .{};
    var app: Ringed = .{};
    try Ringed.start(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    var frame = try driver.pressKeys(&app, Ringed.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Ringed.save));
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));
    try testing.expectEqual(zui.WidgetState.focused, fixture.ui.widgetState(Ringed.save));

    frame = try driver.click(&app, Ringed.declare, Ringed.share);
    try testing.expect(fixture.ui.focused(Ringed.share));
    try testing.expect(!fixture.ui.focusVisible());
    try testing.expect(!Ringed.ringed(&fixture.ui, frame, Ringed.share));

    frame = try driver.pressDirection(&app, Ringed.declare, .down);
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.share));

    _ = try driver.click(&app, Ringed.declare, Ringed.share);
    frame = try driver.action(&app, Ringed.declare, Ringed.save, .focus);
    try testing.expect(fixture.ui.focused(Ringed.save));
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));
}

test "Space on a clicked button shows its ring, and Ctrl+S does not" {
    var fixture: Fixture(Ui) = .{};
    var app: Ringed = .{};
    try Ringed.start(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&app, Ringed.declare, Ringed.save);
    try testing.expectEqual(1, app.saves);
    driver.modifiers = .{ .control = true };
    var frame = try driver.pressKeys(&app, Ringed.declare, &.{.s});
    try testing.expect(!Ringed.ringed(&fixture.ui, frame, Ringed.save));
    frame = try driver.pressKeys(&app, Ringed.declare, &.{.control});
    try testing.expect(!Ringed.ringed(&fixture.ui, frame, Ringed.save));
    driver.modifiers = .{};
    frame = try driver.pressKeys(&app, Ringed.declare, &.{.shift});
    try testing.expect(!Ringed.ringed(&fixture.ui, frame, Ringed.save));

    frame = try driver.pressKeys(&app, Ringed.declare, &.{.space});
    try testing.expectEqual(2, app.saves);
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));
}

test "a click's release hides the ring, its press does not, and a press Escape cancels keeps it" {
    var fixture: Fixture(Ui) = .{};
    var app: Ringed = .{};
    try Ringed.start(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.pressKeys(&app, Ringed.declare, &.{.tab});
    const on_save = try Ringed.pointerAt(driver, Ringed.save);
    var frame = try driver.frame(&app, Ringed.declare, &.{ .{ .pointer_move = .{ .pointer = on_save } }, .{ .pointer_down = .{ .pointer = on_save } } });
    try testing.expect(fixture.ui.pressed(Ringed.save));
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));

    frame = try driver.pressKeys(&app, Ringed.declare, &.{.escape});
    try testing.expect(!fixture.ui.pressed(Ringed.save));
    frame = try driver.frame(&app, Ringed.declare, &.{.{ .pointer_up = .{ .pointer = on_save } }});
    try testing.expectEqual(0, app.saves);
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));

    frame = try driver.click(&app, Ringed.declare, Ringed.save);
    try testing.expectEqual(1, app.saves);
    try testing.expect(fixture.ui.focused(Ringed.save));
    try testing.expect(!Ringed.ringed(&fixture.ui, frame, Ringed.save));
}

test "a focused control keeps its ring while hovered, the hover's fill drawn with it" {
    var fixture: Fixture(Ui) = .{};
    var app: Ringed = .{};
    try Ringed.start(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.pressKeys(&app, Ringed.declare, &.{.tab});
    const frame = try driver.hover(&app, Ringed.declare, Ringed.save);
    try testing.expectEqual(zui.WidgetState.hovered, fixture.ui.widgetState(Ringed.save));
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.save));
    try testing.expectEqual(widgets.style(&fixture.ui, .button, .hovered).background.?, rectangleOf(frame, Ringed.save).?.color);

    const wheel = try driver.frame(&app, Ringed.declare, &.{.{ .wheel = .{ .position = try driver.pointOn(Ringed.save, .{ 0.5, 0.5 }), .delta = .{ 0, 40 }, .at = driver.now } }});
    try testing.expect(Ringed.ringed(&fixture.ui, wheel, Ringed.save));
}

test "a text field shows its ring however it was focused, a click too" {
    var fixture: Fixture(Ui) = .{};
    var app: Ringed = .{};
    try Ringed.start(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.click(&app, Ringed.declare, Ringed.note);
    const frame = try driver.frame(&app, Ringed.declare, &.{.{ .pointer_leave = .mouse }});
    try testing.expect(fixture.ui.focused(Ringed.note));
    try testing.expect(!fixture.ui.focusVisible());
    try testing.expect(Ringed.ringed(&fixture.ui, frame, Ringed.note));
    try testing.expectEqual(zui.WidgetState.idle, fixture.ui.widgetState(Ringed.note));
}

// =============================================================
// Every component, under review
// =============================================================

const page_room = 16;

fn auditGlance(comptime Component: type, permutation: zui_design.Permutation, preview: anytype) !void {
    var resolved: zui.design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(zui_design.default, permutation.axes.preferences(.{}), &resolved);
    const skinned: Widgets = .{ .skin = .{ .tokens = &resolved } };
    var events: [zui_design.Axes.environment_change_count]zui.Event = undefined;
    for (permutation.axes.environmentChanges(), &events) |change, *event| event.* = .{ .environment = change };

    const Shown = struct {
        widgets: Widgets,
        preview: @TypeOf(preview),

        fn declare(shown: *@This(), ui: *Ui) void {
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16) },
                .decoration = .{ .background = shown.widgets.skin.tokens.colors.get(.idle).get(.surface) },
            });
            Component.declare(shown.widgets, ui, shown.preview);
            ui.close();
        }
    };
    var shown: Shown = .{ .widgets = skinned, .preview = preview };
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.driver.frame(&shown, Shown.declare, &events);
    _ = try fixture.driver.frame(&shown, Shown.declare, &.{});
    const frame = try fixture.driver.pressKeys(&shown, Shown.declare, &.{.tab});
    const options: zui_design.AuditOptions = .fromTokens(&resolved, permutation.axes.contrast);
    var room: [page_room]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    for (findings.slice()) |finding| std.debug.print("{s} {any}: {any}\n", .{ @typeName(Component), permutation.axes, finding.measured });
    try testing.expectEqual(0, findings.slice().len + findings.dropped);
}

test "every input's glance permutations audit clean" {
    inline for (zui_widgets.previews.inputs) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (0..Glance.count) |index| {
            const permutation = Glance.at(index);
            try auditGlance(Component, permutation, Glance.preview(permutation));
        }
    }
}

test "every input audits clean in every scheme and density" {
    inline for (zui_widgets.previews.inputs) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (std.enums.values(zui_design.Scheme)) |scheme| {
            for (std.enums.values(zui.design.Density)) |density| {
                for (0..Glance.preview_count) |preview| {
                    const permutation: zui_design.Permutation = .{
                        .axes = .{ .theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark, .contrast = scheme.environmentContrast(), .density = density },
                        .preview = @intCast(preview),
                    };
                    try auditGlance(Component, permutation, Glance.preview(permutation));
                }
            }
        }
    }
}

/// Declares every part of the inputs that `tests.zig`'s form does not, once
/// the second frame has the rectangles the segmented thumb is placed from.
pub fn EveryInput(comptime SkinnedWidgets: type) type {
    return struct {
        const Self = @This();
        const Choice = enum { one, two, three };
        pub const ids = struct {
            pub const stepper: zui.Id = .of("input.stepper");
        };

        widgets: SkinnedWidgets,
        stacked: Choice = .one,
        row: Choice = .two,
        segment: Choice = .one,
        count: i32 = 2,
        empty_bytes: [16]u8 = undefined,
        empty: zui_widgets.EditableText = undefined,
        typed_bytes: [16]u8 = undefined,
        typed: zui_widgets.EditableText = undefined,
        chosen: bool = true,
        unchosen: bool = false,
        on: bool = true,
        off: bool = false,

        pub fn init(form: *Self, skinned: SkinnedWidgets) void {
            form.* = .{ .widgets = skinned };
            form.empty = .init(&form.empty_bytes, "");
            form.typed = .init(&form.typed_bytes, "query");
        }

        pub fn declare(form: *Self, ui: anytype) void {
            const used = form.widgets;
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360) }, .padding = .all(10), .child_gap = 10 } });
            _ = used.radioGroup(ui, .of("input.stacked"), &form.stacked, .{});
            _ = used.radioGroup(ui, .of("input.row"), &form.row, .{ .direction = .left_to_right });
            _ = used.segmented(ui, .of("input.segmented"), &form.segment, .{});
            _ = used.numberStepper(ui, ids.stepper, &form.count, .{ .unit = "nights" });
            _ = used.searchField(ui, .of("input.empty_search"), &form.empty, .{ .shortcut = "Ctrl K" });
            _ = used.searchField(ui, .of("input.typed_search"), &form.typed, .{});
            inline for (comptime std.enums.values(zui_widgets.IconButtonVariant)) |variant| {
                _ = used.iconButton(ui, .of("input.icon." ++ @tagName(variant)), .close, .{ .label = @tagName(variant), .variant = variant });
            }
            _ = used.link(ui, .of("input.link"), "link", "https://example.com");
            _ = used.chip(ui, .of("input.chosen_chip"), "chosen", .{ .selected = &form.chosen, .leading_icon = .info });
            _ = used.chip(ui, .of("input.closable_chip"), "closable", .{ .selected = &form.unchosen, .closable = true });
            _ = used.toggle(ui, .of("input.on"), "on", &form.on, .{});
            _ = used.toggle(ui, .of("input.off"), "off", &form.off, .{});
            ui.close();
        }
    };
}
