//! ```sh
//! bitmap-fonts <output path>
//! ```
//! Writes sokol_debugtext's six fonts, which zui-sokol's `Text` numbers
//! `FontId` 0 to 5, in that order, each 256 glyphs of eight rows, as the
//! client's `zuiWebBitmapFontRows` takes them.

const std = @import("std");
const zui_sokol = @import("zui_sokol");
const sdtx = zui_sokol.sokol.debugtext;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        std.debug.print("expected <output path>\n", .{});
        return error.UnknownArgument;
    }
    const file = try std.Io.Dir.cwd().createFile(init.io, arguments[1], .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    for ([_]sdtx.FontDesc{ sdtx.fontKc853(), sdtx.fontKc854(), sdtx.fontZ1013(), sdtx.fontCpc(), sdtx.fontC64(), sdtx.fontOric() }) |font| {
        if (font.first_char != 0 or font.last_char != 255 or font.data.size != 256 * 8) return error.UnexpectedFontLayout;
        const rows: [*]const u8 = @ptrCast(font.data.ptr.?);
        try writer.interface.writeAll(rows[0..font.data.size]);
    }
    try writer.interface.flush();
}
