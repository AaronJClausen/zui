const zui = @import("zui");

/// A context whose frames have the shape of zui-sokol's tour's: the same
/// commands, colors and payload types, field for field, so the browser
/// decodes the tour's stream without building sokol. `zig build test-demo`
/// checks that every frame of the tour decodes to what it drew.
pub const DemoUi = zui.Context(.{
    .limits = .{ .max_render_commands = 32768, .max_text_bytes = 256 * 1024 },
    .commands = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material }),
    .extended_color = true,
    .ImageHandle = Image,
    .MaterialHandle = Material,
});

/// zui-sokol's `Image`: the ids of a sokol_gfx view and sampler, which mean
/// nothing in the browser.
pub const Image = struct {
    view: SokolId,
    sampler: SokolId,

    pub const SokolId = struct { id: u32 = 0 };
};

/// zui-sokol's `Material`: a pattern between two colors, moving with its
/// phase.
pub const Material = struct {
    pattern: Pattern = .solid,
    first: zui.Color,
    second: zui.Color = .transparent,
    /// In turns; the pattern repeats each whole turn.
    phase: f32 = 0,
    /// The width of one wave of `aurora`, in layout units.
    scale: f32 = 48,

    pub const Pattern = enum(u8) { solid, sheen, aurora };
};
