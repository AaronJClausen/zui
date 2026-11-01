const std = @import("std");
const options = @import("zui_options");
const style = @import("style.zig");
const id_module = @import("id.zig");
const text_layout = @import("text.zig");
const command_types = @import("commands.zig");
const layout = @import("layout.zig");
const emission = @import("emission.zig");
const interaction = @import("interaction.zig");
const state_table = @import("state.zig");
const tasks = @import("tasks.zig");
const parallel_measure = @import("parallel_measure.zig");

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
    /// Persistent per-id state slots. Must be a power of two.
    state_slots: u32 = 1024,
    /// Frames a state slot survives without being touched.
    state_ttl_frames: u8 = 2,
    /// Text measurement cache entries. Must be a power of two.
    measure_cache_entries: u32 = 4096,
    /// Number of frames that can be alive at once. 2 = double buffering.
    frames_in_flight: u8 = 2,
    /// With a platform that declares `thread_safe_measure = true`: once a
    /// frame has made this many platform calls, the misses in the rest of
    /// its text are measured in parallel. A warm frame never gets here, and
    /// for a few misses spawning tasks would cost more than it saves.
    parallel_measure_threshold: u32 = 256,
    /// The most distinct misses one frame measures in parallel; the rest
    /// are measured inline.
    parallel_measure_capacity: u32 = 4096,
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
    /// Hit-tested: can be hovered, pressed and clicked.
    interactive: bool = false,
    /// Reachable with tab; implies `interactive`.
    focusable: bool = false,
    /// Tab cycles only among the focusables inside this element, e.g. a modal.
    focus_scope: bool = false,
    /// Still hit-tested, so it blocks what is beneath it, but never pressed,
    /// clicked or focused, and its widget state is `.disabled`.
    disabled: bool = false,
    clip: ?style.Clip = null,
    scroll: ?style.Scroll = null,
    floating: ?style.Floating = null,
};

pub const Input = struct {
    viewport: [2]f32,
    dt_seconds: f32 = 0,
    /// Null when the pointer is outside the surface.
    pointer: ?[2]f32 = null,
    buttons: std.EnumSet(interaction.Button) = .initEmpty(),
    /// In layout units; positive scrolls toward the end of the content.
    wheel: [2]f32 = .{ 0, 0 },
    /// This frame's key presses, in order. Copied; only needs to live
    /// until `beginFrame` returns.
    keys_pressed: []const interaction.Key = &.{},
    modifiers: interaction.Modifiers = .{},
    /// UTF-8 typed this frame. Copied, like `keys_pressed`.
    text_input: []const u8 = "",
};

pub const Limit = enum {
    elements,
    text_bytes,
    depth,
    render_commands,
    state_slots,

    /// The `Config` field that raises this limit.
    pub fn configField(self: Limit) []const u8 {
        return switch (self) {
            .elements => "max_elements",
            .text_bytes => "max_text_bytes",
            .depth => "max_depth",
            .render_commands => "max_render_commands",
            .state_slots => "state_slots",
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

const ContentKind = enum(u8) { none, text, image, custom };

pub const ElementFlags = packed struct(u16) {
    explicit_id: bool = false,
    interactive: bool = false,
    focusable: bool = false,
    focus_scope: bool = false,
    disabled: bool = false,
    clip_x: bool = false,
    clip_y: bool = false,
    scroll_x: bool = false,
    scroll_y: bool = false,
    top_to_bottom: bool = false,
    floating: bool = false,
    _: u5 = 0,

    pub fn clips(self: ElementFlags) bool {
        return self.clip_x or self.clip_y;
    }

    /// Any flag that makes emission record the element: everything but
    /// the layout direction.
    pub fn emits(self: ElementFlags) bool {
        var without_direction = self;
        without_direction.top_to_bottom = false;
        return @as(u16, @bitCast(without_direction)) != 0;
    }

    pub fn scrolls(self: ElementFlags, axis: style.Axis) bool {
        return if (axis == .x) self.scroll_x else self.scroll_y;
    }
};

const default_layout: style.Layout = .{};

fn nextPowerOfTwo(value: u32) u32 {
    return std.math.ceilPowerOfTwoAssert(u32, @max(value, 2));
}

pub fn Context(comptime config: Config, comptime Platform: type) type {
    comptime validateConfig(config);
    comptime validatePlatform(Platform, config.FontId);

    return struct {
        const Self = @This();

        pub const FontId = config.FontId;
        pub const TextStyle = style.TextStyle(config.FontId);
        pub const RenderCommand = command_types.RenderCommand(TextStyle, config.ImageHandle, config.CustomData);
        /// Rounded up to a whole number of bytes: a `u13` is stored in 16
        /// bits anyway, and every load of one would be masked.
        pub const Index = std.meta.Int(.unsigned, std.math.ceilPowerOfTwoAssert(u16, @max(8, @bitSizeOf(std.math.IntFittingRange(0, config.max_elements)))));
        pub const none_index: Index = config.max_elements;
        pub const root_index: Index = 0;
        pub const root_id: Id = .of("zui.root");
        pub const max_elements = config.max_elements;
        pub const max_depth = config.max_depth;
        const id_table_slots = nextPowerOfTwo(config.max_elements * 2);
        const IdTableSlot = std.meta.Int(.unsigned, std.math.ceilPowerOfTwoAssert(u16, @max(8, @bitSizeOf(std.math.IntFittingRange(0, id_table_slots - 1)))));
        pub const snaps_to_pixels = @hasDecl(Platform, "scale");

        pub const Cache = text_layout.MeasureCache(config.FontId, config.measure_cache_entries, Platform);
        pub const measures_in_parallel = @hasDecl(Platform, "thread_safe_measure") and Platform.thread_safe_measure;
        pub const parallel_measure_threshold = config.parallel_measure_threshold;
        const MeasureBatch = if (measures_in_parallel) parallel_measure.MeasureBatch(config.FontId, Platform, config.parallel_measure_capacity) else void;
        pub const States = state_table.StateTable(config.state_slots);
        pub const Results = interaction.Results(config.max_elements, id_table_slots);
        const InteractionState = interaction.State(config.max_depth + 1);

        pub const Decoration = struct {
            background: ?style.Color,
            corner_radius: style.CornerRadius,
            border: ?style.Border,
        };

        pub const TextRecord = struct {
            element: Index,
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
            child_count: [max_elements]Index,
            /// Children that take part in the flow: `child_count` minus floating ones.
            flow_child_count: [max_elements]Index,
            layout_index: [max_elements]Index,
            decoration_index: [max_elements]Index,
            content_kind: [max_elements]ContentKind,
            content_index: [max_elements]Index,
            size: [max_elements][2]f32,
            min_size: [max_elements][2]f32,
            position: [max_elements][2]f32,
            flags: [max_elements]ElementFlags,
            /// One past the last element of this element's subtree, which is
            /// also its next sibling, if it has one.
            subtree_end: [max_elements]Index,
            /// Index into `floatings`, or `none_index`.
            floating_index: [max_elements]Index,
            /// The extent of an element's children plus padding, for scrolling.
            content_size: [max_elements][2]f32,

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
            floatings: [max_elements]style.Floating,
            floating_count: u32,

            text_bytes: [config.max_text_bytes]u8,
            text_bytes_used: u32,
            lines: [config.max_render_commands]text_layout.Line,
            line_count: u32,
            render_commands: [config.max_render_commands]RenderCommand,
            command_count: u32,

            id_table: [id_table_slots]Index,
            /// The `id_table` slots this frame filled, so the next `reset`
            /// clears only those instead of the whole table.
            filled_id_slots: [max_elements]IdTableSlot,
            filled_id_slot_count: u32,
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

            /// Elements are stored in declaration order, so a parent's first
            /// child is the element after it, and each child's next sibling
            /// is the element after the child's own subtree.
            pub fn children(self: *const Frame, parent: Index) Children {
                return .{ .frame = self, .next_child = parent + 1, .end = self.subtree_end[parent] };
            }

            pub const Children = struct {
                frame: *const Frame,
                next_child: Index,
                end: Index,

                pub fn next(self: *Children) ?Index {
                    if (self.next_child >= self.end) return null;
                    const child = self.next_child;
                    self.next_child = self.frame.subtree_end[child];
                    return child;
                }
            };

            pub fn lookup(self: *const Frame, hash: u64) ?Index {
                var slot: usize = @as(usize, @truncate(hash)) & (id_table_slots - 1);
                while (true) : (slot = (slot + 1) & (id_table_slots - 1)) {
                    const index = self.id_table[slot];
                    if (index == none_index) return null;
                    if (self.element_id[index] == hash) return index;
                }
            }

            pub fn layoutOf(self: *const Frame, index: Index) *const style.Layout {
                const layout_index = self.layout_index[index];
                return if (layout_index == none_index) &default_layout else &self.layouts[layout_index];
            }

            /// Text elements never have a layout, so they are `.fit` here too.
            pub fn sizingOf(self: *const Frame, index: Index, comptime axis: style.Axis) style.Sizing {
                const layout_index = self.layout_index[index];
                if (layout_index == none_index) return .fit;
                const sizing = &self.layouts[layout_index].sizing;
                return if (axis == .x) sizing.width else sizing.height;
            }

            pub fn kindOf(self: *const Frame, index: Index) ContentKind {
                return self.content_kind[index];
            }

            pub fn isFloating(self: *const Frame, index: Index) bool {
                return self.flags[index].floating;
            }

            pub fn floatingOf(self: *const Frame, index: Index) style.Floating {
                return self.floatings[self.floating_index[index]];
            }

            fn reset(self: *Frame, frame_viewport: [2]f32) void {
                self.element_count = 0;
                self.layout_count = 0;
                self.decoration_count = 0;
                self.text_count = 0;
                self.image_count = 0;
                self.custom_count = 0;
                self.floating_count = 0;
                self.text_bytes_used = 0;
                self.line_count = 0;
                self.command_count = 0;
                self.diagnostics = .{};
                self.viewport = frame_viewport;
                for (self.filled_id_slots[0..self.filled_id_slot_count]) |slot| self.id_table[slot] = none_index;
                self.filled_id_slot_count = 0;
            }
        };

        const Memory = struct {
            frames: [config.frames_in_flight]Frame,
            cache: Cache,
            measure_batch: MeasureBatch,
            child_placements: [config.max_elements]layout.ChildPlacement,
            /// Scratch shared by every frame: the width of each word or
            /// paragraph measured in the current `endFrame`.
            run_widths: [text_layout.maxRuns(config.max_text_bytes, config.max_elements)]f32,
            states: States,
            results: Results,
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
        emit_levels: [max_depth + 1]emission.EmitLevel(Index) = undefined,

        input_state: InteractionState = .{},

        /// Set by `release` from any thread; `beginFrame` waits on it when
        /// every frame is still held by a renderer.
        frame_released: std.Io.Event = .unset,
        /// Set by task threads when a task completes (see `needsFrame`).
        task_completed: std.atomic.Value(bool) = .init(false),
        task_pools: ?*tasks.Registration = null,
        interaction_changed: bool = true,
        frame_requested: bool = false,

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
            if (measures_in_parallel) self.memory.measure_batch.clearAll();
            self.memory.states.reset();
            self.memory.results.reset();
            for (&self.memory.frames) |*frame| {
                frame.held = .init(false);
                frame.element_count = 0;
                @memset(&frame.id_table, none_index);
                frame.filled_id_slot_count = 0;
            }
        }

        /// Cancels the tasks of every registered TaskPool, then frees memory.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            while (self.task_pools) |registration| {
                registration.cancel_all(registration);
                self.task_pools = registration.next;
            }
            if (self.owns_memory) gpa.destroy(self.memory);
            self.* = undefined;
        }

        // =============================================================
        // Frame lifecycle
        // =============================================================

        pub fn beginFrame(self: *Self, input: Input) void {
            if (self.current != null) @panic("zui: beginFrame() called again before endFrame()");
            const frame = self.waitForFreeFrame();
            frame.reset(input.viewport);
            self.task_completed.store(false, .release);
            self.frame_requested = false;
            self.memory.cache.generation +%= 1;
            self.resolveInput(input);
            self.memory.states.evict(self.input_state.frame_number, config.state_ttl_frames);
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

        /// Blocks until a renderer releases a frame. Resetting the event
        /// before the second check closes the race with a `release` that
        /// lands between the check and the wait.
        fn waitForFreeFrame(self: *Self) *Frame {
            while (true) {
                if (self.takeFreeFrame()) |frame| return frame;
                self.frame_released.reset();
                if (self.takeFreeFrame()) |frame| return frame;
                self.frame_released.waitUncancelable(self.io);
            }
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
            frame.subtree_end[root_index] = @intCast(frame.element_count);

            layout.run(Self, self, frame);
            @call(.never_inline, emission.run, .{ Self, self, frame });

            const results = &self.memory.results;
            results.has_frame = true;
            if (self.input_state.focus != 0 and !results.isFocusable(self.input_state.focus)) self.input_state.focus = 0;

            var registration = self.task_pools;
            while (registration) |pool| : (registration = pool.next) pool.sweep(pool, self.input_state.frame_number);

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
            for (self.open_stack[1..self.depth]) |still_open| frame.subtree_end[still_open] = @intCast(frame.element_count);
            self.depth = 1;
            self.dropped_depth = 0;
        }

        /// Returns the frame's memory. Safe to call from any thread.
        pub fn release(self: *Self, frame: *const Frame) void {
            const mutable: *Frame = @constCast(frame);
            mutable.held.store(false, .release);
            self.frame_released.set(self.io);
        }

        /// Whether the frame just drawn may be out of date, so the event loop
        /// should run another one instead of waiting for input:
        /// - the last input changed interaction state (hover, press, focus,
        ///   a click, keys, typed text, or a scroll that moved);
        /// - a task completed;
        /// - `requestFrame` was called.
        /// When it is false, an event loop can sleep until the next input or
        /// `Platform.wake`, and an idle application uses no CPU.
        pub fn needsFrame(self: *const Self) bool {
            return self.interaction_changed or self.frame_requested or self.task_completed.load(.acquire);
        }

        /// Asks for one more frame, e.g. while an animation runs.
        pub fn requestFrame(self: *Self) void {
            self.frame_requested = true;
        }

        // =============================================================
        // Task pools (SPEC.md §10.3)
        // =============================================================

        pub fn waker(self: *Self) tasks.Waker {
            return .{
                .task_completed = &self.task_completed,
                .platform = @ptrCast(self.platform),
                .wake = if (@hasDecl(Platform, "wake")) wakePlatform else null,
            };
        }

        fn wakePlatform(platform: *anyopaque) void {
            const typed: *Platform = @ptrCast(@alignCast(platform));
            typed.wake();
        }

        pub fn registerTaskPool(self: *Self, registration: *tasks.Registration) void {
            registration.next = self.task_pools;
            self.task_pools = registration;
        }

        pub fn unregisterTaskPool(self: *Self, registration: *tasks.Registration) void {
            var link = &self.task_pools;
            while (link.*) |current| : (link = &current.next) {
                if (current == registration) {
                    link.* = current.next;
                    return;
                }
            }
        }

        /// The most recent frame from `endFrame`, including one that
        /// returned an error.
        pub fn lastFrame(self: *const Self) *const Frame {
            return self.last_frame orelse @panic("zui: lastFrame() before any endFrame()");
        }

        pub fn diagnostics(self: *const Self) Diagnostics {
            return self.lastFrame().diagnostics;
        }

        /// The size the platform measures for `content`, through the
        /// measurement cache. For widgets that place a caret or map a
        /// pointer position to a character.
        pub fn measureText(self: *Self, content: []const u8, font: FontId, size: f32) [2]f32 {
            return self.memory.cache.measure(self.platform, content, font, size);
        }

        /// The current frame's viewport, as given to `beginFrame`.
        pub fn viewport(self: *const Self) [2]f32 {
            const frame = self.current orelse @panic("zui: viewport() is only known between beginFrame() and endFrame()");
            return frame.viewport;
        }

        /// How many times the text cache has called the platform. Useful
        /// for confirming that steady-state frames hit the cache.
        pub fn measureCalls(self: *const Self) u64 {
            return self.memory.cache.platform_calls;
        }

        // =============================================================
        // Declaration
        // =============================================================

        pub inline fn open(self: *Self, element: ElementConfig) void {
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
            frame.subtree_end[self.open_stack[self.depth]] = @intCast(frame.element_count);
        }

        /// A leaf element: `open` and `close` in one call.
        pub inline fn box(self: *Self, element: ElementConfig) void {
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
            const element_index = self.appendElement(.none, .{}, .text, record_index) orelse return;
            const start = frame.text_bytes_used;
            @memcpy(frame.text_bytes[start..][0..content.len], content);
            frame.text_bytes_used += @intCast(content.len);
            frame.texts[record_index] = .{
                .element = element_index,
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

        inline fn leaf(self: *Self, element: ElementConfig, kind: ContentKind, record_index: u32) bool {
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

        /// `inline`, like `open`, `box` and `leaf`, so each call site is
        /// specialized to its config literal: the fields left at their
        /// defaults cost nothing, and the 168-byte `ElementConfig` is never
        /// copied. Out of line, declaration was about 35% slower.
        inline fn appendElement(self: *Self, element_id: Id, element: ElementConfig, kind: ContentKind, record_index: u32) ?Index {
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
            frame.child_count[index] = 0;
            frame.size[index] = .{ 0, 0 };
            frame.min_size[index] = .{ 0, 0 };
            frame.flow_child_count[index] = 0;
            frame.content_kind[index] = kind;
            frame.content_index[index] = @intCast(record_index);
            frame.subtree_end[index] = index + 1;
            frame.flags[index] = self.flagsFor(element_id, element);

            if (element.floating) |floating| {
                frame.floating_index[index] = @intCast(frame.floating_count);
                frame.floatings[frame.floating_count] = floating;
                frame.floating_count += 1;
            } else {
                frame.floating_index[index] = none_index;
            }

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
                frame.child_count[parent] += 1;
                if (element.floating == null) frame.flow_child_count[parent] += 1;
            }

            if (!element_id.isNone() and !self.registerId(frame, index)) {
                frame.flags[index].interactive = false;
                frame.flags[index].focusable = false;
                frame.flags[index].scroll_x = false;
                frame.flags[index].scroll_y = false;
            }
            return index;
        }

        fn flagsFor(self: *Self, element_id: Id, element: ElementConfig) ElementFlags {
            _ = self;
            var flags: ElementFlags = .{
                .explicit_id = !element_id.isNone(),
                .interactive = element.interactive or element.focusable,
                .focusable = element.focusable,
                .focus_scope = element.focus_scope,
                .disabled = element.disabled,
                .top_to_bottom = if (element.layout) |element_layout| element_layout.direction == .top_to_bottom else false,
                .floating = element.floating != null,
            };
            if (element.clip) |clip| {
                flags.clip_x = clip.horizontal;
                flags.clip_y = clip.vertical;
            }
            if (element.scroll) |scroll| {
                if (element_id.isNone()) {
                    if (std.debug.runtime_safety) @panic("zui: a scroll container needs an id, because its offset is stored by id");
                } else {
                    flags.scroll_x = scroll.horizontal;
                    flags.scroll_y = scroll.vertical;
                }
                flags.clip_x = flags.clip_x or scroll.horizontal;
                flags.clip_y = flags.clip_y or scroll.vertical;
            }
            return flags;
        }

        /// Returns false for a duplicate, which in release builds becomes
        /// non-interactive (safe builds panic).
        fn registerId(self: *Self, frame: *Frame, index: Index) bool {
            _ = self;
            const hash = frame.element_id[index];
            var slot: usize = @as(usize, @truncate(hash)) & (id_table_slots - 1);
            while (true) : (slot = (slot + 1) & (id_table_slots - 1)) {
                const existing = frame.id_table[slot];
                if (existing == none_index) {
                    frame.id_table[slot] = index;
                    frame.filled_id_slots[frame.filled_id_slot_count] = @intCast(slot);
                    frame.filled_id_slot_count += 1;
                    return true;
                }
                if (frame.element_id[existing] == hash) {
                    if (std.debug.runtime_safety) {
                        std.debug.panic("zui: duplicate id {f} in one frame", .{nameOf(frame, index)});
                    }
                    frame.diagnostics.duplicate_ids += 1;
                    return false;
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

        // =============================================================
        // Interaction (answers describe the previous frame, SPEC.md §5)
        // =============================================================

        fn resolveInput(self: *Self, input: Input) void {
            const it = &self.input_state;
            const results = &self.memory.results;
            const was_down = it.buttons.contains(.primary);
            const previous_hover = hoverSignature(it);
            const previous_press = it.press_target;
            const previous_focus = it.focus;
            var scrolled = false;
            it.frame_number +%= 1;
            it.pointer = input.pointer;
            it.buttons = input.buttons;
            it.modifiers = input.modifiers;
            it.key_count = @intCast(@min(input.keys_pressed.len, interaction.max_keys_per_frame));
            @memcpy(it.keys[0..it.key_count], input.keys_pressed[0..it.key_count]);
            it.text_len = @intCast(@min(input.text_input.len, interaction.max_text_input_bytes));
            @memcpy(it.text[0..it.text_len], input.text_input[0..it.text_len]);
            it.clicked = 0;
            if (it.pending_focus) |requested| {
                // Checked here as well as at endFrame, so a disabled element
                // is never focused for long enough to be activated by Enter.
                if (results.isFocusable(requested)) it.focus = requested;
                it.pending_focus = null;
            }

            var scroll_chain: [config.max_depth + 1]u32 = undefined;
            var scroll_count: usize = 0;
            it.hover_count = 0;
            var hot_region: ?u32 = null;
            if (results.has_frame) if (input.pointer) |point| if (results.topmostAt(point)) |top| {
                var region_index = top;
                while (region_index != interaction.no_region) : (region_index = results.regions[region_index].parent) {
                    const region = results.regions[region_index];
                    if (!region.bounds.contains(point)) continue;
                    if (region.flags.interactive and it.hover_count < it.hover_chain.len) {
                        if (hot_region == null) hot_region = region_index;
                        it.hover_chain[it.hover_count] = region.hash;
                        it.hover_count += 1;
                    }
                    if ((region.flags.scroll_x or region.flags.scroll_y) and scroll_count < scroll_chain.len) {
                        scroll_chain[scroll_count] = region_index;
                        scroll_count += 1;
                    }
                }
            };

            const is_down = it.buttons.contains(.primary);
            if (is_down and !was_down) {
                it.press_target = 0;
                it.focus = 0;
                if (hot_region) |index| {
                    const region = results.regions[index];
                    if (!region.flags.disabled) {
                        it.press_target = region.hash;
                        if (region.flags.focusable) it.focus = region.hash;
                    }
                }
            } else if (!is_down and was_down) {
                if (it.press_target != 0 and hot_region != null and results.regions[hot_region.?].hash == it.press_target) it.clicked = it.press_target;
                it.press_target = 0;
            } else if (!is_down) {
                it.press_target = 0;
            }

            for (it.keys[0..it.key_count]) |key| switch (key) {
                .tab => it.focus = results.nextFocus(it.focus, !it.modifiers.shift),
                .enter, .space => if (it.focus != 0) {
                    it.clicked = it.focus;
                },
                else => {},
            };

            for (0..2) |axis| {
                if (input.wheel[axis] == 0) continue;
                for (scroll_chain[0..scroll_count]) |region_index| {
                    const region = results.regions[region_index];
                    if (!region.flags.scrolls(axis)) continue;
                    const scroll = self.memory.states.get(region.hash, interaction.ScrollState, it.frame_number, .create) orelse break;
                    const moved = std.math.clamp(scroll.offset[axis] + input.wheel[axis], 0, region.max_scroll[axis]);
                    if (moved != scroll.offset[axis]) {
                        scroll.offset[axis] = moved;
                        scrolled = true;
                        break;
                    }
                }
            }

            self.interaction_changed = scrolled or it.clicked != 0 or it.key_count != 0 or it.text_len != 0 or
                it.press_target != previous_press or it.focus != previous_focus or hoverSignature(it) != previous_hover;
        }

        fn hoverSignature(it: *const InteractionState) u64 {
            var signature: u64 = it.hover_count;
            for (it.hover_chain[0..it.hover_count]) |hash| signature = id_module.mix(signature, hash);
            return signature;
        }

        /// True for the topmost interactive element under the pointer and for
        /// each interactive ancestor that also contains the pointer.
        pub fn hovered(self: *const Self, element_id: Id) bool {
            return self.input_state.isHovered(element_id.hash);
        }

        /// The primary button is held and the press began on this element.
        pub fn pressed(self: *const Self, element_id: Id) bool {
            return self.input_state.press_target == element_id.hash and self.input_state.buttons.contains(.primary);
        }

        /// The primary button was released over the element it was pressed
        /// on, or the element is focused and Enter or Space was pressed.
        pub fn clicked(self: *const Self, element_id: Id) bool {
            return self.input_state.clicked == element_id.hash and !element_id.isNone();
        }

        pub fn focused(self: *const Self, element_id: Id) bool {
            return self.input_state.focus == element_id.hash and !element_id.isNone();
        }

        /// Focus moves to `element_id` at the start of the next frame.
        pub fn requestFocus(self: *Self, element_id: Id) void {
            self.input_state.pending_focus = element_id.hash;
        }

        pub fn widgetState(self: *const Self, element_id: Id) interaction.WidgetState {
            if (self.memory.results.regionFlags(element_id.hash).disabled) return .disabled;
            if (self.pressed(element_id)) return .pressed;
            if (self.hovered(element_id)) return .hovered;
            if (self.focused(element_id)) return .focused;
            return .idle;
        }

        /// The element's rectangle in the previous frame.
        pub fn rectOf(self: *const Self, element_id: Id) ?style.Rect {
            const entry = self.memory.results.find(element_id.hash) orelse return null;
            return entry.rect;
        }

        /// The pointer relative to the element's top-left corner in the previous frame.
        pub fn pointerLocal(self: *const Self, element_id: Id) ?[2]f32 {
            const point = self.input_state.pointer orelse return null;
            const rect = self.rectOf(element_id) orelse return null;
            return .{ point[0] - rect.x, point[1] - rect.y };
        }

        pub fn pointer(self: *const Self) ?[2]f32 {
            return self.input_state.pointer;
        }

        pub fn keyPressed(self: *const Self, key: interaction.Key) bool {
            return self.input_state.keyPressed(key);
        }

        /// This frame's key presses in the order they happened, for
        /// widgets where order matters (Home then Right is not Right then Home).
        pub fn keysPressed(self: *const Self) []const interaction.Key {
            return self.input_state.keys[0..self.input_state.key_count];
        }

        pub fn modifiers(self: *const Self) interaction.Modifiers {
            return self.input_state.modifiers;
        }

        /// Text typed this frame, truncated to `interaction.max_text_input_bytes`.
        pub fn typedText(self: *const Self) []const u8 {
            return self.input_state.text[0..self.input_state.text_len];
        }

        // =============================================================
        // Persistent state (SPEC.md §9)
        // =============================================================

        /// State for `element_id` that survives across frames while the id
        /// keeps being used. Created zeroed. If the table is full, returns
        /// zeroed scratch memory and reports `.state_slots`.
        pub fn state(self: *Self, element_id: Id, comptime T: type) *T {
            if (self.memory.states.get(element_id.hash, T, self.input_state.frame_number, .create)) |slot| return slot;
            if (self.current) |frame| {
                frame.diagnostics.exceeded.insert(.state_slots);
                frame.diagnostics.needed.set(.state_slots, config.state_slots + 1);
            }
            return self.memory.states.scratch(T);
        }

        pub fn stateIfPresent(self: *Self, element_id: Id, comptime T: type) ?*T {
            return self.memory.states.get(element_id.hash, T, self.input_state.frame_number, .existing_only);
        }

        pub fn scrollOffset(self: *Self, element_id: Id) [2]f32 {
            const scroll = self.stateIfPresent(element_id, interaction.ScrollState) orelse return .{ 0, 0 };
            return scroll.offset;
        }

        /// Clamped to the content at the next layout.
        pub fn setScrollOffset(self: *Self, element_id: Id, offset: [2]f32) void {
            self.state(element_id, interaction.ScrollState).offset = offset;
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
    if (@hasDecl(Platform, "thread_safe_measure") and @TypeOf(Platform.thread_safe_measure) != bool) {
        @compileError(@typeName(Platform) ++ ".thread_safe_measure must be a bool, found " ++ @typeName(@TypeOf(Platform.thread_safe_measure)));
    }
    for (@typeInfo(Platform).@"struct".decls) |declaration| {
        if (std.mem.startsWith(u8, declaration.name, "zui")) {
            @compileError(@typeName(Platform) ++ " declares `" ++ declaration.name ++ "`, which zui does not read; the optional declarations are `wake`, `scale` and `thread_safe_measure`");
        }
    }
}
