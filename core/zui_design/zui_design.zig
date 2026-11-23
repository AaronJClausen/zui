//! The default maker of `zui.design.Tokens`: the user's preferences, from
//! the environment and their choices in the application, resolved against
//! a `zui.design.Design` when one of them changes, never during a frame.
//!
//! ```zig
//! const preferences: zui_design.Preferences = .from(ui.environment(), app.choices);
//! if (!std.meta.eql(preferences, app.preferences)) {
//!     app.preferences = preferences;
//!     _ = zui_design.resolve(app.design, preferences, &app.tokens);
//! }
//! ```

const std = @import("std");
const zui = @import("zui");
const palette = @import("palette.zig");
const contrast = @import("contrast.zig");
const repairs_file = @import("repairs.zig");
const color_vision = @import("color_vision.zig");
const distinguish = @import("distinguish.zig");
const audit_file = @import("audit.zig");
const permutations_file = @import("permutations.zig");
const default_file = @import("default.zig");
const elevation = @import("elevation.zig");

const design = zui.design;
const Design = design.Design;
const CornerSize = design.CornerSize;
const Density = design.Density;
const ControlSize = design.ControlSize;
const Target = design.Target;
const TypeRole = design.TypeRole;

/// zui's own design, which a design language or an application starts
/// from.
pub const default = default_file.default;

/// The color vision the status roles are adapted for: `protan` and
/// `deutan` move danger toward orange and success to azure; `tritan` and
/// `achromat` hold them further apart in lightness.
pub const ColorVision = color_vision.ColorVision;

/// Every shape role one `CornerSize` sharper or rounder than its design
/// gives it; `square` and `bubble` go no further.
pub const CornerPreference = enum { sharper, as_designed, rounder };

/// What the user chose in the application, which no OS reports.
pub const Choices = struct {
    density: Density = .comfortable,
    color_vision: ColorVision = .typical,
    corners: CornerPreference = .as_designed,
    pointer: Target = .pointer,
    /// Replaces the design's accent seed's hue and chroma, and overrides
    /// the system's accent.
    accent: ?zui.Color = null,
};

/// Everything a resolve reads besides the design. Two are equal when
/// `std.meta.eql` says so, which is when the tokens need resolving again.
pub const Preferences = struct {
    theme: zui.Environment.Theme = .light,
    contrast: zui.Environment.Contrast = .normal,
    /// What text is multiplied by, 1 at the user's normal size.
    text_scale: f32 = 1,
    reduced_transparency: bool = false,
    /// The user's accent, which replaces the design's seed's hue and chroma.
    accent: ?zui.Color = null,
    density: Density = .comfortable,
    color_vision: ColorVision = .typical,
    corners: CornerPreference = .as_designed,
    /// `.touch` raises every target floor to a finger's.
    pointer: Target = .pointer,

    /// The environment's theme, contrast, text scale, transparency and
    /// accent, with the user's `choices`. An accent in `choices` wins over
    /// the system's.
    ///
    /// ```zig
    /// const preferences: zui_design.Preferences = .from(ui.environment(), .{ .density = .compact });
    /// ```
    pub fn from(environment: *const zui.Environment, choices: Choices) Preferences {
        return .{
            .theme = environment.theme,
            .contrast = environment.contrast,
            .text_scale = environment.text_scale,
            .reduced_transparency = environment.reduced_transparency,
            .accent = choices.accent orelse environment.accent,
            .density = choices.density,
            .color_vision = choices.color_vision,
            .corners = choices.corners,
            .pointer = choices.pointer,
        };
    }
};

/// What a resolve changed from its design to meet a target.
pub const Repairs = repairs_file.Repairs;
/// One pair a resolve moved, with its contrast before and the lightness
/// it took.
pub const Repair = repairs_file.Repair;

/// Writes every field of `tokens`, a `*zui.design.Tokens(Ui, ExtraRoles)`,
/// from `resolved_design` under `preferences`, allocating nothing. It runs
/// at comptime too, which checks a static design during the build.
///
/// Each seed is a tonal ramp of its hue and chroma, and each role a
/// lightness on one, per theme and contrast; the seed's own lightness is
/// not read. An extra role is colored as the built-in role
/// `builtInRoleOf` names.
///
/// Every pair of `checked_pairs` is moved in lightness until it meets its
/// target in APCA and WCAG 2, then each pair of status fills is moved
/// apart until they differ in lightness under every simulated color
/// vision, and the returned `Repairs` lists each move.
/// At comptime a move the design's own seeds need is a compile error that
/// names the lightness that passes; one a chosen accent or a chosen color
/// vision needs is repaired.
///
/// Each `Elevation` is one shadow, the `shadow` role at the level's alpha,
/// and a rim in the `rim` role, from `elevation_levels`.
///
/// Spacing is the design's density table at `preferences.density`, and a
/// part that draws text pads by its tiers times half of `text_scale` past
/// 1 added to 1. No density lowers the target floors, `pointer_floor` and
/// `touch_floor`, or narrows `focus_ring_width`. Control heights and icon
/// sizes are `control_heights` and `icon_sizes` at the density.
///
/// Each type role is a step of the design's modular scale from body text,
/// sized in each font whose face the design gives so its x-height is the
/// design's (`bodySizeIn`), and multiplied by `text_scale` to a power of 1
/// up to `body`, falling to 0.5 at `display`. Its line height is
/// `lineHeightFor` and its letter spacing `trackingFor` its size. The
/// measure is 66 characters of half the body size.
///
/// ```zig
/// var tokens: zui.design.Tokens(Ui, void) = .{};
/// _ = zui_design.resolve(app.design, .from(ui.environment(), app.choices), &tokens);
///
/// const dark_tokens = comptime dark: {
///     var resolved: zui.design.Tokens(Ui, void) = .{};
///     _ = zui_design.resolve(app.design, .{ .theme = .dark }, &resolved);
///     break :dark resolved;
/// };
/// ```
pub fn resolve(resolved_design: Design, preferences: Preferences, tokens: anytype) Repairs {
    @setEvalBranchQuota(2_000_000);
    var repairs: Repairs = .{};
    const palettes = palettesFor(resolved_design.seeds, preferences, &repairs);
    writeColors(palettes, tokens);
    elevation.write(palettes.get(.idle), .of(preferences.theme, preferences.contrast), tokens);
    if (@inComptime()) failOnRepairsTheDesignNeeds(resolved_design, preferences, &repairs);
    tokens.spacing = resolved_design.density.get(preferences.density);
    tokens.text_padding_scale = 1 + (preferences.text_scale - 1) / 2;
    writeTextStyles(resolved_design.type, preferences.text_scale, tokens);
    for (std.enums.values(design.ShapeRole)) |role| {
        const size = cornerSizeFor(resolved_design.shapes.get(role), preferences.corners);
        tokens.corner_radii.set(role, .all(cornerRadiusOf(size, preferences.density)));
        tokens.corner_shapes.set(role, resolved_design.corner_shape);
    }
    tokens.target_floors = targetFloorsFor(preferences.pointer);
    for (std.enums.values(ControlSize)) |size| {
        const height = control_heights.get(size).get(preferences.density);
        tokens.control_heights.set(size, if (preferences.pointer == .touch) @max(height, touch_floor) else height);
        tokens.icon_sizes.set(size, icon_sizes.get(size).get(preferences.density));
    }
    tokens.outline_width = outline_width;
    tokens.focus_ring_width = focus_ring_width;
    tokens.focus_ring_offset = focus_ring_offset;
    tokens.measure = measure_characters * average_character_width * tokens.text_styles.get(.body).size;
    return repairs;
}

fn failOnRepairsTheDesignNeeds(resolved_design: Design, preferences: Preferences, repairs: *const Repairs) void {
    for (repairs.slice()) |repair| {
        const moves_chosen_accent = preferences.accent != null and
            (palette.rampOf(repair.foreground, repair.scheme) == .accent or palette.rampOf(repair.background, repair.scheme) == .accent);
        const adapts_to_chosen_color_vision = repair.kind != .contrast and preferences.color_vision != .typical;
        if (moves_chosen_accent or adapts_to_chosen_color_vision) continue;
        @compileError(switch (repair.kind) {
            .contrast => repairMessage(resolved_design.name, repair),
            .color_vision, .needs_non_color_cue => separationMessage(resolved_design.name, repair),
        });
    }
}

/// "zui_design: demo.design's danger and success are 0.08 apart in
/// lightness under deuteranopia in light, need 0.15; success at L 0.61
/// passes"
fn separationMessage(comptime design_name: []const u8, comptime repair: Repair) []const u8 {
    const fmt = std.fmt.comptimePrint;
    const nearest = repair.nearest.?;
    const measured = fmt("zui_design: {s}'s {t} and {t} are {s} apart in lightness under {s} in {s}, need {s}", .{
        design_name,               repair.foreground,    repair.background,                                                      distinguish.flooredHundredths(nearest.lightness_difference),
        nearest.deficiency.name(), repair.scheme.name(), distinguish.flooredHundredths(color_vision.least_lightness_difference),
    });
    if (repair.kind == .needs_non_color_cue) return measured ++ "; no lightness of either keeps its contrast, so they need a cue that is not color";
    const moved_role, const move = if (repair.foreground_moved) |move| .{ repair.foreground, move } else .{ repair.background, repair.background_moved.? };
    return fmt("{s}; {t} at L {s} passes", .{ measured, moved_role, hundredthsPast(move) });
}

/// "zui_design: demo.design's on_danger on danger is Lc 73 in light, needs
/// 75; on_danger at L 1.00 passes"
fn repairMessage(comptime design_name: []const u8, comptime repair: Repair) []const u8 {
    const fmt = std.fmt.comptimePrint;
    const lightness_contrast: u32 = @intFromFloat(@floor(@abs(repair.before.lightness_contrast)));
    const needed_lightness_contrast: u32 = @intFromFloat(repair.target.lightness_contrast);
    const measured = if (lightness_contrast < needed_lightness_contrast)
        fmt("Lc {d} in {s}, needs {d}", .{ lightness_contrast, repair.scheme.name(), needed_lightness_contrast })
    else
        fmt("{s}:1 in {s}, needs {s}:1", .{ tenths(@floor(repair.before.ratio * 10)), repair.scheme.name(), tenths(repair.target.ratio * 10) });
    const foreground = @tagName(repair.foreground);
    const background = @tagName(repair.background);
    const passing = if (repair.background_moved) |background_moved|
        fmt("{s} at L {s} and {s} at L {s} pass", .{ foreground, hundredthsPast(repair.foreground_moved.?), background, hundredthsPast(background_moved) })
    else
        fmt("{s} at L {s} passes", .{ foreground, hundredthsPast(repair.foreground_moved.?) });
    return fmt("zui_design: {s}'s {s} on {s} is {s}; {s}", .{ design_name, foreground, background, measured, passing });
}

fn tenths(comptime value_in_tenths: f32) []const u8 {
    const whole: u32 = @intFromFloat(@round(value_in_tenths));
    return std.fmt.comptimePrint("{d}.{d}", .{ whole / 10, whole % 10 });
}

/// Rounded on in the direction of the move, so the lightness written passes
/// too.
fn hundredthsPast(comptime move: repairs_file.LightnessMove) []const u8 {
    const lightness_in_hundredths = move.to * 100;
    const whole: u32 = @intFromFloat(if (move.to > move.from) @ceil(lightness_in_hundredths) else @floor(lightness_in_hundredths));
    return std.fmt.comptimePrint("{d}.{d:0>2}", .{ whole / 100, whole % 100 });
}

/// A radius larger than any element, so emission's clamp to half the
/// shorter side makes a pill.
pub const bubble_radius: f32 = 1 << 16;

/// The width of an outline that shows a part's edge or state.
pub const outline_width: f32 = 1;
/// The width of the focus ring, which no density narrows.
pub const focus_ring_width: f32 = 2;
/// The gap between a part's edge and its focus ring, so the ring shows on
/// a fill of any color.
pub const focus_ring_offset: f32 = 2;

pub const ByControlSize = std.EnumArray(ControlSize, std.EnumArray(Density, f32));

/// A control's height at each size and density; under
/// `Preferences.pointer = .touch` none is below `touch_floor`.
pub const control_heights: ByControlSize = .init(.{
    .small = .init(.{ .compact = 24, .comfortable = 28, .roomy = 32 }),
    .medium = .init(.{ .compact = 28, .comfortable = 36, .roomy = 44 }),
    .large = .init(.{ .compact = 36, .comfortable = 44, .roomy = 52 }),
});

/// The side of a control's icon at each size and density.
pub const icon_sizes: ByControlSize = .init(.{
    .small = .init(.{ .compact = 12, .comfortable = 16, .roomy = 16 }),
    .medium = .init(.{ .compact = 16, .comfortable = 20, .roomy = 24 }),
    .large = .init(.{ .compact = 20, .comfortable = 24, .roomy = 28 }),
});

/// Each elevation's shadow and rim in each scheme.
pub const elevation_levels = elevation.levels;
/// One elevation's shadow and rim in one scheme.
pub const ElevationLevel = elevation.Level;

/// A part a pointer hits is at least this wide and tall, whatever the
/// density.
pub const pointer_floor: f32 = 24;
/// A part a finger hits, or any part a pointer hits under
/// `Preferences.pointer = .touch`, is at least this wide and tall.
pub const touch_floor: f32 = 44;

/// `size` moved one step by `preference`.
pub fn cornerSizeFor(size: CornerSize, preference: CornerPreference) CornerSize {
    const sizes = std.enums.values(CornerSize);
    const index = @intFromEnum(size);
    return switch (preference) {
        .as_designed => size,
        .sharper => sizes[index -| 1],
        .rounder => sizes[@min(index + 1, sizes.len - 1)],
    };
}

/// The radius of each corner of a shape role at `size`.
pub fn cornerRadiusOf(size: CornerSize, density: Density) f32 {
    return switch (size) {
        .square => 0,
        .sharp => if (density == .compact) 2 else 4,
        .smooth => 8,
        .soft => 16,
        .bubble => bubble_radius,
    };
}

/// A resolved color in OKLCH with its alpha.
pub const Shade = palette.Shade;
/// A `Shade` for each built-in role.
pub const Palette = palette.Palette;
/// The built-in role an extra role is colored as, from its `zuiPairs`.
pub const builtInRoleOf = palette.builtInRoleOf;
/// The role each built-in role is checked against.
pub const partnerOf = palette.partnerOf;

/// Every built-in role's color in every state, before it is encoded in a
/// context's color type, with each checked pair's contrast solved and the
/// status fills held apart for color vision in the idle palette, so the
/// state layers derive from solved colors.
pub fn palettesFor(seeds: Design.Seeds, preferences: Preferences, repairs: *Repairs) palette.PalettesByState {
    const ramps = palette.rampSeeds(seedsFor(seeds, preferences.color_vision), preferences.accent);
    const scheme: palette.Scheme = .of(preferences.theme, preferences.contrast);
    var idle = palette.idlePalette(ramps, scheme, preferences.reduced_transparency, preferences.accent);
    contrast.solve(&idle, scheme, repairs);
    color_vision.separateStatusRoles(&idle, scheme, color_vision.leastStatusDifferenceFor(preferences.color_vision), repairs);
    return palette.stateLayers(idle, contrast.layerShares(idle, scheme));
}

/// `seeds` with the status hues `color_vision` replaces them with.
fn seedsFor(seeds: Design.Seeds, chosen_color_vision: ColorVision) Design.Seeds {
    const hues = color_vision.statusHuesFor(chosen_color_vision) orelse return seeds;
    var adapted = seeds;
    adapted.danger_hue = hues.danger;
    adapted.warning_hue = hues.warning;
    adapted.success_hue = hues.success;
    return adapted;
}

/// Fails the build on each entry of a component's `zuiDistinguish` that
/// `resolved_design`, in any scheme, does not show apart under every
/// simulated color vision, by at least `least_lightness_difference` in
/// OKLab lightness in some color the two draw, when neither part declares
/// a `cue` that is not color. The roles are shared by every component, so
/// a pair is checked, not moved. Two parts are compared idle, since a
/// state's layer is feedback on one part at a time; a part in two states,
/// in those two.
///
/// ```zig
/// comptime zui_design.checkDistinguished(app.design, .{ Checkbox, Tab, StatusBadge });
/// ```
pub fn checkDistinguished(comptime resolved_design: Design, comptime components: anytype) void {
    comptime {
        @setEvalBranchQuota(20_000_000);
        var palettes: distinguish.PalettesBySchemes = undefined;
        for (std.enums.values(Scheme)) |scheme| {
            var ignored: Repairs = .{};
            const theme: zui.Environment.Theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark;
            palettes.set(scheme, palettesFor(resolved_design.seeds, .{ .theme = theme, .contrast = scheme.environmentContrast() }, &ignored));
        }
        for (components) |Component| distinguish.checkComponent(resolved_design.name, Component, palettes);
    }
}

/// Checks a finished frame: text and focus ring contrast against what is
/// painted beneath, target sizes, text cut short and overlapping controls.
pub const audit = audit_file.audit;
/// Checks each component's `zuiDistinguish` pairs in a resolve's tokens.
pub const auditDistinguished = audit_file.auditDistinguished;
/// What the audit checks.
pub const AuditCheck = audit_file.Check;
/// What the audit holds a frame to.
pub const AuditOptions = audit_file.Options;
/// One thing the audit found, naming its element, check and value.
pub const Finding = audit_file.Finding;
/// What a finding measured, by its check.
pub const Measured = audit_file.Measured;
/// The findings an audit kept in its caller's room, and those it dropped.
pub const Findings = audit_file.Findings;

/// One value of every axis a component is seen under but its content.
pub const Axes = permutations_file.Axes;
/// An axis of `Axes`, or the component's preview.
pub const Axis = permutations_file.Axis;
/// The text scales a component is seen at.
pub const TextScale = permutations_file.TextScale;
/// One way a component is seen: its axes and its preview.
pub const Permutation = permutations_file.Permutation;
/// How many permutations a review steps through.
pub const Level = permutations_file.Level;
/// Every permutation of a component at a level.
pub const Permutations = permutations_file.Permutations;
/// A permutation's name from one build to the next, which formats and
/// parses.
pub const PermutationKey = permutations_file.PermutationKey;
/// A hash of a frame's commands, the same in every mode and on every target.
pub const hashCommands = permutations_file.hashCommands;
/// The values an axis has, for a component with that many previews.
pub const valueCount = permutations_file.valueCount;
/// The index of a permutation's value of an axis.
pub const valueIndex = permutations_file.valueIndex;

/// A dichromacy at full severity, or achromatopsia, as a color is
/// simulated for it.
pub const Deficiency = color_vision.Deficiency;
/// A linear sRGB color as seen with a `Deficiency`, by Machado et al.'s
/// matrices at full severity.
pub const simulatedLinear = color_vision.simulatedLinear;
/// A color's OKLab lightness as seen with a `Deficiency`.
pub const simulatedLightness = color_vision.simulatedLightness;
/// An encoded color's OKLab lightness as seen with a `Deficiency`.
pub const simulatedLightnessOfColor = color_vision.simulatedLightnessOfColor;
/// Two encoded colors' nearest approach in lightness over every simulation.
pub const nearestOfColors = color_vision.nearestOfColors;
/// Two OKLCH colors' nearest approach in lightness over every simulation.
pub const nearestUnderSimulation = color_vision.nearestUnderSimulation;
/// Where two colors are nearest in lightness, and by how much.
pub const Nearest = color_vision.Nearest;
/// How far apart in lightness two colors are told apart without hue.
pub const least_lightness_difference = color_vision.least_lightness_difference;
/// The status roles' hues for a chosen color vision.
pub const statusHuesFor = color_vision.statusHuesFor;

/// A `Palette` for each state's layer.
pub const PalettesByState = palette.PalettesByState;
/// The theme and contrast a palette is resolved for.
pub const Scheme = palette.Scheme;
/// The measures of a pair's contrast, APCA's Lc and WCAG 2's ratio.
pub const Contrast = contrast.Contrast;
/// The least `Contrast` a pair needs.
pub const ContrastTarget = contrast.Target;
/// The tier of a foreground role, which sets its `ContrastTarget`.
pub const tierOf = contrast.tierOf;
/// Every foreground role and the background it is checked on.
pub const checked_pairs = contrast.checked_pairs;
/// The lightness at which a pair meets a target, moving one of its colors.
pub const passingLightness = contrast.passingLightness;

fn writeColors(palettes: palette.PalettesByState, tokens: anytype) void {
    const Color = @TypeOf(tokens.colors).Value.Value;
    for (std.enums.values(zui.WidgetState)) |state| {
        const shades = palettes.getPtrConst(state);
        const colors = tokens.colors.getPtr(state);
        for (std.enums.values(design.ColorRole)) |role| colors.set(role, shades.get(role).encoded(Color));
    }
    if (@TypeOf(tokens.extra_colors) == void) return;
    const ExtraRoles = @TypeOf(tokens.extra_colors).Value.Key;
    for (std.enums.values(zui.WidgetState)) |state| {
        const colors = tokens.colors.getPtrConst(state);
        const extra_colors = tokens.extra_colors.getPtr(state);
        inline for (comptime std.enums.values(ExtraRoles)) |role| {
            extra_colors.set(role, colors.get(comptime builtInRoleOf(ExtraRoles, role)));
        }
    }
}

fn targetFloorsFor(pointer: Target) std.EnumArray(Target, f32) {
    return .init(.{
        .none = 0,
        .pointer = if (pointer == .touch) touch_floor else pointer_floor,
        .touch = touch_floor,
    });
}

/// The body text's measure is this many average characters, each taken
/// as half the body size wide, a figure close to running text's mean
/// advance in most text faces.
const measure_characters = 66;
const average_character_width = 0.5;

/// Each role's step of the modular scale.
fn scaleStepOf(role: TypeRole) f32 {
    return switch (role) {
        .caption => -2,
        .label, .label_strong => -1,
        .body, .body_strong, .code, .numeric => 0,
        .title => 1,
        .headline => 2,
        .display => 4,
    };
}

/// `text_scale` reaches `caption` to `body` fully and `display` by its
/// square root, so headings do not outgrow the screen.
fn textScalePowerOf(role: TypeRole) f32 {
    const highest_step = scaleStepOf(.display);
    return 1 - 0.5 * @max(0, scaleStepOf(role)) / highest_step;
}

/// The size body text takes in `face`, so its x-height is the scale's; in
/// a face not given, `body_size`.
pub fn bodySizeIn(scale: Design.TypeScale, face: ?design.FaceMetrics) f32 {
    const x_height_per_size = if (face) |given| given.xHeightPerSize() else 0;
    return if (x_height_per_size > 0) scale.x_height / x_height_per_size else scale.body_size;
}

/// Every line is a whole number of these tall.
pub const line_grid: f32 = 4;

/// A line of text of `size`: 1.5 times it at 14 and below, falling in
/// proportion to 1.15 times it at 40 and above, rounded to `line_grid`.
pub fn lineHeightFor(size: f32) f32 {
    const leading = interpolated(size, .{ 14, 1.5 }, .{ 40, 1.15 });
    return @max(line_grid, @round(size * leading / line_grid) * line_grid);
}

/// The letter spacing of text of `size`: +1% of it at 12 and below, none
/// at 16, and −2% at 32 and above, in proportion between.
pub fn trackingFor(size: f32) f32 {
    const share = if (size <= 16)
        interpolated(size, .{ 12, 0.01 }, .{ 16, 0 })
    else
        interpolated(size, .{ 16, 0 }, .{ 32, -0.02 });
    return size * share;
}

/// The value at `at`, in proportion between two points and held beyond them.
fn interpolated(at: f32, from: [2]f32, to: [2]f32) f32 {
    const progress = std.math.clamp((at - from[0]) / (to[0] - from[0]), 0, 1);
    return from[1] + (to[1] - from[1]) * progress;
}

const FontSlot = enum { regular, strong, monospace };

/// Labels that lead and headings from `title` up are set in the strong font.
fn fontSlotOf(role: TypeRole) FontSlot {
    return switch (role) {
        .label_strong, .body_strong, .title, .headline, .display => .strong,
        .code, .numeric => .monospace,
        .caption, .label, .body => .regular,
    };
}

fn writeTextStyles(scale: Design.TypeScale, text_scale: f32, tokens: anytype) void {
    @setEvalBranchQuota(100_000);
    const TextStyle = @TypeOf(tokens.text_styles).Value;
    for (std.enums.values(TypeRole)) |role| {
        const font_index, const face = switch (fontSlotOf(role)) {
            .regular => .{ scale.fonts.regular, scale.faces.regular },
            .strong => .{ scale.fonts.strong, scale.faces.strong },
            .monospace => .{ scale.fonts.monospace, scale.faces.monospace },
        };
        const size = bodySizeIn(scale, face) * std.math.pow(f32, scale.ratio, scaleStepOf(role)) * std.math.pow(f32, text_scale, textScalePowerOf(role));
        tokens.text_styles.set(role, .{
            .font = fontIdOf(@FieldType(TextStyle, "font"), font_index),
            .size = size,
            .letter_spacing = trackingFor(size),
            .line_height = lineHeightFor(size),
            .color = tokens.colors.get(.idle).get(.on_surface),
        });
    }
}

fn fontIdOf(comptime FontId: type, index: u32) FontId {
    return switch (@typeInfo(FontId)) {
        .int => @intCast(index),
        .@"enum" => @enumFromInt(index),
        else => comptime unreachable,
    };
}

test {
    _ = @import("tests.zig");
    _ = @import("audit_tests.zig");
    _ = @import("permutations_tests.zig");
    _ = @import("default_tests.zig");
}
