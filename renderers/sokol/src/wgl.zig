//! An OpenGL context on a Win32 window a host owns, for sokol_gfx without
//! sokol_app.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const BOOL = c_int;
const HWND = *opaque {};
const HDC = *opaque {};
const HGLRC = *opaque {};
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_TYPE_RGBA = 0;
const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB = 0x0002;
const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_ALPHA_BITS_ARB = 0x201B;
const WGL_DEPTH_BITS_ARB = 0x2022;
const WGL_STENCIL_BITS_ARB = 0x2023;
const WGL_TYPE_RGBA_ARB = 0x202B;
const WGL_SAMPLE_BUFFERS_ARB = 0x2041;
const WGL_SAMPLES_ARB = 0x2042;

const CreateContextAttribs = *const fn (HDC, ?HGLRC, [*]const c_int) callconv(.winapi) ?HGLRC;
const ChoosePixelFormatArb = *const fn (HDC, [*]const c_int, ?[*]const f32, c_uint, *c_int, *c_uint) callconv(.winapi) BOOL;
const SwapInterval = *const fn (c_int) callconv(.winapi) BOOL;

extern "user32" fn CreateWindowExW(ex_style: u32, class_name: [*:0]const u16, window_name: ?[*:0]const u16, style: u32, x: c_int, y: c_int, width: c_int, height: c_int, parent: ?HWND, menu: ?*anyopaque, instance: ?*anyopaque, parameter: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "gdi32" fn DescribePixelFormat(hdc: HDC, format: c_int, size: c_uint, descriptor: *PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, hdc: HDC) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, descriptor: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, descriptor: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(context: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, context: ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// The window's OpenGL 4.3 core context, current on the thread that made
/// it, presenting with vsync. Windows composes its pixels as opaque, so a
/// system backdrop behind the window does not show through.
pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    context: HGLRC,
    /// Of the window's default framebuffer: `wanted_sample_count` when the
    /// driver offers it, which smooths the edges of shapes, or 1.
    sample_count: i32,

    pub fn init(window: *anyopaque) error{ NoDeviceContext, NoPixelFormat, NoOpenGlContext, NoCoreProfile }!Context {
        const hwnd: HWND = @ptrCast(window);
        const hdc = GetDC(hwnd) orelse return error.NoDeviceContext;
        errdefer _ = ReleaseDC(hwnd, hdc);
        const entry_points = try EntryPoints.load();
        const format = try PixelFormat.choose(hdc, entry_points.choose_pixel_format);
        var descriptor: PIXELFORMATDESCRIPTOR = .{};
        if (DescribePixelFormat(hdc, format.index, @sizeOf(PIXELFORMATDESCRIPTOR), &descriptor) == 0 or SetPixelFormat(hdc, format.index, &descriptor) == 0) return error.NoPixelFormat;

        const attributes = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_FLAGS_ARB,         WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const context = entry_points.create_context(hdc, null, &attributes) orelse return error.NoCoreProfile;
        if (wglMakeCurrent(hdc, context) == 0) {
            _ = wglDeleteContext(context);
            return error.NoOpenGlContext;
        }
        if (wglGetProcAddress("wglSwapIntervalEXT")) |address| {
            const swap_interval: SwapInterval = @ptrCast(@alignCast(address));
            _ = swap_interval(1);
        }
        return .{ .hwnd = hwnd, .hdc = hdc, .context = context, .sample_count = format.sample_count };
    }

    pub fn deinit(self: *Context) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.context);
        _ = ReleaseDC(self.hwnd, self.hdc);
    }

    const color_format: sg.PixelFormat = .RGBA8;
    const depth_format: sg.PixelFormat = .DEPTH_STENCIL;

    pub fn environment(self: *const Context) sg.Environment {
        return .{ .defaults = .{ .color_format = color_format, .depth_format = depth_format, .sample_count = self.sample_count } };
    }

    /// The window's default framebuffer, at the client area's size now.
    pub fn swapchain(self: *const Context) sg.Swapchain {
        var client: RECT = .{};
        _ = GetClientRect(self.hwnd, &client);
        return .{
            .width = @max(client.right - client.left, 1),
            .height = @max(client.bottom - client.top, 1),
            .sample_count = self.sample_count,
            .color_format = color_format,
            .depth_format = depth_format,
            .gl = .{ .framebuffer = 0 },
        };
    }

    /// Waits for the display's next refresh.
    pub fn present(self: *const Context) void {
        _ = SwapBuffers(self.hdc);
    }
};

const wanted_sample_count = 4;

const legacy_pixel_format: PIXELFORMATDESCRIPTOR = .{
    .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
    .iPixelType = PFD_TYPE_RGBA,
    .cColorBits = 32,
    .cAlphaBits = 8,
    .cDepthBits = 24,
    .cStencilBits = 8,
};

/// What makes a core profile context on a multisampled pixel format. Both
/// are reachable only through a current context, and a window's pixel
/// format is set once, so a legacy context on a hidden window of its own
/// finds them.
const EntryPoints = struct {
    create_context: CreateContextAttribs,
    choose_pixel_format: ?ChoosePixelFormatArb,

    fn load() error{ NoPixelFormat, NoOpenGlContext, NoCoreProfile }!EntryPoints {
        const hidden = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.NoOpenGlContext;
        defer _ = DestroyWindow(hidden);
        const hdc = GetDC(hidden) orelse return error.NoOpenGlContext;
        defer _ = ReleaseDC(hidden, hdc);
        const format = ChoosePixelFormat(hdc, &legacy_pixel_format);
        if (format == 0 or SetPixelFormat(hdc, format, &legacy_pixel_format) == 0) return error.NoPixelFormat;
        const legacy = wglCreateContext(hdc) orelse return error.NoOpenGlContext;
        defer _ = wglDeleteContext(legacy);
        if (wglMakeCurrent(hdc, legacy) == 0) return error.NoOpenGlContext;
        defer _ = wglMakeCurrent(null, null);
        return .{
            .create_context = @ptrCast(@alignCast(wglGetProcAddress("wglCreateContextAttribsARB") orelse return error.NoCoreProfile)),
            .choose_pixel_format = if (wglGetProcAddress("wglChoosePixelFormatARB")) |address| @ptrCast(@alignCast(address)) else null,
        };
    }
};

const PixelFormat = struct {
    index: c_int,
    sample_count: i32,

    fn choose(hdc: HDC, choose_pixel_format: ?ChoosePixelFormatArb) error{NoPixelFormat}!PixelFormat {
        if (choose_pixel_format) |choose_multisampled| {
            const attributes = [_]c_int{
                WGL_DRAW_TO_WINDOW_ARB, 1,
                WGL_SUPPORT_OPENGL_ARB, 1,
                WGL_DOUBLE_BUFFER_ARB,  1,
                WGL_PIXEL_TYPE_ARB,     WGL_TYPE_RGBA_ARB,
                WGL_COLOR_BITS_ARB,     32,
                WGL_ALPHA_BITS_ARB,     8,
                WGL_DEPTH_BITS_ARB,     24,
                WGL_STENCIL_BITS_ARB,   8,
                WGL_SAMPLE_BUFFERS_ARB, 1,
                WGL_SAMPLES_ARB,        wanted_sample_count,
                0,
            };
            var index: c_int = 0;
            var count: c_uint = 0;
            if (choose_multisampled(hdc, &attributes, null, 1, &index, &count) != 0 and count > 0) return .{ .index = index, .sample_count = wanted_sample_count };
        }
        const index = ChoosePixelFormat(hdc, &legacy_pixel_format);
        if (index == 0) return error.NoPixelFormat;
        return .{ .index = index, .sample_count = 1 };
    }
};

comptime {
    std.debug.assert(@sizeOf(PIXELFORMATDESCRIPTOR) == 40);
}
