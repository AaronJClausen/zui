//! Traces zui's zones in the Tracy profiler.
//!
//! ```zig
//! const Ui = zui.Context(.{ .Text = Fonts, .features = .{ .Tracer = zui_tracy.Tracer } });
//!
//! while (running) {
//!     ui.beginFrame(&record);
//!     declare(&ui);
//!     renderer.draw(ui.endFrame());
//!     zui_tracy.frameMark();
//! }
//! ```
//!
//! Build with `-Dzui-tracy=true` (or `.@"zui-tracy" = true` on the zui
//! dependency) to fetch and link Tracy's client. Without it, `Tracer` is
//! `void`, so the same code compiles tracing out and never fetches Tracy.

const std = @import("std");
const zui = @import("zui");
const build_options = @import("zui_tracy_options");

pub const enabled = build_options.enabled;

/// For `Config.features.Tracer`: Tracy's client when enabled, `void` when not.
pub const Tracer = if (enabled) TracyTracer else void;

/// Ends a frame in Tracy's frame graph. Call it once per presented frame.
pub fn frameMark() void {
    if (enabled) ___tracy_emit_frame_mark(null);
}

const TracyTracer = struct {
    pub fn zuiBegin(comptime zone: zui.TraceZone) ZoneContext {
        return ___tracy_emit_zone_begin(&SourceLocationOf(zone).location, 1);
    }

    pub fn zuiEnd(span: ZoneContext) void {
        ___tracy_emit_zone_end(span);
    }
};

/// Tracy identifies a zone by the address of its source location, so each
/// zone needs one static location of its own.
fn SourceLocationOf(comptime zone: zui.TraceZone) type {
    return struct {
        const location: SourceLocation = .{ .name = @tagName(zone), .function = "zui." ++ @tagName(zone), .file = "zui", .line = 0, .color = 0 };
    };
}

const SourceLocation = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

/// Without `TRACY_ON_DEMAND`, which the build never defines; with it, Tracy
/// adds a field.
const ZoneContext = extern struct {
    id: u32,
    active: i32,
};

extern fn ___tracy_emit_zone_begin(location: *const SourceLocation, active: i32) ZoneContext;
extern fn ___tracy_emit_zone_end(context: ZoneContext) void;
extern fn ___tracy_emit_frame_mark(name: ?[*:0]const u8) void;

test {
    _ = @import("tests.zig");
}
