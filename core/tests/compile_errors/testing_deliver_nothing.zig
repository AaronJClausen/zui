const zui = @import("zui");
const zui_testing = @import("zui_testing");

const Counter = struct {
    pub const Delivery = u32;
    pub const View = u32;

    count: u32 = 0,

    pub fn zuiSwap(_: *Counter) void {}
    pub fn zuiView(self: *Counter) View {
        return self.count;
    }
    pub fn zuiDelivery(self: *const Counter, delivery: *Delivery) void {
        delivery.* = self.count;
    }
    pub fn zuiInject(self: *Counter, delivery: *const Delivery) void {
        self.count = delivery.*;
    }
};

const AppSources = struct {
    counter: Counter = .{},
    other: Counter = .{},
};

const Ui = zui.Context(.{ .Sources = AppSources });

fn declare(_: *AppSources, _: *Ui) void {}

export fn deliverOne(driver: *zui_testing.Driver(Ui), sources: *AppSources) void {
    _ = driver.frameDelivering(sources, declare, .{ .counter = 1 }) catch {};
}
