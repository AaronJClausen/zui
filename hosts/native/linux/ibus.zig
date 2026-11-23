const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;
const dbus = @import("dbus.zig");
const keyboard = @import("keyboard.zig");
const text_input = @import("text_input.zig");
const Text = @import("services.zig").Text;

const bus_service: dbus.Header = .{ .type = .method_call, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" };

/// The portal ibus-daemon and fcitx5 both serve, which makes an input
/// context for a client that may not reach the input method's own bus.
pub const portal = struct {
    pub const service = "org.freedesktop.portal.IBus";
    pub const path = "/org/freedesktop/IBus";
    pub const interface = "org.freedesktop.IBus.Portal";
    const owner_changed_rule = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ service ++ "'";
};

pub const context_interface = "org.freedesktop.IBus.InputContext";
const context_signals_rule_start = "type='signal',interface='" ++ context_interface ++ "',path='";
const client_name = "zui";

/// The client draws the preedit, and says when it gains and loses focus.
pub const capabilities: u32 = capability_preedit_text | capability_focus;
const capability_preedit_text: u32 = 1 << 0;
const capability_focus: u32 = 1 << 3;
/// The bit of `ProcessKeyEvent`'s and `ForwardKeyEvent`'s state that
/// marks a release; the others are X's modifier mask.
pub const release_mask: u32 = 1 << 30;

/// A key event the input context holds until the input method has answered
/// for it.
pub const HeldKey = struct {
    /// A `key_down` or a `key_up`.
    event: zui.Event,
    /// What a press would type; null for a release, and where the keyboard
    /// has no keymap.
    pressed_key: ?keyboard.PressedKey,
    /// What the input method is told the key is: its keysym, its evdev
    /// code, and X's modifier mask, with `release_mask` for a release.
    keysym: u32,
    evdev_code: u32,
    state: u32,
};

/// A key the input method hands back for the client to type.
pub const ForwardedKey = struct {
    keysym: u32,
    evdev_code: u32,
    state: u32,

    pub fn isRelease(self: ForwardedKey) bool {
        return self.state & release_mask != 0;
    }
};

/// An input context of IBus's D-Bus protocol, on a connection of its own to
/// the session bus, made through the portal at `open` and focused while a
/// frame asks for text input. Requests are sent only when what the host
/// wants differs from what was last sent, so an idle frame sends nothing.
///
/// While it is focused, each key goes to the input method and is held, in
/// order behind the keys before it, until the input method answers: a key
/// it consumed reaches `listener.onKeyAnswered(key, false)`, and one it
/// did not, `listener.onKeyAnswered(key, true)`, to type. A key held past
/// `answer_bound_ns` is answered as not consumed, with every key held, and
/// the input method is passed over until it answers again. Committed text
/// and forwarded keys keep their place behind the keys held before them.
/// The preedit is kept, not reported.
pub const InputContext = struct {
    bus: dbus.Connection = .{},
    phase: Phase = .closed,
    create_serial: u32 = 0,
    /// The input method's connection, which alone answers for the context
    /// and signals it.
    input_method_name: Text(name_capacity) = .{},
    path: Text(path_capacity) = .{},
    /// In root coordinates; null when the host wants no text input.
    wanted_caret: ?CursorRectangle = null,
    /// What was last sent: `FocusIn` without a `FocusOut` after it, and
    /// the last `SetCursorLocation`.
    focused: bool = false,
    sent_caret: ?CursorRectangle = null,
    /// False after a key went unanswered past the bound, until the input
    /// method answers again.
    answering: bool = true,
    held: [held_capacity]Held = undefined,
    held_count: usize = 0,
    held_commits: [held_commit_capacity]u8 = undefined,
    held_commits_len: usize = 0,
    preedit: text_input.TextInput.Preedit = .{},
    preedit_visible: bool = false,
    left_out_events: u32 = 0,
    left_out_bytes: u32 = 0,
    message_body: [message_body_capacity]u8 = undefined,
    /// Counted for tests, which check that an idle frame sends nothing.
    requests_sent: u32 = 0,

    pub const Phase = enum {
        /// No bus, or no input method answered for a context.
        closed,
        /// `CreateInputContext` is still to be answered.
        creating,
        ready,
    };

    pub const CursorRectangle = text_input.TextInput.CursorRectangle;

    /// Keys held at once; a key past them is left out and counted.
    pub const held_capacity = 64;
    /// UTF-8 bytes of committed text held behind keys; text past it is
    /// left out and counted.
    pub const held_commit_capacity = 4 * 1024;
    /// How long a key waits for the input method's answer before it is
    /// typed without it. An input method answers in well under 2 ms.
    pub const answer_bound_ns = 100 * std.time.ns_per_ms;
    const name_capacity = 255;
    const path_capacity = 255;
    const message_body_capacity = 512;
    const send_timeout_ns = 100 * std.time.ns_per_ms;

    const Held = struct {
        entry: Entry,
        held_at: zui.Instant,
    };

    const Entry = union(enum) {
        key: struct { key: HeldKey, serial: u32, answer: Answer },
        commit: struct { start: usize, len: usize },
        forwarded: ForwardedKey,
    };

    const Answer = enum { awaited, consumed, not_consumed };

    /// Connects to the session bus at `address` and asks the portal for an
    /// input context, giving up at `deadline`; its answer arrives through
    /// `receive`. Without a bus or a portal, keys go straight through.
    pub fn open(self: *InputContext, io: std.Io, address: []const u8, deadline: zui.Instant) void {
        self.* = .{};
        self.connect(io, address, deadline) catch self.close();
    }

    fn connect(self: *InputContext, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
        try self.bus.open(io, address, deadline);
        var hello = bus_service;
        hello.member = "Hello";
        _ = try self.bus.send(io, hello, "", deadline);
        try self.changeMatch(io, "AddMatch", &.{portal.owner_changed_rule}, deadline);
        try self.createContext(io, deadline);
    }

    fn createContext(self: *InputContext, io: std.Io, deadline: zui.Instant) !void {
        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.string(client_name);
        self.create_serial = try self.bus.send(io, .{
            .type = .method_call,
            // An input method the session does not run is not started for one window.
            .flags = .{ .no_auto_start = true },
            .destination = portal.service,
            .path = portal.path,
            .interface = portal.interface,
            .member = "CreateInputContext",
            .signature = "s",
        }, body.buffer[0..body.len], deadline);
        self.phase = .creating;
    }

    pub fn close(self: *InputContext) void {
        self.bus.close();
        self.phase = .closed;
        self.focused = false;
        self.sent_caret = null;
    }

    /// The socket to wait on beside the display; -1 without a bus, which
    /// `poll` passes over.
    pub fn descriptor(self: *const InputContext) i32 {
        return self.bus.fd;
    }

    /// The composing text, valid until the next `receive`; empty while the
    /// input method hides it.
    pub fn preeditText(self: *const InputContext) []const u8 {
        return if (self.preedit_visible) self.preedit.text.slice() else "";
    }

    /// Focuses the context with its caret at `caret`, in root coordinates,
    /// or for null takes the focus away, sending only what changed.
    pub fn want(self: *InputContext, io: std.Io, caret: ?CursorRectangle) void {
        self.wanted_caret = caret;
        self.apply(io);
    }

    fn apply(self: *InputContext, io: std.Io) void {
        if (self.phase != .ready) return;
        const caret = self.wanted_caret orelse {
            if (self.focused) {
                self.focused = false;
                self.sent_caret = null;
                self.forgetComposition();
                self.sendToContext(io, "FocusOut", "", "");
            }
            return;
        };
        if (!self.focused) {
            self.focused = true;
            self.sendToContext(io, "FocusIn", "", "");
        }
        if (self.sent_caret) |sent| if (std.meta.eql(sent, caret)) return;
        self.sent_caret = caret;
        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.int32(caret.x);
        body.int32(caret.y);
        body.int32(caret.width);
        body.int32(caret.height);
        self.sendToContext(io, "SetCursorLocation", "iiii", body.buffer[0..body.len]);
    }

    fn forgetComposition(self: *InputContext) void {
        self.preedit = .{};
        self.preedit_visible = false;
    }

    /// Sends `key` to the input method and holds it, or, while the context
    /// is not focused or the input method is passed over, hands it on, held
    /// only behind keys still held.
    pub fn takeKey(self: *InputContext, io: std.Io, key: HeldKey, now: zui.Instant, listener: anytype) void {
        const sends = self.phase == .ready and self.focused and self.answering;
        if (!sends and self.held_count == 0) return listener.onKeyAnswered(&key, true);
        if (self.held_count == held_capacity) {
            self.left_out_events +|= 1;
            return self.reportLeftOut(listener);
        }
        var answer: Answer = .not_consumed;
        var serial: u32 = 0;
        if (sends) {
            var body: dbus.Writer = .{ .buffer = &self.message_body };
            body.uint32(key.keysym);
            body.uint32(key.evdev_code);
            body.uint32(key.state);
            if (self.send(io, self.contextCall("ProcessKeyEvent", "uuu", false), body.buffer[0..body.len])) |sent| {
                serial = sent;
                answer = .awaited;
            }
        }
        self.hold(.{ .key = .{ .key = key, .serial = serial, .answer = answer } }, now);
        self.deliverAnswered(listener);
    }

    fn hold(self: *InputContext, entry: Entry, now: zui.Instant) void {
        self.held[self.held_count] = .{ .entry = entry, .held_at = now };
        self.held_count += 1;
    }

    /// When the oldest key still awaited is given up on.
    pub fn answerDeadline(self: *const InputContext) ?zui.Instant {
        for (self.held[0..self.held_count]) |held| if (held.entry == .key and held.entry.key.answer == .awaited) {
            return held.held_at.addNanoseconds(answer_bound_ns);
        };
        return null;
    }

    /// Past the bound, every key still awaited is answered as not
    /// consumed, and the input method is passed over until it answers.
    pub fn expire(self: *InputContext, now: zui.Instant, listener: anytype) void {
        const given_up_at = self.answerDeadline() orelse return;
        if (now.isBefore(given_up_at)) return;
        self.answering = false;
        self.answerAwaitedAsNotConsumed();
        self.deliverAnswered(listener);
    }

    fn answerAwaitedAsNotConsumed(self: *InputContext) void {
        for (self.held[0..self.held_count]) |*held| switch (held.entry) {
            .key => |*key| if (key.answer == .awaited) {
                key.answer = .not_consumed;
            },
            else => {},
        };
    }

    /// Hands on, in order, what is no longer waiting for an answer, up to
    /// the first key that is.
    fn deliverAnswered(self: *InputContext, listener: anytype) void {
        var delivered: usize = 0;
        while (delivered < self.held_count) : (delivered += 1) {
            switch (self.held[delivered].entry) {
                .key => |key| switch (key.answer) {
                    .awaited => break,
                    .consumed => listener.onKeyAnswered(&key.key, false),
                    .not_consumed => listener.onKeyAnswered(&key.key, true),
                },
                .commit => |span| listener.onCommittedText(self.held_commits[span.start..][0..span.len]),
                .forwarded => |forwarded| listener.onForwardedKey(forwarded),
            }
        }
        std.mem.copyForwards(Held, self.held[0 .. self.held_count - delivered], self.held[delivered..self.held_count]);
        self.held_count -= delivered;
        if (self.held_count == 0) self.held_commits_len = 0;
        self.reportLeftOut(listener);
    }

    fn reportLeftOut(self: *InputContext, listener: anytype) void {
        if (self.left_out_events == 0 and self.left_out_bytes == 0) return;
        listener.onLeftOut(self.left_out_events, self.left_out_bytes);
        self.left_out_events = 0;
        self.left_out_bytes = 0;
    }

    /// Reads what the bus sent, without waiting. A bus that hung up is
    /// closed, and the keys it held are typed.
    pub fn receive(self: *InputContext, io: std.Io, listener: anytype) void {
        if (!self.bus.isOpen()) return;
        var receiver: Receiver(@TypeOf(listener)) = .{ .context = self, .io = io, .listener = listener };
        self.bus.receive(&receiver) catch self.lose(listener);
    }

    fn Receiver(comptime Listener: type) type {
        return struct {
            context: *InputContext,
            io: std.Io,
            listener: Listener,

            pub fn onMessage(self: *@This(), message: dbus.Message) void {
                self.context.readMessage(self.io, message, self.listener);
            }

            pub fn onMessageTooLarge(self: *@This(), header: dbus.Header, len: usize) void {
                if (header.type == .signal and self.context.isFromContext(header) and std.mem.eql(u8, header.member orelse "", "CommitText")) {
                    self.context.left_out_bytes +|= std.math.lossyCast(u32, len);
                    self.context.reportLeftOut(self.listener);
                }
            }
        };
    }

    fn lose(self: *InputContext, listener: anytype) void {
        self.close();
        self.forgetComposition();
        self.answerAwaitedAsNotConsumed();
        self.deliverAnswered(listener);
    }

    pub fn readMessage(self: *InputContext, io: std.Io, message: dbus.Message, listener: anytype) void {
        const header = message.header;
        var body = message.body;
        switch (header.type) {
            .method_return, .@"error" => {
                const reply_serial = header.reply_serial orelse return;
                if (self.phase == .creating and reply_serial == self.create_serial) return self.readCreated(io, header, &body);
                if (header.type == .method_return and std.mem.eql(u8, header.sender orelse "", self.input_method_name.slice())) self.answering = true;
                self.readKeyAnswer(reply_serial, header, &body, listener);
            },
            .signal => {
                if (isSignal(header, "org.freedesktop.DBus", "NameOwnerChanged", "sss") and std.mem.eql(u8, header.sender orelse "", "org.freedesktop.DBus")) return self.readOwnerChanged(io, &body, listener) catch {};
                if (!self.isFromContext(header)) return;
                self.readContextSignal(header, &body, listener) catch {};
            },
            else => {},
        }
    }

    fn readCreated(self: *InputContext, io: std.Io, header: dbus.Header, body: *dbus.Reader) void {
        const path = if (header.type == .method_return and std.mem.eql(u8, header.signature, "o")) body.string() catch null else null;
        if (path == null or !self.path.set(path.?) or !self.input_method_name.set(header.sender orelse "")) {
            self.phase = .closed;
            return;
        }
        self.phase = .ready;
        self.focused = false;
        self.sent_caret = null;
        self.changeMatch(io, "AddMatch", &.{ context_signals_rule_start, self.path.slice(), "',sender='", self.input_method_name.slice(), "'" }, self.sendDeadline(io)) catch return self.close();
        var capability_body: dbus.Writer = .{ .buffer = &self.message_body };
        capability_body.uint32(capabilities);
        self.sendToContext(io, "SetCapabilities", "u", capability_body.buffer[0..capability_body.len]);
        self.apply(io);
    }

    fn readKeyAnswer(self: *InputContext, reply_serial: u32, header: dbus.Header, body: *dbus.Reader, listener: anytype) void {
        for (self.held[0..self.held_count]) |*held| switch (held.entry) {
            .key => |*key| if (key.answer == .awaited and key.serial == reply_serial) {
                const consumed = header.type == .method_return and std.mem.eql(u8, header.signature, "b") and (body.boolean() catch false);
                key.answer = if (consumed) .consumed else .not_consumed;
                return self.deliverAnswered(listener);
            },
            else => {},
        };
    }

    fn readOwnerChanged(self: *InputContext, io: std.Io, body: *dbus.Reader, listener: anytype) dbus.Reader.Error!void {
        if (!std.mem.eql(u8, try body.string(), portal.service)) return;
        _ = try body.string();
        const new_owner = try body.string();
        if (new_owner.len == 0) {
            if (self.phase == .closed) return;
            self.phase = .closed;
            self.focused = false;
            self.sent_caret = null;
            self.forgetComposition();
            self.answerAwaitedAsNotConsumed();
            self.deliverAnswered(listener);
        } else if (self.phase == .closed and self.bus.isOpen()) {
            self.answering = true;
            self.createContext(io, self.sendDeadline(io)) catch self.lose(listener);
        }
    }

    fn isFromContext(self: *const InputContext, header: dbus.Header) bool {
        if (self.phase != .ready) return false;
        return std.mem.eql(u8, header.interface orelse "", context_interface) and
            std.mem.eql(u8, header.path orelse "", self.path.slice()) and
            std.mem.eql(u8, header.sender orelse "", self.input_method_name.slice());
    }

    fn readContextSignal(self: *InputContext, header: dbus.Header, body: *dbus.Reader, listener: anytype) dbus.Reader.Error!void {
        const member = header.member orelse return;
        const signature = header.signature;
        if (std.mem.eql(u8, member, "CommitText") and std.mem.eql(u8, signature, "v")) {
            const committed = try readText(body) orelse return;
            self.commit(committed, listener);
        } else if ((std.mem.eql(u8, member, "UpdatePreeditText") and std.mem.eql(u8, signature, "vub")) or
            (std.mem.eql(u8, member, "UpdatePreeditTextWithMode") and std.mem.eql(u8, signature, "vubu")))
        {
            const composing = try readText(body) orelse return;
            const cursor_characters = try body.uint32();
            self.preedit_visible = try body.boolean();
            self.left_out_bytes +|= self.preedit.text.set(composing);
            const cursor = byteOffsetOfCharacter(self.preedit.text.slice(), cursor_characters);
            self.preedit.cursor_begin = cursor;
            self.preedit.cursor_end = cursor;
            self.reportLeftOut(listener);
        } else if (std.mem.eql(u8, member, "HidePreeditText") and signature.len == 0) {
            self.preedit_visible = false;
        } else if (std.mem.eql(u8, member, "ShowPreeditText") and signature.len == 0) {
            self.preedit_visible = true;
        } else if (std.mem.eql(u8, member, "ForwardKeyEvent") and std.mem.eql(u8, signature, "uuu")) {
            const forwarded: ForwardedKey = .{ .keysym = try body.uint32(), .evdev_code = try body.uint32(), .state = try body.uint32() };
            if (self.held_count == 0) return listener.onForwardedKey(forwarded);
            if (self.held_count == held_capacity) {
                self.left_out_events +|= 1;
                return self.reportLeftOut(listener);
            }
            self.hold(.{ .forwarded = forwarded }, self.held[self.held_count - 1].held_at);
        }
    }

    /// Typed at once, or behind the keys still held.
    fn commit(self: *InputContext, committed: []const u8, listener: anytype) void {
        if (committed.len == 0) return;
        if (self.held_count == 0) return listener.onCommittedText(committed);
        if (self.held_count == held_capacity or committed.len > held_commit_capacity - self.held_commits_len) {
            self.left_out_bytes +|= std.math.lossyCast(u32, committed.len);
            return self.reportLeftOut(listener);
        }
        const start = self.held_commits_len;
        @memcpy(self.held_commits[start..][0..committed.len], committed);
        self.held_commits_len += committed.len;
        self.hold(.{ .commit = .{ .start = start, .len = committed.len } }, self.held[self.held_count - 1].held_at);
    }

    fn contextCall(self: *const InputContext, member: []const u8, signature: []const u8, no_reply_expected: bool) dbus.Header {
        return .{
            .type = .method_call,
            .flags = .{ .no_reply_expected = no_reply_expected },
            .destination = self.input_method_name.slice(),
            .path = self.path.slice(),
            .interface = context_interface,
            .member = member,
            .signature = signature,
        };
    }

    fn sendToContext(self: *InputContext, io: std.Io, member: []const u8, signature: []const u8, body: []const u8) void {
        _ = self.send(io, self.contextCall(member, signature, true), body);
    }

    /// A bus that fails to take the message is closed; the keys it held
    /// are typed by the next `expire`.
    fn send(self: *InputContext, io: std.Io, header: dbus.Header, body: []const u8) ?u32 {
        self.requests_sent += 1;
        return self.bus.send(io, header, body, self.sendDeadline(io)) catch {
            self.close();
            self.answerAwaitedAsNotConsumed();
            return null;
        };
    }

    fn sendDeadline(_: *const InputContext, io: std.Io) zui.Instant {
        return zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake)).addNanoseconds(send_timeout_ns);
    }

    fn changeMatch(self: *InputContext, io: std.Io, member: []const u8, rule_parts: []const []const u8, send_deadline: zui.Instant) !void {
        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.stringOfParts(rule_parts);
        if (body.overflowed) return error.MessageTooLarge;
        var change = bus_service;
        change.member = member;
        change.signature = "s";
        change.flags.no_reply_expected = true;
        _ = try self.bus.send(io, change, body.buffer[0..body.len], send_deadline);
    }
};

/// An `IBusText` in its variant, `(sa{sv}sv)`: its type's name, its
/// attachments, the text and its attributes. Null for a variant of another
/// type.
pub fn readText(body: *dbus.Reader) dbus.Reader.Error!?[]const u8 {
    if (!try body.beginVariantStruct("(sa{sv}sv)")) return null;
    _ = try body.string();
    try body.skip("a{sv}");
    const text = try body.string();
    try body.skip("v");
    return text;
}

/// IBus counts a cursor in characters; the preedit keeps it in bytes.
fn byteOffsetOfCharacter(utf8: []const u8, character: u32) i32 {
    var characters: u32 = 0;
    var offset: usize = 0;
    while (offset < utf8.len and characters < character) : (characters += 1) {
        offset += std.unicode.utf8ByteSequenceLength(utf8[offset]) catch 1;
    }
    return @intCast(@min(offset, utf8.len));
}

fn isSignal(header: dbus.Header, interface: []const u8, member: []const u8, signature: []const u8) bool {
    return std.mem.eql(u8, header.interface orelse "", interface) and std.mem.eql(u8, header.member orelse "", member) and std.mem.eql(u8, header.signature, signature);
}

/// Writes an `IBusText` holding `text` into `body` as a variant, as an
/// input method sends it, for tests and harnesses that play one.
pub fn writeText(body: *dbus.Writer, text: []const u8) void {
    body.signature("(sa{sv}sv)");
    body.beginStruct();
    body.string("IBusText");
    const attachments = body.beginArray(8);
    body.endArray(attachments);
    body.string(text);
    body.signature("(sa{sv}av)");
    body.beginStruct();
    body.string("IBusAttrList");
    const attachments_of_attributes = body.beginArray(8);
    body.endArray(attachments_of_attributes);
    const attributes = body.beginArray(1);
    body.endArray(attributes);
}

const testing = std.testing;

const Answered = struct {
    typed: [16]u8 = undefined,
    typed_len: usize = 0,
    log: [32]Logged = undefined,
    count: usize = 0,
    left_out_events: u32 = 0,
    left_out_bytes: u32 = 0,

    const Logged = union(enum) { key: struct { evdev_code: u32, types: bool }, commit, forwarded: u32 };

    pub fn onKeyAnswered(self: *Answered, key: *const HeldKey, types: bool) void {
        self.append(.{ .key = .{ .evdev_code = key.evdev_code, .types = types } });
    }

    pub fn onCommittedText(self: *Answered, utf8: []const u8) void {
        @memcpy(self.typed[self.typed_len..][0..utf8.len], utf8);
        self.typed_len += utf8.len;
        self.append(.commit);
    }

    pub fn onForwardedKey(self: *Answered, forwarded: ForwardedKey) void {
        self.append(.{ .forwarded = forwarded.keysym });
    }

    pub fn onLeftOut(self: *Answered, events: u32, bytes: u32) void {
        self.left_out_events += events;
        self.left_out_bytes += bytes;
    }

    fn append(self: *Answered, logged: Logged) void {
        self.log[self.count] = logged;
        self.count += 1;
    }

    fn all(self: *const Answered) []const Logged {
        return self.log[0..self.count];
    }
};

/// A context whose bus is one end of a socket pair, the other end kept
/// to read what it sends, made ready as though the portal had answered.
const PairedContext = struct {
    context: InputContext = .{},
    other_end: i32 = -1,

    fn open(self: *PairedContext) !void {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds)) != .SUCCESS) return error.NoSocketPair;
        self.context.bus.adopt(fds[0]);
        self.other_end = fds[1];
        self.context.phase = .creating;
        self.context.create_serial = 9;
        var body_buffer: [64]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string("/org/freedesktop/IBus/InputContext_3");
        var buffer: [256]u8 = undefined;
        var answered: Answered = .{};
        self.context.readMessage(testing.io, try dbus.decode(try dbus.encode(&buffer, .{ .type = .method_return, .reply_serial = 9, .sender = ":1.5", .signature = "o" }, body_buffer[0..body.len])), &answered);
    }

    fn close(self: *PairedContext) void {
        self.context.close();
        _ = linux.close(self.other_end);
    }

    /// The members of the messages sent since the last call.
    fn sentMembers(self: *PairedContext, members: *SentMembers) !void {
        members.* = .{};
        var reader: dbus.Connection = .{};
        reader.adopt(self.other_end);
        defer reader.fd = -1;
        try reader.receive(members);
    }

    fn signal(self: *PairedContext, member: []const u8, signature: []const u8, body: []const u8, answered: *Answered) !void {
        var buffer: [text_input.TextInput.text_capacity + 512]u8 = undefined;
        self.context.readMessage(testing.io, try dbus.decode(try dbus.encode(&buffer, .{
            .type = .signal,
            .sender = ":1.5",
            .path = "/org/freedesktop/IBus/InputContext_3",
            .interface = context_interface,
            .member = member,
            .signature = signature,
        }, body)), answered);
    }

    fn answer(self: *PairedContext, serial: u32, consumed: bool, answered: *Answered) !void {
        var body_buffer: [8]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.boolean(consumed);
        var buffer: [256]u8 = undefined;
        self.context.readMessage(testing.io, try dbus.decode(try dbus.encode(&buffer, .{ .type = .method_return, .reply_serial = serial, .sender = ":1.5", .signature = "b" }, body_buffer[0..body.len])), answered);
    }
};

const SentMembers = struct {
    members: [16][32]u8 = undefined,
    lens: [16]usize = undefined,
    serials: [16]u32 = undefined,
    count: usize = 0,

    pub fn onMessage(self: *SentMembers, message: dbus.Message) void {
        const member = message.header.member orelse return;
        @memcpy(self.members[self.count][0..member.len], member);
        self.lens[self.count] = member.len;
        self.serials[self.count] = message.header.serial;
        self.count += 1;
    }

    fn memberAt(self: *const SentMembers, index: usize) []const u8 {
        return self.members[index][0..self.lens[index]];
    }
};

fn keyOf(evdev_code: u32) HeldKey {
    return .{ .event = .{ .key_down = .{ .key = .a, .scancode = evdev_code, .at = .{ .nanoseconds = 0 } } }, .pressed_key = null, .keysym = 0x61, .evdev_code = evdev_code, .state = 0 };
}

fn instantAt(milliseconds: u64) zui.Instant {
    return .{ .nanoseconds = milliseconds * std.time.ns_per_ms };
}

test "the portal's answer makes the context ready: it watches its signals and sets its capabilities, then focus and the caret follow what the host wants, each sent once" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    try testing.expectEqual(InputContext.Phase.ready, paired.context.phase);
    var sent: SentMembers = .{};
    try paired.sentMembers(&sent);
    try testing.expectEqual(@as(usize, 2), sent.count);
    try testing.expectEqualStrings("AddMatch", sent.memberAt(0));
    try testing.expectEqualStrings("SetCapabilities", sent.memberAt(1));

    const caret: InputContext.CursorRectangle = .{ .x = 10, .y = 20, .width = 1, .height = 16 };
    paired.context.want(testing.io, caret);
    paired.context.want(testing.io, caret);
    try paired.sentMembers(&sent);
    try testing.expectEqual(@as(usize, 2), sent.count);
    try testing.expectEqualStrings("FocusIn", sent.memberAt(0));
    try testing.expectEqualStrings("SetCursorLocation", sent.memberAt(1));

    paired.context.want(testing.io, .{ .x = 30, .y = 20, .width = 1, .height = 16 });
    paired.context.want(testing.io, null);
    paired.context.want(testing.io, null);
    try paired.sentMembers(&sent);
    try testing.expectEqual(@as(usize, 2), sent.count);
    try testing.expectEqualStrings("SetCursorLocation", sent.memberAt(0));
    try testing.expectEqualStrings("FocusOut", sent.memberAt(1));
}

test "keys are held in order until answered: a consumed one types nothing, and text committed behind a key waits for it" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    var sent: SentMembers = .{};
    try paired.sentMembers(&sent);
    var answered: Answered = .{};

    paired.context.takeKey(testing.io, keyOf(1), instantAt(0), &answered);
    try testing.expectEqual(@as(usize, 1), answered.count);
    paired.context.want(testing.io, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try paired.sentMembers(&sent);
    paired.context.takeKey(testing.io, keyOf(2), instantAt(1), &answered);
    paired.context.takeKey(testing.io, keyOf(3), instantAt(2), &answered);
    try paired.sentMembers(&sent);
    try testing.expectEqual(@as(usize, 2), sent.count);
    try testing.expectEqualStrings("ProcessKeyEvent", sent.memberAt(0));

    var body_buffer: [256]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    writeText(&body, "\u{4f60}");
    try paired.signal("CommitText", "v", body_buffer[0..body.len], &answered);
    try paired.answer(sent.serials[1], false, &answered);
    try testing.expectEqual(@as(usize, 1), answered.count);
    try paired.answer(sent.serials[0], true, &answered);
    try testing.expectEqualStrings("\u{4f60}", answered.typed[0..answered.typed_len]);
    try testing.expectEqualDeep(&[_]Answered.Logged{
        .{ .key = .{ .evdev_code = 1, .types = true } },
        .{ .key = .{ .evdev_code = 2, .types = false } },
        .{ .key = .{ .evdev_code = 3, .types = true } },
        .commit,
    }, answered.all());
    try testing.expectEqual(@as(?zui.Instant, null), paired.context.answerDeadline());
}

test "a key unanswered past the bound is typed with every key behind it, the input method is passed over until it answers, and a forwarded key keeps its place" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    var answered: Answered = .{};
    paired.context.want(testing.io, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    var sent: SentMembers = .{};
    try paired.sentMembers(&sent);

    paired.context.takeKey(testing.io, keyOf(1), instantAt(0), &answered);
    var body_buffer: [16]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    for ([_]u32{ 0x62, 48, 0 }) |value| body.uint32(value);
    try paired.signal("ForwardKeyEvent", "uuu", body_buffer[0..body.len], &answered);
    paired.context.takeKey(testing.io, keyOf(2), instantAt(30), &answered);
    try paired.sentMembers(&sent);
    try testing.expectEqual(instantAt(100), paired.context.answerDeadline().?);
    paired.context.expire(instantAt(99), &answered);
    try testing.expectEqual(@as(usize, 0), answered.count);
    paired.context.expire(instantAt(100), &answered);
    try testing.expectEqualDeep(&[_]Answered.Logged{
        .{ .key = .{ .evdev_code = 1, .types = true } },
        .{ .forwarded = 0x62 },
        .{ .key = .{ .evdev_code = 2, .types = true } },
    }, answered.all());
    try testing.expect(!paired.context.answering);

    paired.context.takeKey(testing.io, keyOf(3), instantAt(200), &answered);
    try testing.expectEqual(@as(usize, 4), answered.count);
    var unsent: SentMembers = .{};
    try paired.sentMembers(&unsent);
    try testing.expectEqual(@as(usize, 0), unsent.count);

    try paired.answer(sent.serials[0], true, &answered);
    try testing.expect(paired.context.answering);
    try testing.expectEqual(@as(usize, 4), answered.count);
}

test "the input method leaving the bus types the keys it held, and a new one is asked for a context" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    var answered: Answered = .{};
    paired.context.want(testing.io, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    paired.context.takeKey(testing.io, keyOf(1), instantAt(0), &answered);
    var sent: SentMembers = .{};
    try paired.sentMembers(&sent);

    var buffer: [512]u8 = undefined;
    for ([_][]const u8{ "", ":1.9" }) |new_owner| {
        var body_buffer: [128]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string(portal.service);
        body.string(":1.5");
        body.string(new_owner);
        paired.context.readMessage(testing.io, try dbus.decode(try dbus.encode(&buffer, .{ .type = .signal, .sender = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .signature = "sss" }, body_buffer[0..body.len])), &answered);
        if (new_owner.len == 0) {
            try testing.expectEqual(InputContext.Phase.closed, paired.context.phase);
            try testing.expectEqualDeep(&[_]Answered.Logged{.{ .key = .{ .evdev_code = 1, .types = true } }}, answered.all());
        }
    }
    try testing.expectEqual(InputContext.Phase.creating, paired.context.phase);
    try paired.sentMembers(&sent);
    try testing.expectEqualStrings("CreateInputContext", sent.memberAt(0));
}

test "the preedit is kept with its cursor in bytes, hidden and shown, and one that does not fit is left out and counted" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    var answered: Answered = .{};
    var body_buffer: [text_input.TextInput.text_capacity + 256]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    writeText(&body, "n\u{4f60}h");
    body.uint32(2);
    body.boolean(true);
    try paired.signal("UpdatePreeditText", "vub", body_buffer[0..body.len], &answered);
    try testing.expectEqualStrings("n\u{4f60}h", paired.context.preeditText());
    try testing.expectEqual(@as(i32, 4), paired.context.preedit.cursor_begin);
    try paired.signal("HidePreeditText", "", "", &answered);
    try testing.expectEqualStrings("", paired.context.preeditText());
    try paired.signal("ShowPreeditText", "", "", &answered);
    try testing.expectEqualStrings("n\u{4f60}h", paired.context.preeditText());

    body = .{ .buffer = &body_buffer };
    writeText(&body, &@as([text_input.TextInput.text_capacity + 1]u8, @splat('x')));
    body.uint32(0);
    body.boolean(true);
    try paired.signal("UpdatePreeditText", "vub", body_buffer[0..body.len], &answered);
    try testing.expectEqualStrings("", paired.context.preeditText());
    try testing.expectEqual(@as(u32, text_input.TextInput.text_capacity + 1), answered.left_out_bytes);
}

test "a signal from another connection or for another context is ignored" {
    var paired: PairedContext = .{};
    try paired.open();
    defer paired.close();
    var answered: Answered = .{};
    var body_buffer: [128]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    writeText(&body, "x");
    var buffer: [512]u8 = undefined;
    for ([_][2][]const u8{ .{ ":1.6", "/org/freedesktop/IBus/InputContext_3" }, .{ ":1.5", "/org/freedesktop/IBus/InputContext_4" } }) |origin| {
        paired.context.readMessage(testing.io, try dbus.decode(try dbus.encode(&buffer, .{ .type = .signal, .sender = origin[0], .path = origin[1], .interface = context_interface, .member = "CommitText", .signature = "v" }, body_buffer[0..body.len])), &answered);
    }
    try testing.expectEqual(@as(usize, 0), answered.count);
    try paired.signal("CommitText", "v", body_buffer[0..body.len], &answered);
    try testing.expectEqualStrings("x", answered.typed[0..answered.typed_len]);
}
