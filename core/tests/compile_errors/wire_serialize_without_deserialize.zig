const zui = @import("zui");
const zui_wire = @import("zui_wire");

const Handle = struct {
    texture: *const anyopaque,

    pub fn zuiSerialize(_: *const Handle, serializer: anytype) !void {
        try serializer.write(@as(u32, 0));
    }
};

const Ui = zui.Context(.{ .CustomData = Handle });

comptime {
    _ = zui_wire.Encoder(Ui);
}
