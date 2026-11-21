//! One small application every renderer draws, so the same frame can be
//! compared across them: a toolbar, a scrolling list, widgets, a tooltip
//! and a modal dialog, generic over the `Ui` that declares it. A target
//! runs it through `zui_app`:
//!
//! ```zig
//! const App = zui_showcase.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .title = "zui + raylib" });
//!
//! pub fn main(init: std.process.Init) !void {
//!     try zui_app.run(App, init, .{ .title = "zui showcase (raylib)" });
//! }
//! ```
//!
//! or declares it on a loop of its own:
//!
//! ```zig
//! const Showcase = zui_showcase.Showcase(Ui);
//! var showcase: Showcase = .{ .title = "zui + raylib", .widgets = .{} };
//! showcase.declare(&ui);
//! ```

const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_app = @import("zui_app");
const zui_glyphs = @import("zui_glyphs");

/// The showcase's colors, dark by default.
pub const Palette = struct {
    background: zui.Color = .rgb(0x16161c),
    panel: zui.Color = .rgb(0x20202a),
    sidebar: zui.Color = .rgb(0x1a1a22),
    text: zui.Color = .rgb(0xe8e8f0),
    muted_text: zui.Color = .rgb(0x9a9aae),
    accent: zui.Color = .rgb(0x5b8cff),
    border: zui.Color = .rgb(0x34344a),
    highlight: zui.Color = .rgb(0xffc65c),
    hovered_row: zui.Color = .rgb(0x3a3a50),
    overlay: zui.Color = .rgba(0x00000099),
};

/// Sizes in layout units. A pixel renderer and a cell renderer need
/// different values for the same UI to read well.
pub const Metrics = struct {
    toolbar_height: f32 = 56,
    sidebar_width: f32 = 260,
    row_height: f32 = 36,
    padding: f32 = 16,
    gap: f32 = 12,
    title_size: f32 = 32,
    body_size: f32 = 18,
    dialog_width: f32 = 420,
    corner_radius: f32 = 6,
};

/// The showcase declared through `Ui`, a `zui.Context`; `declare` it
/// once a frame.
pub fn Showcase(comptime Ui: type) type {
    return struct {
        const Self = @This();

        /// The ids of the showcase's controls, for tests and scripted input.
        pub const ids = zui.ids(.{ "toolbar", "new", "open", "save", "about", "sidebar", "content", "tooltips", "volume", "hover_me", "dialog_close" });

        title: []const u8,
        palette: Palette = .{},
        metrics: Metrics = .{},
        widgets: zui_widgets.Widgets(Ui),

        clicks: u32 = 0,
        last_action: []const u8 = "nothing yet",
        selected_row: ?usize = 2,
        show_tooltips: bool = true,
        volume: f32 = 0.6,
        about_open: bool = false,

        pub fn declare(self: *Self, ui: *Ui) void {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = self.palette.background } });
            defer ui.close();
            self.toolbar(ui);
            {
                ui.open(.{ .layout = .{ .sizing = .grow_both } });
                defer ui.close();
                self.sidebar(ui);
                self.mainPanel(ui);
            }
            self.aboutDialog(ui);
        }

        fn body(self: *const Self, ui: *Ui, content: []const u8, color: zui.Color) void {
            ui.text(content, .{ .size = self.metrics.body_size, .color = color });
        }

        fn toolbar(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.toolbar,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(self.metrics.toolbar_height) }, .padding = .symmetric(self.metrics.padding, 0), .child_gap = self.metrics.gap, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = self.palette.panel, .border = .{ .color = self.palette.border, .widths = .{ .bottom = 1 } } },
            });
            defer ui.close();

            const actions = .{ .{ ids.new, "New" }, .{ ids.open, "Open" }, .{ ids.save, "Save" } };
            inline for (actions) |action| {
                if (self.widgets.button(ui, action[0], action[1], .{})) {
                    self.clicks += 1;
                    self.last_action = action[1];
                }
            }
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
            if (self.widgets.button(ui, ids.about, "About", .{})) self.about_open = true;
        }

        fn sidebar(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.sidebar,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(self.metrics.sidebar_width), .height = .grow } },
                .decoration = .{ .background = self.palette.sidebar },
                .scroll = .{},
            });
            defer ui.close();

            var name_buffer: [32]u8 = undefined;
            for (0..40) |index| {
                const id: zui.Id = .indexed("row", index);
                const state = ui.widgetState(id);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = .pointer,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(self.metrics.row_height) }, .padding = .symmetric(self.metrics.padding, 0), .child_alignment = .{ .y = .center } },
                    .decoration = .{
                        .background = if (self.selected_row == index) self.palette.accent else if (state == .hovered or state == .pressed) self.palette.hovered_row else null,
                        .border = if (ui.focused(id)) .{ .color = self.palette.highlight, .widths = .all(1) } else null,
                    },
                });
                const name = std.fmt.bufPrint(&name_buffer, "Document {d}", .{index + 1}) catch "Document";
                self.body(ui, name, self.palette.text);
                ui.close();
                if (ui.clicked(id)) {
                    self.selected_row = index;
                    self.last_action = "selected a document";
                }
            }
        }

        fn mainPanel(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.content,
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(self.metrics.padding), .child_gap = self.metrics.gap },
            });
            defer ui.close();

            ui.text(self.title, .{ .size = self.metrics.title_size, .color = self.palette.text });
            self.body(ui, "This window is laid out by zui and drawn by the backend named above. The same declaration code runs on every renderer, so differences between them are the renderer's. Resize to watch this paragraph re-wrap, scroll the list with the wheel, and press Tab to move focus.", self.palette.muted_text);

            _ = self.widgets.checkbox(ui, ids.tooltips, "Show tooltips", &self.show_tooltips, .{});
            self.widgets.labeledRow(ui, "Volume");
            _ = self.widgets.slider(ui, ids.volume, &self.volume, .{ .step = 0.05 });
            ui.close();

            {
                ui.open(.{ .id = ids.hover_me, .interactive = true, .layout = .{ .padding = .symmetric(self.metrics.padding, self.metrics.padding / 2) }, .decoration = .{ .background = self.widgets.theme.control.get(ui.widgetState(ids.hover_me)), .corner_radius = .all(self.metrics.corner_radius) } });
                defer ui.close();
                self.body(ui, "Hover me", self.palette.text);
                if (ui.hovered(ids.hover_me) and self.show_tooltips) {
                    ui.open(.{
                        .floating = .{ .anchor = .top_left, .attach_point = .bottom_left, .offset = .{ 0, self.metrics.gap / 2 } },
                        .layout = .{ .padding = .symmetric(self.metrics.padding / 2, self.metrics.padding / 4) },
                        .decoration = .{ .background = self.palette.highlight, .corner_radius = .all(self.metrics.corner_radius) },
                    });
                    self.body(ui, "A floating tooltip", self.palette.background);
                    ui.close();
                }
            }

            var status_buffer: [128]u8 = undefined;
            const selected_number = if (self.selected_row) |index| index + 1 else 0;
            const status = std.fmt.bufPrint(&status_buffer, "Clicks: {d}   Last action: {s}   Selected: document {d}   Volume: {d:.2}", .{ self.clicks, self.last_action, selected_number, self.volume }) catch "";
            self.body(ui, status, self.palette.muted_text);
        }

        fn aboutDialog(self: *Self, ui: *Ui) void {
            if (!self.about_open) return;
            if (ui.keyPressed(.escape)) self.about_open = false;

            ui.open(.{
                .interactive = true,
                .floating = .{ .attach_to = .root, .z = 10 },
                .layout = .{ .sizing = .grow_both, .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = self.palette.overlay },
            });
            defer ui.close();
            ui.open(.{
                .focus_scope = true,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(self.metrics.dialog_width) }, .padding = .all(self.metrics.padding), .child_gap = self.metrics.gap },
                .decoration = .{ .background = self.palette.panel, .corner_radius = .all(self.metrics.corner_radius), .border = .{ .color = self.palette.border, .widths = .all(1) } },
            });
            defer ui.close();
            ui.text("About", .{ .size = self.metrics.title_size, .color = self.palette.text });
            self.body(ui, "This dialog floats in its own layer and keeps Tab focus inside it. Press Escape or Close.", self.palette.muted_text);
            if (self.widgets.button(ui, ids.dialog_close, "Close", .{})) self.about_open = false;
        }
    };
}

/// Metrics that keep controls on whole cells of 8×16 layout units.
pub const cell_metrics: Metrics = .{
    .toolbar_height = 48,
    .sidebar_width = 160,
    .row_height = 16,
    .padding = 16,
    .gap = 16,
    .dialog_width = 400,
    .corner_radius = 1,
};

/// What a target names: the showcase's host, renderer and font system,
/// and the title it shows.
pub const Config = struct {
    Host: type,
    Renderer: type,
    /// A font system, such as `zui_truetype.Text`, laid out for the
    /// placement the renderer draws; `void` when the renderer measures.
    Text: type = void,
    title: []const u8,
};

/// How a run of the showcase behaves, as its flags say:
///
/// ```sh
/// --frames <count>   quit after this many frames, printing whether every frame was ok
/// --hidden           for the target: keep the window hidden
/// ```
pub const Options = struct {
    frame_limit: ?u64 = null,
    hidden: bool = false,

    pub const usage = "--frames <count> or --hidden";

    /// The options `arguments` give, the program's name first.
    pub fn parse(arguments: []const [:0]const u8) error{ UnknownArgument, InvalidCharacter, Overflow }!Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < arguments.len) : (index += 1) {
            const argument = arguments[index];
            if (std.mem.eql(u8, argument, "--frames") and index + 1 < arguments.len) {
                index += 1;
                options.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
            } else if (std.mem.eql(u8, argument, "--hidden")) {
                options.hidden = true;
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }
};

/// The showcase as `zui_app` runs an application on `config.Host`, drawn
/// by `config.Renderer`. On a renderer that draws one glyph per cell it
/// keeps its controls on whole cells. Its `init` takes its `Options` from
/// the process's arguments.
pub fn App(comptime config: Config) type {
    return struct {
        const Self = @This();

        pub const Host = config.Host;
        pub const Renderer = config.Renderer;
        pub const Text = if (config.Text == void) Renderer else config.Text;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = config.Text }));
        pub const ShowcaseOnUi = Showcase(Ui);

        const draws_in_cells = zui_glyphs.placementOf(Renderer) == .cells;

        showcase: ShowcaseOnUi,
        host: *Host,
        options: Options,
        frames: u64 = 0,
        diagnostics_ok: bool = true,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            const options: Options = if (start.process) |process| Options.parse(try process.minimal.args.toSlice(process.arena.allocator())) catch |err| {
                std.log.err("{t}; the showcase takes {s}", .{ err, Options.usage });
                return err;
            } else .{};
            if (config.Text != void and @hasField(config.Text, "placement")) start.text.placement = zui_glyphs.placementOf(Renderer);
            app.* = .{ .showcase = newShowcase(), .host = start.host, .options = options };
            if (@hasField(Renderer, "background")) start.renderer.background = app.showcase.palette.background;
            if (@hasField(Renderer, "clear_color")) start.renderer.clear_color = app.showcase.palette.background;
        }

        pub fn deinit(app: *Self) void {
            if (app.options.frame_limit != null) std.log.info("drew {d} frames, diagnostics ok: {}", .{ app.frames, app.diagnostics_ok });
        }

        /// The showcase as it starts, titled and sized for the renderer.
        pub fn newShowcase() ShowcaseOnUi {
            if (!draws_in_cells) return .{ .title = config.title, .widgets = .{} };
            return .{
                .title = config.title,
                .metrics = cell_metrics,
                .widgets = .{ .theme = .{
                    .corner_radius = 0,
                    .control_height = 16,
                    .horizontal_padding = 8,
                    .gap = 8,
                    .checkbox_size = 16,
                    .slider_thumb_size = .{ 8, 16 },
                    .track_thickness = 16,
                    .label_width = 112,
                } },
            };
        }

        pub fn zuiDeclare(app: *Self, ui: *Ui) void {
            if (app.options.frame_limit != null) ui.requestFrame();
            app.showcase.declare(ui);
        }

        pub fn zuiObserve(app: *Self, _: *const Ui, frame: *const Ui.Frame) void {
            app.diagnostics_ok = app.diagnostics_ok and frame.diagnostics.ok();
        }

        /// Closes the host at the frame limit.
        pub fn zuiLoader(app: *Self, _: *const Ui, _: std.Io) void {
            app.frames += 1;
            if (app.options.frame_limit != app.frames) return;
            if (@hasDecl(Host, "close")) app.host.close() else std.log.err("zui_showcase: {s} cannot close its window, so the run goes on", .{@typeName(Host)});
        }
    };
}

/// Every glyph 8 by 16 units at size 16, so a frame lays out the same on
/// every machine.
const FixedWidthText = struct {
    pub fn zuiMeasure(_: *FixedWidthText, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }
};

test "the showcase declares within its limits, with and without its dialog" {
    const Ui = zui.Context(.{ .Text = FixedWidthText });
    var text: FixedWidthText = .{};
    const io = if (@import("builtin").os.tag == .freestanding) std.Io.failing else std.testing.io;
    var ui: Ui = try .init(std.testing.allocator, io, &text);
    defer ui.deinit(std.testing.allocator);
    var showcase: Showcase(Ui) = .{ .title = "zui + test", .widgets = .{} };
    for ([_]bool{ false, true }) |about_open| {
        showcase.about_open = about_open;
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1280, 720 } } });
        showcase.declare(&ui);
        const frame = ui.endFrame();
        defer ui.release(frame);
        try std.testing.expect(frame.diagnostics.ok());
        try std.testing.expect(frame.rectOf(Showcase(Ui).ids.sidebar) != null);
    }
}

/// Opens a window of 1280×720 units that closes after three frames.
const TestHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    polls: u32 = 0,

    pub fn init(_: *TestHost, _: std.Io, _: zui.WindowOptions) !void {}

    pub fn deinit(_: *TestHost) void {}

    pub fn zuiPoll(self: *TestHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (self.polls == 3) return false;
        self.polls += 1;
        record.begin(.{ .now = .fromNanoseconds(self.polls * std.time.ns_per_s / 60), .viewport = .{ 1280, 720 } });
        return true;
    }

    pub fn zuiWaker(self: *TestHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiWait(_: *TestHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *TestHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1280, 720 }, .format = .sdr } };
    }

    pub fn zuiApply(_: *TestHost, _: zui.WindowId, _: zui.HostRequests) void {}

    fn ignoreWake(_: *anyopaque) void {}
};

fn TestRenderer(comptime placement: zui_glyphs.Placement) type {
    return struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const glyph_placement = placement;

        submitted: u32 = 0,
        background: zui.Color = .black,
        clear_color: zui.Color = .black,

        pub fn zuiSubmit(self: *@This(), _: zui.Surface, _: anytype) !void {
            self.submitted += 1;
        }
    };
}

test "a target runs the showcase through zui_app, its controls on whole cells where the renderer draws cells" {
    if (@import("builtin").os.tag == .freestanding) return error.SkipZigTest;
    inline for (.{ zui_glyphs.Placement.pixel_grid, zui_glyphs.Placement{ .cells = .{ 8, 16 } } }) |placement| {
        const ShowcaseApp = App(.{ .Host = TestHost, .Renderer = TestRenderer(placement), .Text = FixedWidthText, .title = "zui + test" });
        var runner: zui_app.Runner(ShowcaseApp) = undefined;
        try runner.start(.{ .gpa = std.testing.allocator, .io = std.testing.io }, .{ .notify = ignoreNotice });
        defer runner.stop();
        while (try runner.frame()) {}
        try std.testing.expectEqual(3, runner.renderer.submitted);
        try std.testing.expect(runner.app.diagnostics_ok);
        try std.testing.expectEqual(runner.app.showcase.palette.background, runner.renderer.clear_color);
        try std.testing.expectEqual(runner.app.showcase.palette.background, runner.renderer.background);
        try std.testing.expectEqual(placement == .cells, runner.app.showcase.metrics.row_height == cell_metrics.row_height);
    }
}

fn ignoreNotice(_: zui_app.Notice) void {}

test "the showcase's options are its flags" {
    const options = try Options.parse(&.{ "showcase", "--hidden", "--frames", "60" });
    try std.testing.expectEqual(60, options.frame_limit);
    try std.testing.expect(options.hidden);
    try std.testing.expectError(error.UnknownArgument, Options.parse(&.{ "showcase", "--dump" }));
}
