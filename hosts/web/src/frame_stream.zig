const std = @import("std");
const zui_wire = @import("zui_wire");

/// The browser's end of a wire stream from a context of type `Ui`. The
/// transport hands over bytes in whatever pieces it receives them, and each
/// frame is decoded once all of it has arrived. Memory is reserved by
/// `init`.
///
/// ```zig
/// var stream: FrameStream(Ui) = try .init(gpa, .{});
/// // As each piece arrives:
/// try stream.receive(piece);
/// // Before drawing:
/// var newest: ?*const FrameStream(Ui).Frame = null;
/// while (try stream.nextFrame()) |frame| newest = frame;
/// ```
pub fn FrameStream(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const Decoder = zui_wire.Decoder(Ui);
        /// Valid until the next frame is decoded.
        pub const Frame = Decoder.Frame;

        pub const Options = struct {
            capacity: zui_wire.Capacity = .of(Ui),
            /// The most bytes held of messages that have not arrived whole,
            /// so at least the largest message the stream carries: a key
            /// frame of every command.
            max_pending_bytes: usize = 1 << 20,
            /// The fonts this end draws with, `zui_wire.fingerprintOf(&text)`;
            /// a stream measured with others is rejected.
            fingerprint: ?u64 = null,
        };

        pub const ReceiveError = error{
            /// More bytes have arrived than are held, which a transport that
            /// waits for `nextFrame` between pieces sees only for a message
            /// beyond `max_pending_bytes`.
            CapacityExceeded,
        };

        pub const FrameError = zui_wire.HeaderError || error{
            /// A stream of frames carried a record, which only goes the
            /// other way.
            UnexpectedRecord,
        };

        decoder: Decoder,
        pending: []u8,
        pending_end: usize = 0,
        read_start: usize = 0,
        fingerprint: ?u64,
        header_read: bool = false,

        pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Self {
            var decoder: Decoder = try .init(gpa, options.capacity);
            errdefer decoder.deinit(gpa);
            return .{ .decoder = decoder, .pending = try gpa.alloc(u8, options.max_pending_bytes), .fingerprint = options.fingerprint };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.pending);
            self.decoder.deinit(gpa);
        }

        /// Copies `bytes` in after those that arrived before.
        pub fn receive(self: *Self, bytes: []const u8) ReceiveError!void {
            const room = try self.roomFor(bytes.len);
            @memcpy(room, bytes);
            self.received(bytes.len);
        }

        /// Memory for the next `count` bytes, for a transport that writes
        /// them in place and then calls `received(count)`.
        pub fn roomFor(self: *Self, count: usize) ReceiveError![]u8 {
            self.dropRead();
            if (count > self.pending.len - self.pending_end) return error.CapacityExceeded;
            return self.pending[self.pending_end..][0..count];
        }

        /// Takes the `count` bytes written into `roomFor(count)`.
        pub fn received(self: *Self, count: usize) void {
            std.debug.assert(count <= self.pending.len - self.pending_end);
            self.pending_end += count;
        }

        /// The next frame that has arrived whole, or null until more bytes
        /// do. Frames come in the order they were written, each decoded,
        /// since a frame is written as changes from the one before.
        pub fn nextFrame(self: *Self) FrameError!?*const Frame {
            if (!self.header_read) {
                var header: std.Io.Reader = .fixed(self.unread());
                zui_wire.readHeader(&header, self.fingerprint) catch |err| return self.waitingFor(err);
                self.read_start += header.seek;
                self.header_read = true;
            }
            var reader: std.Io.Reader = .fixed(self.unread());
            const message = (self.decoder.next(&reader) catch |err| return self.waitingFor(err)) orelse return null;
            self.read_start += reader.seek;
            return switch (message) {
                .frame => |frame| frame,
                .record => error.UnexpectedRecord,
            };
        }

        fn unread(self: *const Self) []const u8 {
            return self.pending[self.read_start..self.pending_end];
        }

        /// Null while the rest of a message may still arrive; the decoder
        /// is left as it was, to read the message again whole.
        fn waitingFor(self: *const Self, err: zui_wire.HeaderError) FrameError!?*const Frame {
            if (err != error.EndOfStream) return err;
            const message_fills_every_byte_held = self.unread().len == self.pending.len;
            return if (message_fills_every_byte_held) error.CapacityExceeded else null;
        }

        fn dropRead(self: *Self) void {
            if (self.read_start == 0) return;
            const unread_count = self.pending_end - self.read_start;
            std.mem.copyForwards(u8, self.pending[0..unread_count], self.pending[self.read_start..self.pending_end]);
            self.pending_end = unread_count;
            self.read_start = 0;
        }
    };
}
