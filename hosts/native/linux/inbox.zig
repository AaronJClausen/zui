const std = @import("std");
const zui = @import("zui");
const data_device = @import("data_device.zig");

/// What reached a window since its last poll. Positions are in the
/// window's surface coordinates until `drainInto` converts them.
pub const Inbox = struct {
    events: [event_capacity]zui.Event = undefined,
    event_count: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    paths: [path_capacity]u8 = undefined,
    path_len: usize = 0,
    dropped_events: u32 = 0,
    dropped_bytes: u32 = 0,

    pub const event_capacity = 512;
    pub const text_capacity = 1024;
    pub const path_capacity = 16 * 1024;

    pub fn push(self: *Inbox, event: zui.Event) void {
        if (self.event_count == event_capacity) {
            self.dropped_events +|= 1;
            return;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    /// Consecutive characters become one text event.
    pub fn pushText(self: *Inbox, utf8: []const u8) void {
        if (utf8.len > text_capacity - self.text_len) {
            self.dropped_bytes +|= @intCast(utf8.len);
            return;
        }
        const start = self.text_len;
        @memcpy(self.text[start..][0..utf8.len], utf8);
        self.text_len += utf8.len;
        if (self.event_count > 0) {
            const last = &self.events[self.event_count - 1];
            if (last.* == .text and last.text.ptr + last.text.len == self.text[start..].ptr) {
                last.text = self.text[start - last.text.len .. self.text_len];
                return;
            }
        }
        self.push(.{ .text = self.text[start..self.text_len] });
    }

    /// One event for the local files a URI list names; none when it
    /// names none that fit.
    pub fn pushFilesDropped(self: *Inbox, position: [2]f32, uri_list: []const u8, at: zui.Instant) void {
        const start = self.path_len;
        const decoded = data_device.pathsFromUriList(uri_list, self.paths[start..]);
        self.dropped_bytes +|= decoded.left_out_bytes;
        if (decoded.len == 0) return;
        self.path_len += decoded.len;
        self.push(.{ .files_dropped = .{ .position = position, .path_list = self.paths[start..self.path_len], .at = at } });
    }

    /// Appends every event to `record`, its positions divided by
    /// `surface_coordinates_per_unit`, and empties the inbox. True when one
    /// of them was a terminate request.
    pub fn drainInto(self: *Inbox, record: *zui.RecordBuilder, surface_coordinates_per_unit: f32) bool {
        var terminate_requested = false;
        for (self.events[0..self.event_count]) |queued| {
            const converted = inLayoutUnits(queued, surface_coordinates_per_unit);
            switch (converted) {
                .text => |text| record.appendText(text),
                .files_dropped => |drop| record.appendFilesDropped(drop),
                .lifecycle => |change| {
                    if (change == .terminate_requested) terminate_requested = true;
                    record.append(converted);
                },
                else => record.append(converted),
            }
        }
        record.dropped_events +|= self.dropped_events;
        record.dropped_text_bytes +|= self.dropped_bytes;
        self.* = .{};
        return terminate_requested;
    }

    fn inLayoutUnits(queued: zui.Event, surface_coordinates_per_unit: f32) zui.Event {
        var converted = queued;
        switch (converted) {
            .pointer_down, .pointer_up => |*press| scalePosition(&press.pointer.position, surface_coordinates_per_unit),
            .pointer_move => |*move| scalePosition(&move.pointer.position, surface_coordinates_per_unit),
            .wheel => |*wheel| scalePosition(&wheel.position, surface_coordinates_per_unit),
            .files_dropped => |*drop| scalePosition(&drop.position, surface_coordinates_per_unit),
            else => {},
        }
        return converted;
    }

    fn scalePosition(position: *[2]f32, surface_coordinates_per_unit: f32) void {
        position.* = .{ position[0] / surface_coordinates_per_unit, position[1] / surface_coordinates_per_unit };
    }
};
