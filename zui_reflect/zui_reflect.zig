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
        if (inspectField(widgets, ui, id.child(field.name), label, field.type, &@field(value, field.name), field_options)) changed = true;
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
    comptime options: FieldOptions,
) bool {
    if (Field == zui_widgets.EditableText) {
        widgets.labeledRow(ui, label);
        defer ui.close();
        return widgets.textField(ui, id, field, .{ .placeholder = options.placeholder }).changed;
    }
    switch (@typeInfo(Field)) {
        .bool => {
            widgets.labeledRow(ui, label);
            defer ui.close();
            return widgets.checkbox(ui, id, "", field, .{});
        },
        .int, .float => {
            widgets.labeledRow(ui, label);
            defer ui.close();
            if (options.min != null and options.max != null) {
                const changed = widgets.slider(ui, id, field, .{ .min = options.min.?, .max = options.max.?, .step = options.step });
                numberLabel(widgets, ui, field.*);
                return changed;
            }
            return stepper(widgets, ui, id, Field, field, options);
        },
        .@"enum" => {
            widgets.labeledRow(ui, label);
            defer ui.close();
            return widgets.dropdownEnum(ui, id, field, .{});
        },
        .pointer => {
            widgets.labeledRow(ui, label);
            defer ui.close();
            widgets.label(ui, field.*);
            return false;
        },
        .@"struct" => {
            const section = ui.state(id, Section);
            var expanded = !section.collapsed;
            if (widgets.disclosure(ui, id, label, &expanded)) section.collapsed = !expanded;
            if (!expanded) return false;
            ui.open(.{ .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .width = .grow },
                .padding = .{ .left = widgets.activeTheme(ui).horizontal_padding + widgets.activeTheme(ui).gap },
                .child_gap = 4,
            } });
            defer ui.close();
            return inspectFields(widgets, ui, id, Field, field);
        },
        else => comptime unreachable,
    }
}

fn stepper(widgets: anytype, ui: *@TypeOf(widgets).Ui, id: zui.Id, comptime Number: type, number: *Number, comptime options: FieldOptions) bool {
    const previous = number.*;
    const square: zui.Sizing = .fixed(widgets.activeTheme(ui).control_height);
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
