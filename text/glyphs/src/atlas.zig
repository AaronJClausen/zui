const std = @import("std");
const fonts_ = @import("fonts.zig");
const FontId = fonts_.FontId;
const pixel_grid = @import("pixel_grid.zig");
const Codepoints = @import("codepoints.zig").Codepoints;

/// How an atlas holds a texel, as the renderer's texture does.
pub const TexelLayout = enum {
    /// Four bytes: white, with the coverage in alpha, so a vertex color
    /// tints it. Between glyphs, all four are 0.
    rgba8,
    /// Two bytes: 255 inside a glyph and 0 between glyphs, then the
    /// coverage.
    rg8,

    pub fn Texel(comptime layout: TexelLayout) type {
        return switch (layout) {
            .rgba8 => [4]u8,
            .rg8 => [2]u8,
        };
    }

    fn inside(comptime layout: TexelLayout, coverage: u8) Texel(layout) {
        return switch (layout) {
            .rgba8 => .{ 255, 255, 255, coverage },
            .rg8 => .{ 255, coverage },
        };
    }
};

/// Glyphs rasterized on first use and packed into rows of one square
/// image, `side` texels wide, in the texels the renderer's texture takes.
/// Every byte it uses, stb_truetype's or another rasterizer's scratch
/// among them, is reserved by `create`; when it fills up, it starts over
/// empty.
///
/// ```zig
/// const atlas: *zui_glyphs.Atlas(.rgba8) = try .create(gpa);
/// // Each frame, before drawing it:
/// atlas.addFrameGlyphs(fonts, frame.commands(), pixels_per_unit);
/// if (atlas.changed) upload(&atlas.texels);
/// atlas.changed = false;
/// ```
pub fn Atlas(comptime texel_layout: TexelLayout) type {
    return struct {
        const Self = @This();

        pub const Texel = texel_layout.Texel();
        pub const side = 1024;
        /// Glyphs reach above the ascent and below the descent, so a raster
        /// may be taller than its pixel size.
        pub const max_raster_side = pixel_grid.max_pixel_size * 2;
        pub const scratch_bytes = 256 * 1024;
        const slot_count = 4096;
        const padding = 1;

        pub const Key = struct {
            font: FontId,
            pixel_size: u16,
            codepoint: u21,

            fn hash(key: Key) u64 {
                const packed_key = (@as(u64, key.font) << 48) | (@as(u64, key.pixel_size) << 32) | key.codepoint;
                return std.hash.int(packed_key);
            }
        };

        pub const Glyph = struct {
            x: u16 = 0,
            y: u16 = 0,
            width: u16 = 0,
            height: u16 = 0,
            /// From the pen on the baseline to the top-left corner, in pixels.
            offset: [2]i16 = .{ 0, 0 },
        };

        const Slot = struct { key: Key, glyph: Glyph };

        texels: [side * side]Texel,
        slots: [slot_count]?Slot,
        glyph_count: u32,
        shelf_x: u32,
        shelf_y: u32,
        shelf_height: u32,
        coverage: [max_raster_side * max_raster_side]u8,
        scratch: [scratch_bytes]u8 align(16),
        /// The texels changed since the renderer last uploaded them; it
        /// clears this.
        changed: bool,
        /// Frames that needed more glyphs than the atlas holds; the ones
        /// that did not fit were left out.
        overflows: u32,
        /// Glyphs left blank because the rasterizer ran out of scratch.
        raster_refusals: u32,

        pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!*Self {
            const atlas = try gpa.create(Self);
            atlas.overflows = 0;
            atlas.raster_refusals = 0;
            atlas.reset();
            return atlas;
        }

        pub fn destroy(self: *Self, gpa: std.mem.Allocator) void {
            gpa.destroy(self);
        }

        pub fn reset(self: *Self) void {
            @memset(&self.texels, std.mem.zeroes(Texel));
            self.slots = @splat(null);
            self.glyph_count = 0;
            self.shelf_x = 0;
            self.shelf_y = 0;
            self.shelf_height = 0;
            self.changed = true;
        }

        pub fn find(self: *const Self, key: Key) ?Glyph {
            var index: usize = @intCast(key.hash() % slot_count);
            while (self.slots[index]) |slot| : (index = (index + 1) % slot_count) {
                if (std.meta.eql(slot.key, key)) return slot.glyph;
            }
            return null;
        }

        /// The glyph, rasterized from `fonts` and packed first if it is new.
        pub fn findOrAdd(self: *Self, fonts: anytype, key: Key) error{Full}!Glyph {
            if (self.find(key)) |glyph| return glyph;
            if (self.glyph_count * 4 >= slot_count * 3) return error.Full;
            const glyph_index = fonts.glyphIndex(key.font, key.codepoint);
            const pixel_size: f32 = @floatFromInt(key.pixel_size);
            const box = fonts.glyphBox(key.font, glyph_index, pixel_size);
            if (box.width > max_raster_side or box.height > max_raster_side) return error.Full;
            var glyph: Glyph = .{
                .width = @intCast(box.width),
                .height = @intCast(box.height),
                .offset = .{ @intCast(box.offset[0]), @intCast(box.offset[1]) },
            };
            if (box.width != 0 and box.height != 0) {
                const position = try self.place(box.width, box.height);
                glyph.x = @intCast(position[0]);
                glyph.y = @intCast(position[1]);
                @memset(self.coverage[0 .. box.width * box.height], 0);
                if (!fonts.rasterize(key.font, glyph_index, pixel_size, box, &self.coverage, box.width, &self.scratch)) self.raster_refusals += 1;
                self.copyCoverage(glyph);
                self.changed = true;
            }
            self.insert(key, glyph);
            return glyph;
        }

        /// Rasterizes every glyph that `commands`' text in `fonts` needs
        /// before any is drawn, so the texels are uploaded at most once a
        /// frame. If the atlas fills up, it starts over with only this
        /// frame's glyphs.
        pub fn addFrameGlyphs(self: *Self, fonts: anytype, commands: anytype, pixels_per_unit: f32) void {
            self.addGlyphs(fonts, commands, pixels_per_unit) catch {
                self.reset();
                self.addGlyphs(fonts, commands, pixels_per_unit) catch {
                    self.overflows += 1;
                };
            };
        }

        fn addGlyphs(self: *Self, fonts: anytype, commands: anytype, pixels_per_unit: f32) error{Full}!void {
            for (commands) |command| switch (command.payload) {
                .text => |line| if (fonts.fontMetrics(line.style.font) != null) {
                    const pixel_size = pixel_grid.rasterPixelSize(line.style.size, pixels_per_unit);
                    var codepoints = Codepoints.init(line.content);
                    while (codepoints.next()) |codepoint| {
                        _ = try self.findOrAdd(fonts, .{ .font = line.style.font, .pixel_size = pixel_size, .codepoint = codepoint });
                    }
                },
                else => {},
            };
        }

        fn place(self: *Self, width: u32, height: u32) error{Full}![2]u32 {
            if (self.shelf_x + width + padding > side) {
                self.shelf_y += self.shelf_height + padding;
                self.shelf_x = 0;
                self.shelf_height = 0;
            }
            if (self.shelf_y + height + padding > side) return error.Full;
            const position: [2]u32 = .{ self.shelf_x + padding, self.shelf_y + padding };
            self.shelf_x += width + padding;
            self.shelf_height = @max(self.shelf_height, height + padding);
            return position;
        }

        fn copyCoverage(self: *Self, glyph: Glyph) void {
            for (0..glyph.height) |row| {
                for (0..glyph.width) |column| {
                    self.texels[(@as(usize, glyph.y) + row) * side + glyph.x + column] = texel_layout.inside(self.coverage[row * glyph.width + column]);
                }
            }
        }

        fn insert(self: *Self, key: Key, glyph: Glyph) void {
            var index: usize = @intCast(key.hash() % slot_count);
            while (self.slots[index] != null) index = (index + 1) % slot_count;
            self.slots[index] = .{ .key = key, .glyph = glyph };
            self.glyph_count += 1;
        }
    };
}

const BoxFonts = @import("box_fonts.zig").BoxFonts;
const Fonts = fonts_.Fonts;

test "a full atlas refuses new glyphs and starts over empty after reset" {
    const atlas = try Atlas(.rg8).create(std.testing.allocator);
    defer atlas.destroy(std.testing.allocator);
    var placed: u32 = 0;
    while (atlas.place(100, 100)) |_| placed += 1 else |_| {}
    try std.testing.expectEqual(@as(u32, 100), placed);
    atlas.reset();
    try std.testing.expectEqual([2]u32{ 1, 1 }, try atlas.place(100, 100));
}

test "a glyph is rasterized once, into texels of the layout asked for" {
    const atlas = try Atlas(.rgba8).create(std.testing.allocator);
    defer atlas.destroy(std.testing.allocator);
    const fonts = Fonts.of(&BoxFonts{});
    atlas.changed = false;
    const glyph = try atlas.findOrAdd(fonts, .{ .font = 0, .pixel_size = 20, .codepoint = 'W' });
    try std.testing.expect(atlas.changed);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, atlas.texels[@as(usize, glyph.y) * 1024 + glyph.x]);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, atlas.texels[0]);
    atlas.changed = false;
    try std.testing.expectEqual(glyph, try atlas.findOrAdd(fonts, .{ .font = 0, .pixel_size = 20, .codepoint = 'W' }));
    try std.testing.expect(!atlas.changed);
    const space = try atlas.findOrAdd(fonts, .{ .font = 0, .pixel_size = 20, .codepoint = ' ' });
    try std.testing.expectEqual(0, space.width);
    try std.testing.expect(!atlas.changed);
}

test "a frame's glyphs are added before it is drawn, with nothing allocated after create" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const atlas = try Atlas(.rg8).create(failing.allocator());
    defer atlas.destroy(failing.allocator());
    const Command = struct {
        payload: union(enum) {
            text: struct { content: []const u8, style: struct { font: FontId, size: f32 } },
            rectangle: void,
        },
    };
    const commands = [_]Command{
        .{ .payload = .{ .text = .{ .content = "Hi", .style = .{ .font = 1, .size = 16 } } } },
        .{ .payload = .rectangle },
        .{ .payload = .{ .text = .{ .content = "skipped", .style = .{ .font = BoxFonts.font_count, .size = 16 } } } },
    };
    atlas.addFrameGlyphs(Fonts.of(&BoxFonts{}), &commands, 2);
    try std.testing.expect(atlas.find(.{ .font = 1, .pixel_size = 32, .codepoint = 'H' }) != null);
    try std.testing.expect(atlas.find(.{ .font = 1, .pixel_size = 32, .codepoint = 'i' }) != null);
    try std.testing.expectEqual(null, atlas.find(.{ .font = BoxFonts.font_count, .pixel_size = 32, .codepoint = 's' }));
    try std.testing.expectEqual(0, atlas.overflows);
    try std.testing.expectEqual(1, failing.allocations);
}
