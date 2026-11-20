const std = @import("std");

/// What a conformance suite found wrong: one of `Kind`'s errors and a
/// sentence saying where, kept inline so a failing suite allocates nothing.
pub fn DescribedViolation(comptime Kind: type) type {
    return struct {
        const Self = @This();

        kind: Kind,
        buffer: [160]u8 = undefined,
        len: usize = 0,

        pub fn init(kind: Kind, comptime format: []const u8, arguments: anytype) Self {
            var violation: Self = .{ .kind = kind };
            const written = std.fmt.bufPrint(&violation.buffer, format, arguments) catch &violation.buffer;
            violation.len = written.len;
            return violation;
        }

        /// What went wrong, after the implementation's name: "never delivered producer 2's last item".
        pub fn description(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}
