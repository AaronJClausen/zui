const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const Ui = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_text_bytes = 64, .max_depth = 8, .max_render_commands = 64, .measure_cache_entries = 64 },
    .Text = support.FixedMetricsText,
    .features = .{ .semantics = true },
});

const ids = zui.ids(.{ "dialog", "save", "locked", "volume", "list", "name" });

const Dialog = struct {
    text_contract: support.FixedMetricsText = .{},
    ui: Ui = undefined,
    now: zui.Instant = .zero,
    /// The label is copied as it is declared, so the declaration reuses it.
    scratch: [16]u8 = undefined,

    fn init(dialog: *Dialog) !void {
        dialog.ui = try .init(testing.allocator, testing.io, &dialog.text_contract);
    }

    fn deinit(dialog: *Dialog) void {
        dialog.ui.deinit(testing.allocator);
    }

    fn frame(dialog: *Dialog, events: []const zui.Event) !*const Ui.Frame {
        dialog.now = dialog.now.addNanoseconds(support.frame_interval_ns);
        const ui = &dialog.ui;
        ui.beginFrame(&support.record(dialog.now, events));
        ui.open(.{ .id = ids.dialog, .focus_scope = true, .layout = .{ .direction = .top_to_bottom, .padding = .all(10) }, .semantics = .{ .role = .dialog, .label = "Settings" } });
        ui.box(.{ .id = ids.save, .focusable = true, .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(30) } }, .semantics = .{ .role = .button, .label = "Save" } });
        ui.box(.{ .id = ids.locked, .focusable = true, .disabled = true, .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(30) } }, .semantics = .{ .role = .button, .label = "Locked" } });
        ui.box(.{ .id = ids.volume, .focusable = true, .semantics = .{ .role = .slider, .value = .{ .range = .{ .value = 0.5, .step = 0.1 } }, .actions = .initOne(.adjust) } });
        ui.open(.{ .id = ids.list, .scroll = .{ .vertical = true }, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .height = .fixed(40) } }, .semantics = .{ .role = .list_box } });
        for (0..4) |row| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(60), .height = .fixed(20) } }, .semantics = .{ .role = .option, .label = std.fmt.bufPrint(&dialog.scratch, "Row {d}", .{row}) catch unreachable } });
        ui.close();
        ui.box(.{ .id = ids.name, .focusable = true, .semantics = .{ .role = .text_field, .label = "Name", .value = .{ .text = "Ada" } } });
        ui.close();
        const ended = ui.endFrame();
        ui.release(ended);
        return ended;
    }

    fn act(dialog: *Dialog, target: zui.Id, action: zui.Action) !*const Ui.Frame {
        return dialog.frame(&.{.{ .action = .{ .target = target.hash, .action = action } }});
    }
};

test "each element that declares semantics is listed in tree order, with what it is and can do" {
    var dialog: Dialog = .{};
    try dialog.init();
    defer dialog.deinit();
    _ = try dialog.frame(&.{});
    const frame = try dialog.frame(&.{});
    try frame.diagnostics.check();

    const nodes = frame.semantics();
    try testing.expectEqual(@as(usize, 10), nodes.len);
    try testing.expectEqual(zui.SemanticRole.dialog, nodes[0].role);
    try testing.expectEqualStrings("Settings", nodes[0].label);
    try testing.expectEqual(@as(?u32, null), nodes[0].parent);

    const save = nodes[1];
    try testing.expectEqual(ids.save.hash, save.id);
    try testing.expectEqual(@as(?u32, 0), save.parent);
    try testing.expectEqualStrings("Save", save.label);
    try testing.expectEqual(frame.rectOf(ids.save).?, save.bounds);
    try testing.expect(save.actions.eql(.initMany(&.{ .invoke, .focus })));
    try testing.expect(!save.state.disabled);

    const locked = nodes[2];
    try testing.expect(locked.state.disabled);
    try testing.expectEqual(@as(usize, 0), locked.actions.count());

    const volume = nodes[3];
    try testing.expectEqual(@as(f64, 0.5), volume.value.range.value);
    try testing.expect(volume.actions.eql(.initMany(&.{ .invoke, .focus, .adjust })));

    const list = nodes[4];
    try testing.expect(list.actions.contains(.scroll));
    for (nodes[5..9], 0..) |row, index| {
        try testing.expectEqual(@as(?u32, 4), row.parent);
        var expected: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Row {d}", .{index}), row.label);
    }

    const name = nodes[9];
    try testing.expectEqual(@as(?u32, 0), name.parent);
    try testing.expectEqualStrings("Ada", name.value.text);
}

test "actions are answered by the queries of the input they stand in for" {
    var dialog: Dialog = .{};
    try dialog.init();
    defer dialog.deinit();
    const ui = &dialog.ui;
    _ = try dialog.frame(&.{});

    _ = try dialog.act(ids.save, .invoke);
    try testing.expect(ui.clicked(ids.save));
    _ = try dialog.act(ids.locked, .invoke);
    try testing.expect(!ui.clicked(ids.locked));

    var frame = try dialog.act(ids.name, .focus);
    try testing.expect(ui.focused(ids.name));
    try testing.expect(frame.semantics()[9].state.focused);

    _ = try dialog.act(ids.volume, .{ .adjust = -3 });
    try testing.expectEqual(@as(?i32, -3), ui.adjusted(ids.volume));
    try testing.expectEqual(@as(?i32, null), ui.adjusted(ids.save));

    _ = try dialog.act(ids.list, .{ .scroll = .{ 0, 15 } });
    try testing.expectEqual([2]f32{ 0, 15 }, ui.scrollOffset(ids.list));
    try testing.expectEqual([2]f32{ 0, -15 }, ui.manipulation(ids.list).?.translation);
    frame = try dialog.act(ids.list, .{ .scroll = .{ 0, 500 } });
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(ids.list));

    _ = try dialog.act(ids.save, .show_menu);
    try testing.expect(ui.contextRequested(ids.save));

    _ = try dialog.act(ids.name, .dismiss);
    try testing.expect(ui.dismissed(ids.dialog));
    try testing.expect(ui.dismissed(ids.name));
    try testing.expect(!ui.dismissed(ids.save));
    _ = try dialog.frame(&.{});
    try testing.expect(!ui.dismissed(ids.dialog));
}

test "a label that does not fit the text bytes is cut at a character and reported" {
    const Small = zui.Context(.{ .limits = .{ .max_elements = 8, .max_text_bytes = 6 }, .features = .{ .semantics = true } });
    var ui: Small = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.box(.{ .semantics = .{ .role = .label, .label = "Café" } });
    ui.box(.{ .semantics = .{ .role = .label, .label = "là" } });
    const frame = ui.endFrame();
    defer ui.release(frame);

    try testing.expectEqualStrings("Café", frame.semantics()[0].label);
    try testing.expectEqualStrings("l", frame.semantics()[1].label);
    try testing.expect(frame.diagnostics.exceeded.contains(.max_text_bytes));
    try testing.expectEqual(@as(u32, 8), frame.diagnostics.needed.get(.max_text_bytes));
}

test "without the feature, an action is ignored" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    const save: zui.Id = .of("save");
    var ui = harness.begin();
    ui.box(.{ .id = save, .focusable = true, .semantics = .{ .role = .button, .label = "Save" } });
    _ = try harness.end();
    ui = harness.beginEvents(&.{.{ .action = .{ .target = save.hash, .action = .invoke } }});
    try testing.expect(!ui.clicked(save));
    ui.box(.{ .id = save, .focusable = true });
    _ = try harness.end();
}
