const Rect = @import("style.zig").Rect;

/// What part of a custom title bar an element is to the window manager:
/// where a press moves the window, resizes it, or works a caption button.
/// `Element.chrome` declares it; `Frame.chromeRegions()` lists it.
///
/// ```zig
/// ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) } } });
/// defer ui.close();
/// ui.box(.{ .id = .of("close"), .chrome = .close_button, .interactive = true, .decoration = .{ .background = closeBackground(ui) } });
/// ```
pub const ChromeKind = enum(u8) {
    /// A press drags the window, a double click maximizes or restores it,
    /// and a secondary click opens the system's window menu.
    title_bar,
    /// The host minimizes the window when a press and its release land on it.
    minimize_button,
    /// The host maximizes or restores the window when a press and its
    /// release land on it. Hovering it shows Windows 11's snap layouts.
    maximize_button,
    /// The host closes the window when a press and its release land on it,
    /// as the system's close button does.
    close_button,
    resize_top,
    resize_bottom,
    resize_left,
    resize_right,
    resize_top_left,
    resize_top_right,
    resize_bottom_left,
    resize_bottom_right,
    /// The application's own, inside a title bar: the pointer reaches zui
    /// here as anywhere else. Every interactive element inside a title bar
    /// that declares no chrome is listed as one.
    client,
};

/// One part of a frame's window chrome.
pub const ChromeRegion = struct {
    /// The declaring element's id hash; for a `.client` region, the
    /// interactive element's.
    id: u64,
    /// As laid out, in layout units from the surface's top-left, neither
    /// clipped nor transformed.
    bounds: Rect,
    kind: ChromeKind,
};
