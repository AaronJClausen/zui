const std = @import("std");

/// The codepoints of UTF-8 text; each invalid byte reads as U+FFFD, so a
/// run lays out as many glyphs however it is split.
pub const Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Codepoints {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Codepoints) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        if (first < 0x80) {
            self.index += 1;
            return first;
        }
        const length = std.unicode.utf8ByteSequenceLength(first) catch return self.replace();
        if (self.index + length > self.bytes.len) return self.replace();
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..length]) catch return self.replace();
        self.index += length;
        return codepoint;
    }

    fn replace(self: *Codepoints) u21 {
        self.index += 1;
        return std.unicode.replacement_character;
    }
};

test "invalid UTF-8 reads as one replacement character per byte" {
    var codepoints = Codepoints.init("a\xffb\xc3\xa9\xe2\x82");
    try std.testing.expectEqual(@as(?u21, 'a'), codepoints.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), codepoints.next());
    try std.testing.expectEqual(@as(?u21, 'b'), codepoints.next());
    try std.testing.expectEqual(@as(?u21, 0xe9), codepoints.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), codepoints.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), codepoints.next());
    try std.testing.expectEqual(@as(?u21, null), codepoints.next());
}
