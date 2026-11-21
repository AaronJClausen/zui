//! An inspector over `Frame.inspect`: a panel listing the frame's
//! diagnostics and fallbacks, the time each zone took, the element tree
//! and the configs of the element under the pointer.
//!
//! ```zig
//! app.inspector.declare(ui); // last, so its panel floats over the rest
//! const frame = ui.endFrame();
//! app.inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
//! ```

const std = @import("std");
const zui = @import("zui");

/// What each zone took in one frame.
pub const ZoneTimes = struct {
    /// Summed over each time the zone ran.
    nanoseconds: std.EnumArray(zui.TraceZone, u64) = .initFill(0),
    ran: std.EnumSet(zui.TraceZone) = .initEmpty(),
};

/// A tracer for `Config.features.Tracer` that times each zone of a frame
/// for the inspector's performance overlay, and passes each zone on to
/// `Inner`, another tracer such as `zui_tracy.Tracer`, or to nothing when
/// `Inner` is `void`. No zone is timed until `useClock` is given an `Io`.
///
/// ```zig
/// const Timer = zui_debug.ZoneTimer(zui_tracy.Tracer);
/// const Ui = zui.Context(.{ .Text = Fonts, .features = .{ .Tracer = Timer } });
///
/// Timer.useClock(io);
/// ```
pub fn ZoneTimer(comptime Inner: type) type {
    const inner_is_tracer = Inner == void or (@typeInfo(Inner) == .@"struct" and @hasDecl(Inner, "zuiBegin") and @hasDecl(Inner, "zuiEnd"));
    if (!inner_is_tracer) @compileError("zui_debug: ZoneTimer passes its zones on to a tracer or to void, got " ++ @typeName(Inner));
    return struct {
        const InnerSpan = if (Inner == void) void else @TypeOf(Inner.zuiBegin(zui.TraceZone.begin_frame));

        var clock: ?std.Io = null;
        threadlocal var frame_times: ZoneTimes = .{};

        /// A zone begun, and when, if a clock was in use.
        pub const Span = struct {
            zone: zui.TraceZone,
            started: ?std.Io.Timestamp,
            inner: InnerSpan,
        };

        /// Times every zone from now on with `io`'s monotonic clock. Call it
        /// before the first frame, or on the thread that runs the frames.
        pub fn useClock(io: std.Io) void {
            clock = io;
        }

        /// The zones this thread has timed since its last `begin_frame`
        /// began: after `endFrame`, the whole frame's.
        pub fn frameTimes() ZoneTimes {
            return frame_times;
        }

        /// Starts `zone`'s time and `Inner`'s zone; a `begin_frame` starts
        /// the frame's times afresh.
        pub fn zuiBegin(comptime zone: zui.TraceZone) Span {
            if (zone == .begin_frame) frame_times = .{};
            const inner = if (Inner == void) {} else Inner.zuiBegin(zone);
            return .{ .zone = zone, .started = if (clock) |io| std.Io.Timestamp.now(io, .awake) else null, .inner = inner };
        }

        /// Adds the zone's time to the frame's and ends `Inner`'s zone.
        pub fn zuiEnd(span: Span) void {
            if (span.started) |started| {
                const elapsed = started.durationTo(std.Io.Timestamp.now(clock.?, .awake)).nanoseconds;
                const time = frame_times.nanoseconds.getPtr(span.zone);
                time.* +|= std.math.lossyCast(u64, elapsed);
                frame_times.ran.insert(span.zone);
            }
            if (Inner != void) Inner.zuiEnd(span.inner);
        }
    };
}

/// The zone times of the last `frames_kept` frames recorded.
pub const ZoneHistory = struct {
    /// About a second of frames at 60 Hz.
    pub const frames_kept = 60;

    frames: [frames_kept]ZoneTimes = @splat(.{}),
    count: u8 = 0,
    next: u8 = 0,

    /// Keeps `times` in place of the oldest frame once `frames_kept` are kept.
    pub fn record(self: *ZoneHistory, times: ZoneTimes) void {
        self.frames[self.next] = times;
        self.next = (self.next + 1) % frames_kept;
        self.count = @min(self.count + 1, frames_kept);
    }

    /// The frames kept, in no particular order.
    pub fn kept(self: *const ZoneHistory) []const ZoneTimes {
        return self.frames[0..self.count];
    }

    /// The frame recorded last.
    pub fn latest(self: *const ZoneHistory) ?*const ZoneTimes {
        if (self.count == 0) return null;
        return &self.frames[(self.next + frames_kept - 1) % frames_kept];
    }

    /// Whether `zone` ran in any frame kept.
    pub fn ran(self: *const ZoneHistory, zone: zui.TraceZone) bool {
        for (self.kept()) |*times| if (times.ran.contains(zone)) return true;
        return false;
    }

    /// The mean time of `zone` over the frames kept in which it ran.
    pub fn mean(self: *const ZoneHistory, zone: zui.TraceZone) u64 {
        var total: u64 = 0;
        var frames_ran: u64 = 0;
        for (self.kept()) |*times| if (times.ran.contains(zone)) {
            total +|= times.nanoseconds.get(zone);
            frames_ran += 1;
        };
        return if (frames_ran == 0) 0 else total / frames_ran;
    }

    /// The longest `zone` took in a frame kept.
    pub fn peak(self: *const ZoneHistory, zone: zui.TraceZone) u64 {
        var longest: u64 = 0;
        for (self.kept()) |*times| longest = @max(longest, times.nanoseconds.get(zone));
        return longest;
    }
};

/// A theme file, and the directory whose file watch names its changes.
pub const ThemeFile = struct {
    directory: std.Io.Dir,
    /// Relative to `directory` and `/`-separated, as `zui.FileChange`
    /// names it.
    name: []const u8,
};

/// Why a theme file did not load; the panel keeps the theme it has.
pub const LoadThemeError = std.Io.Dir.ReadFileError || error{
    /// Longer than `max_theme_file_bytes`.
    ThemeFileTooLarge,
    /// Not a theme in ZON, or one too large to parse in the loader's memory.
    ParseZon,
    OutOfMemory,
};

/// The longest theme file `PanelTheme.read` takes.
pub const max_theme_file_bytes = 2048;
const theme_parse_memory_bytes = 32 * 1024;

/// How the inspector's panel looks, in a context's `FontId` and `Color`;
/// `font` and `text_size` apply to every line. It does not name the
/// context, so a `zui_async.Latest` of it can be one of that context's
/// sources.
pub fn PanelTheme(comptime FontId: type, comptime Color: type) type {
    return struct {
        const Self = @This();

        width: f32 = 360,
        font: FontId = std.mem.zeroes(FontId),
        text_size: f32 = 12,
        text: Color = .rgb(0xd4d4d4),
        heading: Color = .rgb(0x9cdcfe),
        background: Color = .rgba(0x1e1e1ef0),
        hovered_row: Color = .rgb(0x264f78),

        /// The theme as a ZON file writes it: each color as `0xrrggbbaa`,
        /// and a field left out keeps its default.
        ///
        /// ```zig
        /// .{ .width = 420, .background = 0x101010e0, .heading = 0xffcc66ff }
        /// ```
        pub const Zon = zon: {
            const fields = @typeInfo(Self).@"struct".fields;
            var names: [fields.len][]const u8 = undefined;
            var types: [fields.len]type = undefined;
            var attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
            for (fields, &names, &types, &attributes) |field, *name, *Type, *attribute| {
                name.* = field.name;
                if (field.type == Color) {
                    Type.* = u32;
                    attribute.* = .{ .default_value_ptr = &@as(u32, rgbaHexOf(field.defaultValue().?)) };
                } else {
                    Type.* = field.type;
                    attribute.* = .{ .default_value_ptr = field.default_value_ptr };
                }
            }
            break :zon @Struct(.auto, null, &names, &types, &attributes);
        };

        /// The theme a file's `Zon` names, its colors in `Color`.
        pub fn fromZon(zon: Zon) Self {
            var theme: Self = undefined;
            inline for (@typeInfo(Self).@"struct".fields) |field| {
                const written = @field(zon, field.name);
                @field(theme, field.name) = if (field.type == Color) .rgba(written) else written;
            }
            return theme;
        }

        /// Reads and parses `file`, with no allocation: the file and its
        /// parse fit in fixed memory on the stack.
        pub fn read(io: std.Io, file: ThemeFile) LoadThemeError!Self {
            var source: [max_theme_file_bytes + 2]u8 = undefined;
            const bytes = try file.directory.readFile(io, file.name, source[0 .. max_theme_file_bytes + 1]);
            if (bytes.len > max_theme_file_bytes) return error.ThemeFileTooLarge;
            source[bytes.len] = 0;
            var parse_memory: [theme_parse_memory_bytes]u8 = undefined;
            var parse_allocator: std.heap.FixedBufferAllocator = .init(&parse_memory);
            const zon = try std.zon.parse.fromSlice(Zon, parse_allocator.allocator(), source[0..bytes.len :0], null, .{});
            return .fromZon(zon);
        }

        fn rgbaHexOf(color: Color) u32 {
            const srgb: zui.Color = if (Color == zui.Color) color else color.toColor();
            return @as(u32, srgb.r) << 24 | @as(u32, srgb.g) << 16 | @as(u32, srgb.b) << 8 | srgb.a;
        }
    };
}

/// Whether `Tracer` keeps the frame's zone times, as `ZoneTimer` does.
fn timesZones(comptime Tracer: type) bool {
    return Tracer != void and @hasDecl(Tracer, "frameTimes") and @TypeOf(Tracer.frameTimes) == fn () ZoneTimes;
}

/// The inspector of a context of type `Ui`, which declares its panel into
/// that same context. It copies what it shows out of each frame it
/// observes, so the frame may be released at once. It holds a row for
/// every element the context can declare, so it belongs in the
/// application's state rather than on the stack.
pub fn Inspector(comptime Ui: type) type {
    if (!Ui.has_text) @compileError("zui_debug: Inspector needs a context with Config.Text, which draws its panel");
    return struct {
        const Self = @This();

        /// The name an id was made from, kept only in a `-Dzui-debug` build.
        pub const DebugName = @FieldType(Ui.ElementView, "name");
        const CustomData = @FieldType(Ui.ElementContent, "custom");
        const has_debug_names = DebugName != void;
        const Tracer = Ui.features.Tracer;
        /// Whether the context's tracer is a `ZoneTimer`, whose times the
        /// panel shows.
        pub const times_zones = timesZones(Tracer);
        const ZoneHistoryIfTimed = if (times_zones) ZoneHistory else void;
        const max_text_preview_bytes = 32;
        const max_line_bytes = 256;
        const max_indented_depth = 32;
        const max_run_report_bytes = 1024;

        /// How the panel looks, in this context's font and colors.
        pub const Theme = PanelTheme(Ui.FontId, Ui.Color);

        /// Where `declareWithThemeFrom` finds the panel's theme among the
        /// context's sources.
        pub const ThemeSources = struct {
            /// A `zui_async.Stream(zui.FileChange, ...)` that the host's
            /// file watch of `theme_file.directory` publishes into.
            file_changes: Ui.SourceField,
            /// A `zui_async.Latest(Theme)` that the loader publishes what
            /// `loadTheme` read into.
            theme: Ui.SourceField,
        };

        /// What an element holds. The root is told apart from other boxes.
        pub const Kind = enum { root, box, text, image, custom };

        /// One element of the observed tree.
        pub const Row = struct {
            id: u64,
            name: DebugName,
            explicit_id: bool,
            /// 0 for the root, 1 for its children, and so on.
            depth: u16,
            kind: Kind,
            size: [2]f32,
            text_preview_storage: [max_text_preview_bytes]u8,
            text_preview_len: u8,

            /// The start of a text element's bytes, cut at a codepoint.
            pub fn textPreview(self: *const Row) []const u8 {
                return self.text_preview_storage[0..self.text_preview_len];
            }

            fn writeName(self: *const Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                if (has_debug_names and self.name.len != 0) {
                    try writer.print("{s} ", .{self.name});
                } else if (self.explicit_id) {
                    try writer.print("0x{x:0>16} ", .{self.id});
                }
            }

            fn writeLabel(self: *const Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                if (self.kind != .root) try self.writeName(writer);
                try writer.writeAll(@tagName(self.kind));
                if (self.kind == .text) try writer.print(" \"{s}\"", .{self.textPreview()});
                try writer.print(" {d:.0}x{d:.0}", .{ self.size[0], self.size[1] });
            }
        };

        /// What the element under the pointer declared and how it was laid out.
        pub const Hovered = struct {
            row: Row,
            rect: zui.Rect,
            min_size: [2]f32,
            content_size: [2]f32,
            flags: zui.ElementFlags,
            layout: zui.Layout,
            decoration: ?Ui.Decoration,
            effects: ?Ui.Effects,
            floating: ?zui.Floating,
            content: Content,
        };

        /// A text element's bytes are in its row's `textPreview`.
        pub const Content = union(enum) {
            none,
            text: Ui.TextStyle,
            image: Ui.Image,
            custom: CustomData,
        };

        /// The panel's id unless `panel_id` is set, for an application that
        /// already uses this one.
        pub const default_panel_id: zui.Id = .of("zui_debug");

        /// Its subtree is left out of the tree, so the inspector never
        /// lists its own rows.
        panel_id: zui.Id = default_panel_id,
        theme: Theme = .{},
        /// The file `loadTheme` reads `theme` from, if any.
        theme_file: ?ThemeFile = null,
        /// Set by a change to `theme_file`, and true until it is first read.
        theme_file_changed: bool = true,
        row_storage: [Ui.max_elements]Row = undefined,
        row_count: u32 = 0,
        hovered: ?Hovered = null,
        hovered_row: ?u32 = null,
        /// The last observed frame's.
        diagnostics: zui.Diagnostics = .{},
        run_report_storage: [max_run_report_bytes]u8 = undefined,
        run_report_len: u16 = 0,
        /// The zone times of the frames observed, kept only when
        /// `times_zones`.
        zones: ZoneHistoryIfTimed = if (times_zones) .{} else {},

        /// The tree as last observed, in declaration order.
        pub fn rows(self: *const Self) []const Row {
            return self.row_storage[0..self.row_count];
        }

        /// Keeps `report` formatted with `{f}`, to list under the fallbacks
        /// what no frame says: what the host and renderer lack. Each part
        /// that `; ` separates gets a line, and what does not fit is cut.
        ///
        /// ```zig
        /// app.inspector.reportRun(session.report); // zui_app's Report
        /// ```
        pub fn reportRun(self: *Self, report: anytype) void {
            var writer: std.Io.Writer = .fixed(&self.run_report_storage);
            writer.print("{f}", .{report}) catch {};
            self.run_report_len = @intCast(withoutCutCodepoint(writer.buffered()).len);
        }

        /// What `reportRun` kept.
        pub fn runReport(self: *const Self) []const u8 {
            return self.run_report_storage[0..self.run_report_len];
        }

        /// Copies the diagnostics and the tree out of `frame`, and the
        /// element under `pointer`: the last in declaration order whose
        /// rectangle holds it, which is the innermost. While the pointer is
        /// over the panel, the element it showed stays, so the pointer can
        /// move there to read it. With a `ZoneTimer`, it also records the
        /// frame's zone times, so call it on the thread that ran the frame
        /// and before the next `beginFrame`.
        pub fn observe(self: *Self, frame: *const Ui.Frame, pointer: ?[2]f32) void {
            self.diagnostics = frame.diagnostics;
            if (times_zones) self.zones.record(Tracer.frameTimes());
            const panel_index = frame.lookup(self.panel_id.hash);
            const panel_rect: ?zui.Rect = if (panel_index) |index| frame.inspect(index).rect else null;
            const pointer_on_panel = pointer != null and panel_rect != null and panel_rect.?.contains(pointer.?);
            const hit_point = if (pointer_on_panel) null else pointer;

            var subtree_ends: [Ui.max_depth]u32 = undefined;
            var depth: u16 = 0;
            var hovered_index: ?Ui.Index = null;
            var hovered_row: ?u32 = null;
            self.row_count = 0;
            var index: u32 = 0;
            while (index < frame.elementCount()) {
                const element = frame.inspect(@intCast(index));
                if (panel_index != null and panel_index.? == index) {
                    index = element.subtree_end;
                    continue;
                }
                while (depth > 0 and index >= subtree_ends[depth - 1]) depth -= 1;
                self.row_storage[self.row_count] = rowOf(index, depth, element);
                if (hit_point) |point| if (element.rect.contains(point)) {
                    hovered_index = @intCast(index);
                    hovered_row = self.row_count;
                };
                self.row_count += 1;
                if (element.subtree_end > index + 1 and depth < subtree_ends.len) {
                    subtree_ends[depth] = element.subtree_end;
                    depth += 1;
                }
                index += 1;
            }

            if (pointer_on_panel) {
                if (self.hovered_row) |row| if (row >= self.row_count) {
                    self.hovered_row = null;
                };
                return;
            }
            self.hovered_row = hovered_row;
            self.hovered = if (hovered_index) |found| hoveredOf(frame.inspect(found), self.row_storage[hovered_row.?]) else null;
        }

        fn rowOf(index: u32, depth: u16, element: Ui.ElementView) Row {
            var row: Row = .{
                .id = element.id,
                .name = element.name,
                .explicit_id = element.flags.explicit_id,
                .depth = depth,
                .kind = if (index == 0) .root else switch (element.content) {
                    .none => .box,
                    .text => .text,
                    .image => .image,
                    .custom => .custom,
                },
                .size = .{ element.rect.width, element.rect.height },
                .text_preview_storage = undefined,
                .text_preview_len = 0,
            };
            if (element.content == .text) {
                const preview = wholeCodepoints(element.content.text.bytes, max_text_preview_bytes);
                @memcpy(row.text_preview_storage[0..preview.len], preview);
                row.text_preview_len = @intCast(preview.len);
            }
            return row;
        }

        fn hoveredOf(element: Ui.ElementView, row: Row) Hovered {
            return .{
                .row = row,
                .rect = element.rect,
                .min_size = element.min_size,
                .content_size = element.content_size,
                .flags = element.flags,
                .layout = element.layout.*,
                .decoration = if (element.decoration) |decoration| decoration.* else null,
                .effects = if (element.effects) |effects| effects.* else null,
                .floating = element.floating,
                .content = switch (element.content) {
                    .none => .none,
                    .text => |text| .{ .text = text.style },
                    .image => |image| .{ .image = image },
                    .custom => |custom| .{ .custom = custom },
                },
            };
        }

        /// Declares the panel, floating over the viewport's right edge, from
        /// what the last `observe` copied. Declared last, it floats over
        /// everything else.
        pub fn declare(self: *const Self, ui: *Ui) void {
            ui.open(.{
                .id = self.panel_id,
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .width = .fixed(self.theme.width), .height = .fixed(ui.viewport()[1]) },
                    .padding = .all(8),
                    .child_gap = 2,
                },
                .decoration = .{ .background = self.theme.background },
                .floating = .{ .attach_to = .root, .anchor = .top_right, .attach_point = .top_right, .z = std.math.maxInt(i16) },
                .clip = .both,
                .scroll = .{},
            });
            self.heading(ui, "Diagnostics");
            self.declareDiagnostics(ui);
            self.heading(ui, "Fallbacks");
            self.declareFallbacks(ui);
            self.heading(ui, "Performance");
            self.declarePerformance(ui);
            self.heading(ui, "Hovered");
            if (self.hovered) |*hovered| self.declareHovered(ui, hovered) else self.line(ui, "nothing under the pointer", .{});
            self.heading(ui, "Elements");
            for (self.rows(), 0..) |*row, row_index| {
                const is_hovered = self.hovered_row != null and self.hovered_row.? == row_index;
                if (is_hovered) ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } }, .decoration = .{ .background = self.theme.hovered_row } });
                self.line(ui, "{s}{f}", .{ indentation(row.depth), RowLabel{ .row = row } });
                if (is_hovered) ui.close();
            }
            ui.close();
        }

        /// `declare`, with the panel in the theme last published into
        /// `sources.theme`, which a replay delivers as the live run did.
        /// A change to `theme_file` among `sources.file_changes`, or a
        /// `.rescan`, has the next `loadTheme` read it again.
        ///
        /// ```zig
        /// const Sources = struct {
        ///     debug_theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 32 }) = .{},
        ///     debug_theme: zui_async.Latest(zui_debug.PanelTheme(u16, zui.Color)) = .{},
        /// };
        ///
        /// app.inspector.theme_file = .{ .directory = themes, .name = "debug.zon" };
        /// try Host.zuiFileWatch.watch(host, "themes", .of(&app.sources.debug_theme_files));
        /// // declaring, last:
        /// app.inspector.declareWithThemeFrom(ui, .{ .file_changes = .debug_theme_files, .theme = .debug_theme });
        /// // between frames:
        /// if (app.inspector.loadTheme(io)) |loaded| {
        ///     if (loaded) |theme| waker.wakeIf(app.sources.debug_theme.publish(theme));
        /// } else |err| std.log.warn("zui_debug kept its theme: {t}", .{err});
        /// ```
        pub fn declareWithThemeFrom(self: *Self, ui: *Ui, comptime sources: ThemeSources) void {
            comptime checkThemeSources(sources);
            var changes = ui.source(sources.file_changes).items();
            while (changes.next()) |change| {
                if (self.changesThemeFile(change)) self.theme_file_changed = true;
            }
            if (ui.source(sources.theme).get()) |theme| self.theme = theme;
            self.declare(ui);
        }

        /// Between frames: reads `theme_file` when it changed since it was
        /// last read, for the loader to publish into the source
        /// `declareWithThemeFrom` reads. Null when there is nothing new to
        /// read. A file that does not load, such as one caught half
        /// written, is not read again until it changes again.
        pub fn loadTheme(self: *Self, io: std.Io) LoadThemeError!?Theme {
            const file = self.theme_file orelse return null;
            if (!self.theme_file_changed) return null;
            self.theme_file_changed = false;
            return try Theme.read(io, file);
        }

        fn changesThemeFile(self: *const Self, change: *const zui.FileChange) bool {
            const file = self.theme_file orelse return false;
            return switch (change.kind) {
                .rescan => true,
                .added, .modified, .renamed_to => std.mem.eql(u8, change.pathBytes(), file.name),
                .removed, .renamed_from => false,
            };
        }

        fn checkThemeSources(comptime sources: ThemeSources) void {
            if (!yieldsFileChanges(Ui.SourceView(sources.file_changes))) {
                @compileError("zui_debug: Sources." ++ @tagName(sources.file_changes) ++ " is not a stream of zui.FileChange, such as zui_async.Stream(zui.FileChange, ...)");
            }
            if (!holdsTheme(Ui.SourceView(sources.theme))) {
                @compileError("zui_debug: Sources." ++ @tagName(sources.theme) ++ " does not hold the panel's theme, as a zui_async.Latest(zui_debug.PanelTheme(FontId, Color)) does");
            }
        }

        fn yieldsFileChanges(comptime View: type) bool {
            if (!@hasDecl(View, "items")) return false;
            const Iterator = ReturnType(View.items);
            if (!@hasDecl(Iterator, "next")) return false;
            return ReturnType(Iterator.next) == ?*const zui.FileChange;
        }

        fn holdsTheme(comptime View: type) bool {
            return @hasDecl(View, "get") and ReturnType(View.get) == ?Theme;
        }

        fn ReturnType(comptime function: anytype) type {
            return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        }

        fn declareHovered(self: *const Self, ui: *Ui, hovered: *const Hovered) void {
            self.line(ui, "{f}", .{RowLabel{ .row = &hovered.row }});
            const rect = hovered.rect;
            self.line(ui, "rect = {d}, {d}, {d}x{d}", .{ rect.x, rect.y, rect.width, rect.height });
            self.line(ui, "min_size = {d}x{d}", .{ hovered.min_size[0], hovered.min_size[1] });
            if (hovered.flags.scroll_x or hovered.flags.scroll_y) self.line(ui, "content_size = {d}x{d}", .{ hovered.content_size[0], hovered.content_size[1] });
            self.line(ui, "flags ={f}", .{FlagNames{ .flags = hovered.flags }});
            self.declareChangedFields(ui, "layout", hovered.layout);
            if (hovered.decoration) |decoration| self.declareChangedFields(ui, "decoration", decoration);
            if (hovered.effects) |effects| self.declareChangedFields(ui, "effects", effects);
            if (hovered.floating) |floating| self.declareChangedFields(ui, "floating", floating);
            switch (hovered.content) {
                .none => {},
                .text => |text_style| self.declareChangedFields(ui, "text", text_style),
                .image => |image| self.line(ui, "image = {f}", .{formatted(image)}),
                .custom => |custom| self.line(ui, "custom = {f}", .{formatted(custom)}),
            }
        }

        fn declareDiagnostics(self: *const Self, ui: *Ui) void {
            const diagnostics = &self.diagnostics;
            inline for (comptime std.enums.values(zui.Limit)) |limit| {
                if (diagnostics.exceeded.contains(limit)) {
                    self.line(ui, "limits." ++ @tagName(limit) ++ " is {d}; the frame needed {d}", .{ @field(Ui.limits, @tagName(limit)), diagnostics.needed.get(limit) });
                }
            }
            if (diagnostics.first_dropped_id != 0) self.line(ui, "first past a limit: {f}", .{self.elementName(diagnostics.first_dropped_id)});
            if (diagnostics.duplicate_ids != 0) self.line(ui, "{d} duplicate ids; each second one is not interactive", .{diagnostics.duplicate_ids});
            if (diagnostics.unbalanced) self.line(ui, "open and close are unbalanced", .{});
            if (diagnostics.refused_publishes != 0) {
                self.line(ui, "{d} publishes refused, first by Sources.{s}", .{ diagnostics.refused_publishes, diagnostics.first_refusing_source });
            }
            if (diagnostics.ok()) self.line(ui, "every limit held", .{});
        }

        fn declareFallbacks(self: *const Self, ui: *Ui) void {
            const diagnostics = &self.diagnostics;
            var lowered = diagnostics.lowered.iterator();
            while (lowered.next()) |command| {
                self.line(ui, "{t} drawn as {s}, as the renderer's zui_commands leaves it out", .{ command, loweredTo(command) });
            }
            if (diagnostics.clamped_colors) self.line(ui, "colors clamped to Color, as the renderer does not declare zui_extended_color", .{});
            var report_parts = std.mem.splitSequence(u8, self.runReport(), "; ");
            while (report_parts.next()) |part| if (part.len != 0) self.line(ui, "{s}", .{part});
            if (diagnostics.lowered.count() == 0 and !diagnostics.clamped_colors and self.run_report_len == 0) self.line(ui, "none in effect", .{});
        }

        fn declarePerformance(self: *const Self, ui: *Ui) void {
            if (times_zones) {
                self.declareZoneTimes(ui, &self.zones);
            } else {
                self.line(ui, "untimed, as Config.features.Tracer is not a zui_debug.ZoneTimer", .{});
            }
        }

        fn declareZoneTimes(self: *const Self, ui: *Ui, history: *const ZoneHistory) void {
            const latest = history.latest() orelse return self.line(ui, "no frame observed yet", .{});
            var any_zone_ran = false;
            for (history.kept()) |*times| any_zone_ran = any_zone_ran or times.ran.count() != 0;
            if (!any_zone_ran) return self.line(ui, "no zone timed yet; the ZoneTimer times from useClock(io)", .{});
            self.line(ui, "ms in the last frame (mean, peak) over {d} frames", .{history.count});
            for (std.enums.values(zui.TraceZone)) |zone| if (history.ran(zone)) {
                const depth: u16 = if (zone == .begin_frame or zone == .end_frame) 0 else 1;
                self.line(ui, "{s}{t} {d:.3} ({d:.3}, {d:.3})", .{
                    indentation(depth),
                    zone,
                    milliseconds(latest.nanoseconds.get(zone)),
                    milliseconds(history.mean(zone)),
                    milliseconds(history.peak(zone)),
                });
            };
        }

        fn milliseconds(nanoseconds: u64) f64 {
            return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
        }

        fn loweredTo(command: zui.OptionalCommand) []const u8 {
            return switch (command) {
                .gradient => "a rectangle in its mean color",
                .shadow => "nothing",
                .backdrop_blur => "a rectangle in its tint",
                .transform => "the untransformed element",
                .material => "its fallback background",
            };
        }

        fn elementName(self: *const Self, id: u64) ElementName {
            for (self.rows()) |*row| if (row.id == id) return .{ .id = id, .row = row };
            return .{ .id = id, .row = null };
        }

        const ElementName = struct {
            id: u64,
            row: ?*const Row,

            pub fn format(self: ElementName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                if (has_debug_names) if (self.row) |row| if (row.name.len != 0) return writer.writeAll(row.name);
                try writer.print("0x{x:0>16}", .{self.id});
            }
        };

        /// One line for each field of `config` that differs from its
        /// default, or one saying there are none.
        fn declareChangedFields(self: *const Self, ui: *Ui, comptime label: []const u8, config: anytype) void {
            var any_changed = false;
            inline for (@typeInfo(@TypeOf(config)).@"struct".fields) |field| {
                const value = @field(config, field.name);
                const is_default = if (field.defaultValue()) |default| std.meta.eql(value, default) else false;
                if (!is_default) {
                    any_changed = true;
                    self.line(ui, label ++ "." ++ field.name ++ " = {f}", .{formatted(value)});
                }
            }
            if (!any_changed) self.line(ui, label ++ " = .{{}}", .{});
        }

        fn heading(self: *const Self, ui: *Ui, title: []const u8) void {
            ui.text(title, .{ .font = self.theme.font, .size = self.theme.text_size, .color = self.theme.heading, .wrap = .none });
        }

        fn line(self: *const Self, ui: *Ui, comptime format: []const u8, arguments: anytype) void {
            var buffer: [max_line_bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            writer.print(format, arguments) catch {};
            const fitted = withoutCutCodepoint(writer.buffered());
            ui.text(fitted, .{ .font = self.theme.font, .size = self.theme.text_size, .color = self.theme.text, .wrap = .words });
        }

        const RowLabel = struct {
            row: *const Row,

            pub fn format(self: RowLabel, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try self.row.writeLabel(writer);
            }
        };

        const FlagNames = struct {
            flags: zui.ElementFlags,

            pub fn format(self: FlagNames, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                inline for (@typeInfo(zui.ElementFlags).@"struct".fields) |field| {
                    if (field.type == bool and @field(self.flags, field.name)) try writer.writeAll(" " ++ field.name);
                }
            }
        };

        fn indentation(depth: u16) []const u8 {
            const spaces = " " ** (2 * max_indented_depth);
            return spaces[0 .. 2 * @as(usize, @min(depth, max_indented_depth))];
        }
    };
}

/// `bytes` cut to at most `capacity` bytes without splitting a UTF-8
/// sequence.
fn wholeCodepoints(bytes: []const u8, capacity: usize) []const u8 {
    if (bytes.len <= capacity) return bytes;
    var end = capacity;
    while (end > 0 and bytes[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    return bytes[0..end];
}

/// `bytes` without a UTF-8 sequence that a full fixed writer cut short.
fn withoutCutCodepoint(bytes: []const u8) []const u8 {
    var lead = bytes.len;
    while (lead > 0 and bytes[lead - 1] & 0b1100_0000 == 0b1000_0000) lead -= 1;
    if (lead == 0) return bytes;
    lead -= 1;
    const sequence_length = std.unicode.utf8ByteSequenceLength(bytes[lead]) catch return bytes[0..lead];
    return if (bytes.len - lead >= sequence_length) bytes else bytes[0..lead];
}

fn Formatted(comptime T: type) type {
    return struct {
        value: T,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeValue(writer, self.value);
        }
    };
}

fn formatted(value: anytype) Formatted(@TypeOf(value)) {
    return .{ .value = value };
}

/// Zig's own `{any}`, except that arrays are written as literals and a
/// `zui.Color` as `#rrggbbaa`, at any depth.
fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (T == zui.Color) return writer.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ value.r, value.g, value.b, value.a });
    switch (@typeInfo(T)) {
        .optional => if (value) |inner| try writeValue(writer, inner) else try writer.writeAll("null"),
        .@"struct" => |info| if (info.layout == .@"packed" or info.fields.len == 0) {
            try writer.print("{any}", .{value});
        } else {
            try writer.writeAll(".{");
            inline for (info.fields, 0..) |field, field_index| {
                try writer.writeAll(if (field_index == 0) " ." else ", .");
                try writer.writeAll(field.name ++ " = ");
                try writeValue(writer, @field(value, field.name));
            }
            try writer.writeAll(" }");
        },
        .array => {
            try writer.writeAll(".{");
            for (value, 0..) |item, item_index| {
                try writer.writeAll(if (item_index == 0) " " else ", ");
                try writeValue(writer, item);
            }
            try writer.writeAll(" }");
        },
        else => try writer.print("{any}", .{value}),
    }
}

test {
    _ = @import("tests.zig");
}
