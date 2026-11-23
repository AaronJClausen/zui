const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");

const Density = zui.design.Density;
const WidgetState = zui.WidgetState;

/// The text scales a component is seen at.
pub const TextScale = enum {
    @"100%",
    @"150%",
    @"200%",

    pub fn factor(self: TextScale) f32 {
        return switch (self) {
            .@"100%" => 1,
            .@"150%" => 1.5,
            .@"200%" => 2,
        };
    }
};

/// One value of every axis a component is seen under but its content; the
/// defaults are what a user who changed nothing sees.
pub const Axes = struct {
    theme: zui.Environment.Theme = .light,
    contrast: zui.Environment.Contrast = .normal,
    density: Density = .comfortable,
    text_scale: TextScale = .@"100%",
    color_vision: zui_design.ColorVision = .typical,
    direction: zui.ReadingDirection = .left_to_right,
    corners: zui_design.CornerPreference = .as_designed,
    reduced_transparency: bool = false,
    state: WidgetState = .idle,

    /// `base`, the user's other preferences, under these axes.
    ///
    /// ```zig
    /// _ = zui_design.resolve(app.design, permutation.axes.preferences(.{}), &tokens);
    /// ```
    pub fn preferences(self: Axes, base: zui_design.Preferences) zui_design.Preferences {
        var result = base;
        result.theme = self.theme;
        result.contrast = self.contrast;
        result.text_scale = self.text_scale.factor();
        result.reduced_transparency = self.reduced_transparency;
        result.density = self.density;
        result.color_vision = self.color_vision;
        result.corners = self.corners;
        return result;
    }

    /// The environment changes that set these axes, for a frame's events.
    ///
    /// ```zig
    /// var events: [zui_design.Axes.environment_change_count]zui.Event = undefined;
    /// for (permutation.axes.environmentChanges(), &events) |change, *event| event.* = .{ .environment = change };
    /// ```
    pub fn environmentChanges(self: Axes) [environment_change_count]zui.EnvironmentChange {
        return .{
            .{ .theme = self.theme },
            .{ .contrast = self.contrast },
            .{ .text_scale = self.text_scale.factor() },
            .{ .reduced_transparency = self.reduced_transparency },
            .{ .direction = self.direction },
        };
    }

    pub const environment_change_count = 5;
};

/// An axis of `Axes`, or the component's `preview`.
pub const Axis = enum {
    theme,
    contrast,
    density,
    text_scale,
    color_vision,
    direction,
    corners,
    reduced_transparency,
    state,
    preview,
};

const axes_fields = std.meta.fields(Axes);
const axis_count = @typeInfo(Axis).@"enum".fields.len;

comptime {
    for (axes_fields, 0..) |field, index| std.debug.assert(std.mem.eql(u8, field.name, @tagName(@as(Axis, @enumFromInt(index)))));
    std.debug.assert(axes_fields.len + 1 == axis_count);
}

/// One way a component is seen: its axes and the index of its preview.
pub const Permutation = struct {
    axes: Axes = .{},
    /// Into the component's `zuiPreviews`, in declaration order; 0 for one
    /// that declares none.
    preview: u16 = 0,
};

/// How many permutations a review steps through.
pub const Level = enum {
    /// The defaults and the extremes that break things together.
    glance,
    /// Each axis through its values, the others at their defaults.
    sweep,
    /// Every pair of two axes' values in at least one permutation.
    pairs,
    /// Every combination.
    full,
};

/// What a component without `zuiPreviews` is shown with.
pub const as_declared = "as_declared";

fn valueCountOf(comptime field_type: type) usize {
    return if (field_type == bool) 2 else @typeInfo(field_type).@"enum".fields.len;
}

fn valueAt(comptime field_type: type, index: usize) field_type {
    if (field_type == bool) return index != 0;
    return std.enums.values(field_type)[index];
}

fn indexOfValue(value: anytype) usize {
    if (@TypeOf(value) == bool) return @intFromBool(value);
    for (std.enums.values(@TypeOf(value)), 0..) |candidate, index| if (candidate == value) return index;
    unreachable;
}

/// The values of `axis` a component with `preview_count` previews has.
pub fn valueCount(axis: Axis, preview_count: usize) usize {
    inline for (axes_fields, 0..) |field, index| {
        if (@intFromEnum(axis) == index) return valueCountOf(field.type);
    }
    return preview_count;
}

/// The index of `permutation`'s value of `axis`.
pub fn valueIndex(permutation: Permutation, axis: Axis) usize {
    inline for (axes_fields, 0..) |field, index| {
        if (@intFromEnum(axis) == index) return indexOfValue(@field(permutation.axes, field.name));
    }
    return permutation.preview;
}

fn withValue(permutation: Permutation, axis: Axis, index: usize) Permutation {
    var result = permutation;
    inline for (axes_fields, 0..) |field, field_index| {
        if (@intFromEnum(axis) == field_index) {
            @field(result.axes, field.name) = valueAt(field.type, index);
            return result;
        }
    }
    result.preview = @intCast(index);
    return result;
}

fn valueCounts(comptime preview_count: usize) [axis_count]usize {
    @setEvalBranchQuota(100_000);
    var counts: [axis_count]usize = undefined;
    for (std.enums.values(Axis), &counts) |axis, *count| count.* = valueCount(axis, preview_count);
    return counts;
}

/// The number of previews `Component` declares, 1 for none.
pub fn previewCountOf(comptime Component: type) usize {
    if (!@hasDecl(Component, "zuiPreviews")) return 1;
    comptime zui.checkPreviews(Component);
    return std.meta.fields(@TypeOf(Component.zuiPreviews)).len;
}

/// Every permutation of `Component` at `level`, with its previews from its
/// `zuiPreviews` as the content axis. `glance`, `sweep` and `pairs` are made
/// at comptime; `full` is counted and decoded by index, since it runs to
/// tens of thousands.
///
/// ```zig
/// const Glance = zui_design.Permutations(Chip, .glance);
/// for (0..Glance.count) |index| {
///     const permutation = Glance.at(index);
///     _ = zui_design.resolve(app.design, permutation.axes.preferences(.{}), &tokens);
///     declareChip(&ui, Glance.preview(permutation), tokens.look(Chip, .container, permutation.axes.state));
/// }
/// ```
pub fn Permutations(comptime Component: type, comptime level: Level) type {
    return struct {
        pub const preview_count = previewCountOf(Component);
        const counts = valueCounts(preview_count);
        const listed: []const Permutation = switch (level) {
            .glance => &glanceOf(preview_count),
            .sweep => &sweepOf(preview_count),
            .pairs => &pairsOf(preview_count),
            .full => &.{},
        };
        pub const count: usize = if (level == .full) fullCount() else listed.len;

        fn fullCount() usize {
            var product: usize = 1;
            for (counts) |values| product *= values;
            return product;
        }

        pub fn at(index: usize) Permutation {
            std.debug.assert(index < count);
            if (level != .full) return listed[index];
            var remaining = index;
            var permutation: Permutation = .{};
            for (std.enums.values(Axis), counts) |axis, values| {
                permutation = withValue(permutation, axis, remaining % values);
                remaining /= values;
            }
            return permutation;
        }

        /// The name of the preview `permutation` shows.
        pub fn previewName(permutation: Permutation) []const u8 {
            if (comptime !@hasDecl(Component, "zuiPreviews")) return as_declared;
            return preview_names[permutation.preview];
        }

        const preview_names: [preview_count][]const u8 = if (@hasDecl(Component, "zuiPreviews")) std.meta.fieldNames(@TypeOf(Component.zuiPreviews)).* else .{as_declared};

        /// The content `permutation` shows, one of `Component.zuiPreviews`.
        pub fn preview(permutation: Permutation) PreviewType() {
            return previews[permutation.preview];
        }

        fn PreviewType() type {
            if (!@hasDecl(Component, "zuiPreviews")) return void;
            return std.meta.fields(@TypeOf(Component.zuiPreviews))[0].type;
        }

        const previews: [preview_count]PreviewType() = if (@hasDecl(Component, "zuiPreviews")) previews: {
            var values: [preview_count]PreviewType() = undefined;
            for (std.meta.fieldNames(@TypeOf(Component.zuiPreviews)), &values) |name, *value| value.* = @field(Component.zuiPreviews, name);
            break :previews values;
        } else .{{}};

        /// `permutation`'s key, under `Component`'s type name.
        pub fn key(permutation: Permutation) PermutationKey {
            return .{ .component = @typeName(Component), .preview = previewName(permutation), .axes = permutation.axes };
        }
    };
}

/// The defaults, dark, dark at high contrast, compact at 200%, and every
/// extreme together, right to left; each further preview at the defaults
/// and at every extreme together.
fn glanceOf(comptime preview_count: usize) [5 + 2 * (preview_count - 1)]Permutation {
    const extremes: Axes = .{ .theme = .dark, .contrast = .high, .density = .compact, .text_scale = .@"200%", .direction = .right_to_left };
    var result: [5 + 2 * (preview_count - 1)]Permutation = undefined;
    result[0] = .{};
    result[1] = .{ .axes = .{ .theme = .dark } };
    result[2] = .{ .axes = .{ .theme = .dark, .contrast = .high } };
    result[3] = .{ .axes = .{ .density = .compact, .text_scale = .@"200%" } };
    result[4] = .{ .axes = extremes };
    for (1..preview_count) |preview_index| {
        result[3 + 2 * preview_index] = .{ .preview = @intCast(preview_index) };
        result[4 + 2 * preview_index] = .{ .axes = extremes, .preview = @intCast(preview_index) };
    }
    return result;
}

fn sweepCount(comptime preview_count: usize) usize {
    @setEvalBranchQuota(100_000);
    var total: usize = 1;
    for (valueCounts(preview_count)) |values| total += values - 1;
    return total;
}

/// The defaults once, then each axis's other values in turn.
fn sweepOf(comptime preview_count: usize) [sweepCount(preview_count)]Permutation {
    @setEvalBranchQuota(100_000);
    var result: [sweepCount(preview_count)]Permutation = undefined;
    result[0] = .{};
    var next: usize = 1;
    for (std.enums.values(Axis)) |axis| {
        const default_index = valueIndex(.{}, axis);
        for (0..valueCount(axis, preview_count)) |value| {
            if (value == default_index) continue;
            result[next] = withValue(.{}, axis, value);
            next += 1;
        }
    }
    return result;
}

/// A covering array of strength 2, built greedily: each row starts from the
/// first pair still uncovered and gives every other axis the value that
/// covers the most new pairs with the axes already set, the lowest on a tie.
fn pairsOf(comptime preview_count: usize) [pairsCount(preview_count)]Permutation {
    @setEvalBranchQuota(10_000_000);
    const rows = coveringRows(preview_count);
    var result: [rows.len]Permutation = undefined;
    for (rows, &result) |row, *permutation| {
        permutation.* = .{};
        for (std.enums.values(Axis), row) |axis, value| permutation.* = withValue(permutation.*, axis, value);
    }
    return result;
}

fn pairsCount(comptime preview_count: usize) usize {
    @setEvalBranchQuota(10_000_000);
    return coveringRows(preview_count).len;
}

const max_values = 8;
const Covered = [axis_count][max_values][axis_count][max_values]bool;

fn coveringRows(comptime preview_count: usize) []const [axis_count]usize {
    @setEvalBranchQuota(10_000_000);
    const counts = valueCounts(preview_count);
    for (counts) |values| if (values > max_values) @compileError("zui_design: a component's previews number at most 8 for `pairs`");
    var covered: Covered = @splat(@splat(@splat(@splat(false))));
    var rows: []const [axis_count]usize = &.{};
    while (firstUncovered(&covered, counts)) |pair| {
        var row: [axis_count]?usize = @splat(null);
        row[pair[0]] = pair[1];
        row[pair[2]] = pair[3];
        for (0..axis_count) |axis| {
            if (row[axis] != null) continue;
            var best_value: usize = 0;
            var best_gain: usize = 0;
            for (0..counts[axis]) |value| {
                var gain: usize = 0;
                for (0..axis_count) |other| {
                    const other_value = row[other] orelse continue;
                    if (!covered[axis][value][other][other_value]) gain += 1;
                }
                if (gain > best_gain) {
                    best_gain = gain;
                    best_value = value;
                }
            }
            row[axis] = best_value;
        }
        var complete: [axis_count]usize = undefined;
        for (row, &complete) |value, *slot| slot.* = value.?;
        for (0..axis_count) |first| {
            for (0..axis_count) |second| {
                if (first != second) covered[first][complete[first]][second][complete[second]] = true;
            }
        }
        rows = rows ++ .{complete};
    }
    return rows;
}

fn firstUncovered(covered: *const Covered, counts: [axis_count]usize) ?[4]usize {
    for (0..axis_count) |first| {
        for (first + 1..axis_count) |second| {
            for (0..counts[first]) |first_value| {
                for (0..counts[second]) |second_value| {
                    if (!covered[first][first_value][second][second_value]) return .{ first, first_value, second, second_value };
                }
            }
        }
    }
    return null;
}

/// What names a permutation from one build to the next: its component, its
/// preview and every axis value. It formats as
/// `component/preview/theme=dark,contrast=high,…`, every axis in `Axis`
/// order, and parses back from that, so a review keeps its verdicts by it.
pub const PermutationKey = struct {
    component: []const u8,
    preview: []const u8 = as_declared,
    axes: Axes = .{},

    pub fn format(self: PermutationKey, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}/{s}/", .{ self.component, self.preview });
        inline for (axes_fields, 0..) |field, index| {
            if (index > 0) try writer.writeByte(',');
            const value = @field(self.axes, field.name);
            if (field.type == bool) {
                try writer.print("{s}={}", .{ field.name, value });
            } else {
                try writer.print("{s}={t}", .{ field.name, value });
            }
        }
    }

    pub const ParseError = error{ MalformedKey, UnknownAxis, UnknownValue, RepeatedAxis, MissingAxis };

    /// The key `text` formats as, its names slices of `text`.
    ///
    /// ```zig
    /// const key: zui_design.PermutationKey = try .parse("demo.Chip/long/theme=dark,contrast=normal,…");
    /// ```
    pub fn parse(text: []const u8) ParseError!PermutationKey {
        var parts = std.mem.splitScalar(u8, text, '/');
        const component = parts.next() orelse return error.MalformedKey;
        const preview = parts.next() orelse return error.MalformedKey;
        const values = parts.next() orelse return error.MalformedKey;
        if (parts.next() != null or component.len == 0 or preview.len == 0) return error.MalformedKey;
        var key: PermutationKey = .{ .component = component, .preview = preview };
        var seen: std.EnumSet(std.meta.FieldEnum(Axes)) = .initEmpty();
        var assignments = std.mem.splitScalar(u8, values, ',');
        while (assignments.next()) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.MalformedKey;
            const axis_name = assignment[0..equals];
            const value_name = assignment[equals + 1 ..];
            const axis = std.meta.stringToEnum(std.meta.FieldEnum(Axes), axis_name) orelse return error.UnknownAxis;
            if (seen.contains(axis)) return error.RepeatedAxis;
            seen.insert(axis);
            inline for (axes_fields) |field| {
                if (std.mem.eql(u8, field.name, axis_name)) {
                    @field(key.axes, field.name) = if (field.type == bool)
                        (if (std.mem.eql(u8, value_name, "true")) true else if (std.mem.eql(u8, value_name, "false")) false else return error.UnknownValue)
                    else
                        std.meta.stringToEnum(field.type, value_name) orelse return error.UnknownValue;
                }
            }
        }
        if (seen.count() != axes_fields.len) return error.MissingAxis;
        return key;
    }

    pub fn eql(self: PermutationKey, other: PermutationKey) bool {
        return std.mem.eql(u8, self.component, other.component) and std.mem.eql(u8, self.preview, other.preview) and std.meta.eql(self.axes, other.axes);
    }
};

/// A hash of `commands`, a frame's render commands, that is the same in
/// every build mode and on every target: each command's fields in their
/// declared order, integers little-endian at fixed widths, floats by their
/// bits with `-0` taken as `0` and every NaN as one, enums and union tags by
/// name and text by its bytes; never padding or a pointer. It runs at
/// comptime too.
///
/// ```zig
/// const frame = ui.endFrame();
/// const hash = zui_design.hashCommands(frame.commands());
/// ```
pub fn hashCommands(commands: anytype) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (commands) |command| hashValue(&hasher, command);
    return hasher.final();
}

fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => hasher.update(&.{@intFromBool(value)}),
        .int => |int| {
            const Wide = std.meta.Int(int.signedness, (int.bits + 7) / 8 * 8);
            var bytes: [@sizeOf(Wide)]u8 = undefined;
            std.mem.writeInt(Wide, &bytes, value, .little);
            hasher.update(&bytes);
        },
        .float => |float| {
            const Bits = std.meta.Int(.unsigned, float.bits);
            const normalized: T = if (std.math.isNan(value)) std.math.nan(T) else if (value == 0) 0 else value;
            hashValue(hasher, @as(Bits, @bitCast(normalized)));
        },
        .@"enum" => hashName(hasher, @tagName(value)),
        .optional => if (value) |present| {
            hasher.update(&.{1});
            hashValue(hasher, present);
        } else hasher.update(&.{0}),
        .array => for (value) |element| hashValue(hasher, element),
        .@"struct" => |structure| inline for (structure.fields) |field| hashValue(hasher, @field(value, field.name)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                hashName(hasher, @tagName(tag));
                hashValue(hasher, payload);
            },
        },
        .pointer => |pointer| {
            if (pointer.size != .slice or pointer.child != u8) @compileError("zui_design: hashCommands cannot hash " ++ @typeName(T) ++ ", which points elsewhere");
            hashValue(hasher, @as(u64, value.len));
            hasher.update(value);
        },
        else => @compileError("zui_design: hashCommands cannot hash " ++ @typeName(T)),
    }
}

fn hashName(hasher: *std.hash.Wyhash, name: []const u8) void {
    hashValue(hasher, @as(u8, @intCast(name.len)));
    hasher.update(name);
}
