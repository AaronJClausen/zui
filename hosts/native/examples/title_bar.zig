//! A window whose title bar the application draws: a search field, and
//! minimize, maximize and close buttons, over Mica on Windows. Its parts
//! are chrome regions, so the OS still drags the window by its title bar,
//! maximizes it on a double click and opens its window menu on a secondary
//! click. Windows also snaps it with Win+arrows, shows snap layouts over the
//! maximize button, and resizes it from every edge; a Wayland compositor
//! resizes it from the grips the application declares.
//!
//! ```sh
//! zig build title-bar                          # interactive window
//! zig build title-bar -- --no-system-material  # the solid background Windows 10 shows
//! zig build title-bar -- --check               # hit-test each part in a hidden window, then quit
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_truetype = @import("zui_truetype");
const zui_app = @import("zui_app");
const zui_widgets = @import("zui_widgets");
const zui_design = @import("zui_design");
const zui = @import("zui");
const win32 = if (builtin.os.tag == .windows) zui_host.windows.win32 else struct {};

const Ui = zui.Context(zui_app.contextConfig(zui_sokol.Renderer, .{ .Text = zui_truetype.Text, .features = .{ .semantics = true, .chrome_regions = true } }));
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));

const ids = zui.ids(.{ "root", "title_bar", "title", "search", "minimize", "maximize", "close", "content", "grip" });
const title_bar_height = 32;
const caption_button_width = 46;
const grip_size = 16;
const instructions = if (builtin.os.tag == .windows)
    "Drag the title bar, double-click it, snap with Win+arrows, hover maximize for snap layouts, and resize from any edge."
else
    "Drag the title bar, double-click it, right-click it for the window menu, and resize from the grip in the corner.";

const Palette = struct {
    background: zui.Color,
    text: zui.Color,
    hovered: zui.Color,
    pressed: zui.Color,
    close_hovered: zui.Color,

    const light: Palette = .{ .background = .rgb(0xf3f3f3), .text = .rgb(0x1b1b1b), .hovered = .rgba(0x0000001a), .pressed = .rgba(0x00000033), .close_hovered = .rgb(0xc42b1c) };
    const dark: Palette = .{ .background = .rgb(0x202020), .text = .rgb(0xf3f3f3), .hovered = .rgba(0xffffff1a), .pressed = .rgba(0xffffff33), .close_hovered = .rgb(0xc42b1c) };

    fn of(environment: *const zui.Environment) Palette {
        return if (environment.theme == .dark) dark else light;
    }
};

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var checking = false;
    var material: zui.SystemMaterial = .window;
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--check")) {
            checking = true;
        } else if (std.mem.eql(u8, argument, "--no-system-material")) {
            material = .none;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --check or --no-system-material\n", .{argument});
            return error.UnknownArgument;
        }
    }

    const session = try init.gpa.create(zui_app.Session(TitleBarApp));
    defer init.gpa.destroy(session);
    try session.start(.{ .gpa = init.gpa, .io = init.io, .process = init }, .{
        .title = "zui: a custom title bar",
        .size = .{ 720, 480 },
        .visible = !checking,
        .material = material,
        .title_bar = .custom,
    });
    defer session.stop();
    if (checking) {
        // A Wayland surface the compositor never shows gets no frame
        // callbacks, and a swap waits for the last frame's.
        if (builtin.os.tag == .linux) session.renderer.draws = false;
        session.app.check = .{};
    }
    while (try session.frame()) {}
    if (session.app.check) |check| return check.result();
}

const TitleBarApp = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_truetype.Text;

    host: *Host = undefined,
    widgets: Widgets = .{ .skin = .{ .tokens = &widget_tokens } },
    search_bytes: [64]u8 = undefined,
    search: zui_widgets.EditableText = undefined,
    check: ?Check = null,

    pub fn init(app: *TitleBarApp, start: zui_app.Start(TitleBarApp)) !void {
        app.* = .{ .host = start.host };
        app.search = .init(&app.search_bytes, "");
    }

    pub fn zuiDeclare(app: *TitleBarApp, ui: *Ui) void {
        const environment = ui.environment();
        const palette: Palette = .of(environment);
        ui.open(.{
            .id = ids.root,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
            .decoration = .{ .background = if (environment.system_material) null else palette.background },
        });
        defer ui.close();
        if (environment.custom_title_bar) app.titleBar(ui, palette);
        ui.open(.{ .id = ids.content, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 8 } });
        ui.text(instructions, .{ .size = 15, .color = palette.text, .wrap = .words });
        ui.close();
        if (environment.custom_title_bar and !environment.window_maximized) {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_alignment = .{ .x = .end } } });
            defer ui.close();
            ui.box(.{ .id = ids.grip, .chrome = .resize_bottom_right, .layout = .{ .sizing = .{ .width = .fixed(grip_size), .height = .fixed(grip_size) } }, .decoration = .{ .background = palette.hovered } });
        }
    }

    fn titleBar(app: *TitleBarApp, ui: *Ui, palette: Palette) void {
        ui.open(.{
            .id = ids.title_bar,
            .chrome = .title_bar,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(title_bar_height) }, .padding = .{ .left = 12 }, .child_gap = 12, .child_alignment = .{ .y = .center } },
        });
        defer ui.close();
        ui.open(.{ .id = ids.title, .semantics = .{ .role = .label, .label = "zui: a custom title bar" } });
        ui.text("zui: a custom title bar", .{ .size = 12, .color = palette.text });
        ui.close();
        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
        _ = app.widgets.textField(ui, ids.search, &app.search, .{ .label = "Search" });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });

        const maximized = ui.environment().window_maximized;
        if (captionButton(ui, ids.minimize, .minimize_button, "Minimize", palette.hovered, palette)) app.host.minimize();
        if (captionButton(ui, ids.maximize, .maximize_button, if (maximized) "Restore" else "Maximize", palette.hovered, palette)) app.host.toggleMaximized();
        if (captionButton(ui, ids.close, .close_button, "Close", palette.close_hovered, palette)) app.host.close();
    }

    /// True for the keyboard's click or an assistive technology's invoke.
    /// A pointer's press on a caption button is the host's, which works the
    /// button and ends the press without a click.
    fn captionButton(ui: *Ui, id: zui.Id, kind: zui.ChromeKind, label: []const u8, hovered: zui.Color, palette: Palette) bool {
        const state = ui.widgetState(id);
        ui.open(.{
            .id = id,
            .chrome = kind,
            .focusable = true,
            .semantics = .{ .role = .button, .label = label },
            .decoration = .{ .background = switch (state) {
                .hovered => hovered,
                .pressed => palette.pressed,
                else => null,
            } },
            .layout = .{ .sizing = .{ .width = .fixed(caption_button_width), .height = .grow }, .child_alignment = .{ .x = .center, .y = .center } },
        });
        defer ui.close();
        const glyph = palette.text;
        switch (kind) {
            .minimize_button => ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(1) } }, .decoration = .{ .background = glyph } }),
            .maximize_button => ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .border = .{ .color = glyph, .widths = .all(1) }, .corner_radius = .all(if (std.mem.eql(u8, label, "Restore")) 3 else 1) } }),
            else => ui.text("X", .{ .size = 13, .color = glyph }),
        }
        return ui.clicked(id);
    }

    pub fn zuiObserve(app: *TitleBarApp, _: *const Ui, frame: *const Ui.Frame) void {
        if (app.check) |*check| check.observe(frame);
    }

    pub fn zuiLoader(app: *TitleBarApp, _: *const Ui, _: std.Io) void {
        if (app.check) |*check| check.step(app.host);
    }
};

/// `--check`: once the title bar has been drawn and handed to the host,
/// asks the window what each part is, as Windows does when the pointer is
/// over it, and quits.
const Check = struct {
    /// Null for a part that is the application's.
    const Expectation = struct { id: zui.Id, kind: ?zui.ChromeKind, name: []const u8 };
    const expectations = [_]Expectation{
        .{ .id = ids.title, .kind = .title_bar, .name = "the title" },
        .{ .id = ids.search, .kind = null, .name = "the search field" },
        .{ .id = ids.minimize, .kind = .minimize_button, .name = "minimize" },
        .{ .id = ids.maximize, .kind = .maximize_button, .name = "maximize" },
        .{ .id = ids.close, .kind = .close_button, .name = "close" },
        .{ .id = ids.content, .kind = null, .name = "the content" },
        .{ .id = ids.grip, .kind = .resize_bottom_right, .name = "the grip" },
    };

    /// `WM_NCHITTEST`'s code on Windows; on Linux the chrome the host
    /// hands a press at the point to the compositor for.
    const Answer = if (builtin.os.tag == .windows) win32.LRESULT else ?zui.ChromeKind;

    frames: u32 = 0,
    centres: [expectations.len]?[2]f32 = @splat(null),
    failures: u32 = 0,
    done: bool = false,

    fn observe(check: *Check, frame: *const Ui.Frame) void {
        for (expectations, &check.centres) |expectation, *centre| {
            const rect = frame.rectOf(expectation.id) orelse continue;
            centre.* = .{ rect.x + rect.width / 2, rect.y + rect.height * 0.75 };
        }
    }

    fn step(check: *Check, host: *zui_host.Host) void {
        check.frames += 1;
        if (check.done) return;
        if (check.frames < 3) return host.zuiWaker().wake();
        for (expectations, check.centres) |expectation, centre| {
            const at = centre orelse {
                std.debug.print("title-bar check: {s} was not drawn\n", .{expectation.name});
                check.failures += 1;
                continue;
            };
            const answered = answerAt(host, at);
            const expected = expectedAnswer(expectation.kind);
            if (answered != expected) {
                std.debug.print("title-bar check: {s} hit-tests as {any}, expected {any}\n", .{ expectation.name, answered, expected });
                check.failures += 1;
            }
        }
        check.done = true;
        host.close();
    }

    fn expectedAnswer(kind: ?zui.ChromeKind) Answer {
        if (builtin.os.tag == .windows) {
            return if (kind) |chrome_kind| zui_host.windows.chrome.hitTestCode(chrome_kind) else win32.HTCLIENT;
        } else return kind;
    }

    /// What the OS makes of a point, in layout units.
    fn answerAt(host: *zui_host.Host, at: [2]f32) Answer {
        if (builtin.os.tag == .windows) {
            const pixels_per_unit = host.pixelsPerUnit(.main);
            var point: win32.POINT = .{
                .x = @intFromFloat(at[0] * pixels_per_unit),
                .y = @intFromFloat(at[1] * pixels_per_unit),
            };
            _ = win32.ClientToScreen(host.hwnd, &point);
            return win32.SendMessageW(host.hwnd, win32.WM_NCHITTEST, 0, win32.lparamFromPoint(@intCast(point.x), @intCast(point.y)));
        } else {
            const surface_coordinates_per_unit = host.surfaceCoordinatesPerUnit(.main);
            return host.chromeKindAt(.main, .{ at[0] * surface_coordinates_per_unit, at[1] * surface_coordinates_per_unit });
        }
    }

    fn result(check: Check) !void {
        if (!check.done) return error.CheckDidNotRun;
        if (check.failures != 0) return error.CheckFailed;
        std.debug.print("title-bar check: every part hit-tests as drawn\n", .{});
    }
};

const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;

    sokol: zui_sokol.Renderer,
    /// False submits nothing, for a window that is never shown.
    draws: bool = true,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: anytype) !void {
        self.* = .{ .sokol = try .initForSurface(text, surface) };
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        if (self.draws) try self.sokol.zuiSubmit(surface, frame);
    }
};

/// zui's default design in dark, resolved during the build.
const widget_tokens: zui.design.Tokens(Ui, void) = resolved: {
    @setEvalBranchQuota(10_000_000);
    var dark: zui.design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(zui_design.default, .{ .theme = .dark }, &dark);
    break :resolved dark;
};
