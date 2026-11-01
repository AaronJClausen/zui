const style = @import("style.zig");

pub fn RenderCommand(comptime TextStyle: type, comptime ImageHandle: type, comptime CustomData: type) type {
    return struct {
        bounds: style.Rect,
        /// The element's id hash (internal for elements declared without an id).
        id: u64,
        z: i16 = 0,
        payload: Payload,

        pub const Payload = union(enum) {
            rectangle: Rectangle,
            border: Border,
            text: Text,
            image: ImageHandle,
            clip_begin: style.Rect,
            clip_end,
            custom: CustomData,
        };

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
            style: TextStyle,
            line: u32,
        };
    };
}
