const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

/// The newest number published, swapped at `beginFrame`.
const Counter = struct {
    pub const Delivery = ?u32;
    pub const View = ?u32;

    published: ?u32 = null,
    received: ?u32 = null,
    latest: ?u32 = null,

    pub fn zuiSwap(self: *Counter) void {
        self.received = self.published;
        if (self.published) |value| self.latest = value;
        self.published = null;
    }

    pub fn zuiView(self: *Counter) View {
        return self.latest;
    }

    pub fn zuiDelivery(self: *const Counter, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *Counter, delivery: *const Delivery) void {
        self.received = delivery.*;
        if (delivery.*) |value| self.latest = value;
    }
};

const Sources = struct { counter: Counter = .{} };

const RelayedUi = zui.Context(.{
    .limits = .{ .max_elements = 16, .max_text_bytes = 256, .max_render_commands = 32, .measure_cache_entries = 16, .string_cache_entries = 16, .max_events_per_frame = 4 },
    .Text = support.FixedMetricsText,
    .Sources = Sources,
});

/// Copies each record it is handed into memory of its own, since a relayed
/// record lives only for the call.
const Recorder = struct {
    const capacity = 8;

    params: [capacity]zui.FrameParams = undefined,
    events: [capacity][8]zui.Event = undefined,
    event_counts: [capacity]usize = undefined,
    deliveries: [capacity]RelayedUi.Deliveries = undefined,
    text_bytes: [256]u8 = undefined,
    text_len: usize = 0,
    count: usize = 0,

    fn listener(self: *Recorder) RelayedUi.Relay {
        return .{ .context = self, .relayFn = keep };
    }

    fn keep(context: *anyopaque, record: *const RelayedUi.FrameRecord) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const index = self.count;
        self.count += 1;
        self.params[index] = record.params;
        self.event_counts[index] = record.events.len;
        for (record.events, self.events[index][0..record.events.len]) |event, *kept| {
            kept.* = switch (event) {
                .text => |typed| .{ .text = self.copyText(typed) },
                else => event,
            };
        }
        self.deliveries[index] = record.deliveries.?.*;
    }

    fn copyText(self: *Recorder, typed: []const u8) []const u8 {
        const copy = self.text_bytes[self.text_len..][0..typed.len];
        @memcpy(copy, typed);
        self.text_len += typed.len;
        return copy;
    }

    fn recordAt(self: *const Recorder, index: usize) RelayedUi.FrameRecord {
        return .{ .params = self.params[index], .events = self.events[index][0..self.event_counts[index]], .deliveries = &self.deliveries[index] };
    }
};

const save: zui.Id = .of("save");

fn declare(ui: *RelayedUi, clicks: *u32) void {
    if (ui.clicked(save)) clicks.* += 1;
    ui.box(.{ .id = save, .interactive = true, .decoration = .{ .background = .black }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
    ui.text(ui.typedText(), .{});
    if (ui.source(.counter)) |value| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(@floatFromInt(value)), .height = .fixed(1) } } });
}

fn atFrame(frame: u64) zui.Instant {
    return .fromNanoseconds(frame * 16 * std.time.ns_per_ms);
}

const mouse_at_save: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 10, 10 }, .at = atFrame(1) };
const click_and_typing = [_]zui.Event{
    .{ .pointer_move = .{ .pointer = mouse_at_save } },
    .{ .pointer_down = .{ .pointer = mouse_at_save } },
    .{ .pointer_up = .{ .pointer = mouse_at_save } },
    .{ .text = "hi" },
};
/// Six events where the context keeps four.
const overflowing = [_]zui.Event{
    .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" }, .{ .text = "d" }, .{ .text = "e" }, .{ .text = "f" },
};
const session = [_][]const zui.Event{ &.{}, &click_and_typing, &overflowing, &.{} };

/// Each frame's commands, as `expectEqualDeep` compares them.
const Drawn = struct {
    commands: [session.len][32]RelayedUi.RenderCommand = undefined,
    counts: [session.len]usize = undefined,

    fn keep(self: *Drawn, index: usize, frame: *const RelayedUi.Frame) void {
        const commands = frame.commands();
        self.counts[index] = commands.len;
        @memcpy(self.commands[index][0..commands.len], commands);
    }

    fn of(self: *const Drawn, index: usize) []const RelayedUi.RenderCommand {
        return self.commands[index][0..self.counts[index]];
    }
};

test "a relayed session is the records applied, with each source's delivery, and replays to the same commands" {
    var text_contract: support.FixedMetricsText = .{};
    var ui: RelayedUi = try .init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);
    var sources: Sources = .{};
    var recorder: Recorder = .{};
    ui.relayTo(recorder.listener());

    var clicks: u32 = 0;
    var live: Drawn = .{};
    var typed: [session.len][16]u8 = undefined;
    for (session, 0..) |events, index| {
        if (index == 2) sources.counter.published = 7;
        ui.beginFrame(&.{ .params = .{ .now = atFrame(index), .viewport = .{ 400, 300 }, .scale = 2, .zoom = 1.5 }, .events = events }, &sources);
        @memcpy(typed[index][0..ui.typedText().len], ui.typedText());
        declare(&ui, &clicks);
        const frame = ui.endFrame();
        live.keep(index, frame);
        ui.release(frame);
    }
    ui.relayTo(null);
    ui.beginFrame(&.{ .params = .{ .now = atFrame(session.len), .viewport = .{ 400, 300 } } }, &sources);
    ui.release(ui.endFrame());

    try testing.expectEqual(session.len, recorder.count);
    try testing.expectEqual(@as(u32, 1), clicks);
    for (session, 0..) |events, index| {
        const relayed = recorder.recordAt(index);
        try testing.expectEqual(atFrame(index), relayed.params.now);
        try testing.expectEqual(@as(f32, 1.5), relayed.params.zoom);
        try testing.expectEqualDeep(events[0..@min(events.len, 4)], relayed.events);
        try testing.expectEqual(@as(?u32, if (index == 2) 7 else null), relayed.deliveries.?.counter);
    }

    var replayed_ui: RelayedUi = try .init(testing.allocator, testing.io, &text_contract);
    defer replayed_ui.deinit(testing.allocator);
    var replayed_sources: Sources = .{};
    var replay_recorder: Recorder = .{};
    replayed_ui.relayTo(replay_recorder.listener());
    var replayed_clicks: u32 = 0;
    for (0..session.len) |index| {
        const record = recorder.recordAt(index);
        replayed_ui.beginFrame(&record, &replayed_sources);
        try testing.expectEqualStrings(typed[index][0..replayed_ui.typedText().len], replayed_ui.typedText());
        declare(&replayed_ui, &replayed_clicks);
        const frame = replayed_ui.endFrame();
        try testing.expectEqualDeep(live.of(index), frame.commands());
        replayed_ui.release(frame);
        try testing.expectEqualDeep(record.deliveries.?.*, replay_recorder.deliveries[index]);
    }
    try testing.expectEqual(@as(u32, 1), replayed_clicks);
}

const SourcelessUi = zui.Context(.{ .limits = .{ .max_elements = 8 } });

test "a context without sources relays its records without deliveries" {
    const Count = struct {
        var relayed: u32 = 0;
        var last_viewport: [2]f32 = .{ 0, 0 };

        fn keep(_: *anyopaque, record: *const SourcelessUi.FrameRecord) void {
            relayed += 1;
            last_viewport = record.params.viewport;
        }
    };
    var ui: SourcelessUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var unused: u8 = 0;
    ui.relayTo(.{ .context = &unused, .relayFn = Count.keep });
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 320, 200 } } });
    ui.release(ui.endFrame());
    try testing.expectEqual(@as(u32, 1), Count.relayed);
    try testing.expectEqual([2]f32{ 320, 200 }, Count.last_viewport);
    try testing.expect(!@hasField(SourcelessUi.FrameRecord, "deliveries"));
}
