const std = @import("std");

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

    pub const Rule = enum(u2) { fit, grow, fixed, percent };

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

    pub fn growBetween(min: f32, max: f32) Sizing {
        return .{ .rule = .grow, .amount = 1, .min = min, .max = max };
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

pub const Direction = enum(u1) {
    left_to_right,
    top_to_bottom,

    pub fn axis(self: Direction) Axis {
        return if (self == .left_to_right) .x else .y;
    }
};

pub const Alignment = enum(u2) {
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

pub const ChildAlignment = struct {
    x: Alignment = .start,
    y: Alignment = .start,

    pub fn axis(self: ChildAlignment, which: Axis) Alignment {
        return if (which == .x) self.x else self.y;
    }
};

pub const Layout = struct {
    direction: Direction = .left_to_right,
    sizing: Sizing2 = .{},
    padding: Edges = .{},
    child_gap: f32 = 0,
    child_alignment: ChildAlignment = .{},
};

pub const TextWrap = enum(u2) {
    /// Break between words to fit the element's width, and at newlines.
    words,
    /// Break only at newlines.
    newlines,
    /// Never break; the text is one line.
    none,
};

pub fn TextStyle(comptime FontId: type) type {
    return struct {
        font: FontId = std.mem.zeroes(FontId),
        size: f32 = 16,
        color: Color = .black,
        /// 0 means the height the platform measures for the font.
        line_height: f32 = 0,
        wrap: TextWrap = .words,
        alignment: Alignment = .start,
    };
}

test "Color helpers" {
    try std.testing.expectEqual(Color{ .r = 0x33, .g = 0x66, .b = 0xff }, Color.rgb(0x3366ff));
    try std.testing.expectEqual(Color{ .r = 0x33, .g = 0x66, .b = 0xff, .a = 0x80 }, Color.rgba(0x3366ff80));
    try std.testing.expectEqual(Color{ .r = 128, .g = 128, .b = 128 }, Color.black.mix(.white, 0.5));
}

test "Sizing decl literals" {
    const sizing: Sizing2 = .{ .width = .grow, .height = .fixed(48) };
    try std.testing.expectEqual(Sizing.Rule.grow, sizing.width.rule);
    try std.testing.expectEqual(@as(f32, 48), sizing.axis(.y).amount);
}
