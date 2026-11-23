const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");

const testing = std.testing;
const design = zui.design;

/// Each character `size / 2` wide plus its spacing, and `size` tall.
const HalfEmText = struct {
    pub fn zuiMeasure(_: *HalfEmText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

const Ui = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_text_bytes = 512, .max_render_commands = 64 },
    .Text = HalfEmText,
    .features = .{ .safety_sweeps = true },
});

const harbor: design.Design = .{
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
};

const Plain = struct {};

const Label = struct {
    pub const Content = struct { text: []const u8 };

    pub const zuiPreviews = .{
        .short = Content{ .text = "Save" },
        .long = Content{ .text = "Save every change to every open document" },
        .empty = Content{ .text = "" },
    };
};

/// Draws its swatch in `danger` only while pressed, so a change of `danger`
/// reaches only the pressed permutations.
const Swatch = struct {
    pub const Part = enum { swatch, label };

    pub const zuiAppearance = design.Appearance(Part, .{
        .swatch = .{ .surface = .accent_container, .shape = .control, .padding = .{ .x = .s, .y = .xs }, .states = .{ .pressed = .{ .surface = .danger } } },
        .label = .{ .text = .on_accent_container, .type = .label, .on = .swatch },
    });

    pub const zuiPreviews = .{
        .short = Label.Content{ .text = "Go" },
        .long = Label.Content{ .text = "Go on to the next permutation" },
    };
};

fn expectEveryPairCovered(comptime Component: type) !void {
    const Pairs = zui_design.Permutations(Component, .pairs);
    const axes = std.enums.values(zui_design.Axis);
    for (axes, 0..) |first, first_index| {
        for (axes[first_index + 1 ..]) |second| {
            for (0..zui_design.valueCount(first, Pairs.preview_count)) |first_value| {
                for (0..zui_design.valueCount(second, Pairs.preview_count)) |second_value| {
                    const found = for (0..Pairs.count) |index| {
                        const permutation = Pairs.at(index);
                        if (zui_design.valueIndex(permutation, first) == first_value and zui_design.valueIndex(permutation, second) == second_value) break true;
                    } else false;
                    if (!found) {
                        std.debug.print("{t}={d} and {t}={d} are in no permutation\n", .{ first, first_value, second, second_value });
                        return error.PairNotCovered;
                    }
                }
            }
        }
    }
}

test "every pair of two axes' values is in some permutation of pairs, at a size between the largest pair of axes and full" {
    try expectEveryPairCovered(Plain);
    try expectEveryPairCovered(Label);
    try expectEveryPairCovered(Swatch);
    try testing.expectEqual(27, zui_design.Permutations(Plain, .pairs).count);
    try testing.expectEqual(28, zui_design.Permutations(Label, .pairs).count);
    try testing.expectEqual(27, zui_design.Permutations(Swatch, .pairs).count);
    try testing.expect(zui_design.Permutations(Plain, .pairs).count >= 5 * 5);
}

test "glance shows the defaults and the extremes, and each further preview at both" {
    const Glance = zui_design.Permutations(Plain, .glance);
    try testing.expectEqual(5, Glance.count);
    try testing.expectEqual(zui_design.Permutation{}, Glance.at(0));
    const extremes = Glance.at(4).axes;
    try testing.expectEqual(.dark, extremes.theme);
    try testing.expectEqual(.high, extremes.contrast);
    try testing.expectEqual(.@"200%", extremes.text_scale);
    try testing.expectEqual(.compact, extremes.density);
    try testing.expectEqual(.right_to_left, extremes.direction);

    const LabelGlance = zui_design.Permutations(Label, .glance);
    try testing.expectEqual(9, LabelGlance.count);
    try testing.expectEqualStrings("empty", LabelGlance.previewName(LabelGlance.at(8)));
    try testing.expectEqual(extremes, LabelGlance.at(8).axes);
    try testing.expectEqualStrings("", LabelGlance.preview(LabelGlance.at(8)).text);
}

test "sweep moves one axis at a time from the defaults" {
    const Sweep = zui_design.Permutations(Label, .sweep);
    try testing.expectEqual(1 + 1 + 1 + 2 + 2 + 4 + 1 + 2 + 1 + 4 + 2, Sweep.count);
    try testing.expectEqual(zui_design.Permutation{}, Sweep.at(0));
    for (1..Sweep.count) |index| {
        var moved: usize = 0;
        for (std.enums.values(zui_design.Axis)) |axis| moved += @intFromBool(zui_design.valueIndex(Sweep.at(index), axis) != zui_design.valueIndex(.{}, axis));
        try testing.expectEqual(1, moved);
    }
}

test "full is every combination, decoded by index" {
    const Full = zui_design.Permutations(Label, .full);
    try testing.expectEqual(2 * 2 * 3 * 3 * 5 * 2 * 3 * 2 * 5 * 3, Full.count);
    try testing.expectEqual(zui_design.Permutation{ .axes = .{ .density = .compact, .corners = .sharper } }, Full.at(0));
    const last = Full.at(Full.count - 1);
    try testing.expectEqual(.dark, last.axes.theme);
    try testing.expectEqual(.achromat, last.axes.color_vision);
    try testing.expectEqual(.disabled, last.axes.state);
    try testing.expectEqual(2, last.preview);
    try testing.expect(!std.meta.eql(Full.at(1), Full.at(2)));
}

test "a key formats and parses back, and a malformed one is refused" {
    const Glance = zui_design.Permutations(Label, .glance);
    const key = Glance.key(Glance.at(8));
    var buffer: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{key});
    try testing.expectEqualStrings("permutations_tests.Label/empty/theme=dark,contrast=high,density=compact,text_scale=200%,color_vision=typical,direction=right_to_left,corners=as_designed,reduced_transparency=false,state=idle", text);
    const parsed: zui_design.PermutationKey = try .parse(text);
    try testing.expect(parsed.eql(key));

    try testing.expectError(error.MalformedKey, zui_design.PermutationKey.parse("Label/empty"));
    try testing.expectError(error.UnknownAxis, zui_design.PermutationKey.parse("Label/empty/hue=red"));
    try testing.expectError(error.UnknownValue, zui_design.PermutationKey.parse("Label/empty/theme=sepia"));
    try testing.expectError(error.RepeatedAxis, zui_design.PermutationKey.parse("Label/empty/theme=dark,theme=light"));
    try testing.expectError(error.MissingAxis, zui_design.PermutationKey.parse("Label/empty/theme=dark"));
}

test "axes become preferences and the environment changes that set them" {
    const axes: zui_design.Axes = .{ .theme = .dark, .text_scale = .@"150%", .density = .roomy, .color_vision = .deutan, .corners = .rounder, .reduced_transparency = true, .direction = .right_to_left };
    const preferences = axes.preferences(.{ .pointer = .touch, .accent = .rgb(0xff8800) });
    try testing.expectEqual(zui_design.Preferences{
        .theme = .dark,
        .text_scale = 1.5,
        .reduced_transparency = true,
        .accent = .rgb(0xff8800),
        .density = .roomy,
        .color_vision = .deutan,
        .corners = .rounder,
        .pointer = .touch,
    }, preferences);
    const changes = axes.environmentChanges();
    try testing.expectEqual(zui.EnvironmentChange{ .direction = .right_to_left }, changes[4]);
    try testing.expectEqual(zui.EnvironmentChange{ .text_scale = 1.5 }, changes[2]);
}

fn declareSwatch(ui: *Ui, tokens: *const design.Tokens(Ui, void), permutation: zui_design.Permutation) void {
    const swatch = tokens.look(Swatch, .swatch, permutation.axes.state);
    const label = tokens.look(Swatch, .label, permutation.axes.state);
    ui.open(.{ .id = .of("swatch"), .decoration = swatch.decoration, .layout = .{ .padding = swatch.padding } });
    ui.text(zui_design.Permutations(Swatch, .sweep).preview(permutation).text, label.text);
    ui.close();
}

fn hashOfPermutation(ui: *Ui, tokens: *const design.Tokens(Ui, void), permutation: zui_design.Permutation) u64 {
    var events: [zui_design.Axes.environment_change_count]zui.Event = undefined;
    for (permutation.axes.environmentChanges(), &events) |change, *event| event.* = .{ .environment = change };
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 400, 200 } }, .events = &events });
    declareSwatch(ui, tokens, permutation);
    const frame = ui.endFrame();
    defer ui.release(frame);
    return zui_design.hashCommands(frame.commands());
}

test "a change of one color moves only the hashes of the permutations that draw it" {
    var text: HalfEmText = .{};
    var ui: Ui = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    const Sweep = zui_design.Permutations(Swatch, .sweep);
    var pressed_permutations: usize = 0;
    for (0..Sweep.count) |index| {
        const permutation = Sweep.at(index);
        var tokens: design.Tokens(Ui, void) = .{};
        _ = zui_design.resolve(harbor, permutation.axes.preferences(.{}), &tokens);
        const before = hashOfPermutation(&ui, &tokens, permutation);
        try testing.expectEqual(before, hashOfPermutation(&ui, &tokens, permutation));
        for (std.enums.values(zui.WidgetState)) |state| tokens.colors.getPtr(state).set(.danger, .rgb(0x123456));
        const after = hashOfPermutation(&ui, &tokens, permutation);
        const draws_danger = permutation.axes.state == .pressed;
        pressed_permutations += @intFromBool(draws_danger);
        try testing.expectEqual(draws_danger, before != after);
    }
    try testing.expectEqual(1, pressed_permutations);
}

/// The commands of `declareFixed`, as every target must hash them.
const fixed_declaration_hash: u64 = 1356389077080039845;

fn declareFixed(ui: *Ui) void {
    ui.open(.{ .id = .of("card"), .clip = .both, .layout = .{ .padding = .all(8), .child_gap = 4, .direction = .top_to_bottom }, .decoration = .{ .background = .rgb(0x223344), .border = .{ .color = .rgba(0xffffff80), .widths = .all(1) }, .corner_radius = .all(6) } });
    ui.text("Harbor", .{ .size = 18, .color = .rgb(0xf0f0f0), .letter_spacing = -0.25, .line_height = 24 });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(40.5), .height = .fixed(3) } }, .decoration = .{ .background = .rgb(0x5b8cff) } });
    ui.close();
}

test "a fixed declaration hashes the same in every mode and on every target" {
    var text: HalfEmText = .{};
    var ui: Ui = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 320, 200 } } });
    declareFixed(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(fixed_declaration_hash, zui_design.hashCommands(frame.commands()));
}

test "negative zero and every NaN hash as zero and one NaN, and a changed field changes the hash" {
    const Command = Ui.RenderCommand;
    const rectangle: Command = comptime .{ .bounds = .{ .x = 0, .y = 1, .width = 10, .height = 4 }, .id = 7, .payload = .{ .rectangle = .{ .color = .rgb(0x102030), .corner_radius = .zero } } };
    var negative_zero = rectangle;
    negative_zero.bounds.x = -0.0;
    try testing.expectEqual(zui_design.hashCommands(&[_]Command{rectangle}), zui_design.hashCommands(&[_]Command{negative_zero}));
    var quiet_nan = rectangle;
    quiet_nan.bounds.width = std.math.nan(f32);
    var other_nan = rectangle;
    other_nan.bounds.width = @bitCast(@as(u32, 0x7fc00123));
    try testing.expectEqual(zui_design.hashCommands(&[_]Command{quiet_nan}), zui_design.hashCommands(&[_]Command{other_nan}));
    var recolored = rectangle;
    recolored.payload.rectangle.color.b += 1;
    try testing.expect(zui_design.hashCommands(&[_]Command{rectangle}) != zui_design.hashCommands(&[_]Command{recolored}));
    const at_comptime = comptime zui_design.hashCommands(&[_]Command{rectangle});
    try testing.expectEqual(at_comptime, zui_design.hashCommands(&[_]Command{rectangle}));
}
