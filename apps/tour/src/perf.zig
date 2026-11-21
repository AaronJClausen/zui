const std = @import("std");
const zui = @import("zui");

/// Why zui_app declared a frame: what ended the host's last wait.
pub const FrameReason = enum {
    first,
    input,
    resize,
    requested,
    timer,
    source,

    pub fn describe(reason: FrameReason) []const u8 {
        return switch (reason) {
            .first => "first frame",
            .input => "input arrived",
            .resize => "window resized",
            .requested => "ui.requestFrame()",
            .timer => "requestFrameAt() came due",
            .source => "a source published",
        };
    }
};

/// What the tour's frames are timed by for the strip.
pub const Stopwatch = union(enum) {
    /// The `Io`'s awake clock.
    io,
    /// Milliseconds since a fixed instant, such as a page's
    /// `performance.now()`, for an `Io` that holds one instant for all of a
    /// frame, as one a page steps does.
    clock: *const fn () callconv(.c) f64,
    /// Moves on `step_nanoseconds` each time it is read, so every run times
    /// its frames alike and draws the same timings.
    steady: struct { step_nanoseconds: u64 = std.time.ns_per_us, reads: u64 = 0 },

    pub fn read(self: *Stopwatch, io: std.Io) zui.Instant {
        return switch (self.*) {
            .io => .fromTimestamp(std.Io.Timestamp.now(io, .awake)),
            .clock => |milliseconds| .fromNanoseconds(@intFromFloat(@max(0, milliseconds()) * std.time.ns_per_ms)),
            .steady => |*steady| {
                steady.reads += 1;
                return .fromNanoseconds(steady.reads * steady.step_nanoseconds);
            },
        };
    }
};

/// What the tour measured of each zui frame, kept for the strip. The strip
/// shows the frame before the one being declared, since a frame cannot
/// time its own declaration.
pub const Perf = struct {
    pub const history_length = 120;

    pub const Sample = struct {
        begin_frame_us: f32 = 0,
        declare_us: f32 = 0,
        end_frame_us: f32 = 0,
        elements: u32 = 0,
        commands: u32 = 0,
        measure_calls: u32 = 0,
        reason: FrameReason = .first,

        pub fn totalMicroseconds(sample: Sample) f32 {
            return sample.begin_frame_us + sample.declare_us + sample.end_frame_us;
        }
    };

    history: [history_length]Sample = @splat(.{}),
    newest: usize = history_length - 1,
    recorded: usize = 0,

    zui_frames: u64 = 0,
    /// Frames declared in the last whole second of the clock.
    frames_last_second: u32 = 0,
    frames_this_second: u32 = 0,
    this_second: u64 = 0,
    submit_us: f32 = 0,
    /// What the renderer had to leave out, when it counts it.
    layer_overflows: u32 = 0,
    glyph_overflows: u32 = 0,
    measure_calls_total: u64 = 0,
    wakes: u32 = 0,
    dropped_input_events: u32 = 0,
    diagnostics: zui.Diagnostics = .{},
    next_frame: zui.NextFrame = .immediately,
    next_frame_seconds: f32 = 0,

    pub fn record(self: *Perf, sample: Sample) void {
        self.newest = (self.newest + 1) % history_length;
        self.history[self.newest] = sample;
        self.recorded = @min(self.recorded + 1, history_length);
    }

    /// Counts a frame declared at `seconds` into the second it falls in.
    pub fn countFrameAt(self: *Perf, seconds: f64) void {
        const second: u64 = @intFromFloat(@max(0, @floor(seconds)));
        if (second != self.this_second) {
            self.frames_last_second = if (second == self.this_second + 1) self.frames_this_second else 0;
            self.frames_this_second = 0;
            self.this_second = second;
        }
        self.frames_this_second += 1;
    }

    pub fn latest(self: *const Perf) Sample {
        return self.history[self.newest];
    }

    /// Oldest first, `history_length` long; unrecorded samples are zero.
    pub fn sampleAt(self: *const Perf, age_from_oldest: usize) Sample {
        return self.history[(self.newest + 1 + age_from_oldest) % history_length];
    }

    pub const Summary = struct { minimum: f32, average: f32, p95: f32, maximum: f32 };

    pub fn summarize(self: *const Perf) Summary {
        if (self.recorded == 0) return .{ .minimum = 0, .average = 0, .p95 = 0, .maximum = 0 };
        var totals: [history_length]f32 = undefined;
        var sum: f32 = 0;
        for (0..self.recorded) |age| {
            const total = self.history[(self.newest + history_length - age) % history_length].totalMicroseconds();
            totals[age] = total;
            sum += total;
        }
        const recorded_totals = totals[0..self.recorded];
        std.mem.sort(f32, recorded_totals, {}, std.sort.asc(f32));
        const p95_index = (self.recorded * 95) / 100;
        return .{
            .minimum = recorded_totals[0],
            .average = sum / @as(f32, @floatFromInt(self.recorded)),
            .p95 = recorded_totals[@min(p95_index, self.recorded - 1)],
            .maximum = recorded_totals[self.recorded - 1],
        };
    }
};
