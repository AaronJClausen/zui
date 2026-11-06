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

    pub fn eql(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
    }
};

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

    pub fn start(self: Edges, axis: Axis) f32 {
        return if (axis == .x) self.left else self.top;
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
};

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

pub const Border = struct {
    color: Color,
    widths: Edges,
};

/// How an element's size along one axis is decided. A struct with
/// declarations rather than a tagged union, because Zig forbids a field and
/// a declaration of the same name and the helpers keep literals short:
/// `.width = .grow`, `.height = .fixed(48)`.
pub const Sizing = struct {
    rule: Rule = .fit,
    /// fixed: the size. percent: the fraction of the parent's content box (0..1). grow: the weight.
    amount: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.inf(f32),

    pub const Rule = enum(u8) { fit, grow, fixed, percent };

    pub const fit: Sizing = .{};
    pub const grow: Sizing = .{ .rule = .grow, .amount = 1 };

    pub fn fixed(size: f32) Sizing {
        return .{ .rule = .fixed, .amount = size, .min = size, .max = size };
    }

    pub fn percent(fraction: f32) Sizing {
        return .{ .rule = .percent, .amount = fraction };
    }

    pub fn growWeighted(weight: f32) Sizing {
        return .{ .rule = .grow, .amount = weight };
    }

    pub fn fitBetween(min: f32, max: f32) Sizing {
        return .{ .rule = .fit, .min = min, .max = max };
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

pub const Direction = enum(u8) {
    left_to_right,
    top_to_bottom,

    pub fn axis(self: Direction) Axis {
        return if (self == .left_to_right) .x else .y;
    }
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
    padding: Edges = .{},
    child_gap: f32 = 0,
    child_alignment: Alignment2 = .{},
};

pub const Axes = enum(u2) {
    none,
    horizontal,
    vertical,
    both,

    pub fn includes(self: Axes, axis: Axis) bool {
        return self == .both or self == if (axis == .x) Axes.horizontal else Axes.vertical;
    }
};

/// Background, border and corner radius: what an element draws behind and
/// around its children.
pub const Decoration = struct {
    background: ?Color = null,
    border: ?Border = null,
    corner_radius: CornerRadius = .zero,
};

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
    /// Another element, which must be declared earlier in the frame.
    element: Id,
};

/// An element positioned relative to another box instead of its parent's
/// flow. It takes no space in its parent, paints in layer `z`, escapes its
/// ancestors' clipping, and receives the pointer before lower layers.
pub const Floating = struct {
    attach_to: AttachTo = .parent,
    /// The point of the floating element that is placed...
    anchor: AnchorPoint = .top_left,
    /// ...on this point of the box it attaches to.
    attach_point: AnchorPoint = .top_left,
    offset: [2]f32 = .{ 0, 0 },
    z: i16 = 1,
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
    return struct {
        font: FontId = std.mem.zeroes(FontId),
        /// Layout units, not points.
        size: f32 = 16,
        /// Layout units added after each glyph, including the last.
        letter_spacing: f32 = 0,
        /// 0 means the height the text contract measures for the font.
        line_height: f32 = 0,
        color: Color = .black,
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
}
