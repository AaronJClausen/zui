const zui = @import("zui");

const Chip = struct {
    pub const Part = struct { container: bool };

    pub const zuiAppearance = zui.design.Appearance(Part, .{});
};

comptime {
    _ = Chip.zuiAppearance;
}
