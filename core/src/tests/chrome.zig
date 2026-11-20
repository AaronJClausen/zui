const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const small_limits: zui.Limits = .{ .max_elements = 32, .max_depth = 8, .max_render_commands = 64 };
const ChromeUi = zui.Context(.{ .limits = small_limits, .features = .{ .chrome_regions = true } });
const PlainUi = zui.Context(.{ .limits = small_limits });

const ids = zui.ids(.{ "title_bar", "search", "tabs", "tab", "caption_close", "label", "content", "grip", "scroller", "locked" });

const title_height = 32;

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

/// A title bar holding a search field, an interactive tab strip with a
/// caption button inside it, a label, and a close button; then content with
/// a resize grip in its corner.
fn declareWindow(ui: anytype) void {
    ui.open(.{ .id = .of("window"), .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    {
        ui.open(.{ .id = ids.title_bar, .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(title_height) } } });
        defer ui.close();
        ui.box(.{ .id = ids.search, .focusable = true, .layout = fixed(120, 24) });
        {
            ui.open(.{ .id = ids.tabs, .interactive = true, .layout = fixed(80, 24) });
            defer ui.close();
            ui.box(.{ .id = ids.tab, .interactive = true, .chrome = .maximize_button, .layout = fixed(20, 24) });
        }
        ui.box(.{ .id = ids.label, .layout = fixed(60, 24) });
        ui.box(.{ .id = ids.caption_close, .interactive = true, .chrome = .close_button, .layout = fixed(46, title_height) });
    }
    {
        ui.open(.{ .id = ids.content, .interactive = true, .layout = .{ .sizing = .grow_both } });
        defer ui.close();
        ui.box(.{ .id = ids.grip, .chrome = .resize_bottom_right, .layout = fixed(16, 16) });
    }
    ui.close();
}

fn endedFrame(ui: anytype, comptime declare: anytype) *const @TypeOf(ui.*).Frame {
    ui.beginFrame(&support.record(.fromNanoseconds(support.frame_interval_ns), &.{}));
    declare(ui);
    const frame = ui.endFrame();
    ui.release(frame);
    return frame;
}

fn expectRegion(region: zui.ChromeRegion, kind: zui.ChromeKind, id: zui.Id, frame: *const ChromeUi.Frame) !void {
    try testing.expectEqual(kind, region.kind);
    try testing.expectEqual(id.hash, region.id);
    try testing.expectEqual(frame.rectOf(id).?, region.bounds);
}

test "declared chrome is listed in tree order with its laid-out bounds, and a title bar's interactive elements stay the application's" {
    var ui: ChromeUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    const frame = endedFrame(&ui, declareWindow);
    try frame.diagnostics.check();

    const regions = frame.chromeRegions();
    try testing.expectEqual(@as(usize, 6), regions.len);
    try expectRegion(regions[0], .title_bar, ids.title_bar, frame);
    try expectRegion(regions[1], .client, ids.search, frame);
    try expectRegion(regions[2], .client, ids.tabs, frame);
    try expectRegion(regions[3], .maximize_button, ids.tab, frame);
    try expectRegion(regions[4], .close_button, ids.caption_close, frame);
    try expectRegion(regions[5], .resize_bottom_right, ids.grip, frame);
    try testing.expectEqual(@as(f32, title_height), regions[0].bounds.height);
}

fn declareTitleBarWithScrollingAndDisabled(ui: anytype) void {
    ui.open(.{ .id = ids.title_bar, .chrome = .title_bar, .layout = fixed(300, title_height) });
    ui.box(.{ .id = ids.scroller, .scroll = .{ .horizontal = true, .vertical = false }, .layout = fixed(40, 20) });
    ui.box(.{ .id = ids.locked, .disabled = true, .layout = fixed(40, 20) });
    ui.box(.{ .id = ids.label, .layout = fixed(40, 20) });
    ui.close();
    ui.box(.{ .id = ids.content, .interactive = true, .layout = fixed(40, 20) });
}

test "a scrolling or disabled element inside a title bar is the application's, and one outside every title bar is not listed" {
    var ui: ChromeUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    const frame = endedFrame(&ui, declareTitleBarWithScrollingAndDisabled);
    const regions = frame.chromeRegions();
    try testing.expectEqual(@as(usize, 3), regions.len);
    try expectRegion(regions[0], .title_bar, ids.title_bar, frame);
    try expectRegion(regions[1], .client, ids.scroller, frame);
    try expectRegion(regions[2], .client, ids.locked, frame);
}

fn declareNoChrome(ui: anytype) void {
    ui.box(.{ .id = ids.content, .interactive = true, .layout = fixed(40, 20) });
}

test "a frame that declares no chrome lists none, even after one that did" {
    var ui: ChromeUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    _ = endedFrame(&ui, declareWindow);
    _ = endedFrame(&ui, declareWindow);
    try testing.expectEqual(@as(usize, 0), endedFrame(&ui, declareNoChrome).chromeRegions().len);
}

test "chrome declared in a context without the feature changes nothing" {
    var plain: PlainUi = try .init(testing.allocator, testing.io);
    defer plain.deinit(testing.allocator);
    var with_chrome: ChromeUi = try .init(testing.allocator, testing.io);
    defer with_chrome.deinit(testing.allocator);
    const plain_frame = endedFrame(&plain, declareWindow);
    const chrome_frame = endedFrame(&with_chrome, declareWindow);
    try testing.expectEqual(chrome_frame.elementCount(), plain_frame.elementCount());
    try testing.expectEqual(chrome_frame.commands().len, plain_frame.commands().len);
    try testing.expectEqual(chrome_frame.rectOf(ids.caption_close).?, plain_frame.rectOf(ids.caption_close).?);
}
