const std = @import("std");
const style = @import("style.zig");

/// Pass 7: render commands in paint order. A background and content are
/// emitted when an element is entered, its border when it is left, so the
/// border paints over the element's children.
pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    const scale: f32 = if (Ui.snaps_to_pixels) ui.platform.scale() else 1;
    var emitter: Emitter(Ui) = .{ .frame = frame, .scale = scale };

    var depth: usize = 0;
    ui.emit_stack[0] = Ui.root_index;
    ui.emit_cursor[0] = frame.first_child[Ui.root_index];
    while (true) {
        const next = ui.emit_cursor[depth];
        if (next == Ui.none_index) {
            emitter.leave(ui.emit_stack[depth]);
            if (depth == 0) break;
            depth -= 1;
            continue;
        }
        ui.emit_cursor[depth] = frame.next_sibling[next];
        emitter.enter(next);
        depth += 1;
        ui.emit_stack[depth] = next;
        ui.emit_cursor[depth] = frame.first_child[next];
    }
}

fn Emitter(comptime Ui: type) type {
    return struct {
        const Self = @This();

        frame: *Ui.Frame,
        scale: f32,

        fn rectOf(self: *const Self, element: Ui.Index) style.Rect {
            return self.snap(.{
                .x = self.frame.position[element][0],
                .y = self.frame.position[element][1],
                .width = self.frame.size[element][0],
                .height = self.frame.size[element][1],
            });
        }

        fn snap(self: *const Self, rect: style.Rect) style.Rect {
            if (!Ui.snaps_to_pixels) return rect;
            const left = @round(rect.x * self.scale) / self.scale;
            const top = @round(rect.y * self.scale) / self.scale;
            const right = @round((rect.x + rect.width) * self.scale) / self.scale;
            const bottom = @round((rect.y + rect.height) * self.scale) / self.scale;
            return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
        }

        fn push(self: *Self, command: Ui.RenderCommand) void {
            const frame = self.frame;
            frame.diagnostics.needed.set(.render_commands, frame.diagnostics.needed.get(.render_commands) + 1);
            if (frame.command_count >= frame.render_commands.len) {
                frame.diagnostics.exceeded.insert(.render_commands);
                if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = command.id;
                return;
            }
            frame.render_commands[frame.command_count] = command;
            frame.command_count += 1;
        }

        fn enter(self: *Self, element: Ui.Index) void {
            const frame = self.frame;
            const element_id = frame.element_id[element];
            const bounds = self.rectOf(element);

            if (frame.decoration_index[element] != Ui.none_index) {
                const decoration = frame.decorations[frame.decoration_index[element]];
                if (decoration.background) |color| {
                    self.push(.{ .bounds = bounds, .id = element_id, .payload = .{ .rectangle = .{ .color = color, .corner_radius = decoration.corner_radius } } });
                }
            }

            switch (frame.kindOf(element)) {
                .none => {},
                .image => self.push(.{ .bounds = bounds, .id = element_id, .payload = .{ .image = frame.images[frame.content_index[element]] } }),
                .custom => self.push(.{ .bounds = bounds, .id = element_id, .payload = .{ .custom = frame.customs[frame.content_index[element]] } }),
                .text => self.emitText(element, element_id),
            }
        }

        fn emitText(self: *Self, element: Ui.Index, element_id: u64) void {
            const frame = self.frame;
            const record = frame.texts[frame.content_index[element]];
            const line_height = record.metrics.line_height;
            const alignment = record.style.alignment.fraction();
            for (frame.lines[record.first_line..][0..record.line_count], 0..) |line, line_number| {
                const free = frame.size[element][0] - line.width;
                const line_bounds = self.snap(.{
                    .x = frame.position[element][0] + if (free > 0) free * alignment else 0,
                    .y = frame.position[element][1] + @as(f32, @floatFromInt(line_number)) * line_height,
                    .width = line.width,
                    .height = line_height,
                });
                self.push(.{ .bounds = line_bounds, .id = element_id, .payload = .{ .text = .{
                    .content = frame.text_bytes[line.start..line.end],
                    .style = record.style,
                    .line = @intCast(line_number),
                } } });
            }
        }

        fn leave(self: *Self, element: Ui.Index) void {
            const frame = self.frame;
            if (frame.decoration_index[element] == Ui.none_index) return;
            const decoration = frame.decorations[frame.decoration_index[element]];
            const border = decoration.border orelse return;
            self.push(.{ .bounds = self.rectOf(element), .id = frame.element_id[element], .payload = .{ .border = .{
                .color = border.color,
                .widths = border.widths,
                .corner_radius = decoration.corner_radius,
            } } });
        }
    };
}
