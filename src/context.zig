const std = @import("std");
const options = @import("zui_options");
const style = @import("style.zig");
const id_module = @import("id.zig");
const text_layout = @import("text.zig");
const command_types = @import("commands.zig");
const layout = @import("layout.zig");
const emission = @import("emission.zig");

const Id = id_module.Id;

pub const Config = struct {
    /// Maximum elements declared in one frame, including zui's root.
    max_elements: u32 = 4096,
    /// Bytes of text one frame may reference (copied into the frame arena).
    max_text_bytes: u32 = 64 * 1024,
    /// Maximum nesting depth of open elements, including zui's root.
    max_depth: u16 = 64,
    /// Render commands one frame may emit. Each wrapped line of text is one.
    max_render_commands: u32 = 8192,
    /// Persistent per-id state slots (0.2). Must be a power of two.
    state_slots: u32 = 1024,
    /// Frames a state slot survives without being touched (0.2).
    state_ttl_frames: u8 = 2,
    /// Text measurement cache entries. Must be a power of two.
    measure_cache_entries: u32 = 4096,
    /// Number of frames that can be alive at once. 2 = double buffering.
    frames_in_flight: u8 = 2,
    /// Payload type of `.custom` elements and render commands.
    CustomData: type = void,
    /// Payload type of `.image` elements, e.g. a texture handle.
    ImageHandle: type = u64,
    /// Font identifier passed back to the platform. An integer or enum type.
    FontId: type = u16,
};

/// The configuration of one element. Only the kinds that are set are stored.
pub const ElementConfig = struct {
    id: Id = .none,
    layout: ?style.Layout = null,
    background: ?style.Color = null,
    corner_radius: style.CornerRadius = .zero,
    border: ?style.Border = null,
};

pub const Input = struct {
    viewport: [2]f32,
    dt_seconds: f32 = 0,
};

pub const Limit = enum {
    elements,
    text_bytes,
    depth,
    render_commands,

    /// The `Config` field that raises this limit.
    pub fn configField(self: Limit) []const u8 {
        return switch (self) {
            .elements => "max_elements",
            .text_bytes => "max_text_bytes",
            .depth => "max_depth",
            .render_commands => "max_render_commands",
        };
    }
};

pub const Diagnostics = struct {
    exceeded: std.EnumSet(Limit) = .initEmpty(),
    /// What the frame asked for, per limit, including what was dropped.
    needed: std.EnumArray(Limit, u32) = .initFill(0),
    /// The first element dropped because a limit was reached.
    first_dropped_id: u64 = 0,
    duplicate_ids: u32 = 0,
    unbalanced: bool = false,

    pub fn ok(self: Diagnostics) bool {
        return self.exceeded.count() == 0 and self.duplicate_ids == 0 and !self.unbalanced;
    }
};

pub const EndFrameError = error{ CapacityExceeded, UnbalancedTree };

const ContentKind = enum(u2) { none, text, image, custom };

fn nextPowerOfTwo(value: u32) u32 {
    return std.math.ceilPowerOfTwoAssert(u32, @max(value, 2));
}

pub fn Context(comptime config: Config, comptime Platform: type) type {
    comptime validateConfig(config);
    comptime validatePlatform(Platform, config.FontId);

    return struct {
        const Self = @This();

        pub const TextStyle = style.TextStyle(config.FontId);
        pub const RenderCommand = command_types.RenderCommand(TextStyle, config.ImageHandle, config.CustomData);
        pub const Index = std.math.IntFittingRange(0, config.max_elements);
        pub const none_index: Index = config.max_elements;
        pub const root_index: Index = 0;
        pub const root_id: Id = .of("zui.root");
        pub const max_elements = config.max_elements;
        pub const max_depth = config.max_depth;
        const id_table_slots = nextPowerOfTwo(config.max_elements * 2);
        pub const snaps_to_pixels = @hasDecl(Platform, "scale");

        pub const Cache = text_layout.MeasureCache(config.FontId, config.measure_cache_entries, Platform);

        pub const Decoration = struct {
            background: ?style.Color,
            corner_radius: style.CornerRadius,
            border: ?style.Border,
        };

        pub const TextRecord = struct {
            bytes_start: u32,
            bytes_len: u32,
            style: TextStyle,
            metrics: text_layout.Metrics,
            first_line: u32,
            line_count: u32,
        };

        /// One frame's memory. Only its methods are API; the fields are the
        /// structure-of-arrays storage the layout passes stream through.
        pub const Frame = struct {
            element_count: u32,
            element_id: [max_elements]u64,
            element_name: [max_elements]id_module.DebugName,
            parent: [max_elements]Index,
            first_child: [max_elements]Index,
            last_child: [max_elements]Index,
            next_sibling: [max_elements]Index,
            child_count: [max_elements]Index,
            layout_index: [max_elements]Index,
            decoration_index: [max_elements]Index,
            content_kind: [max_elements]ContentKind,
            content_index: [max_elements]Index,
            size: [max_elements][2]f32,
            min_size: [max_elements][2]f32,
            position: [max_elements][2]f32,

            layouts: [max_elements]style.Layout,
            layout_count: u32,
            decorations: [max_elements]Decoration,
            decoration_count: u32,
            texts: [max_elements]TextRecord,
            text_count: u32,
            images: [max_elements]config.ImageHandle,
            image_count: u32,
            customs: [max_elements]config.CustomData,
            custom_count: u32,

            text_bytes: [config.max_text_bytes]u8,
            text_bytes_used: u32,
            lines: [config.max_render_commands]text_layout.Line,
            line_count: u32,
            render_commands: [config.max_render_commands]RenderCommand,
            command_count: u32,

            id_table: [id_table_slots]Index,
            diagnostics: Diagnostics,
            viewport: [2]f32,
            held: std.atomic.Value(bool),

            pub fn commands(self: *const Frame) []const RenderCommand {
                return self.render_commands[0..self.command_count];
            }

            /// The laid-out rectangle of the element with `element_id`, if it was declared.
            pub fn rectOf(self: *const Frame, element_id: Id) ?style.Rect {
                const index = self.lookup(element_id.hash) orelse return null;
                return .{
                    .x = self.position[index][0],
                    .y = self.position[index][1],
                    .width = self.size[index][0],
                    .height = self.size[index][1],
                };
            }

            pub fn lookup(self: *const Frame, hash: u64) ?Index {
                var slot: usize = @as(usize, @truncate(hash)) & (id_table_slots - 1);
                while (true) : (slot = (slot + 1) & (id_table_slots - 1)) {
                    const index = self.id_table[slot];
                    if (index == none_index) return null;
                    if (self.element_id[index] == hash) return index;
                }
            }

            pub fn layoutOf(self: *const Frame, index: Index) style.Layout {
                const layout_index = self.layout_index[index];
                return if (layout_index == none_index) .{} else self.layouts[layout_index];
            }

            pub fn sizingOf(self: *const Frame, index: Index, axis: style.Axis) style.Sizing {
                if (self.content_kind[index] == .text) return .fit;
                return self.layoutOf(index).sizing.axis(axis);
            }

            pub fn kindOf(self: *const Frame, index: Index) ContentKind {
                return self.content_kind[index];
            }

            fn reset(self: *Frame, viewport: [2]f32) void {
                self.element_count = 0;
                self.layout_count = 0;
                self.decoration_count = 0;
                self.text_count = 0;
                self.image_count = 0;
                self.custom_count = 0;
                self.text_bytes_used = 0;
                self.line_count = 0;
                self.command_count = 0;
                self.diagnostics = .{};
                self.viewport = viewport;
                @memset(&self.id_table, none_index);
            }
        };

        const Memory = struct {
            frames: [config.frames_in_flight]Frame,
            cache: Cache,
        };

        /// The bytes `initBuffer` needs; `init` makes one allocation of this size.
        pub const required_bytes: usize = @sizeOf(Memory);
        pub const required_alignment: usize = @alignOf(Memory);

        comptime {
            if (required_alignment > 16) @compileError("zui: Config payload types need alignment above 16, which initBuffer cannot provide");
        }

        memory: *Memory,
        owns_memory: bool,
        platform: *Platform,
        io: std.Io,

        current: ?*Frame = null,
        last_frame: ?*Frame = null,
        next_frame_slot: u8 = 0,
        open_stack: [max_depth]Index = undefined,
        depth: u16 = 0,
        dropped_depth: u32 = 0,

        /// Scratch for the emission pass, kept here so frames stay plain data.
        emit_stack: [max_depth + 1]Index = undefined,
        emit_cursor: [max_depth + 1]Index = undefined,

        pub fn init(gpa: std.mem.Allocator, io: std.Io, platform: *Platform) std.mem.Allocator.Error!Self {
            const memory = try gpa.create(Memory);
            var self: Self = .{ .memory = memory, .owns_memory = true, .platform = platform, .io = io };
            self.prepareMemory();
            return self;
        }

        pub fn initBuffer(buffer: []align(16) u8, io: std.Io, platform: *Platform) error{BufferTooSmall}!Self {
            if (buffer.len < required_bytes) return error.BufferTooSmall;
            var self: Self = .{ .memory = @ptrCast(@alignCast(buffer.ptr)), .owns_memory = false, .platform = platform, .io = io };
            self.prepareMemory();
            return self;
        }

        fn prepareMemory(self: *Self) void {
            self.memory.cache.reset();
            for (&self.memory.frames) |*frame| {
                frame.held = .init(false);
                frame.element_count = 0;
            }
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.owns_memory) gpa.destroy(self.memory);
            self.* = undefined;
        }

        // =============================================================
        // Frame lifecycle
        // =============================================================

        pub fn beginFrame(self: *Self, input: Input) void {
            if (self.current != null) @panic("zui: beginFrame() called again before endFrame()");
            const frame = self.takeFreeFrame() orelse std.debug.panic(
                "zui: all {d} frames in flight are still held; release() a frame before the next beginFrame()",
                .{config.frames_in_flight},
            );
            frame.reset(input.viewport);
            self.memory.cache.generation +%= 1;
            self.current = frame;
            self.dropped_depth = 0;
            self.depth = 0;

            const root_layout: style.Layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .width = .fixed(input.viewport[0]), .height = .fixed(input.viewport[1]) },
            };
            const root = self.appendElement(root_id, .{ .layout = root_layout }, .none, 0) orelse unreachable;
            self.open_stack[0] = root;
            self.depth = 1;
            frame.diagnostics.needed.set(.depth, 1);
        }

        fn takeFreeFrame(self: *Self) ?*Frame {
            for (0..config.frames_in_flight) |offset| {
                const slot = (self.next_frame_slot + offset) % config.frames_in_flight;
                const frame = &self.memory.frames[slot];
                if (!frame.held.load(.acquire)) {
                    self.next_frame_slot = @intCast((slot + 1) % config.frames_in_flight);
                    return frame;
                }
            }
            return null;
        }

        pub fn endFrame(self: *Self) EndFrameError!*const Frame {
            const frame = self.current orelse @panic("zui: endFrame() called without beginFrame()");
            if (self.depth != 1 or self.dropped_depth != 0) self.reportUnbalanced(frame);

            layout.run(Self, self, frame);
            emission.run(Self, self, frame);

            frame.held.store(true, .release);
            self.current = null;
            self.last_frame = frame;

            if (frame.diagnostics.unbalanced) return error.UnbalancedTree;
            if (frame.diagnostics.exceeded.count() != 0) return error.CapacityExceeded;
            return frame;
        }

        fn reportUnbalanced(self: *Self, frame: *Frame) void {
            if (std.debug.runtime_safety and self.depth > 1) {
                const innermost = self.open_stack[self.depth - 1];
                std.debug.panic("zui: endFrame() with {d} element(s) still open; the innermost is {f}", .{
                    self.depth - 1, nameOf(frame, innermost),
                });
            }
            frame.diagnostics.unbalanced = true;
            self.depth = 1;
            self.dropped_depth = 0;
        }

        /// Returns the frame's memory. Safe to call from any thread.
        pub fn release(self: *Self, frame: *const Frame) void {
            _ = self;
            const mutable: *Frame = @constCast(frame);
            mutable.held.store(false, .release);
        }

        /// The most recent frame from `endFrame`, including one that
        /// returned an error.
        pub fn lastFrame(self: *const Self) *const Frame {
            return self.last_frame orelse @panic("zui: lastFrame() before any endFrame()");
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            return self.lastFrame().diagnostics;
        }

        /// How many times the text cache has called the platform. Useful
        /// for confirming that steady-state frames hit the cache.
        pub fn measureCalls(self: *const Self) u64 {
            return self.memory.cache.platform_calls;
        }

        // =============================================================
        // Declaration
        // =============================================================

        pub fn open(self: *Self, element: ElementConfig) void {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.dropped_depth += 1;
                self.countDropped(frame, .elements);
                return;
            }
            const attempted_depth: u32 = self.depth + 1;
            if (attempted_depth > frame.diagnostics.needed.get(.depth)) frame.diagnostics.needed.set(.depth, attempted_depth);
            if (self.depth >= max_depth) {
                self.recordOverflow(frame, .depth, element.id.hash);
                self.dropped_depth = 1;
                return;
            }
            const index = self.appendElement(element.id, element, .none, 0) orelse {
                self.dropped_depth = 1;
                return;
            };
            self.open_stack[self.depth] = index;
            self.depth += 1;
        }

        pub fn close(self: *Self) void {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.dropped_depth -= 1;
                return;
            }
            if (self.depth <= 1) {
                if (std.debug.runtime_safety) @panic("zui: close() without a matching open()");
                frame.diagnostics.unbalanced = true;
                return;
            }
            self.depth -= 1;
        }

        /// A leaf element: `open` and `close` in one call.
        pub fn box(self: *Self, element: ElementConfig) void {
            _ = self.leaf(element, .none, 0);
        }

        /// A leaf showing `content`. The bytes are copied, so the caller's
        /// buffer may be reused immediately.
        pub fn text(self: *Self, content: []const u8, text_style: TextStyle) void {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.countDropped(frame, .elements);
                return;
            }
            const needed_bytes = frame.diagnostics.needed.get(.text_bytes) + @as(u32, @intCast(content.len));
            frame.diagnostics.needed.set(.text_bytes, needed_bytes);
            if (frame.text_bytes_used + content.len > config.max_text_bytes) {
                self.recordOverflow(frame, .text_bytes, 0);
                return;
            }
            const record_index = frame.text_count;
            _ = self.appendElement(.none, .{}, .text, record_index) orelse return;
            const start = frame.text_bytes_used;
            @memcpy(frame.text_bytes[start..][0..content.len], content);
            frame.text_bytes_used += @intCast(content.len);
            frame.texts[record_index] = .{
                .bytes_start = start,
                .bytes_len = @intCast(content.len),
                .style = text_style,
                .metrics = undefined,
                .first_line = 0,
                .line_count = 0,
            };
            frame.text_count += 1;
        }

        pub fn image(self: *Self, handle: config.ImageHandle, element: ElementConfig) void {
            const frame = self.declaring();
            const record_index = frame.image_count;
            if (self.leaf(element, .image, record_index)) {
                frame.images[record_index] = handle;
                frame.image_count += 1;
            }
        }

        pub fn custom(self: *Self, data: config.CustomData, element: ElementConfig) void {
            if (config.CustomData == void) @compileError("zui: custom() needs Config.CustomData set to your payload type");
            const frame = self.declaring();
            const record_index = frame.custom_count;
            if (self.leaf(element, .custom, record_index)) {
                frame.customs[record_index] = data;
                frame.custom_count += 1;
            }
        }

        fn leaf(self: *Self, element: ElementConfig, kind: ContentKind, record_index: u32) bool {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.countDropped(frame, .elements);
                return false;
            }
            return self.appendElement(element.id, element, kind, record_index) != null;
        }

        fn declaring(self: *Self) *Frame {
            return self.current orelse @panic("zui: elements can only be declared between beginFrame() and endFrame()");
        }

        fn appendElement(self: *Self, element_id: Id, element: ElementConfig, kind: ContentKind, record_index: u32) ?Index {
            const frame = self.current.?;
            frame.diagnostics.needed.set(.elements, frame.diagnostics.needed.get(.elements) + 1);
            if (frame.element_count >= max_elements) {
                self.recordOverflow(frame, .elements, element_id.hash);
                return null;
            }
            const index: Index = @intCast(frame.element_count);
            const has_parent = frame.element_count != 0;
            const parent: Index = if (has_parent) self.open_stack[self.depth - 1] else none_index;

            const hash = if (!element_id.isNone())
                element_id.hash
            else
                id_module.mix(frame.element_id[parent], frame.child_count[parent]);

            frame.element_count += 1;
            frame.element_id[index] = hash;
            frame.element_name[index] = element_id.debug_name;
            frame.parent[index] = parent;
            frame.first_child[index] = none_index;
            frame.last_child[index] = none_index;
            frame.next_sibling[index] = none_index;
            frame.child_count[index] = 0;
            frame.content_kind[index] = kind;
            frame.content_index[index] = @intCast(record_index);

            if (element.layout) |element_layout| {
                frame.layout_index[index] = @intCast(frame.layout_count);
                frame.layouts[frame.layout_count] = element_layout;
                frame.layout_count += 1;
            } else frame.layout_index[index] = none_index;

            if (element.background != null or element.border != null) {
                frame.decoration_index[index] = @intCast(frame.decoration_count);
                frame.decorations[frame.decoration_count] = .{
                    .background = element.background,
                    .corner_radius = element.corner_radius,
                    .border = element.border,
                };
                frame.decoration_count += 1;
            } else frame.decoration_index[index] = none_index;

            if (has_parent) {
                if (frame.last_child[parent] == none_index) {
                    frame.first_child[parent] = index;
                } else {
                    frame.next_sibling[frame.last_child[parent]] = index;
                }
                frame.last_child[parent] = index;
                frame.child_count[parent] += 1;
            }

            if (!element_id.isNone()) self.registerId(frame, index);
            return index;
        }

        fn registerId(self: *Self, frame: *Frame, index: Index) void {
            _ = self;
            const hash = frame.element_id[index];
            var slot: usize = @as(usize, @truncate(hash)) & (id_table_slots - 1);
            while (true) : (slot = (slot + 1) & (id_table_slots - 1)) {
                const existing = frame.id_table[slot];
                if (existing == none_index) {
                    frame.id_table[slot] = index;
                    return;
                }
                if (frame.element_id[existing] == hash) {
                    if (std.debug.runtime_safety) {
                        std.debug.panic("zui: duplicate id {f} in one frame", .{nameOf(frame, index)});
                    }
                    frame.diagnostics.duplicate_ids += 1;
                    return;
                }
            }
        }

        fn recordOverflow(self: *Self, frame: *Frame, limit: Limit, hash: u64) void {
            _ = self;
            frame.diagnostics.exceeded.insert(limit);
            if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = hash;
        }

        fn countDropped(self: *Self, frame: *Frame, limit: Limit) void {
            _ = self;
            frame.diagnostics.needed.set(limit, frame.diagnostics.needed.get(limit) + 1);
        }

        const ElementName = struct {
            frame: *const Frame,
            index: Index,

            pub fn format(self: ElementName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                const hash = self.frame.element_id[self.index];
                if (options.debug) {
                    const name = self.frame.element_name[self.index];
                    if (name.len != 0) return writer.print("\"{s}\" (0x{x:0>16})", .{ name, hash });
                }
                try writer.print("0x{x:0>16}", .{hash});
            }
        };

        fn nameOf(frame: *const Frame, index: Index) ElementName {
            return .{ .frame = frame, .index = index };
        }
    };
}

fn validateConfig(comptime config: Config) void {
    if (!std.math.isPowerOfTwo(config.state_slots)) @compileError(std.fmt.comptimePrint("zui: state_slots must be a power of two, got {d}", .{config.state_slots}));
    if (!std.math.isPowerOfTwo(config.measure_cache_entries)) @compileError(std.fmt.comptimePrint("zui: measure_cache_entries must be a power of two, got {d}", .{config.measure_cache_entries}));
    if (config.frames_in_flight < 1) @compileError("zui: frames_in_flight must be at least 1");
    if (config.max_elements < 2) @compileError("zui: max_elements must be at least 2 (zui's root plus one element)");
    if (config.max_depth < 2) @compileError("zui: max_depth must be at least 2 (zui's root plus one level)");
    if (config.max_render_commands < 1) @compileError("zui: max_render_commands must be at least 1");
    switch (@typeInfo(config.FontId)) {
        .int, .@"enum" => {},
        else => @compileError("zui: FontId must be an integer or enum type, got " ++ @typeName(config.FontId)),
    }
}

fn validatePlatform(comptime Platform: type, comptime FontId: type) void {
    if (@typeInfo(Platform) != .@"struct") @compileError("zui: Platform must be a struct type, got " ++ @typeName(Platform));
    if (!@hasDecl(Platform, "measureText")) @compileError(@typeName(Platform) ++ " does not implement zui.Platform: missing `measureText`");

    const MeasureText = fn (*Platform, []const u8, FontId, f32) [2]f32;
    if (@TypeOf(Platform.measureText) != MeasureText) {
        @compileError(@typeName(Platform) ++ ".measureText must be " ++ @typeName(MeasureText) ++ ", found " ++ @typeName(@TypeOf(Platform.measureText)));
    }
    if (@hasDecl(Platform, "scale") and @TypeOf(Platform.scale) != fn (*const Platform) f32) {
        @compileError(@typeName(Platform) ++ ".scale must be fn (*const " ++ @typeName(Platform) ++ ") f32");
    }
    if (@hasDecl(Platform, "wake") and @TypeOf(Platform.wake) != fn (*Platform) void) {
        @compileError(@typeName(Platform) ++ ".wake must be fn (*" ++ @typeName(Platform) ++ ") void");
    }
    for (@typeInfo(Platform).@"struct".decls) |declaration| {
        if (std.mem.startsWith(u8, declaration.name, "zui")) {
            @compileError(@typeName(Platform) ++ " declares `" ++ declaration.name ++ "`, which zui does not read; the optional hooks are `wake` and `scale`");
        }
    }
}
