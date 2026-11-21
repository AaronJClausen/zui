//! The tour declaring a frame on `wasm32-freestanding`, as a browser's
//! worker runs it, drawn by a renderer that draws every command.

const std = @import("std");
const zui = @import("zui");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");

const EveryCommandRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_commands: zui.CommandSet = .initFull();
    pub const MaterialHandle = struct {
        pattern: Pattern = .flat,
        first: zui.Color,
        second: zui.Color = .transparent,
        phase: f32 = 0,
        scale: f32 = 48,

        pub const Pattern = enum { flat, waves };
    };

    pub fn zuiSubmit(_: *EveryCommandRenderer, _: zui.Surface, _: anytype) !void {}
};

const kit = zui_tour.Kit(.{ .Renderer = EveryCommandRenderer, .FontSystem = zui_truetype.Text, .inspector = true, .renderer_name = "the browser" });

export fn zuiTourDeclaresEveryScreen() bool {
    declareEveryScreen(std.heap.wasm_allocator, std.Io.failing) catch return false;
    return true;
}

fn declareEveryScreen(gpa: std.mem.Allocator, io: std.Io) !void {
    const text = try gpa.create(kit.Text);
    defer gpa.destroy(text);
    try text.init();
    var ui: kit.Ui = try .init(gpa, io, text);
    defer ui.deinit(gpa);
    const tour = try gpa.create(zui_tour.Tour(kit));
    defer gpa.destroy(tour);
    tour.init(io, .zero, text.fonts);
    defer tour.deinit();

    for (kit.offered_screens) |screen| {
        tour.show(screen);
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1440, 900 } } }, &tour.sources);
        tour.declare(&ui);
        const frame = ui.endFrame();
        tour.observe(&ui, frame);
        tour.afterFrame(&ui);
        ui.release(frame);
    }
}
