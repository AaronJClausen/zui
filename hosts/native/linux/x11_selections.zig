const std = @import("std");
const zui = @import("zui");
const x11 = @import("x11.zig");
const data_device = @import("data_device.zig");

/// Where a window's selections are written and read: the connection, the
/// window and the atoms they are named by.
pub const Endpoint = struct {
    connection: *x11.Connection,
    window: x11.Window,
    atoms: *const x11.Atoms,
};

/// A selection's owner writing it into a property of the window, whole or,
/// for `INCR`, in chunks the window takes one at a time. What does not fit
/// the buffer is read, left out and counted.
pub const Transfer = struct {
    property: x11.Atom,
    buffer: []u8,
    len: usize = 0,
    left_out_bytes: usize = 0,
    incremental: bool = false,
    deadline: zui.Instant,

    pub const Progress = enum { more_to_come, finished, nothing_written };

    /// Takes what the owner wrote into the property, deleting it, which
    /// for `INCR` asks the owner for the next chunk.
    pub fn take(self: *Transfer, endpoint: Endpoint, deadline: zui.Instant) Progress {
        const connection = endpoint.connection;
        const cookie = x11.xcb_get_property(connection, 1, endpoint.window, self.property, x11.any_property_type, 0, std.math.maxInt(u32) / 4);
        const reply = x11.xcb_get_property_reply(connection, cookie, null) orelse return .nothing_written;
        defer x11.free(reply);
        if (reply.type == x11.atom_none) return .nothing_written;
        self.deadline = deadline;
        if (reply.type == endpoint.atoms.incr and !self.incremental) {
            self.incremental = true;
            return .more_to_come;
        }
        const length: usize = @intCast(@max(x11.xcb_get_property_value_length(reply), 0));
        const value = if (length > 0) x11.xcb_get_property_value(reply).?[0..length] else "";
        const kept = @min(value.len, self.buffer.len - self.len);
        @memcpy(self.buffer[self.len..][0..kept], value[0..kept]);
        self.len += kept;
        self.left_out_bytes += value.len - kept;
        if (self.incremental and value.len > 0) return .more_to_come;
        return .finished;
    }

    pub fn received(self: *const Transfer) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The `CLIPBOARD` selection as text: written by owning it and answering
/// other clients' requests from the text held, read by converting it to
/// `UTF8_STRING` into a property of the window.
pub const Clipboard = struct {
    /// The text the window owns the selection with, until another client
    /// takes it.
    owned_text: [text_capacity]u8 = undefined,
    owned_len: usize = 0,
    owns_selection: bool = false,
    /// The owned text in Latin-1, for a request for `STRING`.
    latin1_text: [text_capacity]u8 = undefined,
    read: ?PendingRead = null,
    read_text: [text_capacity]u8 = undefined,

    /// UTF-8 bytes of text the clipboard is given, or a read answers
    /// with; a read counts the rest as left out.
    pub const text_capacity = data_device.DataDevice.clipboard_text_capacity;
    /// How long an owner may take to write the text, or the next chunk of
    /// it, before the read is given up.
    pub const transfer_timeout_ns = data_device.DataDevice.transfer_timeout_ns;

    const PendingRead = struct {
        request: zui.ServiceRequest,
        sink: zui.ServiceSink,
        waker: zui.Waker,
        transfer: Transfer,
    };

    /// Owns `CLIPBOARD` with `text`, at the server time of the input that
    /// asked for it. Unavailable when the server gives the selection to
    /// another client.
    pub fn write(self: *Clipboard, endpoint: Endpoint, text: []const u8, time: u32) zui.ServiceError!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (text.len > text_capacity) return error.TooLarge;
        const connection = endpoint.connection;
        const clipboard = endpoint.atoms.clipboard;
        _ = x11.xcb_set_selection_owner(connection, endpoint.window, clipboard, time);
        const reply = x11.xcb_get_selection_owner_reply(connection, x11.xcb_get_selection_owner(connection, clipboard), null) orelse return error.Unavailable;
        defer x11.free(reply);
        if (reply.owner != endpoint.window) return error.Unavailable;
        @memcpy(self.owned_text[0..text.len], text);
        self.owned_len = text.len;
        self.owns_selection = true;
    }

    /// Publishes the clipboard's text into `sink`: the window's own at
    /// once, another owner's once it has written it, `""` when no client
    /// owns the selection or its owner refuses text, and `.failed` when
    /// it takes longer than `transfer_timeout_ns`.
    pub fn startRead(self: *Clipboard, endpoint: Endpoint, request: zui.ServiceRequest, sink: zui.ServiceSink, waker: zui.Waker, time: u32, now: zui.Instant) zui.ServiceError!void {
        if (self.read != null) return error.Busy;
        if (self.owns_selection) return publishText(request, sink, waker, self.owned_text[0..self.owned_len], 0);
        const atoms = endpoint.atoms;
        _ = x11.xcb_delete_property(endpoint.connection, endpoint.window, atoms.clipboard_property);
        _ = x11.xcb_convert_selection(endpoint.connection, endpoint.window, atoms.clipboard, atoms.utf8_string, atoms.clipboard_property, time);
        self.read = .{
            .request = request,
            .sink = sink,
            .waker = waker,
            .transfer = .{ .property = atoms.clipboard_property, .buffer = &self.read_text, .deadline = now.addNanoseconds(transfer_timeout_ns) },
        };
    }

    /// The selection's owner answered the read: `property` holds the text,
    /// or is `None` where it had none to give.
    pub fn onSelectionNotify(self: *Clipboard, endpoint: Endpoint, property: x11.Atom, now: zui.Instant) void {
        const read = if (self.read) |*read| read else return;
        if (property == x11.atom_none) return self.answer("", 0);
        self.takeChunk(endpoint, now, read);
    }

    /// For `INCR`, the owner wrote the next chunk.
    pub fn onPropertyNewValue(self: *Clipboard, endpoint: Endpoint, now: zui.Instant) void {
        const read = if (self.read) |*read| read else return;
        if (!read.transfer.incremental) return;
        self.takeChunk(endpoint, now, read);
    }

    fn takeChunk(self: *Clipboard, endpoint: Endpoint, now: zui.Instant, read: *PendingRead) void {
        switch (read.transfer.take(endpoint, now.addNanoseconds(transfer_timeout_ns))) {
            .more_to_come, .nothing_written => {},
            .finished => {
                const received = read.transfer.received();
                const len = if (read.transfer.left_out_bytes > 0) data_device.wholeCharacters(received) else received.len;
                self.answer(received[0..len], read.transfer.left_out_bytes + received.len - len);
            },
        }
    }

    fn answer(self: *Clipboard, text: []const u8, left_out_bytes: usize) void {
        const pending = self.read.?;
        // Before the answer, so a read made as soon as it arrives is not
        // busy; the text stays put until the next read finishes.
        self.read = null;
        publishText(pending.request, pending.sink, pending.waker, text, left_out_bytes);
    }

    fn publishText(request: zui.ServiceRequest, sink: zui.ServiceSink, waker: zui.Waker, text: []const u8, left_out_bytes: usize) void {
        const answer_text: zui.ServiceAnswer = .{ .request = request, .outcome = .{ .clipboard_text = text }, .left_out_bytes = std.math.lossyCast(u32, left_out_bytes) };
        waker.wakeIf(sink.publish(&answer_text));
    }

    /// Gives up a read past its deadline, answering `.failed`.
    pub fn expire(self: *Clipboard, now: zui.Instant) void {
        const read = self.read orelse return;
        if (now.isBefore(read.transfer.deadline)) return;
        self.read = null;
        const failed: zui.ServiceAnswer = .{ .request = read.request, .outcome = .{ .failed = .unavailable } };
        read.waker.wakeIf(read.sink.publish(&failed));
    }

    pub fn deadline(self: *const Clipboard) ?zui.Instant {
        const read = self.read orelse return null;
        return read.transfer.deadline;
    }

    /// Another client took the selection; the text is dropped.
    pub fn onSelectionClear(self: *Clipboard) void {
        self.owns_selection = false;
        self.owned_len = 0;
    }

    /// Answers another client's request for the selection: its targets,
    /// or the text as `UTF8_STRING`, `text/plain;charset=utf-8`, `TEXT` or
    /// Latin-1 `STRING`, written into the requestor's property; any other
    /// target, or a request while the window owns nothing, is refused with
    /// a property of `None`.
    pub fn answerRequest(self: *Clipboard, endpoint: Endpoint, request: x11.SelectionRequestEvent) void {
        const atoms = endpoint.atoms;
        const connection = endpoint.connection;
        // Clients older than the ICCCM name no property; the target is then
        // the property.
        const property = if (request.property == x11.atom_none) request.target else request.property;
        const answered = self.owns_selection and request.selection == atoms.clipboard and answered: {
            const text = self.owned_text[0..self.owned_len];
            const target = request.target;
            if (target == atoms.targets) {
                const targets = [_]x11.Atom{ atoms.targets, atoms.utf8_string, atoms.text_plain_utf8, x11.atom_string, atoms.text };
                _ = x11.xcb_change_property(connection, x11.property_mode_replace, request.requestor, property, x11.atom_atom, 32, targets.len, &targets);
            } else if (target == atoms.utf8_string or target == atoms.text) {
                _ = x11.xcb_change_property(connection, x11.property_mode_replace, request.requestor, property, atoms.utf8_string, 8, @intCast(text.len), text.ptr);
            } else if (target == atoms.text_plain_utf8) {
                _ = x11.xcb_change_property(connection, x11.property_mode_replace, request.requestor, property, atoms.text_plain_utf8, 8, @intCast(text.len), text.ptr);
            } else if (target == x11.atom_string) {
                const latin1 = latin1Of(text, &self.latin1_text);
                _ = x11.xcb_change_property(connection, x11.property_mode_replace, request.requestor, property, x11.atom_string, 8, @intCast(latin1.len), latin1.ptr);
            } else break :answered false;
            break :answered true;
        };
        const notify: x11.SelectionNotifyEvent = .{
            .response_type = x11.selection_notify,
            .pad0 = 0,
            .sequence = 0,
            .time = request.time,
            .requestor = request.requestor,
            .selection = request.selection,
            .target = request.target,
            .property = if (answered) property else x11.atom_none,
        };
        var event: [32]u8 = @splat(0);
        @memcpy(event[0..@sizeOf(x11.SelectionNotifyEvent)], std.mem.asBytes(&notify));
        _ = x11.xcb_send_event(connection, 0, request.requestor, 0, &event);
    }

    /// `utf8` in Latin-1, each character past it a `?`.
    fn latin1Of(utf8: []const u8, buffer: []u8) []const u8 {
        var len: usize = 0;
        var characters = (std.unicode.Utf8View.init(utf8) catch return "").iterator();
        while (characters.nextCodepoint()) |codepoint| : (len += 1) {
            buffer[len] = if (codepoint <= 0xFF) @intCast(codepoint) else '?';
        }
        return buffer[0..len];
    }
};

/// Files dragged onto the window through XDND, version 5: a source that
/// offers `text/uri-list` is accepted for copying, and its drop's list is
/// read from `XdndSelection`.
pub const Drop = struct {
    /// The source window of the drag in progress.
    source: ?x11.Window = null,
    offers_uri_list: bool = false,
    /// In the window's physical pixels, at the drag's last position.
    position: [2]f32 = .{ 0, 0 },
    read: ?PendingDrop = null,
    uri_list: [uri_list_capacity]u8 = undefined,

    pub const version = 5;
    /// Bytes of a drop's URI list; whole lines past it are left out.
    pub const uri_list_capacity = data_device.DataDevice.uri_list_capacity;

    const PendingDrop = struct { source: x11.Window, transfer: Transfer };

    /// What the window advertises on `XdndAware`.
    pub fn advertise(endpoint: Endpoint) void {
        const advertised: u32 = version;
        _ = x11.xcb_change_property(endpoint.connection, x11.property_mode_replace, endpoint.window, endpoint.atoms.xdnd_aware, x11.atom_atom, 32, 1, &advertised);
    }

    /// `XdndEnter`: its first three types, or, with its first bit set,
    /// every type the source lists on `XdndTypeList`.
    pub fn onEnter(self: *Drop, endpoint: Endpoint, data: [5]u32) void {
        self.source = data[0];
        const atoms = endpoint.atoms;
        self.offers_uri_list = std.mem.indexOfScalar(u32, data[2..5], atoms.uri_list) != null;
        const lists_more_types = data[1] & 1 != 0;
        if (lists_more_types and !self.offers_uri_list) self.offers_uri_list = sourceListsUriList(endpoint, data[0]);
    }

    fn sourceListsUriList(endpoint: Endpoint, source: x11.Window) bool {
        const connection = endpoint.connection;
        const reply = x11.xcb_get_property_reply(connection, x11.xcb_get_property(connection, 0, source, endpoint.atoms.xdnd_type_list, x11.atom_atom, 0, 1024), null) orelse return false;
        defer x11.free(reply);
        const length: usize = @intCast(@max(x11.xcb_get_property_value_length(reply), 0));
        if (reply.format != 32 or length < 4) return false;
        const value = x11.xcb_get_property_value(reply).?;
        const types: []align(1) const u32 = std.mem.bytesAsSlice(u32, value[0 .. length / 4 * 4]);
        for (types) |offered| if (offered == endpoint.atoms.uri_list) return true;
        return false;
    }

    /// `XdndPosition`, at the root window's `root_position`: answered with
    /// `XdndStatus`, accepting a URI list for copying.
    pub fn onPosition(self: *Drop, endpoint: Endpoint, data: [5]u32, root: x11.Window) void {
        const source = self.source orelse return;
        if (data[0] != source) return;
        const root_x: i16 = @bitCast(@as(u16, @truncate(data[2] >> 16)));
        const root_y: i16 = @bitCast(@as(u16, @truncate(data[2])));
        const connection = endpoint.connection;
        if (x11.xcb_translate_coordinates_reply(connection, x11.xcb_translate_coordinates(connection, root, endpoint.window, root_x, root_y), null)) |reply| {
            defer x11.free(reply);
            self.position = .{ @floatFromInt(reply.dst_x), @floatFromInt(reply.dst_y) };
        }
        const accepted: u32 = @intFromBool(self.offers_uri_list);
        const action = if (self.offers_uri_list) endpoint.atoms.xdnd_action_copy else x11.atom_none;
        x11.sendClientMessage(connection, source, endpoint.atoms.xdnd_status, .{ endpoint.window, accepted, 0, 0, action });
    }

    /// `XdndLeave`: the drag left without dropping.
    pub fn onLeave(self: *Drop, data: [5]u32) void {
        if (self.source == data[0]) self.source = null;
    }

    /// `XdndDrop`: asks for the URI list, or finishes at once, refused,
    /// for a drag the window did not accept.
    pub fn onDrop(self: *Drop, endpoint: Endpoint, data: [5]u32, now: zui.Instant) void {
        const source = self.source orelse return;
        if (data[0] != source) return;
        self.source = null;
        if (!self.offers_uri_list) return finish(endpoint, source, false);
        if (self.read) |earlier| finish(endpoint, earlier.source, false);
        const atoms = endpoint.atoms;
        _ = x11.xcb_delete_property(endpoint.connection, endpoint.window, atoms.drop_property);
        _ = x11.xcb_convert_selection(endpoint.connection, endpoint.window, atoms.xdnd_selection, atoms.uri_list, atoms.drop_property, data[2]);
        self.read = .{
            .source = source,
            .transfer = .{ .property = atoms.drop_property, .buffer = &self.uri_list, .deadline = now.addNanoseconds(data_device.DataDevice.transfer_timeout_ns) },
        };
    }

    /// The dropped list, read whole, and where it was dropped.
    pub const Dropped = struct { received: data_device.DataDevice.ReceivedDrop, position: [2]f32 };

    /// The source answered the request for the list: `property` holds it,
    /// or is `None` where it gave none.
    pub fn onSelectionNotify(self: *Drop, endpoint: Endpoint, property: x11.Atom, now: zui.Instant) ?Dropped {
        const read = if (self.read) |*read| read else return null;
        if (property == x11.atom_none) {
            self.read = null;
            finish(endpoint, read.source, false);
            return null;
        }
        return self.takeChunk(endpoint, now, read);
    }

    pub fn onPropertyNewValue(self: *Drop, endpoint: Endpoint, now: zui.Instant) ?Dropped {
        const read = if (self.read) |*read| read else return null;
        if (!read.transfer.incremental) return null;
        return self.takeChunk(endpoint, now, read);
    }

    fn takeChunk(self: *Drop, endpoint: Endpoint, now: zui.Instant, read: *PendingDrop) ?Dropped {
        if (read.transfer.take(endpoint, now.addNanoseconds(data_device.DataDevice.transfer_timeout_ns)) != .finished) return null;
        const pending = read.*;
        self.read = null;
        finish(endpoint, pending.source, true);
        return .{ .received = data_device.wholeUriLines(pending.transfer.received(), pending.transfer.left_out_bytes), .position = self.position };
    }

    /// Gives up a drop's list past its deadline, finishing it refused.
    pub fn expire(self: *Drop, endpoint: Endpoint, now: zui.Instant) void {
        const read = self.read orelse return;
        if (now.isBefore(read.transfer.deadline)) return;
        self.read = null;
        finish(endpoint, read.source, false);
    }

    pub fn deadline(self: *const Drop) ?zui.Instant {
        const read = self.read orelse return null;
        return read.transfer.deadline;
    }

    fn finish(endpoint: Endpoint, source: x11.Window, accepted: bool) void {
        const action = if (accepted) endpoint.atoms.xdnd_action_copy else x11.atom_none;
        x11.sendClientMessage(endpoint.connection, source, endpoint.atoms.xdnd_finished, .{ endpoint.window, @intFromBool(accepted), action, 0, 0 });
    }
};

test "Latin-1 keeps the characters it has, and each other is a question mark" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "caf\xe9 ?", Clipboard.latin1Of("café ✓", &buffer));
}
