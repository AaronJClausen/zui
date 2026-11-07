const zui = @import("zui");

const Tracer = struct {
    pub fn zuiBegin(comptime _: zui.TraceZone) void {}
    pub fn zuiEnd(_: void) void {}
    pub fn zuiFrameMark() void {}
};

comptime {
    _ = zui.Context(.{ .features = .{ .Tracer = Tracer } });
}
