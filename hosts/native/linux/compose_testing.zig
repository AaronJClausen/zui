const std = @import("std");
const zui = @import("zui");
const zui_host = @import("zui_host");
const zui_testing = @import("zui_testing");
const xkb = zui_host.linux.xkb;

const testing = std.testing;

/// Gives `window_host` a US international keymap, whose apostrophe is a
/// dead acute, with right Alt as `Multi_key`, and a compose table of two
/// sequences, so the tests depend on neither the machine's keymap nor its
/// locale.
pub fn useComposingKeyboard(window_host: anytype) !void {
    const names: xkb.RuleNames = .{ .layout = "us", .variant = "intl", .options = "compose:ralt" };
    const keymap = xkb.xkb_keymap_new_from_names(window_host.xkb_context, &names, 0) orelse return error.SkipZigTest;
    const state = xkb.xkb_state_new(keymap) orelse {
        xkb.xkb_keymap_unref(keymap);
        return error.SkipZigTest;
    };
    if (window_host.key_state) |old| xkb.xkb_state_unref(old);
    if (window_host.keymap) |old| xkb.xkb_keymap_unref(old);
    window_host.keymap = keymap;
    window_host.key_state = state;
    window_host.compose.deinit();
    window_host.compose = .fromText(window_host.xkb_context, "<dead_acute> <e> : \"\u{e9}\"\n<Multi_key> <o> <c> : \"\u{a9}\"\n");
    try testing.expect(window_host.compose.state != null);
}

const evdev_apostrophe = 40;
const evdev_e = 18;
const evdev_o = 24;
const evdev_c = 46;
const evdev_q = 16;
const evdev_right_alt = 100;

fn typedText(polled: *const zui_testing.PolledRecord, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (polled.builder.events()) |event| if (event == .text) {
        @memcpy(buffer[len..][0..event.text.len], event.text);
        len += event.text.len;
    };
    return buffer[0..len];
}

fn keysDown(polled: *const zui_testing.PolledRecord) usize {
    var count: usize = 0;
    for (polled.builder.events()) |event| if (event == .key_down) {
        count += 1;
    };
    return count;
}

/// A dead acute and `e` type "é" once, `Multi_key` `o` `c` types "©", a
/// cancelled sequence types nothing, and every press still reaches the
/// record as a key. `press(host, evdev_code, pressed)` delivers a key as
/// the display server would.
pub fn expectComposes(window_host: anytype, comptime press: anytype) !void {
    try useComposingKeyboard(window_host);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    var buffer: [64]u8 = undefined;

    for ([_]u32{ evdev_apostrophe, evdev_e }) |code| {
        press(window_host, code, true);
        press(window_host, code, false);
    }
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("\u{e9}", typedText(&polled, &buffer));
    try testing.expectEqual(@as(usize, 2), keysDown(&polled));

    for ([_]u32{ evdev_right_alt, evdev_o, evdev_c }) |code| {
        press(window_host, code, true);
        press(window_host, code, false);
    }
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("\u{a9}", typedText(&polled, &buffer));
    try testing.expectEqual(@as(usize, 3), keysDown(&polled));

    for ([_]u32{ evdev_apostrophe, evdev_q }) |code| {
        press(window_host, code, true);
        press(window_host, code, false);
    }
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("", typedText(&polled, &buffer));
    try testing.expectEqual(@as(usize, 2), keysDown(&polled));

    press(window_host, evdev_e, true);
    press(window_host, evdev_e, false);
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("e", typedText(&polled, &buffer));
}
