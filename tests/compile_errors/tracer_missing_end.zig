const zui = @import("zui");

const Tracer = struct {
    pub fn zuiBegin(comptime _: zui.TraceZone) void {}
};

comptime {
    _ = zui.Context(.{ .features = .{ .Tracer = Tracer } });
}
