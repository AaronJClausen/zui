const std = @import("std");
const zui = @import("zui");
const wire = @import("zui_wire.zig");

const Io = std.Io;
const Stream = Io.net.Stream;

const socket_buffer_bytes = 64 * 1024;
const closing_patience_ns = std.time.ns_per_s;

/// The host a context runs on when its window is in another process: each
/// record comes from a `Client` over a connection, and each frame goes back
/// to it through `Renderer(Ui)`, which writes into the `.wire` surface this
/// host gives.
///
/// The connection is the application's to make, and it hands the host one
/// end with `attach`; under `zui_app`, in its `init`:
///
/// ```zig
/// pub const Host = zui_wire.Host(Ui);
/// pub const Renderer = zui_wire.Renderer(Ui);
///
/// pub fn init(app: *App, start: zui_app.Start(App)) !void {
///     var server = try address.listen(start.io, .{});
///     defer server.deinit(start.io);
///     try start.host.attach(start.gpa, try server.accept(start.io));
/// }
/// ```
///
/// Time is the client's: a record carries its host's clock, and between
/// records this host counts on from the last one, so `.at` waits and
/// records made after a wake stay in the clock the client's events use.
/// The host must not move after `init`, since the renderer and the task
/// reading the connection hold pointers to it.
pub fn Host(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.wire);

        io: Io = undefined,
        /// The fonts this side measures with, set by the renderer, written
        /// in the stream's header so a client with other fonts refuses it.
        fingerprint: ?u64 = null,
        link: ?*Link = null,
        /// Set by a record arriving, the connection ending and a wake;
        /// cleared after a wait returns.
        signal: Io.Event = .unset,

        const Link = struct {
            gpa: std.mem.Allocator,
            stream: Stream,
            stream_reader: Stream.Reader,
            stream_writer: Stream.Writer,
            read_buffer: [socket_buffer_bytes]u8,
            write_buffer: [socket_buffer_bytes]u8,
            decoder: wire.Decoder(Ui),
            encoder: wire.Encoder(Ui),
            header_written: bool = false,
            reading: Io.Future(void) = undefined,

            /// Guards everything below, which the reading task writes.
            mutex: Io.Mutex = .init,
            /// What arrived since the last poll: the newest parameters and
            /// every event, in order.
            inbox: zui.RecordBuilder,
            /// The client's clock less this process's, as of the last record.
            remote_minus_local_ns: i128 = 0,
            last_polled_at: zui.Instant = .zero,
            closed: bool = false,
            failure: ?anyerror = null,
        };

        pub fn init(self: *Self, io: Io, window: zui.WindowOptions) error{}!void {
            _ = window;
            self.io = io;
        }

        /// Closes the connection, ending the task that reads it.
        pub fn deinit(self: *Self) void {
            const still_connected = self.connected();
            const link = self.link orelse return;
            self.link = null;
            // Shutting down a connection the client already ended is an
            // unexpected error on Windows, which a debug build reports.
            if (still_connected) link.stream.shutdown(self.io, .both) catch {};
            link.reading.cancel(self.io);
            link.stream.close(self.io);
            link.encoder.deinit(link.gpa);
            link.decoder.deinit(link.gpa);
            link.gpa.free(link.inbox.event_buffer);
            link.gpa.free(link.inbox.text_buffer);
            link.gpa.destroy(link);
        }

        /// Takes `stream`, a connection to a `Client`: reads its header and
        /// its first record, so the first poll has the client's viewport,
        /// then reads the rest on a task of the `Io`'s own. Fails when the
        /// client sends something else, or the `Io` cannot run a task
        /// concurrently. Allocates only here.
        pub fn attach(self: *Self, gpa: std.mem.Allocator, stream: Stream) !void {
            std.debug.assert(self.link == null);
            errdefer stream.close(self.io);
            const link = try gpa.create(Link);
            errdefer gpa.destroy(link);
            const event_buffer = try gpa.alloc(zui.Event, Ui.limits.max_events_per_frame);
            errdefer gpa.free(event_buffer);
            const text_buffer = try gpa.alloc(u8, recordTextBytes());
            errdefer gpa.free(text_buffer);
            var decoder: wire.Decoder(Ui) = try .init(gpa, .{ .events = Ui.limits.max_events_per_frame, .record_bytes = recordTextBytes(), .commands = 0, .frame_bytes = 0 });
            errdefer decoder.deinit(gpa);
            var encoder: wire.Encoder(Ui) = try .init(gpa);
            errdefer encoder.deinit(gpa);
            link.* = .{
                .gpa = gpa,
                .stream = stream,
                .stream_reader = undefined,
                .stream_writer = undefined,
                .read_buffer = undefined,
                .write_buffer = undefined,
                .decoder = decoder,
                .encoder = encoder,
                .inbox = .init(event_buffer, text_buffer),
            };
            link.stream_reader = stream.reader(self.io, &link.read_buffer);
            link.stream_writer = stream.writer(self.io, &link.write_buffer);

            const reader = &link.stream_reader.interface;
            try wire.readHeader(reader, null);
            const first = try link.decoder.next(reader) orelse return error.EndOfStream;
            if (first != .record) return error.Malformed;
            self.receive(link, first.record);
            link.reading = try self.io.concurrent(readRecords, .{ self, link });
            self.link = link;
        }

        fn recordTextBytes() u32 {
            return @as(u32, Ui.limits.max_text_input_bytes) + Ui.limits.max_dropped_path_bytes;
        }

        /// The client's clock now, as far as this side can tell: the last
        /// record's instant plus the time since it arrived.
        pub fn now(self: *Self) zui.Instant {
            const link = self.link orelse return .zero;
            link.mutex.lockUncancelable(self.io);
            defer link.mutex.unlock(self.io);
            return self.remoteNow(link);
        }

        /// False before `attach` and once the connection has ended.
        pub fn connected(self: *Self) bool {
            const link = self.link orelse return false;
            link.mutex.lockUncancelable(self.io);
            defer link.mutex.unlock(self.io);
            return !link.closed;
        }

        /// Why the connection ended, when the client sent what this version
        /// does not read; null when it closed or was lost.
        pub fn failure(self: *Self) ?anyerror {
            const link = self.link orelse return null;
            link.mutex.lockUncancelable(self.io);
            defer link.mutex.unlock(self.io);
            return link.failure;
        }

        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            const link = self.link orelse return false;
            link.mutex.lockUncancelable(self.io);
            defer link.mutex.unlock(self.io);
            const inbox = &link.inbox;
            if (link.closed and inbox.event_count == 0) return false;
            const polled_at = self.remoteNow(link);
            link.last_polled_at = polled_at;
            record.begin(.{ .now = polled_at, .viewport = inbox.params.viewport, .scale = inbox.params.scale });
            for (inbox.events()) |event| appendCopy(record, event);
            record.dropped_events +|= inbox.dropped_events;
            record.dropped_text_bytes +|= inbox.dropped_text_bytes;
            inbox.begin(.{ .now = inbox.params.now, .viewport = inbox.params.viewport, .scale = inbox.params.scale });
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        pub fn zuiWait(self: *Self, next: zui.NextFrame) void {
            switch (next) {
                .immediately => {},
                .at => |instant| self.waitUntil(self.localDeadline(instant)),
                .on_event => self.waitUntil(null),
            }
            self.signal.reset();
        }

        pub fn zuiSurface(self: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            return .{ .wire = .{ .connection = self } };
        }

        /// Host requests travel with the frame, for the client's host to
        /// apply.
        pub fn zuiApply(_: *Self, window: zui.WindowId, _: zui.HostRequests) void {
            std.debug.assert(window == .main);
        }

        /// Writes `frame` to the client, as changes from the last one, after
        /// the stream's header. A connection that fails to take it is
        /// closed, so the next poll reports the window gone.
        pub fn sendFrame(self: *Self, frame: anytype) void {
            const link = self.link orelse return;
            const writer = &link.stream_writer.interface;
            const sent = sent: {
                if (!link.header_written) {
                    wire.writeHeader(writer, self.fingerprint) catch break :sent false;
                    link.header_written = true;
                }
                link.encoder.writeFrame(writer, frame) catch break :sent false;
                writer.flush() catch break :sent false;
                break :sent true;
            };
            if (!sent) self.close(link, null);
        }

        fn waitUntil(self: *Self, deadline: ?Io.Clock.Timestamp) void {
            while (!self.signal.isSet()) {
                const instant = deadline orelse {
                    self.signal.waitUncancelable(self.io);
                    continue;
                };
                // A timed wait on Windows may end a little before its deadline.
                if (self.localNanoseconds() >= instant.raw.nanoseconds) return;
                self.signal.waitTimeout(self.io, .{ .deadline = instant }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return,
                };
            }
        }

        /// `instant`, in the client's clock, on this process's.
        fn localDeadline(self: *Self, instant: zui.Instant) Io.Clock.Timestamp {
            const offset = if (self.link) |link| offset: {
                link.mutex.lockUncancelable(self.io);
                defer link.mutex.unlock(self.io);
                break :offset link.remote_minus_local_ns;
            } else 0;
            return .{ .raw = .fromNanoseconds(@as(i96, @intCast(@as(i128, instant.nanoseconds) - offset))), .clock = .awake };
        }

        fn localNanoseconds(self: *Self) i128 {
            return Io.Timestamp.now(self.io, .awake).nanoseconds;
        }

        /// The link's mutex is held.
        fn remoteNow(self: *Self, link: *Link) zui.Instant {
            const estimate = std.math.lossyCast(u64, self.localNanoseconds() + link.remote_minus_local_ns);
            return .fromNanoseconds(@max(estimate, link.last_polled_at.nanoseconds, link.inbox.params.now.nanoseconds));
        }

        fn readRecords(self: *Self, link: *Link) void {
            const reader = &link.stream_reader.interface;
            while (true) {
                const message = (link.decoder.next(reader) catch |err| return self.close(link, protocolFailure(err))) orelse return self.close(link, null);
                switch (message) {
                    .record => |record| self.receive(link, record),
                    .frame => return self.close(link, error.Malformed),
                }
            }
        }

        fn receive(self: *Self, link: *Link, record: *const Ui.FrameRecord) void {
            {
                link.mutex.lockUncancelable(self.io);
                defer link.mutex.unlock(self.io);
                link.inbox.params.now = record.params.now;
                link.inbox.params.viewport = record.params.viewport;
                link.inbox.params.scale = record.params.scale;
                for (record.events) |event| appendCopy(&link.inbox, event);
                link.remote_minus_local_ns = @as(i128, record.params.now.nanoseconds) - self.localNanoseconds();
            }
            self.signal.set(self.io);
        }

        fn close(self: *Self, link: *Link, reason: ?anyerror) void {
            {
                link.mutex.lockUncancelable(self.io);
                defer link.mutex.unlock(self.io);
                if (!link.closed) link.failure = reason;
                link.closed = true;
            }
            self.signal.set(self.io);
        }

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.signal.set(self.io);
        }
    };
}

/// The renderer for a `Host(Ui)`: it draws nothing itself, but writes each
/// frame to the client, whose own renderer draws it. It declares the
/// commands `Ui` generates, so `zui_app` reports what the client's
/// renderer lowers, and takes the application's text contract to put its
/// fingerprint in the stream's header.
pub fn Renderer(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.wire);
        pub const zui_commands: zui.CommandSet = Ui.RenderCommand.commands;
        pub const zui_render_thread = true;

        /// `init(self, surface, text)` when `Ui` measures text, so the
        /// stream carries the fonts' fingerprint; `init(self, surface)`
        /// otherwise.
        pub const init = if (Ui.has_text) initWithText else initWithoutText;

        fn initWithText(_: *Self, surface: zui.Surface, text: *const Ui.Text) error{UnsupportedSurface}!void {
            (try hostOf(surface)).fingerprint = wire.fingerprintOf(text);
        }

        fn initWithoutText(_: *Self, surface: zui.Surface) error{UnsupportedSurface}!void {
            _ = try hostOf(surface);
        }

        pub fn zuiSubmit(_: *Self, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
            (try hostOf(surface)).sendFrame(frame);
        }

        fn hostOf(surface: zui.Surface) error{UnsupportedSurface}!*Host(Ui) {
            return switch (surface) {
                .wire => |connection| @ptrCast(@alignCast(connection.connection)),
                else => error.UnsupportedSurface,
            };
        }
    };
}

/// The other end of a `Host(Ui)`: a host and a renderer of this process's
/// own, which it joins to an application running elsewhere. It sends what
/// the host polls, and draws the newest frame that came back, so a remote
/// client is nothing more than a host plus a renderer.
///
/// ```zig
/// var client: zui_wire.Client(Ui) = undefined;
/// try client.init(gpa, io, try address.connect(io, .{ .mode = .stream }), .{
///     .waker = host.zuiWaker(),
///     .fingerprint = zui_wire.fingerprintOf(&fonts),
/// });
/// defer client.deinit();
/// while (try client.frame(&host, &renderer)) {}
/// ```
///
/// `frame` is `poll`, `send`, `present` and `wait`, which a client that adds
/// events of its own calls one by one, appending to `builder` after `poll`.
/// Frames are read on a task of the `Io`'s own, which wakes the host when
/// one arrives; frames that arrive faster than they are presented are
/// skipped. It must not move after `init`.
pub fn Client(comptime Ui: type) type {
    return struct {
        const Self = @This();
        const Command = Ui.RenderCommand;

        /// A frame as the client's renderer and host take it.
        pub const Frame = wire.Decoder(Ui).Frame;

        pub const Options = struct {
            /// The client's host's, woken when a frame arrives.
            waker: zui.Waker,
            /// The fonts the client's renderer draws with; a stream measured
            /// with others is refused with `error.FontsDiffer`.
            fingerprint: ?u64 = null,
        };

        gpa: std.mem.Allocator,
        io: Io,
        stream: Stream,
        stream_reader: Stream.Reader,
        stream_writer: Stream.Writer,
        buffers: []u8,
        encoder: wire.Encoder(Ui),
        decoder: wire.Decoder(Ui),
        /// What the client's host polls into, and the client may add to
        /// before `send`.
        builder: zui.RecordBuilder,
        last_sent: ?zui.RecordBuilder.HostParams = null,
        fingerprint: ?u64,
        waker: zui.Waker,
        reading: Io.Future(void),
        /// The frame last presented, and the newest one not yet presented.
        shown: Slot,
        ready: Slot,

        /// Guards `ready` and everything below, which the reading task writes.
        mutex: Io.Mutex = .init,
        ready_is_new: bool = false,
        frames_received: u64 = 0,
        closed: bool = false,
        failure: ?anyerror = null,

        const Slot = struct {
            commands: []Command,
            text: []u8,
            frame: Frame = .{ .number = 0, .params = .{ .now = .zero, .viewport = .{ 0, 0 } }, .host_requests = .{}, .command_list = &.{} },

            fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Slot {
                const commands = try gpa.alloc(Command, Ui.limits.max_render_commands);
                errdefer gpa.free(commands);
                return .{ .commands = commands, .text = try gpa.alloc(u8, Ui.limits.max_text_bytes) };
            }

            fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
                gpa.free(self.text);
                gpa.free(self.commands);
            }

            /// `decoded`'s commands, with their text in this slot's memory.
            /// The decoder checked them against the same capacities.
            fn copy(self: *Slot, decoded: *const Frame) void {
                var text_used: usize = 0;
                for (decoded.commands(), self.commands[0..decoded.commands().len]) |command, *kept| {
                    kept.* = command;
                    switch (kept.payload) {
                        .text => |*text| {
                            const content = self.text[text_used..][0..text.content.len];
                            @memcpy(content, text.content);
                            text.content = content;
                            text_used += content.len;
                        },
                        else => {},
                    }
                }
                self.frame = decoded.*;
                self.frame.command_list = self.commands[0..decoded.commands().len];
            }
        };

        /// Takes `stream`, a connection to a `Host(Ui)`, writes the
        /// stream's header and starts reading frames. Allocates only here.
        pub fn init(self: *Self, gpa: std.mem.Allocator, io: Io, stream: Stream, options: Options) !void {
            errdefer stream.close(io);
            const buffers = try gpa.alloc(u8, 2 * socket_buffer_bytes);
            errdefer gpa.free(buffers);
            var encoder: wire.Encoder(Ui) = try .init(gpa);
            errdefer encoder.deinit(gpa);
            var decoder: wire.Decoder(Ui) = try .init(gpa, .of(Ui));
            errdefer decoder.deinit(gpa);
            const event_buffer = try gpa.alloc(zui.Event, Ui.limits.max_events_per_frame);
            errdefer gpa.free(event_buffer);
            const text_buffer = try gpa.alloc(u8, @as(u32, Ui.limits.max_text_input_bytes) + Ui.limits.max_dropped_path_bytes);
            errdefer gpa.free(text_buffer);
            var shown: Slot = try .init(gpa);
            errdefer shown.deinit(gpa);
            var ready: Slot = try .init(gpa);
            errdefer ready.deinit(gpa);
            self.* = .{
                .gpa = gpa,
                .io = io,
                .stream = stream,
                .stream_reader = stream.reader(io, buffers[0..socket_buffer_bytes]),
                .stream_writer = stream.writer(io, buffers[socket_buffer_bytes..]),
                .buffers = buffers,
                .encoder = encoder,
                .decoder = decoder,
                .builder = .init(event_buffer, text_buffer),
                .fingerprint = options.fingerprint,
                .waker = options.waker,
                .reading = undefined,
                .shown = shown,
                .ready = ready,
            };
            const writer = &self.stream_writer.interface;
            try wire.writeHeader(writer, options.fingerprint);
            try writer.flush();
            self.reading = try io.concurrent(readFrames, .{self});
        }

        /// Closes the connection, which ends the application's next poll.
        /// It stops sending first, and reads until the application has
        /// closed its end, for up to `closing_patience_ns`, so the
        /// application never writes a frame into a closed connection.
        pub fn deinit(self: *Self) void {
            // Shutting down a connection the application already ended is an
            // unexpected error on Windows, which a debug build reports.
            if (!self.isClosed()) {
                self.stream.shutdown(self.io, .send) catch {};
                const deadline = Io.Timestamp.now(self.io, .awake).addDuration(.fromNanoseconds(closing_patience_ns));
                while (!self.isClosed() and Io.Timestamp.now(self.io, .awake).nanoseconds < deadline.nanoseconds) {
                    self.io.sleep(.fromMilliseconds(1), .awake) catch break;
                }
            }
            self.reading.cancel(self.io);
            self.stream.close(self.io);
            self.ready.deinit(self.gpa);
            self.shown.deinit(self.gpa);
            self.gpa.free(self.builder.text_buffer);
            self.gpa.free(self.builder.event_buffer);
            self.decoder.deinit(self.gpa);
            self.encoder.deinit(self.gpa);
            self.gpa.free(self.buffers);
        }

        /// One turn: false once the host's window or the connection has
        /// closed. Fails when the stream was refused, as when its fonts
        /// differ, or the renderer failed.
        pub fn frame(self: *Self, host: anytype, renderer: anytype) !bool {
            if (!self.poll(host)) return false;
            self.send();
            _ = try self.present(host, renderer);
            if (self.isClosed()) return false;
            self.wait(host);
            return true;
        }

        /// The host's poll into `builder`; false once its window closed.
        pub fn poll(self: *Self, host: anytype) bool {
            return host.zuiPoll(.main, &self.builder);
        }

        /// Sends `builder`'s record when it has events, or when the viewport
        /// or scale changed: a record of only the time passing is left out,
        /// as the application's host counts the time on itself.
        pub fn send(self: *Self) void {
            const params = self.builder.params;
            const measured: zui.RecordBuilder.HostParams = .{ .now = params.now, .viewport = params.viewport, .scale = params.scale };
            const resized = if (self.last_sent) |last| !std.meta.eql(last.viewport, measured.viewport) or last.scale != measured.scale else true;
            if (!resized and self.builder.event_count == 0) return;
            const record: Ui.FrameRecord = .{ .params = params, .events = self.builder.events() };
            const writer = &self.stream_writer.interface;
            const sent = sent: {
                self.encoder.writeRecord(writer, &record) catch break :sent false;
                writer.flush() catch break :sent false;
                break :sent true;
            };
            if (sent) {
                self.last_sent = measured;
            } else self.close(null);
        }

        /// Draws the newest frame that arrived, if one did since the last,
        /// and applies its host requests. False when there was none.
        pub fn present(self: *Self, host: anytype, renderer: anytype) !bool {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (self.failure) |err| return err;
                if (!self.ready_is_new) return false;
                std.mem.swap(Slot, &self.shown, &self.ready);
                self.ready_is_new = false;
            }
            try renderer.zuiSubmit(host.zuiSurface(.main), &self.shown.frame);
            host.zuiApply(.main, self.shown.frame.host_requests);
            return true;
        }

        /// Until input, or a frame arriving.
        pub fn wait(_: *Self, host: anytype) void {
            host.zuiWait(.on_event);
        }

        /// The frame `present` drew last, valid until the next `present`.
        pub fn shownFrame(self: *const Self) *const Frame {
            return &self.shown.frame;
        }

        /// Frames read from the connection, whether or not presented.
        pub fn framesReceived(self: *Self) u64 {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.frames_received;
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.closed;
        }

        fn readFrames(self: *Self) void {
            const reader = &self.stream_reader.interface;
            wire.readHeader(reader, self.fingerprint) catch |err| return self.close(protocolFailure(err));
            while (true) {
                const message = (self.decoder.next(reader) catch |err| return self.close(protocolFailure(err))) orelse return self.close(null);
                switch (message) {
                    .frame => |decoded| {
                        {
                            self.mutex.lockUncancelable(self.io);
                            defer self.mutex.unlock(self.io);
                            self.ready.copy(decoded);
                            self.ready_is_new = true;
                            self.frames_received += 1;
                        }
                        self.waker.wake();
                    },
                    .record => return self.close(error.Malformed),
                }
            }
        }

        fn close(self: *Self, reason: ?anyerror) void {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                if (!self.closed) self.failure = reason;
                self.closed = true;
            }
            self.waker.wake();
        }
    };
}

/// A connection that ends or fails is closed, as a window is; only bytes
/// that are not a stream of this version are a failure to report.
fn protocolFailure(err: anyerror) ?anyerror {
    return if (err == error.ReadFailed or err == error.EndOfStream) null else err;
}

fn appendCopy(builder: *zui.RecordBuilder, event: zui.Event) void {
    switch (event) {
        .text => |text| builder.appendText(text),
        .files_dropped => |drop| builder.appendFilesDropped(drop),
        else => builder.append(event),
    }
}
