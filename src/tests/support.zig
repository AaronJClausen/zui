const std = @import("std");
const zui = @import("../root.zig");

/// Deterministic metrics: every byte is `size / 2` wide plus the letter
/// spacing after it, and `size` tall, so at the default size of 16 an
/// unspaced character is 8×16.
pub const FixedMetricsText = struct {
    pub fn zuiMeasure(_: *FixedMetricsText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

pub const Ui = zui.Context(.{
    .limits = .{
        .max_elements = 256,
        .max_text_bytes = 4096,
        .max_depth = 16,
        .max_render_commands = 512,
        .measure_cache_entries = 256,
    },
    .Text = FixedMetricsText,
    .features = .{ .flex_wrap = true },
});

pub const frame_interval_ns = 16 * std.time.ns_per_ms;

/// A record for one frame of an 800×600 viewport.
pub fn record(now: zui.Instant, events: []const zui.Event) zui.FrameRecord {
    return .{ .params = .{ .now = now, .viewport = .{ 800, 600 } }, .events = events };
}

pub const Harness = struct {
    text_contract: FixedMetricsText = .{},
    ui: Ui = undefined,
    /// Turns the sampled state the tests describe into the record's events.
    sampler: zui.InputSampler = .{},
    now: zui.Instant = .zero,
    events: [64]zui.Event = undefined,

    pub fn init(self: *Harness) !void {
        self.ui = try Ui.init(std.testing.allocator, std.testing.io, &self.text_contract);
    }

    pub fn deinit(self: *Harness) void {
        self.ui.deinit(std.testing.allocator);
    }

    pub fn begin(self: *Harness) *Ui {
        return self.beginWith(.{});
    }

    /// Begins a frame with the events between the previous sample and this one.
    pub fn beginWith(self: *Harness, sample: zui.InputSampler.Sample) *Ui {
        return self.beginEvents(self.sampler.sample(self.now, sample, &self.events));
    }

    pub fn beginEvents(self: *Harness, events: []const zui.Event) *Ui {
        self.now = self.now.addNanoseconds(frame_interval_ns);
        self.ui.beginFrame(&record(self.now, events));
        return &self.ui;
    }

    /// Ends the frame, expects no limit was exceeded, and releases it so
    /// the next frame can start. The returned frame stays readable until
    /// two more frames have begun.
    pub fn end(self: *Harness) !*const Ui.Frame {
        const frame = self.ui.endFrame();
        self.ui.release(frame);
        try frame.diagnostics.check();
        return frame;
    }
};

pub fn primaryDown() std.EnumSet(zui.Button) {
    return .initOne(.primary);
}

pub fn mouse(position: [2]f32) zui.Pointer {
    return .{ .id = .mouse, .kind = .mouse, .position = position, .at = .zero };
}

pub fn touch(id: u32, position: [2]f32) zui.Pointer {
    return .{ .id = @enumFromInt(id), .kind = .touch, .position = position, .at = .zero };
}

pub fn expectRect(frame: anytype, id: zui.Id, x: f32, y: f32, width: f32, height: f32) !void {
    const rect = frame.rectOf(id) orelse return error.ElementNotFound;
    try std.testing.expectEqual(zui.Rect{ .x = x, .y = y, .width = width, .height = height }, rect);
}

/// One line per command: `kind x y w h [detail]`, in paint order.
pub fn snapshot(frame: anytype, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (frame.commands()) |command| {
        const bounds = command.bounds;
        switch (command.payload) {
            .rectangle => |rectangle| try writer.print("rect {d} {d} {d} {d} #{x:0>2}{x:0>2}{x:0>2}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, rectangle.color.r, rectangle.color.g, rectangle.color.b }),
            .border => |border| try writer.print("border {d} {d} {d} {d} #{x:0>2}{x:0>2}{x:0>2}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, border.color.r, border.color.g, border.color.b }),
            .text => |text| {
                try writer.print("text {d} {d} {d} {d} \"{s}\"", .{ bounds.x, bounds.y, bounds.width, bounds.height, text.content });
                if (text.style.letter_spacing != 0) try writer.print(" spacing={d}", .{text.style.letter_spacing});
                try writer.writeByte('\n');
            },
            .clip_begin => |clip| try writer.print("clip {d} {d} {d} {d}\n", .{ clip.x, clip.y, clip.width, clip.height }),
            .clip_end => try writer.writeAll("clip_end\n"),
        }
    }
    return writer.buffered();
}

/// A tracer that records each zone's beginning and end, in order.
pub const RecordingTracer = struct {
    pub const Mark = struct { zone: zui.TraceZone, edge: enum { begin, end } };

    var marks: [64]Mark = undefined;
    var mark_count: usize = 0;
    var overflowed = false;

    pub fn zuiBegin(comptime zone: zui.TraceZone) zui.TraceZone {
        add(.{ .zone = zone, .edge = .begin });
        return zone;
    }

    pub fn zuiEnd(zone: zui.TraceZone) void {
        add(.{ .zone = zone, .edge = .end });
    }

    fn add(mark: Mark) void {
        if (mark_count == marks.len) {
            overflowed = true;
            return;
        }
        marks[mark_count] = mark;
        mark_count += 1;
    }

    pub fn clear() void {
        mark_count = 0;
        overflowed = false;
    }

    pub fn recorded() error{TooManyMarks}![]const Mark {
        if (overflowed) return error.TooManyMarks;
        return marks[0..mark_count];
    }
};

/// A source that never receives anything: the cost of a source alone.
pub const IdleSource = struct {
    pub const Delivery = void;
    pub const View = void;

    pub fn zuiSwap(_: *IdleSource) void {}
    pub fn zuiView(_: *IdleSource) View {}
    pub fn zuiDelivery(_: *const IdleSource, _: *Delivery) void {}
    pub fn zuiInject(_: *IdleSource, _: *const Delivery) void {}
};
