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
    /// A connection to another process, which a `zui_wire` host made and
    /// only a `zui_wire` renderer writes frames into.
    wire,
};

/// `.initMany(&.{ .win32, .x11 })`
pub const SurfaceKinds = std.EnumSet(SurfaceKind);

/// The pixels a surface's target holds, which its renderer encodes each
/// color into.
pub const OutputFormat = enum {
    /// 8 bits a channel in sRGB, which every host and renderer can use.
    sdr,
    /// Half floats a channel in linear scRGB, as `zui.ExtendedColor`
    /// holds them: 1.0 is SDR white, and above it is HDR.
    scrgb_fp16,
};

/// The output formats a host can open a surface in or a renderer can draw
/// into, which always include `.sdr`:
///
/// ```zig
/// pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });
/// ```
pub const OutputFormats = std.EnumSet(OutputFormat);

/// What a host hands a renderer to draw into: a native handle, or a
/// surface a library owns. A native surface carries the output format the
/// host opened it in, one of `zui.WindowOptions.output_formats`.
pub const Surface = union(SurfaceKind) {
    win32: struct { hwnd: *anyopaque, format: OutputFormat = .sdr },
    cocoa: struct { view: *anyopaque, format: OutputFormat = .sdr },
    /// `transparent`: the compositor blends the surface over what is behind
    /// the window by the alpha it holds, so its renderer keeps alpha;
    /// otherwise every pixel it presents is opaque.
    wayland: struct { display: *anyopaque, surface: *anyopaque, format: OutputFormat = .sdr, transparent: bool = false },
    x11: struct { display: *anyopaque, window: u64, format: OutputFormat = .sdr },
    /// The canvas the web host created, by the id it gave it.
    web: struct { canvas: u32, format: OutputFormat = .sdr },
    /// Physical pixels.
    offscreen: struct { size: [2]u32, format: OutputFormat = .sdr },
    /// The terminal's size in cells, and where the host lets the renderer
    /// write the sequences that draw them.
    terminal: struct { columns: u16, rows: u16, output: *std.Io.Writer },
    library,
    wire: struct { connection: *anyopaque },

    /// `.sdr` for a surface that carries no format.
    pub fn outputFormat(self: Surface) OutputFormat {
        return switch (self) {
            inline .win32, .cocoa, .wayland, .x11, .web, .offscreen => |native| native.format,
            .terminal, .library, .wire => .sdr,
        };
    }
};

/// The output formats `Party`, a host or a renderer, declares: its
/// `zui_output_formats`, or SDR alone.
pub fn declaredOutputFormats(comptime Party: type) OutputFormats {
    return if (@hasDecl(Party, "zui_output_formats")) Party.zui_output_formats else .initOne(.sdr);
}

/// The output formats both `Host` and `Renderer` support, which a window
/// is opened with: SDR, unless both declare more.
pub fn sharedOutputFormats(comptime Host: type, comptime Renderer: type) OutputFormats {
    return declaredOutputFormats(Host).intersectWith(declaredOutputFormats(Renderer));
}
