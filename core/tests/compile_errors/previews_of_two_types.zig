const zui_design = @import("zui_design");

const Chip = struct {
    pub const Content = struct { label: []const u8 };

    pub const zuiPreviews = .{
        .short = Content{ .label = "Save" },
        .count = @as(u32, 3),
    };
};

comptime {
    _ = zui_design.Permutations(Chip, .glance).count;
}
