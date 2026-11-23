const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");

const testing = std.testing;
const design = zui.design;

/// Each character `size / 2` wide plus its spacing, and `size` tall.
const HalfEmText = struct {
    pub fn zuiMeasure(_: *HalfEmText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

const Ui = zui.Context(.{
    .limits = .{ .max_elements = 64, .max_text_bytes = 1024, .max_render_commands = 128 },
    .Text = HalfEmText,
    .features = .{ .safety_sweeps = true },
});

const white: zui.Color = .rgb(0xffffff);
const black: zui.Color = .rgb(0x000000);
const ring_color: zui.Color = .rgb(0x1a56db);

const options: zui_design.AuditOptions = .{ .page_background = white, .focus_ring_color = ring_color };

const Faults = struct {
    faint_text: bool = false,
    ring_on_its_own_color: bool = false,
    small_target: bool = false,
    cut_short: bool = false,
    overlap: bool = false,
};

const ids = struct {
    const faint = zui.Id.of("faint");
    const ring = zui.Id.of("ring");
    const small = zui.Id.of("small");
    const clipped = zui.Id.of("clipped");
    const first_button = zui.Id.of("first button");
    const second_button = zui.Id.of("second button");
};

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

/// A column of a heading, a ring, a button, a clipped line and a row of
/// two buttons, each drawn well unless `faults` says otherwise.
fn declareScene(ui: *Ui, faults: Faults) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 12, .padding = .all(16), .sizing = .grow_both } });
    {
        ui.open(.{ .id = ids.faint, .layout = .{ .padding = .all(4) } });
        ui.text("Harbor", .{ .color = if (faults.faint_text) .rgb(0xcccccc) else black, .wrap = .none });
        ui.close();

        const inside_ring: zui.Color = if (faults.ring_on_its_own_color) .rgb(0x2a5fe0) else white;
        ui.box(.{ .id = ids.ring, .layout = fixed(60, 30), .decoration = .{ .background = inside_ring, .border = .{ .color = ring_color, .widths = .all(2) } } });

        const button_side: f32 = if (faults.small_target) 12 else 32;
        ui.box(.{ .id = ids.small, .interactive = true, .layout = fixed(button_side, button_side), .decoration = .{ .background = .rgb(0xdddddd) } });

        ui.open(.{ .id = ids.clipped, .clip = .horizontal, .layout = fixed(if (faults.cut_short) 40 else 200, 20) });
        ui.text("A line too long", .{ .color = black, .wrap = .none });
        ui.close();

        ui.open(.{ .layout = .{ .child_gap = if (faults.overlap) -16 else 8 } });
        ui.box(.{ .id = ids.first_button, .interactive = true, .layout = fixed(40, 40) });
        ui.box(.{ .id = ids.second_button, .interactive = true, .layout = fixed(40, 40) });
        ui.close();
    }
    ui.close();
}

const Scene = struct {
    text: HalfEmText = .{},
    ui: Ui = undefined,

    fn init(scene: *Scene) !void {
        scene.ui = try .init(testing.allocator, testing.io, &scene.text);
    }

    fn deinit(scene: *Scene) void {
        scene.ui.deinit(testing.allocator);
    }

    fn frame(scene: *Scene, faults: Faults) *const Ui.Frame {
        scene.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 400, 400 } } });
        declareScene(&scene.ui, faults);
        return scene.ui.endFrame();
    }
};

const every_fault: Faults = .{ .faint_text = true, .ring_on_its_own_color = true, .small_target = true, .cut_short = true, .overlap = true };

fn findingOf(findings: *const zui_design.Findings, check: zui_design.AuditCheck) !zui_design.Finding {
    try testing.expectEqual(1, findings.countOf(check));
    for (findings.slice()) |finding| if (finding.check() == check) return finding;
    unreachable;
}

fn expectNames(frame: *const Ui.Frame, finding: zui_design.Finding, id: zui.Id) !void {
    try testing.expectEqual(id.hash, finding.id);
    try testing.expectEqual(@as(?u32, frame.lookup(id.hash).?), finding.element);
}

/// A finding of a text, which is an element of its own inside `id`.
fn expectInside(frame: *const Ui.Frame, finding: zui_design.Finding, id: zui.Id) !void {
    const text_element = frame.inspect(@intCast(finding.element.?));
    try testing.expectEqual(text_element.id, finding.id);
    try testing.expectEqual(frame.lookup(id.hash).?, text_element.parent.?);
}

test "a clean scene audits clean" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    const frame = scene.frame(.{});
    defer scene.ui.release(frame);
    var room: [8]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    for (findings.slice()) |finding| std.debug.print("unexpected: {any}\n", .{finding});
    try testing.expect(findings.isEmpty());
}

test "a scene with one fault of each kind reports exactly those, each naming its element and value" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    const frame = scene.frame(every_fault);
    defer scene.ui.release(frame);
    var room: [8]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    try testing.expectEqual(5, findings.slice().len);
    try testing.expectEqual(0, findings.dropped);

    const faint = try findingOf(&findings, .text_contrast);
    try expectInside(frame, faint, ids.faint);
    try testing.expectEqual(zui.Color.rgb(0xcccccc), faint.measured.text_contrast.foreground);
    try testing.expectEqual(white, faint.measured.text_contrast.background);
    try testing.expect(@abs(faint.measured.text_contrast.measured.lightness_contrast) < 75);
    try testing.expectEqual(75, faint.measured.text_contrast.target.lightness_contrast);

    const ring = try findingOf(&findings, .focus_ring_contrast);
    try expectNames(frame, ring, ids.ring);
    try testing.expect(ring.measured.focus_ring_contrast.measured.ratio < 3);
    try testing.expectEqual(zui.Color.rgb(0x2a5fe0), ring.measured.focus_ring_contrast.background);

    const small = try findingOf(&findings, .target_size);
    try expectNames(frame, small, ids.small);
    try testing.expectEqual([2]f32{ 12, 12 }, small.measured.target_size.size);
    try testing.expectEqual(24, small.measured.target_size.floor);

    const cut = try findingOf(&findings, .text_cut_short);
    try expectInside(frame, cut, ids.clipped);
    try testing.expectEqual(15 * 8, cut.measured.text_cut_short.line_width);
    try testing.expectEqual(40, cut.measured.text_cut_short.shown_width);

    const overlap = try findingOf(&findings, .overlapping_controls);
    try expectNames(frame, overlap, ids.first_button);
    try testing.expectEqual(ids.second_button.hash, overlap.measured.overlapping_controls.other_id);
    try testing.expectEqual(16, overlap.measured.overlapping_controls.overlap.width);
    try testing.expectEqual(40, overlap.measured.overlapping_controls.overlap.height);
}

test "room for fewer findings than faults keeps the first and counts the rest" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    const frame = scene.frame(every_fault);
    defer scene.ui.release(frame);
    var all_room: [8]zui_design.Finding = undefined;
    const all = zui_design.audit(frame, options, &all_room);
    var room: [2]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    try testing.expectEqual(2, findings.slice().len);
    try testing.expectEqual(3, findings.dropped);
    try testing.expect(!findings.isEmpty());
    try testing.expectEqualDeep(all.slice()[0..2], findings.slice());
}

test "the checks an audit is not asked for find nothing" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    const frame = scene.frame(every_fault);
    defer scene.ui.release(frame);
    var room: [8]zui_design.Finding = undefined;
    var only_targets = options;
    only_targets.checks = .initOne(.target_size);
    const findings = zui_design.audit(frame, only_targets, &room);
    try testing.expectEqual(1, findings.slice().len);
    try testing.expectEqual(.target_size, findings.slice()[0].check());
}

test "text is measured against translucent fills blended over what is beneath, and a disabled control's text is not measured" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    scene.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 200, 200 } } });
    scene.ui.open(.{ .layout = .{ .direction = .top_to_bottom, .padding = .all(8), .child_gap = 8 } });
    scene.ui.open(.{ .id = .of("veiled"), .decoration = .{ .background = .rgba(0x00000080) } });
    scene.ui.text("Veiled", .{ .color = .rgb(0x777777), .wrap = .none });
    scene.ui.close();
    scene.ui.open(.{ .id = .of("off"), .interactive = true, .disabled = true, .layout = fixed(80, 30) });
    scene.ui.text("Off", .{ .color = .rgb(0xeeeeee), .wrap = .none });
    scene.ui.close();
    scene.ui.close();
    const frame = scene.ui.endFrame();
    defer scene.ui.release(frame);
    var room: [4]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    const veiled = try findingOf(&findings, .text_contrast);
    try testing.expectEqual(zui.Color.rgb(0x7f7f7f), veiled.measured.text_contrast.background);
    try testing.expectEqual(1, findings.slice().len);
}

test "large text is held to the large text's target" {
    var scene: Scene = .{};
    try scene.init();
    defer scene.deinit();
    scene.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 400, 200 } } });
    scene.ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    scene.ui.text("Title", .{ .size = 24, .color = .rgb(0x808080), .wrap = .none });
    scene.ui.text("Body", .{ .size = 15, .color = .rgb(0x808080), .wrap = .none });
    scene.ui.close();
    const frame = scene.ui.endFrame();
    defer scene.ui.release(frame);
    var room: [4]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    const body = try findingOf(&findings, .text_contrast);
    try testing.expectEqualStrings("Body", frame.inspect(@intCast(body.element.?)).content.text.bytes);
}

const harbor: design.Design = .{
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
};

const LookalikeTabs = struct {
    pub const Part = enum { tab, tab_selected, label, status_failed, status_passed };

    pub const zuiAppearance = design.Appearance(Part, .{
        .tab = .{ .surface = .secondary_container, .shape = .control },
        .tab_selected = .{ .surface = .secondary_container, .shape = .control },
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .tab },
        .status_failed = .{ .surface = .danger, .shape = .chip, .cue = "a cross before its label" },
        .status_passed = .{ .surface = .success, .shape = .chip },
    });

    pub const zuiDistinguish = .{
        .{ .tab, .tab_selected },
        .{ .status_failed, .status_passed },
    };
};

const ApartTabs = struct {
    pub const Part = enum { tab, tab_selected };

    pub const zuiAppearance = design.Appearance(Part, .{
        .tab = .{ .surface = .surface, .shape = .control },
        .tab_selected = .{ .surface = .surface_inverse, .shape = .control },
    });

    pub const zuiDistinguish = .{
        .{ .tab, .tab_selected },
    };
};

test "a zuiDistinguish pair drawn alike in the tokens is found, and one with a cue or apart is not" {
    var tokens: design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(harbor, .{}, &tokens);
    var room: [4]zui_design.Finding = undefined;
    var findings: zui_design.Findings = .init(&room);
    zui_design.auditDistinguished(&tokens, .{ LookalikeTabs, ApartTabs }, &findings);
    try testing.expectEqual(1, findings.slice().len);
    const alike = findings.slice()[0].measured.distinguish;
    try testing.expectEqual(null, findings.slice()[0].element);
    try testing.expectEqualStrings("tab", alike.first_part);
    try testing.expectEqualStrings("tab_selected", alike.second_part);
    try testing.expect(std.mem.endsWith(u8, alike.component, "LookalikeTabs"));
    try testing.expectEqual(0, alike.lightness_difference);
    try testing.expectEqual(zui_design.least_lightness_difference, alike.least);
}

test "options from tokens take their page, focus ring, floor and title size" {
    var tokens: design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(harbor, .{ .theme = .dark, .pointer = .touch }, &tokens);
    const from_tokens: zui_design.AuditOptions = .fromTokens(&tokens, .high);
    try testing.expectEqual(tokens.colors.get(.idle).get(.background), from_tokens.page_background);
    try testing.expectEqual(tokens.colors.get(.focused).get(.focus), from_tokens.focus_ring_color.?);
    try testing.expectEqual(44, from_tokens.target_floor);
    try testing.expectEqual(tokens.text_styles.get(.title).size, from_tokens.large_text_size);
    try testing.expectEqual(.high, from_tokens.contrast);
}
