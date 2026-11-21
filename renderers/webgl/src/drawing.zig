const std = @import("std");
const zui = @import("zui");

/// What the browser's drawing draws, declared as a renderer declares it, so
/// that an application whose frames a page draws configures its context
/// for it, on `wasm32-freestanding` as natively:
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_webgl.Drawing, .{ .Text = zui_truetype.Text }));
/// ```
///
/// It submits nothing itself: its frames reach the page over `zui_wire`,
/// where a `DrawList` lays them out.
pub const Drawing = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.web);
    pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });
    pub const zui_extended_color = true;
    pub const ImageHandle = Image;
    pub const MaterialHandle = Material;

    /// Frames are drawn by the page, not here.
    pub fn zuiSubmit(_: *Drawing, _: zui.Surface, _: anytype) error{UnsupportedSurface}!void {
        return error.UnsupportedSurface;
    }
};

/// A texture by the ids of a view and a sampler, as the sokol renderer
/// names one. The page does not draw images yet.
pub const Image = struct {
    view: Id,
    sampler: Id,

    pub const Id = struct { id: u32 = 0 };
};

/// A pattern between two colors, drawn by its own shader over the element,
/// in its corners, as the sokol renderer's materials are.
///
/// ```zig
/// ui.open(.{ .decoration = .{
///     .background = .rgb(0x1a3050),
///     .material = .{ .pattern = .aurora, .first = .rgb(0x10304a), .second = .rgb(0x40e0a0), .phase = seconds / 8 },
///     .corner_radius = .all(12),
/// } });
/// ```
pub const Material = struct {
    pattern: Pattern = .solid,
    first: zui.Color,
    second: zui.Color = .transparent,
    /// Where the pattern is in its cycle, in turns; a pattern moves as its
    /// phase grows, and repeats each whole turn.
    phase: f32 = 0,
    /// The width of one wave of `aurora`, in layout units.
    scale: f32 = 48,

    pub const Pattern = enum(u8) {
        /// `first` alone.
        solid,
        /// `first` with a soft band of `second` sweeping across it from the
        /// top left to the bottom right once per turn of the phase.
        sheen,
        /// `first` and `second` flowing into each other in waves.
        aurora,
    };
};

test "a context configured for the drawing declares exactly the commands it draws" {
    const Ui = zui.Context(.{
        .commands = Drawing.zui_commands,
        .extended_color = Drawing.zui_extended_color,
        .ImageHandle = Drawing.ImageHandle,
        .MaterialHandle = Drawing.MaterialHandle,
        .limits = .{ .max_elements = 8 },
    });
    const Payload = Ui.RenderCommand.Payload;
    inline for (.{ "gradient", "shadow", "backdrop_blur", "transform_begin", "transform_end", "material", "image" }) |command| try std.testing.expect(@hasField(Payload, command));
    comptime zui.checkRenderer(Drawing);
}
