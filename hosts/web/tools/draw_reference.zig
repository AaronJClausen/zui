//! ```sh
//! draw-reference <stream path> <reference path> <samples per pixel> <with-text | without-text> <frame number>...
//! ```
//! Draws each frame named with the sokol renderer, keeping only the
//! commands the browser's client draws, and its text only `with-text`, in
//! the fonts the tour added. It writes, little-endian, the length (u32) and
//! bytes of the OpenGL renderer's name that drew them, then for each frame
//! its number (u64), its width and height in pixels (u32 each), and its
//! RGBA pixels, bottom row first, as OpenGL and WebGL read them back.

const std = @import("std");
const zui = @import("zui");
const zui_sokol = @import("zui_sokol");
const zui_wire = @import("zui_wire");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;

/// The tour's frames as the sokol renderer takes them: the stream's, field
/// for field, with the sokol renderer's images and materials.
const kit = zui_tour.Kit(.{ .Renderer = zui_sokol.Renderer, .FontSystem = zui_truetype.Text, .inspector = false, .renderer_name = "the browser" });
const Ui = kit.Ui;
const Command = Ui.RenderCommand;

extern fn glBindTexture(target: c_uint, texture: c_uint) callconv(.c) void;
extern fn glGetTexImage(target: c_uint, level: c_int, format: c_uint, pixel_type: c_uint, pixels: ?*anyopaque) callconv(.c) void;
extern fn glGetString(name: c_uint) callconv(.c) ?[*:0]const u8;
const gl_rgba = 0x1908;
const gl_unsigned_byte = 0x1401;
const gl_renderer = 0x1F01;

/// What the browser's client draws so far.
fn isDrawnInBrowser(command: Command, draws_text: bool) bool {
    return switch (command.payload) {
        .rectangle, .border, .gradient, .shadow, .backdrop_blur, .material, .clip_begin, .clip_end, .transform_begin, .transform_end => true,
        .text => draws_text,
        .image => false,
    };
}

const TextChoice = enum { @"with-text", @"without-text" };

const KeptFrame = struct {
    params: zui.FrameParams,
    kept: []const Command,

    pub fn commands(self: *const KeptFrame) []const Command {
        return self.kept;
    }
};

const Harness = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: []const u8,
    reference_path: []const u8,
    frame_numbers: []const u64,
    samples_per_pixel: i32,
    draws_text: bool,
    text: kit.Text = undefined,
    renderer: zui_sokol.Renderer = undefined,
    outcome: anyerror!void = error.FrameNeverDrawn,

    fn from(userdata: ?*anyopaque) *Harness {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn drawEveryFrameNamed(self: *Harness) !void {
        const reference_file = try std.Io.Dir.cwd().createFile(self.io, self.reference_path, .{});
        defer reference_file.close(self.io);
        var reference_buffer: [64 * 1024]u8 = undefined;
        var reference_writer = reference_file.writer(self.io, &reference_buffer);
        const out = &reference_writer.interface;
        const renderer_name = std.mem.span(glGetString(gl_renderer) orelse return error.NoOpenGlRenderer);
        try out.writeInt(u32, @intCast(renderer_name.len), .little);
        try out.writeAll(renderer_name);

        var decoder: zui_wire.Decoder(Ui) = try .init(self.gpa, .of(Ui));
        defer decoder.deinit(self.gpa);
        const kept = try self.gpa.alloc(Command, Ui.limits.max_render_commands);
        defer self.gpa.free(kept);
        var pixels: std.ArrayList([4]u8) = .empty;
        defer pixels.deinit(self.gpa);

        var reader: std.Io.Reader = .fixed(self.stream);
        try zui_wire.readHeader(&reader, null);
        var next_number: usize = 0;
        while (next_number < self.frame_numbers.len) {
            const message = try decoder.next(&reader) orelse return error.FrameMissing;
            const frame = switch (message) {
                .frame => |frame| frame,
                .record => return error.UnexpectedRecord,
            };
            if (frame.number != self.frame_numbers[next_number]) continue;
            next_number += 1;

            var kept_count: usize = 0;
            for (frame.commands()) |command| if (isDrawnInBrowser(command, self.draws_text)) {
                kept[kept_count] = command;
                kept_count += 1;
            };
            const pixels_per_unit = frame.params.scale * frame.params.zoom;
            const size: [2]u32 = .{ @intFromFloat(@round(frame.params.viewport[0] * pixels_per_unit)), @intFromFloat(@round(frame.params.viewport[1] * pixels_per_unit)) };
            const kept_frame: KeptFrame = .{ .params = frame.params, .kept = kept[0..kept_count] };
            try self.renderer.zuiSubmit(.{ .offscreen = .{ .size = size, .format = .sdr } }, &kept_frame);

            try pixels.resize(self.gpa, size[0] * size[1]);
            const texture = sg.glQueryImageInfo(self.renderer.offscreenImage());
            glBindTexture(texture.tex_target, texture.tex[@intCast(texture.active_slot)]);
            glGetTexImage(texture.tex_target, 0, gl_rgba, gl_unsigned_byte, pixels.items.ptr);
            glBindTexture(texture.tex_target, 0);
            // The texture binding was changed behind sokol_gfx's back.
            sg.resetStateCache();

            try out.writeInt(u64, frame.number, .little);
            try out.writeInt(u32, size[0], .little);
            try out.writeInt(u32, size[1], .little);
            try out.writeAll(std.mem.sliceAsBytes(pixels.items));
        }
        try out.flush();
        if (self.renderer.glyphOverflows() != 0) return error.GlyphAtlasOverflowed;
        const blurs = &self.renderer.backdrop_blurs;
        if (blurs.created and blurs.accumulation_format != .RGBA32F) {
            std.debug.print("draw-reference: this GPU sums backdrop blurs in {t}, not RGBA32F, so they are not comparable with the browser's\n", .{blurs.accumulation_format});
            return error.BlursNotSummedInRgba32f;
        }
    }
};

fn onInit(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *Harness = .from(userdata);
    sg.setup(.{ .environment = sokol.glue.environment(), .logger = .{ .func = sokol.log.func } });
    harness.renderer = .init(&harness.text);
    harness.renderer.offscreen_sample_count = harness.samples_per_pixel;
}

fn onFrame(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *Harness = .from(userdata);
    harness.outcome = harness.drawEveryFrameNamed();
    sapp.requestQuit();
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *Harness = .from(userdata);
    harness.renderer.deinit();
    sg.shutdown();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 6) {
        std.debug.print("expected <stream path> <reference path> <samples per pixel> <with-text | without-text> <frame number>...\n", .{});
        return error.UnknownArgument;
    }
    const samples_per_pixel = try std.fmt.parseInt(i32, arguments[3], 10);
    const text_choice = std.meta.stringToEnum(TextChoice, arguments[4]) orelse return error.UnknownArgument;
    const frame_numbers = try arena.alloc(u64, arguments.len - 5);
    for (arguments[5..], frame_numbers) |argument, *number| number.* = try std.fmt.parseInt(u64, argument, 10);
    if (!std.sort.isSorted(u64, frame_numbers, {}, std.sort.asc(u64))) return error.FrameNumbersOutOfOrder;

    const stream = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], arena, .unlimited);
    const harness = try arena.create(Harness);
    harness.* = .{
        .gpa = init.gpa,
        .io = init.io,
        .stream = stream,
        .reference_path = arguments[2],
        .frame_numbers = frame_numbers,
        .samples_per_pixel = samples_per_pixel,
        .draws_text = text_choice == .@"with-text",
    };
    try harness.text.init();
    defer harness.text.deinit();
    sapp.run(.{
        .init_userdata_cb = onInit,
        .frame_userdata_cb = onFrame,
        .cleanup_userdata_cb = onCleanup,
        .user_data = harness,
        .width = 64,
        .height = 64,
        .high_dpi = false,
        .window_title = "zui-web reference",
        .logger = .{ .func = sokol.log.func },
    });
    return harness.outcome;
}
