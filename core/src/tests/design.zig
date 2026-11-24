const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const design = zui.design;
const Ui = support.Ui;

const Chip = struct {
    pub const Part = enum { container, container_selected, label, close };

    pub const zuiAppearance = design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs },
        .container_selected = .{ .surface = .accent_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs, .states = .{ .pressed = .{ .surface = .accent } } },
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .container },
        .close = .{ .icon = .on_secondary_container, .on = .container, .target = .touch, .outline = .outline },
    });

    pub const zuiDistinguish = .{
        .{ .container, .container_selected },
        .{ .close, .idle, .hovered },
    };
};

const Logo = struct {
    pub const Part = enum { mark, caption };

    pub const zuiAppearance = design.Appearance(Part, .{
        .mark = .{ .surface = .unchecked(.rgb(0xff00ff), "the brand's logo") },
        .caption = .{ .text = .on_surface, .on = .mark, .states = .{ .disabled = .{ .text = .unchecked(.rgb(0x808080), "a print proof's grey") } } },
    });
};

const Roles = enum {
    brand,
    on_brand,

    pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand };
};

const Badge = struct {
    pub const Part = enum { body, count };

    pub const zuiAppearance = design.AppearanceWith(Part, Roles, .{
        .body = .{ .surface = .extra(.brand), .shape = .indicator },
        .count = .{ .text = .extra(.on_brand), .type = .numeric, .on = .body, .padding = .{ .x = .xs } },
    });
};

/// Every role's color in every state is distinct: its state's index in
/// the red channel and its role's in the blue.
fn colorFor(state: zui.WidgetState, role_index: usize) zui.Color {
    return .{ .r = @intCast(@intFromEnum(state)), .g = 0, .b = @intCast(role_index) };
}

fn filledTokens(comptime ExtraRoles: type) design.Tokens(Ui, ExtraRoles) {
    var tokens: design.Tokens(Ui, ExtraRoles) = .{
        .spacing = .init(.{ .none = 0, .hair = 1, .xs = 4, .s = 8, .m = 12, .l = 16, .xl = 24, .xxl = 32 }),
        .target_floors = .init(.{ .none = 0, .pointer = 24, .touch = 44 }),
        .outline_width = 1,
        .focus_ring_width = 2,
        .measure = 600,
    };
    for (std.enums.values(zui.WidgetState)) |state| {
        for (std.enums.values(design.ColorRole)) |role| tokens.colors.getPtr(state).set(role, colorFor(state, @intFromEnum(role)));
        if (ExtraRoles != void) {
            for (std.enums.values(ExtraRoles)) |role| tokens.extra_colors.getPtr(state).set(role, colorFor(state, 100 + @as(usize, @intFromEnum(role))));
        }
    }
    for (std.enums.values(design.TypeRole)) |role| tokens.text_styles.set(role, .{ .size = 10 + @as(f32, @floatFromInt(@intFromEnum(role))) });
    for (std.enums.values(design.ShapeRole)) |role| tokens.corner_radii.set(role, .all(@floatFromInt(@intFromEnum(role))));
    return tokens;
}

test "space reads each tier" {
    const tokens = filledTokens(void);
    try testing.expectEqual(@as(f32, 0), tokens.space(.none));
    try testing.expectEqual(@as(f32, 8), tokens.space(.s));
    try testing.expectEqual(@as(f32, 32), tokens.space(.xxl));
}

test "look answers the tokens of the roles a part names, in each state" {
    const tokens = filledTokens(void);
    for (std.enums.values(zui.WidgetState)) |state| {
        const container = tokens.look(Chip, .container, state);
        try testing.expectEqual(colorFor(state, @intFromEnum(design.ColorRole.secondary_container)), container.decoration.background.?);
        try testing.expectEqual(tokens.corner_radii.get(.chip), container.decoration.corner_radius);
        try testing.expectEqual(zui.Edges.symmetric(8, 4), container.padding);
        try testing.expectEqual(@as(f32, 4), container.gap);
        try testing.expect(container.decoration.border == null);

        const label = tokens.look(Chip, .label, state);
        try testing.expect(label.decoration.background == null);
        try testing.expectEqual(tokens.text_styles.get(.label).size, label.text.size);
        try testing.expectEqual(colorFor(state, @intFromEnum(design.ColorRole.on_secondary_container)), label.text.color);
        try testing.expectEqual([2]f32{ 0, 0 }, label.min_size);
    }
}

test "look gives a part its shape role's corner shape with its radius, and a part with no shape role keeps round corners" {
    var tokens = filledTokens(void);
    tokens.corner_shapes.set(.chip, .chamfer);
    tokens.corner_shapes.set(.indicator, .continuous);
    const container = tokens.look(Chip, .container, .idle);
    try testing.expectEqual(zui.CornerShape.chamfer, container.decoration.corner_shape);
    try testing.expectEqual(tokens.corner_radii.get(.chip), container.decoration.corner_radius);
    try testing.expectEqual(zui.CornerShape.round, tokens.look(Chip, .label, .idle).decoration.corner_shape);
}

test "a part's target sets its least size, and draws the focus ring while focused" {
    const tokens = filledTokens(void);
    const idle = tokens.look(Chip, .close, .idle);
    try testing.expectEqual([2]f32{ 44, 44 }, idle.min_size);
    try testing.expectEqual(colorFor(.idle, @intFromEnum(design.ColorRole.on_secondary_container)), idle.text.color);
    try testing.expectEqual(colorFor(.idle, @intFromEnum(design.ColorRole.outline)), idle.decoration.border.?.color);
    try testing.expectEqual(zui.Edges.all(1), idle.decoration.border.?.widths);

    const focused = tokens.look(Chip, .close, .focused);
    try testing.expectEqual(colorFor(.focused, @intFromEnum(design.ColorRole.focus)), focused.decoration.border.?.color);
    try testing.expectEqual(zui.Edges.all(2), focused.decoration.border.?.widths);
}

test "a state's own roles replace the part's in that state alone" {
    const tokens = filledTokens(void);
    try testing.expectEqual(colorFor(.pressed, @intFromEnum(design.ColorRole.accent)), tokens.look(Chip, .container_selected, .pressed).decoration.background.?);
    try testing.expectEqual(colorFor(.hovered, @intFromEnum(design.ColorRole.accent_container)), tokens.look(Chip, .container_selected, .hovered).decoration.background.?);
}

test "a part that draws text pads by the text padding scale" {
    var tokens = filledTokens(Roles);
    tokens.text_padding_scale = 1.5;
    try testing.expectEqual(zui.Edges.symmetric(6, 0), tokens.look(Badge, .count, .idle).padding);
}

test "an unchecked color is drawn as given in every state, and its reason is listed" {
    const tokens = filledTokens(void);
    for (std.enums.values(zui.WidgetState)) |state| {
        try testing.expectEqual(zui.Color.rgb(0xff00ff), tokens.look(Logo, .mark, state).decoration.background.?);
    }
    try testing.expectEqual(zui.Color.rgb(0x808080), tokens.look(Logo, .caption, .disabled).text.color);
    try testing.expectEqual(colorFor(.idle, @intFromEnum(design.ColorRole.on_surface)), tokens.look(Logo, .caption, .idle).text.color);

    const unchecked = Logo.zuiAppearance.unchecked_colors;
    try testing.expectEqual(2, unchecked.len);
    try testing.expectEqual(Logo.Part.mark, unchecked[0].part);
    try testing.expectEqual(null, unchecked[0].state);
    try testing.expectEqualStrings("the brand's logo", unchecked[0].unchecked.reason);
    try testing.expectEqual(Logo.Part.caption, unchecked[1].part);
    try testing.expectEqual(zui.WidgetState.disabled, unchecked[1].state.?);
    try testing.expectEqualStrings("a print proof's grey", unchecked[1].unchecked.reason);
}

test "tokens with extra roles read them, and still read built-in components" {
    const tokens = filledTokens(Roles);
    const body = tokens.look(Badge, .body, .hovered);
    try testing.expectEqual(colorFor(.hovered, 100 + @as(usize, @intFromEnum(Roles.brand))), body.decoration.background.?);
    try testing.expectEqual(tokens.corner_radii.get(.indicator), body.decoration.corner_radius);
    try testing.expectEqual(colorFor(.idle, 100 + @as(usize, @intFromEnum(Roles.on_brand))), tokens.look(Badge, .count, .idle).text.color);
    try testing.expectEqual(colorFor(.idle, @intFromEnum(design.ColorRole.secondary_container)), tokens.look(Chip, .container, .idle).decoration.background.?);
}

test "tokens without extra roles hold no extra colors" {
    try testing.expectEqual(void, design.Tokens(Ui, void).ExtraColorsByRole);
    try testing.expect(@sizeOf(design.Tokens(Ui, Roles)) > @sizeOf(design.Tokens(Ui, void)));
}

test "an extended-color context gets an unchecked color converted" {
    const ExtendedUi = zui.Context(.{ .Text = support.FixedMetricsText, .Color = zui.ExtendedColor });
    const tokens: design.Tokens(ExtendedUi, void) = .{};
    try testing.expectEqual(zui.ExtendedColor.fromColor(.rgb(0xff00ff)), tokens.look(Logo, .mark, .idle).decoration.background.?);
}

test "a design's defaults are the spec's density table and type scale" {
    const harbor: design.Design = .{ .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } } };
    try testing.expectEqual(@as(f32, 12), harbor.density.get(.comfortable).get(.m));
    try testing.expectEqual(@as(f32, 48), harbor.density.get(.roomy).get(.xxl));
    try testing.expectEqual(@as(f32, 1.2), harbor.type.ratio);
    try testing.expectEqual(@as(f32, 15), harbor.type.body_size);
    try testing.expectEqual(design.CornerSize.bubble, harbor.shapes.get(.chip));
    try testing.expectEqual(zui.CornerShape.round, harbor.corner_shape);
}

test "a color choice names its built-in role" {
    const Choice = design.ColorChoice(void);
    try testing.expectEqual(design.ColorRole.scrim, comptime (Choice{ .scrim = {} }).colorRole().?);
    try testing.expectEqual(null, comptime Choice.unchecked(.black, "a test").colorRole());
    inline for (comptime std.meta.fieldNames(design.ColorRole)) |role| try testing.expect(@hasField(Choice, role));
}

test "look takes a part chosen at run time" {
    const tokens = filledTokens(void);
    var selected = false;
    _ = &selected;
    const part: Chip.Part = if (selected) .container_selected else .container;
    try testing.expectEqual(colorFor(.idle, @intFromEnum(design.ColorRole.secondary_container)), tokens.look(Chip, part, .idle).decoration.background.?);
}

test "an icon drawn without a font is counted in the frame's diagnostics, which stay ok" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var ui = harness.begin();
    ui.countMissingIcon();
    ui.countMissingIcon();
    var frame = try harness.end();
    try testing.expectEqual(2, frame.diagnostics.missing_icons);
    try testing.expect(frame.diagnostics.ok());

    ui = harness.begin();
    for (0..300) |_| ui.countMissingIcon();
    frame = try harness.end();
    try testing.expectEqual(255, frame.diagnostics.missing_icons);

    _ = harness.begin();
    frame = try harness.end();
    try testing.expectEqual(0, frame.diagnostics.missing_icons);
}
