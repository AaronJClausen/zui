//! ```sh
//! zig build bench                                  # print the tables
//! zig build bench -- --check-targets               # fail if a SPEC.md §20.2 budget is missed
//! zig build bench -- --json results.json           # save each scenario's fastest declaration and layout
//! zig build bench -- --compare baseline.json       # fail on a >10% regression
//! ```

const std = @import("std");
const zui = @import("zui");
const Io = std.Io;

/// Text measurement with the cost profile of a bitmap font: one table
/// lookup per byte.
const GlyphTableText = struct {
    advances: [256]f32 = blk: {
        var table: [256]f32 = undefined;
        for (&table, 0..) |*advance, byte| advance.* = 6 + @as(f32, @floatFromInt(byte % 5));
        break :blk table;
    },

    pub fn zuiMeasure(self: *GlyphTableText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        var width: f32 = 0;
        for (text) |byte| width += self.advances[byte] + key.letter_spacing;
        return .{ width * key.size / 16, key.size };
    }
};

/// Text measurement with the cost profile of a shaping engine: about a
/// microsecond for a short word.
fn ShapingText(comptime thread_safe: bool) type {
    return struct {
        const Self = @This();
        pub const zui_thread_safe = thread_safe;
        const rounds_per_byte = 160;

        pub fn zuiMeasure(_: *Self, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
            var state: u64 = 0x9e3779b97f4a7c15;
            for (text) |byte| {
                for (0..rounds_per_byte) |_| state = (state ^ byte) *% 0x100000001b3;
            }
            std.mem.doNotOptimizeAway(state);
            return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
        }
    };
}

const Measurement = struct {
    name: []const u8,
    elements: u32,
    /// `beginFrame` and the scene's `open`/`close` calls: everything before `endFrame`.
    declare_min_ns: u64,
    declare_median_ns: u64,
    /// Layout and emission: the time `endFrame` takes.
    layout_min_ns: u64,
    layout_median_ns: u64,
    /// Declaration, layout and emission together.
    frame_median_ns: u64,
    layout_target_ns: ?u64 = null,
    declare_target_ns: ?u64 = null,
    measure_calls_per_frame: f64,
};

const max_timed_frames = 400;

fn Scenario(comptime limits: zui.Limits, comptime Text: type, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(.{ .limits = limits, .Text = Text });

        /// Times `frame_count` frames after `warmup_frames`, in a fresh
        /// Context whose allocator counts every call after `init`.
        fn run(io: Io, gpa: std.mem.Allocator, warmup_frames: usize, frame_count: usize) !Measurement {
            var text: Text = .{};
            var counting: CountingAllocator = .{ .backing = gpa };
            var ui = try Ui.init(counting.allocator(), io, &text);
            defer ui.deinit(counting.allocator());
            const allocations_after_init = counting.allocations;

            var scene: Scene = .{};
            for (0..warmup_frames) |index| {
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
                scene.declare(&ui, index);
                ui.release(ui.endFrame());
            }

            var element_count: u32 = 0;
            var declare_times: [max_timed_frames]u64 = undefined;
            var layout_times: [max_timed_frames]u64 = undefined;
            var frame_times: [max_timed_frames]u64 = undefined;
            const calls_before = ui.measureCalls();
            for (0..frame_count) |index| {
                const frame_start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
                scene.declare(&ui, warmup_frames + index);
                const layout_start = Io.Timestamp.now(io, .awake);
                const frame = ui.endFrame();
                const end = Io.Timestamp.now(io, .awake);
                element_count = frame.elementCount();
                ui.release(frame);
                declare_times[index] = @intCast(frame_start.durationTo(layout_start).nanoseconds);
                layout_times[index] = @intCast(layout_start.durationTo(end).nanoseconds);
                frame_times[index] = @intCast(frame_start.durationTo(end).nanoseconds);
            }
            const calls = ui.measureCalls() - calls_before;
            if (counting.allocations != allocations_after_init) return error.FramesAllocated;

            std.mem.sortUnstable(u64, declare_times[0..frame_count], {}, std.sort.asc(u64));
            std.mem.sortUnstable(u64, layout_times[0..frame_count], {}, std.sort.asc(u64));
            std.mem.sortUnstable(u64, frame_times[0..frame_count], {}, std.sort.asc(u64));
            return .{
                .name = Scene.name,
                .elements = element_count,
                .declare_min_ns = declare_times[0],
                .declare_median_ns = declare_times[frame_count / 2],
                .layout_min_ns = layout_times[0],
                .layout_median_ns = layout_times[frame_count / 2],
                .frame_median_ns = frame_times[frame_count / 2],
                .layout_target_ns = Scene.layout_target_ns,
                .declare_target_ns = if (@hasDecl(Scene, "declare_target_ns")) Scene.declare_target_ns else null,
                .measure_calls_per_frame = @as(f64, @floatFromInt(calls)) / @as(f64, @floatFromInt(frame_count)),
            };
        }
    };
}

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// 4,096 boxes, depth 8, no text. 512 rows, each a chain of
/// 8 nested boxes with a mix of sizing rules, so nearly every element is a
/// parent: the most per-element work a tree of this size can ask for.
const BoxTree = struct {
    const name = "4096 boxes, depth 8";
    const layout_target_ns: ?u64 = 100 * std.time.ns_per_us;
    const declare_target_ns: ?u64 = 55 * std.time.ns_per_us;
    const limits: zui.Limits = .{ .max_elements = 4200, .max_render_commands = 8192 };

    fn declare(_: *BoxTree, ui: anytype, _: usize) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 1 } });
        for (0..512) |row| {
            for (0..8) |depth| {
                const sizing: zui.Sizing2 = switch ((row + depth) % 4) {
                    0 => .{ .width = .grow, .height = .fit },
                    1 => .{ .width = .fit, .height = .fixed(2) },
                    2 => .{ .width = .percent(0.9), .height = .fit },
                    else => .{ .width = .{ .rule = .grow, .amount = 1, .min = 4, .max = 400 }, .height = .fit },
                };
                ui.open(.{
                    .layout = .{ .sizing = sizing, .padding = .all(1), .child_gap = 1, .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom },
                    .decoration = .{
                        .background = if (depth % 3 == 0) zui.Color.rgb(0x202030) else null,
                    },
                });
            }
            for (0..8) |_| ui.close();
        }
        ui.close();
    }
};

const vocabulary = [_][]const u8{
    "layout", "frame",  "render", "measure", "text",   "zig",      "comptime", "element", "panel",  "button",
    "slider", "scroll", "focus",  "hover",   "click",  "window",   "widget",   "cache",   "word",   "line",
    "the",    "a",      "of",     "and",     "to",     "in",       "is",       "for",     "with",   "on",
    "every",  "nested", "fast",   "small",   "simple", "explicit", "memory",   "arena",   "thread", "task",
};

/// 1,000 sentences of about 40 characters, from `vocabulary` or, with
/// `made_up_words`, from random words that rarely repeat.
fn Sentences(comptime made_up_words: bool) type {
    return struct {
        const Self = @This();

        sentences: [1000][]const u8 = undefined,
        storage: [1000][64]u8 = undefined,
        prepared: bool = false,

        fn get(self: *Self) *const [1000][]const u8 {
            if (self.prepared) return &self.sentences;
            var prng: std.Random.DefaultPrng = .init(0x5eed);
            const random = prng.random();
            for (&self.sentences, &self.storage) |*sentence, *bytes| {
                var length: usize = 0;
                const target_length = 40 + random.uintLessThan(usize, 8);
                while (true) {
                    var made_up: [9]u8 = undefined;
                    const word = if (made_up_words) blk: {
                        const word_length = 3 + random.uintLessThan(usize, 7);
                        for (made_up[0..word_length]) |*byte| byte.* = 'a' + random.uintLessThan(u8, 26);
                        break :blk made_up[0..word_length];
                    } else vocabulary[random.uintLessThan(usize, vocabulary.len)];
                    if (length + word.len + 1 > target_length) break;
                    if (length != 0) {
                        bytes[length] = ' ';
                        length += 1;
                    }
                    @memcpy(bytes[length..][0..word.len], word);
                    length += word.len;
                }
                sentence.* = bytes[0..length];
            }
            self.prepared = true;
            return &self.sentences;
        }
    };
}

/// 1,000 texts in 100 panels 160 units wide, so most wrap.
fn declareTextWall(ui: anytype, sentences: *const [1000][]const u8, size: f32) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    for (0..100) |panel| {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(160) }, .padding = .all(4), .child_gap = 2 } });
        for (sentences[panel * 10 ..][0..10]) |sentence| ui.text(sentence, .{ .size = size });
        ui.close();
    }
    ui.close();
}

/// A different font size every frame, so every measurement misses the cache.
fn coldSize(frame_index: usize) f32 {
    return 14 + @as(f32, @floatFromInt(frame_index % 1024)) / 128;
}

const text_limits: zui.Limits = .{ .max_elements = 1200, .max_render_commands = 8192, .max_text_bytes = 64 * 1024 };

/// 1,000 text elements averaging 40 characters, all measurements cached.
const TextWall = struct {
    const name = "1000 texts, warm cache";
    const layout_target_ns: ?u64 = 120 * std.time.ns_per_us;
    sentences: Sentences(false) = .{},

    fn declare(self: *TextWall, ui: anytype, _: usize) void {
        declareTextWall(ui, self.sentences.get(), 16);
    }
};

const TextWallCold = struct {
    const name = "1000 texts, cold cache";
    const layout_target_ns: ?u64 = null;
    sentences: Sentences(false) = .{},

    fn declare(self: *TextWallCold, ui: anytype, frame_index: usize) void {
        declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
    }
};

const DeepTree = struct {
    const name = "depth 64";
    const layout_target_ns: ?u64 = null;
    const limits: zui.Limits = .{ .max_elements = 128, .max_depth = 80 };

    fn declare(_: *DeepTree, ui: anytype, _: usize) void {
        for (0..64) |depth| ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fit }, .padding = .all(1), .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        for (0..64) |_| ui.close();
    }
};

const WideTree = struct {
    const name = "4000 children of one parent";
    const layout_target_ns: ?u64 = null;
    const limits: zui.Limits = .{ .max_elements = 4100, .max_render_commands = 8192 };

    fn declare(_: *WideTree, ui: anytype, _: usize) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 1 } });
        for (0..4000) |index| ui.box(.{
            .layout = .{ .sizing = .{ .width = if (index % 2 == 0) .grow else .fixed(1), .height = .fixed(8) } },
            .decoration = .{
                .background = .rgb(0x303040),
            },
        });
        ui.close();
    }
};

/// The zui-raylib demo's Documents view, declared by hand without
/// zui_widgets: a toolbar, a sidebar of 40 documents and a text panel.
/// About 100 small elements, most with ids, a decoration and a label.
const DocumentsView = struct {
    const name = "documents view";
    const layout_target_ns: ?u64 = null;
    const limits: zui.Limits = .{ .max_elements = 4096 };

    const panel: zui.Color = .rgb(0x20202a);
    const border: zui.Color = .rgb(0x34344a);
    const accent: zui.Color = .rgb(0x5b8cff);
    const focus_ring: zui.Color = .rgb(0xffc65c);
    const text_color: zui.Color = .rgb(0xe8e8f0);
    const muted_text_color: zui.Color = .rgb(0x9a9aae);

    fn declare(_: *DocumentsView, ui: anytype, _: usize) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = .rgb(0x16161c) } });
        declareToolbar(ui);
        ui.open(.{ .layout = .{ .sizing = .grow_both } });
        declareSidebar(ui);
        declareMainPanel(ui);
        ui.close();
        ui.close();
    }

    fn button(ui: anytype, id: zui.Id, content: []const u8) void {
        ui.open(.{
            .id = id,
            .focusable = true,
            .decoration = .{
                .background = if (ui.widgetState(id) == .hovered) border else panel,
                .border = if (ui.focused(id)) .{ .color = focus_ring, .widths = .all(2) } else null,
                .corner_radius = .all(6),
            },
            .layout = .{ .sizing = .{ .height = .fixed(38) }, .padding = .symmetric(14, 0), .child_alignment = .{ .x = .center, .y = .center } },
        });
        ui.text(content, .{ .size = 20, .color = text_color });
        ui.close();
    }

    fn declareToolbar(ui: anytype) void {
        ui.open(.{
            .id = .of("toolbar"),
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(56) }, .padding = .symmetric(12, 8), .child_gap = 8, .child_alignment = .{ .y = .center } },
            .decoration = .{
                .background = panel,
                .border = .{ .color = border, .widths = .{ .bottom = 1 } },
            },
        });
        button(ui, .of("new"), "New");
        button(ui, .of("open"), "Open");
        button(ui, .of("save"), "Save");
        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
        button(ui, .of("documents_view"), "Documents");
        button(ui, .of("thumbnails_view"), "Thumbnails");
        button(ui, .of("settings_view"), "Settings");
        button(ui, .of("about"), "About");
        ui.close();
    }

    fn declareSidebar(ui: anytype) void {
        ui.open(.{
            .id = .of("sidebar"),
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(260), .height = .grow }, .padding = .all(8), .child_gap = 4 },
            .decoration = .{
                .background = .rgb(0x1a1a22),
            },
            .scroll = .{},
        });
        var name_buffer: [32]u8 = undefined;
        for (0..40) |index| {
            const id: zui.Id = .indexed("item", index);
            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(36) }, .padding = .symmetric(12, 8), .child_alignment = .{ .y = .center } },
                .decoration = .{
                    .background = if (index == 2) accent else if (state == .hovered or state == .pressed) border else null,
                    .corner_radius = .all(4),
                    .border = if (ui.focused(id)) .{ .color = focus_ring, .widths = .all(1) } else null,
                },
            });
            const document_name = std.fmt.bufPrint(&name_buffer, "Document {d}", .{index + 1}) catch unreachable;
            ui.text(document_name, .{ .size = 20, .color = text_color });
            ui.close();
        }
        ui.close();
    }

    fn declareMainPanel(ui: anytype) void {
        ui.open(.{ .id = .of("content"), .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(28), .child_gap = 18 } });
        ui.text("zui + raylib", .{ .size = 40, .color = text_color });
        ui.text("This window is laid out by zui and drawn by raylib. Every element is declared each frame as nested function calls; zui computes the layout and returns render commands, and the backend draws them.", .{ .size = 20, .color = muted_text_color });
        ui.open(.{ .layout = .{ .child_gap = 12, .child_alignment = .{ .y = .center } } });
        button(ui, .of("details_toggle"), "Show details");
        ui.open(.{ .id = .of("hover_me"), .interactive = true, .layout = .{ .padding = .symmetric(14, 8) }, .decoration = .{ .background = panel, .corner_radius = .all(6) } });
        ui.text("Hover me", .{ .size = 20, .color = text_color });
        ui.close();
        ui.close();
        ui.text("Clicks: 0   Last action: nothing yet   Selected: document 3", .{ .size = 20, .color = muted_text_color });
        ui.close();
    }
};

const shaping_limits: zui.Limits = .{
    .max_elements = 1200,
    .max_render_commands = 8192,
    .max_text_bytes = 64 * 1024,
    .measure_cache_entries = 16384,
    .parallel_measure_capacity = 8192,
};

/// Cold frames whose measurements cost about a microsecond
/// each, as with a shaping engine, measured on one thread and then across
/// the `Io`'s threads.
fn ShapedTextWall(comptime parallel: bool) type {
    return struct {
        const Self = @This();
        const name = if (parallel) "shaped text, parallel" else "shaped text, one thread";
        const layout_target_ns: ?u64 = null;
        sentences: Sentences(true) = .{},

        fn declare(self: *Self, ui: anytype, frame_index: usize) void {
            declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
        }
    };
}

/// Frames rendered on a second thread while the next one is
/// declared and laid out, against the same work on one thread.
fn framesPerSecond(io: Io, gpa: std.mem.Allocator, render_thread: bool) !f64 {
    const Ui = zui.Context(.{ .limits = text_limits, .Text = GlyphTableText });
    var text: GlyphTableText = .{};
    var ui = try Ui.init(gpa, io, &text);
    defer ui.deinit(gpa);
    var sentences: Sentences(false) = .{};

    const frame_count = 300;
    var queue_buffer: [2]*const Ui.Frame = undefined;
    var queue: Io.Queue(*const Ui.Frame) = .init(&queue_buffer);
    var renderer: ?Io.Future(void) = if (render_thread) try io.concurrent(renderFrames(Ui), .{ io, &ui, &queue }) else null;

    const start = Io.Timestamp.now(io, .awake);
    for (0..frame_count) |_| {
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
        declareTextWall(&ui, sentences.get(), 16);
        const frame = ui.endFrame();
        if (renderer != null) {
            queue.putOneUncancelable(io, frame) catch unreachable;
        } else {
            simulateRender(Ui, io, frame);
            ui.release(frame);
        }
    }
    if (renderer) |*running| {
        queue.close(io);
        running.await(io);
    }
    const elapsed_ns: f64 = @floatFromInt(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    return frame_count * std.time.ns_per_s / elapsed_ns;
}

fn renderFrames(comptime Ui: type) fn (Io, *Ui, *Io.Queue(*const Ui.Frame)) void {
    return struct {
        fn render(io: Io, ui: *Ui, queue: *Io.Queue(*const Ui.Frame)) void {
            while (queue.getOneUncancelable(io)) |frame| {
                simulateRender(Ui, io, frame);
                ui.release(frame);
            } else |_| {}
        }
    }.render;
}

/// A renderer that reads every command and then takes 200 µs, about as
/// long as declaring and laying out the frame. A clock-bounded wait rather
/// than arithmetic, which the optimizer is free to shorten.
fn simulateRender(comptime Ui: type, io: Io, frame: *const Ui.Frame) void {
    var checksum: f32 = 0;
    for (frame.commands()) |command| checksum += command.bounds.x;
    std.mem.doNotOptimizeAway(checksum);
    const start = Io.Timestamp.now(io, .awake);
    while (start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds < 200 * std.time.ns_per_us) {}
}

const StartupMeasurement = struct {
    name: []const u8,
    min_ns: u64,
    median_ns: u64,
};

const startup_samples = 50;

fn startupMeasurement(name: []const u8, times: *[startup_samples]u64) StartupMeasurement {
    std.mem.sortUnstable(u64, times, {}, std.sort.asc(u64));
    return .{ .name = name, .min_ns = times[0], .median_ns = times[startup_samples / 2] };
}

const DefaultUi = zui.Context(.{ .Text = GlyphTableText });

/// Each sample gets memory the process has never touched, so its page
/// faults are timed, as they are when an application starts.
fn timeInit(io: Io, gpa: std.mem.Allocator) !StartupMeasurement {
    var text: GlyphTableText = .{};
    var times: [startup_samples]u64 = undefined;
    for (&times) |*time| {
        const start = Io.Timestamp.now(io, .awake);
        var ui = try DefaultUi.init(gpa, io, &text);
        time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        ui.deinit(gpa);
    }
    return startupMeasurement("init, default config", &times);
}

var init_buffer: [DefaultUi.required_bytes]u8 align(DefaultUi.buffer_alignment) = undefined;

/// Only the first sample touches `init_buffer` for the first time, so this
/// is the time zui itself spends preparing memory.
fn timeInitBuffer(io: Io) !StartupMeasurement {
    var text: GlyphTableText = .{};
    var times: [startup_samples]u64 = undefined;
    for (&times) |*time| {
        const start = Io.Timestamp.now(io, .awake);
        var ui = try DefaultUi.initBuffer(&init_buffer, io, &text);
        // Nothing else reads `init_buffer`, so without this LLVM deletes
        // every write `initBuffer` makes to it, and the sample times nothing.
        std.mem.doNotOptimizeAway(&ui);
        time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        ui.deinit(undefined);
    }
    return startupMeasurement("initBuffer, default config", &times);
}

/// The first frame of each new `Context`: every measurement misses the
/// cache, and the frame's memory is touched for the first time.
fn FirstFrame(comptime name: []const u8, comptime limits: zui.Limits, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(.{ .limits = limits, .Text = GlyphTableText });

        fn run(io: Io, gpa: std.mem.Allocator) !StartupMeasurement {
            var text: GlyphTableText = .{};
            var scene: Scene = .{};
            if (@hasField(Scene, "sentences")) _ = scene.sentences.get();
            var times: [startup_samples]u64 = undefined;
            for (&times) |*time| {
                var counting: CountingAllocator = .{ .backing = gpa };
                var ui = try Ui.init(counting.allocator(), io, &text);
                defer ui.deinit(counting.allocator());
                const allocations_after_init = counting.allocations;

                const start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
                scene.declare(&ui, 0);
                const frame = ui.endFrame();
                time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
                ui.release(frame);
                if (counting.allocations != allocations_after_init) return error.FramesAllocated;
            }
            return startupMeasurement("first frame, " ++ name, &times);
        }
    };
}

const Options = struct {
    json_path: ?[]const u8 = null,
    compare_path: ?[]const u8 = null,
    check_targets: bool = false,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--json") and index + 1 < arguments.len) {
            index += 1;
            options.json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--compare") and index + 1 < arguments.len) {
            index += 1;
            options.compare_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--check-targets")) {
            options.check_targets = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --json <path>, --compare <path> or --check-targets\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn budgetText(buffer: []u8, fastest_ns: u64, budget_ns: ?u64, missed_any: *bool) []const u8 {
    const budget = budget_ns orelse return "";
    const met = fastest_ns <= budget;
    if (!met) missed_any.* = true;
    return std.fmt.bufPrint(buffer, "{s} {d:.0}us", .{ if (met) "ok" else "MISS", microseconds(budget) }) catch unreachable;
}

fn microseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_us;
}

/// The scenarios a regression check compares: the single-threaded ones,
/// whose times don't depend on what the machine's other cores are doing.
const compared_count = 6;
const regression_tolerance = 1.10;

/// One fastest time a regression check compares. The layout time keeps the
/// scenario's bare name, so it still matches baselines from before the
/// declaration time was recorded.
const ComparedTime = struct {
    key_buffer: [64]u8,
    key_len: usize,
    nanoseconds: u64,

    fn key(self: *const ComparedTime) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    fn init(comptime key_format: []const u8, name: []const u8, nanoseconds: u64) ComparedTime {
        var time: ComparedTime = .{ .key_buffer = undefined, .key_len = undefined, .nanoseconds = nanoseconds };
        time.key_len = (std.fmt.bufPrint(&time.key_buffer, key_format, .{name}) catch unreachable).len;
        return time;
    }
};

fn comparedTimes(measurements: []const Measurement, startup_measurements: []const StartupMeasurement, times: []ComparedTime) []const ComparedTime {
    var count: usize = 0;
    for (measurements) |measurement| {
        times[count] = .init("{s}", measurement.name, measurement.layout_min_ns);
        times[count + 1] = .init("{s}, declare", measurement.name, measurement.declare_min_ns);
        count += 2;
    }
    for (startup_measurements) |measurement| {
        times[count] = .init("{s}", measurement.name, measurement.min_ns);
        count += 1;
    }
    return times[0..count];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const options = try parseOptions(try init.minimal.args.toSlice(arena));

    const measurements = [_]Measurement{
        try Scenario(BoxTree.limits, GlyphTableText, BoxTree).run(io, gpa, 20, 400),
        try Scenario(text_limits, GlyphTableText, TextWall).run(io, gpa, 20, 400),
        try Scenario(text_limits, GlyphTableText, TextWallCold).run(io, gpa, 20, 400),
        try Scenario(DeepTree.limits, GlyphTableText, DeepTree).run(io, gpa, 20, 400),
        try Scenario(WideTree.limits, GlyphTableText, WideTree).run(io, gpa, 20, 400),
        try Scenario(DocumentsView.limits, GlyphTableText, DocumentsView).run(io, gpa, 20, 400),
        try Scenario(shaping_limits, ShapingText(false), ShapedTextWall(false)).run(io, gpa, 2, 20),
        try Scenario(shaping_limits, ShapingText(true), ShapedTextWall(true)).run(io, gpa, 2, 20),
    };
    const startup_measurements = [_]StartupMeasurement{
        try timeInit(io, gpa),
        try timeInitBuffer(io),
        try FirstFrame("documents view", DocumentsView.limits, DocumentsView).run(io, gpa),
        try FirstFrame("1000 texts", text_limits, TextWall).run(io, gpa),
    };
    const one_thread_rate = try framesPerSecond(io, gpa, false);
    const render_thread_rate = try framesPerSecond(io, gpa, true);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("{s:<28} {s:>8} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>8} {s:>14} {s:>14} {s:>9}\n", .{ "scenario", "elements", "declare min", "declare med", "layout min", "layout med", "frame med", "ns/elem", "declare budget", "layout budget", "measures" });
    var missed_target = false;
    for (measurements) |measurement| {
        const per_element = @as(f64, @floatFromInt(measurement.layout_min_ns)) / @as(f64, @floatFromInt(measurement.elements));
        var declare_budget_buffer: [32]u8 = undefined;
        var layout_budget_buffer: [32]u8 = undefined;
        const declare_budget = budgetText(&declare_budget_buffer, measurement.declare_min_ns, measurement.declare_target_ns, &missed_target);
        const layout_budget = budgetText(&layout_budget_buffer, measurement.layout_min_ns, measurement.layout_target_ns, &missed_target);
        try out.print("{s:<28} {d:>8} {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>8.1} {s:>14} {s:>14} {d:>9.0}\n", .{
            measurement.name,
            measurement.elements,
            microseconds(measurement.declare_min_ns),
            microseconds(measurement.declare_median_ns),
            microseconds(measurement.layout_min_ns),
            microseconds(measurement.layout_median_ns),
            microseconds(measurement.frame_median_ns),
            per_element,
            declare_budget,
            layout_budget,
            measurement.measure_calls_per_frame,
        });
    }
    const shaped_one_thread: f64 = @floatFromInt(measurements[compared_count].layout_median_ns);
    const shaped_parallel: f64 = @floatFromInt(measurements[compared_count + 1].layout_median_ns);
    try out.print("\nparallel measurement: {d:.2}x as fast as one thread\n", .{shaped_one_thread / shaped_parallel});
    try out.print("render thread: {d:.0} frames/s against {d:.0} on one thread ({d:.2}x)\n", .{ render_thread_rate, one_thread_rate, render_thread_rate / one_thread_rate });
    try out.writeAll("allocations after init: 0 in every scenario\n");

    try out.print("\n{s:<28} {s:>11} {s:>11}\n", .{ "startup", "min", "median" });
    for (startup_measurements) |measurement| {
        try out.print("{s:<28} {d:>9.1}us {d:>9.1}us\n", .{ measurement.name, microseconds(measurement.min_ns), microseconds(measurement.median_ns) });
    }
    try out.print("init allocates {d:.2} MiB at the default config\n", .{@as(f64, @floatFromInt(DefaultUi.required_bytes)) / (1024 * 1024)});
    try out.flush();

    var compared_time_buffer: [2 * compared_count + startup_measurements.len]ComparedTime = undefined;
    const compared_times = comparedTimes(measurements[0..compared_count], &startup_measurements, &compared_time_buffer);
    if (options.json_path) |path| try writeJson(io, path, compared_times);
    const regressed = if (options.compare_path) |path| try compare(io, arena, out, path, compared_times) else false;
    try out.flush();
    if (regressed) return error.Regression;
    if (options.check_targets and missed_target) return error.TargetMissed;
}

fn writeJson(io: Io, path: []const u8, times: []const ComparedTime) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("{\n");
    for (times, 0..) |*time, index| {
        try writer.print("  \"{s}\": {d}{s}\n", .{ time.key(), time.nanoseconds, if (index + 1 < times.len) "," else "" });
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

/// Prints each time's change against the baseline and returns whether any
/// is more than 10% slower. A time missing from the baseline is new and
/// only printed.
fn compare(io: Io, arena: std.mem.Allocator, out: *Io.Writer, path: []const u8, times: []const ComparedTime) !bool {
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    const baseline = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(u64), arena, contents, .{});
    try out.writeAll("\nagainst the baseline (fastest frames):\n");
    var regressed = false;
    for (times) |*time| {
        const before = baseline.map.get(time.key()) orelse {
            try out.print("  {s:<37} new\n", .{time.key()});
            continue;
        };
        const ratio = @as(f64, @floatFromInt(time.nanoseconds)) / @as(f64, @floatFromInt(before));
        const slower = ratio > regression_tolerance;
        if (slower) regressed = true;
        try out.print("  {s:<37} {d:>9.1}us -> {d:>9.1}us  {s}{d:.1}%{s}\n", .{
            time.key(),
            microseconds(before),
            microseconds(time.nanoseconds),
            if (ratio >= 1) "+" else "",
            (ratio - 1) * 100,
            if (slower) "  REGRESSION" else "",
        });
    }
    return regressed;
}
