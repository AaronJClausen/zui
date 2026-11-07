const std = @import("std");

pub const SurfaceKind = enum {
    win32,
    cocoa,
    wayland,
    x11,
    web,
    offscreen,
    /// A character grid, drawn as cells.
    terminal,
    /// A window a library creates and draws into itself, such as raylib's
    /// or sokol_app's: only that library's adapter host provides one, and
    /// only a renderer on that library draws into it.
    library,
};

/// `.initMany(&.{ .win32, .x11 })`
pub const SurfaceKinds = std.EnumSet(SurfaceKind);

/// What a host hands a renderer to draw into: a native handle, or a
/// surface a library owns.
pub const Surface = union(SurfaceKind) {
    win32: struct { hwnd: *anyopaque },
    cocoa: struct { view: *anyopaque },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    x11: struct { display: *anyopaque, window: u64 },
    /// The canvas the web host created, by the id it gave it.
    web: struct { canvas: u32 },
    /// Physical pixels.
    offscreen: struct { size: [2]u32 },
    terminal: struct { columns: u16, rows: u16 },
    library,
};
