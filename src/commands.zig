const std = @import("std");
const style = @import("style.zig");

/// A command a renderer may declare in `zui_commands`. Emission lowers the
/// ones it does not declare to base commands, so it never sees them.
pub const OptionalCommand = enum {
    gradient,
    shadow,
    backdrop_blur,
    /// `transform_begin` and `transform_end`.
    transform,
    material,
};

/// `.initMany(&.{ .gradient, .shadow })`
pub const CommandSet = std.EnumSet(OptionalCommand);

/// What a `RenderCommand`'s payload union is generated from.
pub const CommandOptions = struct {
    TextStyle: type,
    /// `void` leaves out the `image` command.
    ImageHandle: type = void,
    /// `void` leaves out the `custom` command.
    CustomData: type = void,
    MaterialHandle: type = void,
    commands: CommandSet = .initEmpty(),
};

pub fn RenderCommand(comptime options: CommandOptions) type {
    return struct {
        bounds: style.Rect,
        /// The element's id hash (internal for elements declared without an id).
        id: u64,
        z: i16 = 0,
        payload: Payload,

        /// The base commands, then `image` and `custom` when their payload
        /// types are set, then each optional command in `commands`, so a
        /// renderer's exhaustive `switch` covers exactly what it draws.
        pub const Payload = GeneratedPayload: {
            const all = [_]struct { name: []const u8, type: type, present: bool }{
                .{ .name = "rectangle", .type = Rectangle, .present = true },
                .{ .name = "border", .type = Border, .present = true },
                .{ .name = "text", .type = Text, .present = true },
                .{ .name = "image", .type = Image, .present = has_image },
                .{ .name = "clip_begin", .type = style.Rect, .present = true },
                .{ .name = "clip_end", .type = void, .present = true },
                .{ .name = "custom", .type = options.CustomData, .present = has_custom },
                .{ .name = "gradient", .type = Gradient, .present = options.commands.contains(.gradient) },
                .{ .name = "shadow", .type = Shadow, .present = options.commands.contains(.shadow) },
                .{ .name = "backdrop_blur", .type = BackdropBlur, .present = options.commands.contains(.backdrop_blur) },
                .{ .name = "transform_begin", .type = Transform, .present = options.commands.contains(.transform) },
                .{ .name = "transform_end", .type = void, .present = options.commands.contains(.transform) },
                .{ .name = "material", .type = Material, .present = options.commands.contains(.material) },
            };
            var names: [all.len][]const u8 = undefined;
            var types: [all.len]type = undefined;
            var count: usize = 0;
            for (all) |variant| {
                if (!variant.present) continue;
                names[count] = variant.name;
                types[count] = variant.type;
                count += 1;
            }
            const Tag = @Enum(u8, .exhaustive, names[0..count], &std.simd.iota(u8, count));
            break :GeneratedPayload @Union(.auto, Tag, names[0..count], types[0..count], &@splat(.{}));
        };

        pub const has_image = options.ImageHandle != void;
        pub const has_custom = options.CustomData != void;
        pub const commands = options.commands;

        pub const Rectangle = struct {
            color: style.Color,
            corner_radius: style.CornerRadius,
        };

        pub const Border = struct {
            color: style.Color,
            widths: style.Edges,
            corner_radius: style.CornerRadius,
        };

        /// One wrapped line. Renderers never wrap text themselves.
        pub const Text = struct {
            content: []const u8,
            style: options.TextStyle,
            line: u32,
        };

        pub const Image = struct {
            handle: options.ImageHandle,
            /// Multiplied into the image's pixels; white leaves them unchanged.
            tint: style.Color = .white,
            corner_radius: style.CornerRadius = .zero,
        };

        /// A linear gradient across the bounds; lowered to a rectangle in
        /// its mean color.
        pub const Gradient = struct {
            from: style.Color,
            to: style.Color,
            /// Radians clockwise from left to right.
            angle: f32 = 0,
            corner_radius: style.CornerRadius = .zero,
        };

        /// A shadow, or a glow when its offset is zero, around the bounds;
        /// lowered to nothing.
        pub const Shadow = struct {
            color: style.Color,
            offset: [2]f32 = .{ 0, 0 },
            blur: f32 = 0,
            spread: f32 = 0,
            corner_radius: style.CornerRadius = .zero,
        };

        /// Blurs what zui drew below, within the bounds; lowered to a
        /// rectangle in `tint`.
        pub const BackdropBlur = struct {
            radius: f32,
            tint: style.Color,
            corner_radius: style.CornerRadius = .zero,
        };

        /// Applies to the commands up to the matching `transform_end`, when
        /// painting only; lowered to the untransformed commands.
        pub const Transform = struct {
            translation: [2]f32 = .{ 0, 0 },
            scale: [2]f32 = .{ 1, 1 },
            rotation: f32 = 0,
            /// A fraction of the bounds: `.{ 0.5, 0.5 }` is the center.
            origin: [2]f32 = .{ 0.5, 0.5 },
        };

        /// The renderer's own shader or material over the bounds; lowered to
        /// a rectangle in `fallback`.
        pub const Material = struct {
            handle: options.MaterialHandle,
            fallback: style.Color,
            corner_radius: style.CornerRadius = .zero,
        };
    };
}

test "a renderer that declares nothing optional switches over the base commands only" {
    const Command = RenderCommand(.{ .TextStyle = style.TextStyle(u16) });
    const fields = @typeInfo(Command.Payload).@"union".fields;
    try std.testing.expectEqual(5, fields.len);
    const command: Command = .{ .bounds = .{}, .id = 0, .payload = .clip_end };
    const name = switch (command.payload) {
        .rectangle => "rectangle",
        .border => "border",
        .text => "text",
        .clip_begin => "clip_begin",
        .clip_end => "clip_end",
    };
    try std.testing.expectEqualStrings("clip_end", name);
}

test "payload types and optional commands add their variants in order" {
    const Command = RenderCommand(.{
        .TextStyle = style.TextStyle(u16),
        .ImageHandle = u32,
        .CustomData = u8,
        .MaterialHandle = u16,
        .commands = .initMany(&.{ .material, .transform }),
    });
    var names: [@typeInfo(Command.Payload).@"union".fields.len][]const u8 = undefined;
    inline for (@typeInfo(Command.Payload).@"union".fields, &names) |field, *name| name.* = field.name;
    const expected = [_][]const u8{ "rectangle", "border", "text", "image", "clip_begin", "clip_end", "custom", "transform_begin", "transform_end", "material" };
    try std.testing.expectEqual(expected.len, names.len);
    for (expected, names) |expected_name, name| try std.testing.expectEqualStrings(expected_name, name);
}
