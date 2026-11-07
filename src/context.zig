const std = @import("std");
const options = @import("zui_options");
const style = @import("style.zig");
const id_module = @import("id.zig");
const text_layout = @import("text.zig");
const command_types = @import("commands.zig");
const layout = @import("layout.zig");
const emission = @import("emission.zig");
const interaction = @import("interaction.zig");
const input = @import("input.zig");
const record_types = @import("record.zig");
const state_table = @import("state.zig");
const parallel_measure = @import("parallel_measure.zig");
const contracts = @import("contracts.zig");
const trace = @import("trace.zig");
const sources_module = @import("sources.zig");

const Id = id_module.Id;
const Instant = record_types.Instant;
const NextFrame = record_types.NextFrame;
const HostRequests = record_types.HostRequests;
const Cursor = record_types.Cursor;
const Environment = input.Environment;

pub const Config = struct {
    limits: Limits = .{},

    /// The text contract: a type with `zuiMeasure`. `void` removes `text`
    /// from the API.
    Text: type = void,
    /// The application's sources: a struct whose every field implements
    /// the source contract, swapped in field order at each `beginFrame`.
    /// `void` removes the `sources` parameter and `source` from the API.
    Sources: type = void,
    /// The optional commands the renderer draws, its `zui_commands`; only
    /// these are variants of `RenderCommand`'s payload.
    commands: command_types.CommandSet = .initEmpty(),

    /// The renderer's image, e.g. a texture id. `void` removes `image`,
    /// from the API and from the commands.
    ImageHandle: type = void,
    /// What a self-drawn element carries, e.g. a 3D viewport's camera.
    /// `void` removes `custom`, from the API and from the commands.
    CustomData: type = void,
    /// The renderer's shader or material, for the `material` command.
    MaterialHandle: type = void,
    /// The renderer's font identifier, passed back in `MeasureKey`. An
    /// integer or enum type.
    FontId: type = u16,

    features: Features = .{},
    /// Frames alive at once: one being declared plus those a renderer holds.
    frames_in_flight: u8 = 2,
};

/// What a context can do beyond layout and input. A feature that is off
/// generates no code and no memory, and calling its API is a compile error
/// naming the field to set.
pub const Features = struct {
    /// The accessibility tree, `Frame.semantics()`.
    semantics: bool = false,
    /// Recognizing what pointers do to an element, `manipulation`.
    gestures: bool = true,
    /// Moving a row's children that overflow it onto new lines.
    flex_wrap: bool = false,
    /// The invariant checks that read only a `Frame`, at the end of every
    /// `endFrame`, in any build.
    safety_sweeps: bool = std.debug.runtime_safety,
    /// The tracer contract: a type with `zuiBegin` and `zuiEnd`, which
    /// sees each step of `beginFrame` and `endFrame` as a zone. `void`
    /// compiles tracing out.
    Tracer: type = void,
};

pub const Limits = struct {
    /// Declared per frame, including zui's root.
    max_elements: u32 = 4096,
    /// Nesting of `open` inside `open`, including zui's root.
    max_depth: u16 = 64,
    /// UTF-8 bytes of all `text` content per frame.
    max_text_bytes: u32 = 64 * 1024,
    /// Per frame. Each wrapped line of text is one.
    max_render_commands: u32 = 8192,
    /// Persistent `(id, type)` entries. A power of two.
    state_slots: u32 = 1024,
    /// Counted from the last frame its element was declared.
    state_frames_until_eviction: u8 = 2,
    /// The segment cache. A power of two.
    measure_cache_entries: u32 = 4096,
    /// The whole-string cache. A power of two.
    string_cache_entries: u32 = 1024,
    /// Fingers, pens and mice touching or hovering at once.
    max_input_contacts: u8 = 10,
    /// Input events kept from one record.
    max_events_per_frame: u16 = 256,
    /// Typed text kept from one record.
    max_text_input_bytes: u16 = 256,
    /// Paths of dropped files kept from one record, each with a 0 byte
    /// after it. 0 keeps no drops.
    max_dropped_path_bytes: u32 = 4096,
    /// Calls to the text contract in one frame before the rest of its
    /// misses are measured in parallel. A warm frame never gets here, and
    /// for a few misses spawning tasks would cost more than it saves.
    parallel_measure_threshold: u32 = 256,
    /// Distinct misses one cold frame can batch; the rest are measured inline.
    parallel_measure_capacity: u32 = 4096,
};

/// Names a limit by its `Limits` field, so a diagnostic can never name a
/// field that does not exist.
pub const Limit = std.meta.FieldEnum(Limits);

pub const Diagnostics = struct {
    exceeded: std.EnumSet(Limit) = .initEmpty(),
    /// What the frame asked for, per limit, including what was dropped.
    needed: std.EnumArray(Limit, u32) = .initFill(0),
    /// The first element dropped because a limit was reached.
    first_dropped_id: u64 = 0,
    duplicate_ids: u32 = 0,
    unbalanced: bool = false,
    /// Publishes that full sources refused since their previous swap,
    /// summed over every source. Each refused item stayed its producer's.
    refused_publishes: u32 = 0,
    /// The `Sources` field that refused first, e.g. "quotes": the one
    /// whose capacity to raise. Empty when none refused.
    first_refusing_source: []const u8 = "",

    pub fn ok(self: Diagnostics) bool {
        return self.exceeded.count() == 0 and self.duplicate_ids == 0 and !self.unbalanced and self.refused_publishes == 0;
    }

    /// For applications that would rather stop than draw what fit.
    ///
    /// ```zig
    /// const frame = ui.endFrame();
    /// try frame.diagnostics.check();
    /// ```
    pub fn check(self: Diagnostics) error{ CapacityExceeded, UnbalancedTree }!void {
        if (self.exceeded.count() != 0 or self.refused_publishes != 0) return error.CapacityExceeded;
        if (self.unbalanced) return error.UnbalancedTree;
    }

    fn addRefusals(self: *Diagnostics, source_name: []const u8, refused: u32) void {
        if (self.refused_publishes == 0) self.first_refusing_source = source_name;
        self.refused_publishes +|= refused;
    }
};

pub const Element = struct {
    /// Needed for queries, state, scrolling and focus.
    id: Id = .none,
    /// Made at comptime with `zui.static` and referenced, not copied.
    /// `layout` and `decoration` set here replace the style's.
    style: ?style.Static(style.Style) = null,
    layout: ?style.Layout = null,
    decoration: ?style.Decoration = null,
    /// The axes on which descendants are cut off.
    clip: style.Axes = .none,
    scroll: ?style.Scroll = null,
    floating: ?style.Floating = null,
    /// Takes hover, press and click, and blocks them below it.
    ///
    /// This and the three switches after it are `?bool`, null meaning
    /// false, because Zig stores a `bool` field as one bit and loads it as
    /// a byte: LLVM cannot see through that, so every `open` stored and
    /// reloaded the four defaults. An optional's defaults fold away. They
    /// are written as booleans:
    ///
    /// ```zig
    /// ui.open(.{ .id = .of("save"), .focusable = true, .disabled = !app.dirty });
    /// ```
    interactive: ?bool = null,
    /// Reachable with Tab; implies `interactive`.
    focusable: ?bool = null,
    /// Tab cycles inside this subtree, as in a dialog.
    focus_scope: ?bool = null,
    /// Still hit-tested, so it blocks what is beneath it, but never pressed,
    /// clicked or focused, and its widget state is `.disabled`.
    disabled: ?bool = null,
    /// The pointer's shape while this element is the innermost one under
    /// the hovering pointer that sets a cursor. Only an interactive
    /// element is hit-tested, so on any other this has no effect.
    cursor: ?Cursor = null,
};

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

fn nextPowerOfTwo(value: u32) u32 {
    return std.math.ceilPowerOfTwoAssert(u32, @max(value, 2));
}

pub fn Context(comptime config: Config) type {
    comptime validateConfig(config);
    if (config.Text != void) comptime contracts.checkText(config.Text, config.FontId);
    if (config.features.Tracer != void) comptime contracts.checkTracer(config.features.Tracer);
    if (config.Sources != void) comptime contracts.checkSources(config.Sources);

    return struct {
        const Self = @This();

        pub const limits = config.limits;
        pub const features = config.features;
        /// Frames alive at once; a render thread can hold all but one.
        pub const frames_in_flight = config.frames_in_flight;
        /// The text contract, or `void`.
        pub const Text = config.Text;
        pub const has_sources = config.Sources != void;
        pub const Sources = config.Sources;
        /// Names a source in `source` and `framesSinceRead`: `.quotes`.
        pub const SourceField = if (has_sources) std.meta.FieldEnum(Sources) else enum {};
        const source_count = @typeInfo(SourceField).@"enum".fields.len;
        /// What each source received at one `beginFrame`, for replay.
        pub const Deliveries = if (has_sources) sources_module.Deliveries(Sources) else void;
        /// What `beginFrame` takes: with `deliveries` when there are sources.
        pub const FrameRecord = if (has_sources) record_types.FrameRecordWith(Deliveries) else record_types.FrameRecord;
        /// A listener for `relayTo`.
        pub const Relay = record_types.Relay(FrameRecord);

        /// The read-only handle `source(field)` returns.
        pub fn SourceView(comptime field: SourceField) type {
            return @FieldType(Sources, @tagName(field)).View;
        }
        pub const Tracing = trace.Tracing(config.features.Tracer);
        pub const has_text = config.Text != void;
        pub const FontId = config.FontId;
        pub const TextStyle = style.TextStyle(config.FontId);
        pub const MeasureKey = style.MeasureKey(config.FontId);
        /// Generated from `config.commands` and the payload types: a
        /// renderer's exhaustive `switch` over `payload` covers exactly what
        /// it draws.
        pub const RenderCommand = command_types.RenderCommand(.{
            .TextStyle = TextStyle,
            .ImageHandle = config.ImageHandle,
            .CustomData = config.CustomData,
            .MaterialHandle = config.MaterialHandle,
            .commands = config.commands,
        });
        pub const Image = RenderCommand.Image;
        /// Rounded up to a whole number of bytes: a `u13` is stored in 16
        /// bits anyway, and every load of one would be masked.
        pub const Index = std.meta.Int(.unsigned, std.math.ceilPowerOfTwoAssert(u16, @max(8, @bitSizeOf(std.math.IntFittingRange(0, limits.max_elements)))));
        pub const none_index: Index = limits.max_elements;
        pub const root_index: Index = 0;
        /// Side by side, so declaration zeroes both in one store and counts
        /// a flow child in one addition.
        pub const ChildCounts = extern struct {
            all: Index align(@sizeOf(BothCounts)),
            /// Children that take part in the flow: `all` minus floating ones.
            in_flow: Index,

            const BothCounts = std.meta.Int(.unsigned, 2 * @bitSizeOf(Index));
            const none: ChildCounts = .{ .all = 0, .in_flow = 0 };

            inline fn count(self: *ChildCounts, comptime floating: bool) void {
                if (floating) {
                    self.all += 1;
                } else {
                    const both: *BothCounts = @ptrCast(self);
                    both.* += 1 << @bitSizeOf(Index) | 1;
                }
            }
        };
        pub const root_id: Id = .of("zui.root");
        pub const max_elements = limits.max_elements;
        pub const max_depth = limits.max_depth;
        const id_table_slots = nextPowerOfTwo(limits.max_elements * 2);

        const TextContract = if (has_text) config.Text else void;
        pub const Cache = if (has_text) text_layout.MeasureCache(config.FontId, limits.measure_cache_entries, limits.string_cache_entries, TextContract) else void;
        pub const measures_in_parallel = has_text and @hasDecl(TextContract, "zui_thread_safe") and TextContract.zui_thread_safe;
        const MeasureBatch = if (measures_in_parallel) parallel_measure.MeasureBatch(MeasureKey, TextContract, limits.parallel_measure_capacity) else void;
        const run_width_capacity = if (has_text) text_layout.maxRuns(limits.max_text_bytes, limits.max_elements) else 0;
        pub const States = state_table.StateTable(limits.state_slots);
        pub const Results = interaction.Results(limits.max_elements, id_table_slots);
        const InputState = interaction.State(limits.max_input_contacts, limits.max_depth + 1, limits.max_events_per_frame, limits.max_text_input_bytes, limits.max_dropped_path_bytes);

        pub const Decoration = style.Decoration;
        const default_layout: style.Layout = .{};

        pub const TextRecord = struct {
            element: Index,
            bytes_start: u32,
            bytes_len: u32,
            style: TextStyle,
            metrics: text_layout.Metrics,
            first_line: u32,
            line_count: u32,
        };

        /// One frame's memory. Only its methods and `diagnostics` and
        /// `number` are API; the other fields are the structure-of-arrays
        /// storage the layout passes stream through.
        pub const Frame = struct {
            /// Frames since `init`, from 0.
            number: u64,
            /// The record's parameters: what a renderer needs to draw the
            /// commands at the right size and scale.
            params: record_types.FrameParams,
            diagnostics: Diagnostics,
            host_requests: HostRequests,

            element_count: u32,
            element_id: [max_elements]u64,
            element_name: [max_elements]id_module.DebugName,
            parent: [max_elements]Index,
            child_counts: [max_elements]ChildCounts,
            /// The element's layout: the default, one copied into `layouts`, or
            /// a static style's.
            layout: [max_elements]*const style.Layout,
            /// Null for an element that draws no background or border.
            decoration: [max_elements]?*const Decoration,
            content_kind: [max_elements]ContentKind,
            /// Index into the record of the element's `content_kind`; not
            /// written for `.none`.
            content_index: [max_elements]Index,
            size: [max_elements][2]f32,
            min_size: [max_elements][2]f32,
            position: [max_elements][2]f32,
            flags: [max_elements]ElementFlags,
            /// One past the last element of this element's subtree, which is
            /// also its next sibling, if it has one. A container's is only
            /// written when it closes, so it is not valid while it is open.
            subtree_end: [max_elements]Index,
            /// Index into `floatings`. Only written for floating elements;
            /// for any other element it holds whatever an earlier frame left.
            floating_index: [max_elements]Index,
            /// The extent of an element's children plus padding, for scrolling.
            content_size: [max_elements][2]f32,

            /// The configs an element set itself, copied in declaration.
            layouts: [max_elements]style.Layout,
            /// Where the next copied layout goes.
            next_layout: [*]style.Layout,
            decorations: [max_elements]Decoration,
            next_decoration: [*]Decoration,
            texts: [if (has_text) max_elements else 0]TextRecord,
            text_count: u32,
            images: [max_elements]Image,
            image_count: u32,
            customs: [max_elements]config.CustomData,
            custom_count: u32,
            floatings: [max_elements]style.Floating,
            floating_count: u32,

            text_bytes: [if (has_text) limits.max_text_bytes else 0]u8,
            text_bytes_used: u32,
            lines: [if (has_text) limits.max_render_commands else 0]text_layout.Line,
            line_count: u32,
            render_commands: [limits.max_render_commands]RenderCommand,
            command_count: u32,

            id_table: [id_table_slots]Index,
            /// Physical pixels per layout unit: the record's scale times its zoom.
            pixels_per_unit: f32,
            held: std.atomic.Value(bool),

            pub fn commands(self: *const Frame) []const RenderCommand {
                return self.render_commands[0..self.command_count];
            }

            /// The accessible elements, in tree order, for a host to bridge
            /// to the platform's accessibility API. No element declares
            /// semantics yet, so it is empty.
            pub fn semantics(self: *const Frame) []const record_types.SemanticNode {
                comptime requireFeature(.semantics, "semantics()");
                _ = self;
                return &.{};
            }

            /// What the host should apply with this frame: the cursor and
            /// where text input goes.
            pub fn requests(self: *const Frame) HostRequests {
                return self.host_requests;
            }

            pub fn elementCount(self: *const Frame) Index {
                return @intCast(self.element_count);
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
                return self.layout[index];
            }

            /// Null for an element that draws no background or border.
            pub fn decorationOf(self: *const Frame, index: Index) ?*const Decoration {
                return self.decoration[index];
            }

            /// Text elements never have a layout, so they are `.fit` here too.
            pub fn sizingOf(self: *const Frame, index: Index, comptime axis: style.Axis) style.Sizing {
                const sizing = &self.layoutOf(index).sizing;
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

            fn reset(self: *Frame, number: u64, params: record_types.FrameParams) void {
                self.number = number;
                self.params = params;
                self.element_count = 0;
                self.next_layout = &self.layouts;
                self.next_decoration = &self.decorations;
                self.text_count = 0;
                self.image_count = 0;
                self.custom_count = 0;
                self.floating_count = 0;
                self.text_bytes_used = 0;
                self.line_count = 0;
                self.command_count = 0;
                self.diagnostics = .{};
                self.host_requests = .{};
                self.pixels_per_unit = params.scale * params.zoom;
                @memset(&self.id_table, none_index);
            }
        };

        const Memory = struct {
            frames: [config.frames_in_flight]Frame,
            cache: Cache,
            measure_batch: MeasureBatch,
            /// Scratch shared by every frame: the width of each word or
            /// paragraph measured in the current `endFrame`.
            run_widths: [run_width_capacity]f32,
            states: States,
            results: Results,
            input: InputState,
            /// What each source delivered, filled from `zuiDelivery` for a
            /// relay listener.
            relayed_deliveries: Deliveries,
        };

        /// The bytes `initBuffer` needs; `init` makes one allocation of this size.
        pub const required_bytes: usize = @sizeOf(Memory);
        pub const buffer_alignment = std.atomic.cache_line;

        comptime {
            if (@alignOf(Memory) > buffer_alignment) @compileError("zui: Config payload types need alignment above a cache line, which initBuffer cannot provide");
        }

        memory: *Memory,
        owns_memory: bool,
        text_contract: *TextContract,
        io: std.Io,

        current: ?*Frame = null,
        relay_listener: ?Relay = null,
        next_frame_slot: u8 = 0,
        frames_begun: u64 = 0,
        open_stack: [max_depth]Index = undefined,
        /// Not a `u16`: `open` stores it and the next element reloads it,
        /// which LLVM widens to a 32-bit load. A wider load cannot be
        /// forwarded from a pending narrower store, so as a `u16` it stalled
        /// every `open`, and the box tree declared 39% slower.
        depth: u32 = 0,
        dropped_depth: u32 = 0,

        /// Scratch for the emission pass, kept here so frames stay plain data.
        emit_levels: [max_depth + 1]emission.EmitLevel(Index) = undefined,

        frame_released: std.Io.Event = .unset,
        now_instant: Instant = .zero,
        previous_instant: ?Instant = null,
        frame_requested: bool = false,
        requested_deadline: ?Instant = null,
        current_environment: Environment = .{},
        /// The hover-chain position of the element whose cursor the frame
        /// requests; an element nearer the pointer replaces it.
        cursor_chain_position: usize = no_cursor,
        text_input_caret: ?u64 = null,

        /// Held from `beginFrame` to `endFrame` only: between frames the
        /// sources are the application's alone.
        sources_in_frame: if (has_sources) ?*Sources else void = if (has_sources) null else {},
        /// `frames_begun` when each source was last read; 0 for one never read.
        frames_begun_at_last_read: [source_count]u64 = @splat(0),

        const no_cursor = std.math.maxInt(usize);

        /// `init(gpa, io, text)`, or `init(gpa, io)` when `Text` is `void`.
        pub const init = if (has_text) initWithText else initWithoutText;
        /// `initBuffer(buffer, io, text)`, or `initBuffer(buffer, io)` when `Text` is `void`.
        pub const initBuffer = if (has_text) initBufferWithText else initBufferWithoutText;

        fn initWithText(gpa: std.mem.Allocator, io: std.Io, text_contract: *TextContract) std.mem.Allocator.Error!Self {
            return initAllocated(gpa, io, text_contract);
        }

        fn initWithoutText(gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!Self {
            return initAllocated(gpa, io, undefined);
        }

        fn initBufferWithText(buffer: []align(buffer_alignment) u8, io: std.Io, text_contract: *TextContract) error{BufferTooSmall}!Self {
            return initInBuffer(buffer, io, text_contract);
        }

        fn initBufferWithoutText(buffer: []align(buffer_alignment) u8, io: std.Io) error{BufferTooSmall}!Self {
            return initInBuffer(buffer, io, undefined);
        }

        fn initAllocated(gpa: std.mem.Allocator, io: std.Io, text_contract: *TextContract) std.mem.Allocator.Error!Self {
            const memory = try gpa.create(Memory);
            var self: Self = .{ .memory = memory, .owns_memory = true, .text_contract = text_contract, .io = io };
            self.prepareMemory();
            return self;
        }

        fn initInBuffer(buffer: []align(buffer_alignment) u8, io: std.Io, text_contract: *TextContract) error{BufferTooSmall}!Self {
            if (buffer.len < required_bytes) return error.BufferTooSmall;
            var self: Self = .{ .memory = @ptrCast(@alignCast(buffer.ptr)), .owns_memory = false, .text_contract = text_contract, .io = io };
            self.prepareMemory();
            return self;
        }

        fn prepareMemory(self: *Self) void {
            if (has_text) self.memory.cache.reset();
            if (measures_in_parallel) self.memory.measure_batch.clearAll();
            self.memory.states.reset();
            self.memory.results.reset();
            self.memory.input.reset();
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

        /// `beginFrame(record, sources)`, or `beginFrame(record)` when
        /// `Sources` is `void`. Applies the record, then swaps each source in
        /// field order, or injects `record.deliveries` when it is set. Waits
        /// for a free frame if a renderer holds all of them.
        pub const beginFrame = if (has_sources) beginFrameWithSources else beginFrameWithoutSources;
        /// `beginFrame` for hosts that cannot block.
        pub const tryBeginFrame = if (has_sources) tryBeginFrameWithSources else tryBeginFrameWithoutSources;

        fn beginFrameWithSources(self: *Self, record: *const FrameRecord, sources: *Sources) void {
            self.beginWaiting(record, sources);
        }

        fn beginFrameWithoutSources(self: *Self, record: *const FrameRecord) void {
            self.beginWaiting(record, {});
        }

        fn tryBeginFrameWithSources(self: *Self, record: *const FrameRecord, sources: *Sources) error{NoFreeFrame}!void {
            return self.tryBegin(record, sources);
        }

        fn tryBeginFrameWithoutSources(self: *Self, record: *const FrameRecord) error{NoFreeFrame}!void {
            return self.tryBegin(record, {});
        }

        const SourcesPointer = if (has_sources) *Sources else void;

        fn beginWaiting(self: *Self, record: *const FrameRecord, sources: SourcesPointer) void {
            if (self.current != null) @panic("zui: beginFrame() called again before endFrame()");
            const zone = Tracing.begin(.begin_frame);
            defer zone.end();
            const waiting = Tracing.begin(.wait_for_frame);
            const frame = self.waitForFreeFrame();
            waiting.end();
            self.begin(frame, record, sources);
        }

        fn tryBegin(self: *Self, record: *const FrameRecord, sources: SourcesPointer) error{NoFreeFrame}!void {
            if (self.current != null) @panic("zui: beginFrame() called again before endFrame()");
            const zone = Tracing.begin(.begin_frame);
            defer zone.end();
            const waiting = Tracing.begin(.wait_for_frame);
            const free_frame = self.takeFreeFrame();
            waiting.end();
            self.begin(free_frame orelse return error.NoFreeFrame, record, sources);
        }

        fn begin(self: *Self, frame: *Frame, record: *const FrameRecord, sources: SourcesPointer) void {
            frame.reset(self.frames_begun, record.params);
            self.frames_begun += 1;
            self.previous_instant = if (self.frames_begun > 1) self.now_instant else null;
            self.now_instant = record.params.now;
            self.frame_requested = false;
            self.requested_deadline = null;
            self.cursor_chain_position = no_cursor;
            self.text_input_caret = null;
            if (has_text) self.memory.cache.generation +%= 1;
            const evicting = Tracing.begin(.evict_state);
            self.memory.states.evict(self.stateGeneration(), limits.state_frames_until_eviction);
            evicting.end();
            const applying = Tracing.begin(.apply_events);
            self.applyEvents(frame, record.events);
            applying.end();
            if (has_sources) self.swapSources(frame, record, sources);
            if (self.relay_listener) |listener| self.relay(listener, record, sources);
            self.current = frame;
            self.dropped_depth = 0;
            self.depth = 0;

            const root_layout: style.Layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .width = .fixed(record.params.viewport[0]), .height = .fixed(record.params.viewport[1]) },
            };
            const root = self.appendElement(frame, true, root_id, .{ .layout = root_layout }, .none, 0) orelse unreachable;
            self.open_stack[0] = root;
            self.depth = 1;
            frame.diagnostics.needed.set(.max_depth, 1);
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

        fn swapSources(self: *Self, frame: *Frame, record: *const FrameRecord, sources: *Sources) void {
            self.sources_in_frame = sources;
            if (source_count == 0) return;
            const swapping = Tracing.begin(.swap_sources);
            defer swapping.end();
            if (record.deliveries) |deliveries| {
                inline for (@typeInfo(Sources).@"struct".fields) |field| {
                    @field(sources, field.name).zuiInject(&@field(deliveries, field.name));
                }
                return;
            }
            inline for (@typeInfo(Sources).@"struct".fields) |field| {
                const source_value = &@field(sources, field.name);
                source_value.zuiSwap();
                if (@hasDecl(field.type, "zuiRefusedCount")) {
                    const refused = source_value.zuiRefusedCount();
                    if (refused != 0) frame.diagnostics.addRefusals(field.name, refused);
                }
            }
        }

        /// Hands `listener` the record as applied: the events kept, and the
        /// deliveries a replay injected or each source reports it received.
        fn relay(self: *Self, listener: Relay, record: *const FrameRecord, sources: SourcesPointer) void {
            const relaying = Tracing.begin(.relay);
            defer relaying.end();
            var applied: FrameRecord = .{
                .params = record.params,
                .events = record.events[0..@min(record.events.len, limits.max_events_per_frame)],
            };
            if (has_sources) applied.deliveries = record.deliveries orelse delivered: {
                const delivered = &self.memory.relayed_deliveries;
                inline for (@typeInfo(Sources).@"struct".fields) |field| {
                    @field(sources, field.name).zuiDelivery(&@field(delivered, field.name));
                }
                break :delivered delivered;
            };
            listener.relay(&applied);
        }

        /// Lets each source settle its own demand, such as the keys this
        /// frame asked it for.
        fn settleSources(self: *Self, frame: *const Frame) void {
            const sources = self.sources_in_frame.?;
            self.sources_in_frame = null;
            const info: sources_module.EndFrameInfo = .{ .frame_number = frame.number, .frames_in_flight = config.frames_in_flight };
            inline for (@typeInfo(Sources).@"struct".fields) |field| {
                if (@hasDecl(field.type, "zuiEndFrame")) @field(sources, field.name).zuiEndFrame(info);
            }
        }

        /// Always returns a frame to draw. If a limit was exceeded, the
        /// part that fit was laid out, and `frame.diagnostics` says which
        /// limit to raise.
        pub fn endFrame(self: *Self) *const Frame {
            const frame = self.current orelse @panic("zui: endFrame() called without beginFrame()");
            const zone = Tracing.begin(.end_frame);
            defer zone.end();
            if (self.depth != 1 or self.dropped_depth != 0) self.reportUnbalanced(frame);
            frame.subtree_end[root_index] = @intCast(frame.element_count);
            const needed = &frame.diagnostics.needed;
            needed.set(.max_elements, needed.get(.max_elements) + frame.element_count);
            needed.set(.max_text_bytes, needed.get(.max_text_bytes) + frame.text_bytes_used);

            layout.run(Self, self, frame);
            @call(.never_inline, emission.run, .{ Self, self, frame });
            if (self.text_input_caret) |caret| if (frame.rectOf(.{ .hash = caret })) |rect| {
                frame.host_requests.text_input = .{ .caret = rect };
            };

            const results = &self.memory.results;
            results.has_frame = true;
            const focus = &self.memory.input.focus;
            if (focus.* != 0 and !results.isFocusable(focus.*)) focus.* = 0;
            if (has_sources) self.settleSources(frame);

            frame.held.store(true, .release);
            self.current = null;
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

        /// From the next `beginFrame`, hands `listener` each record as
        /// applied, with what each source delivered, so a session can be
        /// recorded, sent elsewhere or replayed; `null` detaches it. Without
        /// a listener nothing is copied.
        pub fn relayTo(self: *Self, listener: ?Relay) void {
            self.relay_listener = listener;
        }

        /// Returns the frame's memory. Safe to call from any thread.
        pub fn release(self: *Self, frame: *const Frame) void {
            const mutable: *Frame = @constCast(frame);
            mutable.held.store(false, .release);
            self.frame_released.set(self.io);
        }

        /// When the host should run the next frame: at once if one was
        /// requested or a source has something not yet swapped, at the
        /// earliest `requestFrameAt`, or else when input arrives. An idle UI
        /// therefore uses no CPU. `nextFrame(sources)`, or `nextFrame()`
        /// when `Sources` is `void`; called after the loader, so what it
        /// published counts.
        pub const nextFrame = if (has_sources) nextFrameWithSources else nextFrameWithoutSources;

        fn nextFrameWithSources(self: *const Self, sources: *const Sources) NextFrame {
            inline for (@typeInfo(Sources).@"struct".fields) |field| {
                if (@hasDecl(field.type, "zuiPending") and @field(sources, field.name).zuiPending()) return .immediately;
            }
            return self.nextFrameWithoutSources();
        }

        fn nextFrameWithoutSources(self: *const Self) NextFrame {
            if (self.frame_requested) return .immediately;
            if (self.requested_deadline) |deadline| return .{ .at = deadline };
            return .on_event;
        }

        /// Asks for one more frame as soon as possible.
        pub fn requestFrame(self: *Self) void {
            self.frame_requested = true;
        }

        /// Asks for a frame at `instant`, e.g. the caret's next blink.
        pub fn requestFrameAt(self: *Self, instant: Instant) void {
            if (self.requested_deadline) |deadline| if (!instant.isBefore(deadline)) return;
            self.requested_deadline = instant;
        }

        pub fn stateGeneration(self: *const Self) u32 {
            return @truncate(self.frames_begun);
        }

        pub fn measureKeyOf(text_style: TextStyle, zoom: f32) MeasureKey {
            return .{ .font = text_style.font, .size = text_style.size * zoom, .letter_spacing = text_style.letter_spacing * zoom };
        }

        pub fn measurer(self: *Self, text_style: TextStyle, zoom: f32) text_layout.Measurer(Cache, TextContract) {
            return .{ .cache = &self.memory.cache, .text_contract = self.text_contract, .key = measureKeyOf(text_style, zoom), .inverse_zoom = 1 / zoom };
        }

        /// The size of `content` in layout units, through the measurement
        /// cache. For widgets that place a caret or map a pointer position
        /// to a character.
        pub fn measureText(self: *Self, content: []const u8, text_style: TextStyle) [2]f32 {
            if (!has_text) @compileError("zui: measureText() needs Config.Text set to a text contract");
            const frame = self.current orelse @panic("zui: measureText() is only available between beginFrame() and endFrame()");
            return self.measurer(text_style, frame.params.zoom).measure(content);
        }

        /// The current frame's viewport, from its record.
        pub fn viewport(self: *const Self) [2]f32 {
            const frame = self.current orelse @panic("zui: viewport() is only known between beginFrame() and endFrame()");
            return frame.params.viewport;
        }

        /// As the host last reported it through `environment` events.
        pub fn environment(self: *const Self) *const Environment {
            return &self.current_environment;
        }

        /// The read-only view of one source, as this frame's swap left it:
        /// `ui.source(.quotes).items()`. Reading it is the frame's demand
        /// for it, which `framesSinceRead` reports to the loader.
        pub const source = if (has_sources) sourceOf else sourceWithoutSources;

        fn sourceOf(self: *Self, comptime field: SourceField) SourceView(field) {
            const sources = self.sources_in_frame orelse @panic("zui: source() is only available between beginFrame() and endFrame()");
            self.frames_begun_at_last_read[@intFromEnum(field)] = self.frames_begun;
            return @field(sources, @tagName(field)).zuiView();
        }

        fn sourceWithoutSources(_: *Self, comptime _: @EnumLiteral()) void {
            @compileError("zui: source() needs Config.Sources set to a struct of sources");
        }

        /// 0 when the last frame to end read the source (or the frame being
        /// declared has), 1 when the frame before it did, and `maxInt(u64)`
        /// when none has. It counts frames, not time, so a sleeping UI never
        /// looks as if no one were watching.
        pub const framesSinceRead = if (has_sources) framesSinceReadOf else framesSinceReadWithoutSources;

        fn framesSinceReadOf(self: *const Self, comptime field: SourceField) u64 {
            const frames_begun_at_read = self.frames_begun_at_last_read[@intFromEnum(field)];
            if (frames_begun_at_read == 0) return std.math.maxInt(u64);
            const frames_ended = self.frames_begun - @intFromBool(self.current != null);
            return frames_ended -| frames_begun_at_read;
        }

        fn framesSinceReadWithoutSources(_: *const Self, comptime _: @EnumLiteral()) u64 {
            @compileError("zui: framesSinceRead() needs Config.Sources set to a struct of sources");
        }

        /// Asks the host for text input at `caret`'s rectangle in this
        /// frame, if `editable` is focused. An editable widget calls it
        /// each frame, naming the element it draws as its caret:
        ///
        /// ```zig
        /// ui.requestTextInput(id, id.child("caret"));
        /// ```
        pub fn requestTextInput(self: *Self, editable: Id, caret: Id) void {
            _ = self.declaring();
            if (self.focused(editable)) self.text_input_caret = caret.hash;
        }

        /// The current record's `now`.
        pub fn now(self: *const Self) Instant {
            return self.now_instant;
        }

        /// Seconds between this record's `now` and the previous one's; 0 on
        /// the first frame.
        pub fn dt(self: *const Self) f32 {
            const previous = self.previous_instant orelse return 0;
            return self.now_instant.secondsSince(previous);
        }

        /// How many times the cache has called the text contract. Useful
        /// for confirming that steady-state frames hit the cache.
        pub fn measureCalls(self: *const Self) u64 {
            if (!has_text) return 0;
            return self.memory.cache.measure_calls;
        }

        // =============================================================
        // Declaration
        // =============================================================

        pub inline fn open(self: *Self, element: Element) void {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.dropped_depth += 1;
                self.countDropped(frame, .max_elements);
                return;
            }
            const attempted_depth: u32 = self.depth + 1;
            if (attempted_depth > frame.diagnostics.needed.get(.max_depth)) frame.diagnostics.needed.set(.max_depth, attempted_depth);
            if (self.depth >= max_depth) {
                self.recordOverflow(frame, .max_depth, element.id.hash);
                self.dropped_depth = 1;
                return;
            }
            const index = self.appendElement(frame, false, element.id, element, .none, 0) orelse {
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
        pub inline fn box(self: *Self, element: Element) void {
            _ = self.leaf(element, .none, 0);
        }

        /// A leaf showing `content`. The bytes are copied, so the caller's
        /// buffer may be reused immediately.
        pub fn text(self: *Self, content: []const u8, text_style: TextStyle) void {
            if (!has_text) @compileError("zui: text() needs Config.Text set to a text contract");
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.countDropped(frame, .max_elements);
                return;
            }
            if (frame.text_bytes_used + content.len > limits.max_text_bytes) {
                self.countDroppedTextBytes(frame, content.len);
                self.recordOverflow(frame, .max_text_bytes, 0);
                return;
            }
            const record_index = frame.text_count;
            const element_index = self.appendElement(frame, false, .none, .{}, .text, record_index) orelse {
                self.countDroppedTextBytes(frame, content.len);
                return;
            };
            frame.subtree_end[element_index] = element_index + 1;
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

        pub fn image(self: *Self, picture: Image, element: Element) void {
            if (config.ImageHandle == void) @compileError("zui: image() needs Config.ImageHandle set to your image type");
            const frame = self.declaring();
            const record_index = frame.image_count;
            if (self.leaf(element, .image, record_index)) {
                frame.images[record_index] = picture;
                frame.image_count += 1;
            }
        }

        pub fn custom(self: *Self, data: config.CustomData, element: Element) void {
            if (config.CustomData == void) @compileError("zui: custom() needs Config.CustomData set to your payload type");
            const frame = self.declaring();
            const record_index = frame.custom_count;
            if (self.leaf(element, .custom, record_index)) {
                frame.customs[record_index] = data;
                frame.custom_count += 1;
            }
        }

        inline fn leaf(self: *Self, element: Element, kind: ContentKind, record_index: u32) bool {
            const frame = self.declaring();
            if (self.dropped_depth > 0) {
                self.countDropped(frame, .max_elements);
                return false;
            }
            const index = self.appendElement(frame, false, element.id, element, kind, record_index) orelse return false;
            frame.subtree_end[index] = index + 1;
            return true;
        }

        fn declaring(self: *Self) *Frame {
            return self.current orelse @panic("zui: elements can only be declared between beginFrame() and endFrame()");
        }

        /// `inline`, like `open`, `box` and `leaf`, so each call site is
        /// specialized to its element literal: the fields left at their
        /// defaults cost nothing, and the `Element` is never copied. Out of
        /// line, declaration was about 35% slower.
        inline fn appendElement(self: *Self, frame: *Frame, comptime is_root: bool, element_id: Id, element: Element, kind: ContentKind, record_index: u32) ?Index {
            if (frame.element_count >= max_elements) {
                self.countDropped(frame, .max_elements);
                self.recordOverflow(frame, .max_elements, element_id.hash);
                return null;
            }
            const index: Index = @intCast(frame.element_count);
            const parent: Index = if (is_root) none_index else self.open_stack[self.depth - 1];

            const hash = if (is_root or !element_id.isNone())
                element_id.hash
            else
                id_module.internal(frame.element_id[parent], frame.child_counts[parent].all);

            frame.element_count += 1;
            frame.element_id[index] = hash;
            frame.element_name[index] = element_id.debug_name;
            frame.parent[index] = parent;
            frame.child_counts[index] = .none;
            frame.size[index] = .{ 0, 0 };
            frame.min_size[index] = .{ 0, 0 };
            frame.content_kind[index] = kind;
            if (kind != .none) frame.content_index[index] = @intCast(record_index);
            frame.flags[index] = flagsFor(element_id, element);

            if (element.cursor) |cursor| if (frame.flags[index].interactive) self.offerCursor(frame, hash, cursor);

            if (element.floating) |floating| {
                frame.floating_index[index] = @intCast(frame.floating_count);
                frame.floatings[frame.floating_count] = floating;
                frame.floating_count += 1;
            }

            if (element.layout) |element_layout| {
                const copied_layout = frame.next_layout;
                frame.next_layout = copied_layout + 1;
                copied_layout[0] = element_layout;
                frame.layout[index] = &copied_layout[0];
            } else frame.layout[index] = if (element.style) |static_style| &static_style.value.layout else &default_layout;

            if (element.decoration) |decoration| {
                if (decoration.background != null or decoration.border != null) {
                    const copied_decoration = frame.next_decoration;
                    frame.next_decoration = copied_decoration + 1;
                    copied_decoration[0] = decoration;
                    frame.decoration[index] = &copied_decoration[0];
                } else frame.decoration[index] = null;
            } else frame.decoration[index] = if (element.style) |static_style| drawnDecoration(&static_style.value.decoration) else null;

            if (!is_root) {
                if (element.floating == null) frame.child_counts[parent].count(false) else frame.child_counts[parent].count(true);
            }

            if (!element_id.isNone() and !registerId(frame, index)) {
                frame.flags[index].interactive = false;
                frame.flags[index].focusable = false;
                frame.flags[index].scroll_x = false;
                frame.flags[index].scroll_y = false;
            }
            return index;
        }

        fn offerCursor(self: *Self, frame: *Frame, hash: u64, cursor: Cursor) void {
            const contact = self.memory.input.hoveringContact() orelse return;
            const chain_position = std.mem.indexOfScalar(u64, contact.hover_chain[0..contact.hover_count], hash) orelse return;
            if (chain_position >= self.cursor_chain_position) return;
            self.cursor_chain_position = chain_position;
            frame.host_requests.cursor = cursor;
        }

        inline fn directionOf(element: Element) style.Direction {
            if (element.layout) |element_layout| return element_layout.direction;
            if (element.style) |static_style| return static_style.value.layout.direction;
            return default_layout.direction;
        }

        /// A static decoration that draws nothing is stored as none, so
        /// emission skips it as it skips an element without one.
        inline fn drawnDecoration(decoration: *const Decoration) ?*const Decoration {
            return if (decoration.background != null or decoration.border != null) decoration else null;
        }

        inline fn flagsFor(element_id: Id, element: Element) ElementFlags {
            var flags: ElementFlags = .{
                .explicit_id = !element_id.isNone(),
                .interactive = (element.interactive orelse false) or (element.focusable orelse false),
                .focusable = element.focusable orelse false,
                .focus_scope = element.focus_scope orelse false,
                .disabled = element.disabled orelse false,
                .clip_x = element.clip.includes(.x),
                .clip_y = element.clip.includes(.y),
                .top_to_bottom = directionOf(element) == .top_to_bottom,
                .floating = element.floating != null,
            };
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
        fn registerId(frame: *Frame, index: Index) bool {
            const hash = frame.element_id[index];
            var slot: usize = @as(usize, @truncate(hash)) & (id_table_slots - 1);
            while (true) : (slot = (slot + 1) & (id_table_slots - 1)) {
                const existing = frame.id_table[slot];
                if (existing == none_index) {
                    frame.id_table[slot] = index;
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

        fn countDroppedTextBytes(self: *Self, frame: *Frame, byte_count: usize) void {
            _ = self;
            frame.diagnostics.needed.set(.max_text_bytes, frame.diagnostics.needed.get(.max_text_bytes) + @as(u32, @intCast(byte_count)));
        }

        fn countDropped(self: *Self, frame: *Frame, limit: Limit) void {
            _ = self;
            frame.diagnostics.needed.set(limit, frame.diagnostics.needed.get(limit) + 1);
        }

        // =============================================================
        // Input: the record's events, applied against the previous
        // frame's hit regions
        // =============================================================

        fn applyEvents(self: *Self, frame: *Frame, events: []const input.Event) void {
            const input_state = &self.memory.input;
            const results = &self.memory.results;
            input_state.clearFrameEvents();
            // The layout may have moved under a pointer that did not, so every
            // hovering pointer is hit-tested once a frame even without a move.
            for (&input_state.contacts) |*slot| {
                if (slot.*) |*contact| contact.hover_stale = contact.hovers();
            }
            if (input_state.pending_focus) |requested| {
                // Checked here as well as at endFrame, so a disabled element
                // is never focused for long enough to be activated by Enter.
                if (results.isFocusable(requested)) input_state.focus = requested;
                input_state.pending_focus = null;
            }

            const kept = @min(events.len, limits.max_events_per_frame);
            if (events.len > kept) {
                frame.diagnostics.exceeded.insert(.max_events_per_frame);
                frame.diagnostics.needed.set(.max_events_per_frame, @intCast(@min(events.len, std.math.maxInt(u32))));
            }
            for (events[0..kept]) |event| switch (event) {
                .pointer_move => |move| {
                    // A touch exists only while it is down; a hovering pen or
                    // mouse is added by its first move.
                    const found = if (move.pointer.kind == .touch) input_state.find(move.pointer.id) else self.contactFor(frame, move.pointer);
                    const contact = found orelse continue;
                    contact.pointer = move.pointer;
                    contact.hover_stale = contact.hovers();
                },
                .pointer_down => |down| {
                    const contact = self.contactFor(frame, down.pointer) orelse continue;
                    contact.pointer = down.pointer;
                    const hot = self.refreshHover(contact);
                    contact.buttons.insert(down.button);
                    if (down.button == .primary) self.press(contact, hot);
                },
                .pointer_up => |up| {
                    const contact = input_state.find(up.pointer.id) orelse continue;
                    contact.pointer = up.pointer;
                    const hot = self.refreshHover(contact);
                    contact.buttons.remove(up.button);
                    if (up.button == .primary) {
                        if (contact.press_target != 0) if (hot) |region| if (results.regions[region].hash == contact.press_target) input_state.addClick(contact.press_target);
                        contact.press_target = 0;
                    }
                    if (!contact.hovers() and contact.buttons.count() == 0) contact.lifted = true;
                },
                .pointer_cancel => |pointer_id| if (input_state.find(pointer_id)) |contact| input_state.remove(contact),
                .pointer_leave => |pointer_id| if (input_state.find(pointer_id)) |contact| {
                    if (contact.buttons.count() == 0) input_state.remove(contact) else contact.hover_count = 0;
                },
                .wheel => |wheel| self.applyWheel(wheel),
                .key_down => |key_event| {
                    input_state.key_events[input_state.key_event_count] = key_event;
                    input_state.key_event_count += 1;
                    switch (key_event.key) {
                        .tab => input_state.focus = results.nextFocus(input_state.focus, !key_event.modifiers.shift),
                        .enter, .space => if (input_state.focus != 0) input_state.addClick(input_state.focus),
                        else => {},
                    }
                },
                .key_up => {},
                .environment => |change| self.current_environment.apply(change),
                .lifecycle => |change| input_state.lifecycle.insert(change),
                .files_dropped => |drop| keepDrop(frame, input_state, drop),
                .text => |typed| {
                    const room = limits.max_text_input_bytes - input_state.text_len;
                    const copied: u16 = @intCast(@min(typed.len, room));
                    @memcpy(input_state.text[input_state.text_len..][0..copied], typed[0..copied]);
                    input_state.text_len += copied;
                    const needed = &frame.diagnostics.needed;
                    needed.set(.max_text_input_bytes, needed.get(.max_text_input_bytes) +| @as(u32, @intCast(@min(typed.len, std.math.maxInt(u32)))));
                    if (copied < typed.len) frame.diagnostics.exceeded.insert(.max_text_input_bytes);
                },
            };

            for (&input_state.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.hover_stale) {
                    _ = self.refreshHover(contact);
                };
            }
        }

        /// Keeps the paths that fit whole, and the drop if any did.
        fn keepDrop(frame: *Frame, input_state: *InputState, drop: input.FilesDropped) void {
            const needed = &frame.diagnostics.needed;
            needed.set(.max_dropped_path_bytes, needed.get(.max_dropped_path_bytes) +| std.math.lossyCast(u32, drop.path_list.len));
            if (input_state.dropped_path_len + drop.path_list.len > limits.max_dropped_path_bytes) frame.diagnostics.exceeded.insert(.max_dropped_path_bytes);
            if (comptime limits.max_dropped_path_bytes == 0) return;
            const start = input_state.dropped_path_len;
            var paths = drop.paths();
            while (paths.next()) |path| {
                if (path.len + 1 > limits.max_dropped_path_bytes - input_state.dropped_path_len) continue;
                @memcpy(input_state.dropped_paths[input_state.dropped_path_len..][0..path.len], path);
                input_state.dropped_paths[input_state.dropped_path_len + path.len] = 0;
                input_state.dropped_path_len += @intCast(path.len + 1);
            }
            if (input_state.dropped_path_len == start) return;
            var kept = drop;
            kept.path_list = input_state.dropped_paths[start..input_state.dropped_path_len];
            input_state.drops[input_state.drop_count] = kept;
            input_state.drop_count += 1;
        }

        fn contactFor(self: *Self, frame: *Frame, pointer: input.Pointer) ?*InputState.Slot {
            if (self.memory.input.findOrAdd(pointer)) |contact| return contact;
            frame.diagnostics.exceeded.insert(.max_input_contacts);
            frame.diagnostics.needed.set(.max_input_contacts, limits.max_input_contacts + 1);
            return null;
        }

        /// Hit-tests the contact where it is, rebuilds its hover chain, and
        /// returns the hot region: the topmost interactive one under it.
        fn refreshHover(self: *Self, contact: *InputState.Slot) ?u32 {
            const results = &self.memory.results;
            contact.hover_stale = false;
            contact.hover_count = 0;
            if (!results.has_frame) return null;
            const point = contact.pointer.position;
            var region_index = results.topmostAt(point) orelse return null;
            var hot: ?u32 = null;
            while (region_index != interaction.no_region) : (region_index = results.regions[region_index].parent) {
                const region = results.regions[region_index];
                if (!region.flags.interactive or !region.bounds.contains(point)) continue;
                if (hot == null) hot = region_index;
                if (contact.hovers() and contact.hover_count < contact.hover_chain.len) {
                    contact.hover_chain[contact.hover_count] = region.hash;
                    contact.hover_count += 1;
                }
            }
            return hot;
        }

        /// Pressing a focusable element focuses it; pressing anything else
        /// clears focus.
        fn press(self: *Self, contact: *InputState.Slot, hot: ?u32) void {
            const input_state = &self.memory.input;
            const results = &self.memory.results;
            input_state.presses_begun += 1;
            contact.press_order = input_state.presses_begun;
            contact.press_target = 0;
            input_state.focus = 0;
            const region = results.regions[hot orelse return];
            if (region.flags.disabled) return;
            contact.press_target = region.hash;
            if (region.flags.focusable) input_state.focus = region.hash;
        }

        /// The innermost scroll container under the wheel that can still
        /// move along an axis takes that axis.
        fn applyWheel(self: *Self, wheel: input.Wheel) void {
            const results = &self.memory.results;
            if (!results.has_frame) return;
            const innermost = results.topmostAt(wheel.position) orelse return;
            for (0..2) |axis| {
                if (wheel.delta[axis] == 0) continue;
                var region_index = innermost;
                while (region_index != interaction.no_region) : (region_index = results.regions[region_index].parent) {
                    const region = results.regions[region_index];
                    if (!region.flags.scrolls(axis) or !region.bounds.contains(wheel.position)) continue;
                    const offset = self.memory.states.get(region.hash, interaction.ScrollState, self.stateGeneration(), .create) orelse break;
                    const moved = std.math.clamp(offset.offset[axis] + wheel.delta[axis], 0, region.max_scroll[axis]);
                    if (moved != offset.offset[axis]) {
                        offset.offset[axis] = moved;
                        break;
                    }
                }
            }
        }

        // =============================================================
        // Interaction queries: each answers for the previous frame
        // =============================================================

        /// True for the topmost interactive element under a hovering
        /// pointer and for each interactive ancestor that also contains it.
        pub fn hovered(self: *const Self, element_id: Id) bool {
            return self.memory.input.isHovered(element_id.hash);
        }

        /// A pointer whose press began on this element is still down.
        /// What pointers did to `element_id` this frame, by dragging,
        /// pinching or rotating it, summed. No gesture is recognized yet,
        /// so it is null.
        pub fn manipulation(self: *const Self, element_id: Id) ?input.Manipulation {
            comptime requireFeature(.gestures, "manipulation()");
            _ = self;
            _ = element_id;
            return null;
        }

        fn requireFeature(comptime feature: std.meta.FieldEnum(Features), comptime api: []const u8) void {
            if (!@field(features, @tagName(feature))) @compileError("zui: " ++ api ++ " needs Config.features." ++ @tagName(feature) ++ " = true");
        }

        pub fn pressed(self: *const Self, element_id: Id) bool {
            return !element_id.isNone() and self.memory.input.isPressed(element_id.hash);
        }

        /// A press and a release on this element by the same pointer, or
        /// Enter or Space while it is focused.
        pub fn clicked(self: *const Self, element_id: Id) bool {
            return !element_id.isNone() and self.memory.input.isClicked(element_id.hash);
        }

        pub fn focused(self: *const Self, element_id: Id) bool {
            return !element_id.isNone() and self.memory.input.focus == element_id.hash;
        }

        /// Focus moves to `element_id` at the next `beginFrame`, which this
        /// requests.
        pub fn requestFocus(self: *Self, element_id: Id) void {
            self.memory.input.pending_focus = element_id.hash;
            self.requestFrame();
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

        /// The primary pointer relative to the element's top-left corner in
        /// the previous frame.
        pub fn pointerLocal(self: *const Self, element_id: Id) ?[2]f32 {
            const pointer = self.primaryPointer() orelse return null;
            const rect = self.rectOf(element_id) orelse return null;
            return .{ pointer.position[0] - rect.x, pointer.position[1] - rect.y };
        }

        /// The mouse, or the first touch still down.
        pub fn primaryPointer(self: *const Self) ?input.Pointer {
            return self.memory.input.primaryPointer();
        }

        pub fn keyPressed(self: *const Self, key: input.Key) bool {
            return self.memory.input.keyPressed(key);
        }

        pub fn chordPressed(self: *const Self, chord: input.Chord) bool {
            return self.memory.input.chordPressed(chord);
        }

        /// This frame's key presses in the order they happened, for
        /// widgets where order matters (Home then Right is not Right then Home).
        pub fn keyEvents(self: *const Self) []const input.KeyEvent {
            const input_state = &self.memory.input;
            return input_state.key_events[0..input_state.key_event_count];
        }

        /// Text committed this frame.
        pub fn typedText(self: *const Self) []const u8 {
            const input_state = &self.memory.input;
            return input_state.text[0..input_state.text_len];
        }

        /// Files dropped onto the surface this frame, in the order they
        /// were dropped. Hit-test a drop's position with `rectOf` to find
        /// the element it landed on.
        pub fn filesDropped(self: *const Self) []const input.FilesDropped {
            const input_state = &self.memory.input;
            return input_state.drops[0..input_state.drop_count];
        }

        /// What the OS reported about the application's life this frame.
        ///
        /// ```zig
        /// if (ui.lifecycle().contains(.terminate_requested)) app.saveDraft();
        /// ```
        pub fn lifecycle(self: *const Self) input.LifecycleSet {
            return self.memory.input.lifecycle;
        }

        // =============================================================
        // Persistent state
        // =============================================================

        /// State for `element_id` that survives across frames while the id
        /// keeps being used. Created zeroed. If the table is full, returns
        /// zeroed scratch memory and reports `.state_slots`.
        pub fn state(self: *Self, element_id: Id, comptime T: type) *T {
            if (self.memory.states.get(element_id.hash, T, self.stateGeneration(), .create)) |slot| return slot;
            if (self.current) |frame| {
                frame.diagnostics.exceeded.insert(.state_slots);
                frame.diagnostics.needed.set(.state_slots, limits.state_slots + 1);
            }
            return self.memory.states.scratch(T);
        }

        pub fn stateIfPresent(self: *Self, element_id: Id, comptime T: type) ?*T {
            return self.memory.states.get(element_id.hash, T, self.stateGeneration(), .existing_only);
        }

        pub fn scrollOffset(self: *Self, element_id: Id) [2]f32 {
            const offset = self.stateIfPresent(element_id, interaction.ScrollState) orelse return .{ 0, 0 };
            return offset.offset;
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
    const limits = config.limits;
    for ([_]Limit{ .state_slots, .measure_cache_entries, .string_cache_entries }) |limit| {
        const value = @field(limits, @tagName(limit));
        if (!std.math.isPowerOfTwo(value)) @compileError(std.fmt.comptimePrint("zui: limits.{t} must be a power of two, got {d}", .{ limit, value }));
    }
    if (config.frames_in_flight < 1) @compileError("zui: frames_in_flight must be at least 1");
    if (limits.max_elements < 2) @compileError("zui: limits.max_elements must be at least 2 (zui's root plus one element)");
    if (limits.max_depth < 2) @compileError("zui: limits.max_depth must be at least 2 (zui's root plus one level)");
    if (limits.max_render_commands < 1) @compileError("zui: limits.max_render_commands must be at least 1");
    switch (@typeInfo(config.FontId)) {
        .int, .@"enum" => {},
        else => @compileError("zui: FontId must be an integer or enum type, got " ++ @typeName(config.FontId)),
    }
    if (config.commands.contains(.material) and config.MaterialHandle == void) @compileError("zui: commands includes .material but MaterialHandle is void");
}
