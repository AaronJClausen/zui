//! Both sides of the frame boundary as bytes: records in, frames out, each
//! frame a delta from the one before, so a session can be saved, sent to
//! another process and replayed there. `Host`, `Renderer` and `Client`
//! run an application in one process and draw it in another.
//!
//! ```zig
//! var encoder: zui_wire.Encoder(Ui) = try .init(gpa);
//! defer encoder.deinit(gpa);
//! try zui_wire.writeHeader(writer, zui_wire.fingerprintOf(&fonts));
//! // In the relay listener:
//! try encoder.writeRecord(writer, record);
//! // After endFrame:
//! try encoder.writeFrame(writer, frame);
//!
//! // Elsewhere:
//! var decoder: zui_wire.Decoder(Ui) = try .init(gpa, .of(Ui));
//! defer decoder.deinit(gpa);
//! try zui_wire.readHeader(reader, zui_wire.fingerprintOf(&renderer));
//! while (try decoder.next(reader)) |message| switch (message) {
//!     .record => |record| ui.beginFrame(record, &sources),
//!     .frame => |frame| try renderer.zuiSubmit(surface, frame),
//! };
//! ```

const std = @import("std");
const zui = @import("zui");
const remote = @import("remote.zig");

pub const Host = remote.Host;
pub const Renderer = remote.Renderer;
pub const Client = remote.Client;

/// Written in every header; a reader rejects a stream of any other version.
pub const version: u16 = 1;
const magic = "zuiw";

pub const WriteError = std.Io.Writer.Error;

pub const ReadError = std.Io.Reader.Error || error{
    /// The bytes are not what this version writes.
    Malformed,
    /// A message holds more than the decoder's `Capacity`.
    CapacityExceeded,
};

pub const HeaderError = ReadError || error{
    NotAWireStream,
    UnsupportedVersion,
    /// The stream was measured with other fonts, so its text would not fit
    /// the boxes laid out for it.
    FontsDiffer,
};

/// Starts a stream. `fingerprint` identifies the fonts its frames were
/// measured with: `fingerprintOf(&text)`.
pub fn writeHeader(writer: *std.Io.Writer, fingerprint: ?u64) WriteError!void {
    try writer.writeAll(magic);
    try writer.writeInt(u16, version, .little);
    try writer.writeByte(@intFromBool(fingerprint != null));
    if (fingerprint) |value| try writer.writeInt(u64, value, .little);
}

/// Fails unless the stream starts with a header of this version whose
/// fingerprint, when both sides have one, is `fingerprint`.
pub fn readHeader(reader: *std.Io.Reader, fingerprint: ?u64) HeaderError!void {
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.NotAWireStream;
    if (try reader.takeInt(u16, .little) != version) return error.UnsupportedVersion;
    const streamed: ?u64 = switch (try reader.takeByte()) {
        0 => null,
        1 => try reader.takeInt(u64, .little),
        else => return error.Malformed,
    };
    if (streamed != null and fingerprint != null and streamed.? != fingerprint.?) return error.FontsDiffer;
}

/// The text contract's `zuiFingerprint`, or null when it declares none.
pub fn fingerprintOf(text: anytype) ?u64 {
    const Text = @typeInfo(@TypeOf(text)).pointer.child;
    return if (@hasDecl(Text, "zuiFingerprint")) text.zuiFingerprint() else null;
}

/// What a type's `zuiSerialize` writes its value with.
///
/// ```zig
/// pub fn zuiSerialize(self: *const Thumbnail, serializer: anytype) !void {
///     try serializer.write(self.path_hash); // the texture stays in this process
/// }
/// ```
pub const Serializer = struct {
    writer: *std.Io.Writer,

    pub fn write(self: Serializer, value: anytype) WriteError!void {
        try encodeValue(self.writer, value);
    }
};

/// What a type's `zuiDeserialize` reads its value with. A slice it reads
/// lives until the decoder's next message.
///
/// ```zig
/// pub fn zuiDeserialize(deserializer: anytype) !Thumbnail {
///     return .{ .path_hash = try deserializer.read(u64), .texture = null };
/// }
/// ```
pub const Deserializer = struct {
    reader: *std.Io.Reader,
    storage: *Storage,

    pub fn read(self: Deserializer, comptime T: type) ReadError!T {
        return decodeValue(T, self.reader, self.storage);
    }
};

/// Fixed memory that decoded slices, and what single pointers point at,
/// are placed in.
pub const Storage = struct {
    bytes: []u8,
    used: usize = 0,
    /// Kept apart from `bytes`, so that `Capacity.frame_bytes` stays the
    /// text alone.
    pointees: []u8 = &.{},
    pointees_used: usize = 0,

    fn take(self: *Storage, comptime T: type, count: usize) ReadError![]T {
        if (@sizeOf(T) == 0) {
            const nowhere: [*]T = @ptrFromInt(@alignOf(T));
            return nowhere[0..count];
        }
        const base = @intFromPtr(self.bytes.ptr);
        const start = std.mem.alignForward(usize, base + self.used, @alignOf(T)) - base;
        const size = std.math.mul(usize, @sizeOf(T), count) catch return error.CapacityExceeded;
        if (start > self.bytes.len or size > self.bytes.len - start) return error.CapacityExceeded;
        self.used = start + size;
        const items: [*]T = @ptrCast(@alignCast(self.bytes.ptr + start));
        return items[0..count];
    }

    fn takeOne(self: *Storage, comptime T: type) ReadError!*T {
        if (@sizeOf(T) == 0) return @ptrFromInt(@alignOf(T));
        const base = @intFromPtr(self.pointees.ptr);
        const start = std.mem.alignForward(usize, base + self.pointees_used, @alignOf(T)) - base;
        if (start > self.pointees.len or @sizeOf(T) > self.pointees.len - start) return error.CapacityExceeded;
        self.pointees_used = start + @sizeOf(T);
        return @ptrCast(@alignCast(self.pointees.ptr + start));
    }
};

const MessageKind = enum(u8) { record = 1, key_frame = 2, frame = 3 };

/// The most a `Decoder` holds of one message.
pub const Capacity = struct {
    /// Events in one record.
    events: u32,
    /// Typed text, dropped paths and whatever deliveries read as slices, in
    /// one record. A relayed text event is whole, so a record that typed more
    /// than the context keeps needs more than `of` gives.
    record_bytes: u32,
    commands: u32,
    /// The text of one frame's commands.
    frame_bytes: u32,

    /// What a stream from a context of type `Ui` needs.
    pub fn of(comptime Ui: type) Capacity {
        return .{
            .events = Ui.limits.max_events_per_frame,
            .record_bytes = @as(u32, Ui.limits.max_text_input_bytes) + Ui.limits.max_dropped_path_bytes,
            .commands = Ui.limits.max_render_commands,
            .frame_bytes = Ui.limits.max_text_bytes,
        };
    }
};

/// Writes the records and frames of a context of type `Ui`, each frame as
/// the changes from the last one written. Fails to compile when a payload
/// type or a source's delivery holds a pointer and declares no
/// `zuiSerialize`, since a pointer means nothing in another process.
pub fn Encoder(comptime Ui: type) type {
    comptime checkPayloads(Ui);
    return struct {
        const Self = @This();
        const Command = Ui.RenderCommand;

        last_record_params: ?zui.FrameParams = null,
        last_frame: ?FrameHeading = null,
        /// The last frame's commands, which the next is written against.
        last_commands: CommandHistory(Command),

        pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return .{ .last_commands = try .init(gpa, Ui.limits.max_render_commands, Ui.limits.max_text_bytes) };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.last_commands.deinit(gpa);
        }

        /// Writes `record` with its parameters as changes from the last
        /// record's, its events, and its deliveries when it has them.
        pub fn writeRecord(self: *Self, writer: *std.Io.Writer, record: *const Ui.FrameRecord) WriteError!void {
            try writer.writeByte(@intFromEnum(MessageKind.record));
            try writeParams(writer, self.last_record_params, record.params);
            self.last_record_params = record.params;
            try writer.writeUleb128(record.events.len);
            for (record.events) |event| try encodeValue(writer, event);
            if (Ui.has_sources) try encodeValue(writer, if (record.deliveries) |deliveries| deliveries.* else null);
        }

        /// Writes what a renderer and a host need of `frame`: its number,
        /// parameters, host requests and commands, as changes from the last
        /// frame written. The first frame is written whole. `frame` is a
        /// `*const Ui.Frame`, or anything with its `number`, `params`,
        /// `requests()` and `commands()`, such as a decoded frame.
        pub fn writeFrame(self: *Self, writer: *std.Io.Writer, frame: anytype) WriteError!void {
            const last = self.last_frame orelse return self.writeKeyFrame(writer, frame);
            if (!self.last_commands.complete or frame.number <= last.number) return self.writeKeyFrame(writer, frame);
            try writer.writeByte(@intFromEnum(MessageKind.frame));
            try writer.writeUleb128(frame.number - last.number);
            try writeParams(writer, last.params, frame.params);
            const requests = frame.requests();
            const requests_changed = !deepEqual(requests, last.requests);
            try writer.writeByte(@intFromBool(requests_changed));
            if (requests_changed) try encodeValue(writer, requests);
            try writeCommands(Command, writer, self.last_commands.items(), frame.commands());
            self.remember(frame);
        }

        /// Writes `frame` whole, for a reader that joins the stream here.
        pub fn writeKeyFrame(self: *Self, writer: *std.Io.Writer, frame: anytype) WriteError!void {
            try writer.writeByte(@intFromEnum(MessageKind.key_frame));
            try writer.writeUleb128(frame.number);
            try writeParams(writer, null, frame.params);
            try encodeValue(writer, frame.requests());
            try writeCommands(Command, writer, &.{}, frame.commands());
            self.remember(frame);
        }

        fn remember(self: *Self, frame: anytype) void {
            self.last_frame = .{ .number = frame.number, .params = frame.params, .requests = frame.requests() };
            self.last_commands.reset();
            for (frame.commands()) |command| self.last_commands.appendCopy(command) catch {
                self.last_commands.complete = false;
                return;
            };
        }
    };
}

/// Reads the stream an `Encoder(Ui)` wrote, into memory reserved by
/// `init`.
pub fn Decoder(comptime Ui: type) type {
    comptime checkPayloads(Ui);
    return struct {
        const Self = @This();
        const Command = Ui.RenderCommand;

        /// A frame as a renderer and a host take it. Valid until the next
        /// frame is decoded.
        pub const Frame = struct {
            number: u64,
            params: zui.FrameParams,
            host_requests: zui.HostRequests,
            command_list: []const Command,

            pub fn commands(self: *const Frame) []const Command {
                return self.command_list;
            }

            pub fn requests(self: *const Frame) zui.HostRequests {
                return self.host_requests;
            }
        };

        /// Each is valid until the next message of its kind is decoded.
        pub const Message = union(enum) {
            /// What `ui.beginFrame` takes, with deliveries when they were
            /// written, so the context replays rather than swaps.
            record: *const Ui.FrameRecord,
            frame: *const Frame,
        };

        events: []zui.Event,
        record_bytes: []align(16) u8,
        deliveries: Ui.Deliveries = undefined,
        record: Ui.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 0, 0 } } },
        last_record_params: ?zui.FrameParams = null,
        frame: Frame = .{ .number = 0, .params = .{ .now = .zero, .viewport = .{ 0, 0 } }, .host_requests = .{}, .command_list = &.{} },
        has_frame: bool = false,
        /// The last frame's commands and the ones being decoded, in turn.
        histories: [2]CommandHistory(Command),
        current: u1 = 0,

        pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Self {
            const events = try gpa.alloc(zui.Event, capacity.events);
            errdefer gpa.free(events);
            const record_bytes = try gpa.alignedAlloc(u8, .@"16", capacity.record_bytes);
            errdefer gpa.free(record_bytes);
            var first: CommandHistory(Command) = try .init(gpa, capacity.commands, capacity.frame_bytes);
            errdefer first.deinit(gpa);
            const second: CommandHistory(Command) = try .init(gpa, capacity.commands, capacity.frame_bytes);
            return .{ .events = events, .record_bytes = record_bytes, .histories = .{ first, second } };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (&self.histories) |*history| history.deinit(gpa);
            gpa.free(self.record_bytes);
            gpa.free(self.events);
        }

        /// The next message, or null where the stream ends between two.
        pub fn next(self: *Self, reader: *std.Io.Reader) ReadError!?Message {
            const kind_byte = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return error.ReadFailed,
            };
            return switch (std.enums.fromInt(MessageKind, kind_byte) orelse return error.Malformed) {
                .record => .{ .record = try self.readRecord(reader) },
                .key_frame => .{ .frame = try self.readFrame(reader, true) },
                .frame => .{ .frame = try self.readFrame(reader, false) },
            };
        }

        fn readRecord(self: *Self, reader: *std.Io.Reader) ReadError!*const Ui.FrameRecord {
            var storage: Storage = .{ .bytes = self.record_bytes };
            const params = try readParams(reader, self.last_record_params);
            const event_count = try readLength(reader);
            if (event_count > self.events.len) return error.CapacityExceeded;
            for (self.events[0..event_count]) |*event| event.* = try decodeValue(zui.Event, reader, &storage);
            self.last_record_params = params;
            self.record = .{ .params = params, .events = self.events[0..event_count] };
            if (Ui.has_sources) {
                if (try decodeValue(?Ui.Deliveries, reader, &storage)) |deliveries| {
                    self.deliveries = deliveries;
                    self.record.deliveries = &self.deliveries;
                }
            }
            return &self.record;
        }

        fn readFrame(self: *Self, reader: *std.Io.Reader, whole: bool) ReadError!*const Frame {
            if (!whole and !self.has_frame) return error.Malformed;
            const last = &self.histories[self.current];
            const decoded = &self.histories[self.current ^ 1];
            var frame = self.frame;
            if (whole) {
                frame.number = try readUleb(reader, u64);
                frame.params = try readParams(reader, null);
                frame.host_requests = try decodeValue(zui.HostRequests, reader, &decoded.storage);
            } else {
                frame.number = std.math.add(u64, frame.number, try readUleb(reader, u64)) catch return error.Malformed;
                frame.params = try readParams(reader, frame.params);
                if (try decodeValue(bool, reader, &decoded.storage)) frame.host_requests = try decodeValue(zui.HostRequests, reader, &decoded.storage);
            }
            try readCommands(Command, reader, if (whole) &.{} else last.items(), decoded);
            frame.command_list = decoded.items();
            self.frame = frame;
            self.current ^= 1;
            self.has_frame = true;
            return &self.frame;
        }
    };
}

const FrameHeading = struct {
    number: u64,
    params: zui.FrameParams,
    requests: zui.HostRequests,
};

/// A frame's commands with their text in memory of their own, so they
/// outlive the frame.
fn CommandHistory(comptime Command: type) type {
    return struct {
        const Self = @This();

        commands: []Command,
        count: usize = 0,
        storage: Storage,
        /// False when the last frame did not fit, so the next is written whole.
        complete: bool = true,

        fn init(gpa: std.mem.Allocator, command_capacity: usize, text_capacity: usize) std.mem.Allocator.Error!Self {
            const commands = try gpa.alloc(Command, command_capacity);
            errdefer gpa.free(commands);
            return .{ .commands = commands, .storage = .{ .bytes = try gpa.alloc(u8, text_capacity) } };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.storage.bytes);
            gpa.free(self.commands);
        }

        fn reset(self: *Self) void {
            self.count = 0;
            self.storage.used = 0;
            self.complete = true;
        }

        fn items(self: *const Self) []const Command {
            return self.commands[0..self.count];
        }

        /// `command`'s text must already be in `storage`.
        fn append(self: *Self, command: Command) ReadError!void {
            if (self.count == self.commands.len) return error.CapacityExceeded;
            self.commands[self.count] = command;
            self.count += 1;
        }

        fn appendCopy(self: *Self, command: Command) ReadError!void {
            var copy = command;
            try self.copyText(&copy);
            try self.append(copy);
        }

        fn copyText(self: *Self, command: *Command) ReadError!void {
            switch (command.payload) {
                .text => |*text| {
                    const content = try self.storage.take(u8, text.content.len);
                    @memcpy(content, text.content);
                    text.content = content;
                },
                else => {},
            }
        }
    };
}

/// The parameters as changes from `last`'s: a mask, the time since, and
/// each field that changed.
const ParamsChanged = packed struct(u8) {
    now_absolute: bool,
    viewport: bool,
    scale: bool,
    zoom: bool,
    reserved: u4 = 0,
};

fn writeParams(writer: *std.Io.Writer, last: ?zui.FrameParams, params: zui.FrameParams) WriteError!void {
    const changed: ParamsChanged = if (last) |previous| .{
        .now_absolute = params.now.isBefore(previous.now),
        .viewport = !deepEqual(params.viewport, previous.viewport),
        .scale = !deepEqual(params.scale, previous.scale),
        .zoom = !deepEqual(params.zoom, previous.zoom),
    } else .{ .now_absolute = true, .viewport = true, .scale = true, .zoom = true };
    try writer.writeByte(@bitCast(changed));
    try writer.writeUleb128(if (changed.now_absolute) params.now.nanoseconds else params.now.nanoseconds - last.?.now.nanoseconds);
    if (changed.viewport) try encodeValue(writer, params.viewport);
    if (changed.scale) try encodeValue(writer, params.scale);
    if (changed.zoom) try encodeValue(writer, params.zoom);
}

fn readParams(reader: *std.Io.Reader, last: ?zui.FrameParams) ReadError!zui.FrameParams {
    const changed: ParamsChanged = @bitCast(try reader.takeByte());
    if (changed.reserved != 0) return error.Malformed;
    const previous = last orelse if (changed.now_absolute and changed.viewport and changed.scale and changed.zoom) zui.FrameParams{ .now = .zero, .viewport = .{ 0, 0 } } else return error.Malformed;
    const elapsed = try readUleb(reader, u64);
    return .{
        .now = if (changed.now_absolute) .fromNanoseconds(elapsed) else previous.now.addNanoseconds(elapsed),
        .viewport = if (changed.viewport) try decodeValue([2]f32, reader, undefined) else previous.viewport,
        .scale = if (changed.scale) try decodeValue(f32, reader, undefined) else previous.scale,
        .zoom = if (changed.zoom) try decodeValue(f32, reader, undefined) else previous.zoom,
    };
}

/// How a run of commands relates to the last frame's, at the position
/// both have reached.
const CommandOp = enum(u2) {
    /// The next commands are the last frame's.
    keep,
    /// The last frame's next commands are gone.
    skip,
    /// New commands, written whole.
    insert,
    /// The last frame's next commands, each with the fields that changed.
    change,
};

const CommandChanged = packed struct(u8) {
    x: bool,
    y: bool,
    width: bool,
    height: bool,
    z: bool,
    payload: bool,
    reserved: u2 = 0,
};

/// How far ahead the encoder looks for a command that moved, as when an
/// element was declared or removed before it.
const resync_window = 32;

fn writeOp(writer: *std.Io.Writer, op: CommandOp, count: usize) WriteError!void {
    try writer.writeUleb128(@as(u64, count) << 2 | @intFromEnum(op));
}

fn writeCommands(comptime Command: type, writer: *std.Io.Writer, last: []const Command, commands: []const Command) WriteError!void {
    try writer.writeUleb128(commands.len);
    var old: usize = 0;
    var new: usize = 0;
    while (new < commands.len) {
        if (old == last.len) {
            try writeInserted(writer, commands[new..]);
            break;
        }
        if (deepEqual(last[old], commands[new])) {
            var run: usize = 1;
            while (old + run < last.len and new + run < commands.len and deepEqual(last[old + run], commands[new + run])) run += 1;
            try writeOp(writer, .keep, run);
            old += run;
            new += run;
        } else if (sameElement(last[old], commands[new])) {
            var run: usize = 1;
            while (old + run < last.len and new + run < commands.len and
                sameElement(last[old + run], commands[new + run]) and !deepEqual(last[old + run], commands[new + run])) run += 1;
            try writeOp(writer, .change, run);
            for (last[old..][0..run], commands[new..][0..run]) |before, after| try writeChange(writer, before, after);
            old += run;
            new += run;
        } else {
            const removed = distanceTo(last[old + 1 ..], commands[new]);
            const added = distanceTo(commands[new + 1 ..], last[old]);
            if (removed != null and (added == null or removed.? <= added.?)) {
                try writeOp(writer, .skip, removed.? + 1);
                old += removed.? + 1;
            } else if (added) |distance| {
                try writeInserted(writer, commands[new..][0 .. distance + 1]);
                new += distance + 1;
            } else {
                try writeOp(writer, .skip, 1);
                try writeInserted(writer, commands[new..][0..1]);
                old += 1;
                new += 1;
            }
        }
    }
}

/// The index in `commands`, within the resync window, of the first
/// command of `wanted`'s element and kind.
fn distanceTo(commands: anytype, wanted: anytype) ?usize {
    for (commands[0..@min(commands.len, resync_window)], 0..) |command, distance| {
        if (sameElement(command, wanted)) return distance;
    }
    return null;
}

fn sameElement(a: anytype, b: @TypeOf(a)) bool {
    return a.id == b.id and std.meta.activeTag(a.payload) == std.meta.activeTag(b.payload);
}

fn writeInserted(writer: *std.Io.Writer, commands: anytype) WriteError!void {
    try writeOp(writer, .insert, commands.len);
    for (commands) |command| {
        try writer.writeInt(u64, command.id, .little);
        try encodeValue(writer, command.bounds);
        try encodeValue(writer, command.z);
        try encodeValue(writer, command.payload);
    }
}

fn writeChange(writer: *std.Io.Writer, before: anytype, after: @TypeOf(before)) WriteError!void {
    const changed: CommandChanged = .{
        .x = !deepEqual(before.bounds.x, after.bounds.x),
        .y = !deepEqual(before.bounds.y, after.bounds.y),
        .width = !deepEqual(before.bounds.width, after.bounds.width),
        .height = !deepEqual(before.bounds.height, after.bounds.height),
        .z = before.z != after.z,
        .payload = !deepEqual(before.payload, after.payload),
    };
    try writer.writeByte(@bitCast(changed));
    if (changed.x) try encodeValue(writer, after.bounds.x);
    if (changed.y) try encodeValue(writer, after.bounds.y);
    if (changed.width) try encodeValue(writer, after.bounds.width);
    if (changed.height) try encodeValue(writer, after.bounds.height);
    if (changed.z) try encodeValue(writer, after.z);
    if (changed.payload) try encodeValue(writer, after.payload);
}

fn readCommands(comptime Command: type, reader: *std.Io.Reader, last: []const Command, decoded: *CommandHistory(Command)) ReadError!void {
    decoded.reset();
    const count = try readLength(reader);
    if (count > decoded.commands.len) return error.CapacityExceeded;
    var old: usize = 0;
    while (decoded.count < count) {
        const op_word = try readUleb(reader, u64);
        const op: CommandOp = @enumFromInt(@as(u2, @truncate(op_word)));
        const run = std.math.cast(usize, op_word >> 2) orelse return error.Malformed;
        if (run == 0) return error.Malformed;
        const reaches_last = op == .keep or op == .skip or op == .change;
        if (reaches_last and run > last.len - old) return error.Malformed;
        if (op != .skip and run > count - decoded.count) return error.Malformed;
        switch (op) {
            .keep => for (last[old..][0..run]) |command| try decoded.appendCopy(command),
            .skip => {},
            .insert => for (0..run) |_| {
                var command: Command = undefined;
                command.id = try reader.takeInt(u64, .little);
                command.bounds = try decodeValue(zui.Rect, reader, undefined);
                command.z = try decodeValue(i16, reader, undefined);
                command.payload = try decodeValue(Command.Payload, reader, &decoded.storage);
                try decoded.append(command);
            },
            .change => for (last[old..][0..run]) |before| {
                const changed: CommandChanged = @bitCast(try reader.takeByte());
                if (changed.reserved != 0) return error.Malformed;
                var command = before;
                if (changed.x) command.bounds.x = try decodeValue(f32, reader, undefined);
                if (changed.y) command.bounds.y = try decodeValue(f32, reader, undefined);
                if (changed.width) command.bounds.width = try decodeValue(f32, reader, undefined);
                if (changed.height) command.bounds.height = try decodeValue(f32, reader, undefined);
                if (changed.z) command.z = try decodeValue(i16, reader, undefined);
                if (changed.payload) {
                    command.payload = try decodeValue(Command.Payload, reader, &decoded.storage);
                    try decoded.append(command);
                } else try decoded.appendCopy(command);
            },
        }
        if (reaches_last) old += run;
    }
}

fn readUleb(reader: *std.Io.Reader, comptime T: type) ReadError!T {
    return reader.takeLeb128(T) catch |err| switch (err) {
        error.Overflow => error.Malformed,
        else => |read_error| read_error,
    };
}

fn readLength(reader: *std.Io.Reader) ReadError!usize {
    return std.math.cast(usize, try readUleb(reader, u64)) orelse error.Malformed;
}

fn checkPayloads(comptime Ui: type) void {
    const Payload = Ui.RenderCommand.Payload;
    if (@hasField(Payload, "image")) checkPayload(@FieldType(Ui.RenderCommand.Image, "handle"), "ImageHandle");
    if (@hasField(Payload, "custom")) checkPayload(@FieldType(Payload, "custom"), "CustomData");
    if (@hasField(Payload, "material")) checkPayload(@FieldType(Ui.RenderCommand.Material, "handle"), "MaterialHandle");
    if (Ui.has_sources) {
        for (@typeInfo(Ui.Deliveries).@"struct".fields) |field| checkPayload(field.type, "delivery of source `" ++ field.name ++ "`");
    }
}

fn checkPayload(comptime T: type, comptime what: []const u8) void {
    if (declaresSerialize(T)) {
        if (!@hasDecl(T, "zuiDeserialize")) @compileError("zui_wire: " ++ @typeName(T) ++ " declares zuiSerialize but not zuiDeserialize");
        return;
    }
    if (pointerIn(T)) |Pointer| {
        @compileError("zui_wire: " ++ what ++ " holds a pointer (" ++ @typeName(Pointer) ++ "); declare zuiSerialize on it to send it");
    }
}

fn declaresSerialize(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "zuiSerialize"),
        else => false,
    };
}

/// The first pointer `T` holds outside a type that serializes itself.
fn pointerIn(comptime T: type) ?type {
    if (declaresSerialize(T)) return null;
    return switch (@typeInfo(T)) {
        .pointer, .@"fn", .@"opaque" => T,
        .optional => |optional| pointerIn(optional.child),
        .array => |array| pointerIn(array.child),
        .vector => |vector| pointerIn(vector.child),
        .error_union => |error_union| pointerIn(error_union.payload),
        .@"struct" => |info| for (info.fields) |field| {
            if (pointerIn(field.type)) |Pointer| break Pointer;
        } else null,
        .@"union" => |info| for (info.fields) |field| {
            if (pointerIn(field.type)) |Pointer| break Pointer;
        } else null,
        else => null,
    };
}

/// Little-endian and compact: integers as LEB128, floats as their bits,
/// unions by tag, slices by length, errors by name. A type that declares
/// `zuiSerialize` writes itself.
fn encodeValue(writer: *std.Io.Writer, value: anytype) WriteError!void {
    const T = @TypeOf(value);
    if (comptime declaresSerialize(T)) {
        return value.zuiSerialize(Serializer{ .writer = writer }) catch error.WriteFailed;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try writer.writeByte(@intFromBool(value)),
        .int => |int| if (int.bits == 0) {} else if (int.bits <= 8)
            try writer.writeByte(@bitCast(@as(@Int(int.signedness, 8), value)))
        else switch (int.signedness) {
            .unsigned => try writer.writeUleb128(value),
            .signed => try writer.writeSleb128(value),
        },
        .float => |float| try writer.writeInt(@Int(.unsigned, float.bits), @bitCast(value), .little),
        .@"enum" => try encodeValue(writer, @intFromEnum(value)),
        .@"struct" => |info| if (info.layout == .@"packed") {
            try encodeValue(writer, @as(info.backing_integer.?, @bitCast(value)));
        } else inline for (info.fields) |field| {
            if (!field.is_comptime) try encodeValue(writer, @field(value, field.name));
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("zui_wire: cannot send " ++ @typeName(T) ++ ", a union without a tag");
            try encodeValue(writer, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| try encodeValue(writer, payload),
            }
        },
        .optional => if (value) |payload| {
            try writer.writeByte(1);
            try encodeValue(writer, payload);
        } else try writer.writeByte(0),
        .array => |array| if (array.child == u8) try writer.writeAll(&value) else for (value) |item| try encodeValue(writer, item),
        .vector => |vector| for (0..vector.len) |index| try encodeValue(writer, value[index]),
        .pointer => |pointer| {
            if (pointer.size == .one) return encodeValue(writer, value.*);
            if (pointer.size != .slice) @compileError("zui_wire: cannot send " ++ @typeName(T) ++ ", a pointer; declare zuiSerialize on the type holding it");
            try writer.writeUleb128(value.len);
            if (pointer.child == u8) try writer.writeAll(value) else for (value) |item| try encodeValue(writer, item);
        },
        .error_set => {
            const name = @errorName(value);
            try writer.writeUleb128(name.len);
            try writer.writeAll(name);
        },
        .error_union => if (value) |payload| {
            try writer.writeByte(0);
            try encodeValue(writer, payload);
        } else |err| {
            try writer.writeByte(1);
            try encodeValue(writer, err);
        },
        else => @compileError("zui_wire: cannot send " ++ @typeName(T)),
    }
}

/// Reads what `encodeValue` wrote. Slices are placed in `storage`.
fn decodeValue(comptime T: type, reader: *std.Io.Reader, storage: *Storage) ReadError!T {
    var value: T = undefined;
    try decodeInto(T, &value, reader, storage);
    return value;
}

/// `decodeValue` through a pointer, since `ReadError!T` cannot name an
/// error set `T`.
fn decodeInto(comptime T: type, value: *T, reader: *std.Io.Reader, storage: *Storage) ReadError!void {
    if (comptime declaresSerialize(T)) {
        value.* = T.zuiDeserialize(Deserializer{ .reader = reader, .storage = storage }) catch |err| return narrowReadError(err);
        return;
    }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => value.* = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => return error.Malformed,
        },
        .int => |int| value.* = if (int.bits == 0)
            0
        else if (int.bits <= 8)
            std.math.cast(T, @as(@Int(int.signedness, 8), @bitCast(try reader.takeByte()))) orelse return error.Malformed
        else
            reader.takeLeb128(T) catch |err| return switch (err) {
                error.Overflow => error.Malformed,
                else => |read_error| read_error,
            },
        .float => |float| value.* = @bitCast(try reader.takeInt(@Int(.unsigned, float.bits), .little)),
        .@"enum" => |info| {
            const tag = try decodeValue(info.tag_type, reader, storage);
            value.* = if (info.is_exhaustive) std.enums.fromInt(T, tag) orelse return error.Malformed else @enumFromInt(tag);
        },
        .@"struct" => |info| if (info.layout == .@"packed") {
            value.* = @bitCast(try decodeValue(info.backing_integer.?, reader, storage));
        } else inline for (info.fields) |field| {
            if (!field.is_comptime) try decodeInto(field.type, &@field(value, field.name), reader, storage);
        },
        .@"union" => |info| switch (try decodeValue(info.tag_type.?, reader, storage)) {
            inline else => |tag| {
                value.* = @unionInit(T, @tagName(tag), undefined);
                try decodeInto(@FieldType(T, @tagName(tag)), &@field(value, @tagName(tag)), reader, storage);
            },
        },
        .optional => |optional| switch (try reader.takeByte()) {
            0 => value.* = null,
            1 => {
                value.* = @as(optional.child, undefined);
                try decodeInto(optional.child, &value.*.?, reader, storage);
            },
            else => return error.Malformed,
        },
        .array => |array| if (array.child == u8) {
            try reader.readSliceAll(value);
        } else for (value) |*item| try decodeInto(array.child, item, reader, storage),
        .vector => |vector| for (0..vector.len) |index| {
            value[index] = try decodeValue(vector.child, reader, storage);
        },
        .pointer => |pointer| {
            if (pointer.size == .one) {
                const pointee = try storage.takeOne(pointer.child);
                try decodeInto(pointer.child, pointee, reader, storage);
                value.* = pointee;
                return;
            }
            if (pointer.size != .slice) @compileError("zui_wire: cannot receive " ++ @typeName(T) ++ ", a pointer; declare zuiDeserialize on the type holding it");
            const items = try storage.take(pointer.child, try readLength(reader));
            if (pointer.child == u8) {
                try reader.readSliceAll(items);
            } else for (items) |*item| try decodeInto(pointer.child, item, reader, storage);
            value.* = items;
        },
        .error_set => |errors| {
            const known = errors orelse @compileError("zui_wire: cannot receive " ++ @typeName(T) ++ "; name the errors it can hold");
            const longest = comptime longest: {
                var length = 0;
                for (known) |known_error| length = @max(length, known_error.name.len);
                break :longest length;
            };
            const length = try readLength(reader);
            if (length > longest) return error.Malformed;
            var name_buffer: [longest]u8 = undefined;
            const name = name_buffer[0..length];
            try reader.readSliceAll(name);
            inline for (known) |known_error| {
                if (std.mem.eql(u8, name, known_error.name)) {
                    value.* = @field(T, known_error.name);
                    return;
                }
            }
            return error.Malformed;
        },
        .error_union => |error_union| switch (try reader.takeByte()) {
            0 => value.* = try decodeValue(error_union.payload, reader, storage),
            1 => {
                var err: error_union.error_set = undefined;
                try decodeInto(error_union.error_set, &err, reader, storage);
                value.* = err;
            },
            else => return error.Malformed,
        },
        else => @compileError("zui_wire: cannot receive " ++ @typeName(T)),
    }
}

/// A `zuiDeserialize` may fail with errors of its own; on the wire they all
/// mean the bytes were not what it wrote.
fn narrowReadError(err: anyerror) ReadError {
    inline for (@typeInfo(ReadError).error_set.?) |known| {
        const read_error = @field(ReadError, known.name);
        if (err == read_error) return read_error;
    }
    return error.Malformed;
}

/// Equal as the wire sees it: floats by their bits, slices by what they
/// hold.
fn deepEqual(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .void => return true,
        .float => |float| return @as(@Int(.unsigned, float.bits), @bitCast(a)) == @as(@Int(.unsigned, float.bits), @bitCast(b)),
        .@"struct" => |info| {
            if (info.layout == .@"packed") return @as(info.backing_integer.?, @bitCast(a)) == @as(info.backing_integer.?, @bitCast(b));
            inline for (info.fields) |field| {
                if (!deepEqual(@field(a, field.name), @field(b, field.name))) return false;
            }
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                inline else => |payload, tag| deepEqual(payload, @field(b, @tagName(tag))),
            };
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEqual(a.?, b.?);
        },
        .array => {
            for (a, b) |item_a, item_b| if (!deepEqual(item_a, item_b)) return false;
            return true;
        },
        .vector => |vector| {
            for (0..vector.len) |index| if (!deepEqual(a[index], b[index])) return false;
            return true;
        },
        .pointer => |pointer| {
            if (pointer.size == .one) return a == b or deepEqual(a.*, b.*);
            if (pointer.size != .slice) return a == b;
            if (a.len != b.len) return false;
            if (pointer.child == u8) return std.mem.eql(u8, a, b);
            for (a, b) |item_a, item_b| if (!deepEqual(item_a, item_b)) return false;
            return true;
        },
        .error_union => {
            const payload_a = a catch |error_a| return if (b) |_| false else |error_b| error_a == error_b;
            const payload_b = b catch return false;
            return deepEqual(payload_a, payload_b);
        },
        else => return a == b,
    }
}

test {
    _ = @import("tests.zig");
    _ = @import("remote_tests.zig");
}
