//! zui's default font system: the text contract on stb_truetype, laying
//! text out through `zui_glyphs`, so a renderer draws each glyph where it
//! was measured.

const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const zui_fonts = @import("zui_fonts");
const FontId = zui_glyphs.FontId;
const GlyphId = zui_glyphs.GlyphId;
const FontMetrics = zui_glyphs.FontMetrics;
const GlyphBox = zui_glyphs.GlyphBox;

pub const Face = @import("face.zig").Face;

/// The text contract on TrueType fonts. `FontId` 0, 1, … are the fonts in
/// the order `addFont` added them; given none, font 0 is Atkinson
/// Hyperlegible Regular, the only font then embedded. Text is laid out for
/// `placement`, which is the placement of the renderer that draws it.
/// Measuring and rasterizing only read the fonts, so zui may measure on
/// several threads while a renderer draws; add every font before the first
/// frame. Nothing here allocates: a renderer's atlas holds the scratch a
/// glyph is rasterized with.
///
/// ```zig
/// var text: zui_truetype.Text = .{ .placement = zui_glyphs.placementOf(Renderer) };
/// const body = try text.addFont(zui_fonts.atkinson_hyperlegible_regular);
/// const bold = try text.addFont(zui_fonts.atkinson_hyperlegible_bold);
/// var ui: Ui = try .init(gpa, io, &text);
/// ui.text("Hello", .{ .font = bold, .size = 18 });
/// ```
pub const Text = struct {
    pub const max_fonts = 8;
    pub const zui_thread_safe = true;

    placement: zui_glyphs.Placement = .pixel_grid,
    faces: [max_fonts]Face = undefined,
    face_count: u8 = 0,

    /// Returns the font's `FontId`. `data` is the font file's bytes, which
    /// must outlive the `Text`: an `@embedFile`, such as one of
    /// `zui_fonts`', or memory reserved for fonts that arrive at run time.
    pub fn addFont(self: *Text, data: []const u8) error{ InvalidFont, TooManyFonts }!FontId {
        if (self.face_count == max_fonts) return error.TooManyFonts;
        self.faces[self.face_count] = try .init(data);
        self.face_count += 1;
        return self.face_count - 1;
    }

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(FontId)) [2]f32 {
        return zui_glyphs.measure(self, run, key, self.placement) orelse .{ 0, key.size };
    }

    /// Covers every font's bytes, in order, and the placement, which is all
    /// that changes a measurement.
    pub fn zuiFingerprint(self: *const Text) u64 {
        if (self.face_count == 0) return fingerprintOf(self.placement, &.{defaultFace().content_hash});
        return self.addedFontsFingerprint();
    }

    /// `zuiFingerprint` of the fonts added, for a text that never measures
    /// in the default font.
    pub fn addedFontsFingerprint(self: *const Text) u64 {
        var hashes: [max_fonts]u64 = undefined;
        for (self.faces[0..self.face_count], hashes[0..self.face_count]) |*added, *hash| hash.* = added.content_hash;
        return fingerprintOf(self.placement, hashes[0..self.face_count]);
    }

    /// The face of a font `addFont` added, ignoring the default.
    pub fn addedFace(self: *const Text, font: FontId) ?*const Face {
        return if (font < self.face_count) &self.faces[font] else null;
    }

    fn face(self: *const Text, font: FontId) ?*const Face {
        if (self.face_count == 0 and font == 0) return defaultFace();
        return self.addedFace(font);
    }

    pub fn fontMetrics(self: *const Text, font: FontId) ?FontMetrics {
        return if (self.face(font)) |found| found.metrics else null;
    }

    pub fn advance(self: *const Text, font: FontId, codepoint: u21) f32 {
        return self.face(font).?.advance(codepoint);
    }

    pub fn glyphIndex(self: *const Text, font: FontId, codepoint: u21) GlyphId {
        return self.face(font).?.glyphIndex(codepoint);
    }

    pub fn glyphBox(self: *const Text, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox {
        return self.face(font).?.glyphBox(glyph, pixel_size);
    }

    pub fn rasterize(self: *const Text, font: FontId, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool {
        return self.face(font).?.rasterize(glyph, pixel_size, box, coverage, stride, scratch);
    }
};

fn fingerprintOf(placement: zui_glyphs.Placement, content_hashes: []const u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&.{@intFromEnum(placement)});
    if (placement == .cells) for (placement.cells) |side| hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(side))));
    for (content_hashes) |hash| hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, hash)));
    return hasher.final();
}

var default_face: Face = undefined;
var default_face_state: std.atomic.Value(enum(u8) { absent, preparing, ready }) = .init(.absent);

/// Read on first use, by whichever thread measures first.
fn defaultFace() *const Face {
    if (default_face_state.load(.acquire) == .ready) return &default_face;
    if (default_face_state.cmpxchgStrong(.absent, .preparing, .acquire, .acquire) == null) {
        default_face = Face.init(zui_fonts.atkinson_hyperlegible_regular) catch unreachable;
        default_face_state.store(.ready, .release);
    } else while (default_face_state.load(.acquire) != .ready) std.atomic.spinLoopHint();
    return &default_face;
}

fn measure(text: *Text, run: []const u8, font: FontId, letter_spacing: f32) [2]f32 {
    return text.zuiMeasure(run, .{ .font = font, .size = 16, .letter_spacing = letter_spacing });
}

test "given no fonts, text is measured in Atkinson Hyperlegible Regular as font 0" {
    var default: Text = .{};
    var added: Text = .{};
    try std.testing.expectEqual(0, try added.addFont(zui_fonts.atkinson_hyperlegible_regular));
    try std.testing.expectEqual(measure(&added, "Hello", 0, 0), measure(&default, "Hello", 0, 0));
    try std.testing.expectEqual(added.zuiFingerprint(), default.zuiFingerprint());
    try std.testing.expectEqual([2]f32{ 0, 16 }, measure(&default, "Hello", 1, 0));
}

test "fonts measure proportionally, in the order they were added" {
    var text: Text = .{};
    const bold = try text.addFont(zui_fonts.atkinson_hyperlegible_bold);
    const mono = try text.addFont(zui_fonts.liberation_mono_regular);
    try std.testing.expectEqual(.{ 0, 1 }, .{ bold, mono });
    try std.testing.expect(measure(&text, "iiii", bold, 0)[0] < measure(&text, "WWWW", bold, 0)[0]);
    try std.testing.expectEqual(measure(&text, "iiii", mono, 0)[0], measure(&text, "WWWW", mono, 0)[0]);
    try std.testing.expectEqual(text.fontMetrics(bold).?.lineHeight(16), measure(&text, "Hello", bold, 0)[1]);
}

test "measurement is additive, with letter spacing after every glyph" {
    var text: Text = .{};
    const one = measure(&text, "one", 0, 2);
    const space = measure(&text, " ", 0, 2);
    const two = measure(&text, "two", 0, 2);
    try std.testing.expectApproxEqAbs(measure(&text, "one two", 0, 2)[0], one[0] + space[0] + two[0], 1e-4);
    try std.testing.expectApproxEqAbs(measure(&text, "one", 0, 0)[0] + 3 * 2, one[0], 1e-4);
}

test "the fonts conform, on the pixel grid and in cells" {
    var text: Text = .{};
    _ = try text.addFont(zui_fonts.atkinson_hyperlegible_regular);
    try zui_glyphs.expectFontsConform(&text, std.testing.allocator);
    var in_cells: Text = .{ .placement = .{ .cells = .{ 8, 16 } } };
    try zui_glyphs.expectFontsConform(&in_cells, std.testing.allocator);
    try std.testing.expectEqual([2]f32{ 5 * 8, 16 }, measure(&in_cells, "Hello", 0, 0));
}

test "the fingerprint tells fonts, their order and the placement apart" {
    var regular_then_bold: Text = .{};
    _ = try regular_then_bold.addFont(zui_fonts.atkinson_hyperlegible_regular);
    _ = try regular_then_bold.addFont(zui_fonts.atkinson_hyperlegible_bold);
    var bold_then_regular: Text = .{};
    _ = try bold_then_regular.addFont(zui_fonts.atkinson_hyperlegible_bold);
    _ = try bold_then_regular.addFont(zui_fonts.atkinson_hyperlegible_regular);
    var in_cells = regular_then_bold;
    in_cells.placement = .{ .cells = .{ 8, 16 } };
    var regular: Text = .{};
    _ = try regular.addFont(zui_fonts.atkinson_hyperlegible_regular);
    const fingerprints = [_]u64{ regular_then_bold.zuiFingerprint(), bold_then_regular.zuiFingerprint(), in_cells.zuiFingerprint(), regular.zuiFingerprint() };
    for (fingerprints, 0..) |fingerprint, index| for (fingerprints[0..index]) |earlier| try std.testing.expect(fingerprint != earlier);
    try std.testing.expectEqual(regular_then_bold.zuiFingerprint(), regular_then_bold.addedFontsFingerprint());
}

test "bytes that are not a font are refused, and a ninth font finds no room" {
    var text: Text = .{};
    try std.testing.expectError(error.InvalidFont, text.addFont("GET / HTTP/1.1\r\n" ++ [_]u8{0} ** 64));
    for (0..Text.max_fonts) |_| _ = try text.addFont(zui_fonts.atkinson_hyperlegible_regular);
    try std.testing.expectError(error.TooManyFonts, text.addFont(zui_fonts.atkinson_hyperlegible_regular));
}

test "a glyph is rasterized from the atlas's scratch, so nothing is allocated after it is made" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const atlas = try zui_glyphs.Atlas(.rgba8).create(failing.allocator());
    defer atlas.destroy(failing.allocator());
    var text: Text = .{};
    const fonts = zui_glyphs.Fonts.of(&text);
    for ("Hamburgefonstiv \u{e9}") |byte| _ = try atlas.findOrAdd(fonts, .{ .font = 0, .pixel_size = zui_glyphs.max_pixel_size, .codepoint = byte });
    try std.testing.expectEqual(0, atlas.raster_refusals);
    try std.testing.expectEqual(1, failing.allocations);
}

test "the text contract is zui's" {
    const Ui = zui.Context(.{ .Text = Text, .limits = .{ .max_elements = 8 } });
    var text: Text = .{};
    const io = if (@import("builtin").os.tag == .freestanding) std.Io.failing else std.testing.io;
    var ui: Ui = try .init(std.testing.allocator, io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 200, 100 } } });
    ui.text("Hello", .{});
    const frame = ui.endFrame();
    defer ui.release(frame);
    try std.testing.expect(frame.diagnostics.ok());
}
