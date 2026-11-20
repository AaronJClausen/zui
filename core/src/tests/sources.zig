const std = @import("std");
const zui = @import("../root.zig");

const testing = std.testing;

var swap_order: [32]u8 = undefined;
var swap_count: usize = 0;

fn swapped() []const u8 {
    return swap_order[0..swap_count];
}

/// Holds one published value until the next swap, and refuses another
/// publish meanwhile: enough of a source to test the core against.
const Slot = struct {
    pub const Delivery = ?u32;
    pub const View = struct {
        value: ?u32,

        pub fn get(self: View) ?u32 {
            return self.value;
        }
    };

    name: u8,
    published: ?u32 = null,
    front: ?u32 = null,
    received: ?u32 = null,
    refused: u32 = 0,
    injections: u32 = 0,
    ended: [8]zui.EndFrameInfo = undefined,
    ended_count: usize = 0,

    fn publish(self: *Slot, value: u32) error{Full}!zui.Wake {
        if (self.published != null) {
            self.refused += 1;
            return error.Full;
        }
        self.published = value;
        return .needed;
    }

    pub fn zuiSwap(self: *Slot) void {
        swap_order[swap_count] = self.name;
        swap_count += 1;
        self.received = self.published;
        if (self.published) |value| self.front = value;
        self.published = null;
    }

    pub fn zuiView(self: *Slot) View {
        return .{ .value = self.front };
    }

    pub fn zuiDelivery(self: *const Slot, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *Slot, delivery: *const Delivery) void {
        self.injections += 1;
        self.received = delivery.*;
        if (delivery.*) |value| self.front = value;
    }

    pub fn zuiPending(self: *const Slot) bool {
        return self.published != null;
    }

    pub fn zuiEndFrame(self: *Slot, info: zui.EndFrameInfo) void {
        self.ended[self.ended_count] = info;
        self.ended_count += 1;
    }

    pub fn zuiRefusedCount(self: *Slot) u32 {
        defer self.refused = 0;
        return self.refused;
    }
};

/// Only the required declarations: never pending, never refusing.
const Constant = struct {
    pub const Delivery = void;
    pub const View = u32;

    pub fn zuiSwap(_: *Constant) void {
        swap_order[swap_count] = 'c';
        swap_count += 1;
    }

    pub fn zuiView(_: *Constant) View {
        return 42;
    }

    pub fn zuiDelivery(_: *const Constant, _: *Delivery) void {}

    pub fn zuiInject(_: *Constant, _: *const Delivery) void {}
};

const AppSources = struct {
    first: Slot = .{ .name = 'a' },
    constant: Constant = .{},
    second: Slot = .{ .name = 'b' },
};

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = AppSources });

const Fixture = struct {
    ui: Ui,
    sources: AppSources = .{},
    now: zui.Instant = .zero,

    fn init() !Fixture {
        swap_count = 0;
        return .{ .ui = try .init(testing.allocator, testing.io) };
    }

    fn deinit(self: *Fixture) void {
        self.ui.deinit(testing.allocator);
    }

    fn begin(self: *Fixture) *Ui {
        return self.beginRecord(.{ .params = .{ .now = self.now, .viewport = .{ 100, 100 } } });
    }

    fn beginRecord(self: *Fixture, record: Ui.FrameRecord) *Ui {
        self.now = self.now.addNanoseconds(std.time.ns_per_ms);
        self.ui.beginFrame(&record, &self.sources);
        return &self.ui;
    }

    fn end(self: *Fixture) *const Ui.Frame {
        const frame = self.ui.endFrame();
        self.ui.release(frame);
        return frame;
    }
};

test "beginFrame swaps every source in field order, and declaration sees only what was swapped" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    _ = try fixture.sources.first.publish(1);
    const ui = fixture.begin();
    try testing.expectEqualStrings("acb", swapped());
    try testing.expectEqual(@as(?u32, 1), ui.source(.first).get());
    try testing.expectEqual(@as(?u32, null), ui.source(.second).get());
    try testing.expectEqual(@as(u32, 42), ui.source(.constant));

    _ = try fixture.sources.second.publish(2);
    try testing.expectEqual(@as(?u32, null), ui.source(.second).get());
    try testing.expect(fixture.end().diagnostics.ok());

    _ = fixture.begin();
    try testing.expectEqualStrings("acbacb", swapped());
    try testing.expectEqual(@as(?u32, 2), ui.source(.second).get());
    try testing.expectEqual(@as(?u32, 1), ui.source(.first).get());
    _ = fixture.end();
}

test "a record with deliveries injects them instead of swapping" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    _ = try fixture.sources.first.publish(1);
    const recorded: Ui.Deliveries = .{ .first = 7, .constant = {}, .second = null };
    const ui = fixture.beginRecord(.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } }, .deliveries = &recorded });
    try testing.expectEqualStrings("", swapped());
    try testing.expectEqual(@as(?u32, 7), ui.source(.first).get());
    try testing.expectEqual(@as(u32, 1), fixture.sources.first.injections);
    try testing.expectEqual(@as(u32, 1), fixture.sources.second.injections);

    var delivered: Slot.Delivery = undefined;
    fixture.sources.first.zuiDelivery(&delivered);
    try testing.expectEqual(@as(?u32, 7), delivered);
    _ = fixture.end();
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame(&fixture.sources));
}

test "framesSinceRead counts the frames since the last that read the source" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();
    const never = std.math.maxInt(u64);

    try testing.expectEqual(never, fixture.ui.framesSinceRead(.first));
    var ui = fixture.begin();
    _ = ui.source(.first);
    try testing.expectEqual(@as(u64, 0), ui.framesSinceRead(.first));
    _ = fixture.end();
    try testing.expectEqual(@as(u64, 0), fixture.ui.framesSinceRead(.first));
    try testing.expectEqual(never, fixture.ui.framesSinceRead(.second));

    ui = fixture.begin();
    _ = ui.source(.second);
    _ = fixture.end();
    try testing.expectEqual(@as(u64, 1), fixture.ui.framesSinceRead(.first));
    try testing.expectEqual(@as(u64, 0), fixture.ui.framesSinceRead(.second));

    _ = fixture.begin();
    _ = fixture.end();
    try testing.expectEqual(@as(u64, 2), fixture.ui.framesSinceRead(.first));
    try testing.expectEqual(@as(u64, 1), fixture.ui.framesSinceRead(.second));
}

test "nextFrame is immediate while a source has something not yet swapped" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    _ = fixture.begin();
    _ = fixture.end();
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame(&fixture.sources));

    try testing.expectEqual(zui.Wake.needed, try fixture.sources.second.publish(3));
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame(&fixture.sources));

    _ = fixture.begin();
    _ = fixture.end();
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame(&fixture.sources));
}

test "refused publishes are reported with the name of the source that refused" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    _ = try fixture.sources.second.publish(1);
    try testing.expectError(error.Full, fixture.sources.second.publish(2));
    try testing.expectError(error.Full, fixture.sources.second.publish(3));
    _ = try fixture.sources.first.publish(4);
    try testing.expectError(error.Full, fixture.sources.first.publish(5));

    _ = fixture.begin();
    const frame = fixture.end();
    try testing.expectEqual(@as(u32, 3), frame.diagnostics.refused_publishes);
    try testing.expectEqualStrings("first", frame.diagnostics.first_refusing_source);
    try testing.expectError(error.CapacityExceeded, frame.diagnostics.check());

    _ = fixture.begin();
    try testing.expect(fixture.end().diagnostics.ok());
}

test "zuiEndFrame learns each frame's number and how many frames may be in flight" {
    var fixture: Fixture = try .init();
    defer fixture.deinit();

    for (0..3) |_| {
        _ = fixture.begin();
        _ = fixture.end();
    }
    const ended = fixture.sources.second.ended[0..fixture.sources.second.ended_count];
    try testing.expectEqual(@as(usize, 3), ended.len);
    for (ended, 0..) |info, frame_number| {
        try testing.expectEqual(zui.EndFrameInfo{ .frame_number = frame_number, .frames_in_flight = 2 }, info);
    }
}

test "a context without sources takes no sources parameter and has no deliveries" {
    const Plain = zui.Context(.{ .limits = .{ .max_elements = 8 } });
    try testing.expectEqual(2, @typeInfo(@TypeOf(Plain.beginFrame)).@"fn".params.len);
    try testing.expectEqual(1, @typeInfo(@TypeOf(Plain.nextFrame)).@"fn".params.len);
    try testing.expectEqual(zui.FrameRecord, Plain.FrameRecord);
    try testing.expectEqual(3, @typeInfo(@TypeOf(Ui.beginFrame)).@"fn".params.len);
    try testing.expectEqual(?u32, @FieldType(Ui.Deliveries, "first"));
    try testing.expectEqual(void, @FieldType(Ui.Deliveries, "constant"));
}

test "an empty sources struct swaps nothing" {
    const EmptyUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = struct {} });
    var ui: EmptyUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var sources: EmptyUi.Sources = .{};
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    ui.release(ui.endFrame());
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame(&sources));
}
