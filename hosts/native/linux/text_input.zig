const std = @import("std");
const zui = @import("zui");
const wayland = @import("wayland.zig");
const Proxy = wayland.Proxy;

/// The seat's `zwp_text_input_v3`: an input method's text, enabled while a
/// frame asks for text input and the compositor's text-input focus is on
/// the window. It sends requests only when what a frame asks for differs
/// from what it last committed, so an idle frame sends nothing. Committed
/// text is handed over on `done`; composing text (the preedit) is kept but
/// not reported, since the record has no place for it yet. No surrounding
/// text or content type is sent.
pub const TextInput = struct {
    /// Null where the compositor offers no text-input manager; the state
    /// still follows the events a harness delivers.
    proxy: ?*Proxy = null,
    /// Requests sent while the focus is elsewhere are ignored by the
    /// compositor, so none are.
    entered: bool = false,
    /// What the last commit enabled; null for disabled. Entering and
    /// leaving invalidate it, as they do the compositor's.
    committed_caret: ?CursorRectangle = null,
    /// Counted as the compositor counts them, for `done`'s serial.
    commits: u32 = 0,
    requests_sent: u32 = 0,

    pending_commit: Text = .{},
    pending_preedit: Preedit = .{},
    preedit: Preedit = .{},
    pending_left_out_bytes: u32 = 0,

    /// The most a Wayland message carries, so no string an event brings is
    /// longer.
    pub const text_capacity = 4096;

    /// In surface coordinates.
    pub const CursorRectangle = struct {
        x: i32,
        y: i32,
        width: i32,
        height: i32,

        /// The surface coordinates covering `caret`, in layout units, at
        /// least one wide and one high.
        pub fn covering(caret: zui.Rect, surface_coordinates_per_unit: f32) CursorRectangle {
            const left = surfaceCoordinate(@floor(caret.x * surface_coordinates_per_unit));
            const top = surfaceCoordinate(@floor(caret.y * surface_coordinates_per_unit));
            const right = surfaceCoordinate(@ceil((caret.x + caret.width) * surface_coordinates_per_unit));
            const bottom = surfaceCoordinate(@ceil((caret.y + caret.height) * surface_coordinates_per_unit));
            return .{ .x = left, .y = top, .width = @max(1, right - left), .height = @max(1, bottom - top) };
        }

        fn surfaceCoordinate(value: f32) i32 {
            const farthest = 1 << 30;
            return @intFromFloat(std.math.clamp(value, -farthest, farthest));
        }
    };

    pub const Text = struct {
        bytes: [text_capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Text) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Keeps none of a text that does not fit, and returns its length.
        pub fn set(self: *Text, utf8: []const u8) u32 {
            if (utf8.len > text_capacity) {
                self.len = 0;
                return @intCast(utf8.len);
            }
            @memcpy(self.bytes[0..utf8.len], utf8);
            self.len = utf8.len;
            return 0;
        }
    };

    /// The input method's composing text, with its cursor in bytes into
    /// it; both ends -1 hide the cursor.
    pub const Preedit = struct {
        text: Text = .{},
        cursor_begin: i32 = 0,
        cursor_end: i32 = 0,
    };

    pub const Applied = struct {
        committed_text: []const u8,
        left_out_bytes: u32,
    };

    pub fn open(self: *TextInput, manager: *Proxy, seat: *Proxy) ?*Proxy {
        self.proxy = wayland.create(manager, wayland.text_input_manager_get_text_input, &wayland.text_input_interface, 1, .{ wayland.no_id, seat });
        return self.proxy;
    }

    pub fn deinit(self: *TextInput) void {
        if (self.proxy) |proxy| wayland.destroy(proxy, wayland.text_input_destroy);
        self.proxy = null;
    }

    /// Enables at `caret`, moves the rectangle to it, or, for null,
    /// disables, committing only what changed.
    pub fn apply(self: *TextInput, caret: ?CursorRectangle) void {
        if (!self.entered or std.meta.eql(self.committed_caret, caret)) return;
        if (caret) |rectangle| {
            if (self.committed_caret == null) {
                self.send(wayland.text_input_enable, .{});
                self.forgetComposition();
            }
            self.send(wayland.text_input_set_cursor_rectangle, .{ rectangle.x, rectangle.y, rectangle.width, rectangle.height });
        } else {
            self.send(wayland.text_input_disable, .{});
            self.forgetComposition();
        }
        self.send(wayland.text_input_commit, .{});
        self.commits +%= 1;
        self.committed_caret = caret;
    }

    pub fn onEnter(self: *TextInput) void {
        self.entered = true;
        self.committed_caret = null;
    }

    pub fn onLeave(self: *TextInput) void {
        self.entered = false;
        self.committed_caret = null;
        self.forgetComposition();
    }

    pub fn onPreeditString(self: *TextInput, utf8: ?[]const u8, cursor_begin: i32, cursor_end: i32) void {
        self.pending_left_out_bytes +|= self.pending_preedit.text.set(utf8 orelse "");
        self.pending_preedit.cursor_begin = cursor_begin;
        self.pending_preedit.cursor_end = cursor_end;
    }

    pub fn onCommitString(self: *TextInput, utf8: ?[]const u8) void {
        self.pending_left_out_bytes +|= self.pending_commit.set(utf8 orelse "");
    }

    /// Applies what the events since the last `done` set, and returns the
    /// text committed, valid until the next event, and what was left out.
    pub fn onDone(self: *TextInput) Applied {
        self.preedit = self.pending_preedit;
        self.pending_preedit = .{};
        const applied: Applied = .{ .committed_text = self.pending_commit.slice(), .left_out_bytes = self.pending_left_out_bytes };
        self.pending_commit.len = 0;
        self.pending_left_out_bytes = 0;
        return applied;
    }

    pub fn preeditText(self: *const TextInput) []const u8 {
        return self.preedit.text.slice();
    }

    fn forgetComposition(self: *TextInput) void {
        self.pending_commit.len = 0;
        self.pending_preedit = .{};
        self.preedit = .{};
        self.pending_left_out_bytes = 0;
    }

    fn send(self: *TextInput, opcode: u32, arguments: anytype) void {
        self.requests_sent += 1;
        if (self.proxy) |proxy| wayland.send(proxy, opcode, arguments);
    }
};

test "a caret's rectangle covers it in whole surface coordinates, and is never empty" {
    const covered: TextInput.CursorRectangle = .covering(.{ .x = 10, .y = 20, .width = 0.5, .height = 16 }, 1.25);
    try std.testing.expectEqual(TextInput.CursorRectangle{ .x = 12, .y = 25, .width = 2, .height = 20 }, covered);
    const empty: TextInput.CursorRectangle = .covering(.{ .x = 4, .y = 4 }, 1);
    try std.testing.expectEqual(TextInput.CursorRectangle{ .x = 4, .y = 4, .width = 1, .height = 1 }, empty);
}

test "a commit string that does not fit is left out whole and counted" {
    var text_input: TextInput = .{};
    var too_long: [TextInput.text_capacity + 1]u8 = @splat('a');
    text_input.onCommitString(&too_long);
    const applied = text_input.onDone();
    try std.testing.expectEqualStrings("", applied.committed_text);
    try std.testing.expectEqual(@as(u32, too_long.len), applied.left_out_bytes);
}
