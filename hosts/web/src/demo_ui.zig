const zui = @import("zui");
const Drawing = @import("zui_webgl").Drawing;

/// A context whose frames have the shape of the tour's as the browser draws
/// them: the commands, colors and payload types `zui_webgl.Drawing`
/// declares, so the browser decodes the tour's stream, and whose records
/// the tour reads, since it has sources. `zig build test-demo` checks that
/// every frame of the tour decodes to what it drew, and `zig build
/// test-input` that the tour takes the records the browser writes.
pub const DemoUi = zui.Context(.{
    .Sources = DemoSources,
    .limits = .{ .max_render_commands = 32768, .max_text_bytes = 256 * 1024 },
    .commands = Drawing.zui_commands,
    .extended_color = Drawing.zui_extended_color,
    .ImageHandle = Drawing.ImageHandle,
    .MaterialHandle = Drawing.MaterialHandle,
});

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
