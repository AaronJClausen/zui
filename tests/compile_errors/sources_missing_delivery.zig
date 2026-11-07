const zui = @import("zui");

const Quotes = struct {
    pub const View = void;

    pub fn zuiSwap(_: *Quotes) void {}
    pub fn zuiView(_: *Quotes) View {}
};

const AppSources = struct {
    quotes: Quotes = .{},
};

comptime {
    _ = zui.Context(.{ .Sources = AppSources });
}
