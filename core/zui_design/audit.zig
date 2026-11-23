const std = @import("std");
const zui = @import("zui");
const contrast = @import("contrast.zig");
const color_vision = @import("color_vision.zig");

const Rect = zui.Rect;
const WidgetState = zui.WidgetState;

/// What the audit checks.
pub const Check = enum {
    /// A line of text against what is painted beneath its middle.
    text_contrast,
    /// A border in the focus ring's color against what is painted just
    /// outside and just inside it.
    focus_ring_contrast,
    /// An interactive element narrower or shorter than the target floor.
    target_size,
    /// A line of text that runs past the side of the clip it is drawn in,
    /// where that clip does not scroll sideways.
    text_cut_short,
    /// Two interactive elements whose visible areas overlap, in one
    /// floating layer, neither inside the other.
    overlapping_controls,
    /// Two parts a component's `zuiDistinguish` pairs that are told apart
    /// in no color they draw under some simulated color vision.
    distinguish,
};

/// Every check.
pub const every_check: std.EnumSet(Check) = .initFull();

/// A contrast the audit measured, with the colors it measured it between.
pub const MeasuredContrast = struct {
    measured: contrast.Contrast,
    target: contrast.Target,
    /// As drawn, over the background when it is translucent.
    foreground: zui.Color,
    background: zui.Color,
};

/// What a finding measured, by its check.
pub const Measured = union(Check) {
    text_contrast: MeasuredContrast,
    focus_ring_contrast: MeasuredContrast,
    target_size: struct { size: [2]f32, floor: f32 },
    text_cut_short: struct {
        line: u32,
        line_width: f32,
        /// How much of the line lies inside its clip.
        shown_width: f32,
    },
    overlapping_controls: struct {
        other_element: u32,
        other_id: u64,
        overlap: Rect,
    },
    distinguish: struct {
        component: []const u8,
        first_part: []const u8,
        first_state: WidgetState,
        second_part: []const u8,
        second_state: WidgetState,
        deficiency: color_vision.Deficiency,
        lightness_difference: f32,
        least: f32,
    },
};

/// One thing the audit found: the element, the check and what it measured.
pub const Finding = struct {
    /// The element's index in the frame, as `Frame.inspect` takes it; null
    /// for a `distinguish` finding, which is of a component's appearance.
    element: ?u32,
    /// The element's id hash, as its commands carry it.
    id: u64 = 0,
    measured: Measured,

    pub fn check(self: Finding) Check {
        return self.measured;
    }
};

/// The findings of an audit, in the room its caller gave: the first that
/// fit, and a count of those past it.
pub const Findings = struct {
    room: []Finding,
    kept_count: u32 = 0,
    /// Found but not kept, past the room.
    dropped: u32 = 0,

    pub fn init(room: []Finding) Findings {
        return .{ .room = room };
    }

    pub fn record(self: *Findings, finding: Finding) void {
        if (self.kept_count == self.room.len) {
            self.dropped += 1;
            return;
        }
        self.room[self.kept_count] = finding;
        self.kept_count += 1;
    }

    pub fn slice(self: *const Findings) []const Finding {
        return self.room[0..self.kept_count];
    }

    /// True when the audit found nothing.
    pub fn isEmpty(self: *const Findings) bool {
        return self.kept_count == 0 and self.dropped == 0;
    }

    /// How many kept findings are of `check`.
    pub fn countOf(self: *const Findings, check: Check) usize {
        var count: usize = 0;
        for (self.slice()) |finding| count += @intFromBool(finding.check() == check);
        return count;
    }
};

/// What the audit holds a frame to.
pub const Options = struct {
    checks: std.EnumSet(Check) = every_check,
    /// What is beneath every command: the color the renderer clears to.
    page_background: zui.Color,
    /// Sets the targets of SPEC's contrast table.
    contrast: zui.Environment.Contrast = .normal,
    /// Text this size and larger is held to the large text's target.
    large_text_size: f32 = 18,
    /// The least width and height of an interactive element.
    target_floor: f32 = 24,
    /// A border drawn in this color is a focus ring; null checks none.
    focus_ring_color: ?zui.Color = null,

    /// The page, the focus ring, the floor and the large text's size of
    /// `tokens`, a `*const zui.design.Tokens(Ui, ExtraRoles)`.
    ///
    /// ```zig
    /// var room: [64]zui_design.Finding = undefined;
    /// const findings = zui_design.audit(frame, .fromTokens(&app.tokens, preferences.contrast), &room);
    /// ```
    pub fn fromTokens(tokens: anytype, contrast_setting: zui.Environment.Contrast) Options {
        return .{
            .page_background = encodedColor(tokens.colors.get(.idle).get(.background)),
            .contrast = contrast_setting,
            .large_text_size = tokens.text_styles.get(.title).size,
            .target_floor = tokens.target_floors.get(.pointer),
            .focus_ring_color = encodedColor(tokens.colors.get(.focused).get(.focus)),
        };
    }
};

/// Checks a finished frame's commands and elements, so custom drawing and
/// colors declared `.unchecked` are caught too, into `room`, allocating
/// nothing. A text's contrast is measured at the middle of each line,
/// against the topmost rectangle, border band or gradient painted there,
/// blending translucent ones, over `options.page_background`; a line over
/// an image, a material or a custom command, or one inside a transform, is
/// not measured, since the frame does not say what those paint. A text or
/// target of a disabled element is not checked.
///
/// Text and focus rings cost a walk back through the commands each, so
/// the audit costs commands × (texts + rings), and overlap a pair test of
/// the interactive elements.
///
/// ```zig
/// const frame = ui.endFrame();
/// var room: [32]zui_design.Finding = undefined;
/// var findings = zui_design.audit(frame, .{ .page_background = palette.background, .focus_ring_color = palette.focus }, &room);
/// zui_design.auditDistinguished(&tokens, .{ Chip, Tab }, &findings);
/// for (findings.slice()) |finding| log.warn("{t} at element {?d}", .{ finding.check(), finding.element });
/// ```
pub fn audit(frame: anytype, options: Options, room: []Finding) Findings {
    var findings: Findings = .init(room);
    const commands = frame.commands();
    if (options.checks.contains(.text_contrast) or options.checks.contains(.focus_ring_contrast)) checkContrasts(frame, commands, options, &findings);
    if (options.checks.contains(.target_size)) checkTargetSizes(frame, options, &findings);
    if (options.checks.contains(.text_cut_short)) checkTextCutShort(frame, commands, &findings);
    if (options.checks.contains(.overlapping_controls)) checkOverlaps(frame, &findings);
    return findings;
}

fn encodedColor(color: anytype) zui.Color {
    return if (@TypeOf(color) == zui.Color) color else color.toColor();
}

fn tagIs(comptime tag: anytype, comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, @tagName(tag), name);
}

fn checkContrasts(frame: anytype, commands: anytype, options: Options, findings: *Findings) void {
    var transform_depth: u32 = 0;
    var last_text_reported: ?u64 = null;
    var cursor: u32 = 0;
    for (commands, 0..) |command, index| switch (command.payload) {
        inline else => |payload, tag| {
            if (comptime tagIs(tag, "transform_begin")) transform_depth += 1;
            if (comptime tagIs(tag, "transform_end")) transform_depth -|= 1;
            if (comptime tagIs(tag, "text")) {
                const element = elementOf(frame, command.id, &cursor);
                const disabled = if (element) |found| isDisabledAt(frame, found) else false;
                if (options.checks.contains(.text_contrast) and transform_depth == 0 and last_text_reported != command.id and !disabled) {
                    const large = payload.style.size >= options.large_text_size;
                    const tier: contrast.Tier = if (large) .large_text else .text;
                    if (measuredAgainstBeneath(commands, index, middleOf(command.bounds), encodedColor(payload.style.color), tier.target(options.contrast), options.page_background)) |measured| {
                        if (!measured.measured.meets(measured.target)) {
                            findings.record(.{ .element = element, .id = command.id, .measured = .{ .text_contrast = measured } });
                            last_text_reported = command.id;
                        }
                    }
                }
            }
            if (comptime tagIs(tag, "border")) {
                if (options.focus_ring_color) |ring_color| {
                    if (options.checks.contains(.focus_ring_contrast) and transform_depth == 0 and encodedColor(payload.color).eql(ring_color)) {
                        checkFocusRing(commands, index, elementOf(frame, command.id, &cursor), command.id, command.bounds, payload.widths, ring_color, options, findings);
                    }
                }
            }
        },
    };
}

fn checkFocusRing(commands: anytype, index: usize, element: ?u32, id: u64, bounds: Rect, widths: zui.Edges, ring_color: zui.Color, options: Options, findings: *Findings) void {
    const middle_y = bounds.y + bounds.height / 2;
    const just_outside: [2]f32 = .{ bounds.x - 1, middle_y };
    const just_inside: [2]f32 = .{ bounds.x + widths.left + 1, middle_y };
    const target = contrast.Tier.non_text.target(options.contrast);
    var weakest: ?MeasuredContrast = null;
    for ([_][2]f32{ just_outside, just_inside }) |point| {
        const measured = measuredAgainstBeneath(commands, index, point, ring_color, target, options.page_background) orelse continue;
        if (weakest == null or @abs(measured.measured.lightness_contrast) < @abs(weakest.?.measured.lightness_contrast)) weakest = measured;
    }
    const found = weakest orelse return;
    if (!found.measured.meets(found.target)) findings.record(.{ .element = element, .id = id, .measured = .{ .focus_ring_contrast = found } });
}

fn middleOf(bounds: Rect) [2]f32 {
    return .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
}

fn measuredAgainstBeneath(commands: anytype, before: usize, point: [2]f32, foreground: zui.Color, target: contrast.Target, page: zui.Color) ?MeasuredContrast {
    const background = paintedBeneath(commands, before, point, page) orelse return null;
    const drawn = over(foreground, background);
    return .{ .measured = .of(drawn, background), .target = target, .foreground = drawn, .background = background };
}

/// `top` drawn over the opaque `bottom`, by its alpha.
fn over(top: zui.Color, bottom: zui.Color) zui.Color {
    var blended = bottom.mix(top, @as(f32, @floatFromInt(top.a)) / 255);
    blended.a = 255;
    return blended;
}

const Paint = union(enum) {
    nothing,
    color: zui.Color,
    /// An image, a material or a custom command, whose colors the frame
    /// does not carry.
    unknown,
};

/// More translucent layers than this over one point are blended as if
/// the deepest were opaque.
const max_translucent_layers = 8;
/// Clips deeper than this are taken to hide what they hold.
const max_clip_depth = 64;

/// What the commands before `before` paint at `point`, over `page`.
fn paintedBeneath(commands: anytype, before: usize, point: [2]f32, page: zui.Color) ?zui.Color {
    var layers: [max_translucent_layers]zui.Color = undefined;
    var layer_count: usize = 0;
    var clips: [max_clip_depth]Rect = undefined;
    var clip_depth: usize = 0;
    var clips_past_depth: usize = 0;
    var transforms_entered: u32 = 0;
    var base = page;
    var index = before;
    walk: while (index > 0) {
        index -= 1;
        const command = commands[index];
        switch (command.payload) {
            inline else => |payload, tag| {
                if (comptime tagIs(tag, "clip_end")) {
                    if (clip_depth < max_clip_depth) {
                        clips[clip_depth] = command.bounds;
                        clip_depth += 1;
                    } else clips_past_depth += 1;
                    continue :walk;
                }
                if (comptime tagIs(tag, "clip_begin")) {
                    if (clips_past_depth > 0) {
                        clips_past_depth -= 1;
                    } else if (clip_depth > 0) clip_depth -= 1;
                    continue :walk;
                }
                if (comptime tagIs(tag, "transform_end")) transforms_entered += 1;
                if (comptime tagIs(tag, "transform_begin")) transforms_entered -|= 1;
                const hidden = transforms_entered > 0 or clips_past_depth > 0 or
                    (clip_depth > 0 and !clips[clip_depth - 1].contains(point));
                if (hidden) continue :walk;
                switch (paintOf(tag, payload, command.bounds, point)) {
                    .nothing => {},
                    .unknown => return null,
                    .color => |color| {
                        if (color.a == 255 or layer_count == max_translucent_layers) {
                            base = color;
                            base.a = 255;
                            break :walk;
                        }
                        layers[layer_count] = color;
                        layer_count += 1;
                    },
                }
            },
        }
    }
    var blended = base;
    while (layer_count > 0) {
        layer_count -= 1;
        blended = over(layers[layer_count], blended);
    }
    return blended;
}

fn paintOf(comptime tag: anytype, payload: anytype, bounds: Rect, point: [2]f32) Paint {
    if (!bounds.contains(point)) return .nothing;
    if (comptime tagIs(tag, "rectangle")) return .{ .color = encodedColor(payload.color) };
    if (comptime tagIs(tag, "border")) {
        const widths = payload.widths;
        const inner: Rect = .{
            .x = bounds.x + widths.left,
            .y = bounds.y + widths.top,
            .width = bounds.width - widths.left - widths.right,
            .height = bounds.height - widths.top - widths.bottom,
        };
        return if (inner.contains(point)) .nothing else .{ .color = encodedColor(payload.color) };
    }
    if (comptime tagIs(tag, "gradient")) return .{ .color = encodedColor(payload.colorAt(bounds, point)) };
    if (comptime tagIs(tag, "backdrop_blur")) return .{ .color = encodedColor(payload.tint) };
    if (comptime tagIs(tag, "image") or tagIs(tag, "material") or tagIs(tag, "custom")) return .unknown;
    return .nothing;
}

/// The element a command was emitted for: by its id when it declared one,
/// and otherwise searched for from `cursor` on, where the last was found,
/// since commands come in nearly the order their elements were declared.
fn elementOf(frame: anytype, id: u64, cursor: *u32) ?u32 {
    if (frame.lookup(id)) |index| return index;
    const element_count: u32 = frame.elementCount();
    var index = cursor.*;
    for (0..element_count) |_| {
        if (index >= element_count) index = 0;
        if (frame.inspect(@intCast(index)).id == id) {
            cursor.* = index;
            return index;
        }
        index += 1;
    }
    return null;
}

fn isDisabledAt(frame: anytype, element: anytype) bool {
    var current: @TypeOf(frame.elementCount()) = @intCast(element);
    while (true) {
        const view = frame.inspect(current);
        if (view.flags.disabled) return true;
        current = view.parent orelse return false;
    }
}

fn checkTargetSizes(frame: anytype, options: Options, findings: *Findings) void {
    const element_count = frame.elementCount();
    for (0..element_count) |element_index| {
        const element: @TypeOf(element_count) = @intCast(element_index);
        const view = frame.inspect(element);
        if (!view.flags.interactive or isDisabledAt(frame, element)) continue;
        if (visibleRectOf(frame, element).isEmpty()) continue;
        const size: [2]f32 = .{ view.rect.width, view.rect.height };
        if (size[0] + size_tolerance >= options.target_floor and size[1] + size_tolerance >= options.target_floor) continue;
        findings.record(.{ .element = element, .id = view.id, .measured = .{ .target_size = .{ .size = size, .floor = options.target_floor } } });
    }
}

/// Snapping to pixels moves an edge by under one.
const size_tolerance = 0.5;

/// The element's rectangle inside every clip around it, up to the floating
/// layer it is in, unless that layer is cut off by its target's clip.
fn visibleRectOf(frame: anytype, element: anytype) Rect {
    var visible = frame.inspect(element).rect;
    var current = element;
    while (true) {
        const view = frame.inspect(current);
        if (view.flags.floating and !view.flags.clips_to_target) return visible;
        const parent = view.parent orelse return visible;
        const parent_view = frame.inspect(parent);
        if (parent_view.flags.clip_x) visible = clippedOnAxis(visible, parent_view.rect, .x);
        if (parent_view.flags.clip_y) visible = clippedOnAxis(visible, parent_view.rect, .y);
        current = parent;
    }
}

fn clippedOnAxis(rect: Rect, clip: Rect, axis: enum { x, y }) Rect {
    var clipped = rect;
    switch (axis) {
        .x => {
            const left = @max(rect.x, clip.x);
            const right = @min(rect.x + rect.width, clip.x + clip.width);
            clipped.x = left;
            clipped.width = @max(0, right - left);
        },
        .y => {
            const top = @max(rect.y, clip.y);
            const bottom = @min(rect.y + rect.height, clip.y + clip.height);
            clipped.y = top;
            clipped.height = @max(0, bottom - top);
        },
    }
    return clipped;
}

/// The floating element an element is in, itself if it floats, or null for
/// the root's layer.
fn floatingLayerOf(frame: anytype, element: anytype) ?@TypeOf(element) {
    var current = element;
    while (true) {
        const view = frame.inspect(current);
        if (view.flags.floating) return current;
        current = view.parent orelse return null;
    }
}

fn checkOverlaps(frame: anytype, findings: *Findings) void {
    const element_count = frame.elementCount();
    for (0..element_count) |first_index| {
        const first: @TypeOf(element_count) = @intCast(first_index);
        const first_view = frame.inspect(first);
        if (!first_view.flags.interactive or isDisabledAt(frame, first)) continue;
        const first_visible = visibleRectOf(frame, first);
        if (first_visible.isEmpty()) continue;
        const first_layer = floatingLayerOf(frame, first);
        var second = first_view.subtree_end;
        while (second < element_count) : (second += 1) {
            const second_view = frame.inspect(second);
            if (!second_view.flags.interactive or !overlapsEnough(first_visible, second_view.rect)) continue;
            if (isDisabledAt(frame, second) or floatingLayerOf(frame, second) != first_layer) continue;
            const overlap = first_visible.intersect(visibleRectOf(frame, second));
            if (!overlapsEnough(first_visible, overlap)) continue;
            findings.record(.{ .element = first, .id = first_view.id, .measured = .{ .overlapping_controls = .{ .other_element = second, .other_id = second_view.id, .overlap = overlap } } });
        }
    }
}

fn checkTextCutShort(frame: anytype, commands: anytype, findings: *Findings) void {
    var clips: [max_clip_depth]Rect = undefined;
    var clips_scrolling_sideways: u64 = 0;
    var clip_depth: usize = 0;
    var clips_past_depth: usize = 0;
    var last_reported: ?u64 = null;
    var cursor: u32 = 0;
    var clip_cursor: u32 = 0;
    for (commands) |command| switch (command.payload) {
        inline else => |payload, tag| {
            if (comptime tagIs(tag, "clip_begin")) {
                if (clip_depth < max_clip_depth) {
                    clips[clip_depth] = payload;
                    const bit = @as(u64, 1) << @intCast(clip_depth);
                    clips_scrolling_sideways = if (scrollsSideways(frame, command.id, &clip_cursor)) clips_scrolling_sideways | bit else clips_scrolling_sideways & ~bit;
                    clip_depth += 1;
                } else clips_past_depth += 1;
            }
            if (comptime tagIs(tag, "clip_end")) {
                if (clips_past_depth > 0) {
                    clips_past_depth -= 1;
                } else clip_depth -|= 1;
            }
            if (comptime tagIs(tag, "text")) {
                const inside_sideways_scroll = clip_depth > 0 and clips_scrolling_sideways & lowBits(clip_depth) != 0;
                if (clip_depth > 0 and clips_past_depth == 0 and !inside_sideways_scroll and last_reported != command.id) {
                    const clip = clips[clip_depth - 1];
                    const line = command.bounds;
                    const runs_past = line.x < clip.x - size_tolerance or line.x + line.width > clip.x + clip.width + size_tolerance;
                    if (runs_past) {
                        const shown = line.intersect(clip);
                        findings.record(.{ .element = elementOf(frame, command.id, &cursor), .id = command.id, .measured = .{ .text_cut_short = .{ .line = payload.line, .line_width = line.width, .shown_width = shown.width } } });
                        last_reported = command.id;
                    }
                }
            }
        },
    };
}

fn lowBits(count: usize) u64 {
    return if (count >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(count)) - 1;
}

fn scrollsSideways(frame: anytype, id: u64, cursor: *u32) bool {
    const element = elementOf(frame, id, cursor) orelse return false;
    return frame.inspect(@intCast(element)).flags.scroll_x;
}

/// Adds a `distinguish` finding for each entry of each component's
/// `zuiDistinguish` that `tokens` draw too alike under some simulated
/// color vision, in the colors `tokens.look` gives the parts: a run-time
/// check of what `checkDistinguished` checks of a design at comptime,
/// which sees a chosen accent and color vision too. A pair either of whose
/// parts declares a `cue` is not measured.
///
/// ```zig
/// zui_design.auditDistinguished(&app.tokens, .{ Checkbox, Tab }, &findings);
/// ```
pub fn auditDistinguished(tokens: anytype, comptime components: anytype, findings: *Findings) void {
    inline for (components) |Component| {
        if (comptime !@hasDecl(Component, "zuiDistinguish")) continue;
        inline for (Component.zuiDistinguish) |entry| {
            const first_part: Component.Part = entry[0];
            const second_part: Component.Part = if (entry.len == 2) entry[1] else entry[0];
            const first_state: WidgetState = if (entry.len == 2) .idle else entry[1];
            const second_state: WidgetState = if (entry.len == 2) .idle else entry[2];
            const Appearance = Component.zuiAppearance;
            const cued = comptime hasCue(Appearance.of(first_part)) or hasCue(Appearance.of(second_part));
            if (!cued) {
                const first = drawnOf(tokens, Component, first_part, first_state);
                const second = drawnOf(tokens, Component, second_part, second_state);
                if (collapseOf(first, second)) |collapse| findings.record(.{ .element = null, .measured = .{ .distinguish = .{
                    .component = @typeName(Component),
                    .first_part = @tagName(first_part),
                    .first_state = first_state,
                    .second_part = @tagName(second_part),
                    .second_state = second_state,
                    .deficiency = collapse.deficiency,
                    .lightness_difference = collapse.lightness_difference,
                    .least = color_vision.least_lightness_difference,
                } } });
            }
        }
    }
}

fn hasCue(comptime part: anytype) bool {
    const cue = part.cue orelse return false;
    return cue.len > 0;
}

/// The colors a part draws in one state: its surface, or the one it is
/// drawn on; its text or icon; and its outline, or its surface.
const Drawn = struct {
    surface: ?zui.Color,
    foreground: ?zui.Color,
    outline: ?zui.Color,
};

fn drawnOf(tokens: anytype, comptime Component: type, comptime part: Component.Part, comptime state: WidgetState) Drawn {
    const declared = comptime Component.zuiAppearance.of(part);
    const colors = comptime declared.colorsIn(state);
    const look = tokens.look(Component, part, state);
    const own_surface: ?zui.Color = if (look.decoration.background) |background| encodedColor(background) else null;
    const surface = own_surface orelse if (declared.on) |on| beneath: {
        const beneath_look = tokens.look(Component, @field(Component.Part, @tagName(on)), state);
        break :beneath if (beneath_look.decoration.background) |background| encodedColor(background) else null;
    } else null;
    const draws_foreground = comptime colors.text != null or colors.icon != null;
    return .{
        .surface = surface,
        .foreground = if (draws_foreground) encodedColor(look.text.color) else null,
        .outline = if (look.decoration.border) |border| encodedColor(border.color) else surface,
    };
}

const Collapse = struct {
    deficiency: color_vision.Deficiency,
    lightness_difference: f32,
};

fn collapseOf(first: Drawn, second: Drawn) ?Collapse {
    var farthest: std.EnumArray(color_vision.Deficiency, f32) = .initFill(0);
    inline for (.{ "surface", "foreground", "outline" }) |channel| {
        if (@field(first, channel)) |first_color| if (@field(second, channel)) |second_color| {
            const differences = color_vision.lightnessDifferencesOfColors(first_color, second_color);
            for (std.enums.values(color_vision.Deficiency)) |deficiency| farthest.set(deficiency, @max(farthest.get(deficiency), differences.get(deficiency)));
        };
    }
    for (std.enums.values(color_vision.Deficiency)) |deficiency| {
        if (farthest.get(deficiency) < color_vision.least_lightness_difference) return .{ .deficiency = deficiency, .lightness_difference = farthest.get(deficiency) };
    }
    return null;
}

fn overlapsEnough(first: Rect, second: Rect) bool {
    const overlap = first.intersect(second);
    return overlap.width > size_tolerance and overlap.height > size_tolerance;
}
