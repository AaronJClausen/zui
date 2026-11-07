//! ```zig
//! const Ui = zui.Context(.{ .Text = zui_testing.FixedMetricsText(u16) });
//!
//! test "saving clears the dirty flag" {
//!     var text: zui_testing.FixedMetricsText(u16) = .{};
//!     var ui: Ui = try .init(std.testing.allocator, std.testing.io, &text);
//!     defer ui.deinit(std.testing.allocator);
//!     var driver: zui_testing.Driver(Ui) = .{ .ui = &ui };
//!
//!     var app: App = .{ .dirty = true };
//!     _ = try driver.frame(&app, App.declare, &.{});
//!     _ = try driver.click(&app, App.declare, .of("save"));
//!     try std.testing.expect(!app.dirty);
//! }
//! ```

const std = @import("std");
const zui = @import("zui");

/// A text contract whose metrics don't depend on fonts: each byte is
/// `size / 2` wide plus the letter spacing after it, and `size` tall, so
/// at the default size of 16 an unspaced character is 8×16.
pub fn FixedMetricsText(comptime FontId: type) type {
    return struct {
        const Self = @This();

        pub fn zuiMeasure(_: *Self, text: []const u8, key: zui.MeasureKey(FontId)) [2]f32 {
            return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
        }
    };
}

/// Runs complete frames from events. Interaction in zui answers for the
/// previous frame's layout, so every helper that targets an element by id
/// needs that element to have been declared in an earlier frame.
///
/// `declare` is called once per frame as `declare(app, ui)`.
pub fn Driver(comptime Ui: type) type {
    return struct {
        const Self = @This();

        ui: *Ui,
        viewport: [2]f32 = .{ 800, 600 },
        now: zui.Instant = .zero,
        frame_interval_ns: u64 = std.time.ns_per_s / 60,
        /// Held for every key the driver presses.
        modifiers: zui.Modifiers = .{},

        /// One frame from `events`: begin, declare, end, and release. The
        /// returned frame stays readable until the next frame begins.
        pub fn frame(self: *Self, app: anytype, comptime declare: anytype, events: []const zui.Event) !*const Ui.Frame {
            self.now = self.now.addNanoseconds(self.frame_interval_ns);
            self.ui.beginFrame(&.{ .params = .{ .now = self.now, .viewport = self.viewport }, .events = events });
            declare(app, self.ui);
            const ended = self.ui.endFrame();
            self.ui.release(ended);
            try ended.diagnostics.check();
            return ended;
        }

        /// The point at `fractions` of the element's rectangle in the
        /// previous frame: `.{ 0.5, 0.5 }` is its center.
        pub fn pointOn(self: *const Self, element_id: zui.Id, fractions: [2]f32) error{ElementNotFound}![2]f32 {
            const rect = self.ui.rectOf(element_id) orelse return error.ElementNotFound;
            return .{ rect.x + rect.width * fractions[0], rect.y + rect.height * fractions[1] };
        }

        fn mouseAt(self: *const Self, position: [2]f32) zui.Pointer {
            return .{ .id = .mouse, .kind = .mouse, .position = position, .at = self.now };
        }

        fn touchAt(self: *const Self, finger: usize, position: [2]f32) zui.Pointer {
            return .{ .id = @enumFromInt(1 + finger), .kind = .touch, .position = position, .at = self.now };
        }

        pub fn hover(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id) !*const Ui.Frame {
            const pointer = self.mouseAt(try self.pointOn(element_id, .{ 0.5, 0.5 }));
            return self.frame(app, declare, &.{.{ .pointer_move = .{ .pointer = pointer } }});
        }

        /// Presses and releases the mouse on the element's center in one
        /// frame, whose declarations see the click.
        pub fn click(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id) !*const Ui.Frame {
            return self.clickAt(app, declare, element_id, .{ 0.5, 0.5 });
        }

        pub fn clickAt(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id, fractions: [2]f32) !*const Ui.Frame {
            const pointer = self.mouseAt(try self.pointOn(element_id, fractions));
            return self.frame(app, declare, &.{
                .{ .pointer_move = .{ .pointer = pointer } },
                .{ .pointer_down = .{ .pointer = pointer } },
                .{ .pointer_up = .{ .pointer = pointer } },
            });
        }

        /// A finger down and up on the element's center in one frame.
        pub fn tap(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id) !*const Ui.Frame {
            const pointer = self.touchAt(0, try self.pointOn(element_id, .{ 0.5, 0.5 }));
            return self.frame(app, declare, &.{
                .{ .pointer_down = .{ .pointer = pointer } },
                .{ .pointer_up = .{ .pointer = pointer } },
            });
        }

        /// Presses the mouse at `from`, moves to `to` with the button held,
        /// and releases there: three frames. Both points are fractions of
        /// the element's rectangle when the drag starts, and may lie outside it.
        pub fn drag(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id, from: [2]f32, to: [2]f32) !*const Ui.Frame {
            const start = self.mouseAt(try self.pointOn(element_id, from));
            const end_point = try self.pointOn(element_id, to);
            _ = try self.frame(app, declare, &.{
                .{ .pointer_move = .{ .pointer = start } },
                .{ .pointer_down = .{ .pointer = start } },
            });
            const end = self.mouseAt(end_point);
            _ = try self.frame(app, declare, &.{.{ .pointer_move = .{ .pointer = end } }});
            return self.frame(app, declare, &.{.{ .pointer_up = .{ .pointer = self.mouseAt(end_point) } }});
        }

        pub const Stroke = struct { from: [2]f32, to: [2]f32 };

        pub const max_fingers = 10;

        /// One finger per stroke, all down together, moving together and
        /// lifting together: three frames, as `drag`.
        ///
        /// ```zig
        /// // Two fingers spreading apart across a map.
        /// _ = try driver.dragFingers(&app, App.declare, .of("map"), &.{
        ///     .{ .from = .{ 0.4, 0.5 }, .to = .{ 0.2, 0.5 } },
        ///     .{ .from = .{ 0.6, 0.5 }, .to = .{ 0.8, 0.5 } },
        /// });
        /// ```
        pub fn dragFingers(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id, strokes: []const Stroke) !*const Ui.Frame {
            std.debug.assert(strokes.len <= max_fingers);
            var events: [max_fingers]zui.Event = undefined;
            var ends: [max_fingers][2]f32 = undefined;
            for (strokes, 0..) |stroke, finger| {
                ends[finger] = try self.pointOn(element_id, stroke.to);
                events[finger] = .{ .pointer_down = .{ .pointer = self.touchAt(finger, try self.pointOn(element_id, stroke.from)) } };
            }
            _ = try self.frame(app, declare, events[0..strokes.len]);
            for (0..strokes.len) |finger| events[finger] = .{ .pointer_move = .{ .pointer = self.touchAt(finger, ends[finger]) } };
            _ = try self.frame(app, declare, events[0..strokes.len]);
            for (0..strokes.len) |finger| events[finger] = .{ .pointer_up = .{ .pointer = self.touchAt(finger, ends[finger]) } };
            return self.frame(app, declare, events[0..strokes.len]);
        }

        /// Each key down and up, in order, in one frame, with `modifiers` held.
        pub fn pressKeys(self: *Self, app: anytype, comptime declare: anytype, keys: []const zui.Key) !*const Ui.Frame {
            var events: [Ui.limits.max_events_per_frame]zui.Event = undefined;
            var count: usize = 0;
            for (keys) |key| {
                if (count + 2 > events.len) {
                    _ = try self.frame(app, declare, events[0..count]);
                    count = 0;
                }
                const key_event: zui.KeyEvent = .{ .key = key, .modifiers = self.modifiers, .at = self.now };
                events[count] = .{ .key_down = key_event };
                events[count + 1] = .{ .key_up = key_event };
                count += 2;
            }
            return self.frame(app, declare, events[0..count]);
        }

        /// Delivers `text` in frames of at most `limits.max_text_input_bytes`,
        /// split at character boundaries, so nothing is truncated.
        pub fn typeText(self: *Self, app: anytype, comptime declare: anytype, text: []const u8) !*const Ui.Frame {
            var remaining = text;
            while (true) {
                var chunk_len = @min(remaining.len, Ui.limits.max_text_input_bytes);
                while (chunk_len < remaining.len and isContinuationByte(remaining[chunk_len])) chunk_len -= 1;
                const ended = try self.frame(app, declare, &.{.{ .text = remaining[0..chunk_len] }});
                remaining = remaining[chunk_len..];
                if (remaining.len == 0) return ended;
            }
        }

        /// Focus moves at the start of the next frame, which this runs.
        pub fn focus(self: *Self, app: anytype, comptime declare: anytype, element_id: zui.Id) !*const Ui.Frame {
            self.ui.requestFocus(element_id);
            return self.frame(app, declare, &.{});
        }
    };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

/// Writes one line per render command, in paint order, for golden-file
/// tests. Elements are named only when their id is a field of `names`
/// (a `zui.ids(...)` set, or any struct of `zui.Id` fields), so snapshots
/// don't change when unrelated internal ids do.
///
/// ```text
/// rect id=toolbar x=0 y=0 w=800 h=40 color=#202020
/// text x=12 y=12 w=32 h=16 size=16 color=#e8e8f0 "Save"
/// clip x=0 y=40 w=200 h=560
/// clip_end
/// ```
pub fn snapshot(writer: *std.Io.Writer, commands: anytype, names: anytype) std.Io.Writer.Error!void {
    for (commands) |command| {
        try writer.writeAll(@tagName(command.payload));
        if (nameOf(names, command.id)) |name| try writer.print(" id={s}", .{name});
        if (command.z != 0) try writer.print(" z={d}", .{command.z});
        switch (command.payload) {
            .clip_begin => |clip| try writeRect(writer, clip),
            .clip_end => {},
            else => try writeRect(writer, command.bounds),
        }
        switch (command.payload) {
            .rectangle => |rectangle| {
                try writeColor(writer, rectangle.color);
                try writeCorners(writer, rectangle.corner_radius);
            },
            .border => |border| {
                try writeColor(writer, border.color);
                try writeEdges(writer, border.widths);
                try writeCorners(writer, border.corner_radius);
            },
            .text => |text| {
                if (text.line != 0) try writer.print(" line={d}", .{text.line});
                try writeFont(writer, text.style.font);
                try writer.print(" size={d}", .{text.style.size});
                if (text.style.letter_spacing != 0) try writer.print(" spacing={d}", .{text.style.letter_spacing});
                try writeColor(writer, text.style.color);
                try writer.print(" \"{s}\"", .{text.content});
            },
            .image => |image| try writeHandle(writer, image.handle),
            .clip_begin, .clip_end, .custom => {},
        }
        try writer.writeByte('\n');
    }
}

/// Compares `snapshot(commands, names)` with `expected`, printing both on
/// a mismatch.
pub fn expectSnapshot(commands: anytype, names: anytype, expected: []const u8) !void {
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    try snapshot(&actual.writer, commands, names);
    try std.testing.expectEqualStrings(expected, actual.written());
}

fn nameOf(names: anytype, hash: u64) ?[]const u8 {
    inline for (@typeInfo(@TypeOf(names)).@"struct".fields) |field| {
        if (field.type != zui.Id) @compileError("zui_testing: snapshot names must be zui.Id fields; ." ++ field.name ++ " is " ++ @typeName(field.type));
        if (@field(names, field.name).hash == hash) return field.name;
    }
    return null;
}

fn writeRect(writer: *std.Io.Writer, rect: zui.Rect) !void {
    try writer.print(" x={d} y={d} w={d} h={d}", .{ rect.x, rect.y, rect.width, rect.height });
}

fn writeColor(writer: *std.Io.Writer, color: zui.Color) !void {
    try writer.print(" color=#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b });
    if (color.a != 255) try writer.print("{x:0>2}", .{color.a});
}

fn writeCorners(writer: *std.Io.Writer, corners: zui.CornerRadius) !void {
    if (std.meta.eql(corners, zui.CornerRadius.zero)) return;
    if (std.meta.eql(corners, zui.CornerRadius.all(corners.top_left))) return writer.print(" radius={d}", .{corners.top_left});
    try writer.print(" radius={d},{d},{d},{d}", .{ corners.top_left, corners.top_right, corners.bottom_left, corners.bottom_right });
}

fn writeEdges(writer: *std.Io.Writer, edges: zui.Edges) !void {
    if (std.meta.eql(edges, zui.Edges.all(edges.left))) return writer.print(" widths={d}", .{edges.left});
    try writer.print(" widths={d},{d},{d},{d}", .{ edges.left, edges.right, edges.top, edges.bottom });
}

fn writeFont(writer: *std.Io.Writer, font: anytype) !void {
    switch (@typeInfo(@TypeOf(font))) {
        .int => if (font != 0) try writer.print(" font={d}", .{font}),
        .@"enum" => if (@intFromEnum(font) != 0) try writer.print(" font={t}", .{font}),
        else => comptime unreachable,
    }
}

/// Only integer and enum handles are written; pointers would make
/// snapshots differ from run to run.
fn writeHandle(writer: *std.Io.Writer, handle: anytype) !void {
    switch (@typeInfo(@TypeOf(handle))) {
        .int => try writer.print(" handle={d}", .{handle}),
        .@"enum" => try writer.print(" handle={t}", .{handle}),
        else => {},
    }
}

pub const CommandError = error{ InvalidBounds, ZOrderDecreases, UnbalancedClip };

pub const Violation = struct {
    kind: CommandError,
    /// `commands.len` for a clip that is never ended.
    command_index: usize,
    reason: []const u8,
};

/// Checks what every frame's commands must satisfy, whatever the UI:
/// - bounds are finite and not negative in size;
/// - z never decreases;
/// - every `clip_begin` has a matching `clip_end`.
/// The first violation is printed with its command index.
pub fn checkCommands(commands: anytype) CommandError!void {
    const found = findViolation(commands) orelse return;
    std.debug.print("zui_testing.checkCommands: command {d}: {s}\n", .{ found.command_index, found.reason });
    return found.kind;
}

pub fn findViolation(commands: anytype) ?Violation {
    var open_clips: usize = 0;
    var previous_z: i16 = std.math.minInt(i16);
    for (commands, 0..) |command, index| {
        const bounds = switch (command.payload) {
            .clip_begin => |clip| clip,
            else => command.bounds,
        };
        for ([_]f32{ bounds.x, bounds.y, bounds.width, bounds.height }) |value| {
            if (!std.math.isFinite(value)) return .{ .kind = error.InvalidBounds, .command_index = index, .reason = "a bound is not finite" };
        }
        if (bounds.width < 0 or bounds.height < 0) return .{ .kind = error.InvalidBounds, .command_index = index, .reason = "the size is negative" };
        if (command.z < previous_z) return .{ .kind = error.ZOrderDecreases, .command_index = index, .reason = "z is lower than the previous command's" };
        previous_z = command.z;
        switch (command.payload) {
            .clip_begin => open_clips += 1,
            .clip_end => {
                if (open_clips == 0) return .{ .kind = error.UnbalancedClip, .command_index = index, .reason = "clip_end without clip_begin" };
                open_clips -= 1;
            },
            else => {},
        }
    }
    if (open_clips != 0) return .{ .kind = error.UnbalancedClip, .command_index = commands.len, .reason = "a clip_begin is never ended" };
    return null;
}

const TestText = FixedMetricsText(u16);
const TestUi = zui.Context(.{
    .limits = .{ .max_elements = 64, .max_text_bytes = 1024, .max_render_commands = 128, .state_slots = 64, .measure_cache_entries = 64 },
    .Text = TestText,
});

const Counter = struct {
    count: u32 = 0,

    const ids = zui.ids(.{ "panel", "increment" });

    fn declare(counter: *Counter, ui: *TestUi) void {
        if (ui.clicked(ids.increment)) counter.count += 1;
        ui.open(.{ .id = ids.panel, .decoration = .{ .background = .rgb(0x202020) }, .layout = .{ .padding = .all(8), .child_gap = 4 } });
        ui.box(.{ .id = ids.increment, .interactive = true, .decoration = .{ .background = .rgba(0x3366ff80), .corner_radius = .all(4) }, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(20) } } });
        ui.text("Add", .{ .color = .white });
        ui.close();
    }
};

fn initTestUi(text: *TestText) !TestUi {
    return .init(std.testing.allocator, std.testing.io, text);
}

test "the driver clicks by id" {
    var text_contract: TestText = .{};
    var ui = try initTestUi(&text_contract);
    defer ui.deinit(std.testing.allocator);
    var driver: Driver(TestUi) = .{ .ui = &ui };

    var counter: Counter = .{};
    try std.testing.expectError(error.ElementNotFound, driver.click(&counter, Counter.declare, Counter.ids.increment));
    _ = try driver.frame(&counter, Counter.declare, &.{});
    _ = try driver.click(&counter, Counter.declare, Counter.ids.increment);
    try std.testing.expectEqual(@as(u32, 1), counter.count);
    _ = try driver.clickAt(&counter, Counter.declare, Counter.ids.panel, .{ 0.95, 0.5 });
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}

test "snapshots name the ids they are given" {
    var text_contract: TestText = .{};
    var ui = try initTestUi(&text_contract);
    defer ui.deinit(std.testing.allocator);
    var driver: Driver(TestUi) = .{ .ui = &ui };

    var counter: Counter = .{};
    const frame = try driver.frame(&counter, Counter.declare, &.{});
    try checkCommands(frame.commands());
    try expectSnapshot(frame.commands(), Counter.ids,
        \\rectangle id=panel x=0 y=0 w=84 h=36 color=#202020
        \\rectangle id=increment x=8 y=8 w=40 h=20 color=#3366ff80 radius=4
        \\text x=52 y=8 w=24 h=16 size=16 color=#ffffff "Add"
        \\
    );
    try expectSnapshot(frame.commands(), .{ .panel = Counter.ids.panel },
        \\rectangle id=panel x=0 y=0 w=84 h=36 color=#202020
        \\rectangle x=8 y=8 w=40 h=20 color=#3366ff80 radius=4
        \\text x=52 y=8 w=24 h=16 size=16 color=#ffffff "Add"
        \\
    );
}

test "typeText splits long input at UTF-8 boundaries" {
    const Recorder = struct {
        received: [512]u8 = undefined,
        len: usize = 0,
        frames: usize = 0,

        fn declare(recorder: *@This(), ui: *TestUi) void {
            const typed = ui.typedText();
            @memcpy(recorder.received[recorder.len..][0..typed.len], typed);
            recorder.len += typed.len;
            recorder.frames += 1;
        }
    };
    var text_contract: TestText = .{};
    var ui = try initTestUi(&text_contract);
    defer ui.deinit(std.testing.allocator);
    var driver: Driver(TestUi) = .{ .ui = &ui };

    const text = "é" ** 200;
    var recorder: Recorder = .{};
    _ = try driver.typeText(&recorder, Recorder.declare, text);
    try std.testing.expectEqualStrings(text, recorder.received[0..recorder.len]);
    try std.testing.expectEqual(@as(usize, 2), recorder.frames);
}

test "the driver taps and drags with several fingers" {
    const Pad = struct {
        taps: u32 = 0,
        pressed_together: bool = false,

        fn declare(pad: *@This(), ui: *TestUi) void {
            if (ui.clicked(.of("pad"))) pad.taps += 1;
            if (ui.pressed(.of("pad")) and ui.pressed(.of("other"))) pad.pressed_together = true;
            ui.open(.{ .layout = .{ .child_gap = 10 } });
            ui.box(.{ .id = .of("pad"), .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(40) } } });
            ui.box(.{ .id = .of("other"), .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(40) } } });
            ui.close();
        }
    };
    var text_contract: TestText = .{};
    var ui = try initTestUi(&text_contract);
    defer ui.deinit(std.testing.allocator);
    var driver: Driver(TestUi) = .{ .ui = &ui };

    var pad: Pad = .{};
    _ = try driver.frame(&pad, Pad.declare, &.{});
    _ = try driver.tap(&pad, Pad.declare, .of("pad"));
    try std.testing.expectEqual(@as(u32, 1), pad.taps);
    _ = try driver.dragFingers(&pad, Pad.declare, .of("pad"), &.{
        .{ .from = .{ 0.5, 0.5 }, .to = .{ 0.5, 0.5 } },
        .{ .from = .{ 1.75, 0.5 }, .to = .{ 1.75, 0.5 } },
    });
    try std.testing.expect(pad.pressed_together);
    try std.testing.expectEqual(@as(u32, 2), pad.taps);
}

test "findViolation rejects broken command lists" {
    const Command = TestUi.RenderCommand;
    const rect: zui.Rect = .{ .width = 10, .height = 10 };
    const fill: Command.Payload = .{ .rectangle = .{ .color = .white, .corner_radius = .zero } };

    try checkCommands(&[_]Command{ .{ .bounds = rect, .id = 1, .payload = .{ .clip_begin = rect } }, .{ .bounds = rect, .id = 1, .payload = .clip_end } });
    try expectViolation(error.UnbalancedClip, 1, &.{.{ .bounds = rect, .id = 1, .payload = .{ .clip_begin = rect } }});
    try expectViolation(error.UnbalancedClip, 0, &.{.{ .bounds = rect, .id = 1, .payload = .clip_end }});
    try expectViolation(error.ZOrderDecreases, 1, &.{ .{ .bounds = rect, .id = 1, .z = 2, .payload = fill }, .{ .bounds = rect, .id = 2, .z = 1, .payload = fill } });
    try expectViolation(error.InvalidBounds, 0, &.{.{ .bounds = .{ .width = -1 }, .id = 1, .payload = fill }});
    try expectViolation(error.InvalidBounds, 0, &.{.{ .bounds = .{ .x = std.math.nan(f32) }, .id = 1, .payload = fill }});
}

fn expectViolation(kind: CommandError, command_index: usize, commands: []const TestUi.RenderCommand) !void {
    const found = findViolation(commands) orelse return error.TestExpectedViolation;
    try std.testing.expectEqual(kind, found.kind);
    try std.testing.expectEqual(command_index, found.command_index);
}
