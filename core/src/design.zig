const std = @import("std");
const style = @import("style.zig");
const interaction = @import("interaction.zig");
const contracts = @import("contracts.zig");

const WidgetState = interaction.WidgetState;

/// What a color is for, never what it looks like. Each `on_*` role is the
/// text and icons drawn on its partner.
pub const ColorRole = enum {
    background,
    surface,
    surface_raised,
    surface_sunken,
    surface_inverse,
    on_surface,
    on_surface_muted,
    on_surface_inverse,
    accent,
    on_accent,
    accent_container,
    on_accent_container,
    secondary_container,
    on_secondary_container,
    danger,
    on_danger,
    warning,
    on_warning,
    success,
    on_success,
    outline,
    outline_muted,
    focus,
    scrim,
};

/// A spacing tier, from no space to the widest; a density gives each its
/// length on a base unit of 4.
pub const Space = enum { none, hair, xs, s, m, l, xl, xxl };

/// The only way a design names a text style: each is a step of the type
/// scale, or body text in another font.
pub const TypeRole = enum { display, headline, title, body, body_strong, label, caption, code, numeric };

/// What a part's corners are for, which a design gives a `CornerSize`.
pub const ShapeRole = enum { control, container, popup, chip, image, indicator };

/// How round a shape role's corners are, from `square`, no radius, to
/// `bubble`, half the shorter side: a pill.
pub const CornerSize = enum { square, sharp, smooth, soft, bubble };

/// The smallest a part is so a pointer or a finger can hit it; `none` for
/// a part that takes no input.
pub const Target = enum { none, pointer, touch };

/// How tightly a design spaces its parts, the user's choice in the
/// application: the column of `Design.density` it reads.
pub const Density = enum { compact, comfortable, roomy };

/// A color in OKLCH: `lightness` from 0 to 1, `chroma` from 0, and `hue`
/// in degrees.
pub const Oklch = struct {
    lightness: f32,
    chroma: f32,
    hue: f32,
};

/// What an application or a theme pack declares; a resolver makes `Tokens`
/// from it and the user's preferences. Plain data, so a theme pack needs
/// only `zui`.
///
/// ```zig
/// pub const harbor: zui.design.Design = .{
///     .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
///     .type = .{ .ratio = 1.25, .fonts = .{ .regular = fonts.inter, .strong = fonts.inter_bold, .monospace = fonts.mono } },
///     .corner_shape = .continuous,
/// };
/// ```
pub const Design = struct {
    seeds: Seeds,
    type: TypeScale = .{},
    shapes: std.EnumArray(ShapeRole, CornerSize) = default_shapes,
    corner_shape: style.CornerShape = .round,
    /// The length of each tier at each density, in layout units.
    density: DensityTable = default_density,

    /// Each becomes a tonal ramp, and every role is taken from a ramp.
    pub const Seeds = struct {
        accent: Oklch,
        neutral: Oklch,
        /// The hue of each status role, in degrees; null takes the
        /// resolver's own.
        danger_hue: ?f32 = null,
        warning_hue: ?f32 = null,
        success_hue: ?f32 = null,
    };

    /// Each `TypeRole` is a step of a modular scale from the body size.
    pub const TypeScale = struct {
        ratio: f32 = 1.2,
        body_size: f32 = 15,
        /// The x-height body text is scaled to, in layout units, so two
        /// faces at one role look one size; null sets it at `body_size`.
        x_height: ?f32 = null,
        fonts: Fonts = .{},
    };

    /// Each the integer value of the application's `FontId`, so a design
    /// names its fonts without knowing that type.
    pub const Fonts = struct {
        regular: u32 = 0,
        strong: u32 = 0,
        monospace: u32 = 0,
    };

    pub const DensityTable = std.EnumArray(Density, std.EnumArray(Space, f32));

    pub const default_density: DensityTable = .init(.{
        .compact = .init(.{ .none = 0, .hair = 1, .xs = 2, .s = 4, .m = 8, .l = 12, .xl = 16, .xxl = 24 }),
        .comfortable = .init(.{ .none = 0, .hair = 1, .xs = 4, .s = 8, .m = 12, .l = 16, .xl = 24, .xxl = 32 }),
        .roomy = .init(.{ .none = 0, .hair = 2, .xs = 6, .s = 10, .m = 16, .l = 24, .xl = 32, .xxl = 48 }),
    });

    pub const default_shapes: std.EnumArray(ShapeRole, CornerSize) = .init(.{
        .control = .sharp,
        .container = .smooth,
        .popup = .smooth,
        .chip = .bubble,
        .image = .smooth,
        .indicator = .bubble,
    });
};

/// A raw color a part draws as it is, outside every contrast check; the
/// audit lists it with its reason.
pub const Unchecked = struct {
    color: style.Color,
    reason: []const u8,
};

/// The color a part names: a `ColorRole` by its tag, one of the
/// application's `ExtraRoles` through `.extra`, or a raw color through
/// `.unchecked`.
///
/// ```zig
/// .surface = .accent_container,
/// .surface = .extra(.brand),
/// .icon = .unchecked(.rgb(0xff00ff), "the brand's logo"),
/// ```
pub fn ColorChoice(comptime ExtraRoles: type) type {
    return union(enum) {
        const Choice = @This();

        background,
        surface,
        surface_raised,
        surface_sunken,
        surface_inverse,
        on_surface,
        on_surface_muted,
        on_surface_inverse,
        accent,
        on_accent,
        accent_container,
        on_accent_container,
        secondary_container,
        on_secondary_container,
        danger,
        on_danger,
        warning,
        on_warning,
        success,
        on_success,
        outline,
        outline_muted,
        focus,
        scrim,
        extra_role: if (ExtraRoles == void) enum {} else ExtraRoles,
        unchecked_color: Unchecked,

        pub fn extra(role: if (ExtraRoles == void) enum {} else ExtraRoles) Choice {
            return .{ .extra_role = role };
        }

        /// `reason` says why the color is exempt, and must not be empty.
        pub fn unchecked(color: style.Color, reason: []const u8) Choice {
            return .{ .unchecked_color = .{ .color = color, .reason = reason } };
        }

        /// The `ColorRole` it names, or null for an extra role or a raw color.
        pub fn colorRole(comptime choice: Choice) ?ColorRole {
            return switch (choice) {
                .extra_role, .unchecked_color => null,
                else => @field(ColorRole, @tagName(choice)),
            };
        }
    };
}

/// How one part of a component looks, in roles and tiers, never values.
/// `.on` names the part its text, icon or outline is drawn on, so every
/// pair the component can draw is known before it is drawn.
pub fn PartAppearance(comptime ExtraRoles: type) type {
    return struct {
        surface: ?Choice = null,
        text: ?Choice = null,
        icon: ?Choice = null,
        /// Drawn `outline_width` wide while the part is not focused.
        outline: ?Choice = null,
        /// A part of the same component, as an enum literal. A part that
        /// draws text or an icon names one; an outline without one is drawn
        /// on the part's own surface.
        on: ?@EnumLiteral() = null,
        shape: ?ShapeRole = null,
        padding: Padding = .{},
        gap: Space = .none,
        type: ?TypeRole = null,
        /// A part with a target takes input, so it draws the `focus` role
        /// as its outline while focused, unless `states.focused` gives one.
        target: Target = .none,
        /// Each state's colors default to the part's own, in that state's
        /// layer; one given here replaces them in that state.
        states: States = .{},

        pub const Choice = ColorChoice(ExtraRoles);

        pub const Padding = struct {
            x: Space = .none,
            y: Space = .none,
        };

        /// What a state may give a part in place of its own colors.
        pub const Colors = struct {
            surface: ?Choice = null,
            text: ?Choice = null,
            icon: ?Choice = null,
            outline: ?Choice = null,
        };

        pub const States = struct {
            hovered: ?Colors = null,
            pressed: ?Colors = null,
            focused: ?Colors = null,
            disabled: ?Colors = null,
        };

        /// The part's colors in `state`, an override replacing its own.
        pub fn colorsIn(comptime self: @This(), comptime state: WidgetState) Colors {
            const own: Colors = .{ .surface = self.surface, .text = self.text, .icon = self.icon, .outline = self.outline };
            const override: ?Colors = switch (state) {
                .idle => null,
                .hovered => self.states.hovered,
                .pressed => self.states.pressed,
                .focused => self.states.focused,
                .disabled => self.states.disabled,
            };
            const replacing = override orelse return own;
            return .{
                .surface = replacing.surface orelse own.surface,
                .text = replacing.text orelse own.text,
                .icon = replacing.icon orelse own.icon,
                .outline = replacing.outline orelse own.outline,
            };
        }
    };
}

/// The struct `Appearance` takes: a field for each tag of `Part`.
pub fn Parts(comptime Part: type, comptime ExtraRoles: type) type {
    if (@typeInfo(Part) != .@"enum") @compileError("zui: an appearance's Part must be an enum, got " ++ @typeName(Part));
    const tags = @typeInfo(Part).@"enum".fields;
    const Declared = ?PartAppearance(ExtraRoles);
    const undeclared: Declared = null;
    var names: [tags.len][]const u8 = undefined;
    for (tags, &names) |tag, *name| name.* = tag.name;
    return @Struct(.auto, null, &names, &@splat(Declared), &@splat(.{ .default_value_ptr = &undeclared }));
}

/// A component's look, as its `zuiAppearance`, in the built-in roles alone.
/// The contract is checked when `Tokens.look` first reads the component:
/// every part declared, every text and icon drawn `.on` a part with a
/// surface, every `.unchecked` color given a reason.
///
/// ```zig
/// const Chip = struct {
///     pub const Part = enum { container, container_selected, label, close };
///
///     pub const zuiAppearance = zui.design.Appearance(Part, .{
///         .container = .{ .surface = .secondary_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs },
///         .container_selected = .{ .surface = .accent_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs },
///         .label = .{ .text = .on_secondary_container, .type = .label, .on = .container },
///         .close = .{ .icon = .on_secondary_container, .on = .container, .target = .touch },
///     });
///
///     pub const zuiDistinguish = .{
///         .{ .container, .container_selected },
///         .{ .close, .idle, .hovered },
///     };
/// };
/// ```
pub fn Appearance(comptime Part: type, comptime parts: Parts(Part, void)) type {
    return AppearanceWith(Part, void, parts);
}

/// `Appearance` whose parts may also name the application's `ExtraRoles`,
/// through `.extra(role)`; it is read only by `Tokens` of those roles.
pub fn AppearanceWith(comptime PartType: type, comptime ExtraRolesType: type, comptime declared: Parts(PartType, ExtraRolesType)) type {
    return struct {
        pub const Part = PartType;
        pub const ExtraRoles = ExtraRolesType;
        pub const parts = declared;

        /// Every raw color the component draws, for the audit to list.
        pub const unchecked_colors: []const UncheckedColor(Part) = uncheckedColorsOf(Part, ExtraRoles, declared);

        pub fn of(comptime part: Part) PartAppearance(ExtraRoles) {
            return @field(parts, @tagName(part)).?;
        }
    };
}

/// A raw color in an appearance: the part, the state it is given in (null
/// for the part's own), and the color with its reason.
pub fn UncheckedColor(comptime Part: type) type {
    return struct {
        part: Part,
        state: ?WidgetState,
        unchecked: Unchecked,
    };
}

fn uncheckedColorsOf(comptime Part: type, comptime ExtraRoles: type, comptime declared: Parts(Part, ExtraRoles)) []const UncheckedColor(Part) {
    var found: []const UncheckedColor(Part) = &.{};
    for (std.enums.values(Part)) |part| {
        const appearance = @field(declared, @tagName(part)) orelse continue;
        const own: PartAppearance(ExtraRoles).Colors = .{ .surface = appearance.surface, .text = appearance.text, .icon = appearance.icon, .outline = appearance.outline };
        found = found ++ uncheckedIn(Part, part, null, own);
        for (std.meta.fields(@TypeOf(appearance.states))) |state| {
            const colors = @field(appearance.states, state.name) orelse continue;
            found = found ++ uncheckedIn(Part, part, @field(WidgetState, state.name), colors);
        }
    }
    return found;
}

fn uncheckedIn(comptime Part: type, comptime part: Part, comptime state: ?WidgetState, comptime colors: anytype) []const UncheckedColor(Part) {
    var found: []const UncheckedColor(Part) = &.{};
    for (std.meta.fields(@TypeOf(colors))) |field| {
        const choice = @field(colors, field.name) orelse continue;
        if (choice == .unchecked_color) found = found ++ .{UncheckedColor(Part){ .part = part, .state = state, .unchecked = choice.unchecked_color }};
    }
    return found;
}

/// The resolved values a frame reads: a color per role in each state, a
/// length per tier, a text style per type role, corners per shape role,
/// the target floors and the body text's measure. A resolver writes every
/// field when a preference changes; each is empty until then.
///
/// `ExtraRoles` is `void`, or the application's own roles: an enum whose
/// tags are not `ColorRole`s, declaring `zuiPairs`, the role each is
/// checked against, a `ColorRole` or another of its own.
///
/// ```zig
/// const Roles = enum {
///     brand,
///     on_brand,
///     chart_line,
///
///     pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand, .chart_line = .surface };
/// };
///
/// var tokens: zui.design.Tokens(Ui, Roles) = .{};
/// const look = tokens.look(Chip, .container, ui.widgetState(id));
/// ui.open(.{ .id = id, .decoration = look.decoration, .layout = .{ .padding = look.padding, .child_gap = look.gap } });
/// ```
pub fn Tokens(comptime Ui: type, comptime ExtraRoles: type) type {
    comptime contracts.checkExtraRoles(ExtraRoles);
    return struct {
        const Self = @This();

        pub const has_extra_roles = ExtraRoles != void;
        pub const ColorsByRole = std.EnumArray(WidgetState, std.EnumArray(ColorRole, Ui.Color));
        pub const ExtraColorsByRole = if (has_extra_roles) std.EnumArray(WidgetState, std.EnumArray(ExtraRoles, Ui.Color)) else void;

        /// Each role's color in each state's layer.
        colors: ColorsByRole = .initFill(.initFill(.transparent)),
        extra_colors: ExtraColorsByRole = if (has_extra_roles) .initFill(.initFill(.transparent)) else {},
        spacing: std.EnumArray(Space, f32) = .initFill(0),
        /// What a part that draws text multiplies its padding by, so large
        /// text has room.
        text_padding_scale: f32 = 1,
        text_styles: std.EnumArray(TypeRole, Ui.TextStyle) = .initFill(.{}),
        corner_radii: std.EnumArray(ShapeRole, style.CornerRadius) = .initFill(.zero),
        corner_shapes: std.EnumArray(ShapeRole, style.CornerShape) = .initFill(.round),
        /// The least width and height of a part with each target.
        target_floors: std.EnumArray(Target, f32) = .initFill(0),
        outline_width: f32 = 0,
        focus_ring_width: f32 = 0,
        /// The width of a column of body text, in layout units.
        measure: f32 = 0,

        /// A part in one state, in the context's own types.
        pub const Look = struct {
            decoration: Ui.Decoration = .{},
            padding: style.Edges = .zero,
            gap: f32 = 0,
            /// The part's type role's style, colored by its text or icon role.
            text: Ui.TextStyle = .{},
            min_size: [2]f32 = .{ 0, 0 },
        };

        pub fn space(self: *const Self, tier: Space) f32 {
            return self.spacing.get(tier);
        }

        /// `part` of `Component` in `state`, from the roles its
        /// `zuiAppearance` names. Checks the component's appearance
        /// contract the first time it is read.
        pub fn look(self: *const Self, comptime Component: type, part: PartOf(Component), state: WidgetState) Look {
            return switch (part) {
                inline else => |known_part| switch (state) {
                    inline else => |known_state| self.lookIn(comptime Component.zuiAppearance.of(known_part), known_state),
                },
            };
        }

        fn PartOf(comptime Component: type) type {
            contracts.checkAppearance(Component, ExtraRoles);
            return Component.Part;
        }

        fn lookIn(self: *const Self, comptime declared: anytype, comptime state: WidgetState) Look {
            const colors = comptime declared.colorsIn(state);
            var result: Look = .{
                .gap = self.space(declared.gap),
                .min_size = @splat(self.target_floors.get(declared.target)),
            };
            const padding_scale = if (colors.text != null) self.text_padding_scale else 1;
            result.padding = .symmetric(self.space(declared.padding.x) * padding_scale, self.space(declared.padding.y) * padding_scale);
            if (declared.type) |type_role| result.text = self.text_styles.get(type_role);
            const foreground = comptime if (colors.text != null) colors.text else colors.icon;
            if (foreground) |drawn| result.text.color = self.colorOf(drawn, state);
            if (colors.surface) |surface| result.decoration.background = self.colorOf(surface, state);
            if (declared.shape) |shape| result.decoration.corner_radius = self.corner_radii.get(shape);
            const draws_focus_ring = state == .focused and declared.target != .none and
                (declared.states.focused == null or declared.states.focused.?.outline == null);
            if (draws_focus_ring) {
                result.decoration.border = .{ .color = self.colors.get(state).get(.focus), .widths = .all(self.focus_ring_width) };
            } else if (colors.outline) |outline| {
                result.decoration.border = .{ .color = self.colorOf(outline, state), .widths = .all(self.outline_width) };
            }
            return result;
        }

        fn colorOf(self: *const Self, comptime choice: anytype, comptime state: WidgetState) Ui.Color {
            if (comptime choice.colorRole()) |role| return self.colors.get(state).get(role);
            return switch (choice) {
                .extra_role => |role| self.extra_colors.get(state).get(role),
                .unchecked_color => |unchecked| if (Ui.Color == style.Color) unchecked.color else .fromColor(unchecked.color),
                else => unreachable,
            };
        }
    };
}
