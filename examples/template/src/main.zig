const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_truetype = @import("zui_truetype");
const Counter = @import("counter.zig").Counter;

const Ui = zui.Context(zui_app.contextConfig(SokolRenderer, .{ .Text = zui_truetype.Text }));

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "zui template", .size = .{ 480, 320 } });
}

const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_truetype.Text;

    counter: Counter(Ui) = .{},
    host: *Host = undefined,
    /// Set by `--frames <count>`, which closes the window after that many frames.
    frame_limit: ?u32 = null,
    frames_drawn: u32 = 0,

    pub fn init(app: *App, start: zui_app.Start(App)) !void {
        app.host = start.host;
        try app.counter.addFonts(start.text);
        if (start.process) |process| app.frame_limit = try frameLimitFrom(process);
    }

    pub fn zuiDeclare(app: *App, ui: *Ui) void {
        app.counter.declare(ui);
    }

    pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
        const limit = app.frame_limit orelse return;
        app.frames_drawn += 1;
        if (app.frames_drawn >= limit) app.host.close() else app.host.zuiWaker().wake();
    }
};

fn frameLimitFrom(process: std.process.Init) !?u32 {
    const arguments = try process.minimal.args.toSlice(process.arena.allocator());
    if (arguments.len == 1) return null;
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--frames")) return try std.fmt.parseInt(u32, arguments[2], 10);
    std.debug.print("expected no arguments, or --frames <count>\n", .{});
    return error.UnknownArgument;
}

/// The sokol renderer, opened on the host's window as `zui_app` opens a
/// renderer.
const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const zui_commands = zui_sokol.Renderer.zui_commands;
    pub const zui_corner_shapes = zui_sokol.Renderer.zui_corner_shapes;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;
    pub const MaterialHandle = zui_sokol.Renderer.MaterialHandle;

    sokol: zui_sokol.Renderer,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: anytype) !void {
        self.sokol = try .initForSurface(text, surface);
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        try self.sokol.zuiSubmit(surface, frame);
    }
};
