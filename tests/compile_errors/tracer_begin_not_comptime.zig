const zui = @import("zui");

const Tracer = struct {
    pub fn zuiBegin(zone: zui.TraceZone) u32 {
        return @intFromEnum(zone);
    }
    pub fn zuiEnd(_: u32) void {}
};

comptime {
    _ = zui.Context(.{ .features = .{ .Tracer = Tracer } });
}
