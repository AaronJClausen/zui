const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

/// Text measurement with the cost profile of a bitmap font: one table
/// lookup per byte.
pub const GlyphTableText = struct {
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

/// 4,096 boxes, depth 8, no text. 512 rows, each a chain of
/// 8 nested boxes with a mix of sizing rules, so nearly every element is a
/// parent: the most per-element work a tree of this size can ask for.
pub const BoxTree = struct {
    pub const name = "4096 boxes, depth 8";
    pub const layout_target_ns: ?u64 = 100 * std.time.ns_per_us;
    pub const declare_target_ns: ?u64 = 55 * std.time.ns_per_us;
    pub const limits: zui.Limits = .{ .max_elements = 4200, .max_render_commands = 8192 };

    pub fn declare(_: *BoxTree, ui: anytype, _: usize) void {
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

/// The box tree with each element's layout and decoration in one of 32
/// static styles, so declaration stores a reference and copies no config.
pub const StaticBoxTree = struct {
    pub const name = "4096 static-styled boxes";
    pub const layout_target_ns: ?u64 = null;
    pub const limits = BoxTree.limits;

    const styles = blk: {
        var by_sizing: [4][8]zui.Static(zui.Style) = undefined;
        for (0..4) |sizing_case| for (0..8) |depth| {
            const sizing: zui.Sizing2 = switch (sizing_case) {
                0 => .{ .width = .grow, .height = .fit },
                1 => .{ .width = .fit, .height = .fixed(2) },
                2 => .{ .width = .percent(0.9), .height = .fit },
                else => .{ .width = .{ .rule = .grow, .amount = 1, .min = 4, .max = 400 }, .height = .fit },
            };
            by_sizing[sizing_case][depth] = zui.static(zui.Style{
                .layout = .{ .sizing = sizing, .padding = .all(1), .child_gap = 1, .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom },
                .decoration = .{ .background = if (depth % 3 == 0) zui.Color.rgb(0x202030) else null },
            });
        };
        break :blk by_sizing;
    };
    const root_style = zui.static(zui.Style{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 1 } });

    pub fn declare(_: *StaticBoxTree, ui: anytype, _: usize) void {
        ui.open(.{ .style = root_style });
        for (0..512) |row| {
            for (0..8) |depth| ui.open(.{ .style = styles[(row + depth) % 4][depth] });
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
pub fn Sentences(comptime made_up_words: bool) type {
    return struct {
        const Self = @This();

        sentences: [1000][]const u8 = undefined,
        storage: [1000][64]u8 = undefined,
        prepared: bool = false,

        pub fn get(self: *Self) *const [1000][]const u8 {
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
pub fn declareTextWall(ui: anytype, sentences: *const [1000][]const u8, size: f32) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    for (0..100) |panel| {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(160) }, .padding = .all(4), .child_gap = 2 } });
        for (sentences[panel * 10 ..][0..10]) |sentence| ui.text(sentence, .{ .size = size });
        ui.close();
    }
    ui.close();
}

/// A different font size every frame, so every measurement misses the cache.
pub fn coldSize(frame_index: usize) f32 {
    return 14 + @as(f32, @floatFromInt(frame_index % 1024)) / 128;
}

/// Room in both caches for every string and word, so the warm scenes are warm.
pub const text_limits: zui.Limits = .{ .max_elements = 1200, .max_render_commands = 8192, .max_text_bytes = 64 * 1024, .string_cache_entries = 2048 };

/// 1,000 text elements averaging 40 characters, all measurements cached.
pub const TextWall = struct {
    pub const name = "1000 texts, warm cache";
    pub const limits = text_limits;
    pub const layout_target_ns: ?u64 = 120 * std.time.ns_per_us;
    sentences: Sentences(false) = .{},

    pub fn declare(self: *TextWall, ui: anytype, _: usize) void {
        declareTextWall(ui, self.sentences.get(), 16);
    }
};

pub const TextWallCold = struct {
    pub const name = "1000 texts, cold cache";
    pub const limits = text_limits;
    pub const layout_target_ns: ?u64 = null;
    sentences: Sentences(false) = .{},

    pub fn declare(self: *TextWallCold, ui: anytype, frame_index: usize) void {
        declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
    }
};

/// The warm text wall's sentences in panels 480 units wide, so every text
/// fits on one line: the cost of labels. Its limits differ from
/// `text_limits` so that its `Context` is a type of its own, and the text
/// wall's declaration keeps its code.
pub const SingleLineTexts = struct {
    pub const name = "1000 single-line texts, warm";
    pub const limits: zui.Limits = .{ .max_elements = 1200, .max_render_commands = 4096, .max_text_bytes = 64 * 1024, .string_cache_entries = 2048 };
    pub const layout_target_ns: ?u64 = null;
    sentences: Sentences(false) = .{},

    pub fn declare(self: *SingleLineTexts, ui: anytype, _: usize) void {
        const sentences = self.sentences.get();
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
        for (0..100) |panel| {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(480) }, .padding = .all(4), .child_gap = 2 } });
            for (sentences[panel * 10 ..][0..10]) |sentence| ui.text(sentence, .{ .size = 16 });
            ui.close();
        }
        ui.close();
    }
};

/// The warm text wall with the frame's number after every sentence, as in
/// "Frame 1234": every string is new each frame, and every word but the
/// number is cached. Its limits differ from `text_limits` for the same
/// reason as `SingleLineTexts`'.
pub const ChangingTexts = struct {
    pub const name = "1000 new strings, warm words";
    pub const limits: zui.Limits = .{ .max_elements = 1200, .max_render_commands = 8192, .max_text_bytes = 80 * 1024 };
    pub const layout_target_ns: ?u64 = null;
    sentences: Sentences(false) = .{},
    numbered: [1000][64]u8 = undefined,

    pub fn declare(self: *ChangingTexts, ui: anytype, frame_index: usize) void {
        const sentences = self.sentences.get();
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
        for (0..100) |panel| {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(160) }, .padding = .all(4), .child_gap = 2 } });
            for (sentences[panel * 10 ..][0..10], self.numbered[panel * 10 ..][0..10]) |sentence, *buffer| {
                ui.text(std.fmt.bufPrint(buffer, "{s} {d}", .{ sentence, frame_index }) catch unreachable, .{ .size = 16 });
            }
            ui.close();
        }
        ui.close();
    }
};

pub const DeepTree = struct {
    pub const name = "depth 64";
    pub const layout_target_ns: ?u64 = null;
    pub const limits: zui.Limits = .{ .max_elements = 128, .max_depth = 80 };

    pub fn declare(_: *DeepTree, ui: anytype, _: usize) void {
        for (0..64) |depth| ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fit }, .padding = .all(1), .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        for (0..64) |_| ui.close();
    }
};

pub const WideTree = struct {
    pub const name = "4000 children of one parent";
    pub const layout_target_ns: ?u64 = null;
    pub const limits: zui.Limits = .{ .max_elements = 4100, .max_render_commands = 8192 };

    pub fn declare(_: *WideTree, ui: anytype, _: usize) void {
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
pub const DocumentsView = struct {
    pub const name = "documents view";
    pub const layout_target_ns: ?u64 = null;
    pub const limits: zui.Limits = .{ .max_elements = 4096 };

    const panel: zui.Color = .rgb(0x20202a);
    const border: zui.Color = .rgb(0x34344a);
    const accent: zui.Color = .rgb(0x5b8cff);
    const focus_ring: zui.Color = .rgb(0xffc65c);
    const text_color: zui.Color = .rgb(0xe8e8f0);
    const muted_text_color: zui.Color = .rgb(0x9a9aae);

    pub fn declare(_: *DocumentsView, ui: anytype, _: usize) void {
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

/// A source whose producer has published nothing: its swap is one atomic
/// load, as `zui_async.Latest`'s is.
pub const IdleSource = struct {
    pub const Delivery = ?u64;
    pub const View = ?u64;

    fresh: std.atomic.Value(bool) = .init(false),
    published: u64 = 0,
    front: ?u64 = null,
    received: ?u64 = null,

    pub fn zuiSwap(self: *IdleSource) void {
        self.received = null;
        if (!self.fresh.load(.acquire)) return;
        self.front = self.published;
        self.received = self.published;
        self.fresh.store(false, .release);
    }

    pub fn zuiView(self: *IdleSource) View {
        return self.front;
    }

    pub fn zuiDelivery(self: *const IdleSource, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *IdleSource, delivery: *const Delivery) void {
        if (delivery.*) |value| self.front = value;
    }

    pub fn zuiPending(self: *const IdleSource) bool {
        return self.fresh.load(.acquire);
    }
};

/// `DeepTree`, reading ten sources that receive nothing: what sources cost
/// a frame when no data arrives, against `DeepTree` alone. A scene without
/// formatting, so instantiating it twice changes no other scene's code.
pub const DeepTreeWithIdleSources = struct {
    pub const name = "depth 64, 10 idle sources";
    pub const layout_target_ns: ?u64 = null;
    pub const limits = DeepTree.limits;
    pub const Sources = struct {
        battery: IdleSource = .{},
        network: IdleSource = .{},
        sync_state: IdleSource = .{},
        unread_count: IdleSource = .{},
        clock: IdleSource = .{},
        download_progress: IdleSource = .{},
        search_results: IdleSource = .{},
        notifications: IdleSource = .{},
        presence: IdleSource = .{},
        quotes: IdleSource = .{},
    };

    tree: DeepTree = .{},

    pub fn declare(self: *DeepTreeWithIdleSources, ui: anytype, frame_index: usize) void {
        const SourceField = @TypeOf(ui.*).SourceField;
        inline for (std.meta.fields(Sources)) |field| {
            if (ui.source(@field(SourceField, field.name)) != null) ui.requestFrame();
        }
        self.tree.declare(ui, frame_index);
    }
};

/// `DeepTree`, reading ten of `zui_async`'s sources that receive nothing,
/// one key of each `KeyedLoads` included: what the default sources cost a
/// frame when no data arrives.
pub const DeepTreeWithIdleAsyncSources = struct {
    pub const name = "depth 64, 10 idle zui_async sources";
    pub const layout_target_ns: ?u64 = null;
    pub const limits = DeepTree.limits;
    pub const Sources = struct {
        battery: zui_async.Latest(f32) = .{},
        network: zui_async.Latest(u32) = .{},
        sync_state: zui_async.Latest(u8) = .{},
        clock: zui_async.Latest(u64) = .{},
        quotes: zui_async.Stream(u64, .{ .capacity = 64, .producers = .many }) = .{},
        log_lines: zui_async.Stream(u32, .{ .capacity = 64 }) = .{},
        catalog: zui_async.Task(error{Offline}!u64, .{ .Progress = f32 }) = .{},
        sync: zui_async.Task(u32, .{}) = .{},
        thumbnails: zui_async.KeyedLoads(u64, u64, .{ .capacity = 64 }) = .{},
        search_results: zui_async.KeyedLoads(u64, u32, .{ .capacity = 64, .Progress = f32 }) = .{},
    };

    tree: DeepTree = .{},

    pub fn declare(self: *DeepTreeWithIdleAsyncSources, ui: anytype, frame_index: usize) void {
        var heard: u64 = 0;
        heard += @intFromBool(ui.source(.battery).get() != null);
        heard += @intFromBool(ui.source(.network).get() != null);
        heard += @intFromBool(ui.source(.sync_state).get() != null);
        heard += @intFromBool(ui.source(.clock).get() != null);
        heard += ui.source(.quotes).count();
        heard += ui.source(.log_lines).count();
        heard += @intFromBool(ui.source(.catalog).status() != .idle);
        heard += @intFromBool(ui.source(.sync).status() != .idle);
        heard += @intFromBool(ui.source(.thumbnails).get(1) != .idle);
        heard += @intFromBool(ui.source(.search_results).get(2) != .idle);
        if (heard != 0) ui.requestFrame();
        self.tree.declare(ui, frame_index);
    }
};
