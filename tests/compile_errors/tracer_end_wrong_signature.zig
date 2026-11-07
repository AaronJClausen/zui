const zui = @import("zui");

const Tracer = struct {
    pub fn zuiBegin(comptime zone: zui.TraceZone) u32 {
        return @intFromEnum(zone);
    }
    pub fn zuiEnd(_: u64) void {}
};

comptime {
    _ = zui.Context(.{ .features = .{ .Tracer = Tracer } });
}
