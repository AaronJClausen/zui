//! Reference widgets, built only on zui's public API.
//!
//! ```zig
//! const widgets: zui_widgets.Widgets(Ui) = .{}; // or .{ .theme = light, .dark_theme = dark }
//!
//! if (widgets.button(ui, .of("save"), "Save", .{})) save();
//! _ = widgets.checkbox(ui, .of("autosave"), "Autosave", &settings.autosave, .{});
//! _ = widgets.slider(ui, .of("volume"), &settings.volume, .{ .min = 0, .max = 100 });
//! _ = widgets.textField(ui, .of("name"), &settings.name, .{ .placeholder = "Name" });
//! _ = widgets.dropdownEnum(ui, .of("quality"), &settings.quality, .{});
//! ```

const std = @import("std");
const zui = @import("zui");

/// Text a `textField` edits in place, in a caller-owned buffer.
///
/// ```zig
/// var name_bytes: [64]u8 = undefined;
/// var name: zui_widgets.EditableText = .init(&name_bytes, "Ada");
/// ```
pub const EditableText = struct {
    buffer: []u8,
    len: usize = 0,

    /// Copies `initial`, cut at a character boundary if the buffer is smaller.
    pub fn init(buffer: []u8, initial: []const u8) EditableText {
        var text: EditableText = .{ .buffer = buffer };
        _ = text.insert(0, initial);
        return text;
    }

    pub fn slice(self: *const EditableText) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Inserts as much of `bytes` as fits, cut at a character boundary, and
    /// returns how many bytes that was.
    pub fn insert(self: *EditableText, position: usize, bytes: []const u8) usize {
        var count = @min(bytes.len, self.buffer.len - self.len);
        while (count > 0 and count < bytes.len and isContinuationByte(bytes[count])) count -= 1;
        std.mem.copyBackwards(u8, self.buffer[position + count .. self.len + count], self.buffer[position..self.len]);
        @memcpy(self.buffer[position..][0..count], bytes[0..count]);
        self.len += count;
        return count;
    }

    pub fn remove(self: *EditableText, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
        self.len -= end - start;
    }

    pub fn set(self: *EditableText, content: []const u8) void {
        self.len = 0;
        _ = self.insert(0, content);
    }
};

/// `"max_fps"` becomes `"Max fps"`.
pub fn labelFromIdentifier(comptime identifier: []const u8) []const u8 {
    return &LabelFromIdentifier(identifier).label;
}

fn LabelFromIdentifier(comptime identifier: []const u8) type {
    return struct {
        const label = blk: {
            var bytes: [identifier.len]u8 = identifier[0..identifier.len].*;
            for (&bytes) |*byte| {
                if (byte.* == '_') byte.* = ' ';
            }
            if (bytes.len != 0) bytes[0] = std.ascii.toUpper(bytes[0]);
            break :blk bytes;
        };
    };
}

pub fn Widgets(comptime UiType: type) type {
    return struct {
        const Self = @This();
        pub const Ui = UiType;
        pub const TextStyle = Ui.TextStyle;

        /// The look while the environment's theme is light, and while it is
        /// dark unless `dark_theme` is set.
        theme: Theme = .{},
        /// The look while the environment's theme is dark.
        dark_theme: ?Theme = null,

        pub const Theme = struct {
            text: TextStyle = .{ .color = .rgb(0xe8e8f0) },
            muted_text_color: zui.Color = .rgb(0x9a9aae),
            disabled_text_color: zui.Color = .rgb(0x5c5c6e),
            control: std.EnumArray(zui.WidgetState, zui.Color) = .init(.{
                .idle = .rgb(0x2c2c3c),
                .hovered = .rgb(0x3a3a50),
                .pressed = .rgb(0x4a6ad0),
                .focused = .rgb(0x2c2c3c),
                .disabled = .rgb(0x24242e),
            }),
            field_background: zui.Color = .rgb(0x15151b),
            border_color: zui.Color = .rgb(0x34344a),
            accent: zui.Color = .rgb(0x5b8cff),
            check_mark: zui.Color = .rgb(0xffffff),
            track: zui.Color = .rgb(0x34344a),
            thumb: zui.Color = .rgb(0xe8e8f0),
            caret: zui.Color = .rgb(0xe8e8f0),
            focus_ring: zui.Color = .rgb(0xffc65c),
            popup_background: zui.Color = .rgb(0x262634),
            option_highlight: zui.Color = .rgb(0x3a3a50),
            selected_option: zui.Color = .rgb(0x30406c),
            corner_radius: f32 = 4,
            control_height: f32 = 30,
            horizontal_padding: f32 = 12,
            gap: f32 = 8,
            checkbox_size: f32 = 18,
            slider_thumb_size: [2]f32 = .{ 12, 20 },
            track_thickness: f32 = 4,
            caret_width: f32 = 2,
            label_width: f32 = 140,
            /// Popups paint in this layer and the next one up.
            popup_z: i16 = 100,
            dropdown_indicator: []const u8 = "v",
            expanded_indicator: []const u8 = "v",
            collapsed_indicator: []const u8 = ">",
        };

        pub fn label(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, textStyle(self.activeTheme(ui), .normal));
        }

        pub fn mutedLabel(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, textStyle(self.activeTheme(ui), .muted));
        }

        /// `dark_theme` while the environment's theme is dark and it is set;
        /// otherwise `theme`.
        pub fn activeTheme(self: *const Self, ui: *const Ui) *const Theme {
            if (ui.environment().theme == .dark) if (self.dark_theme) |*dark| return dark;
            return &self.theme;
        }

        /// Opens a row with `content` in a column `theme.label_width` wide.
        /// Declare the control, then close the row:
        ///
        /// ```zig
        /// widgets.labeledRow(ui, "Volume");
        /// _ = widgets.slider(ui, .of("volume"), &volume, .{ .max = 100 });
        /// ui.close();
        /// ```
        pub fn labeledRow(self: Self, ui: *Ui, content: []const u8) void {
            const theme = self.activeTheme(ui);
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = theme.gap, .child_alignment = .{ .y = .center } } });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(theme.label_width) } } });
            ui.text(content, textStyle(theme, .muted));
            ui.close();
        }

        /// A full-width header that toggles `expanded` when clicked, for
        /// collapsible sections. Returns whether it toggled.
        ///
        /// ```zig
        /// if (widgets.disclosure(ui, .of("advanced"), "Advanced", &advanced_open)) {}
        /// if (advanced_open) advancedSettings(ui);
        /// ```
        pub fn disclosure(self: Self, ui: *Ui, id: zui.Id, content: []const u8, expanded: *bool) bool {
            const theme = self.activeTheme(ui);
            const toggled = ui.clicked(id);
            if (toggled) expanded.* = !expanded.*;
            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .decoration = .{
                    .background = if (state == .hovered or state == .pressed) theme.control.get(state) else null,
                    .border = focusRingOr(theme, ui, id, null),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .sizing = .{ .width = .grow, .height = .fixed(theme.control_height) },
                    .padding = .symmetric(theme.gap, 0),
                    .child_gap = theme.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(if (expanded.*) theme.expanded_indicator else theme.collapsed_indicator, textStyle(theme, .muted));
            ui.text(content, textStyle(theme, .normal));
            ui.close();
            return toggled;
        }

        pub const ButtonOptions = struct {
            disabled: bool = false,
            width: zui.Sizing = .fit,
        };

        /// True in the frame the button is clicked, or activated with Enter
        /// or Space while focused.
        pub fn button(self: Self, ui: *Ui, id: zui.Id, content: []const u8, options: ButtonOptions) bool {
            const theme = self.activeTheme(ui);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .decoration = .{
                    .background = theme.control.get(ui.widgetState(id)),
                    .border = focusRingOr(theme, ui, id, null),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fixed(theme.control_height) },
                    .padding = .symmetric(theme.horizontal_padding, 0),
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            ui.text(content, textStyle(theme, if (options.disabled) .disabled else .normal));
            ui.close();
            return ui.clicked(id);
        }

        pub const CheckboxOptions = struct {
            disabled: bool = false,
        };

        /// Toggles `checked` when clicked; returns whether it did. An empty
        /// `content` draws the box alone.
        pub fn checkbox(self: Self, ui: *Ui, id: zui.Id, content: []const u8, checked: *bool, options: CheckboxOptions) bool {
            const theme = self.activeTheme(ui);
            const toggled = ui.clicked(id);
            if (toggled) checked.* = !checked.*;

            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .layout = .{ .sizing = .{ .height = .fixed(theme.control_height) }, .child_gap = theme.gap, .child_alignment = .{ .y = .center } },
            });
            const outline_color = if (state == .hovered or state == .pressed) theme.accent else theme.border_color;
            ui.open(.{
                .decoration = .{
                    .background = if (checked.* and !options.disabled) theme.accent else theme.field_background,
                    .border = focusRingOr(theme, ui, id, .{ .color = outline_color, .widths = .all(1) }),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .sizing = .{ .width = .fixed(theme.checkbox_size), .height = .fixed(theme.checkbox_size) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            if (checked.*) {
                const mark_size = @round(theme.checkbox_size * 0.45);
                ui.box(.{
                    .decoration = .{
                        .background = if (options.disabled) theme.disabled_text_color else theme.check_mark,
                        .corner_radius = .all(2),
                    },
                    .layout = .{ .sizing = .{ .width = .fixed(mark_size), .height = .fixed(mark_size) } },
                });
            }
            ui.close();
            if (content.len != 0) ui.text(content, textStyle(theme, if (options.disabled) .disabled else .normal));
            ui.close();
            return toggled;
        }

        pub const SliderOptions = struct {
            min: f64 = 0,
            max: f64 = 1,
            /// Values snap to `min + n * step`. Integer values always
            /// round to whole numbers.
            step: ?f64 = null,
            disabled: bool = false,
            width: zui.Sizing = .grow,
        };

        /// Edits the integer or float behind `value` by dragging, or with
        /// the arrow keys, Page Up/Down, Home and End while focused.
        /// Returns whether the value changed.
        pub fn slider(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: SliderOptions) bool {
            const Value = NumberPointee(@TypeOf(value), "slider");
            const theme = self.activeTheme(ui);
            const range = options.max - options.min;
            const previous: f64 = numberToFloat(value.*);
            var proposed = previous;

            if (!options.disabled) {
                if (pointerActivated(ui, id)) if (ui.pointerLocal(id)) |local| if (ui.rectOf(id)) |rect| {
                    const travel = rect.width - theme.slider_thumb_size[0];
                    if (travel > 0) proposed = options.min + range * (local[0] - theme.slider_thumb_size[0] / 2) / travel;
                };
                if (ui.focused(id)) {
                    const key_step = options.step orelse if (@typeInfo(Value) == .int) 1 else range / 100;
                    for (ui.keyEvents()) |key_event| switch (key_event.key) {
                        .left, .down => proposed -= key_step,
                        .right, .up => proposed += key_step,
                        .page_down => proposed -= key_step * 10,
                        .page_up => proposed += key_step * 10,
                        .home => proposed = options.min,
                        .end => proposed = options.max,
                        else => {},
                    };
                }
            }

            var changed = false;
            if (proposed != previous) {
                const stored = floatToNumber(Value, snap(proposed, options));
                changed = stored != value.*;
                value.* = stored;
            }

            const current: f64 = numberToFloat(value.*);
            const fraction: f32 = if (range > 0) @floatCast(std.math.clamp((current - options.min) / range, 0, 1)) else 0;
            const state = ui.widgetState(id);
            const track_radius: zui.CornerRadius = .all(theme.track_thickness / 2);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .layout = .{ .sizing = .{ .width = options.width, .height = .fixed(theme.control_height) }, .child_alignment = .{ .y = .center } },
            });
            // The grow weights split the track's free space at the value,
            // so the thumb lands in place without last frame's width.
            ui.box(.{
                .decoration = .{
                    .background = if (options.disabled) theme.track else theme.accent,
                    .corner_radius = track_radius,
                },
                .layout = .{ .sizing = .{ .width = .growWeighted(fraction), .height = .fixed(theme.track_thickness) } },
            });
            ui.box(.{
                .decoration = .{
                    .background = switch (state) {
                        .pressed => theme.accent,
                        .disabled => theme.disabled_text_color,
                        else => theme.thumb,
                    },
                    .border = focusRingOr(theme, ui, id, null),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{ .sizing = .{ .width = .fixed(theme.slider_thumb_size[0]), .height = .fixed(theme.slider_thumb_size[1]) } },
            });
            ui.box(.{
                .decoration = .{
                    .background = theme.track,
                    .corner_radius = track_radius,
                },
                .layout = .{ .sizing = .{ .width = .growWeighted(1 - fraction), .height = .fixed(theme.track_thickness) } },
            });
            ui.close();
            return changed;
        }

        fn snap(proposed: f64, options: SliderOptions) f64 {
            var snapped = proposed;
            if (options.step) |step| if (step > 0) {
                snapped = options.min + @round((proposed - options.min) / step) * step;
            };
            return std.math.clamp(snapped, @min(options.min, options.max), @max(options.min, options.max));
        }

        pub const TextFieldOptions = struct {
            placeholder: []const u8 = "",
            disabled: bool = false,
            width: zui.Sizing = .grow,
        };

        pub const TextFieldResult = struct {
            changed: bool = false,
            /// Enter was pressed while the field was focused.
            submitted: bool = false,
        };

        const Caret = struct {
            position: u32,
            was_focused: bool,
        };

        /// One line of editable text. Clicking places the caret; typing
        /// inserts at it; Left, Right, Home, End, Backspace and Delete move
        /// and delete by character. Focusing with Tab puts the caret at
        /// the end.
        pub fn textField(self: Self, ui: *Ui, id: zui.Id, text: *EditableText, options: TextFieldOptions) TextFieldResult {
            const theme = self.activeTheme(ui);
            const style = textStyle(theme, if (options.disabled) .disabled else .normal);
            const scroll_id = id.child("scroll");
            const caret = ui.state(id, Caret);
            const focused = ui.focused(id) and !options.disabled;
            var result: TextFieldResult = .{};

            var position = boundaryAtOrBefore(text.slice(), caret.position);
            if (focused and !caret.was_focused) position = text.len;
            caret.was_focused = focused;

            if (!options.disabled and pointerActivated(ui, id)) if (ui.pointerLocal(scroll_id)) |local| {
                position = positionAt(ui, text.slice(), style, local[0] + ui.scrollOffset(scroll_id)[0]);
            };

            if (focused) {
                for (ui.keyEvents()) |key_event| switch (key_event.key) {
                    .left => position = previousBoundary(text.slice(), position),
                    .right => position = nextBoundary(text.slice(), position),
                    .home => position = 0,
                    .end => position = text.len,
                    .backspace => if (position > 0) {
                        const start = previousBoundary(text.slice(), position);
                        text.remove(start, position);
                        position = start;
                        result.changed = true;
                    },
                    .delete => if (position < text.len) {
                        text.remove(position, nextBoundary(text.slice(), position));
                        result.changed = true;
                    },
                    .enter => result.submitted = true,
                    else => {},
                };

                var printable: [Ui.limits.max_text_input_bytes]u8 = undefined;
                var printable_len: usize = 0;
                for (ui.typedText()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    printable[printable_len] = byte;
                    printable_len += 1;
                }
                const inserted = text.insert(position, printable[0..printable_len]);
                position += inserted;
                if (inserted != 0) result.changed = true;
            }
            caret.position = @intCast(position);

            const before = text.slice()[0..position];
            const after = text.slice()[position..];
            if (focused) if (ui.rectOf(scroll_id)) |visible| {
                const caret_left = if (before.len == 0) 0 else ui.measureText(before, style)[0];
                const caret_right = caret_left + theme.caret_width;
                var offset = ui.scrollOffset(scroll_id);
                if (caret_left < offset[0]) offset[0] = caret_left;
                if (caret_right > offset[0] + visible.width) offset[0] = caret_right - visible.width;
                ui.setScrollOffset(scroll_id, offset);
            };

            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .text,
                .decoration = .{
                    .background = theme.field_background,
                    .border = focusRingOr(theme, ui, id, .{ .color = theme.border_color, .widths = .all(1) }),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fixed(theme.control_height) },
                    .padding = .symmetric(theme.gap, 0),
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.open(.{
                .id = scroll_id,
                .scroll = .{ .horizontal = true, .vertical = false },
                .layout = .{ .sizing = .{ .width = .grow }, .child_alignment = .{ .y = .center } },
            });
            if (text.len == 0 and !focused) {
                if (options.placeholder.len != 0) ui.text(options.placeholder, textStyle(theme, .muted));
            } else {
                if (before.len != 0) ui.text(before, style);
                ui.box(.{
                    .id = id.child("caret"),
                    .decoration = .{
                        .background = if (focused) theme.caret else null,
                    },
                    .layout = .{ .sizing = .{ .width = .fixed(theme.caret_width), .height = .fixed(style.size) } },
                });
                if (after.len != 0) ui.text(after, style);
            }
            ui.close();
            ui.close();
            ui.requestTextInput(id, id.child("caret"));
            return result;
        }

        /// The character boundary nearest to `x` units from the text's start.
        fn positionAt(ui: *Ui, text: []const u8, style: TextStyle, x: f32) usize {
            var nearest: usize = 0;
            var nearest_distance = @abs(x);
            var boundary: usize = 0;
            while (boundary < text.len) {
                boundary = nextBoundary(text, boundary);
                const width = ui.measureText(text[0..boundary], style)[0];
                const distance = @abs(width - x);
                if (distance < nearest_distance) {
                    nearest = boundary;
                    nearest_distance = distance;
                } else if (width > x) break;
            }
            return nearest;
        }

        pub const DropdownOptions = struct {
            disabled: bool = false,
            /// `.fit` is at least as wide as the widest label, so the
            /// control keeps its size when the selection changes.
            width: zui.Sizing = .fit,
        };

        const Popup = struct { open: bool };

        /// A button showing `labels[selected.*]` that opens a list of
        /// `labels` below it. Choosing one sets `selected` and returns
        /// true. With the list closed, Up and Down change the selection.
        /// Escape or a click outside closes the list.
        pub fn dropdown(self: Self, ui: *Ui, id: zui.Id, selected: *usize, labels: []const []const u8, options: DropdownOptions) bool {
            const theme = self.activeTheme(ui);
            const popup = ui.state(id, Popup);
            const backdrop_id = id.child("backdrop");
            var changed = false;

            if (options.disabled) {
                popup.open = false;
            } else if (ui.clicked(id)) {
                popup.open = !popup.open;
                if (popup.open and selected.* < labels.len) ui.requestFocus(id.indexedChild("option", selected.*));
            } else if (popup.open) {
                if (ui.clicked(backdrop_id)) popup.open = false;
                if (ui.keyPressed(.escape)) {
                    popup.open = false;
                    ui.requestFocus(id);
                }
                for (0..labels.len) |index| {
                    if (!ui.clicked(id.indexedChild("option", index))) continue;
                    changed = selected.* != index;
                    selected.* = index;
                    popup.open = false;
                    ui.requestFocus(id);
                }
            } else if (ui.focused(id) and labels.len != 0) {
                const previous = selected.*;
                if (ui.keyPressed(.down)) selected.* = if (selected.* + 1 < labels.len) selected.* + 1 else @min(selected.*, labels.len - 1);
                if (ui.keyPressed(.up) and selected.* > 0) selected.* = @min(selected.*, labels.len) - 1;
                changed = selected.* != previous;
            }

            const style = textStyle(theme, if (options.disabled) .disabled else .normal);
            var width = options.width;
            if (width.rule == .fit) {
                var widest_label: f32 = 0;
                for (labels) |option_label| widest_label = @max(widest_label, ui.measureText(option_label, style)[0]);
                const indicator_width = ui.measureText(theme.dropdown_indicator, style)[0];
                width.min = @max(width.min, widest_label + indicator_width + theme.gap + 2 * theme.horizontal_padding);
            }
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .decoration = .{
                    .background = theme.control.get(ui.widgetState(id)),
                    .border = focusRingOr(theme, ui, id, null),
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .sizing = .{ .width = width, .height = .fixed(theme.control_height) },
                    .padding = .symmetric(theme.horizontal_padding, 0),
                    .child_gap = theme.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(if (selected.* < labels.len) labels[selected.*] else "", style);
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
            ui.text(theme.dropdown_indicator, textStyle(theme, .muted));
            ui.close();

            if (popup.open) self.declarePopup(ui, id, backdrop_id, selected.*, labels);
            return changed;
        }

        fn declarePopup(self: Self, ui: *Ui, id: zui.Id, backdrop_id: zui.Id, selected: usize, labels: []const []const u8) void {
            const theme = self.activeTheme(ui);
            const viewport = ui.viewport();
            ui.box(.{
                .id = backdrop_id,
                .interactive = true,
                .floating = .{ .attach_to = .root, .z = theme.popup_z },
                .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
            });
            const button_width = if (ui.rectOf(id)) |rect| rect.width else 0;
            ui.open(.{
                .id = id.child("popup"),
                .focus_scope = true,
                .floating = .{ .attach_to = .{ .element = id }, .attach_point = .bottom_left, .offset = .{ 0, 4 }, .z = theme.popup_z + 1 },
                .decoration = .{
                    .background = theme.popup_background,
                    .border = .{ .color = theme.border_color, .widths = .all(1) },
                    .corner_radius = .all(theme.corner_radius),
                },
                .layout = .{
                    .direction = .top_to_bottom,
                    .padding = .all(4),
                    .sizing = .{ .width = .fitBetween(button_width, std.math.inf(f32)) },
                },
            });
            const style = textStyle(theme, .normal);
            for (labels, 0..) |option_label, index| {
                const option_id = id.indexedChild("option", index);
                ui.open(.{
                    .id = option_id,
                    .focusable = true,
                    .cursor = .pointer,
                    .decoration = .{
                        .background = switch (ui.widgetState(option_id)) {
                            .hovered, .pressed => theme.option_highlight,
                            else => if (index == selected) theme.selected_option else null,
                        },
                        .border = focusRingOr(theme, ui, option_id, null),
                        .corner_radius = .all(theme.corner_radius),
                    },
                    .layout = .{
                        .sizing = .{ .width = .grow, .height = .fixed(theme.control_height) },
                        .padding = .symmetric(theme.horizontal_padding - 4, 0),
                        .child_alignment = .{ .y = .center },
                    },
                });
                ui.text(option_label, style);
                ui.close();
            }
            ui.close();
        }

        /// `dropdown` over an enum's named tags, labeled with
        /// `labelFromIdentifier`.
        pub fn dropdownEnum(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: DropdownOptions) bool {
            const Enum = EnumPointee(@TypeOf(value));
            const tags = @typeInfo(Enum).@"enum".fields;
            const labels = comptime blk: {
                var tag_labels: [tags.len][]const u8 = undefined;
                for (tags, 0..) |tag, index| tag_labels[index] = labelFromIdentifier(tag.name);
                break :blk tag_labels;
            };
            var selected: usize = tags.len;
            inline for (tags, 0..) |tag, index| {
                if (@intFromEnum(value.*) == tag.value) selected = index;
            }
            if (!self.dropdown(ui, id, &selected, &labels, options)) return false;
            inline for (tags, 0..) |tag, index| {
                if (index == selected) value.* = @enumFromInt(tag.value);
            }
            return true;
        }

        const TextTone = enum { normal, muted, disabled };

        fn textStyle(theme: *const Theme, tone: TextTone) TextStyle {
            var style = theme.text;
            style.wrap = .none;
            style.color = switch (tone) {
                .normal => style.color,
                .muted => theme.muted_text_color,
                .disabled => theme.disabled_text_color,
            };
            return style;
        }

        /// Held down, or pressed and released within this frame by a
        /// pointer that is still over it. Not a keyboard activation, which
        /// says nothing about where the pointer is.
        fn pointerActivated(ui: *const Ui, id: zui.Id) bool {
            if (ui.pressed(id)) return true;
            if (!ui.clicked(id)) return false;
            const local = ui.pointerLocal(id) orelse return false;
            const rect = ui.rectOf(id) orelse return false;
            return local[0] >= 0 and local[1] >= 0 and local[0] < rect.width and local[1] < rect.height;
        }

        fn focusRingOr(theme: *const Theme, ui: *const Ui, id: zui.Id, unfocused: ?zui.Border) ?zui.Border {
            if (ui.focused(id)) return .{ .color = theme.focus_ring, .widths = .all(2) };
            return unfocused;
        }
    };
}

fn NumberPointee(comptime Pointer: type, comptime widget: []const u8) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const) {
        switch (@typeInfo(info.pointer.child)) {
            .int, .float => return info.pointer.child,
            else => {},
        }
    }
    @compileError("zui_widgets: " ++ widget ++ " needs a pointer to an integer or float, got " ++ @typeName(Pointer));
}

fn EnumPointee(comptime Pointer: type) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const and @typeInfo(info.pointer.child) == .@"enum") {
        if (@typeInfo(info.pointer.child).@"enum".fields.len == 0) @compileError("zui_widgets: dropdownEnum needs an enum with at least one named tag, got " ++ @typeName(info.pointer.child));
        return info.pointer.child;
    }
    @compileError("zui_widgets: dropdownEnum needs a pointer to an enum, got " ++ @typeName(Pointer));
}

fn numberToFloat(number: anytype) f64 {
    return switch (@typeInfo(@TypeOf(number))) {
        .int => @floatFromInt(number),
        .float => @floatCast(number),
        else => comptime unreachable,
    };
}

fn floatToNumber(comptime Number: type, float: f64) Number {
    return switch (@typeInfo(Number)) {
        .int => std.math.lossyCast(Number, @round(float)),
        .float => @floatCast(float),
        else => comptime unreachable,
    };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn previousBoundary(text: []const u8, position: usize) usize {
    if (position == 0) return 0;
    var index = position - 1;
    while (index > 0 and isContinuationByte(text[index])) index -= 1;
    return index;
}

fn nextBoundary(text: []const u8, position: usize) usize {
    if (position >= text.len) return text.len;
    var index = position + 1;
    while (index < text.len and isContinuationByte(text[index])) index += 1;
    return index;
}

/// Positions are kept across frames while the application may change the
/// text, so a stale one is pulled back inside and onto a character start.
fn boundaryAtOrBefore(text: []const u8, position: usize) usize {
    var index = @min(position, text.len);
    while (index > 0 and index < text.len and isContinuationByte(text[index])) index -= 1;
    return index;
}

test {
    _ = @import("tests.zig");
}
