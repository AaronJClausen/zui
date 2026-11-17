//! An inspector over `Frame.inspect`: a panel listing the frame's
//! diagnostics and fallbacks, the element tree and the configs of the
//! element under the pointer.
//!
//! ```zig
//! app.inspector.declare(ui); // last, so its panel floats over the rest
//! const frame = ui.endFrame();
//! app.inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
//! ```

const std = @import("std");
const zui = @import("zui");

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
        const max_text_preview_bytes = 32;
        const max_line_bytes = 256;
        const max_indented_depth = 32;
        const max_run_report_bytes = 1024;

        /// How the panel looks; `font` and `text_size` apply to every line.
        pub const Theme = struct {
            width: f32 = 360,
            font: Ui.FontId = std.mem.zeroes(Ui.FontId),
            text_size: f32 = 12,
            text: Ui.Color = .rgb(0xd4d4d4),
            heading: Ui.Color = .rgb(0x9cdcfe),
            background: Ui.Color = .rgba(0x1e1e1ef0),
            hovered_row: Ui.Color = .rgb(0x264f78),
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
        row_storage: [Ui.max_elements]Row = undefined,
        row_count: u32 = 0,
        hovered: ?Hovered = null,
        hovered_row: ?u32 = null,
        /// The last observed frame's.
        diagnostics: zui.Diagnostics = .{},
        run_report_storage: [max_run_report_bytes]u8 = undefined,
        run_report_len: u16 = 0,

        /// The tree as last observed, in declaration order.
        pub fn rows(self: *const Self) []const Row {
            return self.row_storage[0..self.row_count];
        }

        /// Keeps `report` formatted with `{f}`, to list under the fallbacks
        /// what no frame says: what the host and renderer lack. Each part
        /// that `; ` separates gets a line, and what does not fit is cut.
        ///
        /// ```zig
        /// app.inspector.reportRun(runner.report); // zui_app's Report
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
        /// move there to read it.
        pub fn observe(self: *Self, frame: *const Ui.Frame, pointer: ?[2]f32) void {
            self.diagnostics = frame.diagnostics;
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
