const zui = @import("zui");

const Quotes = struct {
    pub const Delivery = void;
    pub const View = void;

    pub fn zuiSwap(_: *Quotes) void {}
    pub fn zuiView(_: *Quotes) View {}
    pub fn zuiDelivery(_: *const Quotes, _: *Delivery) void {}
    pub fn zuiInject(_: *Quotes, _: *const Delivery) void {}
};

const AppSources = struct {
    quotes: Quotes = .{},
};

const Ui = zui.Context(.{ .Sources = AppSources });

export fn declare(ui: *Ui) void {
    _ = ui.source(.quotez);
}
