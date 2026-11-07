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
