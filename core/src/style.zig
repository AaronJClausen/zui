const std = @import("std");
const Id = @import("id.zig").Id;

/// `@max` for layout values. Zig's `@max` and `@min` on floats are NaN-aware,
/// which costs about five extra instructions each; layout runs them for
/// every element in every pass, and its values are never NaN unless the
/// application passes one in.
pub inline fn larger(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

pub inline fn smaller(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// `std.math.clamp` without the NaN handling; `min` wins if `min > max`.
pub inline fn clampSize(value: f32, min: f32, max: f32) f32 {
    return larger(min, smaller(value, max));
}

pub const Axis = enum(u1) {
    x,
    y,

    pub fn other(axis: Axis) Axis {
        return if (axis == .x) .y else .x;
    }
};

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// `.rgb(0x3366ff)`
    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    /// `.rgba(0x3366ff80)`
    pub fn rgba(hex: u32) Color {
        return .{ .r = @truncate(hex >> 24), .g = @truncate(hex >> 16), .b = @truncate(hex >> 8), .a = @truncate(hex) };
    }

    /// Linear interpolation per channel; `amount` 0 is `self`, 1 is `other`.
    pub fn mix(self: Color, other: Color, amount: f32) Color {
        const clamped = std.math.clamp(amount, 0, 1);
        return .{
            .r = mixChannel(self.r, other.r, clamped),
            .g = mixChannel(self.g, other.g, clamped),
            .b = mixChannel(self.b, other.b, clamped),
            .a = mixChannel(self.a, other.a, clamped),
        };
    }

    fn mixChannel(from: u8, to: u8, amount: f32) u8 {
        const from_float: f32 = @floatFromInt(from);
        const to_float: f32 = @floatFromInt(to);
        return @intFromFloat(@round(from_float + (to_float - from_float) * amount));
    }

    /// Interpolated in OKLab, where equal steps look equally far apart, so
    /// the middle of a mix is neither muddy nor too dark; alpha is
    /// interpolated linearly. `amount` 0 is `self`, 1 is `other`.
    ///
    /// ```zig
    /// const middle = Color.black.mixOklab(.white, 0.5); // #636363, where `mix` gives #808080
    /// ```
    pub fn mixOklab(self: Color, other: Color, amount: f32) Color {
        const clamped = std.math.clamp(amount, 0, 1);
        const mixed = Oklab.fromLinear(linearOf(self)).mix(.fromLinear(linearOf(other)), clamped).toLinear();
        return .{
            .r = srgbFromLinear(mixed[0]),
            .g = srgbFromLinear(mixed[1]),
            .b = srgbFromLinear(mixed[2]),
            .a = mixChannel(self.a, other.a, clamped),
        };
    }

    pub fn eql(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
    }

    fn linearOf(color: Color) [3]f32 {
        return .{ linearFromSrgb(color.r), linearFromSrgb(color.g), linearFromSrgb(color.b) };
    }
};

/// A color for HDR and wide-gamut displays: linear scRGB in half floats,
/// where 1 is SDR white, a channel above 1 is brighter than SDR white, and
/// one below 0 or above 1 reaches outside sRGB's gamut. Alpha is straight,
/// 0 to 1. A context takes it in place of `Color` with
/// `Config.Color = zui.ExtendedColor`; its helpers match `Color`'s, so a
/// theme written with `.rgb(0x3366ff)` compiles with either.
///
/// ```zig
/// const hdr_white: zui.ExtendedColor = .linear(4, 4, 4, 1); // four times SDR white, on a display with the headroom
/// const brand: zui.ExtendedColor = .rgb(0x3366ff);          // the sRGB color, exactly
/// ```
pub const ExtendedColor = extern struct {
    r: f16,
    g: f16,
    b: f16,
    a: f16 = 1,

    pub const black: ExtendedColor = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: ExtendedColor = .{ .r = 1, .g = 1, .b = 1 };
    pub const transparent: ExtendedColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn linear(red: f32, green: f32, blue: f32, alpha: f32) ExtendedColor {
        return .{ .r = @floatCast(red), .g = @floatCast(green), .b = @floatCast(blue), .a = @floatCast(alpha) };
    }

    /// The sRGB color `.rgb(0x3366ff)` names, decoded to linear.
    pub fn rgb(hex: u24) ExtendedColor {
        return .fromColor(.rgb(hex));
    }

    /// `.rgba(0x3366ff80)`
    pub fn rgba(hex: u32) ExtendedColor {
        return .fromColor(.rgba(hex));
    }

    pub fn fromColor(color: Color) ExtendedColor {
        return .linear(linearFromSrgb(color.r), linearFromSrgb(color.g), linearFromSrgb(color.b), @as(f32, @floatFromInt(color.a)) / 255);
    }

    /// Clamped into SDR and sRGB's gamut, then encoded: what a renderer
    /// that draws only `Color` is given.
    pub fn toColor(self: ExtendedColor) Color {
        return .{
            .r = srgbFromLinear(self.r),
            .g = srgbFromLinear(self.g),
            .b = srgbFromLinear(self.b),
            .a = @intFromFloat(@round(std.math.clamp(@as(f32, self.a), 0, 1) * 255)),
        };
    }

    /// Every channel within 0 to 1, so `toColor` loses only precision.
    pub fn isStandard(self: ExtendedColor) bool {
        const all = self.channels();
        return @reduce(.And, all >= @as(@Vector(4, f32), @splat(0))) and @reduce(.And, all <= @as(@Vector(4, f32), @splat(1)));
    }

    /// Linear interpolation per channel; `amount` 0 is `self`, 1 is `other`.
    pub fn mix(self: ExtendedColor, other: ExtendedColor, amount: f32) ExtendedColor {
        const clamped = std.math.clamp(amount, 0, 1);
        const from = self.channels();
        const to = other.channels();
        const mixed = from + (to - from) * @as(@Vector(4, f32), @splat(clamped));
        return .linear(mixed[0], mixed[1], mixed[2], mixed[3]);
    }

    /// As `Color.mixOklab`, without clamping: the middle of two HDR colors
    /// stays HDR.
    pub fn mixOklab(self: ExtendedColor, other: ExtendedColor, amount: f32) ExtendedColor {
        const clamped = std.math.clamp(amount, 0, 1);
        const from = self.channels();
        const to = other.channels();
        const mixed = Oklab.fromLinear(.{ from[0], from[1], from[2] }).mix(.fromLinear(.{ to[0], to[1], to[2] }), clamped).toLinear();
        return .linear(mixed[0], mixed[1], mixed[2], from[3] + (to[3] - from[3]) * clamped);
    }

    pub fn eql(self: ExtendedColor, other: ExtendedColor) bool {
        return std.meta.eql(self, other);
    }

    fn channels(self: ExtendedColor) @Vector(4, f32) {
        return .{ self.r, self.g, self.b, self.a };
    }
};

const Oklab = struct {
    lightness: f32,
    green_red: f32,
    blue_yellow: f32,

    fn fromLinear(rgb: [3]f32) Oklab {
        const red, const green, const blue = rgb;
        const long = std.math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
        const medium = std.math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
        const short = std.math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);
        return .{
            .lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            .green_red = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            .blue_yellow = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short,
        };
    }

    fn mix(self: Oklab, other: Oklab, amount: f32) Oklab {
        return .{
            .lightness = self.lightness + (other.lightness - self.lightness) * amount,
            .green_red = self.green_red + (other.green_red - self.green_red) * amount,
            .blue_yellow = self.blue_yellow + (other.blue_yellow - self.blue_yellow) * amount,
        };
    }

    fn toLinear(self: Oklab) [3]f32 {
        const long_root = self.lightness + 0.3963377774 * self.green_red + 0.2158037573 * self.blue_yellow;
        const medium_root = self.lightness - 0.1055613458 * self.green_red - 0.0638541728 * self.blue_yellow;
        const short_root = self.lightness - 0.0894841775 * self.green_red - 1.2914855480 * self.blue_yellow;
        const long = long_root * long_root * long_root;
        const medium = medium_root * medium_root * medium_root;
        const short = short_root * short_root * short_root;
        return .{
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
        };
    }
};

fn linearFromSrgb(channel: u8) f32 {
    const encoded = @as(f32, @floatFromInt(channel)) / 255;
    return if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}

fn srgbFromLinear(linear: f32) u8 {
    const clamped = std.math.clamp(linear, 0, 1);
    const encoded = if (clamped <= 0.0031308) clamped * 12.92 else 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

/// As padding, logical: `left` is the start side and `right` the end,
/// so a mirrored element puts `left` on its right. As a border's widths,
/// physical.
pub const Edges = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub const zero: Edges = .{};

    pub fn all(amount: f32) Edges {
        return .{ .left = amount, .right = amount, .top = amount, .bottom = amount };
    }

    pub fn symmetric(horizontal: f32, vertical: f32) Edges {
        return .{ .left = horizontal, .right = horizontal, .top = vertical, .bottom = vertical };
    }

    pub fn total(self: Edges, axis: Axis) f32 {
        return if (axis == .x) self.left + self.right else self.top + self.bottom;
    }
};

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub const zero: CornerRadius = .{};

    pub fn all(radius: f32) CornerRadius {
        return .{ .top_left = radius, .top_right = radius, .bottom_left = radius, .bottom_right = radius };
    }

    /// Each corner at most half the shorter side of `bounds`, so a radius
    /// of any size makes a pill of a box.
    pub fn clampedTo(self: CornerRadius, bounds: Rect) CornerRadius {
        const Radii = @Vector(4, f32);
        const radii: Radii = .{ self.top_left, self.top_right, self.bottom_left, self.bottom_right };
        const clamped = @min(radii, @as(Radii, @splat(@min(bounds.width, bounds.height) * 0.5)));
        return .{ .top_left = clamped[0], .top_right = clamped[1], .bottom_left = clamped[2], .bottom_right = clamped[3] };
    }
};

/// The family of an element's four corners, whatever their radii:
/// `round` is circular arcs, `continuous` a superellipse whose curvature
/// does not break where the corner meets the side, and `chamfer` a 45° cut.
pub const CornerShape = enum(u8) { round, continuous, chamfer };

/// The corner shapes a renderer draws, its `zui_corner_shapes`. It always
/// holds `round`, which every other shape is drawn as where it is missing.
///
/// ```zig
/// pub const zui_corner_shapes: zui.CornerShapeSet = .initFull();
/// ```
pub const CornerShapeSet = std.EnumSet(CornerShape);

/// Corners concentric with those of the nearest ancestor that has a
/// decoration, in place of the element's own `corner_radius`. Each corner
/// follows the ancestor's at the element's inset from that corner, the
/// larger of its distances from the two sides, as laid out: `round` and
/// `continuous` take the ancestor's radius less the inset, and `chamfer`
/// shortens its cut by (2 − √2) × the inset, which keeps the two cuts
/// parallel. A corner whose inset is past the ancestor's radius, or whose
/// radius would fall below `minimum`, takes `minimum`. An element with no
/// decorated ancestor sits in the window's square corners.
///
/// ```zig
/// ui.open(.{ .id = .of("card"), .decoration = .{ .background = .rgb(0x202830), .corner_radius = .all(16) }, .layout = .{ .padding = .all(6) } });
/// defer ui.close();
/// ui.box(.{ .id = .of("thumbnail"), .decoration = .{ .background = .rgb(0x405060), .nested_corners = .{ .minimum = 2 } } }); // radius 10
/// ```
pub const NestedCorners = struct {
    /// The least radius any corner takes; 0 leaves square the corners
    /// that do not follow the ancestor's.
    minimum: f32 = 0,
};

/// `Decoration.nested_corners` in a context without the feature: it holds
/// nothing. A field's coercion can raise no `@compileError`, so the type is
/// named by the message, which Zig's error for any value declared there
/// quotes.
const @"zui: Decoration.nested_corners needs Config.features.nested_corners = true" = enum { off };
const NestedCornersOff = @"zui: Decoration.nested_corners needs Config.features.nested_corners = true";

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, point: [2]f32) bool {
        return point[0] >= self.x and point[0] < self.x + self.width and
            point[1] >= self.y and point[1] < self.y + self.height;
    }

    /// The overlap of two rectangles; empty (zero-sized) when they do not meet.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const left = larger(self.x, other.x);
        const top = larger(self.y, other.y);
        const right = smaller(self.x + self.width, other.x + other.width);
        const bottom = smaller(self.y + self.height, other.y + other.height);
        return .{ .x = left, .y = top, .width = larger(0, right - left), .height = larger(0, bottom - top) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width <= 0 or self.height <= 0;
    }
};

/// Drawn over the element's children, after its subtree.
pub const Border = BorderWith(Color);

/// `Border` in a context's own color type, `Ui.Border`.
pub fn BorderWith(comptime ColorType: type) type {
    return struct {
        color: ColorType,
        /// All zero: no outline, so a border can draw only its dividers.
        widths: Edges = .zero,
        /// The width of a divider between each two adjacent children in the
        /// flow, centered in the gap between them and spanning the element
        /// inside its `widths`. Dividers scroll and clip with the children.
        ///
        /// ```zig
        /// ui.open(.{
        ///     .layout = .{ .direction = .top_to_bottom, .child_gap = 9 },
        ///     .decoration = .{ .border = .{ .color = .rgb(0x2c2c38), .between_children = 1 } },
        /// });
        /// ```
        between_children: f32 = 0,
    };
}

/// How an element's size along one axis is decided. A struct with
/// declarations rather than a tagged union, because Zig forbids a field and
/// a declaration of the same name and the helpers keep literals short:
/// `.width = .grow`, `.height = .fixed(48)`.
pub const Sizing = struct {
    rule: Rule = .fit,
    /// fixed: the size. percent: the fraction of the parent's content box (0..1). grow, grow_from_min: the weight.
    /// aspect_ratio: width / height.
    amount: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.inf(f32),

    /// Four bytes, so `Sizing` has no padding bytes for declaration to copy
    /// into every layout. That is also why a grow basis and an aspect
    /// ratio are rules rather than fields of their own: two two-byte fields
    /// made the box tree's declaration 3.8% more instructions, and an
    /// aspect ratio in `Layout` made it 6.6% slower.
    pub const Rule = enum(u32) {
        fit,
        /// Starts from the content's size and adds a share of the free space
        /// by weight, as CSS `flex: auto`: two `.grow` siblings holding "a"
        /// and "abcdefghijklmnop" in 300 come out 90 and 210.
        grow,
        /// Starts from `min`, a zero basis, and shares the content box by
        /// weight, as CSS `flex: 1`, never narrower than the content's
        /// minimum: the same two siblings come out 150 and 150.
        grow_from_min,
        /// A height derived from the settled width, `width / amount`,
        /// within `min` and `max`. Children do not stretch it; they
        /// overflow. A width cannot follow the height, so on a width, or
        /// with a ratio that is not positive, it takes its content's size.
        aspect_ratio,
        fixed,
        percent,

        pub fn grows(self: Rule) bool {
            return self == .grow or self == .grow_from_min;
        }
    };

    pub const fit: Sizing = .{};
    pub const grow: Sizing = .{ .rule = .grow, .amount = 1 };
    /// Columns or rows of one size, whatever their content.
    pub const grow_equal: Sizing = .{ .rule = .grow_from_min, .amount = 1 };

    pub fn fixed(size: f32) Sizing {
        return .{ .rule = .fixed, .amount = size, .min = size, .max = size };
    }

    pub fn percent(fraction: f32) Sizing {
        return .{ .rule = .percent, .amount = fraction };
    }

    /// A weight of 2 takes twice the free space of a `.grow` sibling.
    pub fn growWeighted(weight: f32) Sizing {
        return .{ .rule = .grow, .amount = weight };
    }

    pub fn fitBetween(min: f32, max: f32) Sizing {
        return .{ .rule = .fit, .min = min, .max = max };
    }

    /// For a height: `.height = .aspectRatio(16.0 / 9.0)` is a 16:9 box at
    /// whatever width its own rule gives it.
    pub fn aspectRatio(width_over_height: f32) Sizing {
        return .{ .rule = .aspect_ratio, .amount = width_over_height };
    }
};

pub const Sizing2 = struct {
    width: Sizing = .fit,
    height: Sizing = .fit,

    pub const grow_both: Sizing2 = .{ .width = .grow, .height = .grow };

    pub fn axis(self: Sizing2, which: Axis) Sizing {
        return if (which == .x) self.width else self.height;
    }
};

/// How an element's children flow. A row flows from its start: the left,
/// or the right in a mirrored element. `right_to_left` mirrors the element
/// for its own children alone: their flow, their alignment, its padding
/// and its floating children's anchors, so in a mirrored element it flows
/// from the left.
pub const Direction = enum(u8) {
    left_to_right,
    top_to_bottom,
    right_to_left,

    pub fn axis(self: Direction) Axis {
        return if (self == .top_to_bottom) .y else .x;
    }
};

/// Whether an element and its subtree are laid out right to left: start
/// on the right for rows, alignment, padding, floating anchors and text.
/// One byte, not a `?bool`, which is two and would make every `Layout`
/// four bytes larger.
pub const Mirrored = enum(u8) {
    /// As the parent is; the root follows the environment's `direction`.
    inherit,
    yes,
    no,
};

pub const Alignment = enum(u8) {
    start,
    center,
    end,

    /// The fraction of the free space placed before the content.
    pub fn fraction(self: Alignment) f32 {
        return switch (self) {
            .start => 0,
            .center => 0.5,
            .end => 1,
        };
    }
};

pub const Alignment2 = struct {
    x: Alignment = .start,
    y: Alignment = .start,

    pub fn axis(self: Alignment2, which: Axis) Alignment {
        return if (which == .x) self.x else self.y;
    }
};

pub const Layout = struct {
    direction: Direction = .left_to_right,
    sizing: Sizing2 = .{},
    /// `left` is the start side, so a mirrored element puts it on the right.
    padding: Edges = .{},
    child_gap: f32 = 0,
    /// `x = .start` is the left, or the right in a mirrored element.
    child_alignment: Alignment2 = .{},
    /// Overrides the parent's for the whole subtree. A phone number in an
    /// Arabic form stays left to right:
    ///
    /// ```zig
    /// ui.open(.{ .layout = .{ .mirrored = .no } });
    /// ```
    mirrored: Mirrored = .inherit,
};

/// A byte rather than two bits: Zig stores a two-bit enum field as two bits
/// and loads it as a byte, and LLVM then cannot fold an element's default
/// `clip`.
pub const Axes = enum(u8) {
    none,
    horizontal,
    vertical,
    both,

    pub fn includes(self: Axes, axis: Axis) bool {
        return self == .both or self == if (axis == .x) Axes.horizontal else Axes.vertical;
    }
};

/// A linear gradient from one color to another across an element,
/// interpolated in OKLab. Its line runs through the element's center at
/// `angle`, just long enough that the two corners farthest along it take
/// `from` and `to`, so no angle leaves a band of one color. Physical, as a
/// border's widths are: a mirrored element keeps its angle.
///
/// ```zig
/// .effects = &.{ .gradient = .{ .from = .rgb(0x3a1c71), .to = .rgb(0xffaf7b), .angle = std.math.pi / 2 } },
/// ```
pub const Gradient = GradientWith(Color);

/// `Gradient` in a context's own color type, `Ui.Gradient`.
pub fn GradientWith(comptime ColorType: type) type {
    return struct {
        const Self = @This();

        from: ColorType,
        to: ColorType,
        /// Radians clockwise from left to right: 0 runs from the left edge to
        /// the right, pi / 2 from the top to the bottom.
        angle: f32 = 0,

        /// How far along the gradient `point` lies: 0 takes `from`, 1 takes `to`.
        pub fn amountAt(self: Self, bounds: Rect, point: [2]f32) f32 {
            const along: [2]f32 = .{ @cos(self.angle), @sin(self.angle) };
            const length = @abs(bounds.width * along[0]) + @abs(bounds.height * along[1]);
            if (length == 0) return 0.5;
            const from_center: [2]f32 = .{ point[0] - (bounds.x + bounds.width / 2), point[1] - (bounds.y + bounds.height / 2) };
            return std.math.clamp((from_center[0] * along[0] + from_center[1] * along[1]) / length + 0.5, 0, 1);
        }

        pub fn colorAt(self: Self, bounds: Rect, point: [2]f32) ColorType {
            return self.from.mixOklab(self.to, self.amountAt(bounds, point));
        }

        /// The gradient's average over the element it covers, which is its
        /// middle at any angle: the gradient is symmetric about the center.
        pub fn meanColor(self: Self) ColorType {
            return self.from.mixOklab(self.to, 0.5);
        }
    };
}

/// A shadow cast beneath an element in the shape of its rounded box, or
/// with no offset, a glow around it. In layout units.
///
/// ```zig
/// .effects = &.{ .shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 4 }, .blur = 12 } },
/// .effects = &.{ .shadow = .glow(.rgba(0x4080ff80), 16) },
/// ```
pub const Shadow = ShadowWith(Color);

/// `Shadow` in a context's own color type, `Ui.Shadow`.
pub fn ShadowWith(comptime ColorType: type) type {
    return struct {
        const Self = @This();

        color: ColorType,
        /// Right and down from the element.
        offset: [2]f32 = .{ 0, 0 },
        /// How far the edge fades, outward from where it would end unblurred.
        blur: f32 = 0,
        /// How far the shape grows on every side before it is blurred.
        spread: f32 = 0,

        pub fn glow(color: ColorType, radius: f32) Self {
            return .{ .color = color, .blur = radius };
        }

        /// Everything the shadow may paint, for an element at `bounds`.
        pub fn paintedBounds(self: Self, bounds: Rect) Rect {
            const reach = larger(0, self.spread + self.blur);
            return .{
                .x = bounds.x + self.offset[0] - reach,
                .y = bounds.y + self.offset[1] - reach,
                .width = bounds.width + 2 * reach,
                .height = bounds.height + 2 * reach,
            };
        }
    };
}

/// Frosted glass: what zui drew beneath an element, blurred within its
/// rounded box, then `tint` over it. A renderer that does not blur draws
/// the tint alone, so a tint that reads well unblurred is the safe choice.
///
/// ```zig
/// .effects = &.{ .backdrop_blur = .{ .radius = 12, .tint = .rgba(0xffffff40) } },
/// ```
pub const BackdropBlur = BackdropBlurWith(Color);

/// `BackdropBlur` in a context's own color type, `Ui.BackdropBlur`.
pub fn BackdropBlurWith(comptime ColorType: type) type {
    return struct {
        /// The blur's standard deviation in layout units, as CSS's `blur()`
        /// takes it. Only what lies within the element is sampled, its edges
        /// extended, so nothing outside it bleeds in.
        radius: f32,
        tint: ColorType,
    };
}

/// A map of the plane that keeps straight lines straight: `point` goes to
/// `x_axis * point[0] + y_axis * point[1] + offset`.
pub const Affine = struct {
    x_axis: [2]f32 = .{ 1, 0 },
    y_axis: [2]f32 = .{ 0, 1 },
    offset: [2]f32 = .{ 0, 0 },

    pub const identity: Affine = .{};

    pub fn apply(self: Affine, point: [2]f32) [2]f32 {
        const moved = self.applyLinear(point);
        return .{ moved[0] + self.offset[0], moved[1] + self.offset[1] };
    }

    fn applyLinear(self: Affine, vector: [2]f32) [2]f32 {
        return .{
            self.x_axis[0] * vector[0] + self.y_axis[0] * vector[1],
            self.x_axis[1] * vector[0] + self.y_axis[1] * vector[1],
        };
    }

    /// `first`, then `self`.
    pub fn after(self: Affine, first: Affine) Affine {
        return .{ .x_axis = self.applyLinear(first.x_axis), .y_axis = self.applyLinear(first.y_axis), .offset = self.apply(first.offset) };
    }

    /// Null when the map flattens the plane onto a line or a point, as a
    /// scale of 0 does.
    pub fn inverse(self: Affine) ?Affine {
        const determinant = self.x_axis[0] * self.y_axis[1] - self.y_axis[0] * self.x_axis[1];
        if (determinant == 0 or !std.math.isFinite(determinant)) return null;
        const linear: Affine = .{
            .x_axis = .{ self.y_axis[1] / determinant, -self.x_axis[1] / determinant },
            .y_axis = .{ -self.y_axis[0] / determinant, self.x_axis[0] / determinant },
        };
        const moved_offset = linear.applyLinear(self.offset);
        return .{ .x_axis = linear.x_axis, .y_axis = linear.y_axis, .offset = .{ -moved_offset[0], -moved_offset[1] } };
    }

    /// The smallest rectangle holding all of `rect` once mapped.
    pub fn boundsOf(self: Affine, rect: Rect) Rect {
        const corners = [_][2]f32{
            self.apply(.{ rect.x, rect.y }),
            self.apply(.{ rect.x + rect.width, rect.y }),
            self.apply(.{ rect.x, rect.y + rect.height }),
            self.apply(.{ rect.x + rect.width, rect.y + rect.height }),
        };
        var low = corners[0];
        var high = corners[0];
        for (corners[1..]) |corner| for (0..2) |axis| {
            low[axis] = smaller(low[axis], corner[axis]);
            high[axis] = larger(high[axis], corner[axis]);
        };
        return .{ .x = low[0], .y = low[1], .width = high[0] - low[0], .height = high[1] - low[1] };
    }
};

/// Moves, scales and rotates an element and everything inside it as they
/// are painted, leaving layout as it was: `rectOf` is still the box it was
/// laid out in, and its neighbours do not move. A pointer hits it where it
/// is drawn. A renderer that does not declare `.transform` draws it, and
/// hit-tests it, untransformed.
///
/// ```zig
/// .effects = &.{ .transform = .{ .rotation = std.math.pi / 12.0 } },
/// .effects = &.{ .transform = .{ .scale = @splat(0.9 + 0.1 * app.dialog_shown), .origin = .{ 0.5, 0 } } },
/// ```
///
/// A floating element is cut off by its target's clip, and by its own box
/// when it clips, before its own transform applies, so it clips to its box
/// as laid out.
pub const Transform = struct {
    /// In layout units, right and down.
    translation: [2]f32 = .{ 0, 0 },
    scale: [2]f32 = .{ 1, 1 },
    /// Radians clockwise, as a gradient's angle is.
    rotation: f32 = 0,
    /// A fraction of the element's box: `.{ 0.5, 0.5 }` is its center and
    /// `.{ 0, 0 }` its top-left corner.
    origin: [2]f32 = .{ 0.5, 0.5 },

    /// From the element laid out at `bounds` to where it is painted:
    /// scaled, then rotated, about the origin, then translated.
    pub fn affine(self: Transform, bounds: Rect) Affine {
        const cosine = @cos(self.rotation);
        const sine = @sin(self.rotation);
        const pivot: [2]f32 = .{ bounds.x + self.origin[0] * bounds.width, bounds.y + self.origin[1] * bounds.height };
        const turned: Affine = .{
            .x_axis = .{ cosine * self.scale[0], sine * self.scale[0] },
            .y_axis = .{ -sine * self.scale[1], cosine * self.scale[1] },
        };
        const turned_pivot = turned.applyLinear(pivot);
        return .{
            .x_axis = turned.x_axis,
            .y_axis = turned.y_axis,
            .offset = .{ pivot[0] + self.translation[0] - turned_pivot[0], pivot[1] + self.translation[1] - turned_pivot[1] },
        };
    }
};

/// Background, border, corner radius and shape: what an element draws
/// behind and around its children.
pub const Decoration = DecorationWith(Color, void, false);

/// `Decoration` in a context's own color type, with a `material`, the
/// renderer's own shader drawn in place of the background, for a context
/// whose `MaterialHandle` is not `void`, and with `nested_corners` for one
/// whose `features.nested_corners` is on. A context names it
/// `Ui.Decoration`.
///
/// ```zig
/// ui.open(.{ .decoration = .{ .background = .rgb(0x202830), .material = .frosted_glass, .corner_radius = .all(8) } });
/// ```
pub fn DecorationWith(comptime ColorType: type, comptime MaterialHandle: type, comptime has_nested_corners: bool) type {
    return struct {
        background: ?ColorType = null,
        border: ?BorderWith(ColorType) = null,
        /// Each at most half the shorter side, however large declared.
        corner_radius: CornerRadius = .zero,
        /// Drawn as `round` by a renderer whose `zui_corner_shapes` lacks it.
        corner_shape: CornerShape = .round,
        /// Replaces `corner_radius` with corners concentric with the
        /// nearest decorated ancestor's.
        nested_corners: if (has_nested_corners) ?NestedCorners else NestedCornersOff = if (has_nested_corners) null else .off,
        /// Drawn over the bounds, in the corners, by a renderer that
        /// declares `.material`. Any other draws `background` instead, so
        /// the background is the material's fallback.
        material: if (MaterialHandle == void) void else ?MaterialHandle = if (MaterialHandle == void) {} else null,

        const has_material = MaterialHandle != void;

        pub inline fn materialOf(self: *const @This()) ?MaterialHandle {
            return if (comptime has_material) self.material else null;
        }

        /// Null in a context without `features.nested_corners`.
        pub inline fn nestedCornersOf(self: *const @This()) ?NestedCorners {
            return if (comptime has_nested_corners) self.nested_corners else null;
        }
    };
}

/// What an element draws with the optional commands, in the shape of its
/// decoration's corner radius: from the bottom, its shadow, its backdrop
/// blur, its background, then its gradient, all moved by its transform.
/// An element points at its effects rather than holding them, so that
/// declaring one without any copies nothing more.
///
/// ```zig
/// const card_effects: zui.Effects = .{ .shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 4 }, .blur = 12 } };
///
/// ui.box(.{ .style = styles.card, .effects = &card_effects });
/// ```
pub const Effects = EffectsWith(Color);

/// `Effects` in a context's own color type, `Ui.Effects`.
pub fn EffectsWith(comptime ColorType: type) type {
    return struct {
        /// Painted over the background, so a translucent gradient tints it.
        gradient: ?GradientWith(ColorType) = null,
        shadow: ?ShadowWith(ColorType) = null,
        /// Painted under the background, so only a translucent one shows it.
        backdrop_blur: ?BackdropBlurWith(ColorType) = null,
        /// Applies to the element's children and other effects too.
        transform: ?Transform = null,
    };
}

/// An element's layout and decoration together, made once at comptime with
/// `zui.static` and referenced by every element that uses it.
pub const Style = StyleWith(Decoration);

/// `Style` with a context's own decoration, `Ui.Style`; it is `Style`
/// unless the context has a `MaterialHandle`.
pub fn StyleWith(comptime ContextDecoration: type) type {
    return struct {
        layout: Layout = .{},
        decoration: ContextDecoration = .{},
    };
}

/// A value in read-only memory for the life of the program, which an
/// element references instead of copying. Only `zui.static` makes one, at
/// comptime, so it is safe under any number of frames in flight.
pub fn Static(comptime T: type) type {
    return struct {
        value: *const T,
    };
}

/// ```zig
/// const toolbar_style = zui.static(zui.Style{
///     .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4) },
///     .decoration = .{ .background = .rgb(0x202020) },
/// });
/// ui.open(.{ .id = .of("toolbar"), .style = toolbar_style });
/// ```
pub fn static(comptime value: anytype) Static(@TypeOf(value)) {
    const Holder = struct {
        const held = value;
    };
    return .{ .value = &Holder.held };
}

/// Which axes of an element scroll. Scrolling also clips those axes, and
/// needs an explicit id, because the offset lives in the state table.
pub const Scroll = struct {
    horizontal: bool = false,
    vertical: bool = true,

    pub const both: Scroll = .{ .horizontal = true, .vertical = true };
};

pub const AnchorPoint = enum(u4) {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    /// The point's position within a box, as fractions of its width and height.
    pub fn fractions(self: AnchorPoint) [2]f32 {
        const index = @intFromEnum(self);
        return .{ @as(f32, @floatFromInt(index % 3)) / 2, @as(f32, @floatFromInt(index / 3)) / 2 };
    }
};

pub const AttachTo = union(enum) {
    /// The element's parent in the tree.
    parent,
    /// The viewport.
    root,
    /// Another element, declared before or after this one but not inside
    /// it; one declared after is placed once the rest of the frame is. An
    /// id no element has, or one inside this element, falls back to the
    /// parent.
    element: Id,
};

/// What cuts off a floating element and its subtree.
pub const FloatingClip = enum(u8) {
    /// Only the viewport: it escapes every ancestor's clip, as a menu
    /// that opens past the edge of a scrolled list should.
    none,
    /// Whatever cuts off its target's children: the viewport for `.root`,
    /// and otherwise the target's own clip within its ancestors', so a
    /// badge on a row scrolls out of sight with the row.
    target,
};

/// An element positioned relative to another box instead of its parent's
/// flow. It takes no space in its parent, paints in layer `z`, escapes its
/// ancestors' clipping unless `clip` is `.target`, and, while `capture`
/// is true, receives the pointer before lower layers.
pub const Floating = struct {
    attach_to: AttachTo = .parent,
    /// The point of the floating element that is placed...
    anchor: AnchorPoint = .top_left,
    /// ...on this point of the box it attaches to.
    attach_point: AnchorPoint = .top_left,
    offset: [2]f32 = .{ 0, 0 },
    z: i16 = 1,
    /// False lets the pointer through to whatever lies beneath, as a
    /// tooltip should; interactive elements inside it still take it.
    capture: bool = true,
    clip: FloatingClip = .none,
};

pub const TextWrap = enum(u8) {
    /// Break between words to fit the element's width, and at newlines.
    words,
    /// Break only at newlines.
    newlines,
    /// Never break; the text is one line.
    none,
};

/// What the text contract is asked to measure. `size` already includes the
/// frame's zoom.
pub fn MeasureKey(comptime FontId: type) type {
    return struct {
        font: FontId,
        size: f32,
        letter_spacing: f32,
    };
}

pub fn TextStyle(comptime FontId: type) type {
    return TextStyleWith(FontId, Color);
}

/// `TextStyle` in a context's own color type, `Ui.TextStyle`.
pub fn TextStyleWith(comptime FontId: type, comptime ColorType: type) type {
    return struct {
        font: FontId = std.mem.zeroes(FontId),
        /// Layout units, not points.
        size: f32 = 16,
        /// Layout units added after each glyph, including the last.
        letter_spacing: f32 = 0,
        /// 0 means the height the text contract measures for the font.
        line_height: f32 = 0,
        color: ColorType = .black,
        wrap: TextWrap = .words,
        alignment: Alignment = .start,
    };
}

test "Color helpers" {
    try std.testing.expectEqual(Color{ .r = 0x33, .g = 0x66, .b = 0xff }, Color.rgb(0x3366ff));
    try std.testing.expectEqual(Color{ .r = 0x33, .g = 0x66, .b = 0xff, .a = 0x80 }, Color.rgba(0x3366ff80));
    try std.testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128 }, Color.black.mix(.white, 0.5));
}

test "Rect intersection and containment" {
    const rect: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .width = 5, .height = 5 }, rect.intersect(.{ .x = 5, .y = 5, .width = 20, .height = 20 }));
    try std.testing.expect(rect.intersect(.{ .x = 20, .y = 0, .width = 5, .height = 5 }).isEmpty());
    try std.testing.expect(rect.contains(.{ 0, 9.5 }));
    try std.testing.expect(!rect.contains(.{ 10, 5 }));
}

test "anchor points" {
    try std.testing.expectEqual([2]f32{ 0, 0 }, AnchorPoint.top_left.fractions());
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, AnchorPoint.center.fractions());
    try std.testing.expectEqual([2]f32{ 1, 1 }, AnchorPoint.bottom_right.fractions());
    try std.testing.expectEqual([2]f32{ 0.5, 1 }, AnchorPoint.bottom_center.fractions());
}

test "Sizing decl literals" {
    const sizing: Sizing2 = .{ .width = .grow, .height = .fixed(48) };
    try std.testing.expectEqual(Sizing.Rule.grow, sizing.width.rule);
    try std.testing.expectEqual(@as(f32, 48), sizing.axis(.y).amount);
    try std.testing.expectEqual(Sizing.Rule.grow_from_min, (Sizing2{ .width = .grow_equal }).width.rule);
    try std.testing.expectEqual(Sizing{ .rule = .aspect_ratio, .amount = 2 }, (Sizing2{ .height = .aspectRatio(2) }).height);
}

test "Layout keeps its size with mirroring" {
    try std.testing.expectEqual(56, @sizeOf(Layout));
}

test "Sizing has no padding bytes" {
    try std.testing.expectEqual(3 * @sizeOf(f32) + @sizeOf(Sizing.Rule), @sizeOf(Sizing));
}
