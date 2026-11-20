//! The typefaces zui bundles, each the bytes of its TrueType file. Only
//! what an application references is embedded in it.
//!
//! ```zig
//! var text: zui_truetype.Text = .{};
//! const body = try text.addFont(zui_fonts.atkinson_hyperlegible_regular);
//! const code = try text.addFont(zui_fonts.liberation_mono_regular);
//! ```

const std = @import("std");

/// Atkinson Hyperlegible Regular, from the Braille Institute, under the SIL
/// Open Font License 1.1 (`OFL.txt`).
pub const atkinson_hyperlegible_regular: []const u8 = @embedFile("AtkinsonHyperlegible-Regular.ttf");

/// Atkinson Hyperlegible Bold, from the Braille Institute, under the SIL
/// Open Font License 1.1 (`OFL.txt`).
pub const atkinson_hyperlegible_bold: []const u8 = @embedFile("AtkinsonHyperlegible-Bold.ttf");

/// Liberation Mono Regular, from Red Hat, under the SIL Open Font License
/// 1.1 (`LiberationMono-LICENSE.txt`).
pub const liberation_mono_regular: []const u8 = @embedFile("LiberationMono-Regular.ttf");

/// The licence each font is distributed under, to ship beside an
/// application that embeds the font.
pub const licences = struct {
    pub const atkinson_hyperlegible: []const u8 = @embedFile("OFL.txt");
    pub const liberation_mono: []const u8 = @embedFile("LiberationMono-LICENSE.txt");
};

test "every font is a TrueType file" {
    const true_type_version = [_]u8{ 0, 1, 0, 0 };
    for ([_][]const u8{ atkinson_hyperlegible_regular, atkinson_hyperlegible_bold, liberation_mono_regular }) |font| {
        try std.testing.expectEqualSlices(u8, &true_type_version, font[0..4]);
    }
    try std.testing.expect(std.mem.indexOf(u8, licences.atkinson_hyperlegible, "SIL OPEN FONT LICENSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, licences.liberation_mono, "Red Hat") != null);
}
