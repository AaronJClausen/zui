const std = @import("std");
const Rect = @import("style.zig").Rect;

/// What an element is to an assistive technology, which a host maps to
/// the platform's nearest control type.
pub const Role = enum(u8) {
    group,
    button,
    link,
    checkbox,
    /// On or off, as a switch.
    toggle,
    radio,
    slider,
    progress_bar,
    text_field,
    /// A button that opens a list to choose from.
    combo_box,
    list_box,
    /// One choice in a `list_box`.
    option,
    label,
    heading,
    image,
    dialog,
    scroll_area,
};

/// A slider's or a progress bar's position in its range.
pub const Range = struct {
    value: f64,
    min: f64 = 0,
    max: f64 = 1,
    /// What one `adjust` step moves it by; 0 when it moves continuously.
    step: f64 = 0,
};

pub const Value = union(enum) {
    none,
    /// A text field's contents, or a combo box's choice. Copied when the
    /// element is declared.
    text: []const u8,
    range: Range,
};

pub const State = struct {
    /// Null when it cannot be checked.
    checked: ?bool = null,
    /// Null when it neither expands nor collapses.
    expanded: ?bool = null,
    selected: bool = false,
    /// Also set by the element's own `disabled`.
    disabled: bool = false,
    /// Set by zui, from the focus the frame was declared with.
    focused: bool = false,
};

/// What an assistive technology can ask an element to do.
pub const ActionKind = enum(u8) {
    /// Answered by `clicked`.
    invoke,
    /// Moves focus to the element, as Tab would.
    focus,
    /// Answered by `adjusted`.
    adjust,
    /// Scrolls a scroll container, and is answered by `manipulation`.
    scroll,
    /// Answered by `contextRequested`.
    show_menu,
    /// Answered by `dismissed`.
    dismiss,
};

pub const Actions = std.EnumSet(ActionKind);

pub const Action = union(ActionKind) {
    invoke,
    focus,
    /// Steps up (positive) or down, as the arrow keys move a slider.
    adjust: i32,
    /// In layout units, as the wheel's delta: positive moves the view down
    /// and to the right.
    scroll: [2]f32,
    show_menu,
    dismiss,
};

/// The `action` event: an assistive technology's request, which a host
/// reports in the record.
///
/// ```zig
/// builder.append(.{ .action = .{ .target = node.id, .action = .invoke } });
/// ```
pub const ActionEvent = struct {
    /// The `SemanticNode.id` it names.
    target: u64,
    action: Action,
};

/// What `Element.semantics` declares. Ignored without
/// `Config.features.semantics`, so a widget can declare it for every
/// context.
///
/// ```zig
/// ui.open(.{ .id = .of("save"), .focusable = true, .semantics = .{ .role = .button, .label = "Save" } });
/// ```
pub const Semantics = struct {
    role: Role,
    /// Copied when the element is declared.
    label: []const u8 = "",
    value: Value = .none,
    state: State = .{},
    /// Beyond those its flags and gestures report: `invoke` when it is
    /// interactive, `focus` when it is focusable, `scroll` when it
    /// scrolls or pans, and `show_menu` when it takes a long press.
    actions: Actions = .initEmpty(),
    /// A heading's level, 1 for the topmost; 0 when it has none.
    level: u8 = 0,
};

/// Where a scroll container's view lies over its content, in layout units,
/// as its last layout placed it.
pub const SemanticScroll = struct {
    /// How far the view has moved from the content's start, per axis.
    offset: [2]f32,
    /// The size of everything it scrolls over, per axis.
    content: [2]f32,
    /// The size of the part it shows, per axis.
    viewport: [2]f32,
    /// Whether it scrolls horizontally, then vertically.
    axes: [2]bool,
};

/// One accessible element, as `Frame.semantics()` lists it.
pub const SemanticNode = struct {
    id: u64,
    /// The index in the list of the nearest enclosing element with
    /// semantics; null for one with none around it.
    parent: ?u32,
    role: Role,
    /// Valid until the frame is released, as `value`'s text is.
    label: []const u8,
    value: Value,
    /// As laid out, untransformed.
    bounds: Rect,
    state: State,
    /// Empty while it is disabled.
    actions: Actions,
    /// As `Semantics.level` declares it.
    level: u8 = 0,
    /// For an element that scrolls; null for one that does not.
    scroll: ?SemanticScroll = null,
};

/// How much of `Frame.semantics()` a window's accessibility bridge holds.
/// `zui_app` opens the window with `Config.limits`' `max_elements` and
/// `max_text_bytes` when `features.semantics` is on; zero nodes, the
/// default, opens it with no bridge.
pub const SemanticsCapacity = struct {
    nodes: u32 = 0,
    text_bytes: u32 = 0,
};

/// What a host's `zuiSemantics` had no room for: the nodes past those that
/// fit, cut from the end of the list so what is kept is still a tree, and
/// the label and value bytes cut at a character.
pub const SemanticsDropped = struct {
    nodes: u32 = 0,
    text_bytes: u32 = 0,

    pub fn any(self: SemanticsDropped) bool {
        return self.nodes != 0 or self.text_bytes != 0;
    }
};
