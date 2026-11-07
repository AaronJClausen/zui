/// One of a host's windows. A host with one window calls it `.main`.
pub const WindowId = enum(u32) {
    main = 0,
    _,
};

/// What a host can do beyond the required contract. The application reads
/// them through `zui_app`; what this machine lacks at run time is a status
/// returned by the call instead.
pub const HostCapabilities = struct {
    windows: Windows = .one,
    /// The desktop can show through the window, as Mica or vibrancy.
    system_material: bool = false,

    pub const Windows = enum { one, many };
};

/// What a host opens a window with: `zui_app` passes it to the host's
/// `init`, and a host with many windows will open each one with it.
pub const WindowOptions = struct {
    /// UTF-8.
    title: [:0]const u8 = "zui",
    /// The window's content area, in layout units at a scale of 1.
    size: [2]u32 = .{ 1280, 720 },
    /// False for a window that never shows, as tests and offscreen
    /// captures want.
    visible: bool = true,
    resizable: bool = true,
};
