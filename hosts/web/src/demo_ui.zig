const zui = @import("zui");

/// A context whose frames have the shape of zui-sokol's tour's: the same
/// commands, colors and payload types, field for field, so the browser
/// decodes the tour's stream without building sokol, and whose records the
/// tour reads, since it has sources. `zig build test-demo` checks that
/// every frame of the tour decodes to what it drew, and `zig build
/// test-input` that the tour takes the records the browser writes.
pub const DemoUi = zui.Context(.{
    .Sources = DemoSources,
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

/// A record from the browser is live, and a live record writes no
/// deliveries, whatever sources a context has: so a source that delivers
/// nothing stands in for the tour's.
pub const DemoSources = struct {
    tour: NothingDelivered = .{},

    pub const NothingDelivered = struct {
        pub const Delivery = void;
        pub const View = void;

        pub fn zuiSwap(_: *NothingDelivered) void {}
        pub fn zuiView(_: *NothingDelivered) void {}
        pub fn zuiDelivery(_: *const NothingDelivered, _: *void) void {}
        pub fn zuiInject(_: *NothingDelivered, _: *const void) void {}
    };
};
