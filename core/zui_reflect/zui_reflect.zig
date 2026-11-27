//! Editors generated from a struct's fields with `@typeInfo`.
//!
//! ```zig
//! const Settings = struct {
//!     volume: f32 = 0.8,
//!     fullscreen: bool = false,
//!     quality: enum { low, medium, high } = .medium,
//!     max_fps: u16 = 144,
//!     frames_rendered: u64 = 0,
//!
//!     pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
//!         .volume = .{ .min = 0, .max = 1 },
//!         .max_fps = .{ .label = "Frame cap", .min = 30, .max = 240, .step = 10 },
//!         .frames_rendered = .{ .hidden = true },
//!     } };
//! };
//!
//! if (zui_reflect.inspector(widgets, ui, .of("settings"), &settings)) settings_changed = true;
//! ```
//!
//! | Field type | Editor |
//! |---|---|
//! | `bool` | checkbox |
//! | integer or float with `min` and `max` | slider |
//! | integer or float otherwise | − and + buttons, by `step` (default 1, or 0.1 for floats) |
//! | enum | dropdown |
//! | `zui_widgets.EditableText` | text field |
//! | `[]const u8` | read-only text |
//! | struct | collapsible section, using that struct's own `zui_inspector` |

const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

pub const FieldOptions = struct {
    /// Defaults to the field name with `labelFromIdentifier` applied.
    label: ?[]const u8 = null,
    hidden: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    placeholder: []const u8 = "",
};

/// The type of a struct's `pub const zui_inspector` declaration. It has
/// one `FieldOptions` per field of `T`, so a misspelled field name is a
/// compile error.
pub fn Options(comptime T: type) type {
    return struct {
        fields: FieldOptionsOf(T) = .{},
    };
}

pub fn FieldOptionsOf(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    const default_options: FieldOptions = .{};
    for (fields, 0..) |field, index| {
        field_names[index] = field.name;
        field_types[index] = FieldOptions;
        field_attributes[index] = .{ .default_value_ptr = &default_options };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attributes);
}

/// Declares an editor for every visible field of `value.*` and returns
/// whether any of them changed it this frame.
pub fn inspector(widgets: anytype, ui: *@TypeOf(widgets).Ui, id: zui.Id, value: anytype) bool {
    const T = StructPointee(@TypeOf(value));
    ui.open(.{ .id = id, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
    const changed = inspectFields(widgets, ui, id, T, value);
    ui.close();
    return changed;
}

fn inspectFields(widgets: anytype, ui: *@TypeOf(widgets).Ui, id: zui.Id, comptime T: type, value: *T) bool {
    const options = comptime optionsOf(T);
    var changed = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_options = comptime @field(options.fields, field.name);
        if (field_options.hidden) continue;
        const label = comptime field_options.label orelse zui_widgets.labelFromIdentifier(field.name);
        if (inspectField(widgets, ui, id.child(field.name), label, field.type, &@field(value, field.name), comptime field.defaultValue(), field_options)) changed = true;
    }
    return changed;
}

const Section = struct { collapsed: bool };

fn inspectField(
    widgets: anytype,
    ui: *@TypeOf(widgets).Ui,
    id: zui.Id,
    label: []const u8,
    comptime Field: type,
    field: *Field,
    comptime default: ?Field,
    comptime options: FieldOptions,
) bool {
    if (Field == zui_widgets.EditableText) {
        propertyRow(widgets, ui, label, false);
        defer ui.close();
        return widgets.textField(ui, id, field, .{ .placeholder = options.placeholder, .label = label }).changed;
    }
    switch (@typeInfo(Field)) {
        .bool => {
            propertyRow(widgets, ui, label, changedFromDefault(Field, field.*, default));
            defer ui.close();
            return widgets.checkbox(ui, id, "", field, .{ .label = label });
        },
        .int, .float => {
            propertyRow(widgets, ui, label, changedFromDefault(Field, field.*, default));
            defer ui.close();
            if (options.min != null and options.max != null) {
                const changed = widgets.slider(ui, id, field, .{ .min = options.min.?, .max = options.max.?, .step = options.step, .label = label });
                numberLabel(widgets, ui, field.*);
                return changed;
            }
            return stepper(widgets, ui, id, Field, field, options);
        },
        .@"enum" => {
            propertyRow(widgets, ui, label, changedFromDefault(Field, field.*, default));
            defer ui.close();
            return widgets.dropdownEnum(ui, id, field, .{ .label = label });
        },
        .pointer => {
            propertyRow(widgets, ui, label, changedFromDefault(Field, field.*, default));
            defer ui.close();
            widgets.label(ui, field.*);
            return false;
        },
        .@"struct" => {
            const section = ui.state(id, Section);
            var expanded = !section.collapsed;
            if (widgets.disclosure(ui, id, label, &expanded)) section.collapsed = !expanded;
            if (!expanded) return false;
            const button = widgets.style(ui, .button, .idle);
            ui.open(.{ .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .width = .grow },
                .padding = .{ .left = button.padding.left + button.gap },
                .child_gap = 4,
            } });
            defer ui.close();
            return inspectFields(widgets, ui, id, Field, field);
        },
        else => comptime unreachable,
    }
}

/// A row in the property grid's look: the label in a column of 40% of
/// the row, at least the skin's `property_row` width, with a dot after it
/// when `changed`. Declare the editor, then close the row.
fn propertyRow(widgets: anytype, ui: *@TypeOf(widgets).Ui, label: []const u8, changed: bool) void {
    const row = widgets.style(ui, .property_row, .idle);
    var name = widgets.style(ui, .property_label, .idle).text;
    name.wrap = .words;
    ui.open(.{ .layout = .{
        .sizing = .{ .width = .grow, .height = .fitBetween(row.size[1], std.math.inf(f32)) },
        .padding = .{ .top = row.padding.top, .bottom = row.padding.bottom },
        .child_gap = row.gap,
        .child_alignment = .{ .y = .center },
    } });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .{ .rule = .percent, .amount = label_column_share, .min = row.size[0] } }, .child_gap = row.gap / 2, .child_alignment = .{ .y = .center } } });
    ui.text(label, name);
    if (changed) {
        const dot = widgets.style(ui, .property_changed, .idle);
        ui.box(.{ .decoration = .{ .background = dot.background, .corner_radius = dot.corner_radius, .corner_shape = dot.corner_shape }, .layout = .{ .sizing = .{ .width = .fixed(dot.size[0]), .height = .fixed(dot.size[0]) } } });
    }
    ui.close();
}

const label_column_share = 0.4;

fn changedFromDefault(comptime Field: type, value: Field, comptime default: ?Field) bool {
    const original = default orelse return false;
    return switch (@typeInfo(Field)) {
        .bool, .int, .float, .@"enum" => value != original,
        .pointer => if (Field == []const u8) !std.mem.eql(u8, value, original) else false,
        else => false,
    };
}

fn stepper(widgets: anytype, ui: *@TypeOf(widgets).Ui, id: zui.Id, comptime Number: type, number: *Number, comptime options: FieldOptions) bool {
    const previous = number.*;
    const square: zui.Sizing = .fixed(widgets.style(ui, .control_medium, .idle).size[1]);
    if (widgets.button(ui, id.child("decrement"), "-", .{ .width = square })) number.* = stepped(Number, number.*, options, .down);
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(72) }, .child_alignment = .{ .x = .center } } });
    numberText(widgets, ui, number.*);
    ui.close();
    if (widgets.button(ui, id.child("increment"), "+", .{ .width = square })) number.* = stepped(Number, number.*, options, .up);
    return number.* != previous;
}

fn stepped(comptime Number: type, number: Number, comptime options: FieldOptions, direction: enum { up, down }) Number {
    var result = number;
    switch (@typeInfo(Number)) {
        .int => {
            const step = comptime std.math.lossyCast(Number, options.step orelse 1);
            result = if (direction == .up) result +| step else result -| step;
            if (options.min) |min| result = @max(result, comptime std.math.lossyCast(Number, @ceil(min)));
            if (options.max) |max| result = @min(result, comptime std.math.lossyCast(Number, @floor(max)));
        },
        .float => {
            const step: Number = comptime @floatCast(options.step orelse 0.1);
            result = if (direction == .up) result + step else result - step;
            if (options.min) |min| result = @max(result, @as(Number, @floatCast(min)));
            if (options.max) |max| result = @min(result, @as(Number, @floatCast(max)));
        },
        else => comptime unreachable,
    }
    return result;
}

fn numberLabel(widgets: anytype, ui: *@TypeOf(widgets).Ui, number: anytype) void {
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(56) }, .child_alignment = .{ .x = .end } } });
    numberText(widgets, ui, number);
    ui.close();
}

fn numberText(widgets: anytype, ui: *@TypeOf(widgets).Ui, number: anytype) void {
    var buffer: [64]u8 = undefined;
    const formatted = switch (@typeInfo(@TypeOf(number))) {
        .int => std.fmt.bufPrint(&buffer, "{d}", .{number}),
        .float => std.fmt.bufPrint(&buffer, "{d:.2}", .{number}),
        else => comptime unreachable,
    } catch unreachable;
    widgets.label(ui, formatted);
}

fn StructPointee(comptime Pointer: type) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const) {
        switch (@typeInfo(info.pointer.child)) {
            .@"struct" => |struct_info| if (struct_info.layout != .@"packed") return info.pointer.child,
            else => {},
        }
    }
    @compileError("zui_reflect: inspector needs a mutable pointer to a non-packed struct, got " ++ @typeName(Pointer));
}

fn optionsOf(comptime T: type) Options(T) {
    const options: Options(T) = if (@hasDecl(T, "zui_inspector")) declared: {
        const Declared = @TypeOf(T.zui_inspector);
        if (Declared != Options(T)) {
            @compileError("zui_reflect: " ++ @typeName(T) ++ ".zui_inspector is " ++ @typeName(Declared) ++ "; declare it as `pub const zui_inspector: zui_reflect.Options(@This())` so misspelled options fail to compile");
        }
        break :declared T.zui_inspector;
    } else .{};

    for (@typeInfo(T).@"struct".fields) |field| {
        const field_options: FieldOptions = @field(options.fields, field.name);
        const field_path = @typeName(T) ++ "." ++ field.name;
        const is_number = switch (@typeInfo(field.type)) {
            .int, .float => true,
            else => false,
        };
        if (!is_number and (field_options.min != null or field_options.max != null or field_options.step != null)) {
            @compileError("zui_reflect: " ++ field_path ++ " is " ++ @typeName(field.type) ++ "; min, max and step only apply to numbers");
        }
        if (field_options.min != null and field_options.max != null and field_options.min.? > field_options.max.?) {
            @compileError(std.fmt.comptimePrint("zui_reflect: {s} has min {d} above max {d}", .{ field_path, field_options.min.?, field_options.max.? }));
        }
        if (field_options.step != null and !(field_options.step.? > 0)) {
            @compileError(std.fmt.comptimePrint("zui_reflect: {s} has step {d}; it must be above 0", .{ field_path, field_options.step.? }));
        }
        if (!field_options.hidden and !isEditable(field.type)) {
            @compileError("zui_reflect: " ++ field_path ++ " is " ++ @typeName(field.type) ++ ", which the inspector cannot edit; hide it with `.fields." ++ field.name ++ " = .{ .hidden = true }`");
        }
    }
    return options;
}

fn isEditable(comptime Field: type) bool {
    if (Field == zui_widgets.EditableText) return true;
    return switch (@typeInfo(Field)) {
        .bool, .int, .float => true,
        .@"enum" => |info| info.is_exhaustive and info.fields.len != 0,
        .pointer => Field == []const u8,
        .@"struct" => |info| info.layout != .@"packed",
        else => false,
    };
}

test {
    _ = @import("tests.zig");
}
