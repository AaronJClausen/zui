const zui = @import("zui");
const zui_wire = @import("zui_wire");

const Texture = struct { id: u32 };

const Ui = zui.Context(.{ .ImageHandle = *const Texture });

comptime {
    _ = zui_wire.Decoder(Ui);
}
