const zui = @import("zui");
const zui_wire = @import("zui_wire");

const Catalog = struct { title: []const u8 };

const CatalogSource = struct {
    pub const Delivery = ?*const Catalog;
    pub const View = ?*const Catalog;

    received: Delivery = null,

    pub fn zuiSwap(_: *CatalogSource) void {}

    pub fn zuiView(self: *CatalogSource) View {
        return self.received;
    }

    pub fn zuiDelivery(self: *const CatalogSource, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *CatalogSource, delivery: *const Delivery) void {
        self.received = delivery.*;
    }
};

const Ui = zui.Context(.{ .Sources = struct { catalog: CatalogSource = .{} } });

comptime {
    _ = zui_wire.Encoder(Ui);
}
