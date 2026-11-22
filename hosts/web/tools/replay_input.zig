//! ```sh
//! replay-input <records path> <stream path>
//! ```
//! Runs the tour on the records the browser's client wrote, as a
//! `zui_wire.Host` reads them, checks each against the input the browser
//! was given, and writes the frames the tour drew as the wire renderer
//! sends them.

const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");
const tour_session = @import("tour_session");
const kit = tour_session.kit;
const Ui = tour_session.Ui;
const Screen = kit.Screen;

/// The rail's fifth entry, Log Tail, on a canvas 1280 by 800 CSS
/// pixels.
const rail_entry: [2]f32 = .{ 50, 266 };
const rail_entry_screen: Screen = .log_tail;
const rail_entry_id: zui.Id = .indexed("rail_item", @intFromEnum(rail_entry_screen));

/// What one record must hold, its events' instants and scancodes left out,
/// and what the tour must have done with it.
const ExpectedRecord = struct {
    viewport: [2]f32 = .{ 1280, 800 },
    scale: f32 = 1.25,
    events: []const zui.Event = &.{},
    screen_after: ?Screen = null,
    cursor_after: ?zui.Cursor = null,
};

fn mouse(position: [2]f32) zui.Pointer {
    return .{ .id = .mouse, .kind = .mouse, .position = position, .at = .zero };
}

fn key(logical: zui.Key, held: zui.Modifiers) zui.KeyEvent {
    return .{ .key = logical, .modifiers = held, .at = .zero };
}

const control: zui.Modifiers = .{ .control = true };
const wheeled_at: [2]f32 = .{ 640, 400 };
const tapped_at: [2]f32 = .{ 300, 300 };

const expected_records = [_]ExpectedRecord{
    .{ .cursor_after = .default },
    .{ .events = &.{.{ .pointer_move = .{ .pointer = mouse(rail_entry) } }}, .cursor_after = .pointer },
    .{
        .events = &.{ .{ .pointer_down = .{ .pointer = mouse(rail_entry) } }, .{ .pointer_up = .{ .pointer = mouse(rail_entry) } } },
        .screen_after = rail_entry_screen,
    },
    .{
        .events = &.{ .{ .key_down = key(.control, control) }, .{ .key_down = key(.digit_3, control) }, .{ .key_up = key(.digit_3, control) }, .{ .key_up = key(.control, .{}) } },
        .screen_after = .x_ray,
    },
    .{
        .events = &.{ .{ .key_down = key(.control, control) }, .{ .key_down = key(.page_down, control) }, .{ .key_up = key(.page_down, control) }, .{ .key_up = key(.control, .{}) } },
        .screen_after = .photo_cull,
    },
    .{ .events = &.{ .{ .key_down = key(.a, .{}) }, .{ .text = "a" }, .{ .key_up = key(.a, .{}) }, .{ .key_down = key(.digit_2, .{}) }, .{ .text = "é" }, .{ .key_up = key(.digit_2, .{}) } } },
    .{ .events = &.{.{ .wheel = .{ .position = wheeled_at, .delta = .{ 0, 120 }, .at = .zero } }} },
    .{ .events = &.{ .{ .pointer_down = .{ .pointer = touch(tapped_at, 1) } }, .{ .pointer_up = .{ .pointer = touch(tapped_at, 0) } } } },
    .{ .viewport = .{ 1024, 768 }, .scale = 2 },
};

/// A touch lifted has no pressure.
fn touch(position: [2]f32, pressure: f32) zui.Pointer {
    return .{ .id = touch_id, .kind = .touch, .position = position, .at = .zero, .pressure = pressure };
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3) {
        std.debug.print("expected <records path> <stream path>\n", .{});
        return error.UnknownArgument;
    }
    const io = init.io;
    const gpa = init.gpa;

    var text: kit.Text = undefined;
    try text.init();
    defer text.deinit();
    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);
    const app = try gpa.create(tour_session.Tour);
    defer gpa.destroy(app);
    app.init(io, .zero, text.fonts);
    defer app.deinit();
    app.heartbeat = false;

    const records_file = try std.Io.Dir.cwd().openFile(io, arguments[1], .{});
    defer records_file.close(io);
    var records_buffer: [64 * 1024]u8 = undefined;
    var records_reader = records_file.reader(io, &records_buffer);
    const reader = &records_reader.interface;
    var decoder: zui_wire.Decoder(Ui) = try .init(gpa, .of(Ui));
    defer decoder.deinit(gpa);
    try zui_wire.readHeader(reader, null);

    const stream_file = try std.Io.Dir.cwd().createFile(io, arguments[2], .{});
    defer stream_file.close(io);
    var stream_buffer: [64 * 1024]u8 = undefined;
    var stream_writer = stream_file.writer(io, &stream_buffer);
    var encoder: zui_wire.Encoder(Ui) = try .init(gpa);
    defer encoder.deinit(gpa);
    try zui_wire.writeHeader(&stream_writer.interface, zui_wire.fingerprintOf(&text));

    var record_index: usize = 0;
    while (try decoder.next(reader)) |message| : (record_index += 1) {
        const sent = switch (message) {
            .record => |record| record,
            .frame => return fail("message {d} is a frame, not a record", .{record_index}),
        };
        if (record_index == expected_records.len) return fail("more than the {d} records the browser was given input for", .{expected_records.len});
        const expected = expected_records[record_index];
        try expectRecord(record_index, &expected, sent);

        var events: [64]zui.Event = undefined;
        var event_count: usize = 0;
        for (app.environment_changes.drain()) |change| {
            events[event_count] = .{ .environment = change };
            event_count += 1;
        }
        for (sent.events) |event| {
            events[event_count] = event;
            event_count += 1;
        }
        ui.beginFrame(&.{ .params = sent.params, .events = events[0..event_count] }, &app.sources);
        app.declare(&ui);
        const frame = ui.endFrame();
        app.observe(&ui, frame);
        app.afterFrame(&ui);
        defer ui.release(frame);

        if (record_index == 0) {
            const entry = frame.rectOf(rail_entry_id) orelse return fail("the tour declared no rail entry for {t}", .{rail_entry_screen});
            const inside = rail_entry[0] > entry.x and rail_entry[0] < entry.x + entry.width and rail_entry[1] > entry.y and rail_entry[1] < entry.y + entry.height;
            if (!inside) return fail("{any} is not on the rail's entry for {t}, laid out at {any}", .{ rail_entry, rail_entry_screen, entry });
        }
        if (expected.screen_after) |screen| {
            if (app.current != screen) return fail("record {d}: the tour shows {t}, not {t}", .{ record_index, app.current, screen });
        }
        if (expected.cursor_after) |cursor| {
            if (frame.requests().cursor != cursor) return fail("record {d}: the tour asks for the {t} cursor, not {t}", .{ record_index, frame.requests().cursor, cursor });
        }
        try encoder.writeFrame(&stream_writer.interface, frame);
    }
    if (record_index != expected_records.len) return fail("{d} records of the {d} the browser was given input for", .{ record_index, expected_records.len });
    try stream_writer.interface.flush();
}

fn expectRecord(index: usize, expected: *const ExpectedRecord, sent: *const Ui.FrameRecord) !void {
    if (!std.meta.eql(sent.params.viewport, expected.viewport) or sent.params.scale != expected.scale) {
        return fail("record {d}: a viewport of {any} at a scale of {d}, not {any} at {d}", .{ index, sent.params.viewport, sent.params.scale, expected.viewport, expected.scale });
    }
    const matches = matches: {
        if (sent.events.len != expected.events.len) break :matches false;
        for (sent.events, expected.events) |event, wanted| {
            if (!sameEvent(event, wanted)) break :matches false;
            if (instantOf(event)) |instant| {
                if (instant.nanoseconds == 0 or sent.params.now.isBefore(instant)) return fail("record {d}: an event at {d} ns, in a record at {d} ns", .{ index, instant.nanoseconds, sent.params.now.nanoseconds });
            }
        }
        break :matches true;
    };
    if (matches) return;
    std.debug.print("record {d} holds:\n", .{index});
    for (sent.events) |event| std.debug.print("  {any}\n", .{withoutInstant(event)});
    std.debug.print("but the browser was given:\n", .{});
    for (expected.events) |event| std.debug.print("  {any}\n", .{event});
    return error.RecordDiffers;
}

fn sameEvent(sent: zui.Event, wanted: zui.Event) bool {
    if (std.meta.activeTag(sent) != std.meta.activeTag(wanted)) return false;
    return switch (sent) {
        .text => |typed| std.mem.eql(u8, typed, wanted.text),
        .key_down, .key_up => |sent_key| sent_key.scancode != 0 and std.meta.eql(withoutInstant(sent), wanted),
        .pointer_down, .pointer_up => |pressed| (pressed.pointer.kind == .mouse or pressed.pointer.id != .mouse) and std.meta.eql(withoutInstant(sent), wanted),
        else => std.meta.eql(withoutInstant(sent), wanted),
    };
}

/// The id the expected records give every touch, whatever the browser
/// numbered it.
const touch_id: zui.PointerId = @enumFromInt(1);

/// `event` as the expected records hold it: at `Instant.zero`, with no
/// scancode and with `touch_id` for a touch, which are the browser's own.
fn withoutInstant(event: zui.Event) zui.Event {
    var copy = event;
    switch (copy) {
        .pointer_down, .pointer_up => |*pressed| {
            pressed.pointer.at = .zero;
            if (pressed.pointer.kind == .touch) pressed.pointer.id = touch_id;
        },
        .pointer_move => |*moved| moved.pointer.at = .zero,
        .wheel => |*wheel| wheel.at = .zero,
        .key_down, .key_up => |*pressed| {
            pressed.at = .zero;
            pressed.scancode = 0;
        },
        else => {},
    }
    return copy;
}

fn instantOf(event: zui.Event) ?zui.Instant {
    return switch (event) {
        .pointer_down, .pointer_up => |pressed| pressed.pointer.at,
        .pointer_move => |moved| moved.pointer.at,
        .wheel => |wheel| wheel.at,
        .key_down, .key_up => |pressed| pressed.at,
        else => null,
    };
}

fn fail(comptime format: []const u8, arguments: anytype) error{ReplayFailed} {
    std.debug.print("replay-input: " ++ format ++ "\n", arguments);
    return error.ReplayFailed;
}
