/// A step of `beginFrame` or `endFrame` that a tracer sees as a zone.
/// `begin_frame` and `end_frame` enclose the steps of their call.
pub const TraceZone = enum {
    begin_frame,
    wait_for_frame,
    evict_state,
    apply_events,

    end_frame,
    measure_text,
    fit_widths,
    distribute_widths,
    wrap_text,
    fit_heights,
    distribute_heights,
    position,
    emit,
    sort_layers,
};

/// Zones through `Tracer`, or, when it is `void`, nothing at all: a
/// `Zone` is then zero-sized and beginning and ending one generate no code.
///
/// ```zig
/// const zone = Tracing(Tracer).begin(.fit_widths);
/// defer zone.end();
/// ```
pub fn Tracing(comptime Tracer: type) type {
    return struct {
        pub const enabled = Tracer != void;
        pub const Span = if (enabled) @TypeOf(Tracer.zuiBegin(TraceZone.begin_frame)) else void;

        pub const Zone = struct {
            span: Span,

            pub inline fn end(self: Zone) void {
                if (enabled) Tracer.zuiEnd(self.span);
            }
        };

        pub inline fn begin(comptime zone: TraceZone) Zone {
            return .{ .span = if (enabled) Tracer.zuiBegin(zone) else {} };
        }
    };
}
