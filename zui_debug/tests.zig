const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_debug = @import("zui_debug.zig");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{
        .max_elements = 64,
        .max_text_bytes = 4096,
        .max_render_commands = 256,
        .measure_cache_entries = 64,
    },
    .Text = Text,
    .ImageHandle = u32,
});
const Inspector = zui_debug.Inspector(Ui);
const Driver = zui_testing.Driver(Ui);

const toolbar_id: zui.Id = .of("toolbar");
const badge_id = toolbar_id.child("badge");
const second_card_id: zui.Id = .of("second card");
const raised_shadow: zui.Shadow = .{ .color = .black, .offset = .{ 0, 2 }, .blur = 4 };

const Toolbar = struct {
    inspector: Inspector = .{},

    fn declare(toolbar: *Toolbar, ui: *Ui) void {
        ui.open(.{ .id = toolbar_id, .layout = .{ .padding = .all(4), .child_gap = 2 }, .decoration = .{ .background = .white } });
        ui.text("Save", .{});
        ui.image(.{ .handle = 7, .natural_size = .{ 16, 16 } }, .{ .id = toolbar_id.child("icon") });
        ui.box(.{
            .id = badge_id,
            .layout = .{ .sizing = .{ .width = .fixed(6), .height = .fixed(6) } },
            .floating = .{ .attach_point = .top_right, .z = 2 },
            .effects = &.{ .shadow = raised_shadow },
        });
        ui.close();
        toolbar.inspector.declare(ui);
    }
};

const Fixture = struct {
    text: Text = .{},
    ui: Ui = undefined,
    driver: Driver = undefined,
    toolbar: Toolbar = .{},

    fn init(fixture: *Fixture) !void {
        fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
        fixture.driver = .{ .ui = &fixture.ui };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ui.deinit(testing.allocator);
    }

    fn observed(fixture: *Fixture, ended: *const Ui.Frame) *const Ui.Frame {
        const pointer = fixture.ui.primaryPointer();
        fixture.toolbar.inspector.observe(ended, if (pointer) |primary| primary.position else null);
        return ended;
    }

    fn frame(fixture: *Fixture) !*const Ui.Frame {
        return fixture.observed(try fixture.driver.frame(&fixture.toolbar, Toolbar.declare, &.{}));
    }

    fn hover(fixture: *Fixture, element_id: zui.Id) !*const Ui.Frame {
        return fixture.observed(try fixture.driver.hover(&fixture.toolbar, Toolbar.declare, element_id));
    }
};

fn panelLines(frame: anytype, buffer: [][]const u8) [][]const u8 {
    const panel = frame.lookup(Inspector.default_panel_id.hash) orelse return buffer[0..0];
    var count: usize = 0;
    for (panel..frame.inspect(panel).subtree_end) |index| {
        const element = frame.inspect(@intCast(index));
        if (element.content == .text and count < buffer.len) {
            buffer[count] = element.content.text.bytes;
            count += 1;
        }
    }
    return buffer[0..count];
}

fn expectLine(lines: []const []const u8, expected: []const u8) !void {
    for (lines) |line| if (std.mem.eql(u8, line, expected)) return;
    std.debug.print("no line \"{s}\" among:\n", .{expected});
    for (lines) |line| std.debug.print("  \"{s}\"\n", .{line});
    return error.TestExpectedEqual;
}

fn labelOf(comptime element_id: zui.Id, comptime debug_name: []const u8) []const u8 {
    if (Inspector.DebugName != void) return debug_name;
    return std.fmt.comptimePrint("0x{x:0>16}", .{element_id.hash});
}

test "the tree has a row per element, indented by depth, and never the panel's own" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    _ = try fixture.frame();
    const expected_kinds = [_]Inspector.Kind{ .root, .box, .text, .image, .box };
    const expected_depths = [_]u16{ 0, 1, 2, 2, 2 };
    for (0..2) |_| {
        _ = try fixture.frame();
        const rows = fixture.toolbar.inspector.rows();
        try testing.expectEqual(expected_kinds.len, rows.len);
        for (rows, expected_kinds, expected_depths) |row, kind, depth| {
            try testing.expectEqual(kind, row.kind);
            try testing.expectEqual(depth, row.depth);
        }
        try testing.expectEqual(toolbar_id.hash, rows[1].id);
        try testing.expectEqualStrings("Save", rows[2].textPreview());
    }

    const frame = try fixture.frame();
    var buffer: [64][]const u8 = undefined;
    const lines = panelLines(frame, &buffer);
    try expectLine(lines, "nothing under the pointer");
    try expectLine(lines, "every limit held");
    try expectLine(lines, "untimed, as Config.features.Tracer is not a zui_debug.ZoneTimer");
    try expectLine(lines, "shadow drawn as nothing, as the renderer's zui_commands leaves it out");
    try expectLine(lines, "    text \"Save\" 32x16");
    try expectLine(lines, "root 800x600");
    try expectLine(lines, "    " ++ comptime labelOf(badge_id, "badge") ++ " box 6x6");
}

test "the hovered element's configs are the ones it changed, and its row is highlighted" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    _ = try fixture.frame();
    _ = try fixture.hover(badge_id);
    const hovered = fixture.toolbar.inspector.hovered.?;
    try testing.expectEqual(badge_id.hash, hovered.row.id);
    try testing.expectEqual(@as(i16, 2), hovered.floating.?.z);
    try testing.expectEqual(raised_shadow, hovered.effects.?.shadow.?);

    const frame = try fixture.frame();
    var buffer: [64][]const u8 = undefined;
    const lines = panelLines(frame, &buffer);
    try expectLine(lines, "flags = explicit_id floating captures_pointer");
    try expectLine(lines, "rect = 58, 0, 6x6");
    try expectLine(lines, "layout.sizing = .{ .width = .{ .rule = .fixed, .amount = 6, .min = 6, .max = 6 }, .height = .{ .rule = .fixed, .amount = 6, .min = 6, .max = 6 } }");
    try expectLine(lines, "effects.shadow = .{ .color = #000000ff, .offset = .{ 0, 2 }, .blur = 4, .spread = 0 }");
    try expectLine(lines, "floating.attach_point = .top_right");
    try expectLine(lines, "floating.z = 2");

    const panel = frame.lookup(Inspector.default_panel_id.hash).?;
    var highlighted: ?[]const u8 = null;
    for (panel + 1..frame.inspect(panel).subtree_end) |index| {
        const element = frame.inspect(@intCast(index));
        if (element.decoration) |decoration| if (std.meta.eql(decoration.background, @as(?zui.Color, (Inspector.Theme{}).hovered_row))) {
            highlighted = frame.inspect(@intCast(index + 1)).content.text.bytes;
        };
    }
    try testing.expectStringEndsWith(highlighted.?, "box 6x6");
}

test "the pointer over the panel keeps the element it last showed" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    _ = try fixture.frame();
    _ = try fixture.hover(badge_id);
    _ = try fixture.hover(Inspector.default_panel_id);
    try testing.expectEqual(badge_id.hash, fixture.toolbar.inspector.hovered.?.row.id);
    try testing.expectEqual(@as(?u32, 4), fixture.toolbar.inspector.hovered_row);
}

test "a text element's configs are its style's changes and its row shows its start" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    const frame = try fixture.frame();
    const label_rect = frame.inspect(2).rect;
    fixture.toolbar.inspector.observe(frame, .{ label_rect.x + 1, label_rect.y + 1 });
    const hovered = fixture.toolbar.inspector.hovered.?;
    try testing.expectEqual(Inspector.Kind.text, hovered.row.kind);
    try testing.expectEqual(@as(f32, 16), hovered.content.text.size);

    const next = try fixture.driver.frame(&fixture.toolbar, Toolbar.declare, &.{});
    var buffer: [64][]const u8 = undefined;
    try expectLine(panelLines(next, &buffer), "text = .{}");
}

const ExtendedUi = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_text_bytes = 2048, .max_render_commands = 128, .measure_cache_entries = 32 },
    .Text = Text,
    .Color = zui.ExtendedColor,
    .MaterialHandle = u8,
});

test "an extended-color context's decoration shows its colors and material" {
    var text: Text = .{};
    var ui = try ExtendedUi.init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    const inspector = try testing.allocator.create(zui_debug.Inspector(ExtendedUi));
    defer testing.allocator.destroy(inspector);
    inspector.* = .{};
    var driver: zui_testing.Driver(ExtendedUi) = .{ .ui = &ui };

    const Scene = struct {
        fn declare(shown: *zui_debug.Inspector(ExtendedUi), declared: *ExtendedUi) void {
            declared.box(.{
                .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(40) } },
                .decoration = .{ .background = .linear(4, 4, 4, 1), .material = 2 },
            });
            shown.declare(declared);
        }
    };
    const frame = try driver.frame(inspector, Scene.declare, &.{});
    inspector.observe(frame, .{ 20, 20 });
    var buffer: [32][]const u8 = undefined;
    const lines = panelLines(try driver.frame(inspector, Scene.declare, &.{}), &buffer);
    try expectLine(lines, "decoration.background = .{ .r = 4, .g = 4, .b = 4, .a = 1 }");
    try expectLine(lines, "decoration.material = 2");
    try expectLine(lines, "material drawn as its fallback background, as the renderer's zui_commands leaves it out");
    try expectLine(lines, "colors clamped to Color, as the renderer does not declare zui_extended_color");
}

const OneEffectUi = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_text_bytes = 2048, .max_render_commands = 128, .measure_cache_entries = 32, .max_effects = 1 },
    .Text = Text,
    .commands = .initOne(.shadow),
});

test "a limit the frame exceeded is named by its field, with what the frame needed and the first element past it" {
    var text: Text = .{};
    var ui = try OneEffectUi.init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    const inspector = try testing.allocator.create(zui_debug.Inspector(OneEffectUi));
    defer testing.allocator.destroy(inspector);
    inspector.* = .{};
    const Scene = struct {
        fn frame(declared: *OneEffectUi, shown: *zui_debug.Inspector(OneEffectUi)) *const OneEffectUi.Frame {
            declared.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } }, .events = &.{} });
            declared.box(.{ .id = .of("first card"), .effects = &.{ .shadow = raised_shadow } });
            declared.box(.{ .id = second_card_id, .effects = &.{ .shadow = raised_shadow } });
            shown.declare(declared);
            const ended = declared.endFrame();
            declared.release(ended);
            return ended;
        }
    };
    inspector.observe(Scene.frame(&ui, inspector), null);
    try testing.expect(inspector.diagnostics.exceeded.contains(.max_effects));
    var buffer: [32][]const u8 = undefined;
    const lines = panelLines(Scene.frame(&ui, inspector), &buffer);
    try expectLine(lines, "limits.max_effects is 1; the frame needed 2");
    try expectLine(lines, "first past a limit: " ++ comptime labelOf(second_card_id, "second card"));
    try expectLine(lines, "none in effect");
}

test "a run's report is listed among the fallbacks, a line for each part" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    fixture.* = .{};
    try fixture.init();
    defer fixture.deinit();

    const Report = struct {
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("raylib with raylib; one window; no host clipboard, menus");
        }
    };
    fixture.toolbar.inspector.reportRun(Report{});
    _ = try fixture.frame();
    var buffer: [64][]const u8 = undefined;
    const lines = panelLines(try fixture.frame(), &buffer);
    try expectLine(lines, "raylib with raylib");
    try expectLine(lines, "one window");
    try expectLine(lines, "no host clipboard, menus");
}

test "a run's report too long to keep is cut before a codepoint it would split" {
    const inspector = try testing.allocator.create(Inspector);
    defer testing.allocator.destroy(inspector);
    inspector.* = .{};

    const LongReport = struct {
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.splatByteAll('a', 1023);
            try writer.writeAll("é and more");
        }
    };
    inspector.reportRun(LongReport{});
    try testing.expectEqual(@as(usize, 1023), inspector.runReport().len);
    try testing.expect(std.unicode.utf8ValidateSlice(inspector.runReport()));
}

const CountingTracer = struct {
    var zones_begun: u32 = 0;
    var zones_open: u32 = 0;

    pub fn zuiBegin(comptime _: zui.TraceZone) void {
        zones_begun += 1;
        zones_open += 1;
    }

    pub fn zuiEnd(_: void) void {
        zones_open -= 1;
    }
};

const CountedTimer = zui_debug.ZoneTimer(CountingTracer);
const UnclockedTimer = zui_debug.ZoneTimer(void);

fn TracedUi(comptime Tracer: type) type {
    return zui.Context(.{
        .limits = .{ .max_elements = 64, .max_text_bytes = 4096, .max_render_commands = 256, .measure_cache_entries = 64 },
        .Text = Text,
        .features = .{ .Tracer = Tracer },
    });
}

fn TracedScene(comptime TracedContext: type) type {
    return struct {
        fn declare(inspector: *zui_debug.Inspector(TracedContext), ui: *TracedContext) void {
            ui.text("traced", .{});
            ui.box(.{ .floating = .{ .z = 1 }, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .background = .black } });
            inspector.declare(ui);
        }
    };
}

fn TracedFixture(comptime Tracer: type) type {
    const TracedContext = TracedUi(Tracer);
    return struct {
        const Self = @This();

        text: Text = .{},
        ui: TracedContext = undefined,
        driver: zui_testing.Driver(TracedContext) = undefined,
        inspector: zui_debug.Inspector(TracedContext) = .{},

        fn create() !*Self {
            const fixture = try testing.allocator.create(Self);
            errdefer testing.allocator.destroy(fixture);
            fixture.* = .{};
            fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
            fixture.driver = .{ .ui = &fixture.ui };
            return fixture;
        }

        fn destroy(fixture: *Self) void {
            fixture.ui.deinit(testing.allocator);
            testing.allocator.destroy(fixture);
        }

        fn frame(fixture: *Self) !*const TracedContext.Frame {
            return fixture.driver.frame(&fixture.inspector, TracedScene(TracedContext).declare, &.{});
        }

        fn observedFrame(fixture: *Self) !void {
            fixture.inspector.observe(try fixture.frame(), null);
        }
    };
}

test "a zone timer times each zone a frame runs and passes each on to its inner tracer" {
    const fixture = try TracedFixture(CountedTimer).create();
    defer fixture.destroy();
    CountedTimer.useClock(testing.io);

    try fixture.observedFrame();
    const begun_before_frame = CountingTracer.zones_begun;
    try fixture.observedFrame();
    const times = CountedTimer.frameTimes();
    try testing.expectEqual(@as(u32, 0), CountingTracer.zones_open);
    try testing.expectEqual(@as(usize, CountingTracer.zones_begun - begun_before_frame), times.ran.count());

    const zones_run = [_]zui.TraceZone{ .begin_frame, .wait_for_frame, .evict_state, .apply_events, .end_frame, .measure_text, .fit_widths, .distribute_widths, .wrap_text, .fit_heights, .distribute_heights, .position, .emit, .sort_layers };
    for (zones_run) |zone| try testing.expect(times.ran.contains(zone));
    try testing.expect(!times.ran.contains(.swap_sources));
    try testing.expect(!times.ran.contains(.relay));
    try testing.expect(times.nanoseconds.get(.end_frame) >= times.nanoseconds.get(.emit) + times.nanoseconds.get(.position));
    try testing.expect(times.nanoseconds.get(.begin_frame) >= times.nanoseconds.get(.apply_events));

    try testing.expectEqual(@as(u8, 2), fixture.inspector.zones.count);
    try testing.expectEqual(times, fixture.inspector.zones.latest().?.*);
}

test "the panel lists each zone timed, with its last, mean and peak time" {
    const fixture = try TracedFixture(CountedTimer).create();
    defer fixture.destroy();

    for ([_]u64{ 3_000_000, 1_000_000, 2_000_000 }) |end_frame_nanoseconds| {
        var times: zui_debug.ZoneTimes = .{};
        times.nanoseconds.set(.end_frame, end_frame_nanoseconds);
        times.nanoseconds.set(.emit, end_frame_nanoseconds / 4);
        times.ran = .initMany(&.{ .end_frame, .emit });
        fixture.inspector.zones.record(times);
    }
    var buffer: [64][]const u8 = undefined;
    const lines = panelLines(try fixture.frame(), &buffer);
    try expectLine(lines, "ms in the last frame (mean, peak) over 3 frames");
    try expectLine(lines, "end_frame 2.000 (2.000, 3.000)");
    try expectLine(lines, "  emit 0.500 (0.500, 0.750)");
    for (lines) |line| try testing.expect(std.mem.indexOf(u8, line, "fit_widths") == null);
}

test "a zone timer without a clock times nothing, and the panel says so" {
    const fixture = try TracedFixture(UnclockedTimer).create();
    defer fixture.destroy();

    var buffer: [64][]const u8 = undefined;
    try expectLine(panelLines(try fixture.frame(), &buffer), "no frame observed yet");
    try fixture.observedFrame();
    try testing.expectEqual(@as(usize, 0), UnclockedTimer.frameTimes().ran.count());
    try expectLine(panelLines(try fixture.frame(), &buffer), "no zone timed yet; the ZoneTimer times from useClock(io)");
}

test "the zone history keeps the last frames, and a zone's mean counts only the frames it ran in" {
    var history: zui_debug.ZoneHistory = .{};
    try testing.expectEqual(@as(?*const zui_debug.ZoneTimes, null), history.latest());
    for (0..zui_debug.ZoneHistory.frames_kept + 5) |frame_number| {
        var times: zui_debug.ZoneTimes = .{};
        times.nanoseconds.set(.emit, frame_number);
        times.ran.insert(.emit);
        if (frame_number % 2 == 0) {
            times.nanoseconds.set(.sort_layers, 10);
            times.ran.insert(.sort_layers);
        }
        history.record(times);
    }
    try testing.expectEqual(@as(usize, zui_debug.ZoneHistory.frames_kept), history.kept().len);
    try testing.expectEqual(@as(u64, zui_debug.ZoneHistory.frames_kept + 4), history.latest().?.nanoseconds.get(.emit));
    try testing.expectEqual(@as(u64, zui_debug.ZoneHistory.frames_kept + 4), history.peak(.emit));
    try testing.expectEqual(@as(u64, (5 + zui_debug.ZoneHistory.frames_kept + 4) / 2), history.mean(.emit));
    try testing.expectEqual(@as(u64, 10), history.mean(.sort_layers));
    try testing.expect(!history.ran(.relay));
}
