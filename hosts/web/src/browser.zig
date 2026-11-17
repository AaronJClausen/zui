const std = @import("std");
const DemoUi = @import("demo_ui.zig").DemoUi;
const DrawList = @import("draw_list.zig").DrawList;
const Text = @import("text.zig").Text;

pub const DemoStream = @import("frame_stream.zig").FrameStream(DemoUi);

pub var stream: DemoStream = undefined;
/// The frame decoded last, which is the one to draw.
pub var newest: ?*const DemoStream.Frame = null;
var draw_list: DrawList = undefined;
var text: Text = undefined;
var bitmap_font_rows: [Text.bitmap_font_bytes]u8 = undefined;
var last_error: ?anyerror = null;

/// Reserves the client's memory. False when the browser has too little.
/// The fonts the stream's text uses are handed over before its first
/// frame, with `zuiWebLoadBitmapFonts` and `zuiWebAddTrueTypeFont`.
///
/// ```js
/// wasm.zuiWebInit();
/// for (const font of [regularTtf, boldTtf]) {
///   new Uint8Array(wasm.memory.buffer, wasm.zuiWebRoomForFont(font.length), font.length).set(font);
///   wasm.zuiWebAddTrueTypeFont(font.length);
/// }
/// socket.onmessage = ({ data }) => {
///   const bytes = new Uint8Array(data);
///   const room = wasm.zuiWebRoomFor(bytes.length);
///   new Uint8Array(wasm.memory.buffer, room, bytes.length).set(bytes);
///   wasm.zuiWebReceived(bytes.length);
///   while (wasm.zuiWebNextFrame() > 0) {}
///   drawer.draw(); // FrameDrawer, from web/frame_drawer.mjs
/// };
/// ```
export fn zuiWebInit() bool {
    stream = DemoStream.init(std.heap.wasm_allocator, .{}) catch |err| {
        last_error = err;
        return false;
    };
    draw_list = DrawList.init(std.heap.wasm_allocator) catch |err| {
        last_error = err;
        return false;
    };
    text = Text.init(std.heap.wasm_allocator) catch |err| {
        last_error = err;
        return false;
    };
    return true;
}

/// Where to write sokol_debugtext's six fonts, `Text.bitmap_font_bytes`
/// of them laid out as `Text.bitmap_font_bytes` says, before
/// `zuiWebLoadBitmapFonts`.
export fn zuiWebBitmapFontRows() usize {
    return @intFromPtr(&bitmap_font_rows);
}

/// Unpacks the bitmap fonts written to `zuiWebBitmapFontRows` into
/// `zuiWebBitmapGlyphTexels`. Until then, bitmap text is not drawn.
export fn zuiWebLoadBitmapFonts() void {
    text.loadBitmapFonts(&bitmap_font_rows);
}

/// `Text.bitmap_texture_width` × `Text.bitmap_texture_height` bytes, one
/// a texel, for an R8 texture sampled at the nearest texel.
export fn zuiWebBitmapGlyphTexels() usize {
    return @intFromPtr(text.bitmap_glyph_texels.ptr);
}

/// Where to write the next TrueType font's `count` bytes, or 0 when they
/// do not fit.
export fn zuiWebRoomForFont(count: usize) usize {
    const room = text.roomForFont(count) orelse return 0;
    return @intFromPtr(room.ptr);
}

/// Adds the TrueType font written to `zuiWebRoomForFont`, returning its
/// `FontId`, which follows the six bitmap fonts' and those added before
/// it, or -1 when it cannot be read, as `zuiWebErrorName` says.
export fn zuiWebAddTrueTypeFont(count: usize) i32 {
    const font = text.addTrueTypeFont(count) catch |err| {
        last_error = err;
        return -1;
    };
    return font;
}

/// The glyph atlas's texels, `GlyphAtlas.side` squared pairs of bytes for
/// an RG8 texture sampled linearly, when they changed since this was last
/// asked, or else 0.
export fn zuiWebGlyphAtlasTexelsIfChanged() usize {
    if (!text.atlas.changed) return 0;
    text.atlas.changed = false;
    return @intFromPtr(&text.atlas.texels);
}

/// Since `zuiWebInit`, how often a frame left glyphs out because the atlas
/// was full, or stb_truetype ran out of memory rasterizing one.
export fn zuiWebGlyphOverflows() u32 {
    return text.glyph_overflows + text.scratch.refusals;
}

/// Where to write the next `count` bytes of the stream, or 0 when they do
/// not fit until frames are taken with `zuiWebNextFrame`.
export fn zuiWebRoomFor(count: usize) usize {
    const room = stream.roomFor(count) catch |err| {
        last_error = err;
        return 0;
    };
    return @intFromPtr(room.ptr);
}

export fn zuiWebReceived(count: usize) void {
    stream.received(count);
}

/// 1 when another frame was decoded, 0 until more of the stream arrives,
/// -1 when the stream cannot be read, as `zuiWebErrorName` says.
export fn zuiWebNextFrame() i32 {
    newest = (stream.nextFrame() catch |err| {
        last_error = err;
        return -1;
    }) orelse return 0;
    return 1;
}

export fn zuiWebFrameNumber() u64 {
    return if (newest) |frame| frame.number else 0;
}

export fn zuiWebCommandCount() usize {
    return if (newest) |frame| frame.commands().len else 0;
}

/// The last failure, as a C string, or an empty one.
export fn zuiWebErrorName() [*:0]const u8 {
    return if (last_error) |err| @errorName(err) else "";
}

/// Lays the newest frame out for drawing, returning how many batches it
/// takes: `zuiWebBatches` holds them, each a `DrawList.Batch`, and
/// `zuiWebVertices` the vertices they draw, each a `DrawList.Vertex`. Its
/// glyphs are added to the atlas first.
export fn zuiWebLayOutNewestFrame() u32 {
    const frame = newest orelse {
        draw_list.vertex_count = 0;
        draw_list.batch_count = 0;
        return 0;
    };
    draw_list.layOut(frame.commands(), frame.params, &text);
    return draw_list.batch_count;
}

export fn zuiWebBatches() usize {
    return @intFromPtr(draw_list.batch_storage.ptr);
}

export fn zuiWebVertices() usize {
    return @intFromPtr(draw_list.vertex_storage.ptr);
}

export fn zuiWebVertexCount() u32 {
    return draw_list.vertex_count;
}

/// The newest frame's viewport, in layout units.
export fn zuiWebViewportWidth() f32 {
    return if (newest) |frame| frame.params.viewport[0] else 0;
}

export fn zuiWebViewportHeight() f32 {
    return if (newest) |frame| frame.params.viewport[1] else 0;
}

/// Physical pixels per layout unit in the newest frame, its scale times
/// its zoom.
export fn zuiWebPixelsPerUnit() f32 {
    return if (newest) |frame| frame.params.scale * frame.params.zoom else 1;
}

/// Since `zuiWebInit`, how often a frame left a shape out, or drew a clip
/// or transform as its parent, because the draw list was full.
export fn zuiWebDrawListOverflows() u32 {
    return draw_list.vertex_overflows + draw_list.batch_overflows + draw_list.transform_overflows;
}
