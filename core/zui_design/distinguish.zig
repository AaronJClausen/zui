const std = @import("std");
const zui = @import("zui");
const oklab = @import("oklab.zig");
const palette = @import("palette.zig");
const color_vision = @import("color_vision.zig");

const Oklch = zui.design.Oklch;
const WidgetState = zui.WidgetState;
const Deficiency = color_vision.Deficiency;

/// Every scheme's palettes, as `checkComponent` compares parts in.
pub const PalettesBySchemes = std.EnumArray(palette.Scheme, palette.PalettesByState);

/// The colors a part shows in one state: its surface, or the one it is
/// drawn on; its text or icon; and its outline, or its surface where it
/// draws none.
const Drawn = struct {
    surface: ?Oklch,
    foreground: ?Oklch,
    outline: ?Oklch,
};

/// Where an entry of `zuiDistinguish` collapses.
const Collapse = struct {
    scheme: palette.Scheme,
    deficiency: Deficiency,
    lightness_difference: f32,
};

/// Fails the build on each entry of `Component.zuiDistinguish` that is told
/// apart in no color it draws, in some scheme and simulation, and whose
/// parts declare no `cue`. Two parts are compared idle, since a state's
/// layer is feedback on one part at a time; a part in two states, in those.
pub fn checkComponent(comptime design_name: []const u8, comptime Component: type, comptime palettes: PalettesBySchemes) void {
    if (!@hasDecl(Component, "zuiDistinguish")) return;
    const Appearance = Component.zuiAppearance;
    const least = flooredHundredths(color_vision.least_lightness_difference);
    inline for (Component.zuiDistinguish) |entry| {
        const first_part: Component.Part = entry[0];
        if (entry.len == 2) {
            const second_part: Component.Part = entry[1];
            if (hasCue(Appearance.of(first_part)) or hasCue(Appearance.of(second_part))) continue;
            if (collapseOf(Appearance, first_part, .idle, second_part, .idle, palettes)) |collapse| {
                @compileError(std.fmt.comptimePrint("zui_design: under {s}, {s}'s {t} and {t} are {s} apart in lightness under {s} in {s}, need {s}; give one a `.cue` that is not color", .{
                    design_name,                @typeName(Component),   first_part, second_part, flooredHundredths(collapse.lightness_difference),
                    collapse.deficiency.name(), collapse.scheme.name(), least,
                }));
            }
        } else {
            const first_state: WidgetState = entry[1];
            const second_state: WidgetState = entry[2];
            if (hasCue(Appearance.of(first_part))) continue;
            if (collapseOf(Appearance, first_part, first_state, first_part, second_state, palettes)) |collapse| {
                @compileError(std.fmt.comptimePrint("zui_design: under {s}, {s}.{t}'s {t} and {t} layers are {s} apart in lightness under {s} in {s}, need {s}; give it a `.cue` that is not color", .{
                    design_name,                @typeName(Component),   first_part, first_state, second_state, flooredHundredths(collapse.lightness_difference),
                    collapse.deficiency.name(), collapse.scheme.name(), least,
                }));
            }
        }
    }
}

fn hasCue(comptime part: anytype) bool {
    const cue = part.cue orelse return false;
    return cue.len > 0;
}

/// Floored, so a difference just short of the least is not shown as it.
pub fn flooredHundredths(comptime value: f32) []const u8 {
    const whole: u32 = @intFromFloat(@floor(value * 100));
    return std.fmt.comptimePrint("{d}.{d:0>2}", .{ whole / 100, whole % 100 });
}

/// The first scheme and simulation in which no color the two parts draw is
/// `least_lightness_difference` apart.
fn collapseOf(
    comptime Appearance: type,
    comptime first_part: anytype,
    comptime first_state: WidgetState,
    comptime second_part: anytype,
    comptime second_state: WidgetState,
    comptime palettes: PalettesBySchemes,
) ?Collapse {
    for (std.enums.values(palette.Scheme)) |scheme| {
        const shades = palettes.get(scheme);
        const first = drawnOf(Appearance, first_part, first_state, shades);
        const second = drawnOf(Appearance, second_part, second_state, shades);
        var farthest: std.EnumArray(Deficiency, f32) = .initFill(0);
        for (.{ "surface", "foreground", "outline" }) |channel| {
            if (@field(first, channel) != null and @field(second, channel) != null) {
                const differences = color_vision.lightnessDifferences(@field(first, channel).?, @field(second, channel).?);
                for (std.enums.values(Deficiency)) |deficiency| farthest.set(deficiency, @max(farthest.get(deficiency), differences.get(deficiency)));
            }
        }
        for (std.enums.values(Deficiency)) |deficiency| {
            if (farthest.get(deficiency) < color_vision.least_lightness_difference) {
                return .{ .scheme = scheme, .deficiency = deficiency, .lightness_difference = farthest.get(deficiency) };
            }
        }
    }
    return null;
}

fn drawnOf(comptime Appearance: type, comptime part: anytype, comptime state: WidgetState, comptime shades: palette.PalettesByState) Drawn {
    const declared = Appearance.of(part);
    const colors = declared.colorsIn(state);
    const beneath: ?Oklch = if (declared.on) |on| beneath: {
        const surface = Appearance.of(@field(Appearance.Part, @tagName(on))).colorsIn(state).surface orelse break :beneath null;
        break :beneath shadeOf(Appearance.ExtraRoles, surface, state, shades);
    } else null;
    const surface = if (colors.surface) |own| shadeOf(Appearance.ExtraRoles, own, state, shades) else beneath;
    const foreground_choice = colors.text orelse colors.icon;
    return .{
        .surface = surface,
        .foreground = if (foreground_choice) |choice| shadeOf(Appearance.ExtraRoles, choice, state, shades) else null,
        .outline = if (colors.outline) |outline| shadeOf(Appearance.ExtraRoles, outline, state, shades) else surface,
    };
}

fn shadeOf(comptime ExtraRoles: type, comptime choice: anytype, comptime state: WidgetState, comptime shades: palette.PalettesByState) Oklch {
    if (choice.colorRole()) |role| return shades.get(state).get(role).color;
    return switch (choice) {
        .extra_role => |role| shades.get(state).get(palette.builtInRoleOf(ExtraRoles, role)).color,
        .unchecked_color => |unchecked| oklab.oklchOfColor(unchecked.color),
        else => unreachable,
    };
}
